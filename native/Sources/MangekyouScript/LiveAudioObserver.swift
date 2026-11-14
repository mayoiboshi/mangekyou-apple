import Foundation
import AVFoundation
import Dispatch
import MangekyouCore

private final class LiveAudioCompletion: NSObject, AVAudioPlayerDelegate {
    nonisolated private let lock = NSLock()
    nonisolated(unsafe) private var outcome: Bool?
    nonisolated override init() { super.init() }
    nonisolated var succeeded: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return outcome
    }

    nonisolated private func finish(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        outcome = value
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finish(flag)
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        finish(false)
    }
}

/// Optional muted host for measuring actual AVAudioPlayer positions. Its
/// realtime clock is independent of the accelerated script's virtual time.
final class LiveAudioObserver {
    struct CompletionEvent: Encodable {
        let channel: Int32
        let playbackStartStep: Int
        let source: ScriptLocation
    }
    struct LifecycleEvent: Encodable {
        let action: String
        let channel: Int32?
        let playbackStep: Int?
        let sourceSHA256: String
    }
    struct FilterUpdateEvent: Encodable {
        let channel: Int32?
        let previousFilter: String
        let updatedFilter: String
        let previousPositionMilliseconds: Double
        let replacementPositionMilliseconds: Double
        let sourceSHA256: String
    }
    private enum Control: Hashable { case volume, pan }
    private struct ControlKey: Hashable { let channel: UInt64; let control: Control }
    private struct PendingControl {
        let change: ScriptMachine.SoundControlChange
        let startNanoseconds: UInt64
        let initial: Float
        let target: Float
        let targetIsRepresentable: Bool
    }
    private struct Entry {
        let player: AVAudioPlayer
        let completion: LiveAudioCompletion
        let source: ScriptLocation
        let bytes: Int
        let durationMilliseconds: Int32
        let volumeFilter: StreamVolumeFilterCandidate?
        let filterChainText: String?
        let timeScalePitch: Int32?
        var playbackStep: Int?
    }
    private var entries: [UInt64: Entry] = [:]
    private var directEntries: [UInt64: Entry] = [:]
    private(set) var directStarts = 0
    private(set) var directCompletions = 0
    private(set) var directCompletionEvents: [CompletionEvent] = []
    private(set) var directCompletionEventsTruncated = false
    // Channel envelope remains independent of the configured category gain.
    private var rawVolumes: [UInt64: Float] = [:]
    private let byteLimit = 96 * 1024 * 1024
    private let maximumStarts: Int
    private let allowVolumeFilter: Bool
    private let forceMuteOutput: Bool
    private let allowFilterChain: Bool
    private let allowTimeScale: Bool
    private let candidateSampleRate: Int
    private(set) var starts = 0
    private(set) var volumeFilterStarts = 0
    private(set) var filterChainStarts = 0
    private(set) var unfilteredCandidateStarts = 0
    private(set) var volumeFilterUpdates = 0
    private(set) var filterChainClears = 0
    private(set) var timeScaleStarts = 0
    private(set) var lastTimeScaleSourceDurationMilliseconds: Int32?
    private(set) var lastTimeScaleOutputDurationMilliseconds: Int32?
    private(set) var recentFilterUpdates: [FilterUpdateEvent] = []
    private(set) var lastVolumeFilterAudioSHA256: String?
    private(set) var finiteRepeatStarts = 0
    private(set) var finiteRepeatReassertions = 0
    private var pendingControls: [ControlKey: PendingControl] = [:]
    private(set) var completedControlCount = 0
    private(set) var completedControlsByChannel: [UInt64: Int] = [:]
    private(set) var rejectedControlCount = 0
    private(set) var completedPlaybackCount = 0
    private(set) var completedPlaybackEvents: [CompletionEvent] = []
    private(set) var deferredSupersededSyncs = 0
    private(set) var streamSwapHandoffs = 0
    private(set) var streamSwapCancelledControls = 0
    private(set) var completionIdentityIssue: String?
    private(set) var completionIdentityChannel: Int32?
    private(set) var recentLifecycle: [LifecycleEvent] = []
    private(set) var observedCategoryGains: [Int32: Int32] = [:]
    private(set) var observedPlayerVolumes: [Int32: Float] = [:]
    var pendingControlCount: Int { pendingControls.count }
    var observedStreamIndices: [Int32] {
        entries.keys.compactMap(ScriptMachine.streamSaveChannelIndex).sorted()
    }
    private let clock = ContinuousClock()
    private let deadline: ContinuousClock.Instant

