import Foundation

/// Candidate for the selected fixed EXE chorus path; x87 and FSIN are approximated.
package struct StreamChorusFilterCandidate: Sendable {
    private static let sine = (0..<4096).map { Float(sin(Double($0) * 6.2831853 / 4096)) }
    private let wet: Int32, dry: Int32, decay: Int32, rate: Int32, depth: Int32
    private let stereo: Bool
    private let delayFrames: Int
    private var buffer = [Int32](repeating: 0, count: 131_072)
    private var readFrame = 0
    private var writeFrame: Int
    private var phase: Float = 0

    package init(wet: Int32 = 50, dry: Int32 = 50, delay: Int32 = 40,
                 decay: Int32 = 50, rate: Int32 = 80, depth: Int32 = 30, stereo: Bool = false) {
        self.wet = min(1000, max(0, wet)); self.dry = min(1000, max(0, dry))
        self.decay = min(100, max(0, decay)); self.rate = min(2000, max(0, rate))
        self.depth = min(100, max(0, depth)); self.stereo = stereo
        let boundedDelay = min(1000, max(5, delay))
        delayFrames = Int((Double(boundedDelay) * 44100 / 1000 + 0.5).rounded(.towardZero))
        writeFrame = delayFrames
    }

    package init(researchFilterText text: String) throws {
        guard !text.isEmpty, text.utf8.count <= 8192,
              text.unicodeScalars.allSatisfy({ $0.value < 128 || $0.value == 0xa0 }) else {
            throw ResourceError.rejected("stream_chorus_filter_text_outside_profile")
        }
        let compact = String(text.unicodeScalars.filter { ![0x20, 0x09, 0xa0].contains($0.value) })
        let parts = compact.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.first == "chorus", parts.count <= 8 else { throw ResourceError.rejected("stream_chorus_filter_unsupported") }
        var values: [String: String] = [:]
        for part in parts.dropFirst() {
            let pair = part.split(separator: ":", omittingEmptySubsequences: false)
            guard pair.count == 2, ["wet", "dry", "delay", "decay", "rate", "depth", "mix"].contains(String(pair[0])),
                  values[String(pair[0])] == nil, !pair[1].isEmpty else {
                throw ResourceError.rejected("stream_chorus_filter_parameter_unsupported")
            }
            values[String(pair[0])] = String(pair[1])
        }
        guard ["normal", "stereo"].contains(values["mix"] ?? "normal") else {
            throw ResourceError.rejected("stream_chorus_filter_mix_unsupported")
        }
        func integer(_ key: String, _ fallback: Int32) throws -> Int32 {
            guard let s = values[key] else { return fallback }
            guard s.utf8.allSatisfy({ (48...57).contains($0) }), let n = Int32(s) else {
                throw ResourceError.rejected("stream_chorus_filter_parameter_unsupported")
            }
            return n
        }
        self.init(wet: try integer("wet", 50), dry: try integer("dry", 50),
                  delay: try integer("delay", 40), decay: try integer("decay", 50),
                  rate: try integer("rate", 80), depth: try integer("depth", 30), stereo: values["mix"] == "stereo")
    }

    package mutating func apply(to samples: inout [Int32]) throws {
        guard samples.count.isMultiple(of: 2), samples.count <= 2_000_000 else {
            throw ResourceError.rejected("stream_chorus_filter_sample_count_outside_profile")
        }
        var staged = self, output = samples
        let wetGain = (wet << 8) / 100, dryGain = (dry << 8) / 100
        let feedback = ((100 - decay) << 8) / 100
        let step = Float(Double(rate) * 0.01)
        let amplitude = min(Float(delayFrames), Float(Double(Float(Double(depth) * 44.1)) * 0.5))
        for i in stride(from: 0, to: samples.count, by: 2) {
            let index = Int((Double(staged.phase) * 4096 / 44100 + 0.5).rounded(.towardZero)) & 4095
            let modulation = Float(Double(amplitude) * Double(Self.sine[index]))
            staged.phase = Float(Double(staged.phase) + Double(step))
            if staged.phase > 44100 { staged.phase = Float(Double(staged.phase) - 44100) }
            let position = Int((Double(staged.readFrame) + Double(modulation)).rounded(.towardZero)) & 65535
            let next = (position + 1) & 65535
            let shifted = Float(Double(modulation) + 65536)
            let fraction = Float(Double(shifted) - Double(Int(shifted)))
            let weight = Int32((Double(fraction) * 256).rounded(.towardZero))
            var wetSamples = [Int32](repeating: 0, count: 2)
            for c in 0...1 {
                let a = staged.buffer[position * 2 + c], b = staged.buffer[next * 2 + c]
                wetSamples[c] = ((a &* (256 - weight)) &+ (b &* weight)) / 256
            }
            staged.readFrame = (staged.readFrame + 1) & 65535
            // The selected instruction sequence stores the left input and left
            // feedback into both buffer channels; this remains a static candidate.
            let stored = samples[i] &+ ((wetSamples[0] &* feedback) / 256)
            staged.buffer[staged.writeFrame * 2] = stored
            staged.buffer[staged.writeFrame * 2 + 1] = stored
            staged.writeFrame = (staged.writeFrame + 1) & 65535
            output[i] = ((samples[i] &* dryGain) &+ (wetSamples[0] &* wetGain)) / 256
            let rightGain = stereo ? -wetGain : wetGain
            output[i + 1] = ((samples[i + 1] &* dryGain) &+ (wetSamples[1] &* rightGain)) / 256
        }
        self = staged; samples = output
    }
}
