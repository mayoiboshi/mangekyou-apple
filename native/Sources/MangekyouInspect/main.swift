import Foundation
import CoreGraphics
import ImageIO
import MangekyouCore
import MangekyouMedia
import CryptoKit

struct ImageCheck: Encodable {
    let relativePath: String
    let sourceSHA256: String?
    let status: EvidenceStatus
    let width: Int?
    let height: Int?
    let notes: [String]
    let issue: String?
    let originalRendererEquivalence: EvidenceStatus = .notTested
}
struct InspectReport: Encodable {
    let inventory: Inventory
    let imageChecks: [ImageCheck]
    let imageDecodeStatus: EvidenceStatus
}

struct SaveStateCheck: Encodable {
    let decodedLength: Int
    let threadVersion: Int32
    let routineCount: Int32
    let readerCursor: SaveReaderCursor
    let routineTextAndIntegerStatus: EvidenceStatus
    let decodedResultIntegerSnapshotCount: Int
    var resolvedLabel: ScriptLocation?
    var resolvedSourcePosition: ScriptLocation?
    var sourcePositionIssue: String?
    var resolvedCommand: ScriptLocation?
    var resolvedResumeRecord: ScriptLocation?
    var resolvedResumeRecordKind: ScriptRecordKind?
    var resolvedCommandControlDepth: Int?
    var commandBoundaryStatus: EvidenceStatus = .notTested
    var stateSeedInference: EvidenceStatus?
    var slotHeaderVerification: EvidenceStatus?
    var statePrefix: SaveStatePrefix?
    var displayState: SaveStatePrefix.DisplayState?
    var engineState: SaveEngineState?
    var engineStateIssue: String?
    var calValArrays: SaveVariableArrays.Summary?
    let restoreStatus: EvidenceStatus

    init(_ data: Data) throws {
        decodedLength = data.count
        readerCursor = try SaveReaderCursor(threadState: data, inspectLegacyThread: true)
        threadVersion = data.withUnsafeBytes {
            Int32(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: Int32.self))
        }
        routineCount = Int32(readerCursor.routines.count)
        restoreStatus = threadVersion < 10 ? .unsupported : .notTested
        decodedResultIntegerSnapshotCount = try readerCursor.validateRoutinePayloads(in: data)
        routineTextAndIntegerStatus = readerCursor.routines.isEmpty ? .notTested : .verified
    }
}

struct SaveThumbnailCheck: Encodable {
    let present: Bool
    let width: Int?
    let height: Int?
}

struct TwoTextureCheck: Encodable {
    let status: EvidenceStatus = .verified
    let width: Int
    let height: Int
    let changedPixels: Int
    let baseTextureChangedPixels: Int?
    let twoTextureChangedPixels: Int
    let twoTextureChangedOnNonOpaquePixels: Int
    let twoTextureChangedPixelsSHA256: String
    let canvasSHA256: String
    let originalRendererEquivalence: EvidenceStatus = .notTested
}