    init(maximumSeconds: Int = 120, maximumStarts: Int = 512, allowVolumeFilter: Bool = false,
         forceMuteOutput: Bool = false, candidateSampleRate: Int = 22050, allowFilterChain: Bool = false,
         allowTimeScale: Bool = false) {
        self.maximumStarts = maximumStarts
        self.allowVolumeFilter = allowVolumeFilter
        self.forceMuteOutput = forceMuteOutput
        self.allowFilterChain = allowFilterChain
        self.allowTimeScale = allowTimeScale
        self.candidateSampleRate = candidateSampleRate
        deadline = ContinuousClock.now.advanced(by: .seconds(maximumSeconds))
    }

    deinit {
        for entry in entries.values { entry.player.stop() }
        for entry in directEntries.values { entry.player.stop() }
    }

    private func recordLifecycle(_ action: String, channel: UInt64, entry: Entry) {
        if recentLifecycle.count == 128 { recentLifecycle.removeFirst() }
        recentLifecycle.append(.init(action: action, channel: ScriptMachine.streamSaveChannelIndex(channel),
                                     playbackStep: entry.playbackStep, sourceSHA256: entry.source.sourceSHA256))
    }

    func retainActiveChannels(_ active: Set<UInt64>) {
        for channel in directEntries.keys.filter({ !active.contains($0) }) {
            directEntries.removeValue(forKey: channel)?.player.stop()
        }
        for channel in entries.keys.filter({ !active.contains($0) }) {
            if let entry = entries.removeValue(forKey: channel) {
                recordLifecycle("inactive_removed", channel: channel, entry: entry)
                entry.player.stop()
            }
            rawVolumes.removeValue(forKey: channel)
            pendingControls.removeValue(forKey: .init(channel: channel, control: .volume))
            pendingControls.removeValue(forKey: .init(channel: channel, control: .pan))
        }
    }

    func hasSupersededStream(channel: UInt64, source: ScriptLocation, playbackStep: Int) -> Bool {
        guard let entry = entries[channel] else { return false }
        return entry.source != source || entry.playbackStep != playbackStep
    }

    func exchangeStreams(_ request: ScriptMachine.SoundSwapRequest,
                         snapshots: [UInt64: (source: ScriptLocation?, step: Int?)]) throws {
        guard clock.now < deadline else { throw ResourceError.rejected("live_audio_time_limit") }
        let first = request.first, second = request.second
        guard ScriptMachine.streamSaveChannelIndex(first) != nil,
              ScriptMachine.streamSaveChannelIndex(second) != nil else {
            throw ResourceError.rejected("live_audio_swap_channel_invalid")
        }
        let oldFirst = entries[first], oldSecond = entries[second]
        func check(_ entry: Entry?, destination: UInt64) throws {
            guard let expected = snapshots[destination] else { return }
            guard let entry, let step = expected.step, entry.source == expected.source,
                  entry.playbackStep == step else {
                throw ResourceError.rejected("live_audio_swap_identity_mismatch")
            }
        }
        try check(oldFirst, destination: second)
        try check(oldSecond, destination: first)
        let affected: Set<UInt64> = [first, second]
        let cancelled = pendingControls.keys.filter { affected.contains($0.channel) }
        for key in cancelled { pendingControls.removeValue(forKey: key) }
        streamSwapCancelledControls += cancelled.count
        if first != second {
            let firstVolume = rawVolumes.removeValue(forKey: first)
            let secondVolume = rawVolumes.removeValue(forKey: second)
            entries.removeValue(forKey: first)
            entries.removeValue(forKey: second)
            if let oldFirst {
                if snapshots[second] != nil {
                    entries[second] = oldFirst
                    rawVolumes[second] = firstVolume
                    recordLifecycle("swapped", channel: second, entry: oldFirst)
                } else {
                    recordLifecycle("swap_inactive_removed", channel: first, entry: oldFirst)
                    oldFirst.player.stop()
                }
            }
            if let oldSecond {
                if snapshots[first] != nil {
                    entries[first] = oldSecond
                    rawVolumes[first] = secondVolume
                    recordLifecycle("swapped", channel: first, entry: oldSecond)
                } else {
                    recordLifecycle("swap_inactive_removed", channel: second, entry: oldSecond)
                    oldSecond.player.stop()
                }
            }
        } else if snapshots[first] == nil, let entry = entries.removeValue(forKey: first) {
            rawVolumes.removeValue(forKey: first)
            recordLifecycle("swap_inactive_removed", channel: first, entry: entry)
            entry.player.stop()
        }
        streamSwapHandoffs += 1
    }

