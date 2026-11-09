import Foundation

struct ScriptBinding: Sendable {
    var elements: [ScriptValue]
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
    var tableScope: [UInt64] = []
    var parameterCount: Int32?
    var integerParameters: [Int32]?
    var objectParameterNames: [Data: UInt64] = [:]
    var stringParameters: [String]?
    var objectAliases: Set<Data> = []
    var forPlans: [Int: ScriptForPlan] = [:]
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

    static let nullHandle = UInt64.max-6
    var voiceActorAliases: [[String]]?
    static let configHandle: UInt64 = 0
    static let inputHandle = UInt64.max-5
    private static let inputName = Data("inp".utf8)
    static let soundHandle = UInt64.max-4
    private static let soundName = Data("snd".utf8)
    struct SoundChannel: Sendable {
        var playing = false
        var playbackStartStep: Int?
        var filterRequest: String?
        var loopRequest: Int32?
        var seekRequest: Int32?
        var volumeType: Int32?
        var volumeDuration: Int32?
        var volumeDelay: Int32?
        var volumeChangePending = false
        var panChangePending = false
        var panRequest: (position: Int32, duration: Int32, delay: Int32)?
        var volume: Int32?
        var resource: ScriptLocation?
    }
    var soundChannels: [UInt64: SoundChannel] = [:]
    static let effectHandle = UInt64.max-3
    private static let effectName = Data("eff".utf8)
    // Requested solid-color transition for the headless scene.
    var effectBackgroundColor: UInt32?
    var effectFillColor: UInt32?
    var effectCapturePriority: Int32?
    var effectField5F: UInt8?
    var fadeInMode: Int32?
    var fadeInDuration: Int32?
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
    var lineLogLockTag: UInt8?
    static let fileLogHandle = UInt64.max-40
    private static let fileLogName = Data("flog".utf8)
    var fileLogPaths: [String] = []
    var fileLogValues: [Data: Int32] = [:]
    var fileLogLocked: Bool?
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
    var systemPlayMode: Int32 = 0
    var systemInputMask: Int32 = 0xffffff
    var linkedPrimaryInputMask: Int32?
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
    private static let screenLockName = Data("_lkscreen".utf8)
    var systemNameSlots = Array(repeating: "", count: 7)
    var thumbnailPriorities: (Int32, Int32)?
    var systemFrameEvent: ScriptLocation?
    var systemLockMask: Int32?
    var systemCustomLockMask: Int32?
    // The zero command writes this engine field; its downstream effect is unresolved.
    var engineField98: Int32?
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
    var system: [Data: ScriptBinding] = [:]
    var configuration: ScriptTable?
    var fontOverrides: [String: ScriptValue] = [:]
    var actorVolumeOverrides: [Int32: Int32] = [:]
    var actorMuteOverrides: [Int32: Int32] = [:]
    var configVoiceValues: [Int32: Int32] = [:]
    var configVoiceModes: [Int32: Int32] = [:]
    var global: [Data: ScriptBinding] = [:]
    var frames: [ScriptFrame] = [ScriptFrame(returnIndex: nil)]
    var tables: [UInt64: ScriptTable] = [:]
    var lists: [UInt64: ScriptStringList] = [:]
    struct PlacementTransition: Sendable {
        let destination: [Int32]
        let duration: Int32
        var elapsed: Int32 = 0
        var destinationTransform: ImageTransform?
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
        var resourceLoadLocation: ScriptLocation?
        var width: Int?
        var height: Int?
        var placement: [Int32]?
        var motion: MotionSettings?
        var tabOrder: Int32?
        var memberCount = 0
        var selectedMember: Int32?
        var motionStartTick: Int64?
        var motionElapsedBeforeSpeedChange: Int64 = 0

        var isDialogueWindowAnimation: Bool {
            placement?.dropFirst(2).first == 1500 &&
                resource?.sourceSHA256 == "49c040e37eebc295e9fc2b8fdf9db40e70cc773dd41ab9ae486e95dd84cdda39"
        }

        func motionElapsedHundredths(at tick: Int64) -> Int64? {
            guard let motionStartTick else { return nil }
            let speed = Int64(playbackSpeed ?? 100)
            let elapsed = min(tick - motionStartTick, Int64(Int32.max) * 100)
            return min(motionElapsedBeforeSpeedChange + elapsed * speed, Int64(Int32.max) * 100)
        }
        var enabled = false
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
    var buttons: Set<UInt64> = []
    struct MessageObject: Sendable {
        var usesTimedCenterText: Bool {
            guard let action = backgroundSelectedMember, (0...4).contains(action) else { return false }
            return background?.sourceSHA256 == "97bb05fa8aaaff094f9ef12978d6fca0c7af6bd3081a01bbedd7ae5c02902a68"
        }

