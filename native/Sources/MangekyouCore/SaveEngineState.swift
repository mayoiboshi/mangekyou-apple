import Foundation

/// Structural boundaries after the variables. Field values remain opaque.
package struct SaveEngineState: Encodable, Sendable {
    struct TailStringSpan: Encodable, Sendable {
        let decodedOffset: Int
        let byteLength: Int
    }

    package let status: EvidenceStatus
    let decodedOffset: Int
    let systemLockMask: Int32
    let systemCustomLockMask: Int32
    let stringListCount: Int
    let blobCount: Int
    let imotwtOffset: Int
    let nextDecodedOffset: Int
    let remainingLength: Int
    let finalObjectOffset: Int
    let finalObjectVersion: Int
    let finalObjectTailVersion: Int
    let tailStringSpans: [TailStringSpan]

    /// The script exposes slots 0...6 through sys n/n2. Slot 7 stays opaque.
    func systemNameSlots(in state: Data) throws -> [String] {
        try tailStringSpans.prefix(7).map { span in
            guard span.decodedOffset >= 0, span.byteLength >= 2,
                  span.decodedOffset <= state.count,
                  span.byteLength <= state.count - span.decodedOffset else {
                throw ResourceError.rejected("save_system_name_slot_bounds")
            }
            let start = state.startIndex + span.decodedOffset + 2
            let end = start + span.byteLength - 2
            guard let text = String(data: state[start..<end], encoding: .utf16LittleEndian) else {
                throw ResourceError.rejected("invalid_save_system_name_encoding")
            }
            return text
        }
    }

    /// Replace the exposed system fields while preserving the opaque eighth slot.
    static func replacingSystemFields(in state: Data, at offset: Int, names: [String],
                                      lockMask: Int32, customLockMask: Int32) throws -> Data {
        let tail = try Self(state: state, at: offset)
        guard names.count == 7, tail.status == .verified, tail.tailStringSpans.count == 8,
              let first = tail.tailStringSpans.first, let opaque = tail.tailStringSpans.last else {
            throw ResourceError.rejected("save_system_name_slot_bounds")
        }
        var encoded = Data()
        for name in names {
            guard let count = Int16(exactly: name.utf16.count),
                  let bytes = name.data(using: .utf16LittleEndian) else {
                throw ResourceError.rejected("invalid_save_system_name_encoding")
            }
            withUnsafeBytes(of: count.littleEndian) { encoded.append(contentsOf: $0) }
            encoded.append(bytes)
        }
        let replacedBytes = opaque.decodedOffset - first.decodedOffset
        guard encoded.count <= SaveEnvelope.maxFileBytes - (state.count - replacedBytes) else {
            throw ResourceError.rejected("save_system_name_slot_bounds")
        }
        var result = state
        let lockOffset = state.startIndex + offset + 12
        withUnsafeBytes(of: lockMask.littleEndian) {
            result.replaceSubrange(lockOffset..<(lockOffset + 4), with: $0)
        }
        withUnsafeBytes(of: customLockMask.littleEndian) {
            result.replaceSubrange((lockOffset + 4)..<(lockOffset + 8), with: $0)
        }
        result.replaceSubrange((state.startIndex + first.decodedOffset)..<(state.startIndex + opaque.decodedOffset),
                               with: encoded)
        let decoded = try Self(state: result, at: offset)
        guard decoded.status == .verified, decoded.systemLockMask == lockMask,
              decoded.systemCustomLockMask == customLockMask, try decoded.systemNameSlots(in: result) == names else {
            throw ResourceError.rejected("save_system_field_roundtrip")
        }
        return result
    }

    package init(state: Data, at start: Int) throws {
        decodedOffset = start
        (systemLockMask, systemCustomLockMask, stringListCount, blobCount, imotwtOffset, finalObjectOffset, finalObjectVersion,
         finalObjectTailVersion, tailStringSpans, nextDecodedOffset) = try state.withUnsafeBytes { bytes in
            var offset = start
            func take(_ length: Int) throws -> Int {
                guard (0...bytes.count).contains(offset), length >= 0, length <= bytes.count - offset else {
                    throw ResourceError.rejected("invalid_save_engine_state_bounds")
                }
                let start = offset
                offset += length
                return start
            }
            func integer() throws -> Int {
                Int(Int32(littleEndian: bytes.loadUnaligned(fromByteOffset: try take(4), as: Int32.self)))
            }
            func skipString() throws {
                let units = Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: try take(2), as: Int16.self))
                _ = try take(Int(units) * 2)
            }

            // 0x6ae017 reads the block into instance +0x14c.
            let fixed = try take(419)
            let lock = Int32(littleEndian: bytes.loadUnaligned(fromByteOffset: fixed + 12, as: Int32.self))
            let customLock = Int32(littleEndian: bytes.loadUnaligned(fromByteOffset: fixed + 16, as: Int32.self))
            for _ in 0..<7 { try skipString() }
            _ = try take(69 + 69)
            // 0x4e133f–0x4e1367 accepts -1 and reads no list entries.
            let serializedCount = try integer()
            let strings = serializedCount == -1 ? 0 : serializedCount
            guard (0...min(65_535, (bytes.count - offset) / 2)).contains(strings) else {
                throw ResourceError.rejected("invalid_engine_string_list_count")
            }
            for _ in 0..<strings { try skipString() }
            _ = try take(68)
            let blobs = try integer()
            guard (0...min(65_536, (bytes.count - offset) / 14)).contains(blobs) else {
                throw ResourceError.rejected("invalid_engine_blob_count")
            }
            for _ in 0..<blobs {
                try skipString()
                _ = try take(8)
                _ = try take(integer())
            }
            let tag = try take(264)
            guard bytes[tag..<(tag + 8)].prefix(while: { $0 != 0 }).elementsEqual("imotwt".utf8) else {
                throw ResourceError.rejected("imotwt_tag_mismatch")
            }
            let finalOffset = offset
            _ = try take(53)
            let version = try integer()
            guard (1...3).contains(version) else { throw ResourceError.rejected("unsupported_final_object_version") }
            _ = try take(121)
            for _ in 0..<4 { try SaveImageGenerators.skip(bytes, take: take) }
            if version >= 2 { try SaveImageGenerators.skipGroup(bytes, take: take) }
            if version >= 3 { _ = try take(4) }
            _ = try take(4)
            let tailVersion = try integer()
            guard (1...2).contains(tailVersion) else {
                throw ResourceError.rejected("unsupported_final_object_tail_version")
            }
            _ = try take(tailVersion == 2 ? 28 : 24)
            // 0x6ae129–0x6ae149 reads eight length-prefixed strings in order.
            let spans = try (0..<8).map { _ in
                let start = offset
                try skipString()
                return TailStringSpan(decodedOffset: start, byteLength: offset - start)
            }
            return (lock, customLock, strings, blobs, tag, finalOffset, version, tailVersion, spans, offset)
        }
        remainingLength = state.count - nextDecodedOffset
        status = remainingLength == 0 ? .verified : .unsupported
    }
}