@main struct Inspect {
    static func main() {
        do {
            var args = Array(CommandLine.arguments.dropFirst())
            if args.first == "--probe-timescale-stream" {
                guard args.count == 7, args[1] == "--assets-dir", args[3] == "--pcm",
                      args[5] == "--pitch", let pitch = Int32(args[6]) else {
                    throw ResourceError.rejected("invalid_timescale_stream_probe_arguments")
                }
                let directory = try SafeDirectory(URL(fileURLWithPath: args[2], isDirectory: true))
                let bytes = try directory.read(args[4], limit: 4_000_000)
                let converted = try StreamTimeScaleCandidate.interpolateStream(bytes, pitch: pitch)
                let report: [String: Any] = ["status": "inferred", "sourceSHA256": bytes.sha256Hex,
                    "outputSHA256": converted.pcm.sha256Hex, "inputFrames": bytes.count / 4,
                    "outputFrames": converted.outputFrames, "blocks": converted.blocks,
                    "shortReadBlocks": converted.shortReadBlocks, "pitch": pitch,
                    "inputFormat": "signed_16_le_stereo", "outputFormat": "signed_16_le_stereo",
                    "originalSchedulerEquivalence": "not_tested", "originalDecoderEquivalence": "not_tested",
                    "originalInterpolationEquivalence": "not_tested", "playback": "not_tested"]
                print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
                return
            }
            if args.first == "--probe-timescale-resampling" {
                guard args.count == 7, args[1] == "--assets-dir", args[3] == "--pcm",
                      args[5] == "--output-frames", let outputFrames = Int(args[6]) else {
                    throw ResourceError.rejected("invalid_timescale_probe_arguments")
                }
                let directory = try SafeDirectory(URL(fileURLWithPath: args[2], isDirectory: true))
                let bytes = try directory.read(args[4], limit: 49152)
                guard !bytes.isEmpty, bytes.count.isMultiple(of: 4) else {
                    throw ResourceError.rejected("timescale_probe_pcm_outside_profile")
                }
                var input: [Int16] = []
                input.reserveCapacity(bytes.count / 2)
                for offset in stride(from: 0, to: bytes.count, by: 2) {
                    let bits = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
                    input.append(Int16(bitPattern: bits))
                }
                let samples = try StreamTimeScaleCandidate.interpolate(input, outputFrames: outputFrames)
                var output = Data(capacity: samples.count * 2)
                for sample in samples {
                    var value = sample.littleEndian
                    withUnsafeBytes(of: &value) { output.append(contentsOf: $0) }
                }
                let report: [String: Any] = ["status": "inferred", "sourceSHA256": bytes.sha256Hex,
                    "outputSHA256": output.sha256Hex, "inputFrames": input.count / 2, "outputFrames": outputFrames,
                    "inputFormat": "signed_16_le_stereo", "outputFormat": "signed_16_le_stereo",
                    "originalSchedulerEquivalence": "not_tested", "originalDecoderEquivalence": "not_tested",
                    "originalInterpolationEquivalence": "not_tested", "playback": "not_tested"]
                print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
                return
            }
            if args.first == "--probe-stream-filter-chain" {
                guard (args.count == 9 || (args.count == 11 && args[9] == "--research-wav")),
                      args[1] == "--assets-dir", args[3] == "--pcm",
                      args[5] == "--filter", args[7] == "--block-frames",
                      let blockFrames = Int(args[8]), (1...65536).contains(blockFrames) else {
                    throw ResourceError.rejected("invalid_stream_filter_chain_probe_arguments")
                }
                let directory = try SafeDirectory(URL(fileURLWithPath: args[2], isDirectory: true))
                let bytes = try directory.read(args[4], limit: 4_000_000)
                guard !bytes.isEmpty, bytes.count.isMultiple(of: 4) else {
                    throw ResourceError.rejected("stream_filter_chain_probe_pcm_outside_profile")
                }
                var chain = try StreamFilterChainCandidate(researchFilterText: args[6])
                var output = Data(capacity: bytes.count * 2)
                var pcm16 = Data(capacity: bytes.count)
                var clipped = 0
                var changed = 0, blocks = 0
                for start in stride(from: 0, to: bytes.count, by: blockFrames * 4) {
                    let end = min(bytes.count, start + blockFrames * 4)
                    var samples: [Int32] = []
                    samples.reserveCapacity((end - start) / 2)
                    for offset in stride(from: start, to: end, by: 2) {
                        let bits = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
                        samples.append(Int32(Int16(bitPattern: bits)))
                    }
                    let original = samples
                    try chain.apply(to: &samples)
                    changed += zip(original, samples).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
                    for sample in samples {
                        var little = sample.littleEndian
                        withUnsafeBytes(of: &little) { output.append(contentsOf: $0) }
                        if args.count == 11 {
                            if sample < -32768 || sample > 32767 { clipped += 1 }
                            var value = Int16(clamping: sample).littleEndian
                            withUnsafeBytes(of: &value) { pcm16.append(contentsOf: $0) }
                        }
                    }
                    blocks += 1
                }
                var report: [String: Any] = ["status": "inferred", "sourceSHA256": bytes.sha256Hex,
                    "outputSHA256": output.sha256Hex, "frameCount": bytes.count / 4,
                    "changedSamples": changed, "blockFrames": blockFrames, "blockCount": blocks,
                    "stageCount": chain.stageCount, "coefficientSampleRateAssumption": 44100,
                    "inputFormat": "signed_16_le_stereo", "outputFormat": "signed_32_le_stereo",
                    "originalDecoderEquivalence": "not_tested", "originalFilterEquivalence": "not_tested",
                    "playback": "not_tested"]
                if args.count == 11 {
                    let parts = try SafeDirectory.components(args[10])
                    var url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                        .appendingPathComponent("private", isDirectory: true)
                    for part in parts.dropLast() { url.appendPathComponent(part, isDirectory: true) }
                    url = url.standardizedFileURL
                    let outComponents = url.pathComponents.map { $0.lowercased() }
                    let inComponents = directory.root.standardizedFileURL.pathComponents.map { $0.lowercased() }
                    guard !outComponents.starts(with: inComponents), let name = parts.last else {
                        throw ResourceError.rejected("research_output_inside_input_directory")
                    }
                    var wav = Data("RIFF".utf8)
                    func append16(_ v: UInt16) { var n = v.littleEndian; withUnsafeBytes(of: &n) { wav.append(contentsOf: $0) } }
                    func append32(_ v: UInt32) { var n = v.littleEndian; withUnsafeBytes(of: &n) { wav.append(contentsOf: $0) } }
                    let size = UInt32(pcm16.count)
                    append32(36 + size); wav.append(Data("WAVEfmt ".utf8)); append32(16); append16(1); append16(2)
                    append32(44100); append32(176400); append16(4); append16(16); wav.append(Data("data".utf8)); append32(size)
                    wav.append(pcm16)
                    try SafeDirectory(url).writeNew(name, data: wav, limit: 4_000_044)
                    report["researchWavSHA256"] = wav.sha256Hex
                    report["researchWavClippedSamples"] = clipped
                    report["researchWavRateAssumption"] = 44100
                }
                print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
                return
            }
            if args.first == "--probe-stream-three-band" {
                guard args.count == 17, args[1] == "--assets-dir", args[3] == "--pcm",
                      args[5] == "--low", let low = Int32(args[6]),
                      args[7] == "--mid", let mid = Int32(args[8]),
                      args[9] == "--high", let high = Int32(args[10]),
                      args[11] == "--low-frequency", let lowFrequency = Int32(args[12]),
                      args[13] == "--high-frequency", let highFrequency = Int32(args[14]),
                      args[15] == "--block-frames", let blockFrames = Int(args[16]),
                      (1...65536).contains(blockFrames) else {
                    throw ResourceError.rejected("invalid_stream_three_band_probe_arguments")
                }
                let directory = try SafeDirectory(URL(fileURLWithPath: args[2], isDirectory: true))
                let bytes = try directory.read(args[4], limit: 4_000_000)
                guard !bytes.isEmpty, bytes.count.isMultiple(of: 4) else {
                    throw ResourceError.rejected("stream_three_band_probe_pcm_outside_profile")
                }
                var filter = StreamThreeBandFilterCandidate(low: low, mid: mid, high: high,
                    lowFrequency: lowFrequency, highFrequency: highFrequency)
                var output = Data(capacity: bytes.count * 2)
                var changed = 0, blocks = 0
                for start in stride(from: 0, to: bytes.count, by: blockFrames * 4) {
                    let end = min(bytes.count, start + blockFrames * 4)
                    var samples: [Int32] = []
                    samples.reserveCapacity((end - start) / 2)
                    for offset in stride(from: start, to: end, by: 2) {
                        let value = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
                        samples.append(Int32(Int16(bitPattern: value)))
                    }
                    let original = samples
                    try filter.apply(to: &samples)
                    changed += zip(original, samples).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
                    for sample in samples {
                        var little = sample.littleEndian
                        withUnsafeBytes(of: &little) { output.append(contentsOf: $0) }
                    }
                    blocks += 1
                }
                let report: [String: Any] = ["status": "inferred", "sourceSHA256": bytes.sha256Hex,
                    "outputSHA256": output.sha256Hex, "frameCount": bytes.count / 4,
                    "changedSamples": changed, "blockFrames": blockFrames, "blockCount": blocks,
                    "low": filter.lowGain, "mid": filter.midGain, "high": filter.highGain,
                    "lowFrequency": filter.lowFrequency, "highFrequency": filter.highFrequency,
                    "coefficientSampleRateAssumption": 44100, "inputFormat": "signed_16_le_stereo",
                    "outputFormat": "signed_32_le_stereo", "originalDecoderEquivalence": "not_tested",
                    "originalFilterEquivalence": "not_tested", "playback": "not_tested"]
                print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
                return
            }
            if args.first == "--probe-stream-volume-filter" {
                guard args.count >= 7, args[1] == "--assets-dir", args[3] == "--pcm", args[5] == "--filter",
                      (args.count - 7).isMultiple(of: 2) else {
                    throw ResourceError.rejected("invalid_stream_volume_probe_arguments")
                }
                var updateFilter: String?, wavPath: String?, sampleRate: Int?, updateFrame: Int?
                for index in stride(from: 7, to: args.count, by: 2) {
                    switch args[index] {
                    case "--update-filter" where updateFilter == nil: updateFilter = args[index + 1]
                    case "--research-wav" where wavPath == nil: wavPath = args[index + 1]
                    case "--update-frame" where updateFrame == nil:
                        guard let frame = Int(args[index + 1]), (0...1_000_000).contains(frame) else {
                            throw ResourceError.rejected("stream_volume_probe_update_frame_outside_profile")
                        }
                        updateFrame = frame
                    case "--sample-rate" where sampleRate == nil:
                        guard let rate = Int(args[index + 1]), (8_000...192_000).contains(rate) else {
                            throw ResourceError.rejected("stream_volume_probe_sample_rate_outside_profile")
                        }
                        sampleRate = rate
                    default: throw ResourceError.rejected("invalid_stream_volume_probe_arguments")
                    }
                }
                guard (wavPath == nil) == (sampleRate == nil) else {
                    throw ResourceError.rejected("stream_volume_probe_wav_requires_sample_rate")
                }
                guard updateFrame == nil || updateFilter != nil else {
                    throw ResourceError.rejected("stream_volume_probe_frame_requires_update")
                }
                let directory = try SafeDirectory(URL(fileURLWithPath: args[2], isDirectory: true))
                var destination: SafeDirectory?, destinationName: String?
                if let wavPath {
                    let parts = try SafeDirectory.components(wavPath)
                    var url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                        .appendingPathComponent("private", isDirectory: true)
                    for part in parts.dropLast() { url.appendPathComponent(part, isDirectory: true) }
                    url = url.standardizedFileURL
                    let outputComponents = url.pathComponents.map { $0.lowercased() }
                    let inputComponents = directory.root.standardizedFileURL.pathComponents.map { $0.lowercased() }
                    guard !outputComponents.starts(with: inputComponents) else {
                        throw ResourceError.rejected("research_output_inside_input_directory")
                    }
                    destination = try SafeDirectory(url)
                    destinationName = parts.last
                }
                let bytes = try directory.read(args[4], limit: 4_000_000)
                guard !bytes.isEmpty, bytes.count.isMultiple(of: 4) else {
                    throw ResourceError.rejected("stream_volume_probe_pcm_outside_profile")
                }
                let initialFilter = try StreamVolumeFilterCandidate(researchFilterText: args[6])
                let filter = try updateFilter.map { try initialFilter.updating(researchFilterText: $0) } ?? initialFilter
                var samples: [Int32] = []
                samples.reserveCapacity(bytes.count / 2)
                for offset in stride(from: 0, to: bytes.count, by: 2) {
                    let value = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
                    samples.append(Int32(Int16(bitPattern: value)))
                }
                let original = samples
                let split = (updateFrame ?? 0) * 2
                guard split <= samples.count else {
                    throw ResourceError.rejected("stream_volume_probe_update_frame_outside_profile")
                }
                if split == 0 {
                    try filter.apply(to: &samples)
                } else {
                    var before = Array(samples[..<split]), after = Array(samples[split...])
                    try initialFilter.apply(to: &before)
                    try filter.apply(to: &after)
                    samples = before + after
                }
                var output = Data(capacity: samples.count * 4)
                for sample in samples {
                    var little = sample.littleEndian
                    withUnsafeBytes(of: &little) { output.append(contentsOf: $0) }
                }
                let changed = zip(original, samples).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
                var report: [String: Any] = ["status": "inferred", "sourceSHA256": bytes.sha256Hex,
                    "outputSHA256": output.sha256Hex, "frameCount": samples.count / 2,
                    "changedSamples": changed, "volume": filter.volume, "pan": filter.pan,
                    "range": filter.range, "filterUpdates": updateFilter == nil ? 0 : 1,
                    "filterUpdateFrame": updateFilter == nil ? NSNull() : (updateFrame ?? 0) as Any,
                    "inputFormat": "signed_16_le_stereo",
                    "outputFormat": "signed_32_le_stereo", "originalDecoderEquivalence": "not_tested",
                    "originalFilterEquivalence": "not_tested", "playback": "not_tested"]
                if let destination, let destinationName, let sampleRate {
                    var wav = Data("RIFF".utf8)
                    func append16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { wav.append(contentsOf: $0) } }
                    func append32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { wav.append(contentsOf: $0) } }
                    let dataSize = UInt32(samples.count * 2)
                    append32(36 + dataSize)
                    wav.append(Data("WAVEfmt ".utf8)); append32(16); append16(1); append16(2)
                    append32(UInt32(sampleRate)); append32(UInt32(sampleRate * 4)); append16(4); append16(16)
                    wav.append(Data("data".utf8)); append32(dataSize)
                    var clipped = 0
                    for sample in samples {
                        if sample < -32768 || sample > 32767 { clipped += 1 }
                        let value = Int16(clamping: sample)
                        append16(UInt16(bitPattern: value))
                    }
                    try destination.writeNew(destinationName, data: wav, limit: 4_000_044)
                    report["researchWavSHA256"] = wav.sha256Hex
                    report["researchWavClippedSamples"] = clipped
                    report["researchWavRate"] = sampleRate
                    report["researchWavConversion"] = "saturating_16_bit_candidate"
                }
                print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
                return
            }
            if args.first == "--inspect-system-data" {
                guard args.count == 5 else { throw ResourceError.rejected("invalid_system_data_arguments") }
                let saves = try SafeDirectory(URL(fileURLWithPath: args[1], isDirectory: true))
                let game = try SafeDirectory(URL(fileURLWithPath: args[3], isDirectory: true))
                let template = try SaveSystemData.headerTemplate(from: game, executable: args[4])
                let data = try saves.read(args[2], limit: SaveEnvelope.maxFileBytes)
                let check = try SaveSystemData(data: data, headerTemplate: template)
                let bindingCount = try check.validateScalarBindings()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try encoder.encode(check.summary), as: UTF8.self))
                FileHandle.standardError.write(Data("staged_scalar_binding_count=\(bindingCount)\n".utf8))
                return
            }
            if args.first == "--inspect-bar-pointer" {
                guard args.count == 9, let knob = Int32(args[4]), let origin = Int32(args[5]),
                      let maximum = Int32(args[6]), let pointer = Int32(args[7]),
                      let rounding = BarPointerGeometry.Rounding(rawValue: args[8]) else {
                    throw ResourceError.rejected("invalid_bar_pointer_arguments")
                }
                let assets = try SafeDirectory(URL(fileURLWithPath: args[1], isDirectory: true))
                let recipeURL = URL(fileURLWithPath: args[2])
                let recipes = try SafeDirectory(recipeURL.deletingLastPathComponent())
                let recipe = try JSONDecoder().decode(ScriptImageRecipe.self,
                    from: recipes.read(recipeURL.lastPathComponent, limit: 32 * 1024 * 1024))
                let container = try assets.read(args[3])
                let location = ScriptModuleReference(logicalPath: args[3], sourceFile: args[3],
                    sourceSHA256: container.sha256Hex).wholeFileLocation(byteLength: container.count)
                guard let canvas = recipe.motionCanvasInputs(location),
                      let geometry = BarPointerGeometry(knobLength: knob, trackLength: canvas.width, maximum: maximum),
                      let value = geometry.value(pointer: pointer, origin: origin, rounding: rounding) else {
                    throw ResourceError.rejected("bar_pointer_geometry_unavailable")
                }
                let report: [String: Any] = ["status": "inferred", "sourceSHA256": container.sha256Hex,
                    "trackCanvas": [canvas.width, canvas.height], "knobLength": knob,
                    "origin": origin, "start": geometry.start, "end": geometry.end,
                    "maximum": maximum, "pointer": pointer, "rounding": rounding.rawValue, "value": value,
                    "engineRoundingMode": "not_tested", "hitTest": "not_tested", "callback": "unsupported"]
                print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
                return
            }
            if args.first == "--inspect-bar-motion" {
                guard args.count == 11, let action = Int32(args[4]), action >= 0,
                      let start = Int32(args[5]), let target = Int32(args[6]),
                      let maximum = Int32(args[7]), let duration = Int32(args[8]),
                      let remaining = Int32(args[9]), let easing = BarMotionSampling.Easing(rawValue: args[10]) else {
                    throw ResourceError.rejected("invalid_bar_motion_arguments")
                }
                let assets = try SafeDirectory(URL(fileURLWithPath: args[1], isDirectory: true))
                let recipeURL = URL(fileURLWithPath: args[2])
                let recipes = try SafeDirectory(recipeURL.deletingLastPathComponent())
                let recipe = try JSONDecoder().decode(ScriptImageRecipe.self,
                    from: recipes.read(recipeURL.lastPathComponent, limit: 32 * 1024 * 1024))
                let container = try assets.read(args[3])
                let location = ScriptModuleReference(logicalPath: args[3], sourceFile: args[3],
                    sourceSHA256: container.sha256Hex).wholeFileLocation(byteLength: container.count)
                guard let inputs = recipe.motionDurationInputs(location),
                      let time = BarMotionSampling.animationTime(start: start, target: target, maximum: maximum,
                          duration: duration, remaining: remaining, animationDuration: inputs.duration, easing: easing),
                      let keys = recipe.motionKeysAtFractionalTime(location, selectedMember: action, time: time),
                      let key = keys.first(where: { $0.type != 0 }), let area = key.sampledFirstSourceArea else {
                    throw ResourceError.rejected("bar_motion_sampling_unavailable")
                }
                var report: [String: Any] = ["status": "inferred", "sourceSHA256": container.sha256Hex,
                    "start": start, "target": target, "maximum": maximum, "duration": duration,
                    "remaining": remaining, "easing": easing.rawValue, "animationDuration": inputs.duration,
                    "animationTime": time, "sourceArea": area, "originalEasingSelection": "not_tested",
                    "originalFloatEquivalence": "not_tested", "pixelRendering": "not_tested"]
                let draws = keys.filter { $0.type != 0 }
                if draws.count == 1, draws[0].type == 4 {
                    let background = SIMD4<UInt8>(20, 40, 60, 255)
                    var canvas = Array(repeating: Array(repeating: background, count: 512), count: 128)
                    do {
                        let covered = try recipe.drawFullTexturePreview(draws[0], container: container,
                            origin: .zero, canvas: &canvas)
                        var hash = SHA256(), changed = 0
                        for row in canvas {
                            changed += row.count { $0 != background }
                            row.withUnsafeBytes { hash.update(bufferPointer: $0) }
                        }
                        report["pixelRendering"] = "inferred"
                        report["covered"] = covered
                        report["changedPixels"] = changed
                        report["canvasSHA256"] = hash.finalize().map { String(format: "%02x", $0) }.joined()
                        report["originalPixelEquivalence"] = "not_tested"
                    } catch {
                        report["pixelRendering"] = "unsupported"
                        report["renderIssue"] = String(describing: error)
                    }
                } else {
                    report["pixelRendering"] = "unsupported"
                    report["renderIssue"] = "bar_progress_key_shape_unsupported"
                }
                print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
                return
            }
            if args.first == "--inspect-single-texture" {
                guard args.count == 6, let action = Int32(args[4]), action >= 0,
                      let time = Float(args[5]), time.isFinite, (0...10_000_000).contains(time) else {
                    throw ResourceError.rejected("invalid_single_texture_arguments")
                }
                let assets = try SafeDirectory(URL(fileURLWithPath: args[1], isDirectory: true))
                let recipeURL = URL(fileURLWithPath: args[2])
                let recipes = try SafeDirectory(recipeURL.deletingLastPathComponent())
                let recipe = try JSONDecoder().decode(ScriptImageRecipe.self,
                    from: recipes.read(recipeURL.lastPathComponent, limit: 32 * 1024 * 1024))
                let container = try assets.read(args[3])
                let location = ScriptModuleReference(logicalPath: args[3], sourceFile: args[3],
                    sourceSHA256: container.sha256Hex).wholeFileLocation(byteLength: container.count)
                guard let keys = recipe.motionKeysAtFractionalTime(location, selectedMember: action, time: time) else {
                    throw ResourceError.rejected("single_texture_timeline_unavailable")
                }
                let draws = keys.filter { $0.type != 0 }
                guard draws.count == 1, draws[0].type == 4 else {
                    throw ResourceError.rejected("single_texture_key_count")
                }
                let pixel = SIMD4<UInt8>(20, 40, 60, 255)
                var canvas = Array(repeating: Array(repeating: pixel, count: 512), count: 128)
                var covered = false
                var issue: String?
                do {
                    covered = try recipe.drawFullTexturePreview(draws[0], container: container,
                        origin: .zero, canvas: &canvas)
                } catch { issue = String(describing: error) }
                var hash = SHA256(), changed = 0
                for row in canvas {
                    changed += row.count { $0 != pixel }
                    row.withUnsafeBytes { hash.update(bufferPointer: $0) }
                }
                var report: [String: Any] = ["status": issue == nil ? "inferred" : "unsupported", "sourceSHA256": container.sha256Hex,
                    "time": time, "sourceArea": draws[0].sampledFirstSourceArea ?? [],
                    "covered": covered, "changedPixels": changed,
                    "canvasSHA256": hash.finalize().map { String(format: "%02x", $0) }.joined(),
                    "originalPixelEquivalence": "not_tested"]
                if let issue { report["issue"] = issue }
                if let area = draws[0].sampledFirstSourceArea, area.count == 4,
                   let anchor = draws[0].literalAnchorRatio, anchor.x == 0, anchor.y == 0,
                   let placement = recipe.axisAlignedState([draws[0]]), placement.scaleX == 1, placement.scaleY == 1,
                   let horizontal = SingleTextureScanBounds.inclusiveRange(start: Float(placement.x),
                       end: Float(placement.x) + area[2], limit: 512),
                   let vertical = SingleTextureScanBounds.inclusiveRange(start: Float(placement.y),
                       end: Float(placement.y) + area[3], limit: 128) {
                    report["candidateScanBounds"] = [horizontal.lowerBound, vertical.lowerBound,
                        horizontal.upperBound, vertical.upperBound]
                    report["candidateScanBoundsScope"] = "inferred; axis-aligned local geometry only, inclusive bounds; not a draw or original pixel result"
                    if let x = SingleTextureScanBounds.coordinateSpan(start: Float(placement.x),
                        end: Float(placement.x) + area[2], sourceStart: area[0],
                        sourceEnd: area[0] + area[2], limit: 512) {
                        report["candidateTextureHorizontalFixedSpan"] = [x.firstFixed, x.stepFixed]
                        report["candidateTextureHorizontalFixedSpanScope"] =
                            "inferred; assumed axis-aligned source vertices, 16.16 coordinates; not a draw or original pixel result"
                    }
                }
                FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]))
                print("")
                if issue != nil { exit(2) }
                return
            }
            if args.first == "--inspect-dual-transfer" {
                guard args.count == 7, let action = Int32(args[4]), action >= 0,
                      let time = Int32(args[5]), time >= 0, let sample = UInt8(args[6]) else {
                    throw ResourceError.rejected("invalid_dual_transfer_arguments")
                }
                let assets = try SafeDirectory(URL(fileURLWithPath: args[1], isDirectory: true))
                let recipeURL = URL(fileURLWithPath: args[2])
                let recipes = try SafeDirectory(recipeURL.deletingLastPathComponent())
                let recipe = try JSONDecoder().decode(ScriptImageRecipe.self,
                    from: recipes.read(recipeURL.lastPathComponent, limit: 32 * 1024 * 1024))
                let data = try assets.read(args[3])
                let location = ScriptModuleReference(logicalPath: args[3], sourceFile: args[3],
                    sourceSHA256: data.sha256Hex).wholeFileLocation(byteLength: data.count)
                guard let keys = recipe.motionKeys(location, selectedMember: action, time: time),
                      let key = keys.first(where: { $0.type == 10 }),
                      let input = key.dual_texture_raw_inputs, let value = key.sampledDualTransferValue,
                      let mode = UInt32(exactly: input.key_cc),
                      let prepared = TwoTexturePixel.command3Threshold(value: value, rawMode: mode) else {
                    throw ResourceError.rejected("dual_transfer_candidate_unavailable")
                }
                let result = TwoTexturePixel.command3Mask(sample: sample, threshold: prepared.threshold,
                                                          gain: prepared.gain, inverted: prepared.inverted)
                let report: [String: Any] = ["status": "inferred", "sourceSHA256": data.sha256Hex,
                    "action": action, "time": time, "keyOffset": key.offset, "value": value,
                    "rawMode": mode, "threshold": prepared.threshold, "gain": prepared.gain,
                    "inverted": prepared.inverted, "sample": sample, "mask": result,
                    "originalRendererEquivalence": "not_tested", "rendererBranch": "not_tested"]
                print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
                return
            }
            if args.first == "--inspect-partial-motion" {
                guard args.count == 6, let action = Int32(args[4]), action >= 0,
                      let time = Int32(args[5]), time >= 0 else {
                    throw ResourceError.rejected("invalid_partial_motion_arguments")
                }
                let assets = try SafeDirectory(URL(fileURLWithPath: args[1], isDirectory: true))
                let recipeURL = URL(fileURLWithPath: args[2])
                let recipes = try SafeDirectory(recipeURL.deletingLastPathComponent())
                let recipe = try JSONDecoder().decode(ScriptImageRecipe.self,
                    from: recipes.read(recipeURL.lastPathComponent, limit: 32 * 1024 * 1024))
                let payload = try assets.read(args[3])
                let location = ScriptModuleReference(logicalPath: args[3], sourceFile: args[3],
                    sourceSHA256: payload.sha256Hex).wholeFileLocation(byteLength: payload.count)
                guard let keys = recipe.samplePartialMotion(location, selectedMember: action, time: time) else {
                    throw ResourceError.rejected("partial_motion_unavailable")
                }
                let samples: [[String: Any]] = keys.map { key in
                    var fields: [String: Any] = ["offset": key.offset, "type": Int(key.type)]
                    fields["opacity"] = recipe.composedOpacity(texture: key, states: []).map { Int($0) }
                    if let slot = key.texture_numbers?.first {
                        fields["slot"] = slot
                        if let texture = recipe.embeddedTexture(location, slot: slot), let size = texture.size,
                           let rect = recipe.fullTextureRectangle(key, size: size, host: .identity) {
                            fields["localBounds"] = [rect.minX, rect.minY, rect.width, rect.height]
                        }
                    }
                    return fields
                }
                let report: [String: Any] = ["status": "inferred", "samples": samples]
                print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
                return
            }
            if args.first == "--inspect-two-texture" {
                var time: Int32 = 0
                if let last = args.last, last.hasPrefix("--time=") {
                    guard let parsed = Int32(last.dropFirst("--time=".count)), parsed >= 0 else {
                        throw ResourceError.rejected("invalid_two_texture_sample_time")
                    }
                    time = parsed
                    args.removeLast()
                }
                let transparent = args.last == "--transparent-target"
                if transparent { args.removeLast() }
                let includeBase = args.last == "--include-type4-base"
                if includeBase { args.removeLast() }
                guard (9...10).contains(args.count), let action = Int32(args[6]), action >= 0,
                      let x = Int(args[7]), let y = Int(args[8]) else {
                    throw ResourceError.rejected("invalid_two_texture_inspection_arguments")
                }
                let assets = try SafeDirectory(URL(fileURLWithPath: args[1], isDirectory: true))
                let recipeURL = URL(fileURLWithPath: args[2])
                let recipes = try SafeDirectory(recipeURL.deletingLastPathComponent())
                let recipe = try JSONDecoder().decode(ScriptImageRecipe.self,
                    from: recipes.read(recipeURL.lastPathComponent, limit: 32 * 1024 * 1024))
                let container = try assets.read(args[3])
                let bound = try assets.read(args[5])
                func location(_ path: String, _ data: Data) -> ScriptLocation {
                    ScriptModuleReference(logicalPath: path, sourceFile: path, sourceSHA256: data.sha256Hex)
                        .wholeFileLocation(byteLength: data.count)
                }
                guard let keys = recipe.motionKeys(location(args[3], container), selectedMember: action, time: time) else {
                    throw ResourceError.rejected("two_texture_timeline_unavailable")
                }
                let draws = keys.filter { $0.type == 11 }
                guard draws.count == 1 else { throw ResourceError.rejected("two_texture_key_count") }
                let opaque = try ResourceImage.decode(assets.read(args[4])).opaqueCanvas(over: CGColor(gray: 0, alpha: 1))
                let background = transparent
                    ? opaque.map { $0.map { _ in SIMD4<UInt8>.zero } } : opaque
                var canvas = background
                guard let slots = draws[0].texture_numbers, slots.count == 2 else {
                    throw ResourceError.rejected("two_texture_slot_count")
                }
                var bindings = [slots[0]: (bound, location(args[5], bound))]
                if args.count == 10 {
                    let second = try assets.read(args[9])
                    bindings[slots[1]] = (second, location(args[9], second))
                }
                var baseTextureChangedPixels: Int?
                if includeBase {
                    let ordered = keys.filter { $0.type != 0 }
                    guard ordered.map(\.type) == [4, 11] else {
                        throw ResourceError.rejected("unsupported_thumbnail_draw_order")
                    }
                    try recipe.drawFullTexturePreview(ordered[0], container: container,
                        boundTextures: bindings.mapValues { $0.0 }, origin: SIMD2(x, y), canvas: &canvas)
                    baseTextureChangedPixels = zip(background, canvas).reduce(0) { count, rows in
                        count + zip(rows.0, rows.1).count { $0 != $1 }
                    }
                }
                let beforeTwoTexture = canvas
                try recipe.drawFullTwoTextureKey(draws[0], container: container,
                    boundTextures: bindings, origin: SIMD2(x, y), canvas: &canvas)
                var hash = SHA256()
                var changed = 0
                for (before, after) in zip(background, canvas) {
                    changed += zip(before, after).count { $0 != $1 }
                    after.withUnsafeBytes { hash.update(bufferPointer: $0) }
                }
                var twoTextureHash = SHA256()
                var twoTextureChanged = 0
                var twoTextureChangedOnNonOpaque = 0
                for (before, after) in zip(beforeTwoTexture, canvas) {
                    for (previous, var pixel) in zip(before, after) where previous != pixel {
                        twoTextureChanged += 1
                        if previous.w != 255 { twoTextureChangedOnNonOpaque += 1 }
                        withUnsafeBytes(of: &pixel) { twoTextureHash.update(bufferPointer: $0) }
                    }
                }
                let report = TwoTextureCheck(width: canvas[0].count, height: canvas.count,
                    changedPixels: changed, baseTextureChangedPixels: baseTextureChangedPixels,
                    twoTextureChangedPixels: twoTextureChanged,
                    twoTextureChangedOnNonOpaquePixels: twoTextureChangedOnNonOpaque,
                    twoTextureChangedPixelsSHA256: twoTextureHash.finalize().map { String(format: "%02x", $0) }.joined(),
                    canvasSHA256: hash.finalize().map { String(format: "%02x", $0) }.joined())
                FileHandle.standardOutput.write(try JSONEncoder().encode(report))
                print("")
                return
            }
            var seedFromStdin = false
            var inferSeed = false
            var headerTemplateFromStdin = false
            var headerExecutable: String?
            var headerGameDirectory: String?
            var calValOffset: Int?
            var locateCalVal = false
            var inspectEngine = false
            var inspectPrefix = false
            var inspectDisplay = false
            var selectedSources: [String] = []
            var previewDisplaySurface: Int?
            var previewDisplayReload: (width: Int, height: Int)?
            if args.first == "--inspect-save-state" {
                while args.count > 3, let option = args.last, option.hasPrefix("--") {
                    switch option {
                    case "--seed-stdin", "--infer-seed", "--header-template-stdin":
                        guard !seedFromStdin, !inferSeed, !headerTemplateFromStdin else {
                            throw ResourceError.rejected("conflicting_state_seed_options")
                        }
                        seedFromStdin = option == "--seed-stdin"
                        inferSeed = option == "--infer-seed"
                        headerTemplateFromStdin = option == "--header-template-stdin"
                    case "--engine-state":
                        guard !inspectEngine else { throw ResourceError.rejected("duplicate_engine_state_option") }
                        inspectEngine = true
                    case "--display-state":
                        guard !inspectDisplay else { throw ResourceError.rejected("duplicate_display_state_option") }
                        inspectDisplay = true
                    case "--state-prefix":
                        guard !inspectPrefix else { throw ResourceError.rejected("duplicate_state_prefix_option") }
                        inspectPrefix = true
                    default:
                        if option.hasPrefix("--header-exe=") {
                            guard headerExecutable == nil else { throw ResourceError.rejected("duplicate_save_header_exe") }
                            headerExecutable = String(option.dropFirst("--header-exe=".count))
                            args.removeLast()
                            continue
                        }
                        if option.hasPrefix("--header-game-dir=") {
                            guard headerGameDirectory == nil else { throw ResourceError.rejected("duplicate_save_header_game_directory") }
                            headerGameDirectory = String(option.dropFirst("--header-game-dir=".count))
                            args.removeLast()
                            continue
                        }
                        if option.hasPrefix("--display-surface-png=") {
                            guard previewDisplaySurface == nil,
                                  let index = Int(option.dropFirst("--display-surface-png=".count)),
                                  (0...1).contains(index) else {
                                throw ResourceError.rejected("invalid_display_surface_preview_option")
                            }
                            previewDisplaySurface = index
                            args.removeLast()
                            continue
                        }
                        if option.hasPrefix("--display-reload-png=") {
                            let size = option.dropFirst("--display-reload-png=".count).split(separator: "x")
                            guard previewDisplayReload == nil, size.count == 2,
                                  let width = Int(size[0]), let height = Int(size[1]),
                                  (1...4096).contains(width), (1...4096).contains(height) else {
                                throw ResourceError.rejected("invalid_display_reload_preview_size")
                            }
                            previewDisplayReload = (width, height)
                            args.removeLast()
                            continue
                        }
                        if option.hasPrefix("--select-source=") {
                            let source = String(option.dropFirst("--select-source=".count))
                            guard !source.isEmpty else { throw ResourceError.rejected("empty_selected_source") }
                            selectedSources.append(source)
                            args.removeLast()
                            continue
                        }
                        let prefix = "--calval-offset="
                        guard option.hasPrefix(prefix) else {
                            throw ResourceError.rejected("unknown_save_state_option")
                        }
                        guard !locateCalVal, calValOffset == nil else {
                            throw ResourceError.rejected("duplicate_calval_offset_option")
                        }
                        let value = option.dropFirst(prefix.count)
                        if value == "auto" {
                            locateCalVal = true
                        } else {
                            guard let offset = Int(value), offset >= 0 else {
                                throw ResourceError.rejected("invalid_calval_offset")
                            }
                            calValOffset = offset
                        }
                    }
                    args.removeLast()
                }
                guard (headerExecutable == nil) == (headerGameDirectory == nil),
                      headerExecutable == nil || (!seedFromStdin && !inferSeed && !headerTemplateFromStdin) else {
                    throw ResourceError.rejected("conflicting_save_header_source_options")
                }
            }
            if args.count == 2, args[0] == "--inspect-save-directory" {
                let directory = try SafeDirectory(URL(fileURLWithPath: args[1], isDirectory: true))
                let report = try SaveSlotInventory.scan(directory)
                FileHandle.standardOutput.write(try JSONEncoder().encode(report))
                print("")
                if report.contains(where: { $0.status == .unsupported }) { exit(2) }
                return
            }
            if (args.count == 3 && ["--inspect-save", "--inspect-save-state", "--inspect-save-thumbnail"].contains(args[0]))
                || (args.count == 6 && args[0] == "--inspect-save-state") {
                let directory = try SafeDirectory(URL(fileURLWithPath: args[1], isDirectory: true))
                let data = try directory.read(args[2], limit: SaveEnvelope.maxFileBytes)
                let encoder = JSONEncoder()
                let output: Data
                var failedSaveCheck = false
                if args[0] == "--inspect-save-state" {
                    var seed: UInt32?
                    if seedFromStdin {
                        var input = Data()
                        while input.count < 17,
                              let chunk = try FileHandle.standardInput.read(upToCount: 17 - input.count),
                              !chunk.isEmpty {
                            input.append(chunk)
                        }
                        guard input.count < 17 else { throw ResourceError.rejected("invalid_state_seed") }
                        let field = String(decoding: input, as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard (1...8).contains(field.utf8.count),
                              field.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                              let value = UInt32(field, radix: 16) else {
                            throw ResourceError.rejected("invalid_state_seed")
                        }
                        seed = value
                    }
                    if let executable = headerExecutable, let game = headerGameDirectory {
                        let original = try SafeDirectory(URL(fileURLWithPath: game, isDirectory: true))
                        let template = try SaveEnvelope.slotHeaderTemplate(from: original, executable: executable)
                        seed = try SaveEnvelope.validatedSlotSeed(data, clearTemplate: template)
                    } else if headerTemplateFromStdin {
                        var template = Data()
                        while template.count < 41,
                              let chunk = try FileHandle.standardInput.read(upToCount: 41 - template.count),
                              !chunk.isEmpty {
                            template.append(chunk)
                        }
                        seed = try SaveEnvelope.validatedSlotSeed(data, clearTemplate: template)
                    }
                    let state = try SaveEnvelope.decodeSlotState(data, seed: seed, inferSeed: inferSeed)
                    var check = try SaveStateCheck(state)
                    if !selectedSources.isEmpty && (args.count != 6 || previewDisplaySurface != nil) {
                        throw ResourceError.rejected("selected_sources_require_catalog_lookup")
                    }
                    if previewDisplaySurface != nil && previewDisplayReload != nil {
                        throw ResourceError.rejected("conflicting_display_preview_options")
                    }
                    func writePreview(_ image: CGImage) throws {
                        let png = NSMutableData()
                        guard let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil) else {
                            throw ResourceError.rejected("saved_display_preview_encoder_unavailable")
                        }
                        CGImageDestinationAddImage(destination, image, nil)
                        guard CGImageDestinationFinalize(destination) else {
                            throw ResourceError.rejected("saved_display_preview_encode_failed")
                        }
                        FileHandle.standardOutput.write(png as Data)
                    }
                    if let index = previewDisplaySurface {
                        let prefix = try SaveStatePrefix(state: state, after: check.readerCursor)
                        try writePreview(ResourceImage.decode(prefix.displaySurfaceBytes(in: state, index: index)).image)
                        return
                    }
                    var previewReload: SaveStatePrefix.DisplaySummary.Reload?
                    if let size = previewDisplayReload {
                        let prefix = try SaveStatePrefix(state: state, after: check.readerCursor)
                        let display = try prefix.inspectDisplay(in: state)
                        if let rect = display.proceduralRect {
                            try writePreview(ResourceImage.savedDisplayRectPreview(rect, width: size.width, height: size.height))
                            return
                        }
                        if let issue = display.proceduralRectIssue { throw ResourceError.rejected(issue) }
                        guard let reload = display.externalReload else {
                            throw ResourceError.rejected("saved_display_reload_unavailable")
                        }
                        guard args.count == 6 else { throw ResourceError.rejected("saved_display_reload_requires_catalog") }
                        previewReload = reload
                    }

                    if headerTemplateFromStdin || headerExecutable != nil { check.slotHeaderVerification = .verified }
                    if inspectPrefix || inspectDisplay || locateCalVal || (inspectEngine && calValOffset == nil) {
                        let prefix = try SaveStatePrefix(state: state, after: check.readerCursor)
                        check.statePrefix = prefix
                        if inspectDisplay {
                            check.displayState = try prefix.inspectDisplayState(in: state)
                        }
                        if locateCalVal || (inspectEngine && calValOffset == nil) {
                            calValOffset = try check.displayState?.calValOffset ?? prefix.locateCalVal(in: state)
                        }
                    }
                    if let calValOffset {
                        let arrays = try SaveVariableArrays.inspectCalVal(state: state, at: calValOffset)
                        check.calValArrays = arrays
                        failedSaveCheck = arrays.indexed.status == .unsupported
                        if inspectEngine && !failedSaveCheck {
                            do {
                                let engine = try SaveEngineState(state: state,
                                    at: arrays.indexed.nextDecodedOffset ?? arrays.nextDecodedOffset)
                                check.engineState = engine
                                if engine.status == .unsupported {
                                    check.engineStateIssue = "unparsed_save_state_tail"
                                    failedSaveCheck = true
                                }
                            } catch {
                                check.engineStateIssue = String(describing: error)
                                failedSaveCheck = true
                            }
                        }
                    }
                    if inferSeed, try SaveEnvelope(data).slot?.transformed == true {
                        check.stateSeedInference = .inferred
                    }
                    if args.count == 6 {
                        let assets = try SafeDirectory(URL(fileURLWithPath: args[3], isDirectory: true))
                        let catalogDirectory = try SafeDirectory(URL(fileURLWithPath: args[4], isDirectory: true))
                        let catalogFile = try JSONDecoder().decode(ScriptCatalogFile.self,
                            from: catalogDirectory.read(args[5], limit: 32 * 1024 * 1024))
                        var catalog = try ScriptModuleCatalog(entries: catalogFile.items)
                        for source in selectedSources.reversed() {
                            try catalog.select(sourceFile: source)
                        }
                        if let size = previewDisplayReload, let reload = previewReload {
                            var repository = try ScriptRepository(directory: assets, catalog: catalog)
                            let (_, bytes) = try reload.readImage(in: state, repository: &repository)
                            let image = try ResourceImage.decode(bytes)
                            try writePreview(image.savedDisplayPreview(transform: reload.transform,
                                                                       width: size.width, height: size.height))
                            return
                        }
                        var repository = try ScriptRepository(directory: assets, catalog: catalog)
                        do {
                            let resolved = try check.readerCursor.resolveLabel(in: state, repository: &repository)
                            check.resolvedLabel = resolved.location
                            let position = try resolved.program.sourcePosition(for: check.readerCursor, anchor: resolved.location)
                            check.resolvedSourcePosition = position
                            if let mode = check.readerCursor.routines.last?.rawState, mode == 2 || mode == 3 || mode == 4 {
                                let index = try resolved.program.savedResumeIndex(position, reader: check.readerCursor)
                                let record = resolved.program.document.records[index]
                                check.resolvedResumeRecord = record.location
                                check.resolvedResumeRecordKind = record.kind
                                check.commandBoundaryStatus = .inferred
                            } else {
                                let boundary = try resolved.program.saveCommandBoundary(position)
                                check.resolvedCommand = boundary.location
                                check.resolvedCommandControlDepth = boundary.controlDepth
                                check.commandBoundaryStatus = .verified
                            }
                        } catch {
                            check.commandBoundaryStatus = .unsupported
                            check.sourcePositionIssue = String(describing: error)
                            failedSaveCheck = true
                        }
                    }
                    output = try encoder.encode(check)
                } else if args[0] == "--inspect-save-thumbnail" {
                    let thumbnail = try ResourceImage.decodeSaveThumbnail(data)
                    output = try encoder.encode(SaveThumbnailCheck(present: thumbnail != nil,
                        width: thumbnail?.image.width, height: thumbnail?.image.height))
                } else {
                    output = try encoder.encode(SaveEnvelope(data))
                }
                FileHandle.standardOutput.write(output)
                print("")
                if failedSaveCheck { exit(2) }
                return
            }
            guard args.count >= 2, args.count <= 3, ["--game-dir", "--assets-dir"].contains(args[0]),
                  args.count == 2 || args[2] == "--verify-images" else {
                throw ResourceError.rejected("""
                    Usage: mangekyou-inspect (--game-dir|--assets-dir) PATH [--verify-images]
                           mangekyou-inspect --inspect-bar-pointer ASSETS RECIPE CONTAINER KNOB ORIGIN MAX POINTER ROUNDING
                           mangekyou-inspect --inspect-single-texture ASSETS RECIPE CONTAINER ACTION TIME
                           mangekyou-inspect --inspect-two-texture ASSETS RECIPE CONTAINER BACKGROUND FIRST ACTION X Y [SECOND] [--include-type4-base] [--transparent-target] [--time=TICKS]
                           mangekyou-inspect --inspect-system-data DIRECTORY FILE GAME_DIRECTORY EXE
                           mangekyou-inspect --inspect-save-directory DIRECTORY
                           mangekyou-inspect --inspect-save DIRECTORY SLOT
                           mangekyou-inspect --inspect-save-thumbnail DIRECTORY SLOT
                           mangekyou-inspect --inspect-save-state DIRECTORY SLOT [ASSETS CATALOG_DIRECTORY CATALOG] [--display-surface-png=0|1|--display-reload-png=WIDTHxHEIGHT] [--select-source=SOURCE ...] [--state-prefix] [--display-state] [--engine-state] [--calval-offset=BYTES|auto] [--seed-stdin|--infer-seed|--header-template-stdin]
                           --seed-stdin reads one hexadecimal value from a pipe closed at EOF.
                           --header-template-stdin reads exactly 40 template bytes from a pipe closed at EOF.
                           --header-game-dir=PATH --header-exe=RELATIVE_PATH uses a pinned local original executable.
                    """)
            }
            let directory = try SafeDirectory(URL(fileURLWithPath: args[1], isDirectory: true))
            let result = try InventoryScanner().scan(directory)
            var checks: [ImageCheck] = []
            if args.count == 3 {
                let images = result.files.filter { ["PNG", "DPNG", "JPEG"].contains($0.format) }
                guard images.count <= 128 else { throw ResourceError.rejected("image_sample_limit") }
                var total = 0
                let deadline = Date().addingTimeInterval(60)
                for entry in images {
                    do {
                        guard Date() < deadline else { throw ResourceError.rejected("image_time_limit") }
                        let data = try directory.read(entry.relativePath)
                        total += data.count
                        guard total <= 128 * 1024 * 1024 else { throw ResourceError.rejected("image_total_byte_limit") }
                        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                        let decoded = try ResourceImage.decode(data)
                        checks.append(ImageCheck(relativePath: entry.relativePath, sourceSHA256: sha,
                            status: .verified, width: decoded.image.width, height: decoded.image.height, notes: decoded.notes, issue: nil))
                    } catch {
                        checks.append(ImageCheck(relativePath: entry.relativePath, sourceSHA256: nil,
                            status: .unsupported, width: nil, height: nil, notes: [], issue: String(describing: error)))
                    }
                }
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let report = InspectReport(inventory: result, imageChecks: checks, imageDecodeStatus: args.count == 3 && !checks.isEmpty ?
                (checks.allSatisfy { $0.status == .verified } ? .verified : .unsupported) : .notTested)
            FileHandle.standardOutput.write(try encoder.encode(report)); print("")
            if !result.issues.isEmpty || checks.contains(where: { $0.status == .unsupported }) { exit(2) }
        } catch {
            let message = "Mangekyou: \(error)\n"
            FileHandle.standardError.write(Data(message.utf8)); exit(2)
        }
    }
}