    func directPlaybackIdentitiesMatch(_ snapshots: [UInt64: (source: ScriptLocation?, step: Int?)]) -> Bool {
        guard snapshots.count == directEntries.count else { return false }
        return snapshots.allSatisfy { channel, snapshot in
            guard let entry = directEntries[channel] else { return false }
            return entry.source == snapshot.source && entry.playbackStep == snapshot.step && entry.player.isPlaying
        }
    }

    func startDirect(channel: UInt64, source: ScriptLocation, playbackStep: Int,
                     decoder: HeadlessMovieHost) throws -> Int32 {
        guard ScriptMachine.directSoundChannelIndex(channel) != nil, clock.now < deadline,
              directStarts + starts < maximumStarts, directEntries[channel] == nil,
              directEntries.count + entries.count < 8 else {
            throw ResourceError.rejected("live_direct_audio_outside_profile")
        }
        let used = entries.values.reduce(0) { $0 + $1.bytes } + directEntries.values.reduce(0) { $0 + $1.bytes }
        guard used <= byteLimit else { throw ResourceError.rejected("live_direct_audio_memory_limit") }
        let converted = try decoder.audioForLiveObserver(source, maximumOutputBytes: byteLimit - used,
                                                         candidateSampleRate: candidateSampleRate)
        guard converted.data.count <= byteLimit - used, converted.durationMilliseconds > 0,
              converted.durationMilliseconds <= 30_000 else {
            throw ResourceError.rejected("live_direct_audio_duration_or_memory_limit")
        }
        let player = try AVAudioPlayer(data: converted.data)
        let completion = LiveAudioCompletion()
        player.delegate = completion
        player.volume = 0
        guard player.duration.isFinite, abs(player.duration - converted.duration) <= max(0.1, converted.duration * 0.001),
              player.prepareToPlay(), player.play() else {
            throw ResourceError.rejected("live_direct_audio_start_failed")
        }
        directEntries[channel] = Entry(player: player, completion: completion, source: source,
            bytes: converted.data.count, durationMilliseconds: converted.durationMilliseconds,
            volumeFilter: nil, filterChainText: nil, timeScalePitch: nil, playbackStep: playbackStep)
        directStarts += 1
        return converted.durationMilliseconds
    }

