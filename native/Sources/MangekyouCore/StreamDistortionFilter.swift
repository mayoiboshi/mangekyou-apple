import Foundation

/// Integer candidate for the selected distortion-filter instruction path.
package struct StreamDistortionFilterCandidate: Sendable {
    package let volume: Int32
    package let range: Int32
    package let foldback: Int32

    package init(volume: Int32 = 140, range: Int32 = 20, foldback: Int32 = 0) {
        self.volume = min(1000, max(0, volume))
        self.range = min(400, max(0, range))
        self.foldback = min(1, max(0, foldback))
    }

    package init(researchFilterText text: String) throws {
        guard !text.isEmpty, text.utf8.count <= 8192,
              text.unicodeScalars.allSatisfy({ $0.value < 128 || $0.value == 0xa0 }) else {
            throw ResourceError.rejected("stream_distortion_filter_text_outside_profile")
        }
        let compact = String(text.unicodeScalars.filter { ![0x20, 0x09, 0xa0].contains($0.value) })
        let parts = compact.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.first == "distortion", parts.count <= 4 else {
            throw ResourceError.rejected("stream_distortion_filter_unsupported")
        }
        var values: [String: Int32] = [:]
        for part in parts.dropFirst() {
            let pair = part.split(separator: ":", omittingEmptySubsequences: false)
            guard pair.count == 2, ["vol", "range", "foldback"].contains(String(pair[0])),
                  values[String(pair[0])] == nil, !pair[1].isEmpty,
                  pair[1].utf8.allSatisfy({ (48...57).contains($0) }), let value = Int32(pair[1]) else {
                throw ResourceError.rejected("stream_distortion_filter_parameter_unsupported")
            }
            values[String(pair[0])] = value
        }
        self.init(volume: values["vol"] ?? 140, range: values["range"] ?? 20,
                  foldback: values["foldback"] ?? 0)
    }

    package func apply(to samples: inout [Int32]) throws {
        guard samples.count.isMultiple(of: 2), samples.count <= 2_000_000 else {
            throw ResourceError.rejected("stream_distortion_filter_sample_count_outside_profile")
        }
        let threshold = (range << 15) / 100
        let gain = (volume << 8) / 100
        for i in samples.indices {
            var sample = samples[i]
            if sample > threshold {
                if foldback == 0 { sample = threshold }
                else { sample = threshold &- min((sample &- threshold) / 2, threshold) }
            }
            if sample < -threshold {
                if foldback == 0 { sample = -threshold }
                else { sample = -threshold &- max((sample &+ threshold) / 2, -threshold) }
            }
            samples[i] = (sample &* gain) / 256
        }
    }
}
