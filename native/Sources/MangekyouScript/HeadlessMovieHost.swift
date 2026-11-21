import Foundation
import Darwin
import ImageIO
import MangekyouCore

private final class ConcurrentProbeResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Data, Error>?

    func store(_ value: Result<Data, Error>) {
        lock.lock()
        result = value
        lock.unlock()
    }

    func take() throws -> Data {
        lock.lock()
        let value = result
        lock.unlock()
        guard let value else { throw ResourceError.rejected("live_audio_probe_result_missing") }
        return try value.get()
    }
}

/// Explicit local decoder backend for exercising the script and media path.
struct HeadlessMovieHost: Sendable {
    let tools: URL
    let assets: SafeDirectory
    var verifiedAudio = Set<String>()

    func decode(_ request: ScriptMachine.MoviePlaybackRequest) throws -> Int32 {
        let source = request.resource
        return try assets.withFile(source.sourceFile) { fd, size in
            guard size == Int64(source.byteLength), try SafeDirectory.movieSHA256(fd: fd, size: size) == source.sourceSHA256 else {
                throw ResourceError.rejected("movie_source_changed")
            }
            let output = Pipe()
            try run("ffprobe", fd: fd, arguments: ["-v","error","-protocol_whitelist","fd","-fd","0",
                "-show_entries","format=duration","-of","csv=p=0","fd:"], output: output.fileHandleForWriting)
            try output.fileHandleForWriting.close()

            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            guard let seconds = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  seconds.isFinite, seconds > 0, seconds <= 600 else {
                throw ResourceError.rejected("movie_duration_outside_profile")
            }
            try run("ffmpeg", fd: fd, arguments: ["-nostdin","-v","error","-xerror","-protocol_whitelist","fd",
                "-fd","0","-i","fd:","-map","0:v:0","-map","0:a:0?","-f","null","-"], output: nil)
            let ticks = Int32((seconds * 1000).rounded(.towardZero))
            let receipt = "decoded_movie=\(source.sourceSHA256) ticks=\(ticks)\n"
            FileHandle.standardError.write(Data(receipt.utf8))
            return ticks
        }
    }

    /// Explicit, bounded sample of an identified embedded video. The caller
    /// supplies a research time; it is not the original movie clock.
    func cutinFrame(_ source: ScriptLocation, range: (offset: Int, length: Int, sha256: String), ticks: Int32) throws -> Data {
        guard (0..<30_000).contains(ticks), source.byteOffset == 0,
              source.rangeSHA256 == source.sourceSHA256,
              range.offset >= 0, (1...32 * 1024 * 1024).contains(range.length),
              range.offset <= source.byteLength, range.length <= source.byteLength - range.offset else {
            throw ResourceError.rejected("cutin_frame_outside_profile")
        }
        return try assets.withFile(source.sourceFile) { fd, size in
            guard size == source.byteLength,
                  try SafeDirectory.movieSHA256(fd: fd, size: size) == source.sourceSHA256 else {
                throw ResourceError.rejected("cutin_source_changed")
            }
            let bytes = try SafeDirectory.read(fd: fd, offset: Int64(range.offset), count: range.length)
            guard bytes.starts(with: Data("OggS".utf8)), bytes.sha256Hex == range.sha256 else {
                throw ResourceError.rejected("cutin_member_changed")
            }
            func temporaryFile() throws -> FileHandle {
                var path = Array((NSTemporaryDirectory() + "mangekyou-cutin-XXXXXX").utf8CString)
                let descriptor = mkstemp(&path)
                guard descriptor >= 0 else { throw ResourceError.rejected("cutin_temp_unavailable") }
                guard unlink(path) == 0 else { close(descriptor); throw ResourceError.rejected("cutin_temp_unlink_failed") }
                return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            }
            let input = try temporaryFile(), output = try temporaryFile()
            defer { try? input.close(); try? output.close() }
            try input.write(contentsOf: bytes)
            // This fixed member was independently checked as 720 frames at
            // 24 fps. Select its zero-based frame instead of seeking to the
            // first timestamp *after* a fractional-frame research time.
            let frame = Int64(ticks) * 24 / 1000
            try run("ffmpeg", fd: input.fileDescriptor, arguments: ["-nostdin", "-v", "error", "-xerror",
                "-protocol_whitelist", "fd", "-fd", "0", "-i", "fd:",
                "-map", "0:v:0", "-vf", "select=eq(n\\,\(frame))", "-fps_mode", "passthrough",
                "-frames:v", "1", "-c:v", "png", "-f", "image2pipe",
                "-fs", "16777216", "pipe:1"], output: output)
            let outputSize = try output.seekToEnd()
            guard outputSize > 0, outputSize < 16 * 1024 * 1024 else {
                throw ResourceError.rejected("cutin_frame_output_size")
            }
            return try SafeDirectory.read(fd: output.fileDescriptor, offset: 0, count: Int(outputSize))
        }
    }

