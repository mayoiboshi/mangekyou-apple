import Foundation

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

    static func encodeIndexedLocals(in state: Data, at offset: Int, frames: [ScriptFrame]) throws
        -> (bytes: Data, end: Int) {
        let indexed = try inspectValIdx(state: state, at: offset, visit: nil)
        let needsGroups = frames.contains { !$0.locals.isEmpty || ($0.parameterCount ?? 0) != 0 }
        guard let groups = indexed.groupSpans, let end = indexed.nextDecodedOffset else {
            guard indexed.issue == "validx_tag_absent", !needsGroups else {
                throw ResourceError.rejected("save_indexed_locals_template_required")
            }
            return (Data(), offset)
        }
        guard groups.count == frames.count || (groups.isEmpty && !needsGroups) else {
            throw ResourceError.rejected("save_indexed_locals_frame_count")
        }
        var output = Data(state.dropFirst(offset).prefix(16))
        for (span, frame) in zip(groups, frames) {
            let group = try Self(state: state, decodedOffset: span.decodedOffset)
            let template = try ScriptStorage.stageSavedGlobalScalars(group)
            var values = ScriptStorage()
            values.global = frame.locals
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
                throw ResourceError.rejected("save_indexed_locals_binding_mismatch")
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
        var timerPayloads: [TimerPayload] = []
        for record in records {
            switch record.values {
            case .integers: integerCount += 1
            case .strings: stringCount += 1
            case .objectText(let elements):
                objectCount += 1
                buttonPayloads += elements.compactMap(\.buttonPayload)
                imagePayloads += elements.compactMap(\.imagePayload)
                timerPayloads += elements.compactMap(\.timerPayload)
            case .absent: absentCount += 1
            }
        }
        return Summary(decodedOffset: offset, integerArrayCount: integerCount,
                       stringArrayCount: stringCount, objectArrayCount: objectCount, absentValueCount: absentCount, buttonPayloads: buttonPayloads, imagePayloads: imagePayloads, timerPayloads: timerPayloads,
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
    }

    struct TimerPayload: Encodable, Sendable {
        let decodedOffset: Int
        let fixedRecord: SaveReaderCursor.Reference
        let interval: Int32
        let elapsed: Int32
        let enabledByte: UInt8
        let updateMask: UInt32
        let rawUpdateMode: Int32
        let callbackStrings: [SaveReaderCursor.Reference]
        let nextDecodedOffset: Int

        var isInactiveWithoutCallback: Bool {
            enabledByte == 0 && elapsed == 0 && interval >= 0 && rawUpdateMode == 0 &&
                updateMask == 0 && callbackStrings.allSatisfy { $0.length == 0 }
        }
    }

    struct ImagePayload: Encodable, Sendable {
        let fixedRecord: SaveReaderCursor.Reference
        let staticPlacement: SIMD3<Int32>?
        let staticScale: SIMD3<Int32>?
        struct ActivePlacement: Encodable, Sendable {
            let origin: SIMD3<Int32>
            let destination: SIMD3<Int32>
            let destinationScale: SIMD3<Int32>
            let remaining: Int32
            let duration: Int32
            let mode: UInt8
        }
        let activePlacement: ActivePlacement?
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
        let drawGate: UInt8
        let enableFlag: UInt8
        let decodedOffset: Int
        let byteLength: Int
        let imageSource: SaveReaderCursor.Reference?
    }

    struct ButtonPayload: Encodable, Sendable {
        let decodedOffset: Int
        let imageLibraryOffset: Int
        let imageSource: SaveReaderCursor.Reference?
        let fixedRecordOffset: Int
        let drawableRectangle: [Int32]
        let stringOffsets: [Int]
        let userStrings: [SaveReaderCursor.Reference]
        let soundNames: [SaveReaderCursor.Reference]
        let textureSlots: [ImagePayload.TextureSlot]
        let rawImageDrawGate: UInt8
        let rawImageEnableFlag: UInt8
        let rawButtonState: UInt8
        let staticPlacement: SIMD3<Int32>?
        let staticScale: SIMD3<Int32>?
        let buttonRecordOffset: Int
        let nextDecodedOffset: Int
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

    /// Rebuild a standalone CalVal section with live scalars and inline text objects.
    /// Keep opaque fields from the supplied template. Refuse unsupported live objects.
    static func generatedBindingType(_ key: Data, in storage: ScriptStorage) -> (kind: UInt8, objectType: String)? {
        guard let elements = storage.global[key]?.elements, !elements.isEmpty else { return nil }
        if elements.allSatisfy({ $0.integer != nil }) { return (0, "") }
        if elements.allSatisfy({ $0.typeName == "string" }) { return (1, "") }
        guard !storage.globalObjectAliases.contains(key) else { return nil }
        let handles = elements.compactMap { value -> UInt64? in
            guard case .object(let handle) = value else { return nil }
            return handle
        }
        guard handles.count == elements.count else { return nil }
        if handles.allSatisfy({ storage.lists[$0] != nil }) { return (2, "list") }
        if handles.allSatisfy({ storage.tables[$0] != nil }) { return (2, "table") }
        return nil
    }

    static func encodeCalValValues(template: Data, storage: ScriptStorage,
                                   newBindingKeys: Set<Data> = []) throws -> Data {
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
        for record in arrays.records {
            let objectType = asciiLower(record.textFields[1])
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
                    throw ResourceError.rejected("save_scalar_replacement_identity")
                }
                try append(span(record.decodedOffset, record.nextDecodedOffset))
                continue
            }
            let key = Data(asciiLower(record.textFields[0]).utf8)
            guard names.insert(key).inserted, let valueOffset = record.valueOffset,
                  let binding = storage.global[key], binding.elements.count <= 1_000_000 else {
                throw ResourceError.rejected("save_scalar_replacement_identity")
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
            guard let (kind, objectType) = generatedBindingType(key, in: storage) else {
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
            try append(Data([kind, 0]))
            try appendWord(0)
            try appendText(name)
            try appendText(objectType)
            let count = UInt32(binding.elements.count)
            for word in [count, 1, 1, 1, count] { try appendWord(word) }
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
        if !newBindingKeys.isEmpty {
            let count = UInt32(arrays.records.count + newBindingKeys.count)
            withUnsafeBytes(of: count.littleEndian) { output.replaceSubrange(16..<20, with: $0) }
        }
        let decoded = try readCalVal(state: output, at: 0)
        guard decoded.nextDecodedOffset == output.count else {
            throw ResourceError.rejected("save_scalar_encoding_boundary")
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
                guard length == 0 || !hasObjectPayload || objectType == "list" || objectType == "table" || objectType == "sbtn" || objectType == "simg" || objectType == "timer" else {
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
                            _ = try integer()
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
                                    fixedRecord: .init(decodedOffset: fixedOffset, length: fixed.count, sha256: Data(fixed).sha256Hex),
                                    interval: timerWord(4), elapsed: timerWord(8), enabledByte: fixed[fixed.startIndex + 12],
                                    updateMask: UInt32(bitPattern: timerWord(13)), rawUpdateMode: timerWord(21),
                                    callbackStrings: callbackStrings, nextDecodedOffset: offset))
                        }
                        if objectType == "sbtn" || objectType == "simg" {
                            guard try take(4).elementsEqual("objd".utf8), try integer() == 1 else {
                                throw ResourceError.rejected("unsupported_saved_visual_object_header")
                            }
                            _ = try integer()
                            let libraryOffset = offset
                            var imageSource: SaveReaderCursor.Reference?
                            var imageTextureSlots: [ImagePayload.TextureSlot] = []
                            var rawActionIndex: Int32 = -1
                            var rawActionElapsed: Int32 = 0
                            var rawActionClockRemainder: Int32 = 0
                            var rawActionSpeed: Int32 = 100
                            var imageFixedRecord: SaveReaderCursor.Reference?
                            var imageStaticPlacement: SIMD3<Int32>?
                            var imageStaticScale: SIMD3<Int32>?
                            var activePlacement: ImagePayload.ActivePlacement?
                            var imageStaticOpacity: UInt8?
                            var imageOpacityTransition: ImagePayload.OpacityTransition?
                            var imageDrawGate: UInt8 = 0
                            var imageEnableFlag: UInt8 = 0
                            var buttonUserStrings: [SaveReaderCursor.Reference] = []
                            var buttonSoundNames: [SaveReaderCursor.Reference] = []
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
                                }, visitUserString: { range in
                                    if objectType == "sbtn" {
                                        buttonUserStrings.append(.init(decodedOffset: range.lowerBound,
                                            length: range.count, sha256: Data(bytes[range]).sha256Hex))
                                    }
                                }, visitSoundName: { range in
                                    if objectType == "sbtn" {
                                        buttonSoundNames.append(.init(decodedOffset: range.lowerBound,
                                            length: range.count, sha256: Data(bytes[range]).sha256Hex))
                                    }
                                }, visit: { start, _, sourceRange, slots, _ in
                                    imageTextureSlots = slots.map { .init(index: $0.index, name: $0.name, embeddedOffset: $0.embeddedOffset, embeddedLength: $0.embeddedLength) }
                                    let fixed = start..<sourceRange.lowerBound - 2
                                    imageFixedRecord = .init(decodedOffset: start, length: fixed.count,
                                        sha256: Data(bytes[fixed]).sha256Hex)
                                    // 0x5ab666 checks the draw gate; 0x5ad0dc reads the separate enable flag.
                                    imageDrawGate = bytes[start + 0x9f9]
                                    imageEnableFlag = bytes[start + 0x9fa]
                                    func field(_ offset: Int) -> Int32 {
                                        Int32(littleEndian: bytes.loadUnaligned(fromByteOffset: start + offset, as: Int32.self))
                                    }
                                    if objectType == "simg" {
                                        // 0x5abda9 passes fixed record +0x804 to 0x57e840.
                                        rawActionIndex = field(0x804)
                                        // 0x5abe27 writes the accumulated action clock.
                                        rawActionElapsed = field(0x894)
                                        // 0x5abe1a restores the pending delta separately from elapsed time.
                                        rawActionClockRemainder = field(0x810)
                                        // 0x5abea4–0x5abeb4 restores the speed through 0x5ae608.
                                        rawActionSpeed = field(0x80c)
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
                                    } else if bytes[start + 0x9fd] <= 1, placementRepeats == 0,
                                              placementRemaining <= min(placementDuration, Int32.max / 1024),
                                              [0x925, 0x929, 0x931, 0x935, 0x93d, 0x941, 0x949, 0x94d].allSatisfy({ field($0) == 0 }),
                                              originScale.z == 100, scale.z == 100,
                                              (0..<2).allSatisfy({ (-16_777_216...16_777_216).contains(originScale[$0]) &&
                                                  (-16_777_216...16_777_216).contains(scale[$0]) }) {
                                        let origin = SIMD3(field(0x909), field(0x90d), field(0x911))
                                        let destination = SIMD3(field(0x915), field(0x919), field(0x91d))
                                        if (0..<3).allSatisfy({ (-16_777_216...16_777_216).contains(origin[$0]) &&
                                            (-16_777_216...16_777_216).contains(destination[$0]) }) {
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
                            if objectType == "simg" {
                                guard let imageFixedRecord else { throw ResourceError.rejected("missing_saved_image_fixed_record") }
                                return ObjectElement(reference: reference, payload: nil, buttonPayload: nil,
                                    imagePayload: .init(fixedRecord: imageFixedRecord, staticPlacement: imageStaticPlacement, staticScale: imageStaticScale, activePlacement: activePlacement, opacityTransition: imageOpacityTransition, staticOpacity: imageStaticOpacity, textureSlots: imageTextureSlots, rawActionIndex: rawActionIndex, rawActionElapsed: rawActionElapsed, rawActionClockRemainder: rawActionClockRemainder, rawActionSpeed: rawActionSpeed, drawGate: imageDrawGate, enableFlag: imageEnableFlag, decodedOffset: objectOffset, byteLength: offset - objectOffset,
                                                        imageSource: imageSource))
                            }
                            let fixedOffset = offset
                            let fixed = try take(189)
                            // 0x678e69–0x678e87 passes these fields to the rectangle setter.
                            let rectangle = fixed.withUnsafeBytes { bytes in
                                (0..<4).map { Int32(littleEndian: bytes.loadUnaligned(
                                    fromByteOffset: 12 + $0 * 4, as: Int32.self)) }
                            }
                            let strings = try (0..<5).map { _ in
                                let start = offset
                                _ = try string()
                                return start
                            }
                            let buttonOffset = offset
                            _ = try take(42)
                            return ObjectElement(reference: reference, payload: nil,
                                buttonPayload: .init(decodedOffset: objectOffset, imageLibraryOffset: libraryOffset, imageSource: imageSource,
                                    fixedRecordOffset: fixedOffset, drawableRectangle: rectangle, stringOffsets: strings, userStrings: buttonUserStrings, soundNames: buttonSoundNames,
                                    textureSlots: imageTextureSlots,
                                    rawImageDrawGate: imageDrawGate, rawImageEnableFlag: imageEnableFlag,
                                    rawButtonState: fixed[fixed.startIndex + 0x98], staticPlacement: imageStaticPlacement,
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
