import Foundation

/// Bounded, stateful candidate for the selected fixed executable's 3-band
/// filter path. Double intermediates approximate x87 extended arithmetic;
/// binary and audible equivalence remain unverified.
package struct StreamThreeBandFilterCandidate: Sendable {
    private struct Channel: Sendable {
        var low = [Float](repeating: 0, count: 4)
        var high = [Float](repeating: 0, count: 4)
        var delay1: Float = 0
        var delay2: Float = 0
        var delay3: Float = 0

        mutating func process(_ sample: Int32, lowCoefficient: Float, highCoefficient: Float,
                              lowGain: Int32, midGain: Int32, highGain: Int32) throws -> Int32 {
            let input = Float(sample)
            var nextLow = input, nextHigh = input
            for i in 0..<4 {
                low[i] = Float(Double(low[i]) + (Double(nextLow) - Double(low[i])) * Double(lowCoefficient))
                nextLow = low[i]
                high[i] = Float(Double(high[i]) + (Double(nextHigh) - Double(high[i])) * Double(highCoefficient))
                nextHigh = high[i]
            }
            let highBand = Float(Double(delay3) - Double(high[3]))
            let midBand = Float(Double(delay3) - (Double(highBand) + Double(low[3])))
            let lowScaled = Float(Double(low[3]) * Double(lowGain) * 0.01)
            let midScaled = Float(Double(midBand) * Double(midGain) * 0.01)
            let highScaled = Float(Double(highBand) * Double(highGain) * 0.01)
            delay3 = delay2
            delay2 = delay1
            delay1 = input
            let mixed = Float(Double(lowScaled) + Double(midScaled) + Double(highScaled))
            let value = Double(mixed).rounded(.towardZero)
            guard value.isFinite, value >= Double(Int32.min), value <= Double(Int32.max) else {
                throw ResourceError.rejected("stream_three_band_sample_outside_profile")
            }
            return Int32(value)
        }
    }

    package let lowGain: Int32
    package let midGain: Int32
    package let highGain: Int32
    package let lowFrequency: Int32
    package let highFrequency: Int32
    private let lowCoefficient: Float
    private let highCoefficient: Float
    private var first = Channel()
    private var second = Channel()

    package init(low: Int32 = 100, mid: Int32 = 25, high: Int32 = 0,
                 lowFrequency: Int32 = 880, highFrequency: Int32 = 6400) {
        lowGain = min(1000, max(-1000, low))
        midGain = min(1000, max(-1000, mid))
        highGain = min(1000, max(-1000, high))
        self.lowFrequency = min(24000, max(50, lowFrequency))
        self.highFrequency = min(24000, max(50, highFrequency))
        lowCoefficient = Float(2 * sin(Double.pi * Double(self.lowFrequency) / 44100))
        highCoefficient = Float(2 * sin(Double.pi * Double(self.highFrequency) / 44100))
    }

    package init(researchFilterText text: String) throws {
        guard !text.isEmpty, text.utf8.count <= 8192,
              text.unicodeScalars.allSatisfy({ $0.value < 128 || $0.value == 0xa0 }) else {
            throw ResourceError.rejected("stream_three_band_filter_text_outside_profile")
        }
        let compact = String(text.unicodeScalars.filter { ![0x20, 0x09, 0xa0].contains($0.value) })
        let parts = compact.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.first == "3bandeq", parts.count <= 6 else {
            throw ResourceError.rejected("stream_three_band_filter_unsupported")
        }
        var values: [String: Int32] = [:]
        for part in parts.dropFirst() {
            let pair = part.split(separator: ":", omittingEmptySubsequences: false)
            guard pair.count == 2, ["low", "mid", "high", "lfreq", "hfreq"].contains(String(pair[0])),
                  values[String(pair[0])] == nil, !pair[1].isEmpty,
                  let value = Int32(pair[1]),
                  String(value) == pair[1] else {
                throw ResourceError.rejected("stream_three_band_filter_parameter_unsupported")
            }
            values[String(pair[0])] = value
        }
        self.init(low: values["low"] ?? 100, mid: values["mid"] ?? 25, high: values["high"] ?? 0,
                  lowFrequency: values["lfreq"] ?? 880, highFrequency: values["hfreq"] ?? 6400)
    }

    /// Two Int32 samples per frame. State and samples commit only when every
    /// sample in the bounded block is representable.
    package mutating func apply(to samples: inout [Int32]) throws {
        guard samples.count.isMultiple(of: 2), samples.count <= 2_000_000 else {
            throw ResourceError.rejected("stream_three_band_sample_count_outside_profile")
        }
        var staged = self
        var output = samples
        for index in stride(from: 0, to: samples.count, by: 2) {
            output[index] = try staged.first.process(samples[index], lowCoefficient: lowCoefficient,
                highCoefficient: highCoefficient, lowGain: lowGain, midGain: midGain, highGain: highGain)
            output[index + 1] = try staged.second.process(samples[index + 1], lowCoefficient: lowCoefficient,
                highCoefficient: highCoefficient, lowGain: lowGain, midGain: midGain, highGain: highGain)
        }
        self = staged
        samples = output
    }
}