    /// Derive a bounded research duration from the header and decoded frame count.
    func researchStandaloneVideoDuration(_ source: ScriptLocation) throws -> Int32 {
        guard source.byteOffset == 0, source.rangeSHA256 == source.sourceSHA256,
              source.sourceFile.lowercased().hasSuffix(".ogv") else {
            throw ResourceError.rejected("research_video_duration_source_outside_profile")
        }
        return try assets.withFile(source.sourceFile) { fd, size in
            guard size == source.byteLength, size > 0, size <= 16 * 1024 * 1024,
                  try SafeDirectory.movieSHA256(fd: fd, size: size) == source.sourceSHA256 else {
                throw ResourceError.rejected("research_video_duration_source_changed")
            }
            let header = try SafeDirectory.read(fd: fd, offset: 0, count: min(Int(size), 65536))
            let dimensions = try ScriptMovieHeader.theoraDimensions(header)
            let rate = try ScriptMovieHeader.theoraFrameRate(header)
            guard (1...4096).contains(dimensions.0), (1...4096).contains(dimensions.1),
                  dimensions.0 * dimensions.1 <= 4_194_304,
                  rate.numerator == 30, rate.denominator == 1 else {
                throw ResourceError.rejected("research_video_duration_header_outside_profile")
            }
            let output = Pipe()
            try run("ffprobe", fd: fd, arguments: ["-v", "error", "-protocol_whitelist", "fd", "-fd", "0",
                "-count_frames", "-select_streams", "v:0", "-show_entries",
                "stream=codec_name,width,height,nb_read_frames,r_frame_rate:format=duration", "-of", "json", "fd:"],
                output: output.fileHandleForWriting)
            try output.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard data.count <= 8192,
                  let info = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let streams = info["streams"] as? [[String: Any]], streams.count == 1,
                  streams[0]["codec_name"] as? String == "theora",
                  streams[0]["width"] as? Int == dimensions.0,
                  streams[0]["height"] as? Int == dimensions.1,
                  streams[0]["r_frame_rate"] as? String == "30/1",
                  let frameText = streams[0]["nb_read_frames"] as? String,
                  let frames = Int64(frameText), (30...300).contains(frames),
                  let format = info["format"] as? [String: Any], let text = format["duration"] as? String,
                  let seconds = Double(text), seconds.isFinite,
                  (frames * 1000) % 30 == 0,
                  let milliseconds = Int32(exactly: frames * 1000 / 30),
                  abs(seconds * 1000 - Double(milliseconds)) <= 1 else {
                throw ResourceError.rejected("research_video_duration_probe_outside_profile")
            }
            return milliseconds
        }
    }

