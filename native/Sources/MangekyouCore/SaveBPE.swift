import Foundation

/// Save codec zero, reconstructed from the original 0x4e1be0 reader.
enum SaveBPE {
    /// Identity dictionaries encode bytes without changing the native block format.
    static func encodeLiterals(_ data: Data) throws -> Data {
        let blockSize = 4096
        guard data.count <= SaveEnvelope.maxFileBytes else {
            throw ResourceError.rejected("save_bpe_output_limit")
        }
        let blocks = (data.count + blockSize - 1) / blockSize
        let overhead = 12 + blocks * 5
        guard data.count <= SaveEnvelope.maxFileBytes - overhead else {
            throw ResourceError.rejected("save_bpe_input_limit")
        }
        var result = Data([0x31, 0x50, 0x43, 0xff, 1, 0, 0, 0])
        result.reserveCapacity(data.count + overhead)
        withUnsafeBytes(of: UInt32(data.count).littleEndian) { result.append(contentsOf: $0) }
        for offset in stride(from: 0, to: data.count, by: blockSize) {
            let length = min(blockSize, data.count - offset)
            // Skip 128 identities, emit identity 128, then skip the remaining 127.
            result.append(contentsOf: [255, 128, 254])
            withUnsafeBytes(of: UInt16(length).littleEndian) { result.append(contentsOf: $0) }
            let start = data.startIndex + offset
            result.append(contentsOf: data[start..<(start + length)])
        }
        return result
    }

    static func decode(_ data: Data) throws -> Data {
        let input = Data(data)
        let hasSignature = input.starts(with: [0x31, 0x50, 0x43, 0xff])
        guard input.count >= (hasSignature ? 12 : 4) else {
            throw ResourceError.rejected("invalid_save_bpe_header")
        }
        var cursor = hasSignature ? 4 : 0
        func number(_ bytes: Int) throws -> Int {
            guard bytes <= input.count - cursor else { throw ResourceError.rejected("truncated_save_bpe") }
            var value = 0
            for shift in 0..<bytes {
                value |= Int(input[cursor]) << (8 * shift)
                cursor += 1
            }
            return value
        }

        // The disk reader passes CL = 0 to 0x4e2550. On a missing 1PC
        // signature, 0x4e1c8d reads the decoded length from the first word
        // and uses 32-bit block lengths.
        let flags = hasSignature ? try number(4) : 0
        let expected = try number(4)
        guard expected <= SaveEnvelope.maxFileBytes else {
            throw ResourceError.rejected(hasSignature ? "save_bpe_output_limit" : "invalid_save_bpe_header")
        }
        var output = Data()
        output.reserveCapacity(expected)
        var stack: [UInt8] = []
        stack.reserveCapacity(256)
        let identity = (0..<256).map(UInt8.init)
        while cursor < input.count {
            var left = identity
            var right = [UInt8](repeating: 0, count: 256)
            var symbol = 0
            while symbol < 256 {
                var count = try number(1)
                if count > 127 {
                    symbol += count - 127
                    if symbol >= 256 { break }
                    count = 0
                }
                guard count + 1 <= 256 - symbol else {
                    throw ResourceError.rejected("save_bpe_dictionary_bounds")
                }
                for _ in 0...count {
                    left[symbol] = UInt8(try number(1))
                    if left[symbol] != identity[symbol] { right[symbol] = UInt8(try number(1)) }
                    symbol += 1
                }
            }

            let count = try number(flags & 1 == 1 ? 2 : 4)
            guard count > 0, count <= input.count - cursor, count <= expected - output.count else {
                throw ResourceError.rejected("save_bpe_block_bounds")
            }
            let end = cursor + count
            while cursor < end || !stack.isEmpty {
                let token: UInt8
                if let pending = stack.popLast() {
                    token = pending
                } else {
                    token = input[cursor]
                    cursor += 1
                }
                let index = Int(token)
                if left[index] == token {
                    guard output.count < expected else { throw ResourceError.rejected("save_bpe_output_bounds") }
                    output.append(token)
                } else {
                    guard stack.count < 256 else { throw ResourceError.rejected("save_bpe_dictionary_cycle_or_depth") }
                    stack.append(right[index])
                    stack.append(left[index])
                }
            }
        }
        guard output.count == expected else { throw ResourceError.rejected("save_bpe_size_mismatch") }
        return output
    }
}
