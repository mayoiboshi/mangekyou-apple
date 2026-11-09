import AVKit
import Foundation
import MangekyouCore

struct PlayerMovie: Sendable {
    let url: URL
    let directory: URL
    static let maximumDuration: Double = 600
    private static let maximumOutputBytes = 256 * 1024 * 1024

    func remove() { try? FileManager.default.removeItem(at: directory) }

    private struct ConversionExit: Error, CustomStringConvertible {
        let status: Int32
        var description: String { "player_media_conversion_failed: \(status)" }
    }

    static func prepare(_ request: ScriptMachine.MoviePlaybackRequest, assets: SafeDirectory, ffmpeg: URL) async throws -> Self {
        try await prepare(resource: request.resource, assets: assets, ffmpeg: ffmpeg)
    }

    static func prepare(resource: ScriptLocation, assets: SafeDirectory, ffmpeg: URL,
                        embeddedRange: (offset: Int, length: Int, sha256: String)? = nil) async throws -> Self {
        let mappings = ["-map", "0:v:0"] + (embeddedRange == nil ? ["-map", "0:a:0?"] : [])
        let output = ["-pix_fmt", "yuv420p", "-c:a", "aac"]
        let movie: Self
        do {
            movie = try convert(resource, assets: assets, ffmpeg: ffmpeg, filename: "movie.mp4", embeddedRange: embeddedRange,
                                options: mappings + ["-c:v", "h264_videotoolbox"] + output)
        } catch let hardware as ConversionExit {
            do {
                movie = try convert(resource, assets: assets, ffmpeg: ffmpeg, filename: "movie.mp4", embeddedRange: embeddedRange,
                                    options: mappings + ["-c:v", "libx264", "-preset", "veryfast"] + output)
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

    private static func convert(_ source: ScriptLocation, assets: SafeDirectory, ffmpeg: URL,
                                filename: String, embeddedRange: (offset: Int, length: Int, sha256: String)? = nil,
                                options: [String]) throws -> Self {
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
                                         "-fd", "0", "-i", "fd:"] + options +
                        ["-t", String(maximumDuration + 1), "-fs", String(maximumOutputBytes), movie.url.path]
                    process.standardInput = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    let done = DispatchSemaphore(value: 0)
                    process.terminationHandler = { _ in done.signal() }
                    try Task.checkCancellation()
                    do { try process.run() }
                    catch { throw ResourceError.rejected("player_media_converter_launch_failed: \(error.localizedDescription)") }
                    let deadline = DispatchTime.now() + 120
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
                    guard size < Int64(maximumOutputBytes) else {
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