    /// Sample the player's bounded standalone Theora profile. The supplied
    /// clock is an interpreter candidate, not a verified original media clock.
    func standaloneSceneFrame(_ source: ScriptLocation, ticks: Int32) throws -> Data {
        guard ticks >= 0, source.byteOffset == 0, source.rangeSHA256 == source.sourceSHA256 else {
            throw ResourceError.rejected("scene_video_frame_clock_outside_profile")
        }
        return try assets.withFile(source.sourceFile) { fd, size in
            guard size == source.byteLength, size > 0, size <= 16 * 1024 * 1024,
                  try SafeDirectory.movieSHA256(fd: fd, size: size) == source.sourceSHA256 else {
                throw ResourceError.rejected("scene_video_frame_source_changed")
            }
            let header = try SafeDirectory.read(fd: fd, offset: 0, count: min(Int(size), 65536))
            let dimensions = try ScriptMovieHeader.theoraDimensions(header)
            guard (1...4096).contains(dimensions.0), (1...4096).contains(dimensions.1),
                  dimensions.0 * dimensions.1 <= 4_194_304 else {
                throw ResourceError.rejected("scene_video_frame_dimensions")
            }
            let probe = Pipe()
            try run("ffprobe", fd: fd, arguments: ["-v", "error", "-protocol_whitelist", "fd", "-fd", "0",
                "-select_streams", "v:0", "-show_entries", "stream=r_frame_rate:format=duration", "-of", "json", "fd:"],
                output: probe.fileHandleForWriting)
            try probe.fileHandleForWriting.close()
            let probeData = probe.fileHandleForReading.readDataToEndOfFile()
            guard probeData.count <= 8192,
                  let info = try JSONSerialization.jsonObject(with: probeData) as? [String: Any],
                  let streams = info["streams"] as? [[String: Any]], streams.count == 1,
                  streams[0]["r_frame_rate"] as? String == "30/1",
                  let format = info["format"] as? [String: Any], let rawDuration = format["duration"] as? String,
                  let duration = Double(rawDuration), duration.isFinite, (1...10).contains(duration) else {
                throw ResourceError.rejected("scene_video_frame_timing_outside_profile")
            }
            let frames = Int64((duration * 30).rounded())
            guard frames > 0 else { throw ResourceError.rejected("scene_video_frame_timing_outside_profile") }
            let frame = (Int64(ticks) * 30 / 1000) % frames
            var path = Array((NSTemporaryDirectory() + "mangekyou-scene-frame-XXXXXX").utf8CString)
            let outputFD = mkstemp(&path)
            guard outputFD >= 0 else { throw ResourceError.rejected("scene_video_frame_temp_unavailable") }
            let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
            defer { try? output.close() }
            guard unlink(path) == 0 else { throw ResourceError.rejected("scene_video_frame_temp_unlink_failed") }
            try run("ffmpeg", fd: fd, arguments: ["-nostdin", "-v", "error", "-xerror", "-protocol_whitelist", "fd",
                "-fd", "0", "-i", "fd:", "-map", "0:v:0", "-vf", "select=eq(n\\,\(frame))",
                "-fps_mode", "passthrough", "-frames:v", "1", "-c:v", "png", "-f", "image2pipe",
                "-fs", "16777216", "pipe:1"], output: output)
            let outputSize = try output.seekToEnd()
            guard outputSize > 0, outputSize < 16 * 1024 * 1024 else {
                throw ResourceError.rejected("scene_video_frame_output_size")
            }
            let bytes = try SafeDirectory.read(fd: outputFD, offset: 0, count: Int(outputSize))
            guard let image = CGImageSourceCreateWithData(bytes as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                  properties[kCGImagePropertyPixelWidth] as? Int == dimensions.0,
                  properties[kCGImagePropertyPixelHeight] as? Int == dimensions.1 else {
                throw ResourceError.rejected("scene_video_frame_dimensions_mismatch")
            }
            return bytes
        }
    }

    mutating func decodeSound(_ source: ScriptLocation, seekMilliseconds: Int32? = nil) throws {
        if let seekMilliseconds {
            guard try savedSoundPCMBytes(source, seekMilliseconds: seekMilliseconds) > 0 else {
                throw ResourceError.rejected("saved_stream_playback_seek_no_samples")
            }
            return
        }
        try assets.withFile(source.sourceFile) { fd, size in
            guard size == Int64(source.byteLength), size <= 16*1024*1024,
                  try SafeDirectory.read(fd: fd,offset: 0,count: Int(size)).sha256Hex == source.sourceSHA256 else {
                throw ResourceError.rejected("sound_source_changed")
            }
            guard !verifiedAudio.contains(source.sourceSHA256) else { return }
            try run("ffmpeg", fd: fd, arguments: ["-nostdin","-v","error","-xerror","-protocol_whitelist","fd",
                "-fd","0","-i","fd:","-map","0:a:0","-f","null","-"], output: nil)
            verifiedAudio.insert(source.sourceSHA256)
        }
    }

    func probeSoundDuration(_ source: ScriptLocation) throws -> (seconds: Double, scriptMilliseconds: Int32) {
        try assets.withFile(source.sourceFile) { fd, size in
            guard source.byteOffset == 0, source.rangeSHA256 == source.sourceSHA256,
                  size == Int64(source.byteLength), size <= 16 * 1024 * 1024,
                  try SafeDirectory.read(fd: fd, offset: 0, count: Int(size)).sha256Hex == source.sourceSHA256 else {
                throw ResourceError.rejected("sound_duration_source_changed")
            }
            let output = Pipe()
            try run("ffprobe", fd: fd, arguments: ["-v", "error", "-protocol_whitelist", "fd", "-fd", "0",
                "-show_entries", "format=duration", "-of", "csv=p=0", "fd:"], output: output.fileHandleForWriting)
            try output.fileHandleForWriting.close()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            guard let seconds = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  seconds.isFinite, seconds > 0, seconds <= 600 else {
                throw ResourceError.rejected("sound_duration_outside_profile")
            }
            // The script duration follows the Float32 and nearest-even FISTP path
            // at 0x5a1560 -> 0x404a9c. Seek validation uses the unrounded duration.
            return (seconds, Int32((Double(Float(seconds)) * 1000).rounded(.toNearestOrEven)))
        }
    }

    /// Decode a bounded stream to an unlinked temporary CAF for the optional
    /// real audio observer. The compressed input is always digest checked.
    func audioForLiveObserver(_ source: ScriptLocation, volumeFilter: StreamVolumeFilterCandidate? = nil,
                              chainFilter: StreamFilterChainCandidate? = nil,
                              maximumOutputBytes: Int? = nil, candidateSampleRate: Int = 22050) throws -> (data: Data, duration: Double, durationMilliseconds: Int32) {
        guard [22050, 44100].contains(candidateSampleRate),
              chainFilter == nil || (volumeFilter == nil && candidateSampleRate == 44100) else {
            throw ResourceError.rejected("live_audio_candidate_sample_rate_unsupported")
        }
        return try assets.withFile(source.sourceFile) { probeFD, probeSize in
            guard source.byteOffset == 0, source.rangeSHA256 == source.sourceSHA256,
                  probeSize == Int64(source.byteLength), probeSize <= 16 * 1024 * 1024,
                  try SafeDirectory.read(fd: probeFD, offset: 0, count: Int(probeSize)).sha256Hex == source.sourceSHA256 else {
                throw ResourceError.rejected("live_audio_source_changed")
            }
            return try assets.withFile(source.sourceFile) { decodeFD, decodeSize in
                guard decodeSize == probeSize,
                      try SafeDirectory.read(fd: decodeFD, offset: 0, count: Int(decodeSize)).sha256Hex == source.sourceSHA256 else {
                    throw ResourceError.rejected("live_audio_source_changed")
                }
                var path = Array((NSTemporaryDirectory() + "mangekyou-live-pcm-XXXXXX").utf8CString)
                let outputFD = mkstemp(&path)
                guard outputFD >= 0 else { throw ResourceError.rejected("live_audio_output_unavailable") }
                let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
                defer { try? output.close() }
                guard unlink(path) == 0 else { throw ResourceError.rejected("live_audio_output_unlink_failed") }
                let probe = Pipe()
                let probeResult = ConcurrentProbeResult()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { group.leave() }
                    do {
                        try self.run("ffprobe", fd: probeFD, arguments: ["-v", "error", "-protocol_whitelist", "fd", "-fd", "0",
                            "-show_entries", "format=duration", "-of", "csv=p=0", "fd:"], output: probe.fileHandleForWriting)
                        try probe.fileHandleForWriting.close()
                        probeResult.store(.success(probe.fileHandleForReading.readDataToEndOfFile()))
                    } catch {
                        try? probe.fileHandleForWriting.close()
                        probeResult.store(.failure(error))
                    }
                }
                let converted = Result<Data, Error> {
                    if volumeFilter != nil || chainFilter != nil {
                        var chain = chainFilter
                        // Decode to an unlinked file and process bounded blocks;
                        // reserve room for the complete output before decoding.
                        let allowance = min(53_000_000, (maximumOutputBytes ?? 53_000_044) - 44)
                        guard allowance >= 4 else { throw ResourceError.rejected("live_audio_memory_limit") }
                        let alignedAllowance = allowance - allowance % 4
                        try run("ffmpeg", fd: decodeFD, arguments: ["-nostdin", "-v", "error", "-xerror",
                            "-protocol_whitelist", "fd", "-fd", "0", "-i", "fd:", "-map", "0:a:0",
                            "-ac", "2", "-ar", String(candidateSampleRate), "-c:a", "pcm_s16le", "-f", "s16le",
                            "-fs", String(alignedAllowance + 1_000_000), "pipe:1"], output: output)
                        let size = try output.seekToEnd()
                        // FFmpeg's cap is beyond the allowance, so reaching it
                        // cannot turn a truncated decode into a valid output.
                        guard size > 0, size <= UInt64(alignedAllowance), size.isMultiple(of: 4) else {
                            throw ResourceError.rejected("live_audio_volume_candidate_size_limit")
                        }
                        var wav = Data("RIFF".utf8)
                        wav.reserveCapacity(Int(size) + 44)
                        func append16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { wav.append(contentsOf: $0) } }
                        func append32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { wav.append(contentsOf: $0) } }
                        let bytes = UInt32(size)
                        append32(36 + bytes); wav.append(Data("WAVEfmt ".utf8)); append32(16)
                        append16(1); append16(2); append32(UInt32(candidateSampleRate)); append32(UInt32(candidateSampleRate * 4)); append16(4); append16(16)
                        wav.append(Data("data".utf8)); append32(bytes)
                        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
                        var offset = 0
                        while offset < Int(size) {
                            guard ContinuousClock.now < deadline else {
                                throw ResourceError.rejected("live_audio_volume_candidate_processing_timeout")
                            }
                            let count = min(262_144, Int(size) - offset)
                            var block = try SafeDirectory.read(fd: outputFD, offset: Int64(offset), count: count)
                            if chain != nil {
                                try chain!.applyPCM16LittleEndian(to: &block)
                            } else if let volumeFilter, volumeFilter != StreamVolumeFilterCandidate() {
                                try volumeFilter.applyPCM16LittleEndian(to: &block)
                            }
                            wav.append(block)
                            offset += count
                        }
                        return wav
                    }
                    try run("ffmpeg", fd: decodeFD, arguments: ["-nostdin", "-v", "error", "-xerror",
                        "-protocol_whitelist", "fd", "-fd", "0", "-i", "fd:", "-map", "0:a:0",
                        "-af", "volume=0", "-ac", "1", "-ar", "22050", "-c:a", "pcm_s16le", "-f", "caf",
                        "-fs", "33554432", "pipe:1"], output: output)
                    let size = try output.seekToEnd()
                    guard size > 0, size < 32 * 1024 * 1024 else {
                        throw ResourceError.rejected("live_audio_decoded_size_limit")
                    }
                    return try SafeDirectory.read(fd: outputFD, offset: 0, count: Int(size))
                }
                group.wait()
                let text = String(decoding: try probeResult.take(), as: UTF8.self)
                let durationText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let duration = Double(durationText), let candidateDuration = Float(durationText),
                      duration.isFinite, duration > 0, duration <= 600,
                      candidateDuration.isFinite, candidateDuration > 0, candidateDuration <= 600 else {
                    throw ResourceError.rejected("live_audio_duration_outside_profile")
                }
                let data = try converted.get()
                if volumeFilter != nil || chainFilter != nil {
                    let decodedDuration = Double(data.count - 44) / Double(candidateSampleRate * 4)
                    guard abs(decodedDuration - duration) <= 0.02 else {
                        throw ResourceError.rejected("live_audio_volume_candidate_duration_mismatch")
                    }
                }
                return (data, duration, Int32((Double(candidateDuration) * 1000).rounded(.toNearestOrEven)))
            }
        }
    }

    /// Isolated, bounded predecoded candidate. Source duration and output
    /// duration are kept separately; this does not establish engine timing.
    func audioForTimeScale(_ source: ScriptLocation, pitch: Int32,
                           maximumOutputBytes: Int = 8_000_044) throws ->
        (data: Data, duration: Double, durationMilliseconds: Int32, inputFrames: Int, blocks: Int, shortReadBlocks: Int) {
        guard maximumOutputBytes >= 48 else { throw ResourceError.rejected("live_audio_memory_limit") }
        let decoded = try audioForLiveObserver(source, volumeFilter: StreamVolumeFilterCandidate(),
            maximumOutputBytes: min(4_000_044, maximumOutputBytes), candidateSampleRate: 44100)
        let remaining = maximumOutputBytes - decoded.data.count * 2 - 44
        guard remaining >= 8 else { throw ResourceError.rejected("live_audio_memory_limit") }
        let converted = try StreamTimeScaleCandidate.interpolateStream(Data(decoded.data.dropFirst(44)), pitch: pitch,
            maximumOutputBytes: min(8_000_000, remaining / 2))
        var wav = Data("RIFF".utf8)
        func append16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { wav.append(contentsOf: $0) } }
        func append32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { wav.append(contentsOf: $0) } }
        let size = UInt32(converted.pcm.count)
        append32(36 + size); wav.append(Data("WAVEfmt ".utf8)); append32(16); append16(1); append16(2)
        append32(44100); append32(176400); append16(4); append16(16); wav.append(Data("data".utf8)); append32(size)
        wav.append(converted.pcm)
        return (wav, Double(converted.outputFrames) / 44100, decoded.durationMilliseconds,
                (decoded.data.count - 44) / 4, converted.blocks, converted.shortReadBlocks)
    }

    func savedSoundPCMBytes(_ source: ScriptLocation, seekMilliseconds: Int32? = nil) throws -> Int {
        try assets.withFile(source.sourceFile) { fd, size in
            guard size == Int64(source.byteLength), size <= 16 * 1024 * 1024,
                  try SafeDirectory.read(fd: fd, offset: 0, count: Int(size)).sha256Hex == source.sourceSHA256 else {
                throw ResourceError.rejected("sound_source_changed")
            }
            // ffmpeg writes at most 11 seconds of mono PCM. Unlink the output
            // immediately so only the decoder and this process can access it.
            var path = Array((NSTemporaryDirectory() + "mangekyou-pcm-XXXXXX").utf8CString)
            let outputFD = mkstemp(&path)
            guard outputFD >= 0 else { throw ResourceError.rejected("sound_probe_output_unavailable") }
            let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
            defer { try? output.close() }
            guard unlink(path) == 0 else { throw ResourceError.rejected("sound_probe_unlink_failed") }
            let window = seekMilliseconds.map { ["-ss", "\($0)ms", "-t", "20ms"] } ?? ["-t", "11"]
            try run("ffmpeg", fd: fd, arguments: ["-nostdin","-v","error","-xerror","-protocol_whitelist","fd",
                "-fd","0","-i","fd:","-map","0:a:0"] + window + ["-ac","1","-ar","44100",
                "-f","s16le","pipe:1"], output: output)
            return Int(try output.seekToEnd())
        }
    }

    private func run(_ name: String, fd: Int32, arguments: [String], output: FileHandle?) throws {
        guard lseek(fd,0,SEEK_SET) == 0 else { throw ResourceError.rejected("movie_source_seek_failed") }
        let process = Process()
        process.executableURL = tools.appendingPathComponent(name)
        process.arguments = arguments
        process.standardInput = FileHandle(fileDescriptor: fd,closeOnDealloc: false)
        process.standardOutput = output ?? FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + 15) == .timedOut {
            kill(process.processIdentifier,SIGKILL)
            process.waitUntilExit()
            throw ResourceError.rejected("movie_decoder_timeout")
        }
        guard process.terminationStatus == 0 else { throw ResourceError.rejected("movie_decoder_failed") }
    }
}
