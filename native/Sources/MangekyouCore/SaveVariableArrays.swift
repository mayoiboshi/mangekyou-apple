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
        for record in records {
            switch record.values {
            case .integers: integerCount += 1
            case .strings: stringCount += 1
            case .objectText(let elements):
                objectCount += 1
                buttonPayloads += elements.compactMap(\.buttonPayload)
                imagePayloads += elements.compactMap(\.imagePayload)
            case .absent: absentCount += 1
            }
        }
        return Summary(decodedOffset: offset, integerArrayCount: integerCount,
                       stringArrayCount: stringCount, objectArrayCount: objectCount, absentValueCount: absentCount, buttonPayloads: buttonPayloads, imagePayloads: imagePayloads,
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
    }

    struct ImagePayload: Encodable, Sendable {
        let fixedRecord: SaveReaderCursor.Reference
        let staticPlacement: SIMD3<Int32>?
        let staticScale: SIMD3<Int32>?
        struct OpacityTransition: Encodable, Sendable {
            let origin: UInt8
            let target: UInt8
            let remaining: Int32
            let duration: Int32
            let repeats: Int32
        }
        let opacityTransition: OpacityTransition?
        let staticOpacity: UInt8?
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
                guard length == 0 || !hasObjectPayload || objectType == "list" || objectType == "table" || objectType == "sbtn" || objectType == "simg" else {
                    throw ResourceError.rejected("object_callback_payload_unparsed")
                }
                values = .objectText(try (0..<length).map { _ in
                    let reference = try string()
                    let payload: TextObjectPayload?
                    if hasObjectPayload {
                        let objectOffset = offset
                        if objectType == "sbtn" || objectType == "simg" {
                            guard try take(4).elementsEqual("objd".utf8), try integer() == 1 else {
                                throw ResourceError.rejected("unsupported_saved_visual_object_header")
                            }
                            _ = try integer()
                            let libraryOffset = offset
                            var imageSource: SaveReaderCursor.Reference?
                            var imageFixedRecord: SaveReaderCursor.Reference?
                            var imageStaticPlacement: SIMD3<Int32>?
                            var imageStaticScale: SIMD3<Int32>?
                            var imageStaticOpacity: UInt8?
                            var imageOpacityTransition: ImagePayload.OpacityTransition?
                            var imageDrawGate: UInt8 = 0
                            var imageEnableFlag: UInt8 = 0
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
                                }, visit: { start, _, sourceRange, _, _ in
                                    let fixed = start..<sourceRange.lowerBound - 2
                                    imageFixedRecord = .init(decodedOffset: start, length: fixed.count,
                                        sha256: Data(bytes[fixed]).sha256Hex)
                                    if objectType == "simg" {
                                        // 0x5ab666 checks the draw gate; 0x5ad0dc reads the separate enable flag.
                                        imageDrawGate = bytes[start + 0x9f9]
                                        imageEnableFlag = bytes[start + 0x9fa]
                                        func field(_ offset: Int) -> Int32 {
                                            Int32(littleEndian: bytes.loadUnaligned(fromByteOffset: start + offset, as: Int32.self))
                                        }
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
                                        // With no positive duration, 0x5ab403 supplies 1024.
                                        // 0x5ac341 then selects the destination on each axis.
                                        if field(0x9ed) <= 0 {
                                            let placement = SIMD3(field(0x915), field(0x919), field(0x91d))
                                            // The original stores the evaluated values as single precision.
                                            if (0..<3).allSatisfy({ (-16_777_216...16_777_216).contains(placement[$0]) }) {
                                                imageStaticPlacement = placement
                                            }
                                            // 0x5ab495–0x5ab4fa feeds the three scale components.
                                            // Keep 3D depth and rotation outside this restore subset.
                                            let scale = SIMD3(field(0x959), field(0x965), field(0x971))
                                            if [0x929, 0x935, 0x941, 0x94d].allSatisfy({ field($0) == 0 }),
                                               scale.z == 100,
                                               (0..<2).allSatisfy({ (-16_777_216...16_777_216).contains(scale[$0]) }) {
                                                imageStaticScale = scale
                                            }
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
                                    imagePayload: .init(fixedRecord: imageFixedRecord, staticPlacement: imageStaticPlacement, staticScale: imageStaticScale, opacityTransition: imageOpacityTransition, staticOpacity: imageStaticOpacity, drawGate: imageDrawGate, enableFlag: imageEnableFlag, decodedOffset: objectOffset, byteLength: offset - objectOffset,
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
                                    fixedRecordOffset: fixedOffset, drawableRectangle: rectangle, stringOffsets: strings,
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
