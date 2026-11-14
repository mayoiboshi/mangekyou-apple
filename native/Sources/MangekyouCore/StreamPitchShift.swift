import Foundation

/// Spectral candidate derived from selected fixed EXE paths. Swift math and
/// Float writebacks approximate x87/FFT behavior; equivalence is unverified.
package struct StreamPitchShiftCandidate: Sendable {
    private static let size = 2048, hop = 512, latency = 1536
    private static let window = (0..<size).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(size))) }
    private let pitch: Int32, wet: Int32, dry: Int32
    private var input = [Float](repeating: 0, count: size)
    private var output = [Float](repeating: 0, count: size)
    private var accumulated = [Float](repeating: 0, count: size * 2)
    private var lastPhase = [Float](repeating: 0, count: size / 2 + 1)
    private var sumPhase = [Float](repeating: 0, count: size / 2 + 1)
    private var cursor = latency

    package init(pitch: Int32 = 150, wet: Int32 = 70, dry: Int32 = 0) {
        self.pitch = min(400, max(10, pitch)); self.wet = min(200, max(0, wet)); self.dry = min(200, max(0, dry))
    }

    package init(researchFilterText text: String) throws {
        guard !text.isEmpty, text.utf8.count <= 8192,
              text.unicodeScalars.allSatisfy({ $0.value < 128 || $0.value == 0xa0 }) else {
            throw ResourceError.rejected("stream_pitch_filter_text_outside_profile")
        }
        let compact = String(text.unicodeScalars.filter { ![0x20, 0x09, 0xa0].contains($0.value) })
        let parts = compact.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.first == "pitchshift", parts.count <= 5 else { throw ResourceError.rejected("stream_pitch_filter_unsupported") }
        var values: [String: String] = [:]
        for part in parts.dropFirst() {
            let pair = part.split(separator: ":", omittingEmptySubsequences: false)
            guard pair.count == 2, ["pitch", "wet", "dry", "mix"].contains(String(pair[0])),
                  values[String(pair[0])] == nil, !pair[1].isEmpty else {
                throw ResourceError.rejected("stream_pitch_filter_parameter_unsupported")
            }
            values[String(pair[0])] = String(pair[1])
        }
        guard values["mix"] == nil || values["mix"] == "normal" else { throw ResourceError.rejected("stream_pitch_filter_mix_unsupported") }
        func integer(_ key: String, _ fallback: Int32) throws -> Int32 {
            guard let s = values[key] else { return fallback }
            guard s.utf8.allSatisfy({ (48...57).contains($0) }), let n = Int32(s) else {
                throw ResourceError.rejected("stream_pitch_filter_parameter_unsupported")
            }
            return n
        }
        self.init(pitch: try integer("pitch", 150), wet: try integer("wet", 70), dry: try integer("dry", 0))
    }

    private static func fft(_ real: inout [Float], _ imaginary: inout [Float], inverse: Bool) {
        let n = size
        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while (j & bit) != 0 { j ^= bit; bit >>= 1 }
            j ^= bit
            if i < j { real.swapAt(i, j); imaginary.swapAt(i, j) }
        }
        var width = 2
        while width <= n {
            let angle = (inverse ? 2.0 : -2.0) * Double.pi / Double(width)
            let cw = Float(cos(angle)), sw = Float(sin(angle))
            for base in stride(from: 0, to: n, by: width) {
                var wr: Float = 1, wi: Float = 0
                for k in 0..<(width / 2) {
                    let a = base + k, b = a + width / 2
                    let tr = Float(Double(real[b]) * Double(wr) - Double(imaginary[b]) * Double(wi))
                    let ti = Float(Double(imaginary[b]) * Double(wr) + Double(real[b]) * Double(wi))
                    let ar = real[a], ai = imaginary[a]
                    real[a] = Float(Double(ar) + Double(tr)); imaginary[a] = Float(Double(ai) + Double(ti))
                    real[b] = Float(Double(ar) - Double(tr)); imaginary[b] = Float(Double(ai) - Double(ti))
                    let next = Float(Double(wr) * Double(cw) - Double(wi) * Double(sw))
                    wi = Float(Double(wi) * Double(cw) + Double(wr) * Double(sw)); wr = next
                }
            }
            width *= 2
        }
    }

    private mutating func transform() throws {
        let n = Self.size, half = n / 2, hop = Self.hop
        let expected = Float(2 * Double.pi * Double(hop) / Double(n)), binHz = Float(44100.0 / Double(n))
        let scale = Float(Double(pitch) * 0.01)
        var real = [Float](repeating: 0, count: n), imag = real
        for i in 0..<n { real[i] = input[i] * Self.window[i] }
        Self.fft(&real, &imag, inverse: false)
        var magnitude = [Float](repeating: 0, count: half + 1), frequency = magnitude
        for bin in 0...half {
            let re = Double(real[bin]), im = Double(imag[bin])
            let amplitude = Float(2 * sqrt(re * re + im * im))
            let phase = atan2(im, re)
            var delta = phase - Double(lastPhase[bin]) - Double(bin) * Double(expected)
            lastPhase[bin] = Float(phase)
            let q = Int((delta / Double.pi).rounded(.towardZero))
            let even = q >= 0 ? q + (q & 1) : q - (q & 1)
            delta -= Double(even) * Double.pi
            let trueBin = Double(bin) + Double(4) * delta / (2 * Double.pi)
            let target = Int((Double(bin) * Double(scale)).rounded(.towardZero))
            if target <= half {
                magnitude[target] = Float(Double(magnitude[target]) + Double(amplitude))
                frequency[target] = Float(trueBin * Double(binHz) * Double(scale))
            }
        }
        real = [Float](repeating: 0, count: n); imag = real
        for bin in 0...half {
            let deviation = (Double(frequency[bin]) - Double(bin) * Double(binHz)) / Double(binHz)
            let phase = Double(sumPhase[bin]) + Double(bin) * Double(expected) + 2 * Double.pi * deviation / 4
            guard phase.isFinite else { throw ResourceError.rejected("stream_pitch_state_outside_profile") }
            sumPhase[bin] = Float(phase)
            real[bin] = Float(Double(magnitude[bin]) * cos(phase))
            imag[bin] = Float(Double(magnitude[bin]) * sin(phase))
        }
        Self.fft(&real, &imag, inverse: true)
        for i in 0..<n {
            accumulated[i] = Float(Double(accumulated[i]) + 2 * Double(Self.window[i]) * Double(real[i]) / Double(half * 4))
        }
        for i in 0..<hop { output[i] = accumulated[i] }
        for i in 0..<n { accumulated[i] = accumulated[i + hop] }
        for i in 0..<Self.latency { input[i] = input[i + hop] }
    }

    package mutating func apply(to samples: inout [Int32]) throws {
        guard samples.count.isMultiple(of: 2), samples.count <= 2_000_000 else {
            throw ResourceError.rejected("stream_pitch_filter_sample_count_outside_profile")
        }
        var staged = self, result = samples
        let wetGain = (wet << 8) / 100, dryGain = (dry << 8) / 100
        for index in stride(from: 0, to: samples.count, by: 2) {
            let mono = (samples[index] &+ samples[index + 1]) / 2
            staged.input[staged.cursor] = Float(Double(mono) / 32768)
            let shifted = Double(staged.output[staged.cursor - Self.latency]) * 32768 + 0.5
            guard shifted.isFinite, shifted >= Double(Int32.min), shifted <= Double(Int32.max) else {
                throw ResourceError.rejected("stream_pitch_sample_outside_profile")
            }
            let processed = Int32(shifted.rounded(.towardZero))
            for c in 0...1 { result[index + c] = ((samples[index + c] &* dryGain) &+ (processed &* wetGain)) / 256 }
            staged.cursor += 1
            if staged.cursor >= Self.size { staged.cursor = Self.latency; try staged.transform() }
        }
        self = staged; samples = result
    }
}
