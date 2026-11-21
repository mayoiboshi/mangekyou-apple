import Foundation

enum SaveLayerClockWords {
    /// The native reader converts each serialized Int32 time word to a floating
    /// value before storing it in the live object arrays. Keep float bit patterns
    /// only inside renderer-facing snapshots.
    static func runtimeFloatBitPatterns(fromSavedWords words: [Int32]) -> [Int32] {
        words.map { Int32(bitPattern: Float($0).bitPattern) }
    }

    /// The native writer applies its x87 ROUND helper to each live float before
    /// writing fixed-record integer words. The default host rounding mode is
    /// nearest-even; other native rounding modes remain outside this profile.
    static func savedWords(fromRuntimeFloatBitPatterns words: [Int32]) throws -> [Int32] {
        try words.map { word in
            let value = Float(bitPattern: UInt32(bitPattern: word))
            guard value.isFinite, let rounded = Int32(exactly: Double(value).rounded(.toNearestOrEven)) else {
                throw ResourceError.rejected("save_layer_clock_word_out_of_range")
            }
            return rounded
        }
    }
}

/// Scalar array records at a caller-verified CalVal or ValIdx array offset.
/// Header bytes and the two serialized text fields retain their original order.
package struct SaveVariableArrays {
    package struct Summary: Encodable, Sendable {
        let status: EvidenceStatus = .verified
        let decodedOffset: Int
        let integerArrayCount: Int
        let stringArrayCount: Int
        let objectArrayCount: Int
        let absentValueCount: Int
        let buttonPayloads: [ButtonPayload]
        let imagePayloads: [ImagePayload]
        let messagePayloads: [MessagePayload]
        let timerPayloads: [TimerPayload]
        package let nextDecodedOffset: Int
        package let indexed: IndexedSummary
    }

    package struct IndexedSummary: Encodable, Sendable {
        struct GroupSpan: Encodable, Sendable {
            let decodedOffset: Int
            let byteLength: Int
        }
        package let status: EvidenceStatus
        let decodedOffset: Int
        var groupCount: Int?
        var recordCount: Int?
        var objectArrayCount: Int?
        var groupSpans: [GroupSpan]?
        package var nextDecodedOffset: Int?
        var issue: String?
    }

    private static func inspectValIdx(state: Data, at offset: Int, visit: ((Int, Int, Self) -> Void)?) throws -> IndexedSummary {
        let start = state.startIndex + offset
        let tag = state[start..<min(start + 8, state.endIndex)]
        guard tag.prefix(while: { $0 != 0 }).elementsEqual("ValIdx".utf8) else {
            return IndexedSummary(status: .notTested, decodedOffset: offset, issue: "validx_tag_absent")
        }
        guard state.count - offset >= 16 else { throw ResourceError.rejected("truncated_validx_header") }
        let (version, count) = state.withUnsafeBytes { bytes in
            (Int32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + 8, as: Int32.self)),
             Int(Int32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + 12, as: Int32.self))))
        }
        guard version == 0 else {
            return IndexedSummary(status: .unsupported, decodedOffset: offset, issue: "unsupported_validx_version")
        }
        var cursor = offset + 16
        guard (0...min(4096, (state.count - cursor) / 4)).contains(count) else {
            throw ResourceError.rejected("invalid_validx_count")
        }
        var records = 0
        var objects = 0
        var spans: [IndexedSummary.GroupSpan] = []
        for slot in 0..<count {
            let group = try Self(state: state, decodedOffset: cursor)
            visit?(slot, cursor, group)
            spans.append(.init(decodedOffset: cursor, byteLength: group.nextDecodedOffset - cursor))
            cursor = group.nextDecodedOffset
            records += group.records.count
            objects += group.records.count { record in
                if case .objectText = record.values { return true }
                return false
            }
        }
        return IndexedSummary(status: .verified, decodedOffset: offset, groupCount: count,
                              recordCount: records, objectArrayCount: objects,
                              groupSpans: spans, nextDecodedOffset: cursor)
    }

    private static func generatedIndexedLocals(_ frames: [ScriptFrame], liveStorage: ScriptStorage?) throws -> Data {
        guard frames.count <= 64 else { throw ResourceError.rejected("save_indexed_locals_frame_count") }
        var output = Data("ValIdx\0\0".utf8) + Data(repeating: 0, count: 4)
        let count = UInt32(frames.count)
        withUnsafeBytes(of: count.littleEndian) { output.append(contentsOf: $0) }
        let emptyCalVal = Data("CalVal\0\0".utf8) + Data([1, 0, 0, 0]) + Data(repeating: 0, count: 8)
        for (frameIndex, frame) in frames.enumerated() {
            var values = liveStorage ?? ScriptStorage()
            values.global.merge(frame.locals, uniquingKeysWith: { _, local in local })
            values.system.removeAll()
            values.frames = [frame]
            values.globalObjectAliases.formUnion(frame.objectAliases)
            values.globalAliasReferences.merge(frame.objectAliasReferences, uniquingKeysWith: { _, local in local })
            var newBindingKeys = Set(frame.locals.keys)
            let parameterKeys = ["paramcount", "paramint", "paramstr"].map { Data($0.utf8) }
            if (frame.parameterCount ?? 0) != 0 {
                guard frame.returnIndex != nil, let count = frame.parameterCount, (0...16).contains(count),
                      let integers = frame.integerParameters, integers.count == 16,
                      let strings = frame.stringParameters, strings.count == 16,
                      parameterKeys.allSatisfy({ !frame.locals.keys.contains($0) && liveStorage?.global[$0] == nil }) else {
                    throw ResourceError.rejected("save_indexed_call_parameter_shape")
                }
                values.global[parameterKeys[0]] = .init(elements: [.integer(count)])
                values.global[parameterKeys[1]] = .init(elements: integers.map(ScriptValue.integer))
                values.global[parameterKeys[2]] = .init(elements: strings.map(ScriptValue.string))
                newBindingKeys.formUnion(parameterKeys)
            }
            let unsupported = newBindingKeys.filter { generatedBindingType($0, in: values) == nil }
            guard unsupported.isEmpty else {
                let details = unsupported.sorted { $0.lexicographicallyPrecedes($1) }.prefix(8).map { key in
                    let kinds = values.global[key]?.elements.map { value -> String in
                        switch value {
                        case .integer: return "int"
                        case .string: return "str"
                        case .object(let handle):
                            let matches = [
                                values.tables[handle] != nil ? "table" : nil,
                                values.lists[handle] != nil ? "list" : nil,
                                values.images[handle] != nil ? "image" : nil,
                                values.messages[handle] != nil ? "message" : nil,
                                values.buttons.contains(handle) ? "button" : nil,
                                values.timers[handle] != nil ? "timer" : nil,
                                values.movies[handle] != nil ? "movie" : nil
                            ].compactMap { $0 }.joined(separator: ",")
                            return matches.isEmpty ? "object_unknown" : matches
                        }
                    }.joined(separator: ",") ?? "missing"
                    return "\(key.sha256Hex):alias=\(values.globalObjectAliases.contains(key) ? 1 : 0):kind=\(kinds)"
                }.joined(separator: ";")
                throw ResourceError.rejected(
                    "save_indexed_new_binding_type_outside_profile:frame=\(frameIndex):bindings=\(unsupported.count):\(details)")
            }
            let generated = try encodeCalValValues(template: emptyCalVal, storage: values,
                                                   newBindingKeys: newBindingKeys)
            guard generated.count - 16 <= SaveEnvelope.maxFileBytes - output.count else {
                throw ResourceError.rejected("save_indexed_locals_size_limit")
            }
            output.append(contentsOf: generated.dropFirst(16))
        }
        let checked = try inspectValIdx(state: output, at: 0, visit: nil)
        guard checked.status == .verified, checked.groupCount == frames.count,
              checked.nextDecodedOffset == output.count else {
            throw ResourceError.rejected("save_indexed_generated_boundary")
        }
        return output
    }

    static func encodeIndexedLocals(in state: Data, at offset: Int, frames: [ScriptFrame],
                                   liveStorage: ScriptStorage? = nil) throws
        -> (bytes: Data, end: Int) {
        let indexed = try inspectValIdx(state: state, at: offset, visit: nil)
        let needsGroups = frames.contains { !$0.locals.isEmpty || ($0.parameterCount ?? 0) != 0 }
        if indexed.issue == "validx_tag_absent", needsGroups {
            return (try generatedIndexedLocals(frames, liveStorage: liveStorage), offset)
        }
        guard let groups = indexed.groupSpans, let end = indexed.nextDecodedOffset else {
            guard indexed.issue == "validx_tag_absent", !needsGroups else {
                throw ResourceError.rejected("save_indexed_locals_template_required")
            }
            return (Data(), offset)
        }
        guard groups.count == frames.count || (groups.isEmpty && !needsGroups) else {
            // A real running call stack can differ from the donor save's
            // indexed-local frame count. Rebuild only from the current live
            // frame bindings and parameter arrays, then validate the emitted
            // ValIdx structure before using it.
            return (try generatedIndexedLocals(frames, liveStorage: liveStorage), end)
        }
        var output = Data(state.dropFirst(offset).prefix(16))
        for (span, frame) in zip(groups, frames) {
            let group = try Self(state: state, decodedOffset: span.decodedOffset)
            var template = try ScriptStorage.stageSavedGlobalScalars(group)
            _ = try template.stageSavedSoundAliases(group)
            var values = ScriptStorage()
            values.global = frame.locals
            values.globalObjectAliases = frame.objectAliases
            values.globalAliasReferences = frame.objectAliasReferences
            let parameterKeys = ["paramcount", "paramint", "paramstr"].map { Data($0.utf8) }
            if (frame.parameterCount ?? 0) != 0 || parameterKeys.contains(where: { template.global[$0] != nil }) {
                guard frame.returnIndex != nil, let count = frame.parameterCount, (0...16).contains(count),
                      let integers = frame.integerParameters, integers.count == 16,
                      let strings = frame.stringParameters, strings.count == 16,
                      parameterKeys.allSatisfy({ values.global[$0] == nil }) else {
                    throw ResourceError.rejected("save_indexed_call_parameter_shape")
                }
                values.global[parameterKeys[0]] = .init(elements: [.integer(count)])
                values.global[parameterKeys[1]] = .init(elements: integers.map(ScriptValue.integer))
                values.global[parameterKeys[2]] = .init(elements: strings.map(ScriptValue.string))
            }
            guard template.global.count == group.records.count,
                  Set(template.global.keys) == Set(values.global.keys) else {
                // Donor frames can have the same depth but different locals.
                // Rebuild the entire group list from the live frames and keep
                // the original donor boundary for the following engine tail.
                return (try generatedIndexedLocals(frames, liveStorage: liveStorage), end)
            }
            let header = Data("CalVal\0\0".utf8) + Data([1, 0, 0, 0, 0, 0, 0, 0])
            let source = Data(state.dropFirst(span.decodedOffset).prefix(span.byteLength))
            let encoded = try encodeCalValValues(template: header + source, storage: values)
            guard encoded.count - header.count <= SaveEnvelope.maxFileBytes - output.count else {
                throw ResourceError.rejected("save_indexed_locals_size_limit")
            }
            output.append(contentsOf: encoded.dropFirst(header.count))
        }
        return (output, end)
    }

    static func readCalVal(state: Data, at offset: Int) throws -> Self {
        guard offset >= 0, offset <= state.count, state.count - offset >= 16 else {
            throw ResourceError.rejected("calval_prefix_missing")
        }
        let start = state.startIndex + offset
        guard state[start..<(start + 8)].prefix(while: { $0 != 0 }).elementsEqual("CalVal".utf8) else {
            throw ResourceError.rejected("calval_prefix_missing")
        }
        let version = state.withUnsafeBytes {
            Int32(littleEndian: $0.loadUnaligned(fromByteOffset: offset + 8, as: Int32.self))
        }
        guard version == 1 else { throw ResourceError.rejected("unsupported_calval_version") }
        return try Self(state: state, decodedOffset: offset + 16)
    }

    package static func inspectCalVal(state: Data, at offset: Int) throws -> Summary {
        try readCalVal(state: state, at: offset).summary(in: state, at: offset)
    }

    func summary(in state: Data, at offset: Int, visitIndexedGroup: ((Int, Int, Self) -> Void)? = nil) throws -> Summary {
        var integerCount = 0
        var stringCount = 0
        var objectCount = 0
        var absentCount = 0
        var buttonPayloads: [ButtonPayload] = []
        var imagePayloads: [ImagePayload] = []
        var messagePayloads: [MessagePayload] = []
        var timerPayloads: [TimerPayload] = []
        for record in records {
            switch record.values {
            case .integers: integerCount += 1
            case .strings: stringCount += 1
            case .objectText(let elements):
                objectCount += 1
                buttonPayloads += elements.compactMap(\.buttonPayload)
                imagePayloads += elements.compactMap(\.imagePayload)
                messagePayloads += elements.compactMap(\.messagePayload)
                timerPayloads += elements.compactMap(\.timerPayload)
            case .absent: absentCount += 1
            }
        }
        return Summary(decodedOffset: offset, integerArrayCount: integerCount,
                       stringArrayCount: stringCount, objectArrayCount: objectCount, absentValueCount: absentCount, buttonPayloads: buttonPayloads, imagePayloads: imagePayloads, messagePayloads: messagePayloads, timerPayloads: timerPayloads,
                       nextDecodedOffset: nextDecodedOffset,
                       indexed: try Self.inspectValIdx(state: state, at: nextDecodedOffset, visit: visitIndexedGroup))
    }

    enum Values {
        case integers([Int32])
        case strings([String])
        case objectText([ObjectElement])
        case absent
    }

    struct ObjectElement {
        let reference: String
        let payload: TextObjectPayload?
        let buttonPayload: ButtonPayload?
        let imagePayload: ImagePayload?
        var timerPayload: TimerPayload? = nil
        var messagePayload: MessagePayload? = nil
    }

    struct TimerPayload: Encodable, Sendable {
        let decodedOffset: Int
        let baseRecordWord: Int32
        let fixedRecord: SaveReaderCursor.Reference
        let interval: Int32
        let elapsed: Int32
        let enabledByte: UInt8
        let updateMask: UInt32
        let secondaryUpdateMask: UInt32
        let rawUpdateMode: Int32
        let callbackStrings: [SaveReaderCursor.Reference]
        let nextDecodedOffset: Int

        var isInactiveWithoutCallback: Bool {
            enabledByte == 0 && elapsed == 0 && interval >= 0 && rawUpdateMode == 0 &&
                updateMask == 0 && callbackStrings.allSatisfy { $0.length == 0 }
        }

        var isSupportedEnabledCallbackTimer: Bool {
            enabledByte == 1 && interval > 0 && elapsed >= 0 && elapsed < interval &&
                updateMask == 0xff && secondaryUpdateMask == 0xff && rawUpdateMode == 0 &&
                callbackStrings.count == 2 && callbackStrings[0].length > 0
        }
    }

    struct ImagePayload: Encodable, Sendable {
        let baseRecordWord: Int32
        let fixedRecord: SaveReaderCursor.Reference
        let userIntegerReferences: [SaveReaderCursor.Reference]
        let userIntegerWords: [Int32]
        let userStrings: [SaveReaderCursor.Reference]
        enum CodingKeys: String, CodingKey {
            case fixedRecord, userIntegerReferences, userStrings, layerTiming, staticPlacement, staticScale, activePlacement, alignment
            case opacityTransition, staticOpacity, textureSlots, rawActionIndex, rawActionElapsed
            case rawActionClockRemainder, rawActionSpeed, rawAnimationSpeed, layerAuxiliaryFlags
            case drawGate, enableFlag, miFlag, decodedOffset
            case byteLength, imageSource, anchorName, rawPlacementMode, rawPlacementStrength, baseRecordWord
            case generatorGroup, generatorGroupRecords
            case filterNames, nativeActionElapsed, drawSettings
        }
        struct LayerTiming: Encodable, Sendable {
            let savedTimeWords: SaveReaderCursor.Reference
            let savedAuxiliaryWords: SaveReaderCursor.Reference
            let nonzeroTimeCount: Int
            let nonzeroAuxiliaryCount: Int
            let restoreStatus: EvidenceStatus = .inferred
            // img/btn/msg native loaders share the fixed image-record reader,
            // which converts serialized integers numerically to runtime floats.
            // Staging retains renderer-facing float bit patterns; reports expose
            // only ranges, hashes and counts.
            let timeWords: [Int32]
            let auxiliaryWords: [Int32]
            enum CodingKeys: String, CodingKey {
                case savedTimeWords, savedAuxiliaryWords, nonzeroTimeCount, nonzeroAuxiliaryCount, restoreStatus
            }
        }
        // The reader restores these two 256-word ranges into per-layer
        // floating-point state. The local renderer uses them as a candidate.
        let layerTiming: LayerTiming
        let staticPlacement: SIMD3<Int32>?
        let staticScale: SIMD3<Int32>?
        let alignment: SIMD2<Int32>
        struct DrawSettings: Encodable, Sendable {
            let channel: Int32
            let inputMask: Int32
            let outputMask: Int32
            let tabOrder: Int32
            let textureFilter: Int32
        }
        let drawSettings: DrawSettings
        struct ActivePlacement: Encodable, Sendable {
            let origin: SIMD3<Int32>
            let destination: SIMD3<Int32>
            let destinationScale: SIMD3<Int32>
            let remaining: Int32
            let duration: Int32
            let mode: UInt8
        }
        let activePlacement: ActivePlacement?
        let generatorGroup: SaveReaderCursor.Reference?
        let generatorGroupRecords: [SaveImageGenerators.Record]
        let filterNames: [SaveReaderCursor.Reference]
        struct OpacityTransition: Encodable, Sendable {
            let origin: UInt8
            let target: UInt8
            let remaining: Int32
            let duration: Int32
            let repeats: Int32
        }
        let opacityTransition: OpacityTransition?
        let staticOpacity: UInt8?
        struct TextureSlot: Encodable, Sendable {
            let index: Int
            let name: SaveReaderCursor.Reference?
            let embeddedOffset: Int
            let embeddedLength: Int
        }
        let textureSlots: [TextureSlot]
        let rawActionIndex: Int32
        let rawActionElapsed: Int32
        let rawActionClockRemainder: Int32
        let rawActionSpeed: Int32
        let rawAnimationSpeed: Int32
        // For standalone video, the native writer stores animation speed at
        // +0x810, the layer remainder at +0x814 and action time at +0x898.
        // Keep the earlier report fields for slots written by research builds.
        let nativeActionElapsed: Int32
        var nativeAnimationSpeed: Int32 { rawActionClockRemainder }
        var nativeLayerRemainder: Int32 { rawAnimationSpeed }
        let layerAuxiliaryFlags: SaveReaderCursor.Reference
        let drawGate: UInt8
        let enableFlag: UInt8
        let miFlag: UInt8
        let decodedOffset: Int
        let byteLength: Int
        let imageSource: SaveReaderCursor.Reference?
        let anchorName: SaveReaderCursor.Reference?
        let rawPlacementMode: UInt8
        let rawPlacementStrength: Int32

        // In the pinned EXE, FUN_005ad744 routes a null file pointer to
        // FUN_005aae18, which clears the image resource state. A zero-length
        // filename with no serialized texture slots is therefore an empty
        // resource identity, not an unresolved external file.
        static func hasVerifiedEmptyFileResource(source: SaveReaderCursor.Reference?,
                                                 textureSlots: [TextureSlot]) -> Bool {
            source == nil && textureSlots.isEmpty
        }
    }

    struct ButtonPayload: Encodable, Sendable {
        let decodedOffset: Int
        let baseRecordWord: Int32
        let imageLibraryOffset: Int
        let imageSource: SaveReaderCursor.Reference?
        let anchorName: SaveReaderCursor.Reference?
        let fixedRecordOffset: Int
        let drawableRectangle: [Int32]
        let stringOffsets: [Int]
        let textStrings: [SaveReaderCursor.Reference]
        let rawTextCursor: Int32
        let rawTextMargins: [Int32]
        let rawKinsokuWordLength: Int32
        let returnSpacing: SIMD2<Int32>
        let rawAsEnabled: UInt8
        let rawApEnabled: UInt8
        let userStrings: [SaveReaderCursor.Reference]
        let userIntegerReferences: [SaveReaderCursor.Reference]
        let userIntegerWords: [Int32]
        let soundNames: [SaveReaderCursor.Reference]
        let textureSlots: [ImagePayload.TextureSlot]
        let rawImageDrawGate: UInt8
        let rawImageEnableFlag: UInt8
        let rawButtonState: UInt8
        let layerTiming: ImagePayload.LayerTiming
        let layerAuxiliaryFlags: SaveReaderCursor.Reference
        let rawActionIndex: Int32
        let rawActionElapsed: Int32
        let rawActionClockRemainder: Int32
        let rawActionSpeed: Int32
        let rawAnimationSpeed: Int32
        let rawSP: [Int32]
        let spReference: SaveReaderCursor.Reference
        // Version 10's 42-byte button record maps byte 8 to object +0xf08.
        let rawCheckByte: UInt8?
        let rawLockByte: UInt8?
        let staticPlacement: SIMD3<Int32>?
        let staticScale: SIMD3<Int32>?
        let buttonRecordOffset: Int
        let nextDecodedOffset: Int
        // Keep raw user values in memory; reports expose only offsets and hashes.
        enum CodingKeys: String, CodingKey {
            case decodedOffset, imageLibraryOffset, imageSource, anchorName, fixedRecordOffset, drawableRectangle
            case stringOffsets, textStrings, rawTextCursor, rawTextMargins, rawKinsokuWordLength, rawAsEnabled, rawApEnabled
            case returnSpacing
            case userStrings, userIntegerReferences, soundNames, textureSlots
            case rawImageDrawGate, rawImageEnableFlag, rawButtonState, rawCheckByte, rawLockByte
            case layerTiming, layerAuxiliaryFlags, rawActionIndex, rawActionElapsed, rawActionClockRemainder
            case rawActionSpeed, rawAnimationSpeed
            case spReference
            case staticPlacement, staticScale, buttonRecordOffset, nextDecodedOffset, baseRecordWord
        }
    }

    struct MessagePayload: Encodable, Sendable {
        let decodedOffset: Int
        let baseRecordWord: Int32
        let imageLibraryOffset: Int
        let imageSource: SaveReaderCursor.Reference?
        let anchorName: SaveReaderCursor.Reference?
        let fixedRecordOffset: Int
        let drawableRectangle: [Int32]
        let stringOffsets: [Int]
        let userStrings: [SaveReaderCursor.Reference]
        // The first two serialized strings are object +0xecc and +0xed0.
        // 0x678edd passes fixed +0x44 with the first to the text replay path.
        let textStrings: [SaveReaderCursor.Reference]
        let rawTextCursor: Int32
        let rawTextMargins: [Int32]
        let rawKinsokuWordLength: Int32
        let returnSpacing: SIMD2<Int32>
        let rawAsEnabled: UInt8
        let rawApEnabled: UInt8
        let staticPlacement: SIMD3<Int32>?
        let staticScale: SIMD3<Int32>?
        let rawActionIndex: Int32
        let rawActionElapsed: Int32
        let rawActionClockRemainder: Int32
        let rawActionSpeed: Int32
        let rawAnimationSpeed: Int32
        let nativeActionIndex: Int32
        let nativeActionElapsed: Int32
        let layerTiming: ImagePayload.LayerTiming
        let layerAuxiliaryFlags: SaveReaderCursor.Reference
        let textureSlots: [ImagePayload.TextureSlot]
        let rawImageDrawGate: UInt8
        let rawImageEnableFlag: UInt8
        let nextDecodedOffset: Int

        /// Earlier local writers use this tuple for an unselected background.
        /// The native reader can still select an action for a drawable resource.
        var isNativeResetMotionState: Bool {
            Self.isNativeResetMotionState(rawActionIndex: rawActionIndex,
                rawActionElapsed: rawActionElapsed, rawActionClockRemainder: rawActionClockRemainder,
                rawActionSpeed: rawActionSpeed, rawAnimationSpeed: rawAnimationSpeed)
        }

        static func isNativeResetMotionState(rawActionIndex: Int32, rawActionElapsed: Int32,
                                             rawActionClockRemainder: Int32, rawActionSpeed: Int32,
                                             rawAnimationSpeed: Int32) -> Bool {
            rawActionIndex == 0 && rawActionElapsed == 0 && rawActionClockRemainder == 100 &&
                rawActionSpeed == 100 && rawAnimationSpeed == 0
        }

        // FUN_005ac0b8 serializes TImageLib.FBaseFilename (+0x94) immediately
        // after the 0xa5e-byte fixed record. RTTI identifies that field, and
        // FUN_005abb34 calls FUN_005ad744 only when it is nonempty. With no
        // child texture slots, this proves an empty external file-resource
        // identity; it does not prove message pixels or callback equivalence.
        static func hasVerifiedEmptyFileResource(source: SaveReaderCursor.Reference?,
                                                 textureSlots: [ImagePayload.TextureSlot]) -> Bool {
            source == nil && textureSlots.isEmpty
        }

        /// Candidate for the primary-buffer path only. Additional native
        /// queues and the original renderer are not reconstructed here.
        func primaryText(in state: Data) throws -> (displayed: String, pending: String,
                                                      displayedOutput: [ScriptStorage.MessageObject.Output],
                                                      pendingOutput: [ScriptStorage.MessageObject.Output]) {
            guard let primary = textStrings.first, primary.length <= 16_384,
                  rawTextCursor >= 0, Int(rawTextCursor) <= primary.length / 2 else {
                throw ResourceError.rejected("saved_message_text_cursor_outside_profile")
            }
            let text = try primary.utf16Text(in: state)
            guard !text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
                throw ResourceError.rejected("saved_message_text_control_outside_profile")
            }
            let start = state.startIndex + primary.decodedOffset
            let split = start + Int(rawTextCursor) * 2
            let end = start + primary.length
            guard let displayed = String(data: Data(state[start..<split]), encoding: .utf16LittleEndian),
                  let pending = String(data: Data(state[split..<end]), encoding: .utf16LittleEndian) else {
                throw ResourceError.rejected("saved_message_text_cursor_not_unicode_boundary")
            }
            let displayedOutput = try ScriptStorage.MessageObject.parseOutput(displayed)
            let pendingOutput = try ScriptStorage.MessageObject.parseOutput(pending)
            guard displayedOutput.count + pendingOutput.count <= 128 else {
                throw ResourceError.rejected("saved_message_text_operation_limit")
            }
            return (displayed, pending, displayedOutput, pendingOutput)
        }
    }

    struct TextObjectPayload {
        let decodedOffset: Int
        let baseField: Int32
        let declaredLineCount: Int
        let lines: [String]
    }

    struct Record {
        let decodedOffset: Int
        let valueOffset: Int?
        let nextDecodedOffset: Int
        let header: Data
        let textFields: [String]
        let values: Values
    }

    let records: [Record]
    let nextDecodedOffset: Int

    /// Replace only a message's primary buffer and its UTF-16 cursor. This is
    /// a bounded building block; it does not serialize the other message state.
    static func replacingMessagePrimaryCandidate(in state: Data, decodedOffset: Int,
                                                 recordIndex: Int, elementIndex: Int,
                                                 displayed: String, pending: String) throws -> Data {
        let original = try Self(state: state, decodedOffset: decodedOffset)
        guard original.records.indices.contains(recordIndex),
              asciiLower(original.records[recordIndex].textFields[1]) == "msg",
              case .objectText(let elements) = original.records[recordIndex].values,
              elements.indices.contains(elementIndex), let payload = elements[elementIndex].messagePayload,
              let primary = payload.textStrings.first, payload.stringOffsets.first == primary.decodedOffset - 2,
              primary.decodedOffset >= 2, primary.length >= 0,
              primary.decodedOffset <= state.count, primary.length <= state.count - primary.decodedOffset,
              payload.fixedRecordOffset >= 0, payload.fixedRecordOffset + 0x48 <= primary.decodedOffset - 2 else {
            throw ResourceError.rejected("saved_message_write_template_outside_profile")
        }
        let raw = Data(state[(state.startIndex + primary.decodedOffset)..<(state.startIndex + primary.decodedOffset + primary.length)])
        guard raw.sha256Hex == primary.sha256 else { throw ResourceError.rejected("saved_message_write_template_identity") }
        let text = displayed + pending
        guard text.utf8.count <= 8192, !text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }),
              let count = Int16(exactly: text.utf16.count),
              let cursor = Int32(exactly: displayed.utf16.count),
              let bytes = text.data(using: .utf16LittleEndian) else {
            throw ResourceError.rejected("saved_message_write_text_outside_profile")
        }
        let displayedOutput = try ScriptStorage.MessageObject.parseOutput(displayed)
        let pendingOutput = try ScriptStorage.MessageObject.parseOutput(pending)
        guard displayedOutput.count + pendingOutput.count <= 128,
              state.count - primary.length + bytes.count <= SaveEnvelope.maxFileBytes else {
            throw ResourceError.rejected("saved_message_write_limit")
        }
        var replacement = Data()
        withUnsafeBytes(of: count.littleEndian) { replacement.append(contentsOf: $0) }
        replacement.append(bytes)
        var result = state
        withUnsafeBytes(of: cursor.littleEndian) {
            result.replaceSubrange((result.startIndex + payload.fixedRecordOffset + 0x44)..<(result.startIndex + payload.fixedRecordOffset + 0x48), with: $0)
        }
        result.replaceSubrange((result.startIndex + primary.decodedOffset - 2)..<(result.startIndex + primary.decodedOffset + primary.length), with: replacement)
        let checked = try Self(state: result, decodedOffset: decodedOffset)
        guard checked.records.indices.contains(recordIndex),
              case .objectText(let checkedElements) = checked.records[recordIndex].values,
              checkedElements.indices.contains(elementIndex), let written = checkedElements[elementIndex].messagePayload else {
            throw ResourceError.rejected("saved_message_write_roundtrip_shape")
        }
        let parsed = try written.primaryText(in: result)
        guard parsed.displayed == displayed, parsed.pending == pending,
              checked.nextDecodedOffset == original.nextDecodedOffset + bytes.count - primary.length else {
            throw ResourceError.rejected("saved_message_write_roundtrip_mismatch")
        }
        return result
    }

    static func replacingMessagePrimaryCandidate(in state: Data, decodedOffset: Int,
                                                 recordIndex: Int, elementIndex: Int,
                                                 message: ScriptStorage.MessageObject) throws -> Data {
        guard let text = message.primaryTextWriteCandidate() else {
            throw ResourceError.rejected("saved_message_write_source_unavailable")
        }
        return try replacingMessagePrimaryCandidate(in: state, decodedOffset: decodedOffset,
            recordIndex: recordIndex, elementIndex: elementIndex, displayed: text.displayed, pending: text.pending)
    }

    /// Replace the audited message layout fields in an
    /// existing template. The rest of the message object remains unverified.
    static func replacingMessageLayoutCandidate(in state: Data, decodedOffset: Int,
                                                recordIndex: Int, elementIndex: Int,
                                                message: ScriptStorage.MessageObject) throws -> Data {
        let original = try Self(state: state, decodedOffset: decodedOffset)
        guard original.records.indices.contains(recordIndex),
              asciiLower(original.records[recordIndex].textFields[1]) == "msg",
              case .objectText(let elements) = original.records[recordIndex].values,
              elements.indices.contains(elementIndex), let payload = elements[elementIndex].messagePayload,
              payload.textStrings.count == 5, payload.stringOffsets.count == 5,
              payload.fixedRecordOffset >= 0, payload.fixedRecordOffset <= state.count - 189,
              let reserve = message.kinsokuWordLength else {
            throw ResourceError.rejected("saved_message_layout_write_template_outside_profile")
        }
        if let bounds = message.textBounds {
            guard bounds.count == 4, bounds[2] >= bounds[0], bounds[3] >= bounds[1],
                  Int64(bounds[2]) - Int64(bounds[0]) <= 4096,
                  Int64(bounds[3]) - Int64(bounds[1]) <= 4096 else {
                throw ResourceError.rejected("saved_message_layout_write_bounds_outside_profile")
            }
        }
        if let margins = message.textMargins, margins.count != 2 {
            throw ResourceError.rejected("saved_message_layout_write_margins_outside_profile")
        }
        let values = [message.prohibitedLineStart, message.prohibitedLineEnd, message.ignoredReturnWords]
        var replacements: [(range: Range<Int>, bytes: Data)] = []
        for (index, value) in values.enumerated() {
            let reference = payload.textStrings[index + 2]
            guard reference.decodedOffset >= 2, reference.length >= 0,
                  reference.decodedOffset <= state.count, reference.length <= state.count - reference.decodedOffset,
                  payload.stringOffsets[index + 2] == reference.decodedOffset - 2,
                  value.utf8.count <= 8192, let length = Int16(exactly: value.utf16.count),
                  let encoded = value.data(using: .utf16LittleEndian),
                  Data(state[(state.startIndex + reference.decodedOffset)..<(state.startIndex + reference.decodedOffset + reference.length)]).sha256Hex == reference.sha256 else {
                throw ResourceError.rejected("saved_message_layout_write_string_outside_profile")
            }
            var bytes = Data()
            withUnsafeBytes(of: length.littleEndian) { bytes.append(contentsOf: $0) }
            bytes.append(encoded)
            replacements.append(((reference.decodedOffset - 2)..<(reference.decodedOffset + reference.length), bytes))
        }
        let delta = replacements.reduce(0) { $0 + $1.bytes.count - $1.range.count }
        guard delta <= SaveEnvelope.maxFileBytes - state.count else {
            throw ResourceError.rejected("saved_message_layout_write_limit")
        }
        var result = state
        func store(_ value: Int32, at offset: Int) {
            withUnsafeBytes(of: value.littleEndian) {
                result.replaceSubrange((result.startIndex + payload.fixedRecordOffset + offset)..<(result.startIndex + payload.fixedRecordOffset + offset + 4), with: $0)
            }
        }
        if let bounds = message.textBounds {
            for (index, value) in bounds.enumerated() { store(value, at: 0x0c + index * 4) }
        }
        if let margins = message.textMargins {
            for (index, value) in margins.enumerated() { store(value, at: 0x90 + index * 4) }
        }
        store(reserve, at: 0x8c)
        result[result.startIndex + payload.fixedRecordOffset + 0x9a] = message.asEnabled ? 1 : 0
        result[result.startIndex + payload.fixedRecordOffset + 0x9b] = message.apEnabled ? 1 : 0
        for replacement in replacements.reversed() {
            result.replaceSubrange((result.startIndex + replacement.range.lowerBound)..<(result.startIndex + replacement.range.upperBound), with: replacement.bytes)
        }
        let checked = try Self(state: result, decodedOffset: decodedOffset)
        guard checked.records.indices.contains(recordIndex),
              case .objectText(let checkedElements) = checked.records[recordIndex].values,
              checkedElements.indices.contains(elementIndex), let written = checkedElements[elementIndex].messagePayload,
              written.textStrings.count == 5, written.rawKinsokuWordLength == reserve,
              written.rawAsEnabled == (message.asEnabled ? 1 : 0), written.rawApEnabled == (message.apEnabled ? 1 : 0),
              (message.textBounds == nil || written.drawableRectangle == message.textBounds),
              (message.textMargins == nil || written.rawTextMargins == message.textMargins),
              checked.nextDecodedOffset == original.nextDecodedOffset + delta else {
            throw ResourceError.rejected("saved_message_layout_write_roundtrip_shape")
        }
        for (reference, value) in zip(written.textStrings[2...4], values) {
            guard try reference.utf16Text(in: result).utf16.elementsEqual(value.utf16) else {
                throw ResourceError.rejected("saved_message_layout_write_roundtrip_mismatch")
            }
        }
        return result
    }

    /// Update only the first four user integers in an existing image template.
    /// All other image state remains opaque and must not be treated as current.
    static func replacingImageUserIntegersCandidate(in state: Data, decodedOffset: Int,
                                                    recordIndex: Int, elementIndex: Int,
                                                    values: [Int32]) throws -> Data {
        let original = try Self(state: state, decodedOffset: decodedOffset)
        guard values.count == 4, original.records.indices.contains(recordIndex),
              ["img", "simg"].contains(asciiLower(original.records[recordIndex].textFields[1])),
              case .objectText(let elements) = original.records[recordIndex].values,
              elements.indices.contains(elementIndex), let payload = elements[elementIndex].imagePayload,
              payload.userIntegerReferences.count == 8, payload.userIntegerWords.count == 8 else {
            throw ResourceError.rejected("saved_image_user_integer_write_outside_profile")
        }
        var result = state
        for (reference, value) in zip(payload.userIntegerReferences.prefix(4), values) {
            let start = reference.decodedOffset
            guard start >= 0, reference.length == 4, start <= state.count - 4,
                  Data(state[(state.startIndex + start)..<(state.startIndex + start + 4)]).sha256Hex == reference.sha256 else {
                throw ResourceError.rejected("saved_image_user_integer_template_identity")
            }
            withUnsafeBytes(of: value.littleEndian) {
                result.replaceSubrange((result.startIndex + start)..<(result.startIndex + start + 4), with: $0)
            }
        }
        let checked = try Self(state: result, decodedOffset: decodedOffset)
        guard checked.records.indices.contains(recordIndex),
              case .objectText(let writtenElements) = checked.records[recordIndex].values,
              writtenElements.indices.contains(elementIndex), let written = writtenElements[elementIndex].imagePayload,
              Array(written.userIntegerWords.prefix(4)) == values,
              written.userIntegerWords.dropFirst(4).elementsEqual(payload.userIntegerWords.dropFirst(4)),
              checked.nextDecodedOffset == original.nextDecodedOffset else {
            throw ResourceError.rejected("saved_image_user_integer_write_roundtrip_mismatch")
        }
        return result
    }

    /// Candidate for an immediate, axis-aligned image placement on an existing
    /// template. Resource identity and the rest of the object remain unverified.
    static func replacingImagePlacementCandidate(in state: Data, decodedOffset: Int,
                                                  recordIndex: Int, elementIndex: Int,
                                                  placement: SIMD3<Int32>, scale: SIMD3<Int32>) throws -> Data {
        let original = try Self(state: state, decodedOffset: decodedOffset)
        guard original.records.indices.contains(recordIndex),
              ["img", "simg"].contains(asciiLower(original.records[recordIndex].textFields[1])),
              case .objectText(let elements) = original.records[recordIndex].values,
              elements.indices.contains(elementIndex), let payload = elements[elementIndex].imagePayload,
              payload.fixedRecord.length == 0xa5e, payload.fixedRecord.decodedOffset >= 0,
              payload.fixedRecord.decodedOffset <= state.count,
              payload.fixedRecord.length <= state.count - payload.fixedRecord.decodedOffset,
              scale.z == 100,
              (0..<3).allSatisfy({ (-16_777_216...16_777_216).contains(placement[$0]) &&
                  (-16_777_216...16_777_216).contains(scale[$0]) }) else {
            throw ResourceError.rejected("saved_image_placement_write_outside_profile")
        }
        let start = payload.fixedRecord.decodedOffset
        let fixed = Data(state[(state.startIndex + start)..<(state.startIndex + start + payload.fixedRecord.length)])
        guard fixed.sha256Hex == payload.fixedRecord.sha256 else {
            throw ResourceError.rejected("saved_image_placement_template_identity")
        }
        var result = state
        func store(_ value: Int32, at offsets: [Int]) {
            for offset in offsets {
                withUnsafeBytes(of: value.littleEndian) {
                    result.replaceSubrange((result.startIndex + start + offset)..<(result.startIndex + start + offset + 4), with: $0)
                }
            }
        }
        // Immediate path 0x5ac85c–0x5ac9aa copies each target into both
        // current and origin fields. Four rotation/depth-angle values are zero.
        for (value, offsets) in [
            (placement.x, [0x8fd, 0x909, 0x915]), (placement.y, [0x901, 0x90d, 0x919]),
            (placement.z, [0x905, 0x911, 0x91d]),
            (Int32(0), [0x921, 0x925, 0x929, 0x92d, 0x931, 0x935, 0x939, 0x93d, 0x941, 0x945, 0x949, 0x94d]),
            (scale.x, [0x951, 0x955, 0x959]), (scale.y, [0x95d, 0x961, 0x965]),
            (scale.z, [0x969, 0x96d, 0x971]), (Int32(0), [0x9e9, 0x9ed, 0xa3e])
        ] { store(value, at: offsets) }
        let checked = try Self(state: result, decodedOffset: decodedOffset)
        guard checked.records.indices.contains(recordIndex),
              case .objectText(let checkedElements) = checked.records[recordIndex].values,
              checkedElements.indices.contains(elementIndex), let written = checkedElements[elementIndex].imagePayload,
              written.staticPlacement == placement, written.staticScale == scale,
              written.drawGate == payload.drawGate, written.enableFlag == payload.enableFlag,
              checked.nextDecodedOffset == original.nextDecodedOffset else {
            throw ResourceError.rejected("saved_image_placement_write_roundtrip_mismatch")
        }
        return result
    }

    /// Rebuild a standalone CalVal section with live scalars and inline text objects.
    /// Keep opaque fields from the supplied template. Refuse unsupported live objects.
    package static let visualPayloadTypes: Set<String> = ["img", "simg", "btn", "sbtn", "msg"]

    static func generatedBindingType(_ key: Data, in storage: ScriptStorage,
                                    objectPayloads: [UInt64: Data] = [:]) -> (kind: UInt8, objectType: String)? {
        guard let elements = storage.global[key]?.elements, !elements.isEmpty else { return nil }
        if elements.allSatisfy({ $0.integer != nil }) { return (0, "") }
        if elements.allSatisfy({ $0.typeName == "string" }) { return (1, "") }
        if storage.globalObjectAliases.contains(key) {
            return storage.savedObjectAliasTexts(key) == nil ? nil : (2, "obj")
        }
        let handles = elements.compactMap { value -> UInt64? in
            guard case .object(let handle) = value else { return nil }
            return handle
        }
        guard handles.count == elements.count else { return nil }
        if handles.allSatisfy({ storage.lists[$0] != nil }) { return (2, "list") }
        if handles.allSatisfy({ storage.tables[$0] != nil }) { return (2, "table") }
        if handles.count == 1, let handle = handles.first,
           storage.timers[handle]?.hasSupportedActiveSaveState == true { return (2, "timer") }
        guard handles.allSatisfy({ objectPayloads[$0] != nil }) else { return nil }
        if handles.allSatisfy({ storage.messages[$0] != nil }) { return (2, "msg") }
        if handles.allSatisfy({ storage.buttons.contains($0) }),
           let first = storage.visualObjectTypes[handles[0]], ["btn", "sbtn"].contains(first),
           handles.allSatisfy({ storage.visualObjectTypes[$0] == first }) { return (2, first) }
        if handles.allSatisfy({ storage.images[$0] != nil }),
           let first = storage.visualObjectTypes[handles[0]], ["img", "simg"].contains(first),
           handles.allSatisfy({ storage.visualObjectTypes[$0] == first }) { return (2, first) }
        return nil
    }

    static func encodeCalValValues(template: Data, storage: ScriptStorage,
                                   newBindingKeys: Set<Data> = [],
                                   objectPayloads: [UInt64: Data] = [:]) throws -> Data {
        let arrays = try readCalVal(state: template, at: 0)
        guard arrays.nextDecodedOffset == template.count, template.count <= SaveEnvelope.maxFileBytes else {
            throw ResourceError.rejected("save_scalar_template_boundary")
        }
        var output = Data(template.prefix(20))
        func append(_ bytes: Data) throws {
            guard bytes.count <= SaveEnvelope.maxFileBytes - output.count else {
                throw ResourceError.rejected("save_scalar_encoding_limit")
            }
            output.append(bytes)
        }
        func span(_ start: Int, _ end: Int) -> Data {
            Data(template[(template.startIndex + start)..<(template.startIndex + end)])
        }
        func appendText(_ string: String) throws {
            guard let count = Int16(exactly: string.utf16.count),
                  let bytes = string.data(using: .utf16LittleEndian) else {
                throw ResourceError.rejected("save_scalar_replacement_length")
            }
            try append(withUnsafeBytes(of: count.littleEndian) { Data($0) })
            try append(bytes)
        }
        var names: Set<Data> = []
        func appendVisualPayload(_ payload: Data) throws {
            guard payload.count >= 12, payload.prefix(4).elementsEqual("objd".utf8),
                  payload.withUnsafeBytes({ Int32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: Int32.self)) }) == 1,
                  payload.count <= SaveEnvelope.maxFileBytes - output.count else {
                throw ResourceError.rejected("save_visual_object_payload_header_or_limit")
            }
            try appendText("")
            try append(payload)
        }
        func newActiveTimerPayload(_ handle: UInt64) throws -> Data {
            guard let timer = storage.timers[handle], timer.hasSupportedActiveSaveState,
                  storage.savedObjectBaseWords[handle] == 0,
                  let callback = timer.callback else {
                throw ResourceError.rejected("save_new_active_timer_state_outside_profile")
            }
            var payload = Data("objd".utf8)
            func word(_ value: Int32) {
                withUnsafeBytes(of: value.littleEndian) { payload.append(contentsOf: $0) }
            }
            word(1)
            // TImoDataTimer's constructor sets its +0x14 serialized base word to zero.
            word(0)
            var fixed = Data(repeating: 0, count: 89)
            func store(_ value: Int32, at offset: Int) {
                withUnsafeBytes(of: value.littleEndian) {
                    fixed.replaceSubrange(offset..<(offset + 4), with: $0)
                }
            }
            store(10, at: 0)
            store(timer.interval, at: 4)
            store(timer.elapsed, at: 8)
            fixed[12] = 1
            store(0xff, at: 13)
            store(0xff, at: 17)
            store(0, at: 21)
            payload.append(fixed)
            func text(_ value: String) throws {
                guard value.utf8.count <= 8192, let count = Int16(exactly: value.utf16.count),
                      let bytes = value.data(using: .utf16LittleEndian) else {
                    throw ResourceError.rejected("save_new_active_timer_string_limit")
                }
                withUnsafeBytes(of: count.littleEndian) { payload.append(contentsOf: $0) }
                payload.append(bytes)
            }
            try text(callback.label)
            try text(timer.argument)
            return payload
        }
        var removedBindingCount = 0
        for record in arrays.records {
            let deletedKey = Data(asciiLower(record.textFields[0]).utf8)
            if storage.global[deletedKey] == nil, storage.deletedGlobalBindings.contains(deletedKey) {
                let supported: Bool
                switch record.values {
                case .integers, .strings: supported = true
                case .objectText(let elements):
                    let objectType = asciiLower(record.textFields[1])
                    supported = !elements.isEmpty && elements.allSatisfy {
                        (objectType == "timer" && $0.timerPayload != nil) ||
                        ((objectType == "list" || objectType == "table") && $0.reference.isEmpty && $0.payload != nil)
                    }
                default: supported = false
                }
                let flags = record.header.withUnsafeBytes {
                    UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
                }
                let unique = names.insert(deletedKey).inserted
                guard supported, flags & 4 != 0, unique else {
                    throw ResourceError.rejected("save_deleted_binding_outside_profile:key_sha256=\(deletedKey.sha256Hex):supported=\(supported ? 1 : 0):deletable=\(flags & 4 != 0 ? 1 : 0):unique=\(unique ? 1 : 0)")
                }
                removedBindingCount += 1
                continue
            }
            let objectType = asciiLower(record.textFields[1])
            if objectType == "obj", record.header[record.header.startIndex + 13] == 1,
               case .objectText(let elements) = record.values, !elements.isEmpty {
                let key = Data(asciiLower(record.textFields[0]).utf8)
                guard names.insert(key).inserted, let valueOffset = record.valueOffset,
                      let references = storage.savedObjectAliasTexts(key), references.count == elements.count else {
                    throw ResourceError.rejected("save_sound_alias_reference_outside_profile")
                }
                try append(span(record.decodedOffset, valueOffset))
                for reference in references { try appendText(reference) }
                continue
            }
            if Self.visualPayloadTypes.contains(objectType), case .objectText(let elements) = record.values,
               record.header[record.header.startIndex + 13] == 0,
               !elements.isEmpty, elements.allSatisfy({ $0.reference.isEmpty }) {
                let key = Data(asciiLower(record.textFields[0]).utf8)
                guard names.insert(key).inserted else {
                    throw ResourceError.rejected("save_global_visual_object_duplicate_name")
                }
                guard let binding = storage.global[key] else {
                    throw ResourceError.rejected("save_global_visual_object_binding_missing:elements=\(elements.count)")
                }
                guard binding.elements.count == elements.count else {
                    throw ResourceError.rejected("save_global_visual_object_count_mismatch:template=\(elements.count):live=\(binding.elements.count)")
                }
                guard let valueOffset = record.valueOffset else {
                    throw ResourceError.rejected("save_global_visual_object_value_offset_missing")
                }
                let handles = binding.elements.compactMap { value -> UInt64? in
                    guard case .object(let handle) = value else { return nil }; return handle
                }
                guard handles.count == elements.count else {
                    throw ResourceError.rejected("save_global_visual_object_non_object_binding")
                }
                guard handles.allSatisfy({ handle in
                          if objectType == "msg" { return storage.messages[handle] != nil }
                          if objectType == "btn" || objectType == "sbtn" {
                              return storage.buttons.contains(handle) && storage.visualObjectTypes[handle] == objectType
                          }
                          return storage.images[handle] != nil && storage.visualObjectTypes[handle] == objectType
                      }) else {
                    throw ResourceError.rejected("save_global_visual_object_type_mismatch:template=\(objectType)")
                }
                guard handles.allSatisfy({ objectPayloads[$0] != nil }) else {
                    throw ResourceError.rejected("save_global_visual_object_payload_missing")
                }
                try append(span(record.decodedOffset, valueOffset))
                for handle in handles { try appendVisualPayload(objectPayloads[handle]!) }
                continue
            }
            if objectType == "timer", case .objectText(let elements) = record.values,
               elements.count == 1, let element = elements.first, element.reference.isEmpty,
               let payload = element.timerPayload, payload.isInactiveWithoutCallback {
                let key = Data(asciiLower(record.textFields[0]).utf8)
                guard names.insert(key).inserted, let binding = storage.global[key],
                      binding.elements.count == 1, case .object(let handle) = binding.first,
                      let timer = storage.timers[handle], !timer.enabled, timer.elapsed == 0,
                      timer.interval >= 0, timer.callback == nil, timer.argument.isEmpty else {
                    throw ResourceError.rejected("save_global_timer_write_outside_profile")
                }
                let intervalOffset = payload.fixedRecord.decodedOffset + 4
                try append(span(record.decodedOffset, intervalOffset))
                try append(withUnsafeBytes(of: timer.interval.littleEndian) { Data($0) })
                try append(span(intervalOffset + 4, record.nextDecodedOffset))
                continue
            }
            if objectType == "timer", case .objectText(let elements) = record.values,
               elements.count == 1, let element = elements.first, element.reference.isEmpty,
               let payload = element.timerPayload, payload.isSupportedEnabledCallbackTimer {
                let key = Data(asciiLower(record.textFields[0]).utf8)
                guard names.insert(key).inserted, let binding = storage.global[key],
                      binding.elements.count == 1, case .object(let handle) = binding.first,
                      let timer = storage.timers[handle] else {
                    throw ResourceError.rejected("save_global_active_timer_binding_identity")
                }
                guard timer.enabled, timer.interval > 0, timer.elapsed >= 0, timer.elapsed < timer.interval,
                      timer.argument.utf8.count <= 8192 else {
                    throw ResourceError.rejected("save_global_active_timer_runtime_state")
                }
                guard let callback = timer.callback, callback.label.hasPrefix("@@"),
                      callback.program.document.records.indices.contains(callback.index),
                      callback.program.ancestors[callback.index].isEmpty,
                      (try? callback.program.label(callback.label)) == callback.index else {
                    throw ResourceError.rejected("save_global_active_timer_callback_identity")
                }
                guard payload.fixedRecord.length == 89 else {
                    throw ResourceError.rejected("save_global_active_timer_fixed_record_shape")
                }
                let fixedOffset = payload.fixedRecord.decodedOffset
                let fixedEnd = fixedOffset + payload.fixedRecord.length
                guard fixedOffset >= payload.decodedOffset, fixedEnd <= payload.nextDecodedOffset,
                      payload.callbackStrings.count == 2,
                      payload.callbackStrings[0].decodedOffset == fixedEnd + 2,
                      payload.callbackStrings[1].decodedOffset > payload.callbackStrings[0].decodedOffset,
                      payload.callbackStrings[1].decodedOffset + payload.callbackStrings[1].length == payload.nextDecodedOffset else {
                    throw ResourceError.rejected("save_global_active_timer_payload_boundary")
                }
                let objectPrefix = span(record.decodedOffset, fixedOffset)
                try append(objectPrefix)
                var fixed = span(fixedOffset, fixedEnd)
                func storeTimerWord(_ value: Int32, at offset: Int) {
                    withUnsafeBytes(of: value.littleEndian) {
                        fixed.replaceSubrange((fixed.startIndex + offset)..<(fixed.startIndex + offset + 4), with: $0)
                    }
                }
                storeTimerWord(timer.interval, at: 4)
                storeTimerWord(timer.elapsed, at: 8)
                fixed[fixed.startIndex + 12] = 1
                try append(fixed)
                try appendText(callback.label)
                try appendText(timer.argument)
                continue
            }
            if case .objectText(let elements) = record.values, !elements.isEmpty,
               objectType == "list" || objectType == "table",
               elements.allSatisfy({ $0.reference.isEmpty && ($0.payload?.declaredLineCount ?? -1) >= 0 }) {
                let key = Data(asciiLower(record.textFields[0]).utf8)
                guard names.insert(key).inserted, let binding = storage.global[key],
                      binding.elements.count == elements.count, let valueOffset = record.valueOffset else {
                    throw ResourceError.rejected("save_global_text_object_binding_identity")
                }
                var offset = valueOffset
                for (value, element) in zip(binding.elements, elements) {
                    guard case .object(let handle) = value, let payload = element.payload else {
                        throw ResourceError.rejected("save_global_text_object_binding_identity")
                    }
                    let lines = objectType == "list" ? storage.lists[handle]?.rawLines
                        : try storage.tables[handle]?.savedTextLines()
                    guard let lines else {
                        throw ResourceError.rejected("save_global_text_object_binding_identity")
                    }
                    try append(span(offset == valueOffset ? record.decodedOffset : offset, payload.decodedOffset + 12))
                    try append(withUnsafeBytes(of: Int32(lines.count).littleEndian) { Data($0) })
                    for line in lines { try appendText(line) }
                    offset = payload.decodedOffset + 16 + payload.lines.reduce(0) { $0 + 2 + $1.utf16.count * 2 }
                }
                guard offset == record.nextDecodedOffset else {
                    throw ResourceError.rejected("save_scalar_encoding_boundary")
                }
                continue
            }
            let isInteger: Bool
            let oldCount: Int
            switch record.values {
            case .integers(let values): isInteger = true; oldCount = values.count
            case .strings(let values): isInteger = false; oldCount = values.count
            case .objectText:
                throw ResourceError.rejected("save_global_object_write_outside_profile")
            case .absent:
                let key = Data(asciiLower(record.textFields[0]).utf8)
                guard names.insert(key).inserted, storage.global[key] == nil else {
                    throw ResourceError.rejected("save_scalar_replacement_identity:absent:key_sha256=\(key.sha256Hex):live=\(storage.global[key] == nil ? 0 : 1)")
                }
                try append(span(record.decodedOffset, record.nextDecodedOffset))
                continue
            }
            let key = Data(asciiLower(record.textFields[0]).utf8)
            guard names.insert(key).inserted, let valueOffset = record.valueOffset,
                  let binding = storage.global[key], binding.elements.count <= 1_000_000 else {
                throw ResourceError.rejected("save_scalar_replacement_identity:value:key_sha256=\(key.sha256Hex):live=\(storage.global[key] == nil ? 0 : 1):offset=\(record.valueOffset == nil ? 0 : 1)")
            }
            let newCount = Int32(binding.elements.count)
            if binding.elements.count == oldCount {
                try append(span(record.decodedOffset, valueOffset - 4))
            } else {
                let shapeOffset = valueOffset - 20
                let shape = span(shapeOffset, valueOffset - 4).withUnsafeBytes { bytes in
                    (0..<4).map { Int32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 4, as: Int32.self)) }
                }
                guard shape == [Int32(oldCount), 1, 1, 1] else {
                    throw ResourceError.rejected("save_scalar_resize_requires_linear_shape")
                }
                try append(span(record.decodedOffset, shapeOffset))
                try append(withUnsafeBytes(of: newCount.littleEndian) { Data($0) })
                try append(span(shapeOffset + 4, valueOffset - 4))
            }
            try append(withUnsafeBytes(of: newCount.littleEndian) { Data($0) })
            for value in binding.elements {
                switch value {
                case .integer(let number) where isInteger:
                    try append(withUnsafeBytes(of: number.littleEndian) { Data($0) })
                case .string(let string) where !isInteger:
                    try appendText(string)
                default: throw ResourceError.rejected("save_scalar_replacement_type_or_count")
                }
            }
        }
        guard arrays.records.count + newBindingKeys.count <= 65_536 else {
            throw ResourceError.rejected("save_scalar_record_count_limit")
        }
        for key in newBindingKeys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            guard !names.contains(key), let binding = storage.global[key], !binding.elements.isEmpty,
                  binding.elements.count <= 4096,
                  let name = String(data: key, encoding: .utf8),
                  name.range(of: #"^#?[a-z_][a-z_0-9]*$"#, options: .regularExpression) != nil else {
                throw ResourceError.rejected("save_new_scalar_declaration_outside_profile")
            }
            guard let (kind, objectType) = generatedBindingType(key, in: storage, objectPayloads: objectPayloads) else {
                throw ResourceError.rejected("save_new_binding_type_outside_profile")
            }
            func appendWord(_ word: UInt32) throws {
                try append(withUnsafeBytes(of: word.littleEndian) { Data($0) })
            }
            let hash = name.utf16.enumerated().reduce(UInt32(0)) { hash, item in
                (hash &+ (UInt32(item.element) << ((item.offset + 1) & 7))) & 0x3fff_ffff
            }
            try appendWord(0)
            try appendWord(0xff)
            try appendWord(hash)
            try append(Data([kind, objectType == "obj" ? 1 : 0]))
            try appendWord(0)
            try appendText(name)
            try appendText(objectType)
            let count = UInt32(binding.elements.count)
            for word in [count, 1, 1, 1, count] { try appendWord(word) }
            if objectType == "obj" {
                guard let references = storage.savedObjectAliasTexts(key), references.count == binding.elements.count else {
                    throw ResourceError.rejected("save_sound_alias_reference_outside_profile")
                }
                for reference in references { try appendText(reference) }
                continue
            }
            if objectType == "timer" {
                guard kind == 2, binding.elements.count == 1,
                      case .object(let handle) = binding.first else {
                    throw ResourceError.rejected("save_new_active_timer_binding_shape")
                }
                try appendVisualPayload(newActiveTimerPayload(handle))
                continue
            }
            if Self.visualPayloadTypes.contains(objectType) {
                let handles = binding.elements.compactMap { value -> UInt64? in
                    guard case .object(let handle) = value else { return nil }; return handle
                }
                guard handles.count == binding.elements.count,
                      handles.allSatisfy({ objectPayloads[$0] != nil }) else {
                    throw ResourceError.rejected("save_new_visual_object_payload_missing")
                }
                for handle in handles { try appendVisualPayload(objectPayloads[handle]!) }
                continue
            }
            for element in binding.elements {
                switch element {
                case .integer(let value): try appendWord(UInt32(bitPattern: value))
                case .string(let value): try appendText(value)
                case .object(let handle):
                    let lines = objectType == "list" ? storage.lists[handle]?.rawLines
                        : try storage.tables[handle]?.savedTextLines()
                    guard let lines, lines.count <= 65_535 else {
                        throw ResourceError.rejected("save_new_text_object_outside_profile")
                    }
                    try appendText("")
                    try append(Data("objd".utf8))
                    try appendWord(1)
                    try appendWord(0)
                    try appendWord(UInt32(lines.count))
                    for line in lines { try appendText(line) }
                }
            }
        }
        if !newBindingKeys.isEmpty || removedBindingCount != 0 {
            let count = UInt32(arrays.records.count + newBindingKeys.count - removedBindingCount)
            withUnsafeBytes(of: count.littleEndian) { output.replaceSubrange(16..<20, with: $0) }
        }
        let decoded = try readCalVal(state: output, at: 0)
        guard decoded.nextDecodedOffset == output.count else {
            throw ResourceError.rejected("save_scalar_encoding_boundary")
        }
        for key in newBindingKeys {
            guard let (kind, objectType) = generatedBindingType(key, in: storage, objectPayloads: objectPayloads),
                  kind == 2 else { continue }
            let name = String(decoding: key, as: UTF8.self)
            guard let record = decoded.records.first(where: { asciiLower($0.textFields[0]) == name }),
                  asciiLower(record.textFields[1]) == objectType,
                  case .objectText(let elements) = record.values,
                  elements.count == (storage.global[key]?.elements.count ?? -1) else {
                throw ResourceError.rejected("save_new_object_roundtrip_shape")
            }
            if objectType == "timer" {
                guard elements.count == 1, let element = elements.first, element.reference.isEmpty,
                      let timer = element.timerPayload, timer.isSupportedEnabledCallbackTimer,
                      timer.baseRecordWord == 0, let live = storage.global[key]?.first,
                      case .object(let handle) = live, let timerState = storage.timers[handle],
                      let callback = timerState.callback,
                      try timer.callbackStrings[0].utf16Text(in: output) == callback.label,
                      try timer.callbackStrings[1].utf16Text(in: output) == timerState.argument else {
                    throw ResourceError.rejected("save_new_active_timer_roundtrip_mismatch")
                }
            } else if Self.visualPayloadTypes.contains(objectType) {
                guard elements.allSatisfy({ element in
                    guard element.reference.isEmpty else { return false }
                    switch objectType {
                    case "msg": return element.messagePayload != nil
                    case "btn", "sbtn": return element.buttonPayload != nil
                    default: return element.imagePayload != nil
                    }
                }) else {
                    throw ResourceError.rejected("save_new_visual_object_roundtrip_mismatch")
                }
            }
        }
        return output
    }

    /// Replace one scalar array without rewriting any unknown header fields.
    /// Require the existing byte length so later state sections stay at the same offsets.
    static func replacingCalValScalar(in state: Data, at offset: Int, name: String,
                                     with replacement: Values) throws -> Data {
        let arrays = try readCalVal(state: state, at: offset)
        let matches = arrays.records.filter { asciiLower($0.textFields[0]) == asciiLower(name) }
        guard matches.count == 1, let record = matches.first, let start = record.valueOffset else {
            throw ResourceError.rejected("save_scalar_replacement_identity")
        }
        var bytes = Data()
        switch (record.values, replacement) {
        case (.integers(let old), .integers(let values)) where old.count == values.count:
            for value in values {
                withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
            }
        case (.strings(let old), .strings(let values)) where old.count == values.count:
            for value in values {
                guard let units = Int16(exactly: value.utf16.count),
                      let text = value.data(using: .utf16LittleEndian),
                      bytes.count + 2 + text.count <= record.nextDecodedOffset - start else {
                    throw ResourceError.rejected("save_scalar_replacement_length")
                }
                withUnsafeBytes(of: units.littleEndian) { bytes.append(contentsOf: $0) }
                bytes.append(text)
            }
        default:
            throw ResourceError.rejected("save_scalar_replacement_type_or_count")
        }
        guard bytes.count == record.nextDecodedOffset - start else {
            throw ResourceError.rejected("save_scalar_replacement_length")
        }
        var result = state
        result.replaceSubrange((state.startIndex + start)..<(state.startIndex + record.nextDecodedOffset), with: bytes)
        return result
    }

    init(state: Data, decodedOffset: Int) throws {
        guard (0...state.count).contains(decodedOffset) else {
            throw ResourceError.rejected("invalid_variable_array_bounds")
        }
        var offset = decodedOffset

        func take(_ count: Int) throws -> Data.SubSequence {
            guard count >= 0, count <= state.count - offset else {
                throw ResourceError.rejected("invalid_variable_array_bounds")
            }
            let start = state.startIndex + offset
            offset += count
            return state[start..<(start + count)]
        }

        func integer() throws -> Int32 {
            try take(4).withUnsafeBytes { Int32(littleEndian: $0.loadUnaligned(as: Int32.self)) }
        }

        func string() throws -> String {
            let units = try take(2).withUnsafeBytes { Int16(littleEndian: $0.loadUnaligned(as: Int16.self)) }
            guard let text = String(data: try take(Int(units) * 2), encoding: .utf16LittleEndian) else {
                throw ResourceError.rejected("invalid_variable_array_utf16")
            }
            return text
        }

        let count = Int(try integer())
        guard (0...min(65536, (state.count - offset) / 22)).contains(count) else {
            throw ResourceError.rejected("invalid_variable_array_count")
        }
        var remainingValues = 1_000_000
        records = try (0..<count).map { _ in
            let start = offset
            let header = try take(18)
            let kind = header[header.startIndex + 12]
            guard kind <= 3 else {
                throw ResourceError.rejected("unsupported_save_variable_array_type")
            }
            let textFields = [try string(), try string()]
            // 0x69eda3 writes type 3 when the value object is null, and
            // 0x69ee41 skips the virtual payload writer for that record.
            if kind == 3 {
                return Record(decodedOffset: start, valueOffset: nil, nextDecodedOffset: offset,
                              header: Data(header), textFields: textFields, values: .absent)
            }
            _ = try take(16)
            let length = Int(try integer())
            let minimumSize = kind == 0 ? 4 : 2
            guard (0...min(remainingValues, (state.count - offset) / minimumSize)).contains(length) else {
                throw ResourceError.rejected("invalid_variable_array_length")
            }
            remainingValues -= length
            let valueOffset = offset
            let values: Values
            switch kind {
            case 0:
                values = .integers(try (0..<length).map { _ in try integer() })
            case 1:
                values = .strings(try (0..<length).map { _ in try string() })
            default:
                let hasObjectPayload = header[header.startIndex + 13] == 0
                let objectType = asciiLower(textFields[1])
                // Fixed EXE VMTs: img/simg use 0x68c250/0x68c1e0;
                // btn/sbtn use 0x68c7b4/0x68c744 for save/load.
                let isButton = objectType == "btn" || objectType == "sbtn"
                let isImage = objectType == "img" || objectType == "simg"
                let isMessage = objectType == "msg"
                guard length == 0 || !hasObjectPayload || objectType == "list" || objectType == "table" || isButton || isImage || isMessage || objectType == "timer" else {
                    throw ResourceError.rejected("object_callback_payload_unparsed")
                }
                values = .objectText(try (0..<length).map { _ in
                    let reference = try string()
                    let payload: TextObjectPayload?
                    if hasObjectPayload {
                        let objectOffset = offset
                        if objectType == "timer" {
                            // TImoObjectDataTimer.LoadFromStream (0x68f164) reads
                            // the objd wrapper, then TImoTimer.LoadFromStream (0x684948).
                            guard try take(4).elementsEqual("objd".utf8), try integer() == 1 else {
                                throw ResourceError.rejected("unsupported_saved_timer_object_header")
                            }
                            let baseRecordWord = try integer()
                            let fixedOffset = offset
                            let fixed = try take(89)
                            func timerWord(_ offset: Int) -> Int32 {
                                fixed.withUnsafeBytes { Int32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: Int32.self)) }
                            }
                            let version = timerWord(0)
                            guard version == 10 else { throw ResourceError.rejected("unsupported_saved_timer_version") }
                            let callbackStrings = try (0..<2).map { _ in
                                let start = offset + 2
                                _ = try string()
                                let base = state.startIndex
                                let payload = Data(state[(base + start)..<(base + offset)])
                                return SaveReaderCursor.Reference(decodedOffset: start, length: payload.count,
                                                                  sha256: payload.sha256Hex)
                            }
                            return ObjectElement(reference: reference, payload: nil, buttonPayload: nil, imagePayload: nil,
                                timerPayload: .init(decodedOffset: objectOffset,
                                    baseRecordWord: baseRecordWord,
                                    fixedRecord: .init(decodedOffset: fixedOffset, length: fixed.count, sha256: Data(fixed).sha256Hex),
                                    interval: timerWord(4), elapsed: timerWord(8), enabledByte: fixed[fixed.startIndex + 12],
                                    updateMask: UInt32(bitPattern: timerWord(13)),
                                    secondaryUpdateMask: UInt32(bitPattern: timerWord(17)), rawUpdateMode: timerWord(21),
                                    callbackStrings: callbackStrings, nextDecodedOffset: offset))
                        }
                        if isButton || isImage || isMessage {
                            guard try take(4).elementsEqual("objd".utf8), try integer() == 1 else {
                                throw ResourceError.rejected("unsupported_saved_visual_object_header")
                            }
                            let baseRecordWord = try integer()
                            let libraryOffset = offset
                            var imageSource: SaveReaderCursor.Reference?
                            var imageLayerAuxiliaryFlagsReference: SaveReaderCursor.Reference?
                            var imageTextureSlots: [ImagePayload.TextureSlot] = []
                            var rawActionIndex: Int32 = -1
                            var rawActionElapsed: Int32 = 0
                            var rawActionClockRemainder: Int32 = 0
                            var rawActionSpeed: Int32 = 100
                            var rawAnimationSpeed: Int32 = 100
                            var nativeActionIndex: Int32 = 0
                            var nativeActionElapsed: Int32 = 0
                            var rawButtonSP: [Int32] = [0, 0]
                            var buttonSPReference: SaveReaderCursor.Reference?
                            var rawPlacementMode: UInt8 = 0
                            var rawPlacementStrength: Int32 = 0
                            var imageFixedRecord: SaveReaderCursor.Reference?
                            var imageLayerTiming: ImagePayload.LayerTiming?
                            var imageStaticPlacement: SIMD3<Int32>?
                            var imageStaticScale: SIMD3<Int32>?
                            var imageAlignment = SIMD2<Int32>.zero
                            var imageDrawSettings: ImagePayload.DrawSettings?
                            var activePlacement: ImagePayload.ActivePlacement?
                            var imageStaticOpacity: UInt8?
                            var imageOpacityTransition: ImagePayload.OpacityTransition?
                            var imageDrawGate: UInt8 = 0
                            var imageEnableFlag: UInt8 = 0
                            var imageMIFlag: UInt8 = 0
                            var buttonUserStrings: [SaveReaderCursor.Reference] = []
                            var buttonUserIntegerReferences: [SaveReaderCursor.Reference] = []
                            var buttonUserIntegerWords: [Int32] = []
                            var buttonSoundNames: [SaveReaderCursor.Reference] = []
                            var imageGeneratorGroup: SaveReaderCursor.Reference?
                            var imageGeneratorGroupRecords: [SaveImageGenerators.Record] = []
                            var imageFilterNames: [SaveReaderCursor.Reference] = []
                            var imageAnchorName: SaveReaderCursor.Reference?
                            try state.withUnsafeBytes { bytes in
                                try SaveStatePrefix.walkImageLibrary(bytes, take: { count in
                                    let start = offset
                                    _ = try take(count)
                                    return start
                                }, integer: { Int(try integer()) }, stringRange: {
                                    let units = try take(2).withUnsafeBytes {
                                        Int16(littleEndian: $0.loadUnaligned(as: Int16.self))
                                    }
                                    let start = offset
                                    _ = try take(Int(units) * 2)
                                    return start..<offset
                                }, imageSlot: { index, name, offset, length, requested in
                                    .init(index: index, name: name.isEmpty ? nil : .init(decodedOffset: name.lowerBound,
                                        length: name.count, sha256: Data(bytes[name]).sha256Hex),
                                        embeddedOffset: offset, embeddedLength: length, embeddedSignature: nil,
                                        nativeReloadRequested: requested, nativeDecoder: nil)
                                }, visitUserInteger: { range in
                                    if isButton || isImage {
                                        buttonUserIntegerReferences.append(.init(decodedOffset: range.lowerBound,
                                            length: range.count, sha256: Data(bytes[range]).sha256Hex))
                                        buttonUserIntegerWords.append(Int32(littleEndian: bytes.loadUnaligned(fromByteOffset: range.lowerBound, as: Int32.self)))
                                    }
                                }, visitUserString: { range in
                                    if isButton || isImage || isMessage {
                                        buttonUserStrings.append(.init(decodedOffset: range.lowerBound,
                                            length: range.count, sha256: Data(bytes[range]).sha256Hex))
                                    }
                                }, visitSoundName: { range in
                                    if isButton || isMessage {
                                        buttonSoundNames.append(.init(decodedOffset: range.lowerBound,
                                            length: range.count, sha256: Data(bytes[range]).sha256Hex))
                                    }
                                }, visitFilterName: { range in
                                    if isImage {
                                        imageFilterNames.append(.init(decodedOffset: range.lowerBound, length: range.count,
                                            sha256: Data(bytes[range]).sha256Hex))
                                    }
                                }, visitLayerAuxiliaryBytes: { range in
                                    imageLayerAuxiliaryFlagsReference = .init(decodedOffset: range.lowerBound,
                                        length: range.count, sha256: Data(bytes[range]).sha256Hex)
                                }, visitGeneratorGroup: { range, records in
                                    if isImage && !range.isEmpty {
                                        imageGeneratorGroup = .init(decodedOffset: range.lowerBound, length: range.count,
                                            sha256: Data(bytes[range]).sha256Hex)
                                        imageGeneratorGroupRecords = records
                                    }
                                }, visitAnchorName: { range in
                                    if !range.isEmpty {
                                        imageAnchorName = .init(decodedOffset: range.lowerBound, length: range.count,
                                                sha256: Data(bytes[range]).sha256Hex)
                                    }
                                }, visit: { start, _, sourceRange, slots, _ in
                                    imageTextureSlots = slots.map { .init(index: $0.index, name: $0.name, embeddedOffset: $0.embeddedOffset, embeddedLength: $0.embeddedLength) }
                                    let fixed = start..<sourceRange.lowerBound - 2
                                    imageFixedRecord = .init(decodedOffset: start, length: fixed.count,
                                        sha256: Data(bytes[fixed]).sha256Hex)
                                    // 0x5ab666 checks the draw gate; 0x5ad0dc reads the separate enable flag.
                                    imageDrawGate = bytes[start + 0x9f9]
                                    imageEnableFlag = bytes[start + 0x9fa]
                                    imageMIFlag = bytes[start + 0x8b4]
                                    rawPlacementMode = bytes[start + 0x9fd]
                                    func field(_ offset: Int) -> Int32 {
                                        Int32(littleEndian: bytes.loadUnaligned(fromByteOffset: start + offset, as: Int32.self))
                                    }
                                    if isImage {
                                        imageAlignment = SIMD2(field(0x8f1), field(0x8f5))
                                        imageDrawSettings = .init(channel: field(0x8a0), inputMask: field(0x8bd),
                                            outputMask: field(0x8c1), tabOrder: field(0x8cd), textureFilter: field(0x9b9))
                                    }
                                    if isButton {
                                        rawButtonSP = [field(0x8c5), field(0x8c9)]
                                        let range = (start + 0x8c5)..<(start + 0x8cd)
                                        buttonSPReference = .init(decodedOffset: range.lowerBound, length: range.count,
                                            sha256: Data(bytes[range]).sha256Hex)
                                    }
                                    if isImage || isButton || isMessage {
                                        let timeRange = (start + 4)..<(start + 0x404)
                                        let auxiliaryRange = (start + 0x404)..<(start + 0x804)
                                        let times: [Int32] = (0..<256).map { field(4 + $0 * 4) }
                                        let auxiliaries: [Int32] = (0..<256).map { field(0x404 + $0 * 4) }
                                        let savedTimeWords = SaveReaderCursor.Reference(decodedOffset: timeRange.lowerBound,
                                            length: timeRange.count, sha256: Data(bytes[timeRange]).sha256Hex)
                                        let savedAuxiliaryWords = SaveReaderCursor.Reference(decodedOffset: auxiliaryRange.lowerBound,
                                            length: auxiliaryRange.count, sha256: Data(bytes[auxiliaryRange]).sha256Hex)
                                        let timing = ImagePayload.LayerTiming(savedTimeWords: savedTimeWords,
                                            savedAuxiliaryWords: savedAuxiliaryWords,
                                            nonzeroTimeCount: times.filter { $0 != 0 }.count,
                                            nonzeroAuxiliaryCount: auxiliaries.filter { $0 != 0 }.count,
                                            timeWords: times, auxiliaryWords: auxiliaries)
                                        imageLayerTiming = timing
                                    }
                                    rawPlacementStrength = field(0x9f1)
                                    if isImage || isButton || isMessage {
                                        // Older local slots use +0x80c. The native reader at 0x5abda9 uses +0x808.
                                        rawActionIndex = field(0x80c)
                                        nativeActionIndex = field(0x808)
                                        // Preserve research-build field names in reports.
                                        rawActionElapsed = field(0x894)
                                        rawActionClockRemainder = field(0x810)
                                        // 0x5abd99 passes +0x8ac to playback-speed setter 0x5ae668.
                                        rawActionSpeed = field(0x8ac)
                                        rawAnimationSpeed = field(0x814)
                                        // 0x5abe21–0x5abe27 restores +0x898 to the manager's action clock.
                                        nativeActionElapsed = field(0x898)
                                    }
                                    if isImage {
                                        // 0x5ab74e multiplies the stored alpha into the draw command.
                                        let remaining = field(0x9c9)
                                        let duration = field(0x9cd)
                                        let repeats = field(0xa42)
                                        if remaining == 0, duration == 0 {
                                            imageStaticOpacity = UInt8(exactly: field(0x9bd))
                                        } else if remaining == 0, duration > 0, repeats == 0 {
                                            imageStaticOpacity = UInt8(exactly: field(0x9c5))
                                        } else if duration > 0, remaining >= 0, remaining <= duration,
                                                  duration <= Int32.max / 1024,
                                                  let origin = UInt8(exactly: field(0x9c1)),
                                                  let target = UInt8(exactly: field(0x9c5)) {
                                            // 0x5ab002 uses the signed repeat count when remaining crosses zero.
                                            imageOpacityTransition = .init(origin: origin, target: target,
                                                remaining: remaining, duration: duration, repeats: repeats)
                                        }
                                    }
                                    let placementDuration = field(0x9ed)
                                    let placementRemaining = field(0x9e9)
                                    let placementRepeats = field(0xa3e)
                                    let scale = SIMD3(field(0x959), field(0x965), field(0x971))
                                    let originScale = SIMD3(field(0x955), field(0x961), field(0x96d))
                                    // 0x5ab3ee truncates remaining × 1024 / duration.
                                    // 0x5ac341 selects the destination when this quotient is zero.
                                    let endpointTail = (max(1, placementDuration) - 1) / 1024
                                    if placementDuration <= 0 || placementRemaining <= 0 ||
                                        (placementRepeats == 0 && placementRemaining <= endpointTail) {
                                        let placement = SIMD3(field(0x915), field(0x919), field(0x91d))
                                        // The original stores the evaluated values as single precision.
                                        if (0..<3).allSatisfy({ (-16_777_216...16_777_216).contains(placement[$0]) }) {
                                            imageStaticPlacement = placement
                                        }
                                        // 0x5ab495–0x5ab4fa feeds the three scale components.
                                        // Keep 3D depth and rotation outside this restore subset.
                                        if [0x929, 0x935, 0x941, 0x94d].allSatisfy({ field($0) == 0 }),
                                           scale.z == 100,
                                           (0..<2).allSatisfy({ (-16_777_216...16_777_216).contains(scale[$0]) }) {
                                            imageStaticScale = scale
                                        }
                                    } else if [UInt8(0), 1, 3].contains(bytes[start + 0x9fd]), placementRepeats == 0,
                                              placementRemaining <= min(placementDuration, Int32.max / 1024),
                                              [0x925, 0x929, 0x931, 0x935, 0x93d, 0x941, 0x949, 0x94d].allSatisfy({ field($0) == 0 }),
                                              originScale.z == 100, scale.z == 100,
                                              (0..<2).allSatisfy({ (-16_777_216...16_777_216).contains(originScale[$0]) &&
                                                  (-16_777_216...16_777_216).contains(scale[$0]) }) {
                                        let origin = SIMD3(field(0x909), field(0x90d), field(0x911))
                                        let destination = SIMD3(field(0x915), field(0x919), field(0x91d))
                                        if (0..<3).allSatisfy({ (-16_777_216...16_777_216).contains(origin[$0]) &&
                                            (-16_777_216...16_777_216).contains(destination[$0]) }) &&
                                            (bytes[start + 0x9fd] == 0 || ScriptStorage.PlacementTransition.canSample(
                                                mode: bytes[start + 0x9fd], strength: field(0x9f1))) {
                                            imageStaticScale = originScale
                                            let mode = bytes[start + 0x9fd]
                                            activePlacement = .init(origin: origin, destination: destination, destinationScale: scale,
                                                remaining: mode == 0 ? placementRemaining - endpointTail : placementRemaining,
                                                duration: mode == 0 ? placementRemaining - endpointTail : placementDuration,
                                                mode: mode)
                                        }
                                    }
                                    if !sourceRange.isEmpty {
                                        imageSource = .init(decodedOffset: sourceRange.lowerBound,
                                            length: sourceRange.count, sha256: Data(bytes[sourceRange]).sha256Hex)
                                    }
                                })
                            }
                            if isImage {
                                guard let imageFixedRecord, let imageLayerTiming,
                                      let imageLayerAuxiliaryFlagsReference, let imageDrawSettings else {
                                    throw ResourceError.rejected("missing_saved_image_fixed_record")
                                }
                                return ObjectElement(reference: reference, payload: nil, buttonPayload: nil,
                                    imagePayload: .init(baseRecordWord: baseRecordWord, fixedRecord: imageFixedRecord, userIntegerReferences: buttonUserIntegerReferences, userIntegerWords: buttonUserIntegerWords, userStrings: buttonUserStrings, layerTiming: imageLayerTiming, staticPlacement: imageStaticPlacement, staticScale: imageStaticScale, alignment: imageAlignment, drawSettings: imageDrawSettings, activePlacement: activePlacement, generatorGroup: imageGeneratorGroup, generatorGroupRecords: imageGeneratorGroupRecords, filterNames: imageFilterNames, opacityTransition: imageOpacityTransition, staticOpacity: imageStaticOpacity, textureSlots: imageTextureSlots, rawActionIndex: rawActionIndex, rawActionElapsed: rawActionElapsed, rawActionClockRemainder: rawActionClockRemainder, rawActionSpeed: rawActionSpeed, rawAnimationSpeed: rawAnimationSpeed, nativeActionElapsed: nativeActionElapsed, layerAuxiliaryFlags: imageLayerAuxiliaryFlagsReference, drawGate: imageDrawGate, enableFlag: imageEnableFlag, miFlag: imageMIFlag, decodedOffset: objectOffset, byteLength: offset - objectOffset,
                                                        imageSource: imageSource, anchorName: imageAnchorName, rawPlacementMode: rawPlacementMode,
                                                        rawPlacementStrength: rawPlacementStrength))
                            }
                            let fixedOffset = offset
                            let fixed = try take(189)
                            let returnSpacing = fixed.withUnsafeBytes { bytes in
                                SIMD2(Int32(littleEndian: bytes.loadUnaligned(fromByteOffset: 0x84, as: Int32.self)),
                                      Int32(littleEndian: bytes.loadUnaligned(fromByteOffset: 0x9d, as: Int32.self)))
                            }
                            // 0x678e69–0x678e87 passes these fields to the rectangle setter.
                            let rectangle = fixed.withUnsafeBytes { bytes in
                                (0..<4).map { Int32(littleEndian: bytes.loadUnaligned(
                                    fromByteOffset: 12 + $0 * 4, as: Int32.self)) }
                            }
                            var textReferences: [SaveReaderCursor.Reference] = []
                            let strings = try (0..<5).map { _ in
                                let start = offset
                                _ = try string()
                                if isMessage || isButton {
                                    let payload = Data(state[(state.startIndex + start + 2)..<(state.startIndex + offset)])
                                    textReferences.append(.init(decodedOffset: start + 2, length: payload.count,
                                                                sha256: payload.sha256Hex))
                                }
                                return start
                            }
                            if isMessage {
                                guard let imageLayerTiming, let imageLayerAuxiliaryFlagsReference else {
                                    throw ResourceError.rejected("missing_saved_message_layer_state")
                                }
                                // 0x68cc34 and 0x68cca4 use the common button
                                // loader/writer without the derived 42-byte tail.
                                return ObjectElement(reference: reference, payload: nil, buttonPayload: nil, imagePayload: nil,
                                    messagePayload: .init(decodedOffset: objectOffset, baseRecordWord: baseRecordWord,
                                        imageLibraryOffset: libraryOffset,
                                        imageSource: imageSource, anchorName: imageAnchorName, fixedRecordOffset: fixedOffset, drawableRectangle: rectangle,
                                        stringOffsets: strings, userStrings: buttonUserStrings, textStrings: textReferences,
                                        rawTextCursor: fixed.withUnsafeBytes { Int32(littleEndian: $0.loadUnaligned(fromByteOffset: 0x44, as: Int32.self)) },
                                        rawTextMargins: fixed.withUnsafeBytes { bytes in
                                            [0x90, 0x94].map { Int32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: Int32.self)) }
                                        }, rawKinsokuWordLength: fixed.withUnsafeBytes {
                                            Int32(littleEndian: $0.loadUnaligned(fromByteOffset: 0x8c, as: Int32.self))
                                        }, returnSpacing: returnSpacing, rawAsEnabled: fixed[fixed.startIndex + 0x9a],
                                        rawApEnabled: fixed[fixed.startIndex + 0x9b],
                                        staticPlacement: imageStaticPlacement, staticScale: imageStaticScale,
                                        rawActionIndex: rawActionIndex, rawActionElapsed: rawActionElapsed,
                                        rawActionClockRemainder: rawActionClockRemainder, rawActionSpeed: rawActionSpeed,
                                        rawAnimationSpeed: rawAnimationSpeed,
                                        nativeActionIndex: nativeActionIndex, nativeActionElapsed: nativeActionElapsed,
                                        layerTiming: imageLayerTiming, layerAuxiliaryFlags: imageLayerAuxiliaryFlagsReference,
                                        textureSlots: imageTextureSlots,
                                        rawImageDrawGate: imageDrawGate, rawImageEnableFlag: imageEnableFlag,
                                        nextDecodedOffset: offset))
                            }
                            let buttonOffset = offset
                            let buttonRecord = try take(42)
                            let buttonVersion = buttonRecord.withUnsafeBytes {
                                Int32(littleEndian: $0.loadUnaligned(as: Int32.self))
                            }
                            let checkByte = buttonVersion == 10 ? buttonRecord[buttonRecord.startIndex + 8] : nil
                            let lockByte = buttonVersion == 10 ? buttonRecord[buttonRecord.startIndex + 9] : nil
                            guard let imageLayerTiming, let imageLayerAuxiliaryFlagsReference, let buttonSPReference else {
                                throw ResourceError.rejected("missing_saved_button_layer_state")
                            }
                            return ObjectElement(reference: reference, payload: nil,
                                buttonPayload: .init(decodedOffset: objectOffset, baseRecordWord: baseRecordWord,
                                    imageLibraryOffset: libraryOffset, imageSource: imageSource, anchorName: imageAnchorName,
                                    fixedRecordOffset: fixedOffset, drawableRectangle: rectangle, stringOffsets: strings,
                                    textStrings: textReferences,
                                    rawTextCursor: fixed.withUnsafeBytes { Int32(littleEndian: $0.loadUnaligned(fromByteOffset: 0x44, as: Int32.self)) },
                                    rawTextMargins: fixed.withUnsafeBytes { bytes in [0x90, 0x94].map { Int32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: Int32.self)) } },
                                    rawKinsokuWordLength: fixed.withUnsafeBytes { Int32(littleEndian: $0.loadUnaligned(fromByteOffset: 0x8c, as: Int32.self)) },
                                    returnSpacing: returnSpacing,
                                    rawAsEnabled: fixed[fixed.startIndex + 0x9a],
                                    rawApEnabled: fixed[fixed.startIndex + 0x9b],
                                    userStrings: buttonUserStrings,
                                    userIntegerReferences: buttonUserIntegerReferences, userIntegerWords: buttonUserIntegerWords, soundNames: buttonSoundNames,
                                    textureSlots: imageTextureSlots,
                                    rawImageDrawGate: imageDrawGate, rawImageEnableFlag: imageEnableFlag,
                                    rawButtonState: fixed[fixed.startIndex + 0x98],
                                    layerTiming: imageLayerTiming, layerAuxiliaryFlags: imageLayerAuxiliaryFlagsReference,
                                    rawActionIndex: rawActionIndex, rawActionElapsed: rawActionElapsed,
                                    rawActionClockRemainder: rawActionClockRemainder, rawActionSpeed: rawActionSpeed,
                                    rawAnimationSpeed: rawAnimationSpeed,
                                    rawSP: rawButtonSP,
                                    spReference: buttonSPReference,
                                    rawCheckByte: checkByte, rawLockByte: lockByte,
                                    staticPlacement: imageStaticPlacement,
                                    staticScale: activePlacement == nil ? imageStaticScale : nil,
                                    buttonRecordOffset: buttonOffset, nextDecodedOffset: offset), imagePayload: nil)
                        }
                        // Both list (0x68e3cc) and table (0x68f308) read the
                        // base object, then a length-prefixed string list.
                        guard try take(4).elementsEqual("objd".utf8), try integer() == 1 else {
                            throw ResourceError.rejected("unsupported_saved_text_object_header")
                        }
                        let baseField = try integer()
                        let lines = Int(try integer())
                        guard (-1...min(65_535, remainingValues, (state.count - offset) / 2)).contains(lines) else {
                            throw ResourceError.rejected("invalid_saved_text_object_line_count")
                        }
                        remainingValues -= max(0, lines)
                        payload = TextObjectPayload(decodedOffset: objectOffset, baseField: baseField,
                            declaredLineCount: lines,
                            lines: try (0..<max(0, lines)).map { _ in try string() })
                    } else {
                        payload = nil
                    }
                    return ObjectElement(reference: reference, payload: payload, buttonPayload: nil, imagePayload: nil)
                })
            }
            return Record(decodedOffset: start, valueOffset: valueOffset, nextDecodedOffset: offset,
                          header: Data(header), textFields: textFields, values: values)
        }
        nextDecodedOffset = offset
    }
}
