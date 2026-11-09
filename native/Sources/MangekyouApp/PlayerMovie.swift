import AVKit
import Foundation
import MangekyouCore

struct PlayerMovie: Sendable {
    let url: URL
    let directory: URL
    static let maximumDuration: Double = 600
    static let maximumSceneDuration: Double = 10
    private static let maximumOutputBytes = 256 * 1024 * 1024

    func remove() { try? FileManager.default.removeItem(at: directory) }

    private struct ConversionExit: Error, CustomStringConvertible {
        let status: Int32
        var description: String { "player_media_conversion_failed: \(status)" }
    }

    static func captureFrame(in asset: AVAsset, at requested: CMTime) async throws -> (CGImage, CMTime) {
        let generator = AVAssetImageGenerator(asset: asset)
        let tolerance = CMTime(value: 1, timescale: 10)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let (frame, actual) = try await generator.image(at: requested)
        try Task.checkCancellation()
        let delta = CMTimeSubtract(actual, requested)
        guard delta.isNumeric, CMTimeCompare(delta, tolerance) <= 0,
              CMTimeCompare(delta, CMTimeMultiply(tolerance, multiplier: -1)) >= 0 else {
            throw ResourceError.rejected("game_thread_cutin_frame_time_mismatch")
        }
        return (frame, actual)
    }

    static func prepare(_ request: ScriptMachine.MoviePlaybackRequest, assets: SafeDirectory, ffmpeg: URL) async throws -> Self {
        try await prepare(resource: request.resource, assets: assets, ffmpeg: ffmpeg)
    }

    static func prepare(resource: ScriptLocation, assets: SafeDirectory, ffmpeg: URL,
                        embeddedRange: (offset: Int, length: Int, sha256: String)? = nil) async throws -> Self {
        let mappings = ["-map", "0:v:0"] + (embeddedRange == nil ? ["-map", "0:a:0?"] : [])
        // The verified Chinese ending has backwards audio timestamps. Its
        // video timestamps and decoded audio sample count agree independently.
        let preservesEndingTiming = embeddedRange == nil &&
            resource.sourceSHA256 == "ba920c98e296e8f0d48ecd59141f81edc61f4eadad0509e69d63149d7e5fcb58"
        let inputOptions = preservesEndingTiming ? ["-copyts"] : []
        let audioFilter = preservesEndingTiming ? "asetpts=N/SR/TB" : "aresample=async=1"
        let audio = embeddedRange == nil ? ["-af", audioFilter, "-c:a", "aac"] : []
        let videoTiming = preservesEndingTiming ? ["-fps_mode", "passthrough", "-enc_time_base:v", "demux"] : []
        let output = ["-pix_fmt", "yuv420p"] + videoTiming + audio
        let movie: Self
        do {
            movie = try convert(resource, assets: assets, ffmpeg: ffmpeg, filename: "movie.mp4", embeddedRange: embeddedRange,
                                inputOptions: inputOptions, options: mappings + ["-c:v", "h264_videotoolbox"] + output)
        } catch let hardware as ConversionExit {
            do {
                movie = try convert(resource, assets: assets, ffmpeg: ffmpeg, filename: "movie.mp4", embeddedRange: embeddedRange,
                                    inputOptions: inputOptions, options: mappings + ["-c:v", "libx264", "-preset", "veryfast"] + output)
            } catch let software as ConversionExit {
                throw ResourceError.rejected("player_video_conversion_failed: hardware \(hardware.status), software \(software.status)")
            }
        }
        do {
            let duration = try await AVURLAsset(url: movie.url).load(.duration).seconds
            try Task.checkCancellation()
            try validateDuration(duration)
            return movie
        } catch {
            movie.remove()
            throw error
        }
    }

    static func prepareSceneVideo(_ source: ScriptLocation, assets: SafeDirectory, ffmpeg: URL) throws -> Self {
        let timing = ["-map", "0:v:0", "-an", "-fps_mode", "passthrough",
                      "-enc_time_base:v", "demux", "-pix_fmt", "yuv420p"]
        do {
            return try convert(source, assets: assets, ffmpeg: ffmpeg, filename: "scene.mp4",
                               durationLimit: maximumSceneDuration, byteLimit: 64 * 1024 * 1024, timeout: 15,
                               options: timing + ["-c:v", "h264_videotoolbox"])
        } catch is ConversionExit {
            return try convert(source, assets: assets, ffmpeg: ffmpeg, filename: "scene.mp4",
                               durationLimit: maximumSceneDuration, byteLimit: 64 * 1024 * 1024, timeout: 15,
                               options: timing + ["-c:v", "libx264", "-preset", "veryfast"])
        }
    }

    static func validateDuration(_ seconds: Double) throws {
        guard seconds.isFinite, seconds > 0 else {
            throw ResourceError.rejected("player_media_duration_invalid")
        }
        guard seconds <= maximumDuration else {
            throw ResourceError.rejected("player_media_duration_limit")
        }
    }

    static func prepareAudio(_ source: ScriptLocation, assets: SafeDirectory, ffmpeg: URL) throws -> Self {
        try convert(source, assets: assets, ffmpeg: ffmpeg, filename: "sound.m4a",
                    options: ["-map", "0:a:0", "-c:a", "alac"])
    }

