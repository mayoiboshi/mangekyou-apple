import Foundation

package struct FileLogPatternSnapshot: Encodable, Sendable {
    let status: EvidenceStatus = .inferred
    let registeredPaths: Int
    let scannedEntries: Int
    let matchingEntries: Int
    let matchingPatterns: Int
    let truncated: Bool
}

struct ScriptBinding: Sendable {
    var elements: [ScriptValue]
    var explicitArray = false
    var first: ScriptValue { elements[0] }
}

struct ScriptFrame: Sendable {
    struct SavedResultScalars: Sendable {
        let integers: [Int32]
        let strings: [String]
        var click: Int32? = nil
        var stop: Int32? = nil
        var buttonInts: [Int32] = []
        var buttonStrings: [String] = []
        var subInts: [Int32] = []
        var subStrings: [String] = []
    }
    var savedReturnScalars: SavedResultScalars? = nil
    let returnIndex: Int?
    var returnProgram: ScriptProgram?
    var entryLabel: String?
    var locals: [Data: ScriptBinding] = [:]
    var controls: [Int] = []
    var ifConditions: [Int: Int32] = [:]
    var tableScope: [UInt64] = []
    var parameterCount: Int32?
    var integerParameters: [Int32]?
    var objectParameterNames: [Data: UInt64] = [:]
    var stringParameters: [String]?
    var objectAliases: Set<Data> = []
    var objectAliasReferences: [Data: [String?]] = [:]
    var forPlans: [Int: ScriptForPlan] = [:]
    // Set only for locally constructed text/sound/line-tag prefix calls.
    var completedLineReturnCandidate = false
}

/// Explicit experimental storage profile; does not reproduce native object ownership/ABI.
struct ScriptStorage: Sendable {
    var visualTicks: Int64 = 0
    var drawRequestCount: Int32?
    static let cameraHandle = UInt64.max-8
    private static let cameraName = Data("camex".utf8)
    struct CameraPlacementRequest: Sendable {
        let position: [Int32]
        let scale: [Int32]
        let rotation: [Int32]
        let duration: Int32
        let loop: Int32
    }
    struct GeneratorRequest: Sendable {
        let index: Int32
        let arguments: [Int32]
        let persistent: Bool
    }
    var cameraGeneratorFilterRequests: [String] = []
    var cameraGeneratorRequests: [Int32: GeneratorRequest] = [:]
    var cameraPlacementRequest: CameraPlacementRequest?
    var cameraColorRequest: (alpha: Int32, color: Int32, duration: Int32, loop: Int32)?
    var cameraMotion: (mode: Int32, strength: Int32)?
    var cameraBlendMode: Int32?
    var cameraTextureFilter: UInt8 = 0
    var cameraPriorities: (lower: Int32, upper: Int32)?
    var cameraInitialized = false
    static let replacementHandle = UInt64.max-7
    private static let replacementName = Data("rep".utf8)
    struct ReplacementRule: Sendable {
        let key: String
        let value: String
    }
    var exceptTextPrefix: String?
    var noWordLineText: String?
    var replacementOrder: [Data] = []
    var replacementRules: [Data: ReplacementRule] = [:]

    mutating func registerReplacement(key: String, value: String) throws {
        guard !key.isEmpty, key.utf8.count <= 256, key.utf8.allSatisfy({ $0 < 128 }),
              !value.isEmpty, value.utf8.count <= 8192 else {
            throw ResourceError.rejected("replacement_registration_outside_profile")
        }
        let normalized = Data(asciiLower(key).utf8)
        guard replacementRules[normalized] != nil || replacementRules.count < 512 else {
            throw ResourceError.rejected("replacement_registration_limit")
        }
        if replacementRules[normalized] == nil { replacementOrder.append(normalized) }
        replacementRules[normalized] = ReplacementRule(key: key,value: value)
    }

    mutating func restoreReaderReplacements(_ cursor: SaveReaderCursor, in state: Data) throws {
        guard cursor.replaceEnableByte != 0 else { return }
        guard cursor.replacements.count <= 512 else {
            throw ResourceError.rejected("saved_reader_replacement_limit")
        }
        var candidate = self
        for rule in cursor.replacements {
            let key = try rule.firstText.utf16Text(in: state)
            let value = try rule.secondText.utf16Text(in: state)
            guard rule.rawField == 0, key.hasPrefix("^"),
                  candidate.replacementRules[Data(asciiLower(key).utf8)] == nil else {
                throw ResourceError.rejected("saved_reader_replacement_outside_profile")
            }
            try candidate.registerReplacement(key: key, value: value)
        }
        self = candidate
    }

    mutating func restoreReaderPrefixes(_ cursor: SaveReaderCursor, in state: Data) throws {
        let text = try cursor.textPrefix.utf16Text(in: state)
        let empty = try cursor.emptyLineText.utf16Text(in: state)
        guard [text, empty].allSatisfy({ prefix in
            prefix.utf8.count <= 8192 && !prefix.unicodeScalars.contains { $0.value < 32 }
        }) else {
            throw ResourceError.rejected("saved_reader_prefix_outside_profile")
        }
        exceptTextPrefix = text.isEmpty ? nil : text
        noWordLineText = empty.isEmpty ? nil : empty
    }

    static let nullHandle = UInt64.max-6
    var voiceActorAliases: [[String]]?
    static let configHandle: UInt64 = 0
    static let inputHandle = UInt64.max-5
    private static let inputName = Data("inp".utf8)
    static let soundHandle = UInt64.max-4
    private static let soundName = Data("snd".utf8)
    private static let directSoundName = Data("dsnd".utf8)
    // A bounded candidate for the observed game configuration, not a claim
    // that every native configuration has sixteen channels.
    private static let directSoundBase = UInt64.max - 2048
    static func isDirectSoundHandle(_ handle: UInt64) -> Bool {
        handle <= directSoundBase && handle >= directSoundBase - 15
    }
    struct DirectSoundChannel: Sendable {
        var resource: ScriptLocation?
        var volume: Int32 = 256
        var volumeType: Int32 = 0
        var lastStartTick: UInt32 = 0
    }
    var directSoundChannels: [UInt64: DirectSoundChannel] = [:]
    var directSoundChannelCount: Int32 = 16
    static func directSoundIndex(_ handle: UInt64) -> Int32? {
        guard isDirectSoundHandle(handle) else { return nil }
        return Int32(directSoundBase - handle)
    }
    struct SoundChannel: Sendable {
        var playing = false
        var playbackStartStep: Int?
        var filterRequest: String?
        var filterRequestKnown = true
        var volumeFilterCandidate: StreamVolumeFilterCandidate?
        var filterChainCandidateText: String?
        var loopRequest: Int32?
        var seekRequest: Int32?
        var volumeType: Int32?
        // vtn only changes the selected type; the manager applies it on play or refresh.
        var appliedVolumeType: Int32?
        var volumeDuration: Int32?
        var volumeDelay: Int32?
        var volumeChangePending = false
        var panChangePending = false
        var volumeControlToken: UUID?
        var panControlToken: UUID?
        var volumeControlPlaybackStep: Int?
        var panControlPlaybackStep: Int?
        var panRequest: (position: Int32, duration: Int32, delay: Int32)?
        var volume: Int32?
        var resource: ScriptLocation?
        // Original evaluated load operand; a resolved catalog path alone does
        // not preserve the spelling returned by the native ?l command.
        var requestedSourceName: String?
        var requestedSourceNameKnown = true
        // Supplied by a bounded host probe for this loaded resource.
        var probedDurationMilliseconds: Int32?
    }
    var soundChannels: [UInt64: SoundChannel] = [:]
    // Keep transient changes visible even when a later instruction clears the
    // filter before the host gets control back.
    var activeStreamFilterApplicationUnverified = false
    // Records outside the saved bank have no reconstructed string state.
    var unknownStreamFieldsOnRestore = false

    mutating func ensureStreamChannel(_ handle: UInt64) {
        guard soundChannels[handle] == nil else { return }
        soundChannels[handle] = unknownStreamFieldsOnRestore
            ? .init(filterRequestKnown: false, requestedSourceNameKnown: false) : .init()
    }

    @discardableResult
    mutating func stageSavedStreamNames(_ names: [Int32: String]) -> Int {
        var restored = 0
        for (index, name) in names {
            guard case .object(let handle) = try? readIndexed("snd", index),
                  Self.isStreamHandle(handle) else { continue }
            if soundChannels[handle] == nil {
                soundChannels[handle] = .init(filterRequestKnown: false, requestedSourceNameKnown: false)
            }
            soundChannels[handle]?.requestedSourceName = name
            soundChannels[handle]?.requestedSourceNameKnown = true
            restored += 1
        }
        return restored
    }

    @discardableResult
    mutating func stageSavedStreamFilters(_ filters: [Int32: String]) -> Int {
        var restored = 0
        for (index, filter) in filters {
            guard case .object(let handle) = try? readIndexed("snd", index),
                  Self.isStreamHandle(handle) else { continue }
            if soundChannels[handle] == nil {
                soundChannels[handle] = .init(filterRequestKnown: false, requestedSourceNameKnown: false)
            }
            soundChannels[handle]?.filterRequest = filter
            soundChannels[handle]?.filterRequestKnown = true
            // The saved text alone does not reveal parameters retained by
            // earlier same-type updates.
            soundChannels[handle]?.volumeFilterCandidate = nil
            soundChannels[handle]?.filterChainCandidateText = nil
            restored += 1
        }
        return restored
    }

