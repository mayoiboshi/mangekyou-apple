import Foundation

/// Candidate for the selected EXE's bounded, block-local PCM16 interpolation.
/// The caller supplies lengths; this does not model stream scheduling or EOF.
package enum StreamTimeScaleCandidate {
    package static func pitch(researchFilterText text: String) throws -> Int32 {
        guard !text.isEmpty, text.utf8.count <= 8192,
              text.unicodeScalars.allSatisfy({ $0.value < 128 || $0.value == 0xa0 }) else {
            throw ResourceError.rejected("stream_timescale_filter_text_outside_profile")
        }
        let compact = String(text.unicodeScalars.filter { ![0x20, 0x09, 0xa0].contains($0.value) })
        let parts = compact.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.first == "timescale", parts.count <= 2 else {
            throw ResourceError.rejected("stream_timescale_filter_unsupported")
        }
        guard parts.count == 2 else { return 100 }
        let pair = parts[1].split(separator: ":", omittingEmptySubsequences: false)
        guard pair.count == 2, pair[0] == "pitch", !pair[1].isEmpty,
              pair[1].utf8.allSatisfy({ (48...57).contains($0) }), let value = Int32(pair[1]) else {
            throw ResourceError.rejected("stream_timescale_filter_parameter_unsupported")
        }
        return min(300, max(10, value))
    }
    package struct StreamResult: Sendable {
        package let pcm: Data
        package let blocks: Int
        package let shortReadBlocks: Int
        package let outputFrames: Int
    }

    package static func interpolate(_ samples: [Int16], outputFrames: Int) throws -> [Int16] {
        let inputFrames = samples.count / 2
        guard samples.count.isMultiple(of: 2), (1...12_288).contains(inputFrames),
              (1...4096).contains(outputFrames) else {
            throw ResourceError.rejected("stream_timescale_block_outside_profile")
        }
        if inputFrames == outputFrames { return samples }
        let step = UInt32((Double(inputFrames) / Double(outputFrames) * 65536 + 0.5).rounded(.towardZero))
        var position: UInt32 = 0, output: [Int16] = []
        output.reserveCapacity(outputFrames * 2)
        for _ in 0..<outputFrames {
            let index = Int(position >> 16)
            guard index < inputFrames else { throw ResourceError.rejected("stream_timescale_source_position_outside_profile") }
            let next = min(index + 1, inputFrames - 1)
            let fraction = Int32((position & 0xffff) >> 8)
            for channel in 0...1 {
                let first = Int32(samples[index * 2 + channel]), second = Int32(samples[next * 2 + channel])
                let result = (first * (256 - fraction) + second * fraction) / 256
                output.append(Int16(result))
            }
            position = position &+ step
        }
        return output
    }

    /// Research approximation of repeated maximum 4096-byte requests. Every
    /// block resets interpolation position, including the final short read.
    package static func interpolateStream(_ bytes: Data, pitch: Int32,
                                          maximumOutputBytes: Int = 8_000_000) throws -> StreamResult {
        guard !bytes.isEmpty, bytes.count.isMultiple(of: 4), bytes.count <= 4_000_000,
              (10...300).contains(pitch), (4...8_000_000).contains(maximumOutputBytes) else {
            throw ResourceError.rejected("stream_timescale_stream_outside_profile")
        }
        let factor = Float(Double(pitch) * 0.01)
        let desiredBytes = max(4, Int((4096 * Double(factor) + 0.5).rounded(.towardZero)) / 4 * 4)
        var cursor = 0, blocks = 0, shortReads = 0, output = Data()
        while cursor < bytes.count {
            let size = min(desiredBytes, bytes.count - cursor)
            let frames: Int
            if size == desiredBytes { frames = 1024 }
            else {
                shortReads += 1
                let adjustedBytes = Int((Double(size) / Double(factor) + 0.5).rounded(.towardZero))
                frames = max(4, adjustedBytes / 4 * 4) / 4
            }
            guard frames <= 4096, output.count <= maximumOutputBytes - frames * 4 else {
                throw ResourceError.rejected("stream_timescale_stream_output_limit")
            }
            var input: [Int16] = []
            input.reserveCapacity(size / 2)
            for offset in stride(from: cursor, to: cursor + size, by: 2) {
                let bits = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
                input.append(Int16(bitPattern: bits))
            }
            for sample in try interpolate(input, outputFrames: frames) {
                var little = sample.littleEndian
                withUnsafeBytes(of: &little) { output.append(contentsOf: $0) }
            }
            cursor += size; blocks += 1
        }
        return .init(pcm: output, blocks: blocks, shortReadBlocks: shortReads, outputFrames: output.count / 4)
    }
}
