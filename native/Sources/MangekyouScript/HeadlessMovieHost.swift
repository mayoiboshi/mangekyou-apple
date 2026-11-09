import Foundation
import Darwin
import MangekyouCore

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