    @discardableResult
    func start(channel: UInt64, source: ScriptLocation, playbackStep: Int?, repeats: Int32,
               preservePosition: Bool, seek: Int32?, volumeFilter: StreamVolumeFilterCandidate? = nil,
               filterChainText: String? = nil,
               decoder: HeadlessMovieHost) throws -> Int32? {
        guard ScriptMachine.streamSaveChannelIndex(channel) != nil else { return nil }
        guard clock.now < deadline else { throw ResourceError.rejected("live_audio_time_limit") }
        guard volumeFilter == nil || allowVolumeFilter else { throw ResourceError.rejected("live_audio_stream_filter_application_unverified") }
        guard filterChainText == nil || (allowFilterChain && forceMuteOutput && candidateSampleRate == 44100 && volumeFilter == nil) else {
            throw ResourceError.rejected("live_audio_stream_filter_chain_unsupported")
        }
        if preservePosition {
            guard seek == nil, (-1...1024).contains(repeats),
                  let previous = entries[channel], previous.player.isPlaying,
                  previous.source == source, previous.playbackStep == playbackStep,
                  previous.volumeFilter == volumeFilter, previous.filterChainText == filterChainText,
                  previous.timeScalePitch == nil else {
                throw ResourceError.rejected("live_audio_preserved_stream_unavailable")
            }
            previous.player.numberOfLoops = Int(repeats)
            if repeats > 0 { finiteRepeatReassertions += 1 }
            return previous.durationMilliseconds
        }
        pendingControls.removeValue(forKey: .init(channel: channel, control: .volume))
        pendingControls.removeValue(forKey: .init(channel: channel, control: .pan))
        guard (-1...1024).contains(repeats) else {
            throw ResourceError.rejected("live_audio_repeat_count_outside_profile")
        }
        guard starts + directStarts < maximumStarts else { throw ResourceError.rejected("live_audio_start_limit") }
        let used = entries.values.reduce(0) { $0 + $1.bytes } + directEntries.values.reduce(0) { $0 + $1.bytes }
        guard used <= byteLimit, entries[channel] != nil || entries.count + directEntries.count < 8 else {
            throw ResourceError.rejected("live_audio_memory_limit")
        }
        let timeScale = filterChainText.flatMap { try? StreamTimeScaleCandidate.pitch(researchFilterText: $0) }
        guard timeScale == nil || (allowTimeScale && seek == nil) else {
            throw ResourceError.rejected("live_audio_timescale_state_unsupported")
        }
        let chain = try timeScale == nil ? filterChainText.map { try StreamFilterChainCandidate(researchFilterText: $0) } : nil
        let outputFilter = allowVolumeFilter && chain == nil ? (volumeFilter ?? StreamVolumeFilterCandidate()) : nil
        let converted: (data: Data, duration: Double, durationMilliseconds: Int32)
        if let timeScale {
            let candidate = try decoder.audioForTimeScale(source, pitch: timeScale, maximumOutputBytes: byteLimit - used)
            converted = (candidate.data, candidate.duration, candidate.durationMilliseconds)
        } else {
            converted = try decoder.audioForLiveObserver(source, volumeFilter: outputFilter, chainFilter: chain,
                maximumOutputBytes: byteLimit - used, candidateSampleRate: candidateSampleRate)
        }
        guard converted.data.count <= byteLimit - used else { throw ResourceError.rejected("live_audio_memory_limit") }
        let player = try AVAudioPlayer(data: converted.data)
        let completion = LiveAudioCompletion()
        player.delegate = completion
        guard player.duration.isFinite, abs(player.duration - converted.duration) <= max(0.1, converted.duration * 0.001) else {
            throw ResourceError.rejected("live_audio_duration_mismatch")
        }
        if let seek {
            guard seek >= 0, Double(seek) / 1000 < player.duration else {
                throw ResourceError.rejected("live_audio_seek_outside_track")
            }
            player.currentTime = Double(seek) / 1000
        }
        player.numberOfLoops = Int(repeats)
        // Candidate-mode samples are audible. Start muted until the first
        // synchronization applies channel and category gain.
        player.volume = allowVolumeFilter ? 0 : 1
        guard player.prepareToPlay(), player.play() else { throw ResourceError.rejected("live_audio_start_failed") }
        if let previous = entries[channel] {
            recordLifecycle("replaced", channel: channel, entry: previous)
            previous.player.stop()
        }
        entries[channel] = Entry(player: player, completion: completion, source: source,
                                 bytes: converted.data.count, durationMilliseconds: converted.durationMilliseconds,
                                 volumeFilter: volumeFilter, filterChainText: filterChainText, timeScalePitch: timeScale,
                                 playbackStep: playbackStep)
        if let entry = entries[channel] { recordLifecycle("started", channel: channel, entry: entry) }
        rawVolumes[channel] = 1
        starts += 1
        if allowVolumeFilter {
            if timeScale != nil {
                timeScaleStarts += 1
                lastTimeScaleSourceDurationMilliseconds = converted.durationMilliseconds
                lastTimeScaleOutputDurationMilliseconds = Int32((converted.duration * 1000).rounded(.toNearestOrEven))
            }
            else if chain != nil { filterChainStarts += 1 }
            else if volumeFilter == nil { unfilteredCandidateStarts += 1 } else { volumeFilterStarts += 1 }
            lastVolumeFilterAudioSHA256 = converted.data.sha256Hex
        }
        if repeats > 0 { finiteRepeatStarts += 1 }
        return converted.durationMilliseconds
    }

