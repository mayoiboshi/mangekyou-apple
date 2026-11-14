import Foundation

/// Restricted research chain; preserves signed 32-bit values between stages.
package struct StreamFilterChainCandidate: Sendable {
    private enum Stage: Sendable {
        case equalizer(StreamThreeBandFilterCandidate)
        case volume(StreamVolumeFilterCandidate)
        case distortion(StreamDistortionFilterCandidate)
        case noise(StreamNoiseFilterCandidate)
        case reverb(StreamReverbFilterCandidate)
        case chorus(StreamChorusFilterCandidate)
        case pitchShift(StreamPitchShiftCandidate)
    }
    private var stages: [Stage]
    package var stageCount: Int { stages.count }

    package init(researchFilterText text: String) throws {
        guard !text.isEmpty, text.utf8.count <= 8192 else {
            throw ResourceError.rejected("stream_filter_chain_text_outside_profile")
        }
        let parts = text.split(separator: "\\", omittingEmptySubsequences: false)
        guard (1...16).contains(parts.count) else {
            throw ResourceError.rejected("stream_filter_chain_length_outside_profile")
        }
        stages = try parts.map { part in
            let stage = String(part)
            let name = stage.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let compactName = String(name.unicodeScalars.filter { ![0x20, 0x09, 0xa0].contains($0.value) })
            switch compactName {
            case "3bandeq": return .equalizer(try StreamThreeBandFilterCandidate(researchFilterText: stage))
            case "volume": return .volume(try StreamVolumeFilterCandidate(researchFilterText: stage))
            case "distortion": return .distortion(try StreamDistortionFilterCandidate(researchFilterText: stage))
            case "noise": return .noise(try StreamNoiseFilterCandidate(researchFilterText: stage))
            case "reverb": return .reverb(try StreamReverbFilterCandidate(researchFilterText: stage))
            case "chorus": return .chorus(try StreamChorusFilterCandidate(researchFilterText: stage))
            case "pitchshift": return .pitchShift(try StreamPitchShiftCandidate(researchFilterText: stage))
            default: throw ResourceError.rejected("stream_filter_chain_stage_unsupported")
            }
        }
    }

    package mutating func apply(to samples: inout [Int32]) throws {
        var staged = stages, output = samples
        for index in staged.indices {
            switch staged[index] {
            case .equalizer(var filter):
                try filter.apply(to: &output)
                staged[index] = .equalizer(filter)
            case .volume(let filter):
                try filter.apply(to: &output)
            case .distortion(let filter):
                try filter.apply(to: &output)
            case .noise(var filter):
                try filter.apply(to: &output)
                staged[index] = .noise(filter)
            case .reverb(var filter):
                try filter.apply(to: &output)
                staged[index] = .reverb(filter)
            case .chorus(var filter):
                try filter.apply(to: &output)
                staged[index] = .chorus(filter)
            case .pitchShift(var filter):
                try filter.apply(to: &output)
                staged[index] = .pitchShift(filter)
            }
        }
        stages = staged
        samples = output
    }

    /// Host conversion candidate: retain Int32 between stages and saturate only
    /// after the final stage. A failed block leaves both state and input intact.
    package mutating func applyPCM16LittleEndian(to bytes: inout Data) throws {
        guard bytes.count.isMultiple(of: 4), bytes.count <= 1_048_576 else {
            throw ResourceError.rejected("stream_filter_chain_pcm_block_outside_profile")
        }
        var samples: [Int32] = []
        samples.reserveCapacity(bytes.count / 2)
        for offset in stride(from: 0, to: bytes.count, by: 2) {
            let bits = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
            samples.append(Int32(Int16(bitPattern: bits)))
        }
        var staged = self
        try staged.apply(to: &samples)
        var output = Data(capacity: bytes.count)
        for sample in samples {
            var value = Int16(clamping: sample).littleEndian
            withUnsafeBytes(of: &value) { output.append(contentsOf: $0) }
        }
        self = staged
        bytes = output
    }
}