        enum Output: Sendable {
            case directive(name: String, operands: [Int32])
            case text(String)
            case ruby(base: String, annotation: String)
        }

        var pendingOutput: [Output] = []
        var committedOutput: [Output] = []

        mutating func commitOutput() throws {
            guard pendingOutput.count <= 1024 - committedOutput.count else {
                throw ResourceError.rejected("message_committed_output_limit")
            }
            committedOutput.append(contentsOf: pendingOutput)
            pendingOutput.removeAll()
        }

        /// Headless estimate of the text pen. Glyph shaping is a host concern.
        var headlessTextPosition: [Int32] {
            var x: Int64 = 0, y: Int64 = 0
            var width: Int64 = 24, height: Int64 = 24
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
                case .directive("n", _):
                    newLine()
                case .directive("i", let offset):
                    // 0x679761 adds to the horizontal pen and clamps it at zero.
                    x = max(0, x + Int64(offset[0]))
                case .text(let text), .ruby(let text, _):
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
    func buttonArrayCount(_ raw: String) throws -> Int32 {
        let key = Data(asciiLower(raw).utf8)
        guard let binding = frames.last?.locals[key] ?? global[key],
              binding.elements.allSatisfy({ if case .object(let handle) = $0 { return buttons.contains(handle) }; return false })
        else { throw ResourceError.rejected("garr_requires_button_array") }
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
    var buttonMotion: [UInt64: MotionSettings] = [:]
    var buttonPlacement: [UInt64: [Int32]] = [:]
    var buttonSounds: [UInt64: [Int32: ScriptLocation]] = [:]
    var buttonImages: [UInt64: [Int32: ScriptLocation]] = [:]
    var buttonResources: [UInt64: ScriptLocation] = [:]
    var images: [UInt64: ImageObject] = [:]
    private var nextObject: UInt64 = 1

    private static let indexedSoundBase = UInt64.max - 1024
    private static let indexedSoundCount: Int32 = 25

    static func isStreamHandle(_ handle: UInt64) -> Bool {
        handle == soundHandle || (indexedSoundBase - UInt64(indexedSoundCount - 1)..<indexedSoundBase).contains(handle)
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
           lists[handle] == nil || binding.elements.count == 1 {
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
    mutating func resetIntegerBinding(_ raw: String) throws {
        let key = Data(asciiLower(raw).utf8)
        let frame = frames.count - 1
        guard let binding = frames[frame].locals[key] ?? global[key] ?? system[key],
              binding.first.integer != nil else {
            throw ResourceError.rejected("init_requires_integer_binding")
        }
        let reset = ScriptBinding(elements: Array(repeating: .integer(0), count: binding.elements.count))
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
            if localAlias { frames[i].locals[name]!.elements[index] = .object(handle) }
            else { global[name]!.elements[index] = .object(handle) }
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
    @discardableResult mutating func declare(_ raw: String, category: String, type: String, count: Int = 1) throws -> Bool {
        guard (1...4096).contains(count) else { throw ResourceError.rejected("array_element_count_limit") }
        guard !["theora","timer"].contains(type) || count == 1 else { throw ResourceError.rejected("object_array_outside_profile") }
        guard raw.utf8.count <= 4096, Self.isDecimalDeclarationName(raw,category: category,type: type) || raw.range(of: #"^#?[\p{L}_][\p{L}\p{N}_]*$"#, options: .regularExpression) != nil
        else { throw ResourceError.rejected("non_scalar_declaration_name") }
        guard ["int","str","table","list","img","simg","theora","btn","sbtn","obj","msg","timer"].contains(type) else { throw ResourceError.rejected("declaration_type_outside_profile") }
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
        if type == "msg" {
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
                else { images[handle] = ImageObject() }
                return .object(handle)
            }
        } else {
            let value: ScriptValue
            switch type {
            case "obj":
                if category == "gvar" { globalObjectAliases.insert(name) }
                else { frames[i].objectAliases.insert(name) }
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
        let binding = ScriptBinding(elements: elements)
        if category == "var" { frames[i].locals[name] = binding }
        else if category == "gvar" { global[name] = binding }
        else { system[name] = binding }
        try validate(); return true
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
        return frames.last?.locals[key] != nil ? 3 : global[key] != nil ? 2 : (system[key] != nil || key == Self.cameraName || key == Self.replacementName || key == Self.inputName || key == Self.configName || key == Self.temporaryDataName || key == Self.memoryDataName || key == Self.saveDataName || key == Self.miscName || key == Self.dialogueLogName || key == Self.lineLogName || key == Self.fileLogName || key == Self.systemKeyName || key == Self.systemName || key == Self.saveLockName || key == Self.loadLockName || key == Self.skipLockName || key == Self.screenLockName || key == Self.soundEffectTypeName || key == Self.outQuartName || key == Self.linearMotionName || key == Self.effectName || key == Self.soundName) ? 1 : 0
    }
    mutating func deleteGlobalBinding(_ name: String) throws {
        let key = Data(asciiLower(name).utf8)
        // 0x69f03a returns without deleting when lookup finds no binding.
        if lookupCategory(name) == 0 { return }
        guard frames.last?.locals[key] == nil, let binding = global[key] else {
            throw ResourceError.rejected("delete_requires_global_binding")
        }
        if globalObjectAliases.remove(key) != nil {
            global.removeValue(forKey: key)
            return
        }
        let handles = binding.elements.compactMap { value -> UInt64? in
            if case .object(let handle) = value { return handle }
            return nil
        }
        guard handles.allSatisfy({ images[$0] != nil || movies[$0] != nil || buttons.contains($0)
            || messages[$0] != nil || timers[$0] != nil || tables[$0] != nil || lists[$0] != nil }) else {
            throw ResourceError.rejected("delete_object_type_outside_profile")
        }
        global.removeValue(forKey: key)
        for handle in handles {
            placementTransitions.removeValue(forKey: handle)
            images.removeValue(forKey: handle)
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

    mutating func initializeButtonRegisters() throws {
        for (name,value) in [("resultbtnstr",ScriptValue.string("")),("resultbtnint",.integer(0))] {
            let key = Data(name.utf8)
            if system[key] == nil {
                system[key] = ScriptBinding(elements: Array(repeating: value,count: 4))
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
                  try staged.declare(name, category: "gvar", type: type, count: values.count),
                  staged.global[key] != nil else {
                throw ResourceError.rejected("save_global_binding_identity")
            }
            staged.global[key] = ScriptBinding(elements: values)
            try staged.validate()
        }
        return staged
    }

    /// Allocate identities for inline saved buttons in the isolated calculation probe.
    /// Drawable state and callbacks are outside this probe's command profile.
    mutating func stageSavedGlobalButtonIdentities(_ arrays: SaveVariableArrays, resources: [Int: ScriptLocation] = [:]) throws -> Int {
        var staged = self
        var count = 0
        for record in arrays.records {
            guard asciiLower(record.textFields[1]) == "sbtn",
                  case .objectText(let elements) = record.values, !elements.isEmpty,
                  elements.allSatisfy({ $0.reference.isEmpty && $0.buttonPayload != nil }) else { continue }
            guard try staged.declare(record.textFields[0], category: "gvar", type: "sbtn", count: elements.count) else {
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
                guard rectangle[2] >= rectangle[0], rectangle[3] >= rectangle[1] else {
                    throw ResourceError.rejected("saved_button_rectangle_inverted")
                }
                // 0x67bc12–0x67bc39 clamps both spans to 4096.
                let right = Int32(min(Int64(rectangle[2]), Int64(rectangle[0]) + 4096))
                let bottom = Int32(min(Int64(rectangle[3]), Int64(rectangle[1]) + 4096))
                staged.drawableRectangles[handle] = [rectangle[0], rectangle[1], right, bottom]
            }
            count += 1
        }
        self = staged
        return count
    }

    /// Stage inline image identities and verified static placement fields.
    mutating func stageSavedGlobalImageIdentities(_ arrays: SaveVariableArrays, resources: [Int: ScriptLocation] = [:]) throws -> Int {
        var staged = self
        var count = 0
        for record in arrays.records {
            guard asciiLower(record.textFields[1]) == "simg",
                  case .objectText(let elements) = record.values, !elements.isEmpty,
                  elements.allSatisfy({ $0.reference.isEmpty && $0.imagePayload != nil }) else { continue }
            guard try staged.declare(record.textFields[0], category: "gvar", type: "simg", count: elements.count) else {
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
                staged.images[handle]?.resource = resources[payload.decodedOffset]
                if let placement = payload.staticPlacement {
                    staged.images[handle]?.placement = [placement.x, placement.y, placement.z]
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
