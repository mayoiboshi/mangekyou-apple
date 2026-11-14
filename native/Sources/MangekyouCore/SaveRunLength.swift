import Foundation

/// Version-one runlengthpack stream used by the save-state codec.
enum SaveRunLength {
    /// Emit bounded literal blocks accepted by the version-one reader.
    static func encodeLiterals(_ input: Data) throws -> Data {
        let input = Data(input)
        let blockLength = input.count & ~3
        let tailLength = input.count - blockLength
        let controls = (blockLength / 4 + 62) / 63
        guard input.count <= SaveEnvelope.maxFileBytes,
              64 + blockLength + controls <= SaveEnvelope.maxFileBytes else {
            throw ResourceError.rejected("runlengthpack_output_limit")
        }
        var output = Data(repeating: 0, count: 64)
        output.replaceSubrange(0..<14, with: "runlengthpack\0".utf8)
        for (offset, value) in [(16, UInt32(1)), (20, UInt32(blockLength)), (24, UInt32(tailLength))] {
            withUnsafeBytes(of: value.littleEndian) { output.replaceSubrange(offset..<(offset + 4), with: $0) }
        }
        if tailLength > 0 { output.replaceSubrange(28..<(28 + tailLength), with: input.suffix(tailLength)) }
        var cursor = 0
        while cursor < blockLength {
            let words = min(63, (blockLength - cursor) / 4)
            output.append(UInt8(bitPattern: Int8(-words)))
            output.append(input[cursor..<(cursor + words * 4)])
            cursor += words * 4
        }
        return output
    }

    static func decode(_ data: Data) throws -> Data {
        let input = Data(data)
        guard input.count >= 64, input.starts(with: "runlengthpack\0".utf8) else {
            throw ResourceError.rejected("invalid_runlengthpack_header")
        }
        let (version, blockBytes, tailBytes) = input.withUnsafeBytes { bytes in
            func field(_ offset: Int) -> Int {
                Int(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
            }
            return (field(16), field(20), field(24))
        }
        guard version == 1, blockBytes % 4 == 0, tailBytes <= 3 else {
            throw ResourceError.rejected("unsupported_runlengthpack_layout")
        }
        guard blockBytes + tailBytes <= SaveEnvelope.maxFileBytes else {
            throw ResourceError.rejected("runlengthpack_output_limit")
        }

        var output = Data()
        output.reserveCapacity(blockBytes + tailBytes)
        var references = [Range<Int>?](repeating: nil, count: 64)
        var protected = [Bool](repeating: false, count: 64)
        var next = 0
        var cursor = 64
        while output.count < blockBytes {
            guard cursor < input.count else { throw ResourceError.rejected("truncated_runlengthpack_control") }
            let control = Int(Int8(bitPattern: input[cursor]))
            cursor += 1
            let source: Range<Int>
            let repetitions: Int
            switch control {
            case 1...127:
                source = cursor..<(cursor + 4)
                cursor += 4
                repetitions = control
            case -63 ... -1:
                source = cursor..<(cursor + (-control * 4))
                cursor = source.upperBound
                repetitions = 1
                while protected[next] {
                    protected[next] = false
                    next = (next + 1) % 64
                }
                references[next] = source
                next = (next + 1) % 64
            case -127 ... -64:
                let index = -control - 64
                guard let reference = references[index] else {
                    throw ResourceError.rejected("undefined_runlengthpack_reference")
                }
                source = reference
                repetitions = 1
                protected[index] = true
            default:
                throw ResourceError.rejected("invalid_runlengthpack_control")
            }
            guard source.upperBound <= input.count,
                  source.count * repetitions <= blockBytes - output.count else {
                throw ResourceError.rejected("runlengthpack_block_bounds")
            }
            let block = input[source]
            for _ in 0..<repetitions { output.append(block) }
        }
        guard cursor == input.count else { throw ResourceError.rejected("runlengthpack_trailing_data") }
        output.append(input[28..<(28 + tailBytes)])
        return output
    }
}