    /// Rebuild the bounded candidate while the previous player continues, then
    /// replace it at the sampled playhead. This is not gapless or original timing.
    func updateVolumeFilter(_ request: ScriptMachine.SoundFilterRequest, decoder: HeadlessMovieHost) throws {
        guard allowVolumeFilter, clock.now < deadline,
              let old = entries[request.channel], old.player.isPlaying,
              old.timeScalePitch == nil,
              old.filterChainText == request.previousChain,
              request.previousChain == nil || (allowFilterChain && forceMuteOutput && request.updated == nil),
              old.source == request.source, old.playbackStep == request.playbackStep,
              old.volumeFilter == request.previous,
              old.player.numberOfLoops == 0 || old.player.numberOfLoops == -1,
              pendingControls.keys.allSatisfy({ $0.channel != request.channel }), starts + directStarts < maximumStarts else {
            throw ResourceError.rejected("live_audio_volume_update_identity_or_state_unsupported")
        }
        let used = entries.values.reduce(0) { $0 + $1.bytes } + directEntries.values.reduce(0) { $0 + $1.bytes }
        guard used <= byteLimit else { throw ResourceError.rejected("live_audio_memory_limit") }
        let converted = try decoder.audioForLiveObserver(request.source,
            volumeFilter: request.updated ?? StreamVolumeFilterCandidate(), maximumOutputBytes: byteLimit - used,
            candidateSampleRate: candidateSampleRate)
        guard converted.data.count <= byteLimit - used else {
            throw ResourceError.rejected("live_audio_memory_limit")
        }
        let player = try AVAudioPlayer(data: converted.data)
        let completion = LiveAudioCompletion()
        player.delegate = completion
        guard player.duration.isFinite, abs(player.duration - old.player.duration) <= 0.02,
              old.player.isPlaying, old.completion.succeeded == nil, player.prepareToPlay() else {
            throw ResourceError.rejected("live_audio_volume_update_player_unavailable")
        }
        old.player.pause()
        let position = old.player.currentTime
        guard position >= 0, position < player.duration else {
            _ = old.player.play()
            throw ResourceError.rejected("live_audio_volume_update_position_outside_track")
        }
        player.currentTime = position
        guard abs(player.currentTime - position) <= 0.05 else {
            _ = old.player.play()
            throw ResourceError.rejected("live_audio_volume_update_seek_tolerance_exceeded")
        }
        player.numberOfLoops = old.player.numberOfLoops
        player.volume = old.player.volume
        player.pan = old.player.pan
        guard player.play() else {
            _ = old.player.play()
            throw ResourceError.rejected("live_audio_volume_update_start_failed")
        }
        old.player.stop()
        recordLifecycle("filter_replaced", channel: request.channel, entry: old)
        entries[request.channel] = Entry(player: player, completion: completion, source: request.source,
            bytes: converted.data.count, durationMilliseconds: converted.durationMilliseconds,
            volumeFilter: request.updated, filterChainText: nil, timeScalePitch: nil, playbackStep: request.playbackStep)
        if recentFilterUpdates.count == 128 { recentFilterUpdates.removeFirst() }
        recentFilterUpdates.append(.init(channel: ScriptMachine.streamSaveChannelIndex(request.channel),
            previousFilter: request.previousChain != nil ? "chain" : (request.previous == nil ? "none" : "volume"),
            updatedFilter: request.updated == nil ? "none" : "volume",
            previousPositionMilliseconds: position * 1000, replacementPositionMilliseconds: player.currentTime * 1000,
            sourceSHA256: request.source.sourceSHA256))
        starts += 1
        if request.previousChain != nil { filterChainClears += 1 } else { volumeFilterUpdates += 1 }
        lastVolumeFilterAudioSHA256 = converted.data.sha256Hex
    }

