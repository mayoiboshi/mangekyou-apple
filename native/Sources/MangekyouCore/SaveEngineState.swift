import Foundation

/// Engine state after the global and routine variables.
package struct SaveEngineState: Encodable, Sendable {
    struct TailStringSpan: Encodable, Sendable {
        let decodedOffset: Int
        let byteLength: Int
    }

    private struct MemoryCheckpointSpan: Encodable, Sendable {
        let name: Range<Int>
        let fixedFields: Range<Int>
        let stream: Range<Int>
    }

    struct MemoryCheckpoint: Sendable {
        let nameUTF16: Data
        let fixedFields: Data
        let stream: Data
    }

    package let status: EvidenceStatus
    let decodedOffset: Int
    let systemLockMask: Int32
    let systemCustomLockMask: Int32
    private let releaseArgumentSpan: TailStringSpan
    private let formCloseFilenameSpan: TailStringSpan
    let stringListCount: Int
    let blobCount: Int
    private let memoryCheckpointCountOffset: Int
    private let memoryCheckpointSpans: [MemoryCheckpointSpan]
    let imotwtOffset: Int
    let nextDecodedOffset: Int
    let remainingLength: Int
    let finalObjectOffset: Int
    let finalObjectVersion: Int
    let finalObjectTailVersion: Int
    let tailStringSpans: [TailStringSpan]

    func memoryCheckpoints(in state: Data) throws -> [MemoryCheckpoint] {
        guard state.count >= nextDecodedOffset else {
            throw ResourceError.rejected("invalid_save_engine_state_bounds")
        }
        func copy(_ range: Range<Int>) -> Data {
            state.subdata(in: (state.startIndex + range.lowerBound)..<(state.startIndex + range.upperBound))
        }
        return memoryCheckpointSpans.map { span in
            MemoryCheckpoint(nameUTF16: copy(span.name), fixedFields: copy(span.fixedFields), stream: copy(span.stream))
        }
    }

    func replacingMemoryCheckpoints(in state: Data, with checkpoints: [MemoryCheckpoint]) throws -> Data {
        let oldEnd = imotwtOffset
        let oldStart = memoryCheckpointCountOffset
        let limit = SaveEnvelope.maxFileBytes - (state.count - (oldEnd - oldStart))
        guard state.count >= nextDecodedOffset, checkpoints.count <= 65_536, limit >= 4 else {
            throw ResourceError.rejected("save_memory_checkpoint_size_limit")
        }
        if blobCount == 0, checkpoints.isEmpty { return state }
        var replacement = Data()
        withUnsafeBytes(of: Int32(checkpoints.count).littleEndian) { replacement.append(contentsOf: $0) }
        for checkpoint in checkpoints {
            guard checkpoint.nameUTF16.count.isMultiple(of: 2),
                  let nameLength = Int16(exactly: checkpoint.nameUTF16.count / 2),
                  checkpoint.fixedFields.count == 8,
                  let streamLength = Int32(exactly: checkpoint.stream.count),
                  checkpoint.nameUTF16.count + checkpoint.stream.count + 14 <= limit - replacement.count else {
                throw ResourceError.rejected("save_memory_checkpoint_size_limit")
            }
            withUnsafeBytes(of: nameLength.littleEndian) { replacement.append(contentsOf: $0) }
            replacement.append(checkpoint.nameUTF16)
            replacement.append(checkpoint.fixedFields)
            withUnsafeBytes(of: streamLength.littleEndian) { replacement.append(contentsOf: $0) }
            replacement.append(checkpoint.stream)
        }
        var updated = state
        let countStart = state.startIndex + oldStart
        // The native writer sets the first dword of the 68-byte container header.
        updated.replaceSubrange((countStart - 68)..<(countStart - 64), with: [10, 0, 0, 0])
        updated.replaceSubrange(countStart..<(state.startIndex + oldEnd), with: replacement)
        return updated
    }

    /// The script exposes slots 0...6 through sys n/n2. Slot 7 stays opaque.
    func systemNameSlots(in state: Data) throws -> [String] {
        try tailStringSpans.prefix(7).map { try Self.systemString(in: state, span: $0) }
    }

    func systemReleaseArgument(in state: Data) throws -> String {
        try Self.systemString(in: state, span: releaseArgumentSpan)
    }

    func formCloseSaveFilename(in state: Data) throws -> String {
        try Self.systemString(in: state, span: formCloseFilenameSpan)
    }

    private static func systemString(in state: Data, span: TailStringSpan) throws -> String {
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

    private static func encodeSystemString(_ value: String) throws -> Data {
        guard let count = Int16(exactly: value.utf16.count),
              let bytes = value.data(using: .utf16LittleEndian) else {
            throw ResourceError.rejected("invalid_save_system_name_encoding")
        }
        return withUnsafeBytes(of: count.littleEndian) { Data($0) } + bytes
    }

    /// Replace the exposed system fields while preserving the opaque eighth slot.
    static func replacingSystemFields(in state: Data, at offset: Int, names: [String],
                                      releaseArgument: String, formCloseSaveFilename: String,
                                      lockMask: Int32, customLockMask: Int32) throws -> Data {
        let tail = try Self(state: state, at: offset)
        guard names.count == 7, tail.status == .verified, tail.tailStringSpans.count == 8,
              let first = tail.tailStringSpans.first, let opaque = tail.tailStringSpans.last else {
            throw ResourceError.rejected("save_system_name_slot_bounds")
        }
        var encoded = Data()
        for name in names {
            encoded.append(try encodeSystemString(name))
        }
        let encodedReleaseFields = try encodeSystemString(releaseArgument) + encodeSystemString(formCloseSaveFilename)
        let releaseStart = tail.releaseArgumentSpan.decodedOffset
        let releaseEnd = tail.formCloseFilenameSpan.decodedOffset + tail.formCloseFilenameSpan.byteLength
        let replacedBytes = opaque.decodedOffset - first.decodedOffset + releaseEnd - releaseStart
        guard encoded.count + encodedReleaseFields.count <= SaveEnvelope.maxFileBytes - (state.count - replacedBytes) else {
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
        result.replaceSubrange((state.startIndex + releaseStart)..<(state.startIndex + releaseEnd),
                               with: encodedReleaseFields)
        let decoded = try Self(state: result, at: offset)
        guard decoded.status == .verified, decoded.systemLockMask == lockMask,
              decoded.systemCustomLockMask == customLockMask, try decoded.systemNameSlots(in: result) == names,
              try decoded.systemReleaseArgument(in: result) == releaseArgument,
              try decoded.formCloseSaveFilename(in: result) == formCloseSaveFilename else {
            throw ResourceError.rejected("save_system_field_roundtrip")
        }
        return result
    }

    package init(state: Data, at start: Int) throws {
        decodedOffset = start
        (systemLockMask, systemCustomLockMask, releaseArgumentSpan, formCloseFilenameSpan, stringListCount, memoryCheckpointCountOffset, memoryCheckpointSpans, imotwtOffset, finalObjectOffset,
         finalObjectVersion, finalObjectTailVersion, tailStringSpans, nextDecodedOffset) = try state.withUnsafeBytes { bytes in
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
            for _ in 0..<5 { try skipString() }
            // 0x6ae4a4 writes instance +0x18 here; 0x6ae0c4 restores it.
            let releaseStart = offset
            try skipString()
            let release = TailStringSpan(decodedOffset: releaseStart, byteLength: offset - releaseStart)
            // The next string is instance +0x1c (0x6ae4b0 and 0x6ae0dc).
            let closeStart = offset
            try skipString()
            let closeName = TailStringSpan(decodedOffset: closeStart, byteLength: offset - closeStart)
            _ = try take(69 + 69)
            // 0x4e133f–0x4e1367 accepts -1 and reads no list entries.
            let serializedCount = try integer()
            let strings = serializedCount == -1 ? 0 : serializedCount
            guard (0...min(65_535, (bytes.count - offset) / 2)).contains(strings) else {
                throw ResourceError.rejected("invalid_engine_string_list_count")
            }
            for _ in 0..<strings { try skipString() }
            // 0x6ae106 reads the +0x104 mdat container. 0x5b2440 then reads
            // each UTF-16 name, eight fixed bytes, and the bounded stream.
            _ = try take(68)
            let checkpointCountOffset = offset
            let blobs = try integer()
            guard (0...min(65_536, (bytes.count - offset) / 14)).contains(blobs) else {
                throw ResourceError.rejected("invalid_engine_blob_count")
            }
            let checkpoints = try (0..<blobs).map { _ in
                let nameStart = offset + 2
                try skipString()
                let name = nameStart..<offset
                let fieldsStart = try take(8)
                let fields = fieldsStart..<offset
                let length = try integer()
                let streamStart = try take(length)
                let stream = streamStart..<offset
                return MemoryCheckpointSpan(name: name, fixedFields: fields, stream: stream)
            }
            let tag = try take(264)
            let observedTag = Data(bytes[tag..<(tag + 8)])
            guard observedTag.prefix(while: { $0 != 0 }).elementsEqual("imotwt".utf8) else {
                throw ResourceError.rejected(
                    "imotwt_tag_mismatch:state_offset=\(start):tag_offset=\(tag):state_bytes=\(bytes.count):tag_sha256=\(observedTag.sha256Hex)")
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
            return (lock, customLock, release, closeName, strings, checkpointCountOffset, checkpoints, tag, finalOffset, version, tailVersion, spans, offset)
        }
        blobCount = memoryCheckpointSpans.count
        remainingLength = state.count - nextDecodedOffset
        status = remainingLength == 0 ? .verified : .unsupported
    }
}
