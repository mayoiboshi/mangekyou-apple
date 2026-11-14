import Foundation

/// Bounded candidate for the fixed executable's volume-filter integer path.
/// Its restricted text parser and sample representation are research candidates.
package struct StreamVolumeFilterCandidate: Sendable, Equatable, Encodable {
    package let volume: Int32
    package let pan: Int32
    package let range: Int32

    package init(volume: Int32 = 100, pan: Int32 = 50, range: Int32 = 200) {
        self.volume = min(1000, max(0, volume))
        self.pan = min(100, max(0, pan))
        self.range = min(200, max(10, range))
    }

    /// Accept only a single explicitly understood volume filter. Other filter
    /// stages and ambiguous parameters are rejected instead of approximated.
    package init(researchFilterText text: String) throws {
        let values = try Self.parameters(text)
        self.init(volume: values["vol"] ?? 100, pan: values["pan"] ?? 50, range: values["range"] ?? 200)
    }

    /// A same-type update changes only parameters that were explicitly supplied.
    package func updating(researchFilterText text: String) throws -> Self {
        let values = try Self.parameters(text)
        return Self(volume: values["vol"] ?? volume, pan: values["pan"] ?? pan, range: values["range"] ?? range)
    }

    private static func parameters(_ text: String) throws -> [String: Int32] {
        guard !text.isEmpty, text.utf8.count <= 8192,
              text.unicodeScalars.allSatisfy({ $0.value < 128 || $0.value == 0xa0 }) else {
            throw ResourceError.rejected("stream_volume_filter_text_outside_profile")
        }
        let compact = String(text.unicodeScalars.filter { ![0x20, 0x09, 0xa0].contains($0.value) })
        let parts = compact.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.first == "volume", parts.count <= 4 else {
            throw ResourceError.rejected("stream_volume_filter_chain_unsupported")
        }
        var values: [String: Int32] = [:]
        for part in parts.dropFirst() {
            let pair = part.split(separator: ":", omittingEmptySubsequences: false)
            guard pair.count == 2, ["vol", "pan", "range"].contains(String(pair[0])),
                  values[String(pair[0])] == nil, !pair[1].isEmpty,
                  pair[1].utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = Int32(pair[1]) else {
                throw ResourceError.rejected("stream_volume_filter_parameter_unsupported")
            }
            values[String(pair[0])] = value
        }
        return values
    }

    /// Interleaved signed 32-bit samples, two values per frame. Integer
    /// multiplication follows the selected x86 path's low 32-bit result.
    package func apply(to samples: inout [Int32]) throws {
        guard samples.count.isMultiple(of: 2), samples.count <= 2_000_000 else {
            throw ResourceError.rejected("stream_volume_filter_sample_count_outside_profile")
        }
        let firstPan = min(100, (100 - pan) * 100 / 50)
        let secondPan = min(100, pan * 100 / 50)
        let firstGain = ((volume * firstPan / 100) << 8) / 100
        let secondGain = ((volume * secondPan / 100) << 8) / 100
        let ceiling = (range << 15) / 100
        for index in stride(from: 0, to: samples.count, by: 2) {
            let first = (samples[index] &* firstGain) / 256
            let second = (samples[index + 1] &* secondGain) / 256
            samples[index] = min(ceiling, max(-ceiling, first))
            samples[index + 1] = min(ceiling, max(-ceiling, second))
        }
    }

    /// Process a bounded block of interleaved signed PCM16 in place. The
    /// final 16-bit saturation is a host conversion candidate.
    package func applyPCM16LittleEndian(to bytes: inout Data) throws {
        guard bytes.count.isMultiple(of: 4), bytes.count <= 1_048_576 else {
            throw ResourceError.rejected("stream_volume_filter_pcm_block_outside_profile")
        }
        let firstPan = min(100, (100 - pan) * 100 / 50)
        let secondPan = min(100, pan * 100 / 50)
        let firstGain = ((volume * firstPan / 100) << 8) / 100
        let secondGain = ((volume * secondPan / 100) << 8) / 100
        let ceiling = (range << 15) / 100
        bytes.withUnsafeMutableBytes { raw in
            let samples = raw.bindMemory(to: UInt8.self)
            for offset in stride(from: 0, to: samples.count, by: 2) {
                let bits = UInt16(samples[offset]) | (UInt16(samples[offset + 1]) << 8)
                let gain = offset.isMultiple(of: 4) ? firstGain : secondGain
                let amplified = (Int32(Int16(bitPattern: bits)) &* gain) / 256
                let clipped = min(ceiling, max(-ceiling, amplified))
                let result = UInt16(bitPattern: Int16(clamping: clipped))
                samples[offset] = UInt8(truncatingIfNeeded: result)
                samples[offset + 1] = UInt8(truncatingIfNeeded: result >> 8)
            }
        }
    }
}
