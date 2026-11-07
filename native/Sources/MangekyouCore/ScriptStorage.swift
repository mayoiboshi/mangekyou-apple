import Foundation

struct ScriptBinding: Sendable {
    var elements: [ScriptValue]
    var first: ScriptValue { elements[0] }
}

struct ScriptFrame: Sendable {
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
        var filterRequest: String?
        var loopRequest: Int32?
        var seekRequest: Int32?
        var volumeType: Int32?
        var volumeDuration: Int32?
        var volumeDelay: Int32?
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
    var fadeInDuration: Int32?
    var fadeInPriority: Int32?
    var fadeInRule: (resource: ScriptLocation, power: Int32)?
    var fadeTransform: [Int32]?
    var fadeTiming: (mode: UInt8, power: Int32)?
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
    var fileLogLocked: Bool?
    var systemPlayMode: Int32 = 0
    var systemAutoPlayValue: Int32 = 0
    static let systemHandle = UInt64.max-2
    private static let systemName = Data("sys".utf8)
    private static let soundEffectTypeName = Data("_stse".utf8)
    private static let outQuartName = Data("_mmoutquart".utf8)
    private static let skipLockName = Data("_lkskip".utf8)
    private static let screenLockName = Data("_lkscreen".utf8)
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
    private static let temporaryDataName = Data("tdat".utf8)
    static let saveDataHandle = UInt64.max
    private static let configName = Data("cfg".utf8)
    private static let saveDataName = Data("dat".utf8)
    // Fresh session namespace. Import of original saves is a separate operation.
    private let sessionSaveNames: Set<Data> = []

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
        var standaloneDPNG = false
        var boundImages: [Int32: ScriptLocation] = [:]
        var extendedScalarValues: [Int: Int32] = [:]
        var filterOverrides: [Int32: String] = [:]
        var playbackSpeed: Int32?
        var animationSpeed: Int32?
        var volume: Int32?
        var volumeType: Int32?
        var alignment: (x: Int32, y: Int32)?
        var colorRequest: (alpha: Int32, multiply: Int32, add: Int32, duration: Int32, loop: Int32)?
        var blendMode: Int32?
        var textureFilter: Int32?
        var drawChannel: Int32?
        var inputMask: Int32?
        var outputMask: Int32?
        var resource: ScriptLocation?
        var width: Int?
        var height: Int?
        var placement: [Int32]?
        var motion: MotionSettings?
        var tabOrder: Int32?
        var memberCount = 0
        var selectedMember: Int32?
        var enabled = false
    }
    struct MovieObject: Sendable {
        var initialized = false
        var durationTicks: Int32?
        var resource: ScriptLocation?
        var placement: [Int32]?
        var enabled = false
    }
    var movies: [UInt64: MovieObject] = [:]
    var buttons: Set<UInt64> = []
    struct MessageObject: Sendable {
        enum Output: Sendable {
            case directive(name: String, operands: [Int32])
            case text(String)
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
                case .text(let text):
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
    var buttonTextOutput: [UInt64: [MessageObject.Output]] = [:]
    var drawableRectangles: [UInt64: [Int32]] = [:]
    var buttonTextBounds: [UInt64: [Int32]] = [:]
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
        if name == Self.miscName { return .object(Self.miscHandle) }
        if name == Self.dialogueLogName { return .object(Self.dialogueLogHandle) }
        if name == Self.lineLogName { return .object(Self.lineLogHandle) }
        if name == Self.fileLogName { return .object(Self.fileLogHandle) }
        if name == Self.systemName { return .object(Self.systemHandle) }
        if name == Self.soundEffectTypeName { return .integer(2) }
        if name == Self.outQuartName { return .integer(3) }
        if name == Self.skipLockName { return .integer(0x80) }
        if name == Self.screenLockName { return .integer(1) }
        if name == Self.systemKeyName { return .object(Self.systemKeyHandle) }
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
        if case .object(let handle) = binding.first, !globalObjectAliases.contains(name), !((frames.last?.objectAliases.contains(name)) ?? false), name != Data("resultobj".utf8), !buttons.contains(handle), messages[handle] == nil, tables[handle] == nil, images[handle] == nil {
            throw ResourceError.rejected("object_index_outside_profile")
        }
        guard index >= 0, Int(index) < binding.elements.count else {
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
        }
        guard previous.first.typeName == value.typeName, value.typeName != "object"
        else { throw ResourceError.rejected("scalar_assignment_type_outside_profile") }
        if case .string(let s) = value, s.utf8.count > 8192 { throw ResourceError.rejected("string_value_limit") }
        if frames[i].locals[name] != nil { frames[i].locals[name]!.elements[index] = value }
        else if global[name] != nil { global[name]!.elements[index] = value }
        else { system[name]!.elements[index] = value }
        try validate()
    }
    static func isDecimalDeclarationName(_ raw: String, category: String, type: String) -> Bool {
        category == "var" && type == "int" && !raw.isEmpty &&
            raw.utf8.allSatisfy { (48...57).contains($0) }
    }
    @discardableResult mutating func declare(_ raw: String, category: String, type: String, count: Int = 1) throws -> Bool {
        guard (1...4096).contains(count) else { throw ResourceError.rejected("array_element_count_limit") }
        guard !["list","theora"].contains(type) || count == 1 else { throw ResourceError.rejected("object_array_outside_profile") }
        guard raw.utf8.count <= 4096, Self.isDecimalDeclarationName(raw,category: category,type: type) || raw.range(of: #"^#?[\p{L}_][\p{L}\p{N}_]*$"#, options: .regularExpression) != nil
        else { throw ResourceError.rejected("non_scalar_declaration_name") }
        guard ["int","str","table","list","img","simg","theora","btn","sbtn","obj","msg"].contains(type) else { throw ResourceError.rejected("declaration_type_outside_profile") }
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
        } else if type == "table" || type == "img" || type == "simg" {
            // The simg constructor at 0x68db3a invokes the base image constructor.
            if type == "table" {
                guard count <= 512-tables.count-lists.count else { throw ResourceError.rejected("table_object_limit") }
            } else {
                guard count <= 128-images.count else { throw ResourceError.rejected("image_object_limit") }
            }
            elements = (0..<count).map { _ in
                let handle = nextObject
                nextObject += 1
                if type == "table" { tables[handle] = ScriptTable(allowWideKeys: true) }
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
            case "theora":
                guard movies.count < 32 else { throw ResourceError.rejected("movie_object_limit") }
                value = .object(nextObject); movies[nextObject] = MovieObject(); nextObject += 1
            case "list":
                guard tables.count+lists.count < 512 else { throw ResourceError.rejected("table_object_limit") }
                value = .object(nextObject); lists[nextObject] = ScriptStringList(); nextObject += 1
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
        return frames.last?.locals[key] != nil ? 3 : global[key] != nil ? 2 : (system[key] != nil || key == Self.cameraName || key == Self.replacementName || key == Self.inputName || key == Self.configName || key == Self.temporaryDataName || key == Self.saveDataName || key == Self.miscName || key == Self.dialogueLogName || key == Self.lineLogName || key == Self.fileLogName || key == Self.systemKeyName || key == Self.systemName || key == Self.skipLockName || key == Self.screenLockName || key == Self.soundEffectTypeName || key == Self.outQuartName || key == Self.effectName || key == Self.soundName) ? 1 : 0
    }
    mutating func deleteGlobalBinding(_ name: String) throws {
        let key = Data(asciiLower(name).utf8)
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
        guard handles.allSatisfy({ images[$0] != nil || movies[$0] != nil || buttons.contains($0) }) else {
            throw ResourceError.rejected("delete_object_type_outside_profile")
        }
        global.removeValue(forKey: key)
        for handle in handles {
            placementTransitions.removeValue(forKey: handle)
            images.removeValue(forKey: handle)
            movies.removeValue(forKey: handle)
            buttons.remove(handle)
            enabledButtons.remove(handle)
            buttonResources.removeValue(forKey: handle)
            buttonImages.removeValue(forKey: handle)
            buttonSounds.removeValue(forKey: handle)
            buttonMotion.removeValue(forKey: handle)
            buttonPlacement.removeValue(forKey: handle)
            buttonScale.removeValue(forKey: handle)
            buttonUserIntegers.removeValue(forKey: handle)
            buttonTextOutput.removeValue(forKey: handle)
            drawableRectangles.removeValue(forKey: handle)
            buttonTextBounds.removeValue(forKey: handle)
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

    mutating func setClickResultZero() throws {
        let key = Data("resultclkint".utf8)
        if let binding = global[key], binding.first.integer == nil {
            throw ResourceError.rejected("click_result_type_conflict")
        }
        if global[key] == nil { global[key] = ScriptBinding(elements: [.integer(0)]) }
        else { global[key]!.elements[0] = .integer(0) }
        try validate()
    }

    mutating func setButtonResults(handle: UInt64, label: String) throws {
        clearResultBindings()
        global[Data("resultobj".utf8)] = ScriptBinding(elements: [.object(handle)])
        try setConfigResultArray([.string(label),.string("")],string: true)
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
        guard dictionaries.reduce(0, { n, dict in n+dict.values.reduce(0, { $0+$1.elements.count }) }) <= 65_536
        else { throw ResourceError.rejected("array_total_element_limit") }
        let strings = dictionaries.reduce(0) { total, dict in
            total + dict.values.reduce(0) { n, b in n+b.elements.reduce(0) { count, v in
                if case .string(let s) = v { return count+s.utf8.count }; return count
            } }
        }
        guard strings <= 8*1024*1024 else { throw ResourceError.rejected("string_storage_limit") }
        let loaded = tables.values.compactMap(\.summary)
        guard loaded.reduce(0, { $0+$1.source.byteLength }) <= 8*1024*1024,
              loaded.reduce(0, { $0+$1.lines.count }) <= 50_000,
              tables.values.reduce(0, { $0+$1.storedBytes }) <= 16*1024*1024,
              tables.values.reduce(0, { $0+$1.count }) <= 100_000
        else { throw ResourceError.rejected("table_storage_budget") }
        let loadedLists = lists.values.compactMap(\.summary)
        guard loadedLists.reduce(0, { $0+$1.source.byteLength }) <= 8*1024*1024,
              lists.values.reduce(0, { $0+$1.lineCount }) <= 50_000,
              lists.values.reduce(0, { $0+$1.generatedBytes }) <= 8*1024*1024
        else { throw ResourceError.rejected("list_storage_budget") }
    }
}