    static func savedDirectBufferBytes(_ source: ScriptLocation, assets: SafeDirectory, ffmpeg: URL) throws -> Int {
        // 0x59f792–0x59f7a2 constructs a mono, 16-bit, 44.1 kHz buffer.
        let pcm = try convert(source, assets: assets, ffmpeg: ffmpeg, filename: "probe.pcm",
                              durationLimit: 10, byteLimit: 2 * 1024 * 1024, timeout: 15,
                              options: ["-map", "0:a:0", "-ac", "1", "-ar", "44100", "-f", "s16le"])
        defer { pcm.remove() }
        return try SafeDirectory(pcm.directory).withFile("probe.pcm") { _, size in Int(size) }
    }

    private static func convert(_ source: ScriptLocation, assets: SafeDirectory, ffmpeg: URL,
                                filename: String, embeddedRange: (offset: Int, length: Int, sha256: String)? = nil,
                                inputOptions: [String] = [], durationLimit: Double = maximumDuration,
                                byteLimit: Int = maximumOutputBytes, timeout: Int = 120,
                                options: [String]) throws -> Self {
        try Task.checkCancellation()
        // Resolve the OS-owned temporary root before strict no-symlink traversal.
        let temporaryPath = FileManager.default.temporaryDirectory.path
        guard let canonical = temporaryPath.withCString({ realpath($0, nil) }) else {
            throw ResourceError.system("player_media_temporary_root", errno)
        }
        let temporaryRoot = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
        free(canonical)
        let folder = temporaryRoot.appendingPathComponent("mangekyou-private-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let movie = Self(url: folder.appendingPathComponent(filename), directory: folder)
        do {
            let inputName = "embedded.ogv"
            let inputURL = folder.appendingPathComponent(inputName)
            defer { if embeddedRange != nil { try? FileManager.default.removeItem(at: inputURL) } }
            try assets.withFile(source.sourceFile) { sourceFD, size in
                guard source.byteOffset == 0, size == source.byteLength,
                      source.rangeSHA256 == source.sourceSHA256,
                      try SafeDirectory.movieSHA256(fd: sourceFD, size: size) == source.sourceSHA256 else {
                    throw ResourceError.rejected("player_media_source_changed")
                }
                try Task.checkCancellation()
                if let range = embeddedRange {
                    guard range.offset >= 0, (1...32 * 1024 * 1024).contains(range.length),
                          Int64(range.offset) <= size, Int64(range.length) <= size - Int64(range.offset) else {
                        throw ResourceError.rejected("player_embedded_video_range")
                    }
                    let bytes = try SafeDirectory.read(fd: sourceFD, offset: Int64(range.offset), count: range.length)
                    guard bytes.starts(with: Data("OggS".utf8)), bytes.sha256Hex == range.sha256 else {
                        throw ResourceError.rejected("player_embedded_video_identity")
                    }
                    try bytes.write(to: inputURL, options: .withoutOverwriting)
                }
                func runConverter(_ fd: Int32) throws {
                    guard lseek(fd, 0, SEEK_SET) == 0 else {
                        throw ResourceError.rejected("player_media_source_seek_failed")
                    }
                    let process = Process()
                    process.executableURL = ffmpeg
                    process.arguments = ["-nostdin", "-v", "error", "-xerror", "-protocol_whitelist", "fd",
                                         "-fd", "0"] + inputOptions + ["-i", "fd:"] + options +
                        ["-t", String(durationLimit + 1), "-fs", String(byteLimit), movie.url.path]
                    process.standardInput = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    let done = DispatchSemaphore(value: 0)
                    process.terminationHandler = { _ in done.signal() }
                    try Task.checkCancellation()
                    do { try process.run() }
                    catch { throw ResourceError.rejected("player_media_converter_launch_failed: \(error.localizedDescription)") }
                    let deadline = DispatchTime.now() + .seconds(timeout)
                    while done.wait(timeout: min(deadline, .now() + .milliseconds(100))) == .timedOut {
                        if Task.isCancelled || DispatchTime.now() >= deadline {
                            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                            process.waitUntilExit()
                            try Task.checkCancellation()
                            throw ResourceError.rejected("player_media_conversion_timeout")
                        }
                    }
                    try Task.checkCancellation()
                    guard process.terminationStatus == 0 else {
                        throw ConversionExit(status: process.terminationStatus)
                    }
                }
                if embeddedRange != nil {
                    try SafeDirectory(folder).withFile(inputName) { fd, _ in try runConverter(fd) }
                } else {
                    try runConverter(sourceFD)
                }
            }
            let output = try SafeDirectory(folder)
            do {
                try output.withFile(filename) { _, size in
                    guard size > 0 else { throw ResourceError.rejected("player_media_output_empty") }
                    guard size < Int64(byteLimit) else {
                        throw ResourceError.rejected("player_media_output_limit")
                    }
                }
            } catch ResourceError.system(_, let code) where code == ENOENT {
                throw ResourceError.rejected("player_media_output_missing")
            }
            return movie
        } catch {
            movie.remove()
            throw error
        }
    }
}
