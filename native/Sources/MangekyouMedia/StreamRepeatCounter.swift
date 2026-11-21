import AVFoundation
import Foundation

/// Counts finite repeats from successful end-of-stream callbacks. AVAudioPlayer
/// retains its configured loop count, so it cannot supply this checkpoint.
package final class StreamRepeatCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var requested: Int32 = 0
    private var remaining: Int32 = 0
    private var terminal = false

    package init() {}

    package var configuredRepeats: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    package func configure(_ repeats: Int32, player: AVAudioPlayer) {
        lock.lock()
        defer { lock.unlock() }
        guard !terminal else { return }
        requested = repeats
        remaining = repeats
        player.numberOfLoops = repeats < 0 ? -1 : 0
    }

    /// A nil outcome means the active stream has another pass, or the owner
    /// already stopped it and a late delegate callback has nothing to do.
    package func finished(_ player: AVAudioPlayer, succeeded: Bool) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        guard !terminal else { return nil }
        if succeeded, remaining > 0 {
            player.currentTime = 0
            if player.play() {
                remaining -= 1
                return nil
            }
            terminal = true
            return false
        }
        terminal = true
        return succeeded
    }

    package func checkpoint(_ player: AVAudioPlayer) -> (seconds: Double, requested: Int32, remaining: Int32)? {
        lock.lock()
        defer { lock.unlock() }
        guard !terminal, requested > 0, player.isPlaying else { return nil }
        let seconds = player.currentTime
        guard seconds.isFinite, seconds >= 0, seconds < player.duration else { return nil }
        return (seconds, requested, remaining)
    }

    package func stop(_ player: AVAudioPlayer) {
        lock.lock()
        terminal = true
        lock.unlock()
        player.stop()
    }
}
