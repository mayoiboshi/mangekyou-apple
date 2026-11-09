import Foundation

/// Save codec zero, reconstructed from the original 0x4e1be0 reader.
enum SaveBPE {
    static func decode(_ data: Data) throws -> Data {
        let input = Data(data)
        guard input.count >= 12, input.starts(with: [0x31, 0x50, 0x43, 0xff]) else {
            throw ResourceError.rejected("invalid_save_bpe_header")
        }
        var cursor = 4
        func number(_ bytes: Int) throws -> Int {
            guard bytes <= input.count - cursor else { throw ResourceError.rejected("truncated_save_bpe") }
            var value = 0
            for shift in 0..<bytes {
                value |= Int(input[cursor]) << (8 * shift)
                cursor += 1
            }
            return value
        }

        let flags = try number(4)
        let expected = try number(4)
        guard expected <= SaveEnvelope.maxFileBytes else { throw ResourceError.rejected("save_bpe_output_limit") }
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