    /// Give a stopped, identity-matched player a short opportunity to deliver
    /// its delegate result. A stopped player is never treated as successful EOF
    /// without that result; a timeout leaves the caller's strict check in place.
    func awaitStoppedCompletion(for snapshots: [UInt64: (source: ScriptLocation?, step: Int?)]) throws -> Bool {
        guard clock.now < deadline else { throw ResourceError.rejected("live_audio_time_limit") }
        var pending: [LiveAudioCompletion] = []
        for (channel, snapshot) in snapshots {
            guard let entry = entries[channel] else {
                completionIdentityIssue = "recovery_observer_entry_missing"
                completionIdentityChannel = ScriptMachine.streamSaveChannelIndex(channel)
                throw ResourceError.rejected("live_audio_completion_identity_mismatch")
            }
            guard entry.source == snapshot.source else {
                completionIdentityIssue = "recovery_source_mismatch"
                completionIdentityChannel = ScriptMachine.streamSaveChannelIndex(channel)
                throw ResourceError.rejected("live_audio_completion_identity_mismatch")
            }
            guard entry.playbackStep == snapshot.step else {
                completionIdentityIssue = "recovery_playback_step_mismatch"
                completionIdentityChannel = ScriptMachine.streamSaveChannelIndex(channel)
                throw ResourceError.rejected("live_audio_completion_identity_mismatch")
            }
            if !entry.player.isPlaying && entry.completion.succeeded == nil {
                pending.append(entry.completion)
            }
        }
        guard !pending.isEmpty else { return false }
        let waitDeadline = clock.now.advanced(by: .milliseconds(20))
        while pending.contains(where: { $0.succeeded == nil }), clock.now < waitDeadline, clock.now < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.001))
        }
        return true
    }

    /// Advance only controls for matching live players. This host uses wall
    /// time, so it is not evidence of original-engine fade equivalence.
    func synchronizeControls(machine: inout ScriptMachine, excluding deferred: Set<UInt64> = []) throws {
        guard clock.now < deadline else { throw ResourceError.rejected("live_audio_time_limit") }
        var accepted: [UInt64: StreamVolumeFilterCandidate] = [:]
        var acceptedChains: [UInt64: String] = [:]
        if allowVolumeFilter {
            for (channel, filter) in machine.researchActiveStreamVolumeFilters {
                let snapshot = machine.activeStreamPlaybackSnapshots[channel]
                if let entry = entries[channel], entry.volumeFilter == filter,
                   snapshot?.source == entry.source, snapshot?.step == entry.playbackStep {
                    accepted[channel] = filter
                } else if machine.phase == .waitingForMedia, machine.soundPlaybackChannel == channel,
                          machine.soundPlaybackRequest == snapshot?.source {
                    accepted[channel] = filter
                }
            }
        }
        if allowFilterChain {
            for (channel, text) in machine.researchActiveStreamFilterChains {
                if (try? StreamTimeScaleCandidate.pitch(researchFilterText: text)) != nil && !allowTimeScale { continue }
                let snapshot = machine.activeStreamPlaybackSnapshots[channel]
                if let entry = entries[channel], entry.filterChainText == text,
                   snapshot?.source == entry.source, snapshot?.step == entry.playbackStep {
                    acceptedChains[channel] = text
                } else if machine.phase == .waitingForMedia, machine.soundPlaybackChannel == channel,
                          machine.soundPlaybackRequest == snapshot?.source {
                    acceptedChains[channel] = text
                }
            }
        }
        if let issue = machine.researchLiveStreamFilterIssue(accepting: accepted, chains: acceptedChains) {
            throw ResourceError.rejected(issue)
        }
        deferredSupersededSyncs += deferred.filter { entries[$0] != nil }.count
        // AVAudioPlayer delivers completion on the creating run loop. Poll it
        // without waiting; a stopped player alone is not proof of normal EOF.
        for _ in 0...(entries.count + directEntries.count) {
            if !RunLoop.current.run(mode: .default, before: Date()) { break }
        }
        for (channel, entry) in directEntries {
            guard let succeeded = entry.completion.succeeded else { continue }
            guard succeeded, !entry.player.isPlaying, let step = entry.playbackStep,
                  let index = ScriptMachine.directSoundChannelIndex(channel),
                  let snapshot = machine.activeDirectPlaybackSnapshots[channel],
                  snapshot.source == entry.source, snapshot.step == step else {
                throw ResourceError.rejected("live_direct_audio_completion_identity_mismatch")
            }
            if directCompletionEvents.count < 64 {
                directCompletionEvents.append(.init(channel: index, playbackStartStep: step, source: entry.source))
            } else {
                directCompletionEventsTruncated = true
            }
            machine.acknowledgeSoundCompletion(channel: channel, playbackStartStep: step)
            directEntries.removeValue(forKey: channel)
            directCompletions += 1
        }
        for (channel, entry) in entries {
            guard !deferred.contains(channel) else { continue }
            guard let succeeded = entry.completion.succeeded else { continue }
            guard succeeded else { throw ResourceError.rejected("live_audio_playback_failed") }
            let snapshot = machine.activeStreamPlaybackSnapshots[channel]
            if entry.player.isPlaying { completionIdentityIssue = "callback_while_playing" }
            else if snapshot == nil { completionIdentityIssue = "machine_stream_missing" }
            else if snapshot?.source != entry.source { completionIdentityIssue = "source_mismatch" }
            else if entry.playbackStep == nil { completionIdentityIssue = "observer_step_missing" }
            else if snapshot?.step != entry.playbackStep { completionIdentityIssue = "playback_step_mismatch" }
            else { completionIdentityIssue = nil }
            completionIdentityChannel = completionIdentityIssue == nil ? nil : ScriptMachine.streamSaveChannelIndex(channel)
            guard completionIdentityIssue == nil, let step = entry.playbackStep else {
                throw ResourceError.rejected("live_audio_completion_identity_mismatch")
            }
            guard let index = ScriptMachine.streamSaveChannelIndex(channel) else {
                throw ResourceError.rejected("live_audio_completion_channel_unsupported")
            }
            if completedPlaybackEvents.count < 512 {
                completedPlaybackEvents.append(.init(channel: index, playbackStartStep: step, source: entry.source))
            }
            machine.acknowledgeSoundCompletion(channel: channel, playbackStartStep: step)
            recordLifecycle("completed", channel: channel, entry: entry)
            entries.removeValue(forKey: channel)
            rawVolumes.removeValue(forKey: channel)
            pendingControls.removeValue(forKey: .init(channel: channel, control: .volume))
            pendingControls.removeValue(forKey: .init(channel: channel, control: .pan))
            completedPlaybackCount += 1
        }
        let snapshots = machine.activeStreamPlaybackSnapshots
        let matching = Set(entries.compactMap { channel, entry -> UInt64? in
            guard !deferred.contains(channel), let snapshot = snapshots[channel], snapshot.source == entry.source,
                  snapshot.step == entry.playbackStep, entry.player.isPlaying else { return nil }
            return channel
        })
        for key in pendingControls.keys.filter({ !deferred.contains($0.channel) && !matching.contains($0.channel) }) {
            pendingControls.removeValue(forKey: key)
        }
        let now = DispatchTime.now().uptimeNanoseconds
        func sample(_ pending: PendingControl) -> (value: Float, fraction: Float) {
            let elapsed = Double(now - pending.startNanoseconds) / 1_000_000
            let afterDelay = max(0, elapsed - Double(pending.change.delay))
            let fraction: Float = elapsed < Double(pending.change.delay) ? 0 :
                (pending.change.duration == 0 ? 1 : Float(min(1, afterDelay / Double(pending.change.duration))))
            return (pending.initial + (pending.target - pending.initial) * fraction, fraction)
        }
        func queue(_ changes: [UInt64: ScriptMachine.SoundControlChange], control: Control) {
            for (channel, change) in changes {
                guard let player = entries[channel]?.player else { continue }
                let key = ControlKey(channel: channel, control: control)
                if let previous = pendingControls[key] {
                    let value = sample(previous).value
                    if control == .volume { rawVolumes[channel] = value } else { player.pan = value }
                }
                let initial = control == .volume ? (rawVolumes[channel] ?? 1) : player.pan
                let target: Float = control == .volume
                    ? Float(min(256, max(0, change.target))) / 256
                    : Float(min(256, max(-256, change.target))) / 256
                let targetIsRepresentable = control == .volume
                    ? (0...256).contains(change.target) : (-256...256).contains(change.target)
                pendingControls[key] =
                    .init(change: change, startNanoseconds: now, initial: initial, target: target,
                          targetIsRepresentable: targetIsRepresentable)
            }
        }
        queue(machine.takeSoundVolumeChanges(only: matching), control: .volume)
        queue(machine.takeSoundPanChanges(only: matching), control: .pan)
        for key in Array(pendingControls.keys) {
            guard let pending = pendingControls[key], let player = entries[key.channel]?.player,
                  matching.contains(key.channel) else { continue }
            let (value, fraction) = sample(pending)
            if key.control == .volume { rawVolumes[key.channel] = value } else { player.pan = value }
            if fraction == 1 {
                let actual = key.control == .volume ? (rawVolumes[key.channel] ?? 1) : player.pan
                let kind: ScriptMachine.SoundControlKind = key.control == .volume ? .volume : .pan
                if pending.targetIsRepresentable, abs(actual - pending.target) <= 0.0001,
                   machine.acknowledgeSoundControlChange(pending.change, channel: key.channel, kind: kind) {
                    completedControlCount += 1
                    completedControlsByChannel[key.channel, default: 0] += 1
                } else {
                    rejectedControlCount += 1
                }
                pendingControls.removeValue(forKey: key)
            }
        }
        let gains = try machine.soundCategoryGains(only: matching)
        observedCategoryGains.removeAll()
        observedPlayerVolumes.removeAll()
        for channel in matching {
            guard let player = entries[channel]?.player, let gain = gains[channel],
                  let index = ScriptMachine.streamSaveChannelIndex(channel) else { continue }
            player.volume = forceMuteOutput ? 0 : (rawVolumes[channel] ?? 1) * Float(gain) / 256
            observedCategoryGains[index] = gain
            observedPlayerVolumes[index] = player.volume
        }
    }

    func positions(for snapshots: [UInt64: (source: ScriptLocation?, step: Int?)]) throws -> [Int32: Int32] {
        guard clock.now < deadline else { throw ResourceError.rejected("live_audio_time_limit") }
        var positions: [Int32: Int32] = [:]
        for (channel, snapshot) in snapshots {
            guard let index = ScriptMachine.streamSaveChannelIndex(channel), let entry = entries[channel],
                  entry.source == snapshot.source, entry.playbackStep == snapshot.step, entry.player.isPlaying else {
                throw ResourceError.rejected("live_audio_playback_identity_or_state_mismatch")
            }
            // Candidate for 0x59c761 -> 0x5a1675 -> 0x404a9c: the
            // original stages seconds as Float32, scales, then uses FISTP.
            // The observed initialization uses nearest-even; live x87 state
            // and the original audio clock remain unverified.
            let position = Double(Float(entry.player.currentTime)) * 1000
            guard position.isFinite, position >= 0, position <= Double(Int32.max) else {
                throw ResourceError.rejected("live_audio_position_outside_profile")
            }
            positions[index] = Int32(position.rounded(.toNearestOrEven))
        }
        return positions
    }

    /// Report only identity and player state; resource names and audio data stay private.
    func positionFailure(for snapshots: [UInt64: (source: ScriptLocation?, step: Int?)]) -> String {
        guard clock.now < deadline else { return "time_limit" }
        for channel in snapshots.keys.sorted() {
            guard let snapshot = snapshots[channel] else { continue }
            guard let index = ScriptMachine.streamSaveChannelIndex(channel) else { return "invalid_channel" }
            guard let entry = entries[channel] else { return "channel=\(index),entry_missing" }
            guard entry.source == snapshot.source else { return "channel=\(index),source_mismatch" }
            guard entry.playbackStep == snapshot.step else { return "channel=\(index),step_mismatch" }
            guard entry.player.isPlaying else {
                let callback = entry.completion.succeeded.map { $0 ? "success" : "failure" } ?? "pending"
                return "channel=\(index),stopped,callback=\(callback)"
            }
            let position = entry.player.currentTime * 1000
            if !position.isFinite || position < 0 || position > Double(Int32.max) {
                return "channel=\(index),position_outside_profile"
            }
        }
        return "no_failure_on_resample"
    }

    func seek(_ request: ScriptMachine.SoundSeekRequest,
              snapshots: [UInt64: (source: ScriptLocation?, step: Int?)]) throws {
        guard clock.now < deadline,
              let entry = entries[request.channel], let snapshot = snapshots[request.channel],
              entry.source == request.source, snapshot.source == request.source,
              entry.playbackStep == request.playbackStep, snapshot.step == request.playbackStep,
              entry.player.isPlaying, entry.timeScalePitch == nil else {
            throw ResourceError.rejected("live_audio_seek_identity_or_state_mismatch")
        }
        let seconds = Double(request.milliseconds) / 1000
        guard seconds >= 0, seconds < entry.player.duration else { throw ResourceError.rejected("live_audio_seek_outside_track") }
        entry.player.currentTime = seconds
        guard entry.player.isPlaying, abs(entry.player.currentTime - seconds) < 0.1 else {
            throw ResourceError.rejected("live_audio_seek_not_confirmed")
        }
    }

    func allowsSourcePositionQuery(channel: UInt64) -> Bool {
        entries[channel]?.timeScalePitch == nil
    }
}
