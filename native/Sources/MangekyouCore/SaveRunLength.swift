import Foundation

/// Version-one runlengthpack stream used by the save-state codec.
enum SaveRunLength {
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
