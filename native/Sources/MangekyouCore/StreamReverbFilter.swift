import Foundation

/// Stateful 44.1 kHz candidate for the selected EXE reverb path.
/// Double intermediates approximate x87 arithmetic and are not equivalent proof.
package struct StreamReverbFilterCandidate: Sendable {
    package let wet: Int32, dry: Int32, delay: Int32, decay: Int32, roomFrequency: Int32
    private let coefficient: Float
    private var buffer = [Int32](repeating: 0, count: 131_072)
    private var readFrame = 0
    private var writeFrame: Int
    private var left: Float = 0, right: Float = 0

    package init(wet: Int32 = 50, dry: Int32 = 50, delay: Int32 = 100,
                 decay: Int32 = 50, roomFrequency: Int32 = 600) {
        self.wet = min(1000, max(0, wet)); self.dry = min(1000, max(0, dry))
        self.delay = min(1000, max(5, delay)); self.decay = min(100, max(0, decay))
        self.roomFrequency = min(40000, max(20, roomFrequency))
        coefficient = Float(2 * sin(Double.pi * Double(self.roomFrequency) / 44100))
        writeFrame = Int((Double(self.delay) * 44100 / 1000 + 0.5).rounded(.towardZero))
    }

    package init(researchFilterText text: String) throws {
        guard !text.isEmpty, text.utf8.count <= 8192,
              text.unicodeScalars.allSatisfy({ $0.value < 128 || $0.value == 0xa0 }) else {
            throw ResourceError.rejected("stream_reverb_filter_text_outside_profile")
        }
        let compact = String(text.unicodeScalars.filter { ![0x20, 0x09, 0xa0].contains($0.value) })
        let parts = compact.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.first == "reverb", parts.count <= 7 else { throw ResourceError.rejected("stream_reverb_filter_unsupported") }
        var values: [String: String] = [:]
        for part in parts.dropFirst() {
            let pair = part.split(separator: ":", omittingEmptySubsequences: false)
            guard pair.count == 2, ["wet", "dry", "delay", "decay", "roomfreq", "mix"].contains(String(pair[0])),
                  values[String(pair[0])] == nil, !pair[1].isEmpty else {
                throw ResourceError.rejected("stream_reverb_filter_parameter_unsupported")
            }
            values[String(pair[0])] = String(pair[1])
        }
        guard values["mix"] == nil || values["mix"] == "normal" else {
            throw ResourceError.rejected("stream_reverb_filter_mix_unsupported")
        }
        func integer(_ key: String, _ fallback: Int32) throws -> Int32 {
            guard let s = values[key] else { return fallback }
            guard s.utf8.allSatisfy({ (48...57).contains($0) }), let n = Int32(s) else {
                throw ResourceError.rejected("stream_reverb_filter_parameter_unsupported")
            }
            return n
        }
        self.init(wet: try integer("wet", 50), dry: try integer("dry", 50),
                  delay: try integer("delay", 100), decay: try integer("decay", 50),
                  roomFrequency: try integer("roomfreq", 600))
    }

    package mutating func apply(to samples: inout [Int32]) throws {
        guard samples.count.isMultiple(of: 2), samples.count <= 2_000_000 else {
            throw ResourceError.rejected("stream_reverb_filter_sample_count_outside_profile")
        }
        var staged = self, output = samples
        let wetGain = (wet << 8) / 100, dryGain = (dry << 8) / 100
        let feedback = ((100 - decay) << 8) / 100
        for i in stride(from: 0, to: samples.count, by: 2) {
            let a = staged.buffer[staged.readFrame * 2], b = staged.buffer[staged.readFrame * 2 + 1]
            staged.readFrame = (staged.readFrame + 1) % 65536
            staged.left = Float(Double(staged.left) + (Double(a) - Double(staged.left)) * Double(coefficient))
            staged.right = Float(Double(staged.right) + (Double(b) - Double(staged.right)) * Double(coefficient))
            let l = Double(staged.left).rounded(.towardZero), r = Double(staged.right).rounded(.towardZero)
            guard l.isFinite, r.isFinite, l >= Double(Int32.min), l <= Double(Int32.max),
                  r >= Double(Int32.min), r <= Double(Int32.max) else {
                throw ResourceError.rejected("stream_reverb_sample_outside_profile")
            }
            let filtered = [Int32(l), Int32(r)]
            for c in 0...1 {
                let input = samples[i + c], value = filtered[c]
                staged.buffer[staged.writeFrame * 2 + c] = input &+ ((value &* feedback) / 256)
                output[i + c] = ((input &* dryGain) &+ (value &* wetGain)) / 256
            }
            staged.writeFrame = (staged.writeFrame + 1) % 65536
        }
        self = staged
        samples = output
    }
}