    mutating func acknowledgeSoundControl(channel: UInt64, token: UUID, volume: Bool) -> Bool {
        guard var sound = soundChannels[channel], sound.playing else { return false }
        if volume {
            guard !sound.volumeChangePending, sound.volumeControlToken == token,
                  sound.volumeControlPlaybackStep == sound.playbackStartStep else { return false }
            sound.volumeDuration = 0
            sound.volumeDelay = 0
            sound.volumeControlToken = nil
            sound.volumeControlPlaybackStep = nil
        } else {
            guard !sound.panChangePending, sound.panControlToken == token,
                  sound.panControlPlaybackStep == sound.playbackStartStep,
                  let pan = sound.panRequest else { return false }
            sound.panRequest = (pan.position, 0, 0)
            sound.panControlToken = nil
            sound.panControlPlaybackStep = nil
        }
        soundChannels[channel] = sound
        return true
    }
    static let effectHandle = UInt64.max-3
    private static let effectName = Data("eff".utf8)
    // Requested solid-color transition for the headless scene.
    var effectBackgroundColor: UInt32?
    var effectFillColor: UInt32?
    var effectCapturePriority: Int32?
    var effectField5F: UInt8?
    var fadeInMode: Int32?
    var fadeInDuration: Int32?
    var fadeInStartTick: Int64?
    var fadeInPriority: Int32?
    var fadeInAnimation: ScriptLocation?
    var fadeInRule: (resource: ScriptLocation, power: Int32)?
    var fadeTransform: [Int32]?
    var fadeTiming: (mode: UInt8, power: Int32)?
    static let mathHandle = UInt64.max-46
    private static let mathName = Data("math".utf8)
    static let miscHandle = UInt64.max-43
    private static let miscName = Data("misc".utf8)
    static let dialogueLogHandle = UInt64.max-42
    private static let dialogueLogName = Data("log".utf8)
    struct DialogueLogEntry: Sendable {
        let location: ScriptLocation
        let speaker: String
        let text: String
        let voice: String
        let extra: String
    }
    var dialogueLogEntries: [DialogueLogEntry] = []
    var dialogueLogBytes = 0
    static let lineLogHandle = UInt64.max-41
    private static let lineLogName = Data("llog".utf8)
    var lineLogValues: [Data: Int32] = [:]
    var importedLabelHistory = false
    // TLabelLog's allocation path zero-initializes the instance; its
    // constructor only assigns the backend pointer (0x405704, 0x5b15fc).
    var lineLogLockTag: UInt8? = 0
    static let fileLogHandle = UInt64.max-40
    private static let fileLogName = Data("flog".utf8)
    var fileLogPaths: [String] = []
    var fileLogValues: [Data: Int32] = [:]
    var fileLogLocked: Bool?
    mutating func addFileLogPath(_ path: String) throws {
        let normalized = asciiLower(path), key = Data(normalized.utf8)
        guard !fileLogPaths.contains(where: { Data($0.utf8) == key }) else { return }
        guard fileLogPaths.count < 512 else { throw ResourceError.rejected("file_log_path_limit") }
        fileLogPaths.append(normalized)
    }
    mutating func removeFileLogPath(_ path: String) {
        let key = Data(asciiLower(path).utf8)
        if let index = fileLogPaths.firstIndex(where: { Data($0.utf8) == key }) {
            fileLogPaths.remove(at: index)
        }
    }
    /// Research model of the path callback; the complete set of
    /// path-resolver callers and the original resolved spelling are unverified.
    enum ImageFileLogOutcome: String {
        case matched, filtered, noPaths, locked, noMatch
    }
    func fileLogPatternSnapshot() -> FileLogPatternSnapshot {
        let needles = fileLogPaths.map { Array($0.utf16) }
        var matchedPatterns = Set<Int>(), matchedEntries = 0, scanned = 0, comparisons = 0
        var truncated = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        for key in fileLogValues.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            guard let name = String(data: key, encoding: .utf8) else { truncated = true; break }
            let haystack = Array(("\\\\" + name).utf16)
            var entryMatched = false
            for (index, needle) in needles.enumerated() {
                comparisons += 1
                if comparisons > 100_000 || ContinuousClock.now >= deadline { truncated = true; break }
                guard !needle.isEmpty, needle.count <= haystack.count else { continue }
                if (0...(haystack.count - needle.count)).contains(where: { offset in
                    haystack[offset..<(offset + needle.count)].elementsEqual(needle)
                }) {
                    entryMatched = true
                    matchedPatterns.insert(index)
                }
            }
            if truncated { break }
            scanned += 1
            if entryMatched { matchedEntries += 1 }
        }
        return FileLogPatternSnapshot(registeredPaths: needles.count, scannedEntries: scanned,
            matchingEntries: matchedEntries, matchingPatterns: matchedPatterns.count, truncated: truncated)
    }
    @discardableResult mutating func recordImageFileLogCandidate(_ logicalPath: String) throws -> ImageFileLogOutcome {
        let name = asciiLower(logicalPath.replacingOccurrences(of: "/", with: "\\"))
        guard !name.isEmpty, !name.hasPrefix("$$$") else { return .filtered }
        guard !fileLogPaths.isEmpty else { return .noPaths }
        guard let locked = fileLogLocked else { throw ResourceError.rejected("file_log_lock_unknown") }
        guard !locked else { return .locked }
        // 0x5b1784 contains two UTF-16 backslashes before the path.
        let haystack = Array(("\\\\" + name).utf16)
        let matches = fileLogPaths.contains { path in
            let needle = Array(path.utf16)
            guard !needle.isEmpty, needle.count <= haystack.count else { return false }
            return (0...(haystack.count - needle.count)).contains { offset in
                haystack[offset..<(offset + needle.count)].elementsEqual(needle)
            }
        }
        guard matches else { return .noMatch }
        let key = Data(name.utf8)
        guard key.count <= 8192, name.utf16.count <= 4096,
              fileLogValues.count < 20_000 || fileLogValues[key] != nil else {
            throw ResourceError.rejected("file_log_write_outside_profile")
        }
        let previous = max(fileLogValues[key] ?? -1, 0)
        let incremented = previous &+ 1
        fileLogValues[key] = incremented > 0x0fffffff ? 0x0fffffff : incremented
        return .matched
    }
    struct TimerObject: Sendable {
        var callback: (program: ScriptProgram, index: Int, label: String)?
        var enabled = false
        var elapsed: Int32 = 0
        var argument = ""
        var interval: Int32 = 0
    }
    var timers: [UInt64: TimerObject] = [:]
    var systemReleaseArgument = ""
    var restoredSystemSkip: Bool?
    // Opt-in, frame-sampled candidate; nil means no eligible frame was sampled.
    var researchSystemSkip: Bool?
    var researchSkipTime: Int32 = 0
    var systemPlayMode: Int32 = 0
    var systemInputMask: Int32 = 0xffffff
    var linkedPrimaryInputMask: Int32?
    var systemOutputMask: Int32 = 0xffffff
    var linkedPrimaryOutputMask: Int32?
    var selectsPrimaryScriptSource = false
    var linkedPrimaryPlayMode: Int32?
    var systemAutoPlayValue: Int32 = 0
    static let systemHandle = UInt64.max-2
    private static let systemName = Data("sys".utf8)
    private static let soundEffectTypeName = Data("_stse".utf8)
    private static let linearMotionName = Data("_mmlinear".utf8)
    private static let outQuartName = Data("_mmoutquart".utf8)
    private static let saveLockName = Data("_lksave".utf8)
    private static let loadLockName = Data("_lkload".utf8)
    private static let skipLockName = Data("_lkskip".utf8)
    private static let autoLockName = Data("_lkauto".utf8)
    private static let screenLockName = Data("_lkscreen".utf8)
    var systemNameSlots = Array(repeating: "", count: 7)
    var thumbnailPriorities: (Int32, Int32)?
    var systemFrameEvent: ScriptLocation?
    // The reset at 0x6aef06 clears both fields, then 0x6aef33 sets only the main lock.
    var systemLockMask: Int32 = 0x0fff_ffff
    var systemCustomLockMask: Int32 = 0
    // The zero command writes this engine field; its downstream effect is unresolved.
    var engineField98: Int32?
    // A host clock advanced after zero without modelling the native reset.
    var researchZeroClockHistoryUncertain = false
    static let systemKeyHandle = UInt64.max-1
    private static let systemKeyName = Data("skey".utf8)
    var mouseGestureMode: Int32?
    var swipeSettings: (mode: Int32, option: Int32)?
    var systemKeyEnabled: Bool?
    var systemKeyBindings: [Int32: (name: String, target: String?)] = [:]
    static let temporaryDataHandle = UInt64.max-44
    static let memoryDataHandle = UInt64.max-45
    private static let memoryDataName = Data("mdat".utf8)
    private static let temporaryDataName = Data("tdat".utf8)
    static let saveDataHandle = UInt64.max
    private static let configName = Data("cfg".utf8)
    private static let saveDataName = Data("dat".utf8)
    // Read-only slot names admitted by the host for this session.
    var sessionSaveNames: Set<Data> = []
    var sessionSaveMetadata: [Data: (strings: [String], time: DateComponents?)] = [:]
    var sessionSaveThumbnails: [Data: ScriptLocation] = [:]

    func containsSessionSave(_ name: String) throws -> Bool {
        guard name.utf8.count <= 255,
              name.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil,
              !name.contains("..") else {
            throw ResourceError.rejected("save_name_outside_profile")
        }
        return sessionSaveNames.contains(Data(asciiLower(name).utf8))
    }
    var globalObjectAliases: Set<Data> = []
    // Preserve only reference text explicitly supplied at assignment. A nil
    // entry means the object was assigned by handle and its spelling is unknown.
    var globalAliasReferences: [Data: [String?]] = [:]
    var system: [Data: ScriptBinding] = [:]
    // Local adapters for TScriptRoutineResult fields, not declarations from a system-data table.
    var transientButtonResultNames: Set<Data> = []
    var configuration: ScriptTable?
    var fontOverrides: [String: ScriptValue] = [:]
    var configMessageOverrides: [String: Int32] = [:]
    var configDisplayOverrides: [String: Int32] = [:]
    var configDisplayNeedsHostUpdate = false
    var configDisplayRefreshRequested = false
    var configMessageAlphaNeedsRendering = false
    var actorVolumeOverrides: [Int32: Int32] = [:]
    var actorMuteOverrides: [Int32: Int32] = [:]
    var researchExpectedActorAliasSHA256: String?
    var configVoiceValues: [Int32: Int32] = [:]
    var configVoiceModes: [Int32: Int32] = [:]

    func configAudioSlot(_ index: Int32, volume: Bool) throws -> Int32 {
        guard (0..<32).contains(index) else { throw ResourceError.rejected("audio_volume_type_outside_profile") }
        let override = volume ? configVoiceValues[index] : configVoiceModes[index]
        if let override { return override }
        let key = volume ? "Volume" : "Mute"
        if let configured = try configuration?.value(for: "\(key)[\(index)]") {
            guard let parsed = ScriptExpression.integerTextCache(configured) else {
                throw ResourceError.rejected("config_volume_value_invalid")
            }
            return parsed
        }
        return volume ? 256 : 0
    }

    func soundCategoryGain(_ sound: SoundChannel) throws -> Int32 {
        let index = sound.appliedVolumeType ?? sound.volumeType ?? 0
        // 0x6d313c tests equality with one; movie audio tests nonzero.
        if try configAudioSlot(index, volume: false) == 1 { return 0 }
        return try configAudioSlot(index, volume: true)
    }

    func effectiveMovieVolume(_ movie: MovieObject) throws -> Int32 {
        let index = movie.volumeTarget ?? 0
        let mute = try configAudioSlot(index, volume: false)
        guard mute == 0 else { return 0 }
        let scale = try configAudioSlot(index, volume: true)
        // 0x68429d uses the low 32 bits, then signed division rounds toward zero.
        return (scale &* (movie.volume ?? 256)) / 256
    }
    var global: [Data: ScriptBinding] = [:]
    var frames: [ScriptFrame] = [ScriptFrame(returnIndex: nil)]
    var tables: [UInt64: ScriptTable] = [:]
    var lists: [UInt64: ScriptStringList] = [:]
    struct PlacementTransition: Sendable {
        let destination: [Int32]
        let duration: Int32
        var elapsed: Int32 = 0
        var destinationTransform: ImageTransform?
        var savedMode: UInt8?

        func matchesUnchangedRequest(destination: [Int32], duration: Int32, transform: ImageTransform) -> Bool {
            guard savedMode == nil, transform.loop == 0, self.duration == duration,
                  self.destination == destination, let previous = destinationTransform else { return false }
            return previous.loop == 0 && previous.depth == transform.depth && previous.scale == transform.scale &&
                previous.rotation == transform.rotation
        }

        var quantizedProgress: Double {
            let remaining = Int64(duration - elapsed)
            return Double(1024 - remaining * 1024 / Int64(duration)) / 1024
        }

        func sampleSavedLinearAxis(from origin: Int32, to target: Int32) -> Int32 {
            Int32(sampleLinearScale(from: origin, to: target).rounded(.toNearestOrEven))
        }

        func sampleLinearScale(from origin: Int32, to target: Int32) -> Float {
            let progress = quantizedProgress
            // 0x50b9e4 stores the weighted sum as a single-precision value.
            return Float(Double(origin) * (1 - progress) + Double(target) * progress)
        }
    }
    var placementTransitions: [UInt64: PlacementTransition] = [:]

    struct MotionSettings: Sendable {
        var mode: UInt8
        var strength: Int32
    }
    struct ImageTransform: Sendable {
        let depth: Int32
        let scale: [Int32]
        let rotation: [Int32]
        let loop: Int32
    }
    struct ImageObject: Sendable {
        var generatorRequests: [Int32: GeneratorRequest] = [:]
        var generatorFilterRequests: [String] = []
        var transform: ImageTransform?
        // Nil for a newly constructed image; native initialization selects 1.
        var savedPlacementMode: UInt8?
        var extendedDefaultsPrepared = false
        var hasExtendedContainerMetadata = false
        var boundImages: [Int32: ScriptLocation] = [:]
        var extendedScalarValues: [Int: Int32] = [:]
        var filterOverrides: [Int32: String] = [:]
        var playbackSpeed: Int32?
        var animationSpeed: Int32?
        var volume: Int32?
        var volumeType: Int32?
        var alignment: (x: Int32, y: Int32)?
        var immediateOpacity: UInt8 = 255
        var opacityEndpoint: (value: UInt8, remaining: Int32, duration: Int32, repeats: Int32)?
        var presentedOpacity: UInt8 {
            guard let endpoint = opacityEndpoint else { return immediateOpacity }
            // 0x5ab050–0x5ab094 quantizes time, uses motion mode 1 and rounds.
            let step = 1024 - Int64(endpoint.remaining) * 1024 / Int64(endpoint.duration)
            let origin = Double(immediateOpacity)
            return UInt8(clamping: Int((origin + (Double(endpoint.value) - origin)
                * Double(step) / 1024).rounded(.toNearestOrEven)))
        }
        mutating func advanceOpacity(ticks: Int32) {
            guard var endpoint = opacityEndpoint else { return }
            let remaining = endpoint.remaining - ticks
            if endpoint.repeats != 0 {
                // 0x5ab002–0x5ab040 rolls over only after the clock crosses zero.
                if remaining < 0 {
                    if endpoint.repeats > 0 { endpoint.repeats -= 1 }
                    endpoint.remaining = max(0, remaining + endpoint.duration)
                } else {
                    endpoint.remaining = remaining
                }
                opacityEndpoint = endpoint
            } else if remaining <= 0 {
                immediateOpacity = endpoint.value
                opacityEndpoint = nil
            } else {
                endpoint.remaining = remaining
                opacityEndpoint = endpoint
            }
        }
        var colorRequest: (alpha: Int32, multiply: Int32, add: Int32, duration: Int32, loop: Int32)?
        var blendMode: Int32?
        var textureFilter: Int32?
        var drawChannel: Int32?
        var inputMask: Int32?
        var outputMask: Int32?
        var resource: ScriptLocation?
        var isTheoraResource = false
        var resourceLoadLocation: ScriptLocation?
        var width: Int?
        var height: Int?
        var placement: [Int32]?
        var motion: MotionSettings?
        var tabOrder: Int32?
        var memberCount = 0
        var selectedMember: Int32?
        struct SavedLayerTimeSnapshot: Sendable {
            let times: [Int32]
            let auxiliary: [Int32]
            let visualTick: Int64
        }
        // A read-only snapshot for an explicitly requested frozen preview.
        // It is not an implementation of the subsequent layer clock updates.
        var savedLayerTimeSnapshot: SavedLayerTimeSnapshot?
        var motionStartTick: Int64?
        var motionElapsedBeforeSpeedChange: Int64 = 0
        var restoredMotionThreshold: Int64?
        var restoredMotionRemainder: Int64 = 0

        mutating func advanceRestoredMotion(ticks: Int32) {
            guard let threshold = restoredMotionThreshold, motionStartTick != nil else { return }
            restoredMotionRemainder += Int64(ticks) * Int64(playbackSpeed ?? 100)
            if restoredMotionRemainder >= threshold {
                motionElapsedBeforeSpeedChange = min(motionElapsedBeforeSpeedChange + restoredMotionRemainder, Int64(Int32.max) * 100)
                restoredMotionRemainder = 0
            }
        }

        var isDialogueWindowAnimation: Bool {
            placement?.dropFirst(2).first == 1500 &&
                resource?.sourceSHA256 == "49c040e37eebc295e9fc2b8fdf9db40e70cc773dd41ab9ae486e95dd84cdda39"
        }

        func motionElapsedHundredths(at tick: Int64) -> Int64? {
            guard let motionStartTick else { return nil }
            if restoredMotionThreshold != nil { return motionElapsedBeforeSpeedChange }
            let speed = Int64(playbackSpeed ?? 100)
            let elapsed = min(tick - motionStartTick, Int64(Int32.max) * 100)
            return min(motionElapsedBeforeSpeedChange + elapsed * speed, Int64(Int32.max) * 100)
        }
        var enabled = false
        // A restored image can still draw while the separate enable byte is zero.
        var savedDrawGate: Bool?
        var isDrawable: Bool { savedDrawGate ?? enabled }
    }
    struct MovieObject: Sendable {
        var initialized = false
        var durationTicks: Int32?
        var remainingTicks: Int32?
        var volumeTarget: Int32?
        var volume: Int32?
        var textureFilter: UInt8?
        var size: (Int32, Int32)?
        var resource: ScriptLocation?
        var placement: [Int32]?
        var enabled = false
    }
    var movies: [UInt64: MovieObject] = [:]
    // Preserve script-declared subtype for future save serialization.
    struct BarObject: Sendable {
        var resources: [ScriptLocation?] = [nil, nil, nil]
        var enabled = false
        // Research preview state derived from the wrapper's enable dispatch.
        // These are candidates until the native runtime's live child objects
        // and rendered output are compared.
        var trackEnableMotion: Int32?
        var progressEnableMotion: Int32?
        var maximum: Int32 = 100
        var value: Int32 = 0
        var transition: Int32 = 0
        // Native +0x103 and +0xfb: previous target and remaining transition ticks.
        var transitionStart: Int32 = 0
        var transitionRemaining: Int32 = 0
        var locked = false
        // Research guard: lock changes can select a different child motion.
        // Keep this sticky because unlocking does not restore the enable frame.
        var lockStateChanged = false
        mutating func setLock(_ value: Bool) {
            if locked != value { lockStateChanged = true }
            locked = value
        }
        var placement: [Int32] = [0, 0, 0]
        // The research hit candidate requires an explicit immediate placement.
        var placementSet = false
        mutating func setImmediatePlacement(_ value: [Int32]) {
            // 0x67eddc skips the child update when all target fields already match.
            if placement != value { placementSet = true }
            placement = value
        }
        var userIntegers: [Int: Int32] = [:]
        var userStrings: [Int: String] = [:]
        // Input-change marker; aging over native update cycles is not yet connected.
        var changeCyclesRemaining: Int32 = 0
    }
    var bars: [UInt64: BarObject] = [:]
    var visualObjectTypes: [UInt64: String] = [:]
    var buttons: Set<UInt64> = []
    struct MessageObject: Sendable {
        var usesTimedCenterText: Bool {
            guard let action = backgroundSelectedMember, (0...4).contains(action) else { return false }
            return background?.sourceSHA256 == "97bb05fa8aaaff094f9ef12978d6fca0c7af6bd3081a01bbedd7ae5c02902a68"
        }

        enum Output: Sendable, Equatable {
            case directive(name: String, operands: [Int32])
            case text(String)
            case ruby(base: String, annotation: String)
        }

        /// Shared bounded adapter for script output and saved primary text.
        static func parseOutput(_ text: String) throws -> [Output] {
            guard text.utf8.count <= 8192 else {
                throw ResourceError.rejected("message_output_requires_bounded_directive_string")
            }
            var remaining = text[...]
            var output: [Output] = []
            let arities = ["n": 0, "i": 1, "f": 1, "rf": 1, "s": 2, "c": 1, "rc": 1, "pi": 2, "rs": 2, "rpi": 2, "rp": 2]
            while !remaining.isEmpty {
                guard output.count < 128 else { throw ResourceError.rejected("message_pending_output_limit") }
                if remaining.first != "[" {
                    let end = remaining.firstIndex(of: "[") ?? remaining.endIndex
                    output.append(.text(String(remaining[..<end])))
                    remaining = remaining[end...]
                    continue
                }
                guard let end = remaining.firstIndex(of: "]") else {
                    throw ResourceError.rejected("message_markup_outside_profile")
                }
                let fields = remaining[remaining.index(after: remaining.startIndex)..<end]
                    .split(separator: ",", omittingEmptySubsequences: false)
                if fields.first == "rb", fields.count == 3, !fields[1].isEmpty, !fields[2].isEmpty {
                    output.append(.ruby(base: String(fields[1]), annotation: String(fields[2])))
                    remaining = remaining[remaining.index(after: end)...]
                    continue
                }
                if fields.first == "pc", fields.count == 2 {
                    // 0x67a391 uses numeric conversion with U+005F fallback.
                    let code = ScriptExpression.integerTextCache(String(fields[1])) ?? 0x5f
                    guard let scalar = Unicode.Scalar(UInt16(truncatingIfNeeded: code)) else {
                        throw ResourceError.rejected("message_code_unit_outside_profile")
                    }
                    output.append(.text(String(scalar)))
                    remaining = remaining[remaining.index(after: end)...]
                    continue
                }
                if fields.count == 2, fields.first == "n",
                   let advance = Int32(fields[1]), advance > 0 {
                    output.append(.directive(name: "n", operands: [advance]))
                    remaining = remaining[remaining.index(after: end)...]
                    continue
                }
                guard let name = fields.first, let arity = arities[String(name)], fields.count == arity + 1 else {
                    throw ResourceError.rejected("message_directive_outside_profile")
                }
                let operands = try fields.dropFirst().map { operand -> Int32 in
                    if name == "c" || name == "rc", operand.first == "$",
                       let color = UInt32(operand.dropFirst(), radix: 16) {
                        return Int32(bitPattern: color)
                    }
                    guard let integer = Int32(operand) else {
                        throw ResourceError.rejected("message_directive_operand_outside_profile")
                    }
                    return integer
                }
                output.append(.directive(name: String(name), operands: operands))
                remaining = remaining[remaining.index(after: end)...]
            }
            return output
        }

        var pendingOutput: [Output] = []
        var committedOutput: [Output] = []
        // Preserve exact script syntax when available. Oversized or externally
        // reconstructed state remains usable for playback but not for writing.
        var pendingRawOutput: String? = ""
        var committedRawOutput: String? = ""

        mutating func enqueueOutput(_ text: String, parsed: [Output]) {
            pendingOutput.append(contentsOf: parsed)
            if let old = pendingRawOutput, old.utf8.count + text.utf8.count <= 8192 {
                pendingRawOutput = old + text
            } else {
                pendingRawOutput = nil
            }
        }

        mutating func clearOutput() {
            pendingOutput.removeAll()
            committedOutput.removeAll()
            pendingRawOutput = ""
            committedRawOutput = ""
        }

        func primaryTextWriteCandidate() -> (displayed: String, pending: String)? {
            func normalized(_ items: [Output]) -> [Output] {
                var result: [Output] = []
                for item in items {
                    if case .text(let text) = item, case .text(let previous)? = result.last {
                        result[result.count - 1] = .text(previous + text)
                    } else { result.append(item) }
                }
                return result
            }
            guard let displayed = committedRawOutput, let pending = pendingRawOutput,
                  displayed.utf8.count + pending.utf8.count <= 8192,
                  !(displayed + pending).unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }),
                  let shown = try? Self.parseOutput(displayed), let queued = try? Self.parseOutput(pending),
                  shown.count + queued.count <= 128,
                  normalized(shown) == normalized(committedOutput),
                  normalized(queued) == normalized(pendingOutput) else { return nil }
            return (displayed, pending)
        }

        mutating func commitOutput() throws {
            guard pendingOutput.count <= 1024 - committedOutput.count else {
                throw ResourceError.rejected("message_committed_output_limit")
            }
            committedOutput.append(contentsOf: pendingOutput)
            pendingOutput.removeAll()
            if let shown = committedRawOutput, let queued = pendingRawOutput,
               shown.utf8.count + queued.utf8.count <= 8192 {
                committedRawOutput = shown + queued
            } else {
                committedRawOutput = nil
            }
            pendingRawOutput = ""
        }

        /// Headless estimate of the text pen. Glyph shaping is a host concern.
        var headlessTextPosition: [Int32] {
            var x: Int64 = 0, y: Int64 = 0
            var width: Int64 = 24, height: Int64 = 24
            var horizontalPitch: Int64 = 0
            let limit = textBounds.map { max(1, Int64($0[2]) - Int64($0[0])) }
            func newLine() {
                x = 0
                y += height
            }
            for operation in committedOutput {
                switch operation {
                case .directive("s", let size):
                    width = min(8192, max(1, Int64(size[0])))
                    height = min(8192, max(1, Int64(size[1])))
                case .directive("pi", let pitch) where pitch.count == 2:
                    horizontalPitch = Int64(pitch[0])
                case .directive("n", let operands):
                    if let advance = operands.first {
                        // 0x67a53d resets the pen X and adds the positive argument to Y.
                        x = 0
                        y += Int64(advance)
                    } else {
                        newLine()
                    }
                case .directive("i", let offset):
                    // 0x679761 adds to the horizontal pen and clamps it at zero.
                    x = max(0, x + Int64(offset[0]))
                case .text(let text):
                    for character in text {
                        if character.isNewline {
                            newLine()
                        } else {
                            let advance = character.unicodeScalars.allSatisfy(\.isASCII) ? max(1, width / 2) : width
                            if let limit, let reserve = kinsokuWordLength, width + horizontalPitch > 0 {
                                // 0x67b134 uses the declared width and pitch to
                                // classify the next token. The pen itself is still
                                // only estimated here; font metrics and nsw are not
                                // supplied by this headless path.
                                let available = (limit - x) / (width + horizontalPitch)
                                let token = Array(String(character).utf16)
                                func containsToken(_ haystack: String) -> Bool {
                                    let units = Array(haystack.utf16)
                                    guard !token.isEmpty, token.count <= units.count else { return false }
                                    return (0...(units.count - token.count)).contains { start in
                                        units[start..<(start + token.count)].elementsEqual(token)
                                    }
                                }
                                let atStart = reserve != 0 && containsToken(prohibitedLineStart)
                                let atEnd = reserve != 0 && containsToken(prohibitedLineEnd)
                                let remaining = available - Int64(reserve)
                                if available < 1 || (!atStart && (atEnd ? remaining < 2 : remaining < 1)) {
                                    newLine()
                                }
                            } else if let limit, x > 0, x + advance > limit {
                                newLine()
                            }
                            x += advance + (kinsokuWordLength == nil ? 0 : horizontalPitch)
                        }
                    }
                case .ruby(let text, _):
                    // Ruby is handled as a separate native operation, so keep
                    // the existing estimate until its complete placement is known.
                    for character in text {
                        if character.isNewline {
                            newLine()
                        } else {
                            let advance = character.unicodeScalars.allSatisfy(\.isASCII) ? max(1, width / 2) : width
                            if let limit, x > 0, x + advance > limit { newLine() }
                            x += advance
                        }
                    }
                default:
                    break
                }
            }
            return [Int32(clamping: x), Int32(clamping: y)]
        }

        var generatorFilterRequests: [String] = []
        var placement: [Int32]?
        var transform: ImageTransform?
        var alignment: (Int32, Int32)?
        var enabled = false
        var background: ScriptLocation?
        var backgroundBoundImages: [Int32: ScriptLocation] = [:]
        var backgroundMemberCount = 0
        var backgroundSelectedMember: Int32?
        var backgroundMotionStartTick: Int64?
        var backgroundExtendedDefaultsPrepared = false
        var ignoredReturnWords = ""
        var kinsokuWordLength: Int32?
        var prohibitedLineStart = ""
        var prohibitedLineEnd = ""
        var textBounds: [Int32]?
        var textMargins: [Int32]?
        var returnSpacing: (Int32, Int32)?
        var apEnabled = false
        var asEnabled = false
        var volumeType: Int32?
        var inputMask: Int32?
        var outputMask: Int32?
        var drawChannel: Int32?
    }
    var messages: [UInt64: MessageObject] = [:]
    var buttonUserStrings: [UInt64: [Int: String]] = [:]
    var buttonScriptTargets: [UInt64: String] = [:]
    var buttonVolumeType: [UInt64: Int32] = [:]
    var enabledButtons: Set<UInt64> = []
    var buttonInputMasks: [UInt64: Int32] = [:]
    var buttonOutputMasks: [UInt64: Int32] = [:]
    var buttonLocks: [UInt64: UInt8] = [:]
    // Older saved button records have not been mapped to these state bytes.
    var unknownSavedButtonLocks: Set<UInt64> = []
    var unknownSavedButtonChecks: Set<UInt64> = []
    func buttonIsKnownUnlocked(_ handle: UInt64) -> Bool {
        !unknownSavedButtonLocks.contains(handle) && buttonLocks[handle, default: 0] == 0
    }
    func requireKnownSavedButtonStatesForAdoption() throws {
        guard unknownSavedButtonLocks.isEmpty, unknownSavedButtonChecks.isEmpty else {
            throw ResourceError.rejected("saved_button_state_unverified")
        }
    }
    func buttonArrayCount(_ raw: String) throws -> Int32 {
        let key = Data(asciiLower(raw).utf8)
        guard let binding = frames.last?.locals[key] ?? global[key],
              binding.elements.allSatisfy({ if case .object(let handle) = $0 { return buttons.contains(handle) }; return false })
        else { throw ResourceError.rejected("garr_requires_button_array") }
        return Int32(binding.elements.count)
    }
    func scriptObjectArrayCount(_ raw: String) throws -> Int32 {
        let key = Data(asciiLower(raw).utf8)
        guard let binding = frames.last?.locals[key] ?? global[key] else {
            throw ResourceError.rejected("garr_requires_supported_object_array")
        }
        let isButtonArray = binding.elements.allSatisfy {
            if case .object(let handle) = $0 { return buttons.contains(handle) }; return false
        }
        let isMessageArray = binding.elements.allSatisfy {
            if case .object(let handle) = $0 { return messages[handle] != nil }; return false
        }
        guard isButtonArray || isMessageArray else { throw ResourceError.rejected("garr_requires_supported_object_array") }
        return Int32(binding.elements.count)
    }
    var buttonUserIntegers: [UInt64: [Int: Int32]] = [:]
    var buttonText: [UInt64: MessageObject] = [:]
    var drawableRectangles: [UInt64: [Int32]] = [:]
    var buttonExtendedScalarValues: [UInt64: [Int: Int32]] = [:]
    var buttonTextBounds: [UInt64: [Int32]] = [:]
    var buttonCheckVisual: [UInt64: UInt8] = [:]
    var buttonMI: Set<UInt64> = []
    var buttonTabOrder: [UInt64: Int32] = [:]
    var buttonScale: [UInt64: [Int32]] = [:]
    var savedButtonPlacementScale: [UInt64: SIMD2<Int32>] = [:]
    var buttonMotion: [UInt64: MotionSettings] = [:]
    var buttonPlacement: [UInt64: [Int32]] = [:]
    var buttonSounds: [UInt64: [Int32: ScriptLocation]] = [:]
    var buttonImages: [UInt64: [Int32: ScriptLocation]] = [:]
    var buttonResources: [UInt64: ScriptLocation] = [:]
    var images: [UInt64: ImageObject] = [:]
    var savedTextureData: [ScriptLocation: Data] = [:]
    private var nextObject: UInt64 = 1

    private static let indexedSoundBase = UInt64.max - 1024
    // Bounded candidate for the 32-channel configuration used by the
    // observed replay cleanup; other configurations remain unverified.
    private static let indexedSoundCount: Int32 = 32

    static func isStreamHandle(_ handle: UInt64) -> Bool {
        streamChannelIndex(handle) != nil
    }

    static func streamChannelIndex(_ handle: UInt64) -> Int32? {
        if handle == soundHandle { return 0 }
        guard handle < indexedSoundBase,
              handle >= indexedSoundBase - UInt64(indexedSoundCount - 1) else { return nil }
        return Int32(indexedSoundBase - handle)
    }

    func isAliasTarget(_ handle: UInt64) -> Bool {
        Self.isStreamHandle(handle) || handle == Self.cameraHandle || tables[handle] != nil || lists[handle] != nil || images[handle] != nil || messages[handle] != nil
    }

    var resultStopInt: Int32?

    func read(_ raw: String) throws -> ScriptValue {
        if asciiLower(raw) == "resultstopint", let resultStopInt { return .integer(resultStopInt) }
        let name = Data(asciiLower(raw).utf8)
        if name == Data("paramcount".utf8), let count = frames.last?.parameterCount {
            return .integer(count)
        }
        if name == Data("null".utf8) { return .object(Self.nullHandle) }
        // The original registers this string at 0x6bd007.
        if name == Data("#quot".utf8) { return .string("\"") }
        if name == Self.cameraName { return .object(Self.cameraHandle) }
        if name == Self.replacementName { return .object(Self.replacementHandle) }
        if name == Self.inputName { return .object(Self.inputHandle) }
        if name == Self.configName { return .object(Self.configHandle) }
        if name == Self.effectName { return .object(Self.effectHandle) }
        if name == Self.mathName { return .object(Self.mathHandle) }
        if name == Self.miscName { return .object(Self.miscHandle) }
        if name == Self.dialogueLogName { return .object(Self.dialogueLogHandle) }
        if name == Self.lineLogName { return .object(Self.lineLogHandle) }
        if name == Self.fileLogName { return .object(Self.fileLogHandle) }
        if name == Self.systemName { return .object(Self.systemHandle) }
        if name == Self.soundEffectTypeName { return .integer(2) }
        if name == Self.linearMotionName { return .integer(1) } // 0x6bd619 registers the value.
        if name == Self.outQuartName { return .integer(3) }
        // System constants initialized by the original engine at 0x6bd2fe and 0x6bd30e.
        if name == Self.saveLockName { return .integer(2) }
        if name == Self.loadLockName { return .integer(4) }
        if name == Self.skipLockName { return .integer(0x80) }
        if name == Self.autoLockName { return .integer(0x40) }
        if name == Self.screenLockName { return .integer(1) }
        if name == Self.systemKeyName { return .object(Self.systemKeyHandle) }
        if name == Self.memoryDataName { return .object(Self.memoryDataHandle) }
        if name == Self.temporaryDataName { return .object(Self.temporaryDataHandle) }
        if name == Self.saveDataName { return .object(Self.saveDataHandle) }
        guard let value = frames.last?.locals[name] ?? global[name] ?? system[name]
        else { throw ResourceError.rejected("undefined_or_unbound_scalar") }
        return value.first
    }
    func readIndexed(_ raw: String, _ index: Int32) throws -> ScriptValue {
        let name = Data(asciiLower(raw).utf8)
        if name == Self.directSoundName {
            guard (0..<directSoundChannelCount).contains(index) else { throw ResourceError.rejected("direct_sound_channel_outside_profile") }
            return .object(Self.directSoundBase - UInt64(index))
        }
        if name == Self.soundName {
            guard (0..<Self.indexedSoundCount).contains(index) else { throw ResourceError.rejected("sound_channel_outside_profile") }
            return .object(index == 0 ? Self.soundHandle : Self.indexedSoundBase - UInt64(index))
        }
        if name == Data("paramstr".utf8), let parameters = frames.last?.stringParameters {
            guard (0..<16).contains(index) else { throw ResourceError.rejected("parameter_index_out_of_range") }
            return .string(parameters[Int(index)])
        }
        if name == Data("paramint".utf8), let parameters = frames.last?.integerParameters {
            guard (0..<16).contains(index) else { throw ResourceError.rejected("parameter_index_out_of_range") }
            return .integer(parameters[Int(index)])
        }
        guard name != Self.configName && name != Self.saveDataName && name != Self.systemKeyName && name != Self.systemName else { throw ResourceError.rejected("object_index_outside_profile") }
        guard let binding = frames.last?.locals[name] ?? global[name] ?? system[name]
        else { throw ResourceError.rejected("undefined_or_unbound_scalar") }
        if case .object(let handle) = binding.first, !globalObjectAliases.contains(name), !((frames.last?.objectAliases.contains(name)) ?? false), name != Data("resultobj".utf8), !buttons.contains(handle), messages[handle] == nil, tables[handle] == nil, images[handle] == nil,
           lists[handle] == nil || (binding.elements.count == 1 && !binding.explicitArray) {
            throw ResourceError.rejected("object_index_outside_profile")
        }
        guard index >= 0, Int(index) < binding.elements.count else {
            // Result arrays are fixed-width in the guest ABI. The runtime stores
            // only the slots a command filled, leaving the others at their defaults.
            if (0..<16).contains(index), frames.last?.locals[name] == nil, global[name] != nil {
                if name == Data("resultstr".utf8) { return .string("") }
                if name == Data("resultint".utf8) { return .integer(0) }
            }
            if ProcessInfo.processInfo.environment["MANGEKYOU_INDEX_DIAGNOSTIC"] == "1" {
                FileHandle.standardError.write(Data("array_index=\(index) array_count=\(binding.elements.count) binding_sha256=\(name.sha256Hex)\n".utf8))
            }
            throw ResourceError.rejected("array_index_out_of_range")
        }
        return binding.elements[Int(index)]
    }
    mutating func writeIndexed(_ raw: String, _ index: Int32, _ value: ScriptValue) throws {
        let key = Data(asciiLower(raw).utf8)
        if key == Data("resultint".utf8), global[key] == nil, frames.last?.locals[key] == nil, system[key] == nil,
           (0..<16).contains(index), value.integer != nil || {
               if case .string = value { return true }
               return false
           }() {
            try resultInteger(0)
        }
        if key == Data("resultstr".utf8), global[key] == nil, frames.last?.locals[key] == nil,
           system[key] == nil, (0..<16).contains(index), case .string = value {
            // A new command clears the result bindings. An explicit write
            // can establish the string slots again, like ResultInt.
            try setConfigResultArray(Array(repeating: .string(""), count: 16), string: true)
        }
        if (0..<16).contains(index), frames.last?.locals[key] == nil,
           let binding = global[key], binding.elements.count <= Int(index) {
            let defaultValue: ScriptValue?
            switch asciiLower(raw) {
            case "resultstr": defaultValue = .string("")
            case "resultint": defaultValue = .integer(0)
            default: defaultValue = nil
            }
            if let defaultValue {
                var candidate = self
                candidate.global[key]?.elements.append(contentsOf:
                    repeatElement(defaultValue, count: Int(index) + 1 - binding.elements.count))
                try candidate.validate()
                _ = try candidate.readIndexed(raw, index)
                try candidate.writeElement(raw, index: Int(index), value: value)
                self = candidate
                return
            }
        }
        _ = try readIndexed(raw,index)
        try writeElement(raw,index: Int(index),value: value)
    }
    private func aliasReferenceBytes() -> Int {
        let dictionaries = [globalAliasReferences] + frames.map(\.objectAliasReferences)
        return dictionaries.reduce(0) { total, dictionary in
            total + dictionary.values.reduce(0) { sum, entries in
                sum + entries.reduce(0) { $0 + ($1?.utf8.count ?? 0) }
            }
        }
    }

    private func aliasReference(source: String, index: Int32, handle: UInt64) -> String? {
        let key = Data(asciiLower(source).utf8)
        guard index >= 0, let frame = frames.last else { return nil }
        let binding: ScriptBinding?
        let references: [String?]?
        if frame.locals[key] != nil {
            guard frame.objectAliases.contains(key) else { return nil }
            binding = frame.locals[key]; references = frame.objectAliasReferences[key]
        } else {
            guard globalObjectAliases.contains(key) else { return nil }
            binding = global[key]; references = globalAliasReferences[key]
        }
        guard let binding, binding.elements.indices.contains(Int(index)),
              binding.elements[Int(index)] == .object(handle),
              let references, references.indices.contains(Int(index)) else { return nil }
        return references[Int(index)]
    }

    func savedSoundAliasTexts(_ key: Data) -> [String]? {
        guard globalObjectAliases.contains(key), let binding = global[key],
              let refs = globalAliasReferences[key], refs.count == binding.elements.count else { return nil }
        var result: [String] = []
        for (value, saved) in zip(binding.elements, refs) {
            guard case .object(let handle) = value, let text = saved else { return nil }
            if text.isEmpty {
                guard handle == Self.nullHandle else { return nil }
            } else {
                guard text.hasPrefix("snd["), text.hasSuffix("]"),
                      let index = Int32(text.dropFirst(4).dropLast()), text == "snd[\(index)]",
                      (try? readIndexed("snd", index)) == .object(handle) else { return nil }
            }
            result.append(text)
        }
        return result
    }

    func recordedSoundAliasIndex(source: String, index: Int32, handle: UInt64) -> Int32? {
        guard let reference = aliasReference(source: source, index: index, handle: handle),
              reference.hasPrefix("snd["), reference.hasSuffix("]"),
              let value = Int32(reference.dropFirst(4).dropLast()),
              (try? readIndexed("snd", value)) == .object(handle) else { return nil }
        return value
    }

    // The caller supplies an index observed during the same direct expression
    // evaluation; do not re-evaluate the original index expression.
    mutating func recordSoundAliasReference(target: String, index: Int32, soundIndex: Int32, handle: UInt64) throws {
        let key = Data(asciiLower(target).utf8), frameIndex = frames.count - 1
        guard index >= 0, try readIndexed("snd", soundIndex) == .object(handle) else { return }
        let local = frames[frameIndex].locals[key] != nil
        let binding = local ? frames[frameIndex].locals[key] : global[key]
        let references = local ? frames[frameIndex].objectAliasReferences[key] : globalAliasReferences[key]
        guard local ? frames[frameIndex].objectAliases.contains(key) : globalObjectAliases.contains(key),
              let binding, binding.elements.indices.contains(Int(index)), binding.elements[Int(index)] == .object(handle),
              let references, references.indices.contains(Int(index)) else { return }
        let text = "snd[\(soundIndex)]"
        guard aliasReferenceBytes() - (references[Int(index)]?.utf8.count ?? 0) + text.utf8.count <= 8 * 1024 * 1024 else {
            throw ResourceError.rejected("object_alias_reference_storage_limit")
        }
        if local { frames[frameIndex].objectAliasReferences[key]?[Int(index)] = text }
        else { globalAliasReferences[key]?[Int(index)] = text }
    }

    mutating func resetIntegerBinding(_ raw: String) throws {
        let key = Data(asciiLower(raw).utf8)
        let frame = frames.count - 1
        guard let binding = frames[frame].locals[key] ?? global[key] ?? system[key],
              binding.first.integer != nil else {
            throw ResourceError.rejected("init_requires_integer_binding")
        }
        let reset = ScriptBinding(elements: Array(repeating: .integer(0), count: binding.elements.count), explicitArray: binding.explicitArray)
        if frames[frame].locals[key] != nil { frames[frame].locals[key] = reset }
        else if global[key] != nil { global[key] = reset }
        else { system[key] = reset }
    }

    mutating func updateInteger(_ name: String, delta: Int32) throws {
        guard let value = try read(name).integer else { throw ResourceError.rejected("for_update_requires_integer") }
        let next = value.addingReportingOverflow(delta)
        guard !next.overflow else { throw ResourceError.rejected("for_update_overflow_outside_profile") }
        try write(name,.integer(next.partialValue))
    }

    mutating func write(_ raw: String, _ value: ScriptValue) throws {
        try writeElement(raw,index: 0,value: value)
    }
    private mutating func writeElement(_ raw: String, index: Int, value source: ScriptValue) throws {
        var value = source
        let name = Data(asciiLower(raw).utf8), i = frames.count-1
        guard let previous = frames[i].locals[name] ?? global[name] ?? system[name]
        else { throw ResourceError.rejected("assignment_target_not_declared") }
        let localAlias = frames[i].objectAliases.contains(name)
        if localAlias || (frames[i].locals[name] == nil && globalObjectAliases.contains(name)) {
            let reference: ScriptValue?
            if case .string(let target) = value {
                let key = Data(asciiLower(target).utf8)
                if let handle = frames[i].objectParameterNames[key] {
                    reference = .object(handle)
                } else {
                    reference = try read(target)
                }
            } else {
                reference = value
            }
            guard case .object(let handle)? = reference,
                  isAliasTarget(handle) else {
                throw ResourceError.rejected("object_alias_target_outside_profile")
            }
            let references = localAlias ? frames[i].objectAliasReferences[name] : globalAliasReferences[name]
            guard let references, references.indices.contains(index) else {
                throw ResourceError.rejected("object_alias_reference_shape")
            }
            let savedText: String?
            if case .string(let text) = source, text.utf8.count <= 8192 { savedText = text }
            else { savedText = nil }
            guard aliasReferenceBytes() - (references[index]?.utf8.count ?? 0) + (savedText?.utf8.count ?? 0) <= 8 * 1024 * 1024 else {
                throw ResourceError.rejected("object_alias_reference_storage_limit")
            }
            if localAlias {
                frames[i].locals[name]!.elements[index] = .object(handle)
                frames[i].objectAliasReferences[name]?[index] = savedText
            } else {
                global[name]!.elements[index] = .object(handle)
                globalAliasReferences[name]?[index] = savedText
            }
            return
        }
        // The original write path uses the target tag with the evaluated
        // descriptor. String evaluation fills its numeric field through
        // 0x415a90, with zero as the conversion fallback.
        if previous.first.typeName == "integer", case .string(let text) = value {
            value = .integer(ScriptExpression.integerTextCache(text) ?? 0)
        } else if previous.first.typeName == "string", case .integer(let integer) = value {
            value = .string(String(integer))
        }
        guard previous.first.typeName == value.typeName, value.typeName != "object"
        else { throw ResourceError.rejected("scalar_assignment_type_outside_profile") }
        var growsStringStorage = false
        if case .string(let text) = value {
            let bytes = text.utf8.count
            guard bytes <= 8192 else { throw ResourceError.rejected("string_value_limit") }
            if case .string(let old) = previous.elements[index] {
                growsStringStorage = bytes > old.utf8.count
            } else {
                growsStringStorage = bytes > 0
            }
        }
        if frames[i].locals[name] != nil { frames[i].locals[name]!.elements[index] = value }
        else if global[name] != nil { global[name]!.elements[index] = value }
        else { system[name]!.elements[index] = value }
        // Replacing an existing slot cannot grow bindings, arrays, tables or lists.
        if growsStringStorage { try validate() }
    }
    static func isDecimalDeclarationName(_ raw: String, category: String, type: String) -> Bool {
        category == "var" && type == "int" && !raw.isEmpty &&
            raw.utf8.allSatisfy { (48...57).contains($0) }
    }
    @discardableResult mutating func declare(_ raw: String, category: String, type: String, count: Int = 1, validateAfter: Bool = true, explicitArray: Bool = false) throws -> Bool {
        guard (1...4096).contains(count) else { throw ResourceError.rejected("array_element_count_limit") }
        guard !["theora","timer"].contains(type) || count == 1 else { throw ResourceError.rejected("object_array_outside_profile") }
        guard raw.utf8.count <= 4096, Self.isDecimalDeclarationName(raw,category: category,type: type) || raw.range(of: #"^#?[\p{L}_][\p{L}\p{N}_]*$"#, options: .regularExpression) != nil
        else { throw ResourceError.rejected("non_scalar_declaration_name") }
        guard ["int","str","table","list","img","simg","theora","btn","sbtn","bar","obj","msg","timer"].contains(type) else { throw ResourceError.rejected("declaration_type_outside_profile") }
        guard category != "svar" || ["int","str"].contains(type) else { throw ResourceError.rejected("system_object_declaration_outside_profile") }
        guard type != "obj" || category == "gvar" || (category == "var" && count == 1) else {
            throw ResourceError.rejected("object_alias_declaration_outside_profile")
        }
        guard type != "msg" || category == "gvar" else {
            throw ResourceError.rejected("message_declaration_outside_profile")
        }
        // 0x69d048 tests the visible lookup category before allocating a binding.
        if lookupCategory(raw) != 0 { return false }
        if (type == "table" || type == "list"), count > 512-tables.count-lists.count {
            // Returned frames leave their allocations in these dictionaries.
            // Preserve aliases and scopes that any active frame can still use.
            var reachable = Set<UInt64>()
            func mark(_ bindings: [Data: ScriptBinding]) {
                for binding in bindings.values {
                    for case .object(let handle) in binding.elements { reachable.insert(handle) }
                }
            }
            mark(global)
            mark(system)
            for frame in frames {
                mark(frame.locals)
                reachable.formUnion(frame.tableScope)
                reachable.formUnion(frame.objectParameterNames.values)
            }
            tables = tables.filter { reachable.contains($0.key) }
            lists = lists.filter { reachable.contains($0.key) }
        }
        let name = Data(asciiLower(raw).utf8), i = frames.count-1
        let elements: [ScriptValue]
        if type == "bar" {
            guard count == 1, category == "gvar", bars.count < 128 else {
                throw ResourceError.rejected("bar_declaration_outside_profile")
            }
            let handle = nextObject
            nextObject += 1
            bars[handle] = BarObject()
            elements = [.object(handle)]
        } else if type == "msg" {
            // The startup script indexes and scopes each message object independently.
            // Message lifecycle semantics are still outside this profile.
            guard count <= 128-messages.count else { throw ResourceError.rejected("message_object_limit") }
            elements = (0..<count).map { _ in
                let handle = nextObject
                nextObject += 1
                messages[handle] = MessageObject()
                return .object(handle)
            }
        } else if type == "btn" || type == "sbtn" {
            // The sbtn constructor at 0x68cd28 calls the btn constructor
            // before setting its subtype tags. Share the base button storage.
            guard count <= 128-buttons.count else { throw ResourceError.rejected("button_object_limit") }
            elements = (0..<count).map { _ in
                let handle = nextObject
                nextObject += 1
                buttons.insert(handle)
                visualObjectTypes[handle] = type
                return .object(handle)
            }
        } else if type == "table" || type == "list" || type == "img" || type == "simg" {
            // The simg constructor at 0x68db3a invokes the base image constructor.
            if type == "table" || type == "list" {
                guard count <= 512-tables.count-lists.count else { throw ResourceError.rejected("table_object_limit") }
            } else {
                guard count <= 128-images.count else { throw ResourceError.rejected("image_object_limit") }
            }
            elements = (0..<count).map { _ in
                let handle = nextObject
                nextObject += 1
                if type == "table" { tables[handle] = ScriptTable(allowWideKeys: true) }
                else if type == "list" { lists[handle] = ScriptStringList() }
                else {
                    images[handle] = ImageObject()
                    visualObjectTypes[handle] = type
                }
                return .object(handle)
            }
        } else {
            let value: ScriptValue
            switch type {
            case "obj":
                if category == "gvar" {
                    globalObjectAliases.insert(name)
                    globalAliasReferences[name] = Array(repeating: "", count: count)
                } else {
                    frames[i].objectAliases.insert(name)
                    frames[i].objectAliasReferences[name] = Array(repeating: "", count: count)
                }
                value = .object(Self.nullHandle)
            case "int": value = .integer(0)
            case "str": value = .string("")
            case "timer":
                // The original type factory dispatches to 0x68ee58.
                guard category == "gvar", timers.count < 32 else {
                    throw ResourceError.rejected("timer_declaration_outside_profile")
                }
                value = .object(nextObject)
                timers[nextObject] = TimerObject()
                nextObject += 1
            case "theora":
                guard movies.count < 32 else { throw ResourceError.rejected("movie_object_limit") }
                value = .object(nextObject); movies[nextObject] = MovieObject(); nextObject += 1
            default: throw ResourceError.rejected("declaration_type_outside_profile")
            }
            elements = Array(repeating: value,count: count)
        }
        let binding = ScriptBinding(elements: elements, explicitArray: explicitArray)
        if category == "var" { frames[i].locals[name] = binding }
        else if category == "gvar" { global[name] = binding }
        else { system[name] = binding }
        if validateAfter { try validate() }
        return true
    }
    mutating func results(string: String, integer: Int32) throws {
        guard string.utf8.count <= 8192 else { throw ResourceError.rejected("string_value_limit") }
        let sk = Data(asciiLower("ResultStr").utf8), ik = Data(asciiLower("ResultInt").utf8)
        guard global[sk] == nil || global[sk]?.first.typeName == "string",
              global[ik] == nil || global[ik]?.first.typeName == "integer"
        else { throw ResourceError.rejected("table_result_register_type_conflict") }
        if global[sk] == nil { global[sk] = ScriptBinding(elements: [.string(string)]) }
        else { global[sk]!.elements[0] = .string(string) }
        try resultInteger(integer)
    }
    func lookupCategory(_ raw: String) -> Int32 {
        let key = Data(asciiLower(raw).utf8)
        return frames.last?.locals[key] != nil ? 3 : global[key] != nil ? 2 : (system[key] != nil || key == Self.cameraName || key == Self.replacementName || key == Self.inputName || key == Self.configName || key == Self.temporaryDataName || key == Self.memoryDataName || key == Self.saveDataName || key == Self.miscName || key == Self.dialogueLogName || key == Self.lineLogName || key == Self.fileLogName || key == Self.systemKeyName || key == Self.systemName || key == Self.saveLockName || key == Self.loadLockName || key == Self.skipLockName || key == Self.autoLockName || key == Self.screenLockName || key == Self.soundEffectTypeName || key == Self.outQuartName || key == Self.linearMotionName || key == Self.effectName || key == Self.soundName || key == Self.directSoundName) ? 1 : 0
    }
    mutating func deleteGlobalBinding(_ name: String) throws {
        let key = Data(asciiLower(name).utf8)
        // 0x69f03a returns without deleting when lookup finds no binding.
        if lookupCategory(name) == 0 { return }
        guard frames.last?.locals[key] == nil, let binding = global[key] else {
            throw ResourceError.rejected("delete_requires_global_binding")
        }
        if globalObjectAliases.remove(key) != nil {
            globalAliasReferences.removeValue(forKey: key)
            global.removeValue(forKey: key)
            return
        }
        let handles = binding.elements.compactMap { value -> UInt64? in
            if case .object(let handle) = value { return handle }
            return nil
        }
        guard handles.allSatisfy({ images[$0] != nil || movies[$0] != nil || buttons.contains($0)
            || messages[$0] != nil || timers[$0] != nil || tables[$0] != nil || lists[$0] != nil || bars[$0] != nil }) else {
            throw ResourceError.rejected("delete_object_type_outside_profile")
        }
        global.removeValue(forKey: key)
        for handle in handles {
            placementTransitions.removeValue(forKey: handle)
            images.removeValue(forKey: handle)
            bars.removeValue(forKey: handle)
            visualObjectTypes.removeValue(forKey: handle)
            movies.removeValue(forKey: handle)
            messages.removeValue(forKey: handle)
            timers.removeValue(forKey: handle)
            tables.removeValue(forKey: handle)
            lists.removeValue(forKey: handle)
            buttons.remove(handle)
            enabledButtons.remove(handle)
            buttonResources.removeValue(forKey: handle)
            buttonImages.removeValue(forKey: handle)
            buttonSounds.removeValue(forKey: handle)
            buttonMotion.removeValue(forKey: handle)
            buttonPlacement.removeValue(forKey: handle)
            buttonScale.removeValue(forKey: handle)
            savedButtonPlacementScale.removeValue(forKey: handle)
            buttonUserIntegers.removeValue(forKey: handle)
            buttonText.removeValue(forKey: handle)
            drawableRectangles.removeValue(forKey: handle)
            buttonExtendedScalarValues.removeValue(forKey: handle)
            buttonTextBounds.removeValue(forKey: handle)
            buttonCheckVisual.removeValue(forKey: handle)
            buttonMI.remove(handle)
            buttonTabOrder.removeValue(forKey: handle)
            buttonInputMasks.removeValue(forKey: handle)
            buttonOutputMasks.removeValue(forKey: handle)
            buttonLocks.removeValue(forKey: handle)
            unknownSavedButtonLocks.remove(handle)
            unknownSavedButtonChecks.remove(handle)
            buttonVolumeType.removeValue(forKey: handle)
            buttonUserStrings.removeValue(forKey: handle)
            buttonScriptTargets.removeValue(forKey: handle)
        }
        let removed = Set(handles)
        for index in frames.indices {
            frames[index].tableScope.removeAll { removed.contains($0) }
        }
    }

    mutating func setClickResult(_ result: Int32) throws {
        let key = Data("resultclkint".utf8)
        if let binding = global[key], binding.first.integer == nil {
            throw ResourceError.rejected("click_result_type_conflict")
        }
        if global[key] == nil { global[key] = ScriptBinding(elements: [.integer(result)]) }
        else { global[key]!.elements[0] = .integer(result) }
        try validate()
    }

    mutating func setButtonResults(handle: UInt64, label: String) throws {
        clearResultBindings()
        global[Data("resultobj".utf8)] = ScriptBinding(elements: [.object(handle)])
        let strings = buttonUserStrings[handle] ?? [:]
        try setConfigResultArray((0..<4).map { .string(strings[$0] ?? ($0 == 0 ? label : "")) }, string: true)
        try resultInteger(0)
    }

    /// Script-created bars use monotonic handles; their original manager appends
    /// new objects and gsc scans that list from index zero.
    mutating func setBarChangeResults() throws {
        let match = bars.filter { $0.value.changeCyclesRemaining > 0 }.min { $0.key < $1.key }
        guard let (handle, bar) = match else {
            try setButtonResults(handle: Self.nullHandle, label: "")
            return
        }
        clearResultBindings()
        global[Data("resultobj".utf8)] = ScriptBinding(elements: [.object(handle)])
        try setConfigResultArray((0..<4).map { .integer(bar.userIntegers[$0] ?? 0) }, string: false)
        try setConfigResultArray((0..<4).map { .string(bar.userStrings[$0] ?? "") }, string: true)
        bars[handle]?.changeCyclesRemaining = 0
    }

    mutating func initializeButtonRegisters() throws {
        for (name,value) in [("resultbtnstr",ScriptValue.string("")),("resultbtnint",.integer(0))] {
            let key = Data(name.utf8)
            if system[key] == nil {
                system[key] = ScriptBinding(elements: Array(repeating: value,count: 4))
                transientButtonResultNames.insert(key)
            }
        }
        try validate()
    }

    mutating func clearResultBindings() {
        for name in ["resultstr", "resultint", "resultobj"] {
            global.removeValue(forKey: Data(name.utf8))
        }
    }

    mutating func setConfigResultArray(_ values: [ScriptValue], string: Bool) throws {
        let key = Data((string ? "resultstr" : "resultint").utf8)
        global[key] = ScriptBinding(elements: values)
        try validate()
    }

    /// Stage the scalar components of one saved routine result together.
    mutating func stageRoutineResultScalars(from routine: SaveReaderCursor.Routine, in state: Data) throws {
        guard let values = try routine.savedResultScalars(in: state) else { return }
        try applySavedResultScalars(values)
    }

    /// Encode the currently populated result banks. Object names must already
    /// be resolved in the save namespace by the caller.
    func encodeRoutineResultSnapshot(objectNames: [String]? = nil, buttonName: String) throws -> Data {
        func integers(_ binding: ScriptBinding?) throws -> [Int32] {
            try (binding?.elements ?? []).map {
                guard let value = $0.integer else {
                    throw ResourceError.rejected("saved_result_snapshot_requires_integer")
                }
                return value
            }
        }
        func strings(_ binding: ScriptBinding?) throws -> [String] {
            try (binding?.elements ?? []).map {
                guard case .string(let value) = $0 else {
                    throw ResourceError.rejected("saved_result_snapshot_requires_string")
                }
                return value
            }
        }
        guard let click = global[Data("resultclkint".utf8)]?.first.integer,
              let stop = resultStopInt else {
            throw ResourceError.rejected("saved_result_snapshot_click_or_stop_unavailable")
        }
        return try SaveReaderCursor.Routine.encodeResultSnapshot(
            integers: integers(global[Data("resultint".utf8)]),
            strings: strings(global[Data("resultstr".utf8)]),
            objects: objectNames ?? savedRoutineResultObjectNames(), button: buttonName,
            buttonInts: integers(system[Data("resultbtnint".utf8)]),
            buttonStrings: strings(system[Data("resultbtnstr".utf8)]), click: click, stop: stop,
            subInts: integers(global[Data("resultsubint".utf8)]),
            subStrings: strings(global[Data("resultsubstr".utf8)]))
    }

    private func savedRoutineResultObjectNames() throws -> [String] {
        let resultKey = Data("resultobj".utf8)
        let results = global[resultKey]?.elements ?? []
        guard results.count <= 16 else {
            throw ResourceError.rejected("saved_result_object_count")
        }
        let names = try results.map { value -> String in
            guard case .object(let handle) = value, lists[handle] != nil || tables[handle] != nil else {
                throw ResourceError.rejected("saved_result_object_kind_unsupported")
            }
            let candidates = global.keys.filter { key in
                guard key != resultKey, !globalObjectAliases.contains(key),
                      frames.last?.locals[key] == nil, frames.last?.objectParameterNames[key] == nil,
                      key.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }),
                      let binding = global[key], binding.elements.count == 1 else { return false }
                return binding.first == .object(handle)
            }
            guard candidates.count == 1, let key = candidates.first else {
                throw ResourceError.rejected("saved_result_object_name_unresolved")
            }
            return String(decoding: key, as: UTF8.self)
        }
        return names + Array(repeating: "", count: 16 - names.count)
    }

    mutating func applySavedResultScalars(_ values: ScriptFrame.SavedResultScalars) throws {
        var candidate = self
        try candidate.setConfigResultArray(values.integers.map(ScriptValue.integer), string: false)
        try candidate.setConfigResultArray(values.strings.map(ScriptValue.string), string: true)
        if let click = values.click { try candidate.setClickResult(click) }
        if let stop = values.stop { candidate.resultStopInt = stop }
        for (name, elements) in [("resultbtnint", values.buttonInts.map(ScriptValue.integer)),
                                 ("resultbtnstr", values.buttonStrings.map(ScriptValue.string))] where !elements.isEmpty {
            candidate.system[Data(name.utf8)] = ScriptBinding(elements: elements)
        }
        for (name, elements) in [("resultsubint", values.subInts.map(ScriptValue.integer)),
                                 ("resultsubstr", values.subStrings.map(ScriptValue.string))] where !elements.isEmpty {
            candidate.global[Data(name.utf8)] = ScriptBinding(elements: elements)
        }
        try candidate.validate()
        self = candidate
    }

    struct SavedResultObjectCheck: Encodable, Sendable {
        let slot: Int
        let reference: SaveReaderCursor.Reference
        let status: EvidenceStatus
        let issue: String?
    }

    /// Candidate lookup for plain names in the staged global container.
    /// Keep text private and preserve each slot's original byte reference.
    func savedResultObjectChecks(from routine: SaveReaderCursor.Routine, in state: Data,
                                 indexedStatus: EvidenceStatus, shadowed: Set<Data>) throws -> [SavedResultObjectCheck] {
        let fields = try routine.resultObjectReferences.enumerated().compactMap { slot, field -> (Int, SaveReaderCursor.Reference, String)? in
            guard field.length != 0 else { return nil }
            return (slot, field, try field.utf16Text(in: state))
        }
        return fields.map { slot, field, name in
            let key = Data(asciiLower(name).utf8)
            let issue: String?
            if name.hasSuffix("]") {
                issue = "saved_object_index_resolution_unsupported"
            } else if !name.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                || (48...57).contains($0) || $0 == 95 }) {
                issue = "saved_object_name_outside_profile"
            } else if indexedStatus == .unsupported || shadowed.contains(key) {
                issue = "saved_object_indexed_container_precedence_unresolved"
            } else if let binding = global[key], binding.elements.count == 1,
                      case .object(let handle) = binding.first, lists[handle] != nil || tables[handle] != nil {
                issue = nil
            } else {
                issue = "saved_object_global_candidate_unavailable"
            }
            return .init(slot: slot, reference: field, status: issue == nil ? .inferred : .unsupported, issue: issue)
        }
    }

    /// Stage the category-2 scalar bindings independently of object reconstruction.
    static func stageSavedGlobalScalars(_ arrays: SaveVariableArrays) throws -> ScriptStorage {
        var staged = ScriptStorage()
        for record in arrays.records {
            let name = record.textFields[0]
            let key = Data(asciiLower(name).utf8)
            let values: [ScriptValue]
            let type: String
            switch record.values {
            case .integers(let integers):
                values = integers.map(ScriptValue.integer)
                type = "int"
            case .strings(let strings):
                guard strings.allSatisfy({ $0.utf8.count <= 8192 }) else {
                    throw ResourceError.rejected("save_global_string_value_limit")
                }
                values = strings.map(ScriptValue.string)
                type = "str"
            case .objectText, .absent:
                continue
            }
            guard staged.global[key] == nil,
                  try staged.declare(name, category: "gvar", type: type, count: values.count, validateAfter: false),
                  staged.global[key] != nil else {
                throw ResourceError.rejected("save_global_binding_identity")
            }
            staged.global[key] = ScriptBinding(elements: values)
        }
        try staged.validate()
        return staged
    }

    /// Stage only empty and canonical snd[index] reference-only object arrays.
    /// Their relation to native runtime references remains inferred.
    mutating func stageSavedSoundAliases(_ arrays: SaveVariableArrays) throws -> Int {
        var staged = self
        var count = 0
        for record in arrays.records {
            guard asciiLower(record.textFields[1]) == "obj", record.header[record.header.startIndex + 13] == 1,
                  case .objectText(let elements) = record.values, !elements.isEmpty else { continue }
            let name = record.textFields[0], key = Data(asciiLower(name).utf8)
            guard try staged.declare(name, category: "gvar", type: "obj", count: elements.count),
                  staged.global[key] != nil else { throw ResourceError.rejected("saved_sound_alias_binding_identity") }
            for (index, element) in elements.enumerated() {
                let text = element.reference
                let handle: UInt64
                if text.isEmpty { handle = Self.nullHandle }
                else {
                    guard text.hasPrefix("snd["), text.hasSuffix("]"),
                          let channel = Int32(text.dropFirst(4).dropLast()), text == "snd[\(channel)]",
                          case .object(let resolved) = try staged.readIndexed("snd", channel) else {
                        throw ResourceError.rejected("saved_sound_alias_reference_outside_profile")
                    }
                    handle = resolved
                }
                staged.global[key]!.elements[index] = .object(handle)
                staged.globalAliasReferences[key]?[index] = text
            }
            guard staged.savedSoundAliasTexts(key) != nil else { throw ResourceError.rejected("saved_sound_alias_binding_identity") }
            count += 1
        }
        guard staged.aliasReferenceBytes() <= 8 * 1024 * 1024 else { throw ResourceError.rejected("object_alias_reference_storage_limit") }
        try staged.validate()
        self = staged
        return count
    }

    /// Allocate identities for inline saved buttons in the isolated calculation probe.
    /// Reuse the script's single-label adapter when a saved target resolves in the resumed program.
    mutating func stageSavedGlobalButtonIdentities(_ arrays: SaveVariableArrays, resources: [Int: ScriptLocation] = [:],
                                                   textures: [Int: [Int32: ScriptLocation]] = [:],
                                                   sounds: [Int: [Int32: ScriptLocation]] = [:],
                                                   savedState: Data? = nil, program: ScriptProgram? = nil) throws -> Int {
        var staged = self
        var count = 0
        for record in arrays.records {
            let type = asciiLower(record.textFields[1])
            guard ["btn", "sbtn"].contains(type),
                  case .objectText(let elements) = record.values, !elements.isEmpty,
                  elements.allSatisfy({ $0.reference.isEmpty && $0.buttonPayload != nil }) else { continue }
            guard try staged.declare(record.textFields[0], category: "gvar", type: type, count: elements.count) else {
                throw ResourceError.rejected("save_global_button_binding_identity")
            }
            let key = Data(asciiLower(record.textFields[0]).utf8)
            guard let binding = staged.global[key], binding.elements.count == elements.count else {
                throw ResourceError.rejected("save_global_button_binding_identity")
            }
            for (element, value) in zip(elements, binding.elements) {
                guard case .object(let handle) = value, let payload = element.buttonPayload else {
                    throw ResourceError.rejected("save_global_button_binding_identity")
                }
                let rectangle = payload.drawableRectangle
                staged.buttonResources[handle] = resources[payload.decodedOffset]
                staged.buttonImages[handle] = textures[payload.decodedOffset]
                staged.buttonSounds[handle] = sounds[payload.decodedOffset]
                guard payload.userIntegerWords.count == 8 else {
                    throw ResourceError.rejected("saved_button_user_integer_count")
                }
                // The script command exposes the first four of the eight saved words.
                staged.buttonUserIntegers[handle] = Dictionary(uniqueKeysWithValues:
                    payload.userIntegerWords.prefix(4).enumerated().map { ($0.offset, $0.element) })
                // 0x67c698 reads the v10 button record at +0xf00; ck is +0xf08.
                if let checked = payload.rawCheckByte { staged.buttonCheckVisual[handle] = checked }
                else { staged.unknownSavedButtonChecks.insert(handle) }
                if let locked = payload.rawLockByte { staged.buttonLocks[handle] = locked }
                else { staged.unknownSavedButtonLocks.insert(handle) }
                // The sbtn input paths at 0x67c57b and 0x67c940 test the
                // inherited enable byte through 0x5ad0dc.
                if payload.rawImageEnableFlag != 0, staged.buttonResources[handle] != nil {
                    staged.enabledButtons.insert(handle)
                }
                guard rectangle[2] >= rectangle[0], rectangle[3] >= rectangle[1] else {
                    throw ResourceError.rejected("saved_button_rectangle_inverted")
                }
                // 0x67bc12–0x67bc39 clamps both spans to 4096.
                let right = Int32(min(Int64(rectangle[2]), Int64(rectangle[0]) + 4096))
                let bottom = Int32(min(Int64(rectangle[3]), Int64(rectangle[1]) + 4096))
                staged.drawableRectangles[handle] = [rectangle[0], rectangle[1], right, bottom]
                if let placement = payload.staticPlacement {
                    staged.buttonPlacement[handle] = [placement.x, placement.y, placement.z]
                }
                if let scale = payload.staticScale {
                    staged.savedButtonPlacementScale[handle] = SIMD2(scale.x, scale.y)
                }
                if let savedState {
                    let strings = try payload.userStrings.prefix(4).map { try $0.utf16Text(in: savedState) }
                    let populated = strings.enumerated().filter { !$0.element.isEmpty }
                    staged.buttonUserStrings[handle] = Dictionary(uniqueKeysWithValues: populated.map { ($0.offset, $0.element) })
                    if populated.count == 1, let first = populated.first, first.offset == 0,
                       let program, let destination = try? program.label(first.element),
                       program.ancestors[destination].isEmpty {
                        staged.buttonScriptTargets[handle] = first.element
                    }
                }
            }
            count += 1
        }
        self = staged
        return count
    }

    mutating func stageSavedInactiveTimers(_ arrays: SaveVariableArrays) throws -> Int {
        var staged = self
        var count = 0
        for record in arrays.records {
            guard asciiLower(record.textFields[1]) == "timer",
                  case .objectText(let elements) = record.values, elements.count == 1,
                  elements.allSatisfy({ element in
                      element.reference.isEmpty && element.timerPayload?.isInactiveWithoutCallback == true
                  }) else { continue }
            let name = record.textFields[0]
            guard try staged.declare(name, category: "gvar", type: "timer", count: elements.count),
                  let binding = staged.global[Data(asciiLower(name).utf8)],
                  binding.elements.count == elements.count else {
                throw ResourceError.rejected("save_global_timer_binding_identity")
            }
            for (element, value) in zip(elements, binding.elements) {
                guard case .object(let handle) = value, let timer = element.timerPayload,
                      staged.timers[handle] != nil else {
                    throw ResourceError.rejected("save_global_timer_binding_identity")
                }
                staged.timers[handle]?.interval = timer.interval
            }
            count += 1
        }
        self = staged
        return count
    }

    /// Stage inline image identities and verified static placement fields.
    struct SavedImageResource {
        let location: ScriptLocation
        let width: Int
        let height: Int
        let memberCount: Int
        let hasExtendedContainerMetadata: Bool
        var isTheoraResource = false
        var motionCount: Int? = nil
        var motionUpdateThreshold: Int32? = nil
        var boundTextures: [Int32: ScriptLocation] = [:]
    }

    /// Stage only a partial, disposable message preview. The caller must not
    /// use this storage for a saved execution candidate.
    mutating func stageSavedMessagePreviews(_ arrays: SaveVariableArrays, state: Data,
                                            resources: [Int: SavedImageResource]) throws -> Int {
        var staged = self
        var count = 0
        for record in arrays.records {
            guard asciiLower(record.textFields[1]) == "msg",
                  case .objectText(let elements) = record.values, !elements.isEmpty else { continue }
            guard elements.allSatisfy({ $0.reference.isEmpty && $0.messagePayload != nil }),
                  try staged.declare(record.textFields[0], category: "gvar", type: "msg", count: elements.count),
                  let binding = staged.global[Data(asciiLower(record.textFields[0]).utf8)],
                  binding.elements.count == elements.count else {
                throw ResourceError.rejected("saved_message_preview_binding_outside_profile")
            }
            for (element, value) in zip(elements, binding.elements) {
                guard case .object(let handle) = value, let payload = element.messagePayload,
                      let placement = payload.staticPlacement, let scale = payload.staticScale,
                      payload.drawableRectangle.count == 4, payload.rawTextMargins.count == 2,
                      payload.drawableRectangle[2] >= payload.drawableRectangle[0],
                      payload.drawableRectangle[3] >= payload.drawableRectangle[1],
                      payload.textureSlots.allSatisfy({ (0...1).contains($0.index) }) else {
                    throw ResourceError.rejected("saved_message_preview_layout_outside_profile")
                }
                let resource = resources[payload.decodedOffset]
                if payload.rawImageDrawGate != 0, payload.imageSource != nil {
                    guard let resource,
                          Set(resource.boundTextures.keys) == Set(payload.textureSlots.map { Int32($0.index) }) else {
                        throw ResourceError.rejected("saved_message_preview_background_outside_profile")
                    }
                    if resource.hasExtendedContainerMetadata {
                        // Match normal message member selection when the recipe
                        // has no separate motion-name table.
                        let motionCount = resource.motionCount ?? resource.memberCount
                        guard payload.rawActionIndex >= 0,
                              Int(payload.rawActionIndex) < motionCount, payload.rawActionElapsed >= 0,
                              payload.rawActionClockRemainder == 0, payload.rawActionSpeed == 100 else {
                            throw ResourceError.rejected("saved_message_preview_motion_outside_profile")
                        }
                    } else if resource.memberCount > 1 || !resource.boundTextures.isEmpty {
                        throw ResourceError.rejected("saved_message_preview_background_outside_profile")
                    }
                } else if !payload.textureSlots.isEmpty {
                    throw ResourceError.rejected("saved_message_preview_background_outside_profile")
                }
                let text = try payload.primaryText(in: state)
                guard payload.textStrings.count == 5 else {
                    throw ResourceError.rejected("saved_message_layout_strings_outside_profile")
                }
                let layoutStrings = try payload.textStrings[2...4].map { reference in
                    guard reference.length <= 16_384 else {
                        throw ResourceError.rejected("saved_message_layout_strings_outside_profile")
                    }
                    let value = try reference.utf16Text(in: state)
                    guard value.utf8.count <= 8192 else {
                        throw ResourceError.rejected("saved_message_layout_strings_outside_profile")
                    }
                    return value
                }
                var message = MessageObject()
                message.placement = [placement.x, placement.y, placement.z]
                message.transform = .init(depth: 0, scale: [scale.x, scale.y, scale.z],
                                          rotation: [0, 0, 0], loop: 0)
                let rectangle = payload.drawableRectangle
                message.textBounds = [rectangle[0], rectangle[1],
                    Int32(min(Int64(rectangle[2]), Int64(rectangle[0]) + 4096)),
                    Int32(min(Int64(rectangle[3]), Int64(rectangle[1]) + 4096))]
                message.textMargins = payload.rawTextMargins
                message.prohibitedLineStart = layoutStrings[0]
                message.prohibitedLineEnd = layoutStrings[1]
                message.ignoredReturnWords = layoutStrings[2]
                message.kinsokuWordLength = payload.rawKinsokuWordLength
                message.asEnabled = payload.rawAsEnabled != 0
                message.apEnabled = payload.rawApEnabled != 0
                message.enabled = payload.rawImageDrawGate != 0
                message.background = resource?.location
                message.backgroundBoundImages = resource?.boundTextures ?? [:]
                message.backgroundMemberCount = resource?.memberCount ?? 0
                if payload.rawImageDrawGate != 0, resource?.hasExtendedContainerMetadata == true {
                    message.backgroundSelectedMember = payload.rawActionIndex
                    message.backgroundMotionStartTick = staged.visualTicks - Int64(payload.rawActionElapsed)
                }
                message.committedOutput = text.displayedOutput
                message.pendingOutput = text.pendingOutput
                message.committedRawOutput = text.displayed
                message.pendingRawOutput = text.pending
                staged.messages[handle] = message
            }
            count += 1
        }
        try staged.validate()
        self = staged
        return count
    }

    mutating func stageSavedGlobalImageIdentities(_ arrays: SaveVariableArrays,
                                                  resources: [Int: SavedImageResource] = [:],
                                                  savedState: Data? = nil) throws -> Int {
        var staged = self
        var count = 0
        for record in arrays.records {
            let type = asciiLower(record.textFields[1])
            guard ["img", "simg"].contains(type),
                  case .objectText(let elements) = record.values, !elements.isEmpty,
                  elements.allSatisfy({ $0.reference.isEmpty && $0.imagePayload != nil }) else { continue }
            guard try staged.declare(record.textFields[0], category: "gvar", type: type, count: elements.count) else {
                throw ResourceError.rejected("save_global_image_binding_identity")
            }
            let key = Data(asciiLower(record.textFields[0]).utf8)
            guard let binding = staged.global[key], binding.elements.count == elements.count else {
                throw ResourceError.rejected("save_global_image_binding_identity")
            }
            for (element, value) in zip(elements, binding.elements) {
                guard case .object(let handle) = value, let payload = element.imagePayload else {
                    throw ResourceError.rejected("save_global_image_binding_identity")
                }
                guard payload.userIntegerWords.count == 8 else {
                    throw ResourceError.rejected("saved_image_user_integer_count")
                }
                staged.buttonUserIntegers[handle] = Dictionary(uniqueKeysWithValues:
                    payload.userIntegerWords.prefix(4).enumerated().map { ($0.offset, $0.element) })
                guard payload.userStrings.count == 8 else {
                    throw ResourceError.rejected("saved_image_user_string_count")
                }
                if let savedState {
                    let strings = try payload.userStrings.prefix(4).map { try $0.utf16Text(in: savedState) }
                    staged.buttonUserStrings[handle] = Dictionary(uniqueKeysWithValues:
                        strings.enumerated().filter { !$0.element.isEmpty }.map { ($0.offset, $0.element) })
                } else if payload.userStrings.prefix(4).contains(where: { $0.length != 0 }) {
                    throw ResourceError.rejected("saved_image_user_string_state_required")
                }
                guard payload.drawGate == 0 || payload.staticOpacity != nil || payload.opacityTransition != nil else {
                    throw ResourceError.rejected("saved_drawable_image_opacity_unrestored:\(payload.decodedOffset)")
                }
                guard payload.drawGate == 0 || payload.staticPlacement != nil || payload.activePlacement != nil else {
                    throw ResourceError.rejected("saved_drawable_image_placement_unrestored:\(payload.decodedOffset)")
                }
                guard payload.drawGate == 0 || payload.staticScale != nil else {
                    throw ResourceError.rejected("saved_drawable_image_scale_or_transform_unrestored:\(payload.decodedOffset)")
                }
                if let resource = resources[payload.decodedOffset] {
                    if resource.isTheoraResource {
                        guard payload.rawActionIndex == -1 ||
                            (payload.rawActionIndex == 0 && payload.rawActionElapsed >= 0 &&
                             payload.rawActionClockRemainder == 0 && payload.rawActionSpeed == 100) else {
                            throw ResourceError.rejected("saved_video_image_clock_outside_profile:\(payload.decodedOffset)")
                        }
                    }
                    staged.images[handle]?.resource = resource.location
                    staged.images[handle]?.boundImages = resource.boundTextures
                    staged.images[handle]?.width = resource.width > 0 ? resource.width : nil
                    staged.images[handle]?.height = resource.height > 0 ? resource.height : nil
                    staged.images[handle]?.memberCount = resource.memberCount
                    staged.images[handle]?.hasExtendedContainerMetadata = resource.hasExtendedContainerMetadata
                    staged.images[handle]?.isTheoraResource = resource.isTheoraResource
                    if let count = resource.motionCount, payload.rawActionIndex >= 0,
                       Int(payload.rawActionIndex) < count {
                        staged.images[handle]?.selectedMember = payload.rawActionIndex
                        if !resource.isTheoraResource {
                            staged.images[handle]?.savedLayerTimeSnapshot = .init(
                                times: payload.layerTiming.timeWords, auxiliary: payload.layerTiming.auxiliaryWords,
                                visualTick: staged.visualTicks)
                        }
                        if payload.rawActionElapsed >= 0 {
                            staged.images[handle]?.motionStartTick = staged.visualTicks
                            staged.images[handle]?.motionElapsedBeforeSpeedChange = Int64(payload.rawActionElapsed) * 100
                            staged.images[handle]?.playbackSpeed = min(3000, max(0, payload.rawActionSpeed))
                            if let threshold = resource.motionUpdateThreshold, threshold > 0,
                               payload.rawActionClockRemainder >= 0 {
                                staged.images[handle]?.restoredMotionThreshold = Int64(threshold) * 100
                                staged.images[handle]?.restoredMotionRemainder = Int64(payload.rawActionClockRemainder) * 100
                            }
                        }
                    }
                }
                staged.images[handle]?.savedDrawGate = payload.drawGate != 0
                staged.images[handle]?.enabled = payload.enableFlag != 0
                if let placement = payload.staticPlacement {
                    staged.images[handle]?.placement = [placement.x, placement.y, placement.z]
                } else if let motion = payload.activePlacement {
                    staged.images[handle]?.placement = [motion.origin.x, motion.origin.y, motion.origin.z]
                    staged.placementTransitions[handle] = .init(
                        destination: [motion.destination.x, motion.destination.y, motion.destination.z],
                        duration: motion.duration, elapsed: motion.duration - motion.remaining,
                        destinationTransform: .init(depth: 0, scale: [motion.destinationScale.x, motion.destinationScale.y, motion.destinationScale.z],
                                                    rotation: [0, 0, 0], loop: 0),
                        savedMode: motion.mode)
                }
                if let fade = payload.opacityTransition {
                    staged.images[handle]?.immediateOpacity = fade.origin
                    staged.images[handle]?.opacityEndpoint = (fade.target, fade.remaining, fade.duration, fade.repeats)
                } else if let opacity = payload.staticOpacity {
                    staged.images[handle]?.immediateOpacity = opacity
                }
                if let scale = payload.staticScale {
                    staged.images[handle]?.transform = .init(depth: 0, scale: [scale.x, scale.y, scale.z],
                                                              rotation: [0, 0, 0], loop: 0)
                }
                staged.images[handle]?.savedPlacementMode = payload.rawPlacementMode
            }
            count += 1
        }
        self = staged
        return count
    }

    /// Rebuild standalone text objects in the isolated restore candidate.
    /// Reference-only entries need the original alias mapping.
    mutating func stageSavedGlobalTextObjects(_ arrays: SaveVariableArrays) throws -> (lists: Int, tables: Int) {
        var staged = self
        var counts = (lists: 0, tables: 0)
        var remainingTextBytes = 8 * 1024 * 1024
        for record in arrays.records {
            let type = asciiLower(record.textFields[1])
            guard type == "list" || type == "table",
                  case .objectText(let elements) = record.values, !elements.isEmpty else { continue }
            let payloads = elements.compactMap(\.payload)
            guard payloads.count == elements.count,
                  payloads.allSatisfy({ $0.declaredLineCount >= 0 }) else { continue }
            let name = record.textFields[0]
            let key = Data(asciiLower(name).utf8)
            guard try staged.declare(name, category: "gvar", type: type, count: payloads.count),
                  let binding = staged.global[key], binding.elements.count == payloads.count else {
                throw ResourceError.rejected("save_global_text_object_binding_identity")
            }
            for (value, payload) in zip(binding.elements, payloads) {
                guard case .object(let handle) = value else {
                    throw ResourceError.rejected("save_global_text_object_binding_identity")
                }
                guard payload.lines.count <= 10_000 else {
                    throw ResourceError.rejected("saved_text_object_line_limit")
                }
                let byteCount = payload.lines.reduce(3) { $0 + $1.utf8.count + 1 }
                guard byteCount <= 1024 * 1024, byteCount <= remainingTextBytes else {
                    throw ResourceError.rejected("saved_text_object_size_limit")
                }
                remainingTextBytes -= byteCount
                var text = Data([0xef, 0xbb, 0xbf])
                text.reserveCapacity(byteCount)
                for line in payload.lines {
                    guard !line.unicodeScalars.contains(where: { $0.value == 0 || $0 == "\r" || $0 == "\n" }) else {
                        throw ResourceError.rejected("saved_text_object_line_outside_profile")
                    }
                    text.append(contentsOf: line.utf8)
                    text.append(10)
                }
                if type == "list" {
                    staged.lists[handle] = try ScriptStringList(data: text, relativePath: "save-list-preview.txt")
                } else {
                    staged.tables[handle] = try ScriptTable(data: text, relativePath: "save-table-preview.txt",
                                                            allowWideKeys: true)
                }
            }
            if type == "list" { counts.lists += 1 } else { counts.tables += 1 }
        }
        try staged.validate()
        self = staged
        return counts
    }

    mutating func resultInteger(_ value: Int32) throws {
        let key = Data(asciiLower("ResultInt").utf8)
        guard global[key] == nil || global[key]?.first.typeName == "integer"
        else { throw ResourceError.rejected("table_result_register_type_conflict") }
        if global[key] == nil {
            // The native result record reserves 0x40 bytes before ResultObj.
            global[key] = ScriptBinding(elements: Array(repeating: .integer(0),count: 16))
        }
        global[key]!.elements[0] = .integer(value)
        try validate()
    }
    mutating func resultString(_ value: String) throws {
        guard value.utf8.count <= 8192 else { throw ResourceError.rejected("string_value_limit") }
        let key = Data(asciiLower("ResultStr").utf8)
        guard global[key] == nil || global[key]?.first.typeName == "string"
        else { throw ResourceError.rejected("table_result_register_type_conflict") }
        if global[key] == nil { global[key] = ScriptBinding(elements: [.string(value)]) }
        else { global[key]!.elements[0] = .string(value) }
        try validate()
    }
    func scopedTables() throws -> [UInt64] {
        let scope = frames.last!.tableScope
        guard !scope.isEmpty, scope.allSatisfy({ tables[$0] != nil || lists[$0] != nil })
        else { throw ResourceError.rejected("table_object_scope_required") }
        return scope
    }
    func validate() throws {
        let dictionaries = [system,global] + frames.map(\.locals)
        guard dictionaries.reduce(0, { $0+$1.count }) <= 4096 else { throw ResourceError.rejected("scalar_storage_limit") }
        var elements = 0
        var strings = 0
        for dictionary in dictionaries {
            for binding in dictionary.values {
                elements += binding.elements.count
                guard elements <= 65_536 else { throw ResourceError.rejected("array_total_element_limit") }
                for value in binding.elements {
                    if case .string(let text) = value { strings += text.utf8.count }
                }
            }
        }
        guard strings <= 8*1024*1024 else { throw ResourceError.rejected("string_storage_limit") }
        guard aliasReferenceBytes() <= 8*1024*1024 else {
            throw ResourceError.rejected("object_alias_reference_storage_limit")
        }
        var tableSourceBytes = 0
        var tableSourceLines = 0
        var tableBytes = 0
        var tableEntries = 0
        for table in tables.values {
            if let summary = table.summary {
                tableSourceBytes += summary.source.byteLength
                tableSourceLines += summary.lines.count
            }
            tableBytes += table.storedBytes
            tableEntries += table.count
        }
        guard tableSourceBytes <= 8*1024*1024, tableSourceLines <= 50_000,
              tableBytes <= 16*1024*1024, tableEntries <= 100_000
        else { throw ResourceError.rejected("table_storage_budget") }

        var listSourceBytes = 0
        var listLines = 0
        var listGeneratedBytes = 0
        for list in lists.values {
            listSourceBytes += list.summary?.source.byteLength ?? 0
            listLines += list.lineCount
            listGeneratedBytes += list.generatedBytes
        }
        guard listSourceBytes <= 8*1024*1024, listLines <= 50_000,
              listGeneratedBytes <= 8*1024*1024
        else { throw ResourceError.rejected("list_storage_budget") }
    }
}
