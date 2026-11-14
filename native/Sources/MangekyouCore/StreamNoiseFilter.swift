import Foundation

/// Bounded deterministic candidate for the selected fixed EXE noise path.
package struct StreamNoiseFilterCandidate: Sendable {
    package enum Blend: String, Sendable { case replace, add, mul }
    package let amount: Int32
    package let volume: Int32
    package let blend: Blend
    private var state: UInt32 = 0x34ab_cd0e

    package init(amount: Int32 = 25, volume: Int32 = 100, blend: Blend = .mul) {
        self.amount = min(100, max(0, amount))
        self.volume = min(100, max(0, volume))
        self.blend = blend
    }

    package init(researchFilterText text: String) throws {
        guard !text.isEmpty, text.utf8.count <= 8192,
              text.unicodeScalars.allSatisfy({ $0.value < 128 || $0.value == 0xa0 }) else {
            throw ResourceError.rejected("stream_noise_filter_text_outside_profile")
        }
        let compact = String(text.unicodeScalars.filter { ![0x20, 0x09, 0xa0].contains($0.value) })
        let parts = compact.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.first == "noise", parts.count <= 4 else {
            throw ResourceError.rejected("stream_noise_filter_unsupported")
        }
        var values: [String: String] = [:]
        for part in parts.dropFirst() {
            let pair = part.split(separator: ":", omittingEmptySubsequences: false)
            guard pair.count == 2, ["amount", "vol", "blend"].contains(String(pair[0])),
                  values[String(pair[0])] == nil, !pair[1].isEmpty else {
                throw ResourceError.rejected("stream_noise_filter_parameter_unsupported")
            }
            values[String(pair[0])] = String(pair[1])
        }
        func integer(_ key: String, default fallback: Int32) throws -> Int32 {
            guard let s = values[key] else { return fallback }
            guard s.utf8.allSatisfy({ (48...57).contains($0) }), let n = Int32(s) else {
                throw ResourceError.rejected("stream_noise_filter_parameter_unsupported")
            }
            return n
        }
        let blend: Blend
        switch values["blend"] ?? "mul" {
        case "mul": blend = .mul
        case "add": blend = .add
        case "replace": blend = .replace
        default: throw ResourceError.rejected("stream_noise_filter_blend_unsupported")
        }
        self.init(amount: try integer("amount", default: 25),
                  volume: try integer("vol", default: 100), blend: blend)
    }

    package mutating func apply(to samples: inout [Int32]) throws {
        guard samples.count.isMultiple(of: 2), samples.count <= 2_000_000 else {
            throw ResourceError.rejected("stream_noise_filter_sample_count_outside_profile")
        }
        let mix = (amount << 8) / 100, dry = 256 - mix, gain = (volume << 8) / 100
        for i in stride(from: 0, to: samples.count, by: 2) {
            state = state &* 1_103_515_245 &+ 12_345
            let random = (Int32(state & 0xffff) - 32768) &* gain / 256
            for channel in i...(i + 1) {
                let input = samples[channel]
                let wet: Int32
                switch blend {
                case .replace: wet = random
                case .add: wet = random &+ input
                case .mul: wet = ((random / 16) &* input) / 2048
                }
                samples[channel] = ((input &* dry) &+ (wet &* mix)) / 256
            }
        }
    }
}
