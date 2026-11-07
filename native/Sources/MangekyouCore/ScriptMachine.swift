import Foundation

public struct ScriptControlBlock: Sendable {
    let start: Int
    let end: Int
    let family: String
    let markers: [Int]
}

public struct ScriptProgram: Sendable {
    public let document: ScriptDocument
    let sources: [Data: ScriptSource]
    let includesExpanded: Bool
    let labels: [Data: [Int]]
    let blocks: [Int: ScriptControlBlock]
    let startsByEnd: [Int: Int]
    let startsByMarker: [Int: Int]
    let ancestors: [[Int]]

    public init(_ document: ScriptDocument) throws {
        try self.init(document,sources: [:],includesExpanded: false)
    }
    init(_ document: ScriptDocument, sources: [Data: ScriptSource], includesExpanded: Bool) throws {
        self.document = document
        var allSources = sources
        allSources[Data(document.source.relativePath.utf8)] = document.source
        self.sources = allSources; self.includesExpanded = includesExpanded
        var labels: [Data: [Int]] = [:], stack: [(start: Int, family: String, markers: [Int])] = []
        var blocks: [Int: ScriptControlBlock] = [:], ends: [Int: Int] = [:], markers: [Int: Int] = [:], ancestors: [[Int]] = []
        for (i,record) in document.records.enumerated() {
            ancestors.append(stack.map(\.start))
            if record.kind == .label, let name = record.identifier { labels[Data(asciiLower(name).utf8),default: []].append(i) }
            guard record.kind == .command, let command = record.command else { continue }
            let token = asciiLower(command)
            if ["if","for","case"].contains(token) {
                stack.append((i,token,[]))
                guard stack.count <= 64 else { throw ResourceError.rejected("control_nesting_limit") }
            } else if token == "end" {
                guard let block = stack.popLast() else { throw ResourceError.rejected("unmatched_control_end_at_byte_\(record.location.byteOffset)") }
                blocks[block.start] = ScriptControlBlock(start: block.start,end: i,family: block.family,markers: block.markers)
                ends[i] = block.start
            } else if ["brk", "cnt"].contains(token), let loop = stack.lastIndex(where: { $0.family == "for" }) {
                stack[loop].markers.append(i); markers[i] = stack[loop].start
            } else if ["then","else","of","ans","brk","cnt"].contains(token) {
                guard !stack.isEmpty else { throw ResourceError.rejected("unmatched_control_marker_at_byte_\(record.location.byteOffset)") }
                stack[stack.count-1].markers.append(i); markers[i] = stack.last!.start
            }
        }
        guard stack.isEmpty else { throw ResourceError.rejected("unterminated_control_block") }
        self.labels = labels; self.blocks = blocks; startsByEnd = ends; startsByMarker = markers; self.ancestors = ancestors
    }

    func label(_ raw: String) throws -> Int {
        guard raw.hasPrefix("@@"), !raw.hasPrefix("@@@"), raw.count > 2 else { throw ResourceError.rejected("dynamic_or_nonliteral_target") }
        let matches = labels[Data(asciiLower(String(raw.dropFirst(2))).utf8)] ?? []
        guard matches.count == 1 else { throw ResourceError.rejected(matches.isEmpty ? "unresolved_same_file_target" : "ambiguous_same_file_target") }
        return matches[0]
    }
}

public struct ScriptTrace: Encodable, Sendable {
    public let sequence: Int
    public let location: ScriptLocation
    public let recordType: ScriptRecordKind
    public let command: String?
    public let commandSHA256: String?
    public let status: EvidenceStatus
    public let action: String
    public let reason: String?
    public let target: ScriptLocation?
    public let callDepth: Int
    public let skipped: ScriptSkippedSpan?
    public let resultType: String?
    public let resource: ScriptLocation?
}

public struct ScriptSkippedSpan: Encodable, Sendable {
    public let status: EvidenceStatus = .notTested
    public let reason = "Not executed under the experimental branch model"
    public let location: ScriptLocation
    public let recordCount: Int
    public let recordTypes: [String: Int]
}

public enum ScriptMachinePhase: String, Encodable, Sendable { case ready, waiting, waitingForEvent, waitingForMedia, finished, stopped }

public struct ScriptMachineSummary: Encodable, Sendable {
    public let status: EvidenceStatus
    public let phase: ScriptMachinePhase
    public let profile = "experimental_static_contracts_v41"
    public let evidenceStatus: EvidenceStatus = .inferred
    public let originalEngineEquivalence: EvidenceStatus = .notTested
    public let scope = "Bounded arrays, table/list text, loops, format pairs and pinned includes; complete preprocessing, locale/media/saves not_tested"
    public let errorPolicy = "Atomic instruction commit and stop; original error rollback not_tested"
    public let scalarInitialization = "Candidate int-zero/string-empty/table/list initialization; no verified native ownership ABI"
    public let steps: Int
    public let currentLocation: ScriptLocation?
    public let stopReason: String?
    public let callDepth: Int
    public let variableCounts: [String: Int]
    public let moduleSnapshotCount: Int
    public let moduleSnapshotBytes: Int
    public let sourceSnapshotCount: Int
    public let tableObjectCount: Int
    public let tableEntryCount: Int
    public let tableSnapshots: [ScriptTableSummary]
    public let listObjectCount: Int
    public let listLineCount: Int
    public let listSnapshots: [ScriptStringListSummary]
    public let tableAuxiliaryResultFlags: EvidenceStatus = .notTested
    public let objectLifetime = "Bounded table/list handles retained until the run ends; original destruction and aliasing not_tested"
    public let inputSnapshotPolicy = "Pinned immutable snapshots within one run; identical source bytes may alias, differing variants require explicit selection"
    public let trace: [ScriptTrace]
}

/// Explicit opt-in required. Unknowns are terminal; they are never advanced past.
public struct ScriptMachine: Sendable {
    public private(set) var program: ScriptProgram
    public private(set) var phase: ScriptMachinePhase = .ready
    private let retainFullTrace: Bool
    private var executedSteps = 0
    public private(set) var traces: [ScriptTrace] = []
    public private(set) var lastResult: ScriptValue?
    public private(set) var stopReason: String?
    public private(set) var pc: Int
    private var storage = ScriptStorage()
    private var repository: ScriptRepository?
    public private(set) var pendingModuleCandidates: [ScriptModuleReference] = []
    public static let maximumSupportedSteps = 650_000
    private let maximumSteps: Int
    private let maximumFrames: Int
    public private(set) var clickWaitRemaining: Int32?
    private struct LogJumpCheckpoint: Sendable {
        let name: String
        let options: Int32
        let mode: Int32
        let storage: ScriptStorage
        let program: ScriptProgram
        let resumeIndex: Int
    }
    private var logJumpLimit = 16
    private var logJumpCheckpoints: [LogJumpCheckpoint] = []

    private var callbackElapsedTicks: Int32?
    private var pendingClick = false
    private var pendingButton: UInt64?
    private var pointerPosition: (x: Int32, y: Int32)?
    public private(set) var timedStopRequest: (duration: Int32, alternateDuration: Int32)?
    private var stopCallback: Int?
    private var stopCallbackFrameDepth: Int?

    /// Advance the headless placement clock to known endpoints.
    public mutating func advancePlacementClock(ticks: Int32) throws {
        guard ticks >= 0 else { throw ResourceError.rejected("negative_placement_ticks") }
        for (handle,var transition) in storage.placementTransitions {
            transition.elapsed += min(ticks,transition.duration-transition.elapsed)
            if transition.elapsed == transition.duration {
                if storage.buttons.contains(handle) {
                    storage.buttonPlacement[handle] = transition.destination
                } else {
                    storage.images[handle]?.placement = transition.destination
                }
                storage.placementTransitions.removeValue(forKey: handle)
            } else {
                storage.placementTransitions[handle] = transition
            }
        }
    }

    public var hasScopedStop: Bool {
        phase == .waitingForEvent && stopCallback != nil && stopCallbackFrameDepth == nil &&
            storage.frames.last?.controls.isEmpty == false
    }

    /// Consume queued message operations for headless execution.
    public mutating func commitHeadlessMessageOutput() throws -> Bool {
        guard hasScopedStop else { return false }
        var messages = storage.messages
        var committed = false
        for handle in messages.keys {
            guard var message = messages[handle], !message.pendingOutput.isEmpty else { continue }
            try message.commitOutput()
            messages[handle] = message
            committed = true
        }
        if committed { storage.messages = messages }
        return committed
    }

    /// Dispatch one event cycle while the script is suspended at stop.
    public mutating func dispatchStopCallback(pointer: (x: Int32, y: Int32)? = nil, buttonIndex: Int32? = nil, click: Bool = false, elapsedTicks: Int32 = 0) throws {
        guard phase == .waitingForEvent, let callback = stopCallback,
              stopCallbackFrameDepth == nil, storage.frames.count < maximumFrames, elapsedTicks >= 0 else {
            throw ResourceError.rejected("pending_stop_callback_required")
        }
        if let buttonIndex {
            guard case .object(let handle) = try storage.readIndexed("Button",buttonIndex),
                  storage.enabledButtons.contains(handle), storage.buttonLocks[handle,default: 0] == 0,
                  storage.buttonScriptTargets[handle] != nil else {
                throw ResourceError.rejected("stop_button_not_selectable")
            }
            pendingButton = handle
        }
        storage.frames.append(ScriptFrame(returnIndex: pc,returnProgram: program))
        callbackElapsedTicks = elapsedTicks
        pendingClick = click
        pointerPosition = pointer
        stopCallbackFrameDepth = storage.frames.count
        pc = callback
        phase = .ready
    }

    public struct MoviePlaybackRequest: Sendable {
        public let resource: ScriptLocation
        public let placement: [Int32]
        fileprivate let handle: UInt64
    }
    public private(set) var moviePlaybackRequest: MoviePlaybackRequest?

    public private(set) var soundPlaybackRequest: ScriptLocation?

    public mutating func acknowledgeSoundPlayback() throws {
        guard phase == .waitingForMedia, soundPlaybackRequest != nil else {
            throw ResourceError.rejected("pending_sound_required")
        }
        soundPlaybackRequest = nil
        phase = .ready
    }

    /// Resume after a host has started decoding and supplied the duration in engine ticks.
    public mutating func acknowledgeMoviePlayback(durationTicks: Int32) throws {
        guard phase == .waitingForMedia, let request = moviePlaybackRequest,
              storage.movies[request.handle]?.resource != nil, durationTicks > 0 else {
            throw ResourceError.rejected("pending_movie_and_positive_duration_required")
        }
        storage.movies[request.handle]!.durationTicks = durationTicks
        moviePlaybackRequest = nil
        phase = .ready
    }

    /// Advance the finite countdown using host-supplied engine ticks.
    public mutating func advanceClickWait(ticks: Int32) throws {
        guard phase == .waiting, let remaining = clickWaitRemaining, remaining >= 0, ticks >= 0 else {
            throw ResourceError.rejected("finite_click_wait_required")
        }
        if ticks >= remaining {
            clickWaitRemaining = nil
            phase = .ready
        } else {
            clickWaitRemaining = remaining-ticks
        }
    }
    public mutating func advanceTimedStop(ticks: Int32) throws {
        guard phase == .waitingForEvent, stopCallbackFrameDepth == nil,
              let request = timedStopRequest, ticks >= 0 else {
            throw ResourceError.rejected("timed_stop_wait_required")
        }
        // 0x6cad38 publishes the countdown and 0x6cad4e resumes at zero.
        let remaining = max(0, request.duration - ticks)
        storage.resultStopInt = remaining
        if remaining == 0 {
            timedStopRequest = nil
            stopCallback = nil
            phase = .ready
        } else {
            timedStopRequest = (remaining, request.alternateDuration)
        }
    }
    private let imageMemberLookup: (@Sendable (ScriptLocation, String) throws -> (offset: Int, length: Int, sha256: String)?)?
    private func motionIndex(_ name: String, in names: [String]) -> Int32 {
        let key = Data(asciiLower(name).utf8)
        return Int32(names.lastIndex { Data(asciiLower($0).utf8) == key } ?? -1)
    }

    private let imageMotionNames: (@Sendable (ScriptLocation) -> [String]?)?
    private let imageExtendedValues: (@Sendable (ScriptLocation) -> [Int: Int32]?)?
    private let imageLoader: (@Sendable (Data) throws -> (Int, Int, Int))?

    public init(program: ScriptProgram, allowExperimental: Bool, entryLabel: String? = nil,
                maximumSteps: Int = 10_000, maximumFrames: Int = 64, repository: ScriptRepository? = nil, configuration: ScriptTable? = nil,
                imageLoader: (@Sendable (Data) throws -> (Int, Int, Int))? = nil,
                imageMemberLookup: (@Sendable (ScriptLocation, String) throws -> (offset: Int, length: Int, sha256: String)?)? = nil,
                imageExtendedValues: (@Sendable (ScriptLocation) -> [Int: Int32]?)? = nil,
                imageMotionNames: (@Sendable (ScriptLocation) -> [String]?)? = nil, retainFullTrace: Bool = true) throws {
        guard allowExperimental else { throw ResourceError.rejected("experimental_execution_not_enabled") }
        guard (1...Self.maximumSupportedSteps).contains(maximumSteps), (1...64).contains(maximumFrames) else { throw ResourceError.rejected("machine_limits") }
        self.retainFullTrace = retainFullTrace
        self.maximumSteps = maximumSteps; self.maximumFrames = maximumFrames
        self.imageLoader = imageLoader
        self.imageMemberLookup = imageMemberLookup
        self.imageExtendedValues = imageExtendedValues
        self.imageMotionNames = imageMotionNames
        storage.configuration = configuration
        var pinnedRepository = repository
        let prepared = try pinnedRepository?.attachRoot(program) ?? program
        self.program = prepared; self.repository = pinnedRepository
        storage.frames[0].entryLabel = entryLabel
        pc = try entryLabel.map { try prepared.label($0) } ?? 0
        if pc < prepared.ancestors.count, !prepared.ancestors[pc].isEmpty { throw ResourceError.rejected("entry_inside_control_block") }
    }

    public func value(named name: String) throws -> ScriptValue { try storage.read(name) }
    public var summary: ScriptMachineSummary {
        let records = program.document.records
        return ScriptMachineSummary(status: phase == .stopped ? .unsupported : .inferred,phase: phase,
            steps: executedSteps,currentLocation: pc < records.count ? records[pc].location : nil,
            stopReason: stopReason,callDepth: storage.frames.count,
            variableCounts: ["system":storage.system.count,"global":storage.global.count,
                "all_local_frames":storage.frames.reduce(0) { $0+$1.locals.count }],
            moduleSnapshotCount: repository?.loadedModuleCount ?? 0,moduleSnapshotBytes: repository?.snapshotBytes ?? 0,
            sourceSnapshotCount: repository?.sourceSnapshotCount ?? 0,tableObjectCount: storage.tables.count,
            tableEntryCount: storage.tables.values.reduce(0) { $0+$1.count },
            tableSnapshots: storage.tables.keys.sorted().compactMap { storage.tables[$0]?.summary },
            listObjectCount: storage.lists.count,listLineCount: storage.lists.values.reduce(0) { $0+($1.summary?.lineCount ?? 0) },
            listSnapshots: storage.lists.keys.sorted().compactMap { storage.lists[$0]?.summary },trace: traces)
    }

    public mutating func run(stepQuota: Int = 10_000) throws {
        guard (1...Self.maximumSupportedSteps).contains(stepQuota) else { throw ResourceError.rejected("invalid_step_quota") }
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(30))
        for _ in 0..<stepQuota {
            if phase != .ready { return }
            if Task.isCancelled { stopReason = "machine_cancelled"; phase = .stopped; return }
            if clock.now >= deadline { stopReason = "machine_time_limit"; phase = .stopped; return }
            _ = step()
        }
    }

    @discardableResult public mutating func step() -> ScriptTrace? {
        guard phase == .ready else { return nil }
        let records = program.document.records
        guard pc < records.count else {
            if storage.frames.count > 1 { phase = .stopped; stopReason = "callee_reached_EOF_without_return" }
            else { phase = .finished }
            return nil
        }
        let record = records[pc], oldPC = pc
        let raw = record.command
        let safeCommand = raw.flatMap { $0.range(of: #"^[A-Za-z?][A-Za-z_0-9?]{0,15}$"#, options: .regularExpression) == nil ? nil : $0 }
        func trace(_ status: EvidenceStatus, _ action: String, reason: String? = nil,
                   target: ScriptLocation? = nil, skipped: ScriptSkippedSpan? = nil, resultType: String? = nil,
                   resource: ScriptLocation? = nil) -> ScriptTrace {
            ScriptTrace(sequence: executedSteps+1,location: record.location,recordType: record.kind,command: safeCommand,
                commandSHA256: raw.map { Data($0.utf8).sha256Hex },status: status,action: action,reason: reason,
                target: target,callDepth: storage.frames.count,skipped: skipped,resultType: resultType,resource: resource)
        }
        guard executedSteps < maximumSteps else { stopReason = "machine_total_step_limit"; phase = .stopped; return nil }
        var candidate = storage, nextProgram = program, next = pc+1, target: ScriptLocation?, skip: ScriptSkippedSpan?, result: ScriptValue?
        var candidateRepository = repository, resourceLocation: ScriptLocation?
        pendingModuleCandidates = []
        var action = "advance"
        func field(_ index: Int) throws -> String {
            guard index < record.fields.count, record.fields[index].key == nil else { throw ResourceError.rejected("missing_or_named_operand_outside_profile") }
            return record.fields[index].raw
        }
        func arity(_ count: Int) throws {
            guard record.fields.count == count else { throw ResourceError.rejected("unsupported_command_arity") }
        }
        func callLabel(_ slot: Int = 0) throws -> String {
            let raw = try field(slot)
            if raw.hasPrefix("@@") { return raw }
            let value = try ScriptExpression.parse(raw).evaluate(read: { try candidate.read($0) },
                write: { _,_ in throw ResourceError.rejected("mutating_label_operand_outside_profile") },
                readIndexed: { try candidate.readIndexed($0,$1) })
            guard case .string(let label) = value, label.utf8.count <= 4096 else {
                throw ResourceError.rejected("dynamic_label_requires_bounded_string")
            }
            return label
        }
        func skipped(_ range: Range<Int>) throws -> ScriptSkippedSpan? {
            guard !range.isEmpty else { return nil }
            let slice = records[range]
            let start = slice.first!.location.byteOffset, end = slice.last!.location.byteOffset + slice.last!.location.byteLength
            var kinds: [String: Int] = [:]
            for r in slice { kinds[r.kind.rawValue,default: 0] += 1 }
            let file = Data(slice.first!.location.sourceFile.utf8)
            guard let source = program.sources[file], slice.allSatisfy({ Data($0.location.sourceFile.utf8) == file })
            else { throw ResourceError.rejected("cross_source_skip_outside_profile") }
            var previous = start
            for record in slice {
                guard record.location.byteOffset >= previous else { throw ResourceError.rejected("repeated_source_skip_outside_profile") }
                previous = record.location.byteOffset+record.location.byteLength
            }
            return ScriptSkippedSpan(location: source.location(start..<end,line: slice.first!.location.lineNumber),
                recordCount: slice.count,recordTypes: kinds)
        }
        do {
            switch record.kind {
            case .bom, .layout, .label, .comment: break
            case .include:
                guard program.includesExpanded else { throw ResourceError.rejected("include_preprocessing_required") }
                action = "include_expansion_marker"
            case .empty:
                guard let prefix = candidate.noWordLineText, !prefix.isEmpty,
                      case .integer(1) = try? candidate.read("Imo_SentenceFlag") else { break }
                // 0x6963fa tests for an empty line after preprocessing.
                // A pending sentence can end with a caret directive as well as text.
                guard let previous = records[..<pc].last(where: { $0.kind != .layout }),
                      previous.kind == .text || previous.kind == .sound || previous.kind == .lineTag else { break }
                let fields = prefix.split(separator: ",", omittingEmptySubsequences: false)
                guard fields.count == 2, fields[0] == "\\subp" else {
                    throw ResourceError.rejected("blank_line_prefix_outside_profile")
                }
                let label = String(fields[1])
                // The handler runs its own script before clearing the pending flag.
                guard !candidate.frames.contains(where: { $0.entryLabel == label }) else { break }
                let destination = try program.label(label)
                guard program.ancestors[destination].isEmpty, candidate.frames.count < maximumFrames else {
                    throw ResourceError.rejected("blank_line_prefix_call_boundary")
                }
                candidate.frames.append(ScriptFrame(returnIndex: pc+1, returnProgram: program, entryLabel: label))
                next = destination
                action = "blank_line_prefix_call_candidate"
            case .text, .sound:
                guard let prefix = candidate.exceptTextPrefix else {
                    throw ResourceError.rejected("unsupported_record_\(record.kind.rawValue)")
                }
                let fields = prefix.split(separator: ",", omittingEmptySubsequences: false)
                guard fields.count == 4, fields[0] == "\\subp", fields[2].isEmpty, fields[3].isEmpty,
                      let source = program.sources[Data(record.location.sourceFile.utf8)] else {
                    throw ResourceError.rejected("text_prefix_outside_profile")
                }
                let start = record.location.byteOffset
                let end = start + record.location.byteLength
                var lower = 0, upper = source.scalars.count
                while lower < upper {
                    let middle = lower + (upper - lower) / 2
                    if source.scalars[middle].bytes.lowerBound < start { lower = middle + 1 }
                    else { upper = middle }
                }
                let first = lower
                while lower < source.scalars.count, source.scalars[lower].bytes.lowerBound < end { lower += 1 }
                let text = source.string(first..<lower)
                let label = String(fields[1])
                let destination = try program.label(label)
                guard text.utf8.count <= 8192, program.ancestors[destination].isEmpty,
                      candidate.frames.count < maximumFrames else {
                    throw ResourceError.rejected("text_prefix_call_boundary")
                }
                candidate.frames.append(ScriptFrame(returnIndex: pc+1, returnProgram: program, entryLabel: label,
                    parameterCount: 1, integerParameters: [ScriptExpression.integerTextCache(text) ?? 0] + Array(repeating: 0, count: 15),
                    stringParameters: [text] + Array(repeating: "", count: 15)))
                next = destination
                action = "text_prefix_call_candidate"
            case .lineTag:
                guard let raw, record.fields.count <= 16,
                      let rule = candidate.replacementRules[Data(asciiLower("^" + raw).utf8)] else {
                    throw ResourceError.rejected("unsupported_record_line_tag")
                }
                // The AVG reader registers caret prefixes through rep. Execute
                // the registered local sub expansion at its source position.
                let fields = rule.value.split(separator: ",", omittingEmptySubsequences: false)
                let packed = fields.count >= 3 && fields[0] == "\\subp" && fields[2].isEmpty
                guard packed || ((2...3).contains(fields.count) && fields[0] == "\\sub" &&
                    ((fields.count == 3 && fields[2].isEmpty) || record.fields.isEmpty)) else {
                    throw ResourceError.rejected("line_tag_replacement_outside_profile")
                }
                let destination = try program.label(String(fields[1]))
                guard program.ancestors[destination].isEmpty else {
                    throw ResourceError.rejected("call_target_inside_control_block")
                }
                guard candidate.frames.count < maximumFrames else {
                    throw ResourceError.rejected("call_frame_limit")
                }
                var strings = Array(repeating: "", count: 16)
                var integers = Array(repeating: Int32(0), count: 16)
                let arguments: [String]
                if packed {
                    var tail = fields.dropFirst(3).map(String.init) + record.fields.map(\.raw)
                    while tail.last == "" { tail.removeLast() }
                    arguments = tail.isEmpty ? [] : [tail.joined(separator: ",")]
                } else {
                    guard record.fields.allSatisfy({ $0.key == nil }) else {
                        throw ResourceError.rejected("line_tag_argument_outside_profile")
                    }
                    arguments = record.fields.map(\.value)
                }
                for (slot, text) in arguments.enumerated() {
                    guard text.utf8.count <= 8192 else {
                        throw ResourceError.rejected("line_tag_argument_outside_profile")
                    }
                    strings[slot] = text
                    integers[slot] = ScriptExpression.integerTextCache(text) ?? 0
                }
                candidate.frames.append(ScriptFrame(returnIndex: pc+1, returnProgram: program, entryLabel: String(fields[1]),
                    parameterCount: Int32(arguments.count), integerParameters: integers, stringParameters: strings))
                next = destination
                action = "line_tag_replacement_call_candidate"
            case .command:
                guard let raw, safeCommand != nil else { throw ResourceError.rejected("invalid_command_identifier") }
                let command = asciiLower(raw)
                switch command {
                case "exop":
                    try arity(1)
                    let text = try callLabel()
                    let document = try ScriptDocument(data: Data([0xff, 0xfe]) + Data(text.utf16.flatMap {
                        [UInt8(truncatingIfNeeded: $0), UInt8($0 >> 8)]
                    }), relativePath: record.location.sourceFile)
                    let commands = document.records.filter { $0.kind != .bom && $0.kind != .layout }
                    guard commands.count == 1, let operation = commands.first, operation.kind == .command,
                          let opcode = operation.command.map(asciiLower), opcode == "sub" || opcode == "subp",
                          (1...18).contains(operation.fields.count) else {
                        throw ResourceError.rejected("dynamic_operation_outside_profile")
                    }
                    if operation.fields.count >= 2 {
                        let module = operation.fields[1].raw
                        guard module.isEmpty || asciiLower(module) == "self" else {
                            throw ResourceError.rejected("dynamic_operation_module_outside_profile")
                        }
                    }
                    let label = operation.fields[0].raw
                    let destination = try program.label(label)
                    guard program.ancestors[destination].isEmpty, candidate.frames.count < maximumFrames else {
                        throw ResourceError.rejected("dynamic_operation_call_boundary")
                    }
                    // 0x6b1142 feeds the evaluated string to the command executor.
                    // Preserve the include-template argument spelling in the local call.
                    var strings = Array(repeating: "", count: 16)
                    var integers = Array(repeating: Int32(0), count: 16)
                    var arguments = operation.fields.dropFirst(2).map(\.raw)
                    if opcode == "subp" {
                        // The original subp handler packs the tail into the first argument.
                        while arguments.last == "" { arguments.removeLast() }
                        if !arguments.isEmpty { arguments = [arguments.joined(separator: ",")] }
                    }
                    for (slot, argument) in arguments.enumerated() {
                        strings[slot] = argument
                        integers[slot] = ScriptExpression.integerTextCache(argument) ?? 0
                    }
                    candidate.frames.append(ScriptFrame(returnIndex: pc+1, returnProgram: program, entryLabel: label,
                        parameterCount: Int32(arguments.count),
                        integerParameters: integers, stringParameters: strings))
                    next = destination
                    action = "dynamic_local_call_candidate"
                case "init":
                    guard (1...128).contains(record.fields.count) else {
                        throw ResourceError.rejected("init_field_count_limit")
                    }
                    // 0x6af7ea resolves each named binding through 0x69efdc.
                    for slot in record.fields.indices {
                        guard case .name(let name) = try ScriptExpression.parse(field(slot)) else {
                            throw ResourceError.rejected("init_requires_named_binding")
                        }
                        try candidate.resetIntegerBinding(name)
                    }
                    action = "integer_binding_reset_candidate"
                case "var", "gvar", "svar":
                    guard (2...129).contains(record.fields.count) else { throw ResourceError.rejected("declaration_field_count_limit") }
                    let type = asciiLower(try field(0))
                    var created = 0
                    for slot in 1..<record.fields.count {
                        let spelling = try field(slot)
                        // 0x6b1b91 passes declaration fields as names, before
                        // the name/index parser at 0x69fb64.
                        if ScriptStorage.isDecimalDeclarationName(spelling,category: command,type: type) {
                            if try candidate.declare(spelling,category: command,type: type) { created += 1 }
                            continue
                        }
                        let declaration = try ScriptExpression.parse(spelling), name: String, count: Int
                        switch declaration {
                        case .name(let raw): name = raw; count = 1
                        case .indexed(let raw, let coordinate):
                            guard ["int","str","btn","sbtn","table","img","simg","obj","msg"].contains(type) else { throw ResourceError.rejected("object_array_outside_profile") }
                            let value = try coordinate.evaluate(read: { try candidate.read($0) },write: { _,_ in
                                throw ResourceError.rejected("mutating_array_dimension_outside_profile")
                            },readIndexed: { try candidate.readIndexed($0,$1) })
                            guard let integer = value.integer else { throw ResourceError.rejected("array_dimension_requires_integer") }
                            name = raw; count = max(1,Int(integer))
                        default: throw ResourceError.rejected("non_scalar_declaration_name")
                        }
                        if try candidate.declare(name,category: command,type: type,count: count) { created += 1 }
                    }
                    action = created == 0 ? "preserve_existing_declaration_candidate" : "declare_\(type)_candidate"
                case "scp":
                    guard record.fields.count <= 16 else { throw ResourceError.rejected("object_scope_slot_limit") }
                    if !record.fields.isEmpty, record.fields.allSatisfy({ $0.key == nil && $0.raw.isEmpty }) {
                        candidate.frames[candidate.frames.count-1].tableScope = []
                        action = "clear_empty_scope_candidate"; break
                    }
                    var handles: [UInt64] = [], sawEmpty = false
                    for i in record.fields.indices {
                        let raw = try field(i)
                        if raw.isEmpty { sawEmpty = true; continue }
                        guard !sawEmpty else { throw ResourceError.rejected("scope_gap_before_nonempty_selector_unverified") }
                        let value = try ScriptExpression.parse(raw).evaluate(read: { try candidate.read($0) },write: { _,_ in
                            throw ResourceError.rejected("mutating_object_selector_outside_profile")
                        },readIndexed: { try candidate.readIndexed($0,$1) })
                        guard case .object(let handle) = value, handle == ScriptStorage.configHandle || handle == ScriptStorage.saveDataHandle || handle == ScriptStorage.temporaryDataHandle || handle == ScriptStorage.systemKeyHandle || handle == ScriptStorage.fileLogHandle || handle == ScriptStorage.lineLogHandle || handle == ScriptStorage.dialogueLogHandle || handle == ScriptStorage.miscHandle || handle == ScriptStorage.systemHandle || handle == ScriptStorage.effectHandle || ScriptStorage.isStreamHandle(handle) || handle == ScriptStorage.inputHandle || handle == ScriptStorage.replacementHandle || handle == ScriptStorage.cameraHandle || candidate.tables[handle] != nil || candidate.lists[handle] != nil || candidate.images[handle] != nil || candidate.movies[handle] != nil || candidate.buttons.contains(handle) || candidate.messages[handle] != nil
                        else { throw ResourceError.rejected("non_table_or_string_scope_selector_unverified") }
                        handles.append(handle)
                    }
                    candidate.frames[candidate.frames.count-1].tableScope = handles
                    action = sawEmpty ? "select_scope_empty_suffix_candidate" : "select_table_scope_candidate"
                case "col":
                    let scope = candidate.frames.last!.tableScope
                    guard scope.count == 1, let handle = scope.first else {
                        throw ResourceError.rejected("color_requires_single_scope")
                    }
                    let camera = handle == ScriptStorage.cameraHandle && candidate.cameraInitialized
                    guard camera ? (3...4).contains(record.fields.count) :
                        candidate.images[handle] != nil && (4...5).contains(record.fields.count) else {
                        throw ResourceError.rejected("color_scope_or_arity_outside_profile")
                    }
                    let values = try record.fields.indices.map { slot in
                        let value = try ScriptExpression.parse(field(slot)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_camera_operand") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard let integer = value.integer else { throw ResourceError.rejected("camera_color_requires_integer") }
                        return integer
                    }
                    if camera {
                        // 0x6b9975 forwards four integers to the camera color component.
                        candidate.cameraColorRequest = (values[0],values[1],values[2],values.count == 4 ? values[3] : 0)
                        action = "camera_color_request_candidate"
                    } else {
                        // 0x6c6d98 forwards the five image operands to 0x5acb8c.
                        // The fifth slot is evaluated through 0x6be1d8 even when omitted.
                        let loop: Int32 = values.count == 5 ? values[4] : 0
                        candidate.images[handle]?.colorRequest = (values[0],values[1],values[2],values[3],loop)
                        action = "image_color_request_candidate"
                    }
                case "pri":
                    try arity(2)
                    guard candidate.frames.last!.tableScope == [ScriptStorage.cameraHandle],
                          candidate.cameraInitialized else {
                        throw ResourceError.rejected("camera_priority_requires_initialized_scope")
                    }
                    let priorities = try record.fields.indices.map { slot in
                        let value = try ScriptExpression.parse(field(slot)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_camera_operand") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard let integer = value.integer else { throw ResourceError.rejected("camera_priority_requires_integer") }
                        return integer
                    }
                    // 0x68243c keeps the previous values if the range is reversed.
                    if priorities[0] <= priorities[1] {
                        candidate.cameraPriorities = (priorities[0],priorities[1])
                    }
                    action = "camera_priority_candidate"
                case "?e":
                    try arity(0)
                    guard candidate.frames.last!.tableScope.count == 1,
                          let handle = candidate.frames.last!.tableScope.first,
                          let image = candidate.images[handle] else {
                        throw ResourceError.rejected("image_enable_query_requires_image_scope")
                    }
                    // 0x6c7aba reads the enable byte via 0x5ad0dc.
                    candidate.clearResultBindings()
                    try candidate.resultInteger(image.enabled ? 1 : 0)
                    action = "image_enable_query_candidate"
                case "?dc":
                    try arity(0)
                    guard candidate.frames.last!.tableScope.count == 1,
                          let handle = candidate.frames.last!.tableScope.first,
                          let channel = candidate.images[handle]?.drawChannel else {
                        throw ResourceError.rejected("image_draw_channel_unavailable")
                    }
                    candidate.clearResultBindings()
                    try candidate.resultInteger(channel)
                    action = "image_draw_channel_query_candidate"
                case "ds":
                    try arity(4)
                    let scope = candidate.frames.last!.tableScope
                    guard scope.count == 1, let handle = scope.first,
                          candidate.images[handle] != nil || candidate.buttons.contains(handle) else {
                        throw ResourceError.rejected("drawable_rectangle_requires_drawable_scope")
                    }
                    // 0x6c766a forwards four operands to 0x5ae1c8, which stores them verbatim.
                    candidate.drawableRectangles[handle] = try record.fields.indices.map { slot in
                        let value = try ScriptExpression.parse(field(slot)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_drawable_rectangle_operand") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard let integer = value.integer else {
                            throw ResourceError.rejected("drawable_rectangle_requires_integer")
                        }
                        return integer
                    }
                    action = "drawable_rectangle_candidate"
                case "ts", "tmg":
                    let scope = candidate.frames.last!.tableScope
                    guard scope.count == 1, let handle = scope.first else {
                        throw ResourceError.rejected("message_geometry_requires_message_scope")
                    }
                    let button = command == "ts" && candidate.buttonResources[handle] != nil
                    guard button || candidate.messages[handle] != nil else {
                        throw ResourceError.rejected("message_geometry_requires_message_scope")
                    }
                    try arity(command == "ts" && !button ? 4 : 2)
                    let values: [Int32] = try record.fields.indices.map { slot in
                        let value = try ScriptExpression.parse(field(slot)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_message_operand_outside_profile") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard let integer = value.integer else {
                            throw ResourceError.rejected("message_geometry_requires_integer")
                        }
                        return integer
                    }
                    if button {
                        // The missing third slot at 0x6c9209 selects the
                        // zero-origin form with two far endpoints.
                        candidate.buttonTextBounds[handle] = [
                            min(0, values[0]), min(0, values[1]),
                            min(4096, max(0, values[0])), min(4096, max(0, values[1]))
                        ]
                        action = "button_text_bounds_candidate"
                        break
                    }
                    var message = candidate.messages[handle]!
                    if command == "ts" {
                        // 0x67bbb0 orders each pair of endpoints, caps the
                        // far endpoints, and clears the resized text surface.
                        let bounds = [min(values[0], values[2]), min(values[1], values[3]),
                                      min(4096, max(values[0], values[2])),
                                      min(4096, max(values[1], values[3]))]
                        if bounds != message.textBounds {
                            message.pendingOutput.removeAll()
                            message.committedOutput.removeAll()
                        }
                        message.textBounds = bounds
                        action = "message_text_bounds_candidate"
                    } else {
                        // 0x67bccc writes both margins and forces the surface refresh.
                        message.textMargins = values
                        message.pendingOutput.removeAll()
                        message.committedOutput.removeAll()
                        action = "message_text_margins_candidate"
                    }
                    candidate.messages[handle] = message
                case "?tp":
                    try arity(0)
                    let scope = candidate.frames.last!.tableScope
                    guard scope.count == 1, let handle = scope.first, let message = candidate.messages[handle] else {
                        throw ResourceError.rejected("message_text_position_requires_message_scope")
                    }
                    // 0x6c9478 and 0x6c9490 read the renderer's text pen.
                    candidate.clearResultBindings()
                    try candidate.setConfigResultArray(message.headlessTextPosition.map(ScriptValue.integer), string: false)
                    action = "message_text_position_estimate_candidate"
                case "?tmg":
                    try arity(0)
                    let scope = candidate.frames.last!.tableScope
                    guard scope.count == 1, let handle = scope.first,
                          let margins = candidate.messages[handle]?.textMargins else {
                        throw ResourceError.rejected("message_margin_query_requires_configured_margins")
                    }
                    candidate.clearResultBindings()
                    try candidate.setConfigResultArray(margins.map(ScriptValue.integer), string: false)
                    action = "message_text_margin_query_candidate"
                case "nsw", "kwl", "kwb", "kwe", "ns":
                    try arity(command == "ns" ? 2 : 1)
                    let scope = candidate.frames.last!.tableScope
                    guard scope.count == 1, let handle = scope.first, var message = candidate.messages[handle] else {
                        throw ResourceError.rejected("message_layout_requires_message_scope")
                    }
                    func layoutOperand(_ slot: Int) throws -> ScriptValue {
                        try ScriptExpression.parse(field(slot)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_message_operand_outside_profile") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                    }
                    let value = try layoutOperand(0)
                    switch command {
                    case "nsw", "kwb", "kwe":
                        let string: String
                        switch value {
                        case .string(let text) where text.utf8.count <= 8192:
                            string = text
                        case .integer(0) where try command == "kwe" && field(0) == "0":
                            // 0x69b058 retains the numeric literal spelling in +8;
                            // 0x6c906a takes that string field for kwe.
                            string = "0"
                        default:
                            throw ResourceError.rejected("message_layout_requires_bounded_string")
                        }
                        // 0x6c9620, 0x6c8fd5, and 0x6c903c write distinct strings.
                        switch command {
                        case "nsw": message.ignoredReturnWords = string
                        case "kwb": message.prohibitedLineStart = string
                        default: message.prohibitedLineEnd = string
                        }
                    case "kwl":
                        guard let length = value.integer else {
                            throw ResourceError.rejected("message_layout_requires_integer")
                        }
                        message.kinsokuWordLength = length // 0x6c90a3
                    default:
                        let spacing = try layoutOperand(1)
                        let second: Int32?
                        switch spacing {
                        case .string(let text): second = ScriptExpression.integerTextCache(text)
                        default: second = spacing.integer
                        }
                        // 0x6c96a5 and 0x6c96cb read the evaluated numeric slots.
                        guard let first = value.integer, let second else {
                            throw ResourceError.rejected("message_layout_requires_integer")
                        }
                        message.returnSpacing = (first, second) // 0x6791c4
                    }
                    candidate.messages[handle] = message
                    action = "message_\(command)_layout_candidate"
                case "ap", "as":
                    try arity(1)
                    let scope = candidate.frames.last!.tableScope
                    let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                        write: { _,_ in throw ResourceError.rejected("mutating_message_operand_outside_profile") },
                        readIndexed: { try candidate.readIndexed($0,$1) })
                    guard let integer = value.integer else {
                        throw ResourceError.rejected("message_flag_requires_integer")
                    }
                    if command == "ap", scope == [ScriptStorage.systemHandle] {
                        // 0x6b24f4 stores the complete integer in the system slot.
                        candidate.systemAutoPlayValue = integer
                        action = "system_ap_write_candidate"
                        break
                    }
                    guard scope.count == 1, let handle = scope.first, var message = candidate.messages[handle] else {
                        throw ResourceError.rejected("message_flag_requires_message_scope")
                    }
                    // 0x6c8e19 and 0x6c8e8c compare the operand to exactly one.
                    if command == "ap" { message.apEnabled = integer == 1 }
                    else { message.asEnabled = integer == 1 }
                    candidate.messages[handle] = message
                    action = "message_\(command)_flag_candidate"
                case "cc":
                    try arity(0)
                    let scope = candidate.frames.last!.tableScope
                    guard scope.count == 1, let handle = scope.first, var message = candidate.messages[handle] else {
                        throw ResourceError.rejected("message_clear_requires_message_scope")
                    }
                    // 0x6c8f64 calls 0x6787b0, which drains output and clears
                    // the message surface and transient text. The CLI only queues
                    // output without rendering glyphs.
                    message.pendingOutput.removeAll()
                    message.committedOutput.removeAll()
                    candidate.messages[handle] = message
                    action = "message_clear_directive_buffer_candidate"
                case "?mc":
                    try arity(0)
                    let scope = candidate.frames.last!.tableScope
                    guard scope.count == 1, let handle = scope.first, let message = candidate.messages[handle] else {
                        throw ResourceError.rejected("message_completion_requires_message_scope")
                    }
                    // The original query masks the message status byte at 0x6c956a.
                    // The headless model tracks idle versus queued output.
                    candidate.clearResultBindings()
                    try candidate.resultInteger(message.pendingOutput.isEmpty ? 0 : 1)
                    action = "message_output_status_candidate"
                case "mc":
                    try arity(0)
                    let scope = candidate.frames.last!.tableScope
                    guard scope.count == 1, let handle = scope.first, var message = candidate.messages[handle] else {
                        throw ResourceError.rejected("message_flush_requires_message_scope")
                    }
                    // 0x6c954b calls 0x678b00, which drains the pending queue.
                    // Keep the committed operations available for the rendering host.
                    try message.commitOutput()
                    candidate.messages[handle] = message
                    action = "message_flush_output_candidate"
                case "o":
                    try arity(1)
                    let scope = candidate.frames.last!.tableScope
                    guard scope.count == 1, let handle = scope.first, candidate.messages[handle] != nil || candidate.buttonTextBounds[handle] != nil else {
                        throw ResourceError.rejected("message_output_requires_message_scope")
                    }
                    let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                        write: { _,_ in throw ResourceError.rejected("mutating_message_operand_outside_profile") },
                        readIndexed: { try candidate.readIndexed($0,$1) })
                    guard case .string(let text) = value, !text.isEmpty, text.utf8.count <= 8192 else {
                        throw ResourceError.rejected("message_output_requires_bounded_directive_string")
                    }
                    // 0x6c9778 forwards the string to 0x6782a8. The renderer at
                    // 0x6794ee distinguishes text from bracketed directives.
                    // Queue the supported text and directives for the future host.
                    var remaining = text[...]
                    var output: [ScriptStorage.MessageObject.Output] = []
                    let arities = ["n": 0, "f": 1, "rf": 1, "s": 2, "c": 1, "rc": 1, "pi": 2, "rs": 2, "rpi": 2, "rp": 2]
                    while !remaining.isEmpty {
                        guard output.count < 128 else {
                            throw ResourceError.rejected("message_pending_output_limit")
                        }
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
                        guard let name = fields.first, let arity = arities[String(name)],
                              fields.count == arity + 1 else {
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
                    // Preserve each output batch in script order for headless replay.
                    // The original renderer drains output at 0x6789e8.
                    if candidate.messages[handle] == nil {
                        guard output.count <= 128 - (candidate.buttonTextOutput[handle]?.count ?? 0) else {
                            throw ResourceError.rejected("message_pending_output_limit")
                        }
                        candidate.buttonTextOutput[handle,default: []].append(contentsOf: output)
                        action = "button_queue_output_candidate"
                        break
                    }
                    var message = candidate.messages[handle]!
                    guard output.count <= 128 - message.pendingOutput.count else {
                        throw ResourceError.rejected("message_pending_directive_limit")
                    }
                    message.pendingOutput.append(contentsOf: output)
                    candidate.messages[handle] = message
                    action = "message_queue_output_candidate"
                case "dc", "bg", "in", "out", "ps":
                    try arity(1)
                    let scope = candidate.frames.last!.tableScope
                    let imageHandle = scope.count == 1 ? scope.first : nil
                    let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                        write: { _,_ in throw ResourceError.rejected("mutating_effect_operand_outside_profile") },
                        readIndexed: { try candidate.readIndexed($0,$1) })
                    if (command == "in" || command == "out"), let handle = imageHandle,
                       candidate.buttons.contains(handle) {
                        guard let mask = value.integer else {
                            throw ResourceError.rejected("button_mask_requires_integer")
                        }
                        // The shared drawable handler writes +0xbf5 / +0xbf9.
                        if command == "in" { candidate.buttonInputMasks[handle] = mask }
                        else { candidate.buttonOutputMasks[handle] = mask }
                        action = "button_\(command)_mask_candidate"
                        break
                    }
                    if ["dc", "in", "out"].contains(command), let handle = imageHandle,
                       var message = candidate.messages[handle] {
                        guard let integer = value.integer else {
                            throw ResourceError.rejected("message_setting_requires_integer")
                        }
                        switch command {
                        case "dc":
                            // 0x6cba9d validates the channel; 0x67ea0c forwards it to all three image components.
                            guard (0...3).contains(integer) else {
                                throw ResourceError.rejected("message_draw_channel_outside_profile")
                            }
                            message.drawChannel = integer
                        case "in": message.inputMask = integer // 0x67ed6c
                        default: message.outputMask = integer // 0x67ed98
                        }
                        candidate.messages[handle] = message
                        action = "message_\(command)_setting_candidate"
                        break
                    }
                    if command != "bg", let handle = imageHandle, var image = candidate.images[handle] {
                        guard let integer = value.integer else {
                            throw ResourceError.rejected("image_setting_requires_integer")
                        }
                        switch command {
                        case "dc":
                            // 0x5acf1c stores the channel in the image and its component.
                            guard (0...3).contains(integer) else { throw ResourceError.rejected("image_draw_channel_outside_profile") }
                            image.drawChannel = integer
                        case "ps": image.playbackSpeed = integer
                        case "in": image.inputMask = integer
                        default: image.outputMask = integer
                        }
                        candidate.images[handle] = image
                        action = "image_\(command)_setting_candidate"
                        break
                    }
                    guard scope == [ScriptStorage.effectHandle], command == "dc" || command == "bg" else {
                        throw ResourceError.rejected("effect_or_image_scope_required")
                    }
                    if command == "bg" {
                        guard let color = value.integer else { throw ResourceError.rejected("effect_background_requires_integer") }
                        // 0x693a20 forces opaque alpha before storing the color.
                        candidate.effectBackgroundColor = UInt32(bitPattern: color) | 0xff00_0000
                        action = "effect_background_candidate"
                        break
                    }
                    // 0x6b62dd calls the byte setter at 0x693c3c.
                    guard value.integer == 3 else { throw ResourceError.rejected("effect_dc_index_outside_profile") }
                    candidate.effectField5F = 3
                    action = "effect_dc_field_write_candidate"
                case "fdi", "fdm", "fdp":
                    if command != "fdi" || !(4...5).contains(record.fields.count) { try arity(command == "fdp" ? 5 : 2) }
                    guard candidate.frames.last!.tableScope == [ScriptStorage.effectHandle] else {
                        throw ResourceError.rejected("effect_scope_required")
                    }
                    func integerOperand(_ slot: Int) throws -> Int32 {
                        let value = try ScriptExpression.parse(field(slot)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_effect_operand_outside_profile") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard let integer = value.integer else { throw ResourceError.rejected("fade_operand_requires_integer") }
                        return integer
                    }
                    if command == "fdp" {
                        // 0x6b5f81 reads five transform operands.
                        candidate.fadeTransform = try record.fields.indices.map(integerOperand)
                        action = "effect_fade_transform_candidate"
                        break
                    }
                    let mode = try integerOperand(0), duration = try integerOperand(1)
                    if command == "fdm" {
                        // 0x6b5b39 passes the low mode byte and full power word.
                        candidate.fadeTiming = (UInt8(truncatingIfNeeded: mode), duration)
                        action = "effect_fade_timing_candidate"
                        break
                    }
                    guard mode == 0, (0...60_000).contains(duration) else {
                        throw ResourceError.rejected("fade_in_mode_or_duration_outside_profile")
                    }
                    candidate.fadeInRule = nil
                    if record.fields.count >= 4 {
                        let path = try callLabel(2)
                        if !path.isEmpty {
                            guard record.fields.count == 5, candidateRepository != nil, let imageLoader else {
                                throw ResourceError.rejected("fade_in_resource_outside_profile")
                            }
                            let logical = try candidateRepository!.catalog.resourcePath(path,currentSourceFile: record.location.sourceFile)
                            let (reference, data) = try candidateRepository!.readResource(logical)
                            _ = try imageLoader(data)
                            let location = ScriptLocation(sourceFile: reference.sourceFile,sourceSHA256: reference.sourceSHA256,
                                byteOffset: 0,byteLength: data.count,rangeSHA256: data.sha256Hex,lineNumber: 1)
                            resourceLocation = location
                            candidate.fadeInRule = (location,try integerOperand(4))
                        }
                        candidate.fadeInPriority = try integerOperand(3)
                    } else {
                        candidate.fadeInPriority = nil
                    }
                    candidate.fadeInDuration = duration
                    action = "effect_fade_in_request_candidate"
                case "c":
                    guard record.fields.count <= 1,
                          candidate.frames.last!.tableScope == [ScriptStorage.effectHandle] else {
                        throw ResourceError.rejected("effect_capture_scope_or_arity")
                    }
                    // 0x6b60b5 defaults the priority to 60000, then 0x693704
                    // uses it for capture and records it in the effect object.
                    var priority: Int32 = 60_000
                    if !record.fields.isEmpty, try !field(0).isEmpty {
                        let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_effect_operand_outside_profile") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard let integer = value.integer else {
                            throw ResourceError.rejected("effect_capture_requires_integer_priority")
                        }
                        priority = integer
                    }
                    // The native capture helper preserves an existing capture.
                    if candidate.effectCapturePriority == nil || candidate.fadeInDuration != nil {
                        candidate.effectCapturePriority = priority
                        candidate.fadeInDuration = nil
                        candidate.fadeInPriority = nil
                        candidate.fadeInRule = nil
                    }
                    candidate.effectFillColor = 0xff00_0000
                    action = record.fields.isEmpty ? "effect_black_fill_candidate" : "effect_capture_request_candidate"
                case "del":
                    guard (1...32).contains(record.fields.count) else {
                        throw ResourceError.rejected("delete_operand_count_outside_profile")
                    }
                    for slot in record.fields.indices {
                        guard case .name(let name) = try ScriptExpression.parse(field(slot)) else {
                            throw ResourceError.rejected("delete_requires_named_binding")
                        }
                        try candidate.deleteGlobalBinding(name)
                    }
                    action = "global_binding_delete_candidate"
                case "draw":
                    try arity(1)
                    let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                        write: { _,_ in throw ResourceError.rejected("mutating_draw_operand") },
                        readIndexed: { try candidate.readIndexed($0,$1) })
                    guard let count = value.integer else { throw ResourceError.rejected("draw_requires_integer") }
                    // 0x6bc98c stores the request, clamped to at least one.
                    candidate.drawRequestCount = max(1,count)
                    action = "draw_request_candidate"
                case "stop":
                    let timed = record.fields.count == 3
                    if !timed { try arity(1) }
                    guard stopCallback == nil else {
                        throw ResourceError.rejected("nested_stop_outside_profile")
                    }
                    let callback = try program.label(callLabel())
                    guard program.ancestors[callback].isEmpty else {
                        throw ResourceError.rejected("stop_callback_inside_control_block")
                    }
                    try candidate.initializeButtonRegisters()
                    if timed {
                        let ticks = try (1...2).map { slot in
                            let value = try ScriptExpression.parse(field(slot)).evaluate(
                                read: { try candidate.read($0) },
                                write: { _,_ in throw ResourceError.rejected("mutating_stop_duration") },
                                readIndexed: { try candidate.readIndexed($0,$1) })
                            guard let integer = value.integer, (0...60_000).contains(integer) else {
                                throw ResourceError.rejected("timed_stop_duration_outside_profile")
                            }
                            return integer
                        }
                        // 0x6b0030 and 0x6b00cf retain separate timing operands.
                        timedStopRequest = (ticks[0], ticks[1])
                    }
                    stopCallback = callback
                    phase = .waitingForEvent
                    action = timed ? "timed_stop_callback_wait_candidate" : "stop_callback_wait_candidate"
                case "clk":
                    guard record.fields.count <= 1 else { throw ResourceError.rejected("click_wait_arity") }
                    var countdown: Int32 = -1
                    if !record.fields.isEmpty, !(try field(0)).isEmpty {
                        let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_wait_operand_outside_profile") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard let integer = value.integer else { throw ResourceError.rejected("click_wait_requires_integer") }
                        countdown = max(-1,integer)
                    }
                    try candidate.setClickResultZero()
                    clickWaitRemaining = countdown
                    phase = .waiting
                    action = "click_wait_enter_candidate"
                case "mge", "swe":
                    guard candidate.frames.last!.tableScope == [ScriptStorage.inputHandle],
                          (1...(command == "mge" ? 1 : 2)).contains(record.fields.count) else {
                        throw ResourceError.rejected("input_gesture_scope_or_arity")
                    }
                    func mode(_ slot: Int) throws -> Int32 {
                        let value = try ScriptExpression.parse(field(slot)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_gesture_operand") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        if case .string(let text) = value { return ScriptExpression.integerTextCache(text) ?? 0 }
                        guard let integer = value.integer else { throw ResourceError.rejected("gesture_mode_requires_integer") }
                        return integer
                    }
                    if command == "mge" {
                        candidate.mouseGestureMode = try mode(0) // 0x6ca89c
                        action = "input_mouse_gesture_mode_candidate"
                    } else {
                        let option = record.fields.count == 2 ? try mode(1) : 1
                        candidate.swipeSettings = (try mode(0), option) // 0x6ca9e1 / 0x6caa21
                        action = "input_swipe_mode_candidate"
                    }
                case "swap":
                    try arity(2)
                    let channels = try record.fields.indices.map { slot in
                        let value = try ScriptExpression.parse(field(slot)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_swap_operand") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard case .object(let handle) = value, ScriptStorage.isStreamHandle(handle) else {
                            throw ResourceError.rejected("swap_requires_sound_channels")
                        }
                        return handle
                    }
                    let first = candidate.soundChannels[channels[0]]
                    let second = candidate.soundChannels[channels[1]]
                    candidate.soundChannels[channels[0]] = second
                    candidate.soundChannels[channels[1]] = first
                    action = "sound_channel_swap_candidate"
                case "lim":
                    try arity(1)
                    guard candidate.frames.last!.tableScope == [ScriptStorage.temporaryDataHandle] else {
                        throw ResourceError.rejected("temporary_data_limit_requires_scope")
                    }
                    let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                        write: { _,_ in throw ResourceError.rejected("mutating_temporary_data_limit") },
                        readIndexed: { try candidate.readIndexed($0,$1) })
                    guard let limit = value.integer, (0...64).contains(limit) else {
                        throw ResourceError.rejected("temporary_data_limit_outside_profile")
                    }
                    logJumpLimit = Int(limit)
                    logJumpCheckpoints = Array(logJumpCheckpoints.suffix(logJumpLimit))
                    action = "temporary_checkpoint_limit_candidate"
                case "s", "?g":
                    if command == "s", candidate.frames.last!.tableScope.count == 1,
                       let stream = candidate.frames.last!.tableScope.first, ScriptStorage.isStreamHandle(stream) {
                        try arity(0)
                        // 0x6b5168 takes the zero/default stop path for this channel.
                        candidate.soundChannels[stream]?.playing = false
                        action = "sound_channel_stop_candidate"
                        break
                    }
                    if command == "s", candidate.frames.last!.tableScope == [ScriptStorage.temporaryDataHandle] {
                        try arity(3)
                        let name = try callLabel()
                        let values = try (1...2).map { slot in
                            try ScriptExpression.parse(field(slot)).evaluate(read: { try candidate.read($0) },
                                write: { _,_ in throw ResourceError.rejected("mutating_temporary_data_operand") },
                                readIndexed: { try candidate.readIndexed($0,$1) })
                        }
                        guard !name.isEmpty, name.utf8.count <= 1024,
                              let options = values[0].integer, let mode = values[1].integer else {
                            throw ResourceError.rejected("temporary_checkpoint_operands_outside_profile")
                        }
                        if logJumpLimit > 0 {
                            logJumpCheckpoints.removeAll { Data($0.name.utf8) == Data(name.utf8) }
                            if logJumpCheckpoints.count == logJumpLimit { logJumpCheckpoints.removeFirst() }
                            logJumpCheckpoints.append(.init(name: name, options: options, mode: mode,
                                storage: candidate, program: program, resumeIndex: pc+1))
                        }
                        action = "temporary_checkpoint_capture_candidate"
                        break
                    }
                    try arity(command == "s" ? 2 : 1)
                    if command == "?g", candidate.frames.last!.tableScope == [ScriptStorage.dialogueLogHandle] {
                        let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_dialogue_log_index") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard let index = value.integer else {
                            throw ResourceError.rejected("dialogue_log_query_requires_integer")
                        }
                        // 0x5b08f0 indexes backward from the newest record.
                        let entries = candidate.dialogueLogEntries
                        let entry = index >= 0 && Int(index) < min(256, entries.count)
                            ? entries[entries.count - 1 - Int(index)] : nil
                        candidate.clearResultBindings()
                        try candidate.setConfigResultArray(
                            [entry?.speaker, entry?.text, entry?.voice, entry?.extra].map { .string($0 ?? "") }, string: true)
                        action = "dialogue_log_reverse_query_candidate"
                        break
                    }
                    guard candidate.frames.last!.tableScope == [ScriptStorage.lineLogHandle] else {
                        throw ResourceError.rejected("line_log_command_requires_line_log_scope")
                    }
                    let name = try callLabel()
                    let key = Data(name.utf8)
                    if command == "s" {
                        let value = try ScriptExpression.parse(field(1)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_line_log_operand") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard let integer = value.integer, candidate.lineLogLockTag == 0,
                              candidate.lineLogValues.count < 4096 || candidate.lineLogValues[key] != nil else {
                            throw ResourceError.rejected("line_log_write_outside_profile")
                        }
                        // 0x6cc892 stores the value by key and reports success.
                        candidate.lineLogValues[key] = integer
                        candidate.clearResultBindings()
                        try candidate.resultInteger(1)
                        action = "line_log_integer_write_candidate"
                    } else {
                        // 0x6cc5b8 returns zero when the key is absent.
                        candidate.clearResultBindings()
                        try candidate.resultInteger(candidate.lineLogValues[key] ?? 0)
                        action = "line_log_integer_query_candidate"
                    }
                case "?k2":
                    try arity(0)
                    guard candidate.frames.last!.tableScope == [ScriptStorage.lineLogHandle] else {
                        throw ResourceError.rejected("read_status_query_requires_line_log_scope")
                    }
                    // The command-line session has no imported read-history.
                    // The script treats a result other than one as unread.
                    candidate.clearResultBindings()
                    try candidate.resultInteger(0)
                    action = "fresh_session_unread_status_candidate"
                case "?mcw", "?ap":
                    try arity(0)
                    let scope = candidate.frames.last!.tableScope
                    let value: Int32
                    if command == "?mcw", scope == [ScriptStorage.configHandle] {
                        // 0x6c3234 reads the field populated by AutoPlayClickTime at 0x50025f.
                        let configured = try candidate.configuration?.value(for: "AutoPlayClickTime")
                        value = configured.flatMap(ScriptExpression.integerTextCache) ?? 1500
                        action = "config_autoplay_click_time_candidate"
                    } else if command == "?ap", scope == [ScriptStorage.systemHandle] {
                        // 0x6b2508 reads the integer written by sys ap.
                        value = candidate.systemAutoPlayValue
                        action = "system_autoplay_value_query_candidate"
                    } else {
                        throw ResourceError.rejected("autoplay_query_scope_outside_profile")
                    }
                    candidate.clearResultBindings()
                    try candidate.resultInteger(value)
                case "?cv", "?cvv", "?cvm", "cvv", "cvm":
                    let writesActorSetting = command == "cvv" || command == "cvm"
                    try arity(writesActorSetting ? 2 : 1)
                    guard candidate.frames.last!.tableScope == [ScriptStorage.configHandle],
                          candidateRepository != nil else {
                        throw ResourceError.rejected("voice_actor_query_requires_config_catalog")
                    }
                    let name = asciiLower(try callLabel())
                    if candidate.voiceActorAliases == nil {
                        let (reference, data) = try candidateRepository!.readResource("system/voice/voicedata.txt")
                        let source = try ScriptSource(data: data, relativePath: reference.sourceFile)
                        var aliases = Array(repeating: [String](), count: 64)
                        for line in source.string(0..<source.scalars.count).components(separatedBy: .newlines) {
                            guard line.hasPrefix("act[") else { continue }
                            let fields = line.dropFirst(4).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                            guard fields.count == 2, fields[0].last == "]",
                                  let index = Int(fields[0].dropLast()), aliases.indices.contains(index) else {
                                throw ResourceError.rejected("voice_actor_alias_row_outside_profile")
                            }
                            aliases[index] = fields[1].split(separator: ",").map { asciiLower(String($0)) }
                        }
                        candidate.voiceActorAliases = aliases
                        resourceLocation = source.location(0..<data.count, line: 1)
                    }
                    // 0x6c1c8c scans 64 actor slots, returning the first
                    // matching alias or wildcard and -1 if neither exists.
                    let index = candidate.voiceActorAliases!.firstIndex {
                        $0.contains { $0 == "*" || Data($0.utf8) == Data(name.utf8) }
                    }
                    if command == "?cv" {
                        candidate.clearResultBindings()
                        try candidate.resultInteger(Int32(index ?? -1))
                        action = "voice_actor_index_candidate"
                    } else {
                        guard let index else { throw ResourceError.rejected("voice_actor_setting_alias_missing") }
                        // Original cfg dispatch 0x6c2486/0x6c25b1 writes the
                        // same actor slots queried at 0x6c2525/0x6c2640.
                        let volume = command == "cvv" || command == "?cvv"
                        let slot = Int32(index)
                        if writesActorSetting {
                            let value = try ScriptExpression.parse(field(1)).evaluate(read: { try candidate.read($0) },
                                write: { _,_ in throw ResourceError.rejected("mutating_config_operand_outside_profile") },
                                readIndexed: { try candidate.readIndexed($0,$1) })
                            guard let integer = value.integer else {
                                throw ResourceError.rejected("config_operand_requires_integer")
                            }
                            if volume { candidate.actorVolumeOverrides[slot] = integer }
                            else { candidate.actorMuteOverrides[slot] = integer }
                            action = "config_actor_setting_write_candidate"
                        } else {
                            let override = volume ? candidate.actorVolumeOverrides[slot] : candidate.actorMuteOverrides[slot]
                            let key = volume ? "ActorVolume" : "ActorMute"
                            let configured = try candidate.configuration?.value(for: "\(key)[\(index)]")
                            // Constructor 0x502de4 initializes volume to 256
                            // and mute to zero for each actor slot.
                            let value = override ?? configured.flatMap(ScriptExpression.integerTextCache) ?? (volume ? 256 : 0)
                            candidate.clearResultBindings()
                            try candidate.resultInteger(value)
                            action = "config_actor_setting_query_candidate"
                        }
                    }
                case "prm":
                    try arity(0)
                    guard candidate.frames.last!.tableScope == [ScriptStorage.miscHandle] else {
                        throw ResourceError.rejected("process_parameters_require_misc_scope")
                    }
                    // 0x6c4565 reports guest launch arguments. This session
                    // supplies none. Host tool flags belong to the runner.
                    candidate.clearResultBindings()
                    try candidate.resultInteger(0)
                    try candidate.resultString("")

                    action = "guest_launch_parameters_empty_candidate"
                case "?mrd":
                    guard record.fields.count <= 1 else { throw ResourceError.rejected("unsupported_command_arity") }
                    guard candidate.frames.last!.tableScope == [ScriptStorage.systemHandle] else {
                        throw ResourceError.rejected("reader_query_requires_system_scope")
                    }
                    if record.fields.isEmpty {
                        // 0x6b2821 reads the active reader rather than a caller frame.
                        let source = program.document.source.relativePath
                        let parts = source.split(separator: "/", maxSplits: 1)
                        let logical = parts.count == 2 && parts[0].hasSuffix(".pack") ? String(parts[1]) : source
                        candidate.clearResultBindings()
                        try candidate.setConfigResultArray([.string(logical),
                            .string(candidate.frames.last?.entryLabel ?? "")], string: true)
                        action = "active_reader_identity_candidate"
                        break
                    }
                    let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                        write: { _,_ in throw ResourceError.rejected("mutating_reader_depth_operand") },
                        readIndexed: { try candidate.readIndexed($0,$1) })
                    guard value.integer == 1, let frame = candidate.frames.last,
                          let caller = frame.returnProgram, let index = frame.returnIndex, index > 0,
                          caller.document.records[index-1].kind == .lineTag else {
                        throw ResourceError.rejected("reader_query_depth_outside_profile")
                    }
                    // 0x6b2798 selects the reader one level back. Use the
                    // caller record's logical filename without the pack prefix.
                    let source = caller.document.records[index-1].location.sourceFile
                    let parts = source.split(separator: "/", maxSplits: 1)
                    let logical = parts.count == 2 && parts[0].hasSuffix(".pack") ? String(parts[1]) : source
                    candidate.clearResultBindings()
                    let callerLabel = candidate.frames.dropLast().last?.entryLabel ?? ""
                    try candidate.setConfigResultArray([.string(logical), .string(callerLabel)], string: true)
                    action = "caller_reader_identity_candidate"
                case "tz":
                    guard candidate.frames.last!.tableScope == [ScriptStorage.systemHandle],
                          (1...2).contains(record.fields.count) else {
                        throw ResourceError.rejected("thumbnail_priority_scope_or_arity")
                    }
                    let values: [Int32] = try record.fields.indices.map { slot in
                        let value = try ScriptExpression.parse(field(slot)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_thumbnail_priority_operand") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard let integer = value.integer else {
                            throw ResourceError.rejected("thumbnail_priority_requires_integer")
                        }
                        return integer
                    }
                    // 0x6b39d8 writes both slots, evaluating an omitted second slot as zero.
                    candidate.thumbnailPriorities = (values[0], values.count == 2 ? values[1] : 0)
                    action = "system_thumbnail_priority_candidate"
                case "eve":
                    try arity(2)
                    guard candidate.frames.last!.tableScope == [ScriptStorage.systemHandle],
                          asciiLower(try callLabel(0)) == "onframe" else {
                        throw ResourceError.rejected("system_event_outside_profile")
                    }
                    let destination = try program.label(callLabel(1))
                    guard program.ancestors[destination].isEmpty else {
                        throw ResourceError.rejected("system_event_target_inside_control_block")
                    }
                    // 0x6b34d1 compares the event name and resolves the label
                    // through 0x6c06f0 before replacing the stored target.
                    let location = records[destination].location
                    candidate.systemFrameEvent = location
                    target = location
                    action = "system_frame_event_registration_candidate"
                case "lkc":
                    try arity(1)
                    guard candidate.frames.last!.tableScope == [ScriptStorage.systemHandle] else {
                        throw ResourceError.rejected("lock_mask_requires_system_scope")
                    }
                    let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                        write: { _,_ in throw ResourceError.rejected("mutating_lock_mask_operand") },
                        readIndexed: { try candidate.readIndexed($0,$1) })
                    guard let mask = value.integer else {
                        throw ResourceError.rejected("lock_mask_requires_integer")
                    }
                    // 0x6b261e writes +0x15c, separate from lk at +0x158.
                    candidate.systemCustomLockMask = mask
                    action = "system_custom_lock_mask_candidate"
                case "?lk", "?lkc":
                    try arity(0)
                    guard candidate.frames.last!.tableScope == [ScriptStorage.systemHandle] else {
                        throw ResourceError.rejected("lock_query_requires_system_scope")
                    }
                    // 0x6b25de and 0x6b2636 read their respective lock fields.
                    let custom = command == "?lkc"
                    let mask = custom ? candidate.systemCustomLockMask : candidate.systemLockMask
                    candidate.clearResultBindings()
                    try candidate.resultInteger(mask ?? 0)
                    action = custom ? "system_custom_lock_query_candidate" : "system_lock_query_candidate"
                case "?mt":
                    try arity(0)
                    guard candidate.frames.last!.tableScope == [ScriptStorage.systemHandle],
                          let elapsed = callbackElapsedTicks else {
                        throw ResourceError.rejected("frame_time_query_requires_event_clock")
                    }
                    // 0x6b29a2 reads the current engine frame delta.
                    candidate.clearResultBindings()
                    try candidate.resultInteger(elapsed)
                    action = "system_frame_time_query_candidate"
                case "?skp", "dskp":
                    try arity(0)
                    guard candidate.frames.last!.tableScope == [ScriptStorage.systemHandle] else {
                        throw ResourceError.rejected("skip_query_requires_system_scope")
                    }
                    candidate.clearResultBindings()
                    // 0x6b249c reads the engine flag; 0x6b3b73 reads the context flag.
                    try candidate.resultInteger(0)
                    action = command == "dskp" ? "context_skip_fresh_session_candidate" : "system_skip_fresh_session_candidate"
                case "zero":
                    try arity(0)
                    candidate.engineField98 = 2
                    action = "engine_field_98_write_candidate"
                case "sc":
                    try arity(0)
                    guard candidate.frames.last!.tableScope == [ScriptStorage.inputHandle],
                          stopCallbackFrameDepth != nil, pendingButton == nil else {
                        throw ResourceError.rejected("input_click_query_outside_profile")
                    }
                    // 0x6ca40e calls the event scan at 0x6c9b4c.
                    candidate.clearResultBindings()
                    try candidate.resultInteger(pendingClick ? 1 : 0)
                    action = pendingClick ? "input_click_consumed_candidate" : "input_click_empty_cycle_candidate"
                    pendingClick = false
                case "gbc":
                    try arity(0)
                    guard candidate.frames.last!.tableScope == [ScriptStorage.inputHandle],
                          stopCallbackFrameDepth != nil else {
                        throw ResourceError.rejected("button_event_scope_required")
                    }
                    let handle = pendingButton ?? ScriptStorage.nullHandle
                    try candidate.setButtonResults(handle: handle,label: candidate.buttonScriptTargets[handle] ?? "")
                    pendingButton = nil
                    action = "input_button_result_candidate"
                case "play":
                    try arity(0)
                    guard stopCallbackFrameDepth == candidate.frames.count, stopCallback != nil else {
                        throw ResourceError.rejected("play_outside_stop_callback")
                    }
                    stopCallback = nil
                    timedStopRequest = nil
                    action = "stop_callback_play_candidate"
                case "?mp":
                    try arity(0)
                    guard candidate.frames.last!.tableScope == [ScriptStorage.inputHandle],
                          let pointerPosition else {
                        throw ResourceError.rejected("input_pointer_sample_required")
                    }
                    // 0x6ca602 publishes the two coordinates as ResultInt[0...1].
                    candidate.clearResultBindings()
                    try candidate.setConfigResultArray([.integer(pointerPosition.x),.integer(pointerPosition.y)],string: false)
                    action = "input_pointer_query_candidate"
                case "mm", "tf", "bm", "alg2":
                    guard (1...2).contains(record.fields.count),
                          let handle = candidate.frames.last!.tableScope.first,
                          candidate.frames.last!.tableScope.count == 1,
                          (handle == ScriptStorage.cameraHandle && candidate.cameraInitialized) ||
                            candidate.images[handle] != nil ||
                            (command == "alg2" && candidate.messages[handle] != nil) ||
                            (command == "mm" && candidate.buttonResources[handle] != nil) else {
                        throw ResourceError.rejected("motion_mode_requires_loaded_scope")
                    }
                    if handle == ScriptStorage.cameraHandle {
                        guard command != "alg2" else { throw ResourceError.rejected("image_alignment_requires_image_scope") }
                        try arity(command == "mm" ? 2 : 1)
                    } else if command != "mm" {
                        try arity(command == "alg2" ? 2 : 1)
                    }
                    let operands: [Int32] = try record.fields.indices.map { slot in
                        let value = try ScriptExpression.parse(field(slot)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_image_operand_outside_profile") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard let integer = value.integer else { throw ResourceError.rejected("image_operand_requires_integer") }
                        return integer
                    }
                    if handle == ScriptStorage.cameraHandle {
                        if command == "bm" {
                            // 0x68215c only stores blend indices 0...14.
                            if (0..<15).contains(operands[0]) {
                                candidate.cameraBlendMode = operands[0]
                            }
                            action = "camera_blend_mode_candidate"
                        } else if command == "tf" {
                            // 0x682490 accepts filters 1 and 2 and maps other values to zero.
                            candidate.cameraTextureFilter = (1...2).contains(operands[0]) ? UInt8(operands[0]) : 0
                            action = "camera_texture_filter_candidate"
                        } else {
                            // 0x682448 stores a full-width mode and clamps strength.
                            candidate.cameraMotion = (operands[0],min(200,max(0,operands[1])))
                            action = "camera_motion_mode_candidate"
                        }
                        break
                    }
                    if command == "bm" {
                        // Unlike the camera setter, 0x5acb5c stores the complete integer.
                        candidate.images[handle]?.blendMode = operands[0]
                        action = "image_blend_mode_candidate"
                        break
                    }
                    if command == "alg2" {
                        // 0x5adb2c stores both alignment operands as integers.
                        if candidate.messages[handle] != nil {
                            candidate.messages[handle]?.alignment = (operands[0],operands[1])
                            action = "message_alignment_candidate"
                        } else {
                            candidate.images[handle]?.alignment = (operands[0],operands[1])
                            action = "image_alignment_candidate"
                        }
                        break
                    }
                    if command == "tf" {
                        // 0x6c73da writes the image filter field without a loaded-resource gate.
                        candidate.images[handle]?.textureFilter = operands[0]
                        action = "image_texture_filter_candidate"
                        break
                    }
                    // Original setter at 0x5ac770 stores a byte and clamps the second integer.
                    let motion = ScriptStorage.MotionSettings(mode: UInt8(truncatingIfNeeded: operands[0]),
                        strength: operands.count == 2 ? min(200,max(0,operands[1])) : 100)
                    if candidate.buttons.contains(handle) {
                        candidate.buttonMotion[handle] = motion
                        action = "button_motion_mode_candidate"
                    } else {
                        candidate.images[handle]?.motion = motion
                        action = "image_motion_mode_candidate"
                    }
                case "?p":
                    try arity(0)
                    if candidate.frames.last!.tableScope == [ScriptStorage.systemHandle] {
                        // 0x6b23dd reads the system play-mode byte.
                        candidate.clearResultBindings()
                        try candidate.resultInteger(candidate.systemPlayMode)
                        action = "system_play_mode_query_candidate"
                        break
                    }
                    if candidate.frames.last!.tableScope.count == 1,
                       let stream = candidate.frames.last!.tableScope.first, ScriptStorage.isStreamHandle(stream) {
                        // Dispatch 0x6b5226 maps the stream state to stopped,
                        // finite playback, or indefinite playback in ResultInt[0].
                        let channel = candidate.soundChannels[stream]
                        let status: Int32 = channel?.playing == true ? (channel?.loopRequest == -1 ? 2 : 1) : 0
                        candidate.clearResultBindings()
                        try candidate.resultInteger(status)
                        action = "sound_play_status_query_candidate"
                        break
                    }
                    guard let handle = candidate.frames.last!.tableScope.first,
                          candidate.frames.last!.tableScope.count == 1,
                          let placement = candidate.images[handle]?.placement ?? candidate.messages[handle]?.placement ?? candidate.buttonPlacement[handle] else {
                        throw ResourceError.rejected("image_position_requires_placement")
                    }
                    guard (candidate.placementTransitions[handle]?.elapsed ?? 0) == 0 else {
                        throw ResourceError.rejected("intermediate_motion_position_outside_profile")
                    }
                    // This profile supports the zero-anchor placement path only.
                    candidate.clearResultBindings()
                    try candidate.setConfigResultArray(placement.map(ScriptValue.integer),string: false)
                    action = candidate.buttons.contains(handle) ? "button_position_query_candidate" : "image_position_query_candidate"
                    if candidate.messages[handle] != nil { action = "message_position_query_candidate" }

                case "d":
                    try arity(0)
                    if candidate.frames.last!.tableScope.count == 1,
                       let handle = candidate.frames.last!.tableScope.first, candidate.messages[handle] != nil {
                        // 0x67e67c / 0x67e6a4 forward disable / enable to all message components.
                        candidate.messages[handle]?.enabled = false
                        action = "message_disable_candidate"
                        break
                    }
                    if candidate.frames.last!.tableScope.count == 1,
                       let handle = candidate.frames.last!.tableScope.first, candidate.buttons.contains(handle) {
                        candidate.enabledButtons.remove(handle)
                        action = "button_disable_candidate"
                        break
                    }
                    guard let handle = candidate.frames.last!.tableScope.first,
                          candidate.frames.last!.tableScope.count == 1,
                          var image = candidate.images[handle] else {
                        throw ResourceError.rejected("image_disable_requires_image_scope")
                    }
                    image.enabled = false
                    candidate.images[handle] = image
                    action = "image_disable_candidate"
                case "e":
                    try arity(0)
                    if candidate.frames.last!.tableScope.count == 1,
                       let handle = candidate.frames.last!.tableScope.first, candidate.messages[handle] != nil {
                        // 0x67e67c / 0x67e6a4 forward disable / enable to all message components.
                        candidate.messages[handle]?.enabled = true
                        action = "message_enable_candidate"
                        break
                    }
                    if let handle = candidate.frames.last!.tableScope.first,
                       candidate.frames.last!.tableScope.count == 1, candidate.buttonResources[handle] != nil {
                        candidate.enabledButtons.insert(handle)
                        action = "button_enable_candidate"
                        break
                    }
                    if let handle = candidate.frames.last!.tableScope.first,
                       candidate.frames.last!.tableScope.count == 1, var movie = candidate.movies[handle],
                       movie.resource != nil {
                        movie.enabled = true
                        candidate.movies[handle] = movie
                        action = "theora_enable_candidate"
                        break
                    }
                    guard let handle = candidate.frames.last!.tableScope.first,
                          candidate.frames.last!.tableScope.count == 1,
                          var image = candidate.images[handle] else {
                        throw ResourceError.rejected("image_enable_requires_image_scope")
                    }
                    // 0x5aca20 sets the enable byte before attempting automatic selection.
                    image.enabled = true
                    candidate.images[handle] = image
                    action = image.selectedMember == nil ? "image_enable_default_candidate" : "image_enable_candidate"
                case "sk":
                    try arity(1)
                    guard candidate.frames.last!.tableScope.count == 1,
                          let stream = candidate.frames.last!.tableScope.first,
                          ScriptStorage.isStreamHandle(stream) else {
                        throw ResourceError.rejected("sound_seek_requires_stream_scope")
                    }
                    let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                        write: { _,_ in throw ResourceError.rejected("mutating_sound_operand_outside_profile") },
                        readIndexed: { try candidate.readIndexed($0,$1) })
                    guard let position = value.integer else {
                        throw ResourceError.rejected("sound_seek_requires_integer")
                    }
                    // 0x6b5406 forwards the seek operand to the stream component.
                    candidate.soundChannels[stream,default: .init()].seekRequest = position
                    action = "sound_seek_request_candidate"
                case "vtn", "v", "pan":
                    let scope = candidate.frames.last!.tableScope
                    if command == "v", scope.count == 1, let handle = scope.first,
                       var table = candidate.tables[handle] {
                        guard (1...2).contains(record.fields.count) else {
                            throw ResourceError.rejected("unsupported_command_arity")
                        }
                        func tableOperand(_ slot: Int) throws -> ScriptValue {
                            try ScriptExpression.parse(field(slot)).evaluate(read: { try candidate.read($0) },
                                write: { _,_ in throw ResourceError.rejected("mutating_table_write_operand") },
                                readIndexed: { try candidate.readIndexed($0,$1) })
                        }
                        guard case .string(let name) = try tableOperand(0) else {
                            throw ResourceError.rejected("table_write_requires_string_key")
                        }
                        let value: String
                        // The missing operand produces a zero-tagged integer and
                        // the table writer converts that integer to decimal text.
                        switch record.fields.count == 1 ? ScriptValue.integer(0) : try tableOperand(1) {
                        case .string(let string): value = string
                        case .integer(let integer): value = String(integer)
                        case .object: throw ResourceError.rejected("table_write_object_value_outside_profile")
                        }
                        if name.isEmpty {
                            // The insertion helper at 0x563563 bypasses a nil name.
                            action = "table_empty_key_ignored_candidate"
                            break
                        }
                        try table.setValue(value,for: name)
                        candidate.tables[handle] = table
                        try candidate.validate()
                        action = "table_value_write_candidate"
                        break
                    }
                    let timed = command != "vtn" && (2...3).contains(record.fields.count)
                    if !timed { try arity(1) }
                    let button = scope.count == 1 && command == "vtn"
                        ? scope.first.flatMap { candidate.buttonResources[$0] == nil ? nil : $0 } : nil
                    let image = scope.count == 1 && command != "pan"
                        ? scope.first.flatMap { candidate.images[$0] == nil ? nil : $0 } : nil
                    let message = scope.count == 1 && command == "vtn"
                        ? scope.first.flatMap { candidate.messages[$0] == nil ? nil : $0 } : nil
                    let stream = scope.count == 1 ? scope.first.flatMap { ScriptStorage.isStreamHandle($0) ? $0 : nil } : nil
                    guard message != nil || image != nil || button != nil || stream != nil else {
                        throw ResourceError.rejected("sound_setting_requires_loaded_channel")
                    }
                    let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                        write: { _,_ in throw ResourceError.rejected("mutating_sound_operand_outside_profile") },
                        readIndexed: { try candidate.readIndexed($0,$1) })
                    guard let integer = value.integer else {
                        throw ResourceError.rejected("sound_setting_requires_integer")
                    }
                    if let message {
                        // 0x6cc228 calls the volume-type setter on the first two components.
                        candidate.messages[message]?.volumeType = integer
                        action = "message_volume_type_candidate"
                        break
                    }
                    if let image {
                        // 0x6c82ff calls the image volume-type setter at 0x5ae6bc.
                        if command == "vtn" {
                            candidate.images[image]?.volumeType = integer
                            action = "image_volume_type_candidate"
                        } else {
                            try arity(1)
                            // 0x5ad0ac stores volume on the image and its component.
                            candidate.images[image]?.volume = integer
                            action = "image_volume_candidate"
                        }
                        break
                    }
                    if let button {
                        candidate.buttonVolumeType[button] = integer
                        action = "button_volume_type_candidate"
                        break
                    }
                    if let stream, candidate.soundChannels[stream] == nil { candidate.soundChannels[stream] = .init() }
                    if command == "vtn" { candidate.soundChannels[stream!]?.volumeType = integer }
                    else {
                        var timing: [Int32] = [0,0]
                        for slot in record.fields.indices.dropFirst() {
                            let value = try ScriptExpression.parse(field(slot)).evaluate(read: { try candidate.read($0) },
                                write: { _,_ in throw ResourceError.rejected("mutating_sound_operand_outside_profile") },
                                readIndexed: { try candidate.readIndexed($0,$1) })
                            guard let ticks = value.integer, ticks >= 0 else {
                                throw ResourceError.rejected("sound_timing_requires_nonnegative_integer")
                            }
                            timing[slot-1] = ticks
                        }
                        if command == "pan" {
                            // 0x6b5643 forwards position and two timing operands.
                            candidate.soundChannels[stream!]?.panRequest = (integer,timing[0],timing[1])
                        } else {
                            candidate.soundChannels[stream!]?.volume = integer
                            candidate.soundChannels[stream!]?.volumeDuration = timing[0]
                            candidate.soundChannels[stream!]?.volumeDelay = timing[1]
                        }
                    }
                    action = "sound_\(command)_candidate"
                case "sp", "pp":
                    guard let handle = candidate.frames.last!.tableScope.first,
                          candidate.frames.last!.tableScope.count == 1 else {
                        throw ResourceError.rejected("placement_requires_single_scope")
                    }
                    let imageSpeed = command == "sp" && candidate.images[handle] != nil
                    if imageSpeed {
                        guard (1...2).contains(record.fields.count) else {
                            throw ResourceError.rejected("unsupported_command_arity")
                        }
                    } else {
                        try arity(command == "sp" ? 2 : 3)
                    }
                    let slots = imageSpeed ? record.fields.indices.prefix(1) : record.fields.indices.prefix(record.fields.count)
                    let operands: [Int32] = try slots.map { slot in
                        let value = try ScriptExpression.parse(field(slot)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_movie_operand_outside_profile") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard let integer = value.integer else { throw ResourceError.rejected("placement_requires_integer") }
                        return integer
                    }
                    if imageSpeed {
                        // 0x6c58df reads only the first slot and calls the
                        // animation speed setter at 0x5ae608.
                        candidate.images[handle]?.animationSpeed = min(3000, max(0, operands[0]))
                        action = "image_animation_speed_candidate"
                    } else if command == "sp" {
                        guard candidate.buttonResources[handle] != nil else {
                            throw ResourceError.rejected("button_scale_requires_loaded_scope")
                        }
                        candidate.buttonScale[handle] = operands
                        action = "button_scale_candidate"
                    } else {
                        guard var movie = candidate.movies[handle], movie.resource != nil else {
                            throw ResourceError.rejected("movie_placement_requires_loaded_scope")
                        }
                        movie.placement = operands
                        candidate.movies[handle] = movie
                        action = "theora_placement_candidate"
                    }
                case "?tt":
                    try arity(0)
                    guard let handle = candidate.frames.last!.tableScope.first,
                          candidate.frames.last!.tableScope.count == 1,
                          let duration = candidate.movies[handle]?.durationTicks else {
                        throw ResourceError.rejected("movie_duration_unavailable")
                    }
                    candidate.clearResultBindings()
                    try candidate.resultInteger(duration)
                    action = "theora_duration_query_candidate"
                case "p4":
                    guard (11...12).contains(record.fields.count) else {
                        throw ResourceError.rejected("unsupported_command_arity")
                    }
                    guard candidate.frames.last!.tableScope.count == 1,
                          let handle = candidate.frames.last!.tableScope.first,
                          candidate.images[handle] != nil || candidate.messages[handle] != nil else {
                        throw ResourceError.rejected("extended_placement_requires_image_scope")
                    }
                    let values = try record.fields.indices.map { slot in
                        let value = try ScriptExpression.parse(field(slot)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_image_operand_outside_profile") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard let integer = value.integer else { throw ResourceError.rejected("image_operand_requires_integer") }
                        return integer
                    }
                    let duration = values[10]
                    // 0x6c6251 evaluates an omitted final operand through the nil-value path.
                    let loop: Int32 = values.count == 12 ? values[11] : 0
                    guard duration >= 0, loop == 0 else {
                        throw ResourceError.rejected("extended_placement_timing_outside_profile")
                    }
                    // 0x6c6284 shares the standard image placement helper.
                    let placement = [values[0],values[1],values[9]]
                    let transform = ScriptStorage.ImageTransform(depth: values[2],scale: Array(values[3..<6]),rotation: Array(values[6..<9]),loop: loop)
                    if var message = candidate.messages[handle] {
                        // Message image forwarding at 0x6b7d63 reaches the
                        // shared placement handler. Only immediate placement is modeled.
                        guard duration == 0 else {
                            throw ResourceError.rejected("timed_message_placement_outside_profile")
                        }
                        message.placement = placement
                        message.transform = transform
                        candidate.messages[handle] = message
                        action = "message_extended_placement_candidate"
                        break
                    }
                    var image = candidate.images[handle]!
                    image.transform = transform
                    if duration == 0 {
                        image.placement = placement
                        candidate.placementTransitions.removeValue(forKey: handle)
                    } else {
                        guard image.placement != nil, (candidate.placementTransitions[handle]?.elapsed ?? 0) == 0 else {
                            throw ResourceError.rejected("timed_placement_origin_unavailable")
                        }
                        candidate.placementTransitions[handle] = .init(destination: placement,duration: duration)
                    }
                    candidate.images[handle] = image
                    action = "image_extended_placement_candidate"
                case "p2":
                    try arity(1)
                    guard candidate.frames.last!.tableScope.count == 1,
                          let stream = candidate.frames.last!.tableScope.first,
                          ScriptStorage.isStreamHandle(stream) else {
                        throw ResourceError.rejected("sound_playback_requires_stream_scope")
                    }
                    let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                        write: { _,_ in throw ResourceError.rejected("mutating_sound_operand_outside_profile") },
                        readIndexed: { try candidate.readIndexed($0,$1) })
                    guard let loop = value.integer else {
                        throw ResourceError.rejected("sound_playback_loop_requires_integer")
                    }
                    // 0x59d01e returns without playing when the stream has no payload.
                    guard let resource = candidate.soundChannels[stream]?.resource else {
                        action = "sound_empty_playback_ignored_candidate"
                        break
                    }
                    candidate.soundChannels[stream]?.loopRequest = max(-1,loop)
                    candidate.soundChannels[stream]?.playing = true
                    soundPlaybackRequest = resource
                    phase = .waitingForMedia
                    action = "sound_playback_request_candidate"
                case "p", "m":
                    if command == "p", candidate.frames.last!.tableScope == [ScriptStorage.systemHandle] {
                        try arity(1)
                        let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_system_play_mode") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard let mode = value.integer, (0...5).contains(mode) else {
                            throw ResourceError.rejected("system_play_mode_outside_profile")
                        }
                        // 0x6b2369 dispatches 0 through 5 to the mode setters.
                        candidate.systemPlayMode = mode
                        action = "system_play_mode_write_candidate"
                        break
                    }
                    if command == "p", candidate.frames.last!.tableScope == [ScriptStorage.cameraHandle] {
                        guard (10...11).contains(record.fields.count) else {
                            throw ResourceError.rejected("unsupported_command_arity")
                        }
                        guard candidate.cameraInitialized else {
                            throw ResourceError.rejected("camera_placement_requires_initialization")
                        }
                        let values = try record.fields.indices.map { slot in
                            let value = try ScriptExpression.parse(field(slot)).evaluate(read: { try candidate.read($0) },
                                write: { _,_ in throw ResourceError.rejected("mutating_camera_operand") },
                                readIndexed: { try candidate.readIndexed($0,$1) })
                            guard let integer = value.integer else {
                                throw ResourceError.rejected("camera_placement_requires_integer")
                            }
                            return integer
                        }
                        // 0x6b9622 evaluates slot eleven. An omitted slot evaluates to zero.
                        candidate.cameraPlacementRequest = .init(position: Array(values[0..<3]),
                            scale: Array(values[3..<6]),rotation: Array(values[6..<9]),
                            duration: values[9],loop: values.count == 11 ? values[10] : 0)
                        action = "camera_placement_request_candidate"
                        break
                    }
                    if command == "p", candidate.frames.last!.tableScope.count == 1,
                       let stream = candidate.frames.last!.tableScope.first, ScriptStorage.isStreamHandle(stream) {
                        try arity(1)
                        let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_sound_operand_outside_profile") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard let loop = value.integer else {
                            throw ResourceError.rejected("sound_playback_loop_requires_integer")
                        }
                        guard let resource = candidate.soundChannels[stream]?.resource else {
                            action = "sound_empty_playback_ignored_candidate"
                            break
                        }
                        // 0x6b51aa tests for exactly one, and 0x573648
                        // translates that flag to the indefinite loop count.
                        candidate.soundChannels[stream]?.loopRequest = loop == 1 ? -1 : 0
                        candidate.soundChannels[stream]?.playing = true
                        soundPlaybackRequest = resource
                        phase = .waitingForMedia
                        action = "sound_playback_request_candidate"
                        break
                    }
                    if command == "p", let handle = candidate.frames.last!.tableScope.first,
                       candidate.frames.last!.tableScope.count == 1, let movie = candidate.movies[handle] {
                        try arity(0)
                        guard movie.enabled, let resource = movie.resource, let placement = movie.placement else {
                            throw ResourceError.rejected("movie_playback_requires_prepared_movie")
                        }
                        moviePlaybackRequest = MoviePlaybackRequest(resource: resource,placement: placement,handle: handle)
                        phase = .waitingForMedia
                        action = "theora_playback_request_candidate"
                        break
                    }
                    guard let handle = candidate.frames.last!.tableScope.first,
                          candidate.frames.last!.tableScope.count == 1,
                          (command == "m" && (candidate.images[handle] != nil || candidate.messages[handle] != nil)) ||
                            candidate.images[handle]?.resource != nil ||
                            (command == "p" && (candidate.buttonResources[handle] != nil || candidate.messages[handle] != nil)) else {
                        throw ResourceError.rejected("placement_or_member_requires_loaded_scope")
                    }
                    if command == "m", var message = candidate.messages[handle] {
                        try arity(1)
                        let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_image_operand_outside_profile") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard let index = value.integer else {
                            throw ResourceError.rejected("message_member_outside_profile")
                        }
                        // 0x6b7d63 forwards to the image member dispatcher.
                        if index == -1 || (index == 0 && message.backgroundMemberCount == 0) {
                            action = "message_empty_member_ignored_candidate"
                        } else {
                            guard index >= 0, Int(index) < message.backgroundMemberCount else {
                                throw ResourceError.rejected("message_member_outside_profile")
                            }
                            message.backgroundSelectedMember = index
                            candidate.messages[handle] = message
                            action = "message_background_member_selection_candidate"
                        }
                        break
                    }
                    let hasDuration = command == "p" && record.fields.count == 4
                    if !hasDuration { try arity(command == "p" ? 3 : 1) }
                    let motionNames = candidate.images[handle]?.resource.flatMap { imageMotionNames?($0) }
                    let operands: [Int32] = try record.fields.indices.map { slot in
                        let value = try ScriptExpression.parse(field(slot)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_image_operand_outside_profile") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        if command == "m", case .string(let name) = value {
                            // The named selector resolves through the member table before selecting.
                            if let motionNames {
                                return motionIndex(name, in: motionNames)
                            }
                            guard candidate.images[handle]?.resource == nil else {
                                throw ResourceError.rejected("named_image_member_metadata_required")
                            }
                            return 0
                        }
                        guard let integer = value.integer else { throw ResourceError.rejected("image_operand_requires_integer") }
                        return integer
                    }
                    if command == "p" {
                        let duration = hasDuration ? operands[3] : 0
                        guard duration >= 0 else {
                            throw ResourceError.rejected("negative_placement_duration_outside_profile")
                        }
                        if candidate.messages[handle] != nil {
                            // 0x6b7d63 forwards to the image position handler at 0x6c5942.
                            guard duration == 0 else {
                                throw ResourceError.rejected("timed_message_placement_outside_profile")
                            }
                            candidate.messages[handle]?.placement = Array(operands.prefix(3))
                            action = "message_placement_candidate"
                            break
                        }
                        if duration > 0 {
                            guard (candidate.images[handle]?.placement ?? candidate.messages[handle]?.placement ?? candidate.buttonPlacement[handle]) != nil,
                                  (candidate.placementTransitions[handle]?.elapsed ?? 0) == 0 else {
                                throw ResourceError.rejected("timed_placement_origin_unavailable")
                            }
                            // 0x5ac85f stores the target separately from the current position.
                            candidate.placementTransitions[handle] = .init(destination: Array(operands.prefix(3)),duration: duration)
                            action = "timed_placement_request_candidate"
                            break
                        }
                        candidate.placementTransitions.removeValue(forKey: handle)
                    }
                    if candidate.buttons.contains(handle) {
                        candidate.buttonPlacement[handle] = Array(operands.prefix(3))
                        action = "button_placement_candidate"
                        break
                    }
                    var image = candidate.images[handle]!
                    if command == "p" {
                        image.placement = Array(operands.prefix(3))
                        action = "image_placement_candidate"
                    } else {
                        guard operands[0] == -1 || (image.resource == nil && operands[0] == 0) ||
                            (operands[0] >= 0 && Int(operands[0]) < (motionNames?.count ?? image.memberCount)) else {
                            throw ResourceError.rejected("image_member_not_loaded")
                        }
                        if operands[0] == -1 {
                            action = "image_member_missing_ignored_candidate"
                        } else if image.resource == nil {
                            // 0x57e860 bypasses selection when the member count is zero.
                            action = "image_empty_member_ignored_candidate"
                        } else {
                            image.selectedMember = operands[0]
                            action = "image_member_selection_candidate"
                        }
                    }
                    candidate.images[handle] = image
                case "garr":
                    try arity(1)
                    guard case .name(let name) = try ScriptExpression.parse(field(0)) else {
                        throw ResourceError.rejected("garr_requires_named_binding")
                    }
                    let count = try candidate.buttonArrayCount(name)
                    candidate.clearResultBindings()
                    try candidate.resultInteger(count)
                    action = "button_array_count_candidate"
                case "lk":
                    if let handle = candidate.frames.last!.tableScope.first,
                       candidate.frames.last!.tableScope.count == 1, candidate.buttons.contains(handle) {
                        try arity(1)
                        let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_lock_operand_outside_profile") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard let lock = value.integer else { throw ResourceError.rejected("button_lock_requires_integer") }
                        candidate.buttonLocks[handle] = UInt8(truncatingIfNeeded: lock)
                        action = "button_lock_candidate"
                        break
                    }
                    if candidate.frames.last!.tableScope == [ScriptStorage.lineLogHandle] {
                        try arity(1)
                        let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_lock_operand_outside_profile") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        // 0x6cb136 copies the descriptor tag, not its integer payload.
                        switch value {
                        case .integer: candidate.lineLogLockTag = 0
                        case .string: candidate.lineLogLockTag = 1
                        case .object: throw ResourceError.rejected("line_log_lock_tag_outside_profile")
                        }
                        action = "line_log_lock_tag_candidate"
                        break
                    }
                    if candidate.frames.last!.tableScope == [ScriptStorage.fileLogHandle] {
                        try arity(1)
                        let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_lock_operand_outside_profile") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard let flag = value.integer else {
                            throw ResourceError.rejected("file_log_lock_requires_integer")
                        }
                        candidate.fileLogLocked = flag == 1 // 0x6b9f15
                        action = "file_log_lock_candidate"
                        break
                    }
                    if candidate.frames.last!.tableScope == [ScriptStorage.systemKeyHandle] {
                        try arity(1)
                        let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_lock_operand_outside_profile") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard let lock = value.integer else {
                            throw ResourceError.rejected("system_key_lock_requires_integer")
                        }
                        // 0x6ba34d inverts the operand before the byte setter at 0x696670.
                        candidate.systemKeyEnabled = lock == 0
                        action = "system_key_lock_candidate"
                        break
                    }
                    guard candidate.frames.last!.tableScope == [ScriptStorage.systemHandle],
                          record.fields.count <= 1 else {
                        throw ResourceError.rejected("system_lock_scope_or_arity")
                    }
                    if record.fields.isEmpty {
                        candidate.systemLockMask = 0x0fff_ffff
                    } else {
                        let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_lock_operand_outside_profile") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard let mask = value.integer else {
                            throw ResourceError.rejected("system_lock_requires_integer")
                        }
                        candidate.systemLockMask = mask
                    }
                    action = "system_lock_mask_candidate"
                case "?c", "?s", "?n":
                    try arity(command == "?c" ? 0 : 1)
                    if command == "?c", candidate.frames.last!.tableScope == [ScriptStorage.effectHandle] {
                        // 0x6b6127 only reports capture mode (1), not fade-in
                        // mode (4). ResultInt[1] is the priority field at +0x61.
                        let capturing = candidate.effectCapturePriority != nil && candidate.fadeInDuration == nil
                        let priority = candidate.fadeInDuration != nil
                            ? candidate.fadeInPriority ?? 60_000 : candidate.effectCapturePriority ?? 65_535
                        candidate.clearResultBindings()
                        try candidate.setConfigResultArray([.integer(capturing ? 1 : 0), .integer(priority)],string: false)
                        action = "effect_capture_status_query_candidate"
                        break
                    }
                    guard candidate.frames.last!.tableScope.count == 1,
                          let handle = candidate.frames.last!.tableScope.first,
                          (command != "?n" && candidate.lists[handle] != nil) ||
                            candidate.tables[handle] != nil else {
                        throw ResourceError.rejected("list_query_requires_single_scope")
                    }
                    if command == "?c" {
                        candidate.clearResultBindings()
                        try candidate.resultInteger(Int32(candidate.lists[handle]?.lineCount ?? candidate.tables[handle]!.count))
                        action = "list_count_candidate"
                    } else {
                        let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_list_index") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard let index = value.integer else { throw ResourceError.rejected("list_index_requires_integer") }
                        candidate.clearResultBindings()
                        if command == "?n" {
                            try candidate.resultString(candidate.tables[handle]!.name(at: index))
                            action = "table_name_candidate"
                            break
                        }
                        let line: String
                        if let list = candidate.lists[handle] {
                            line = try list.line(at: index)
                            action = "list_line_candidate"
                        } else {
                            // 0x6ce150 reads the value by sorted row index at 0x56396c.
                            let table = candidate.tables[handle]!
                            let name = try table.name(at: index)
                            line = try table.value(for: name) ?? ""
                            action = "table_value_at_index_candidate"
                        }
                        try candidate.resultString(line)
                        if candidate.lists[handle] != nil {
                            try candidate.resultInteger(try ScriptStringList.integerCache(line))
                        }
                    }
                case "ad":
                    try arity(2)
                    let scope = candidate.frames.last!.tableScope
                    guard scope.count == 1, let handle = scope.first, var list = candidate.lists[handle] else {
                        throw ResourceError.rejected("list_split_requires_list_scope")
                    }
                    let strings: [String] = try record.fields.indices.map { slot in
                        let value = try ScriptExpression.parse(field(slot)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_list_split_operand") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard case .string(let text) = value, text.utf8.count <= 8192 else {
                            throw ResourceError.rejected("list_split_requires_bounded_string")
                        }
                        return text
                    }
                    // 0x6cd58c reads the separator and source and calls the
                    // split helper at 0x4e281c before appending its entries.
                    guard [",", ";"].contains(strings[0]), let separator = strings[0].first,
                          !strings[1].contains("\r"), !strings[1].contains("\n") else {
                        throw ResourceError.rejected("list_split_separator_outside_profile")
                    }
                    for part in ScriptStringList.splitUnquoted(strings[1], separator: separator) {
                        try list.append(part, at: record.location)
                    }
                    candidate.lists[handle] = list
                    try candidate.validate()
                    action = "list_split_append_candidate"
                case "i", "a":
                    if command == "i", candidate.frames.last!.tableScope == [ScriptStorage.temporaryDataHandle] {
                        try arity(0)
                        logJumpCheckpoints.removeAll()
                        action = "temporary_checkpoint_clear_candidate"
                        break
                    }
                    if candidate.frames.last!.tableScope == [ScriptStorage.dialogueLogHandle] {
                        if command == "i" {
                            try arity(0)
                            candidate.dialogueLogEntries.removeAll()
                            candidate.dialogueLogBytes = 0
                            action = "dialogue_log_clear_candidate"
                        } else {
                            try arity(4)
                            let values = try record.fields.indices.map { try callLabel($0) }
                            let bytes = values.reduce(0) { $0 + $1.utf8.count }
                            guard candidate.dialogueLogEntries.count < 20_000,
                                  candidate.dialogueLogBytes + bytes <= 16 * 1024 * 1024 else {
                                throw ResourceError.rejected("dialogue_log_budget")
                            }
                            candidate.dialogueLogEntries.append(.init(location: record.location,
                                speaker: values[0], text: values[1], voice: values[2], extra: values[3]))
                            candidate.dialogueLogBytes += bytes
                            action = "dialogue_log_append_candidate"
                        }
                        break
                    }
                    if candidate.frames.last!.tableScope == [ScriptStorage.fileLogHandle] {
                        if command == "i" {
                            try arity(0)
                            candidate.fileLogPaths.removeAll()
                            action = "file_log_clear_candidate"
                        } else {
                            try arity(1)
                            let path = try callLabel()
                            guard candidate.fileLogPaths.count < 512 else {
                                throw ResourceError.rejected("file_log_path_limit")
                            }
                            // 0x6b9eb2 registers a path with the file-log object.
                            candidate.fileLogPaths.append(path)
                            action = "file_log_path_candidate"
                        }
                        break
                    }
                    if command == "i", candidate.frames.last!.tableScope == [ScriptStorage.cameraHandle] {
                        try arity(0)
                        // 0x6b9443 resets the camera component via two helpers.
                        candidate.cameraGeneratorFilterRequests.removeAll()
                        candidate.cameraGeneratorRequests.removeAll()
                        candidate.cameraPlacementRequest = nil
                        candidate.cameraColorRequest = nil
                        candidate.cameraBlendMode = nil
                        candidate.cameraMotion = nil
                        candidate.cameraTextureFilter = 0
                        candidate.cameraPriorities = nil
                        candidate.cameraInitialized = true
                        action = "camera_initialize_candidate"
                        break
                    }
                    if command == "i", candidate.frames.last!.tableScope.count == 1,
                       let handle = candidate.frames.last!.tableScope.first, candidate.tables[handle] != nil {
                        try arity(0)
                        candidate.tables[handle]?.clear()
                        action = "table_clear_candidate"
                        break
                    }
                    if command == "a", candidate.frames.last!.tableScope.count == 1,
                       let handle = candidate.frames.last!.tableScope.first, var list = candidate.lists[handle] {
                        try arity(1)
                        let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_list_append_operand") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard case .string(let text) = value else {
                            throw ResourceError.rejected("list_append_requires_string")
                        }
                        try list.append(text,at: record.location)
                        candidate.lists[handle] = list
                        try candidate.validate()
                        action = "list_append_candidate"
                        break
                    }
                    if command == "a", candidate.frames.last!.tableScope == [ScriptStorage.replacementHandle] {
                        try arity(2)
                        func replacementOperand(_ slot: Int) throws -> String {
                            let value = try ScriptExpression.parse(field(slot)).evaluate(read: { try candidate.read($0) },
                                write: { _,_ in throw ResourceError.rejected("mutating_replacement_operand") },
                                readIndexed: { try candidate.readIndexed($0,$1) })
                            guard case .string(let string) = value else {
                                throw ResourceError.rejected("replacement_operand_requires_string")
                            }
                            return string
                        }
                        // Omitted mode resolves to zero in the 0x6ba3fa path.
                        try candidate.registerReplacement(key: replacementOperand(0),value: replacementOperand(1))
                        action = "replacement_register_mode_zero_candidate"
                        break
                    }
                    if command == "i", candidate.frames.last!.tableScope.count == 1,
                       let handle = candidate.frames.last!.tableScope.first, candidate.lists[handle] != nil {
                        try arity(0)
                        candidate.lists[handle] = ScriptStringList()
                        action = "list_clear_candidate"
                        break
                    }
                    if command == "i", candidate.frames.last!.tableScope == [ScriptStorage.effectHandle] {
                        try arity(0)
                        // 0x6b5add invokes the effect reset at 0x69365c.
                        candidate.effectFillColor = nil
                        candidate.effectCapturePriority = nil
                        candidate.fadeInDuration = nil
                        candidate.fadeInPriority = nil
                        candidate.fadeInRule = nil
                        candidate.fadeTiming = nil
                        candidate.fadeTransform = nil
                        action = "effect_reset_candidate"
                        break
                    }
                    if command == "i", candidate.frames.last!.tableScope.count == 1,
                       let stream = candidate.frames.last!.tableScope.first, ScriptStorage.isStreamHandle(stream) {
                        try arity(0)
                        candidate.soundChannels[stream] = ScriptStorage.SoundChannel()
                        action = "sound_channel_reset_candidate"
                        break
                    }
                    if command == "i", let handle = candidate.frames.last!.tableScope.first,
                       candidate.frames.last!.tableScope.count == 1, candidate.movies[handle] != nil {
                        try arity(0)
                        candidate.movies[handle] = ScriptStorage.MovieObject(initialized: true)
                        action = "theora_reset_candidate"
                        break
                    }
                    if command == "i", let handle = candidate.frames.last!.tableScope.first,
                       candidate.frames.last!.tableScope.count == 1, candidate.images[handle] != nil {
                        try arity(0)
                        candidate.placementTransitions.removeValue(forKey: handle)
                        candidate.images[handle] = ScriptStorage.ImageObject()
                        action = "image_reset_candidate"
                        break
                    }
                    guard candidate.frames.last!.tableScope == [ScriptStorage.systemKeyHandle] else {
                        throw ResourceError.rejected("unsupported_command")
                    }
                    if command == "i" {
                        try arity(0)
                        candidate.systemKeyBindings.removeAll()
                        action = "system_key_reset_candidate"
                    } else {
                        guard (2...5).contains(record.fields.count) else {
                            throw ResourceError.rejected("unsupported_command_arity")
                        }
                        func operand(_ slot: Int) throws -> ScriptValue {
                            try ScriptExpression.parse(field(slot)).evaluate(read: { try candidate.read($0) },
                                write: { _,_ in throw ResourceError.rejected("mutating_key_operand_outside_profile") },
                                readIndexed: { try candidate.readIndexed($0,$1) })
                        }
                        guard let code = try operand(0).integer, case .string(let name) = try operand(1),
                              !name.isEmpty, name.utf8.count <= 256 else {
                            throw ResourceError.rejected("system_key_binding_shape")
                        }
                        guard candidate.systemKeyBindings.count < 512 || candidate.systemKeyBindings[code] != nil else {
                            throw ResourceError.rejected("system_key_binding_limit")
                        }
                        // 0x6ba3a7 reads three slots before calling the key binder.
                        let label = record.fields.count > 2 && !record.fields[2].raw.isEmpty
                            ? try callLabel(2) : nil
                        if candidate.systemKeyBindings[code] == nil {
                            candidate.systemKeyBindings[code] = (name, label)
                        }
                        action = "system_key_bind_candidate"
                    }
                case "stid":
                    try arity(2)
                    func conversionOperand(_ slot: Int) throws -> ScriptValue {
                        try ScriptExpression.parse(field(slot)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_integer_conversion_operand") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                    }
                    guard case .string(let text) = try conversionOperand(0),
                          let fallback = try conversionOperand(1).integer else {
                        throw ResourceError.rejected("integer_conversion_requires_string_and_default")
                    }
                    // 0x6aff0f passes the text and integer default to the conversion helper.
                    candidate.clearResultBindings()
                    try candidate.resultInteger(ScriptExpression.integerTextCache(text) ?? fallback)
                    action = "string_integer_default_candidate"
                case "fexs":
                    try arity(1)
                    let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                        write: { _,_ in throw ResourceError.rejected("mutating_resource_exists_operand") },
                        readIndexed: { try candidate.readIndexed($0,$1) })
                    guard case .string(let path) = value, let catalog = candidateRepository?.catalog else {
                        throw ResourceError.rejected("resource_exists_requires_path_and_catalog")
                    }
                    let found = try catalog.resourceExists(path,currentSourceFile: record.location.sourceFile)
                    candidate.clearResultBindings()
                    try candidate.resultInteger(found ? 1 : 0)
                    action = "resource_exists_snapshot_candidate"
                case "g2":
                    try arity(2)
                    let scope = candidate.frames.last!.tableScope
                    guard scope.count == 1, let handle = scope.first,
                          (handle == ScriptStorage.cameraHandle && candidate.cameraInitialized) || candidate.images[handle] != nil || candidate.messages[handle] != nil else {
                        throw ResourceError.rejected("generator_requires_initialized_scope")
                    }
                    func generatorOperand(_ slot: Int) throws -> ScriptValue {
                        try ScriptExpression.parse(field(slot)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_camera_operand") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                    }
                    guard case .string(let filter) = try generatorOperand(0), filter.utf8.count <= 8192,
                          let reset = try generatorOperand(1).integer else {
                        throw ResourceError.rejected("camera_generator_filter_operand_outside_profile")
                    }
                    // 0x6b9843 and 0x682464 reset the filter component when the flag equals one.
                    let camera = handle == ScriptStorage.cameraHandle
                    var filters = camera ? candidate.cameraGeneratorFilterRequests
                        : candidate.images[handle]?.generatorFilterRequests ?? candidate.messages[handle]!.generatorFilterRequests
                    if reset == 1 { filters.removeAll() }
                    guard filters.count < 64 else { throw ResourceError.rejected("generator_filter_request_limit") }
                    filters.append(filter)
                    if camera {
                        candidate.cameraGeneratorFilterRequests = filters
                        action = "camera_generator_filter_request_candidate"
                    } else if candidate.messages[handle] != nil {
                        // 0x6b9394 selects the message receiver before the shared g2 dispatch.
                        candidate.messages[handle]?.generatorFilterRequests = filters
                        action = "message_generator_filter_request_candidate"
                    } else {
                        candidate.images[handle]?.generatorFilterRequests = filters
                        action = "image_generator_filter_request_candidate"
                    }
                case "g":
                    let scope = candidate.frames.last!.tableScope
                    if scope.count == 1, let handle = scope.first,
                       handle == ScriptStorage.cameraHandle || candidate.images[handle] != nil {
                        try arity(10)
                        let camera = handle == ScriptStorage.cameraHandle
                        guard !camera || candidate.cameraInitialized else {
                            throw ResourceError.rejected("camera_generator_requires_initialization")
                        }
                        let values = try record.fields.indices.map { slot in
                            let value = try ScriptExpression.parse(field(slot)).evaluate(read: { try candidate.read($0) },
                                write: { _,_ in throw ResourceError.rejected("mutating_camera_operand") },
                                readIndexed: { try candidate.readIndexed($0,$1) })
                            guard let integer = value.integer else {
                                throw ResourceError.rejected("camera_generator_requires_integer")
                            }
                            return integer
                        }
                        let index = values[0]
                        guard (0...1).contains(index) else {
                            throw ResourceError.rejected("camera_generator_index_outside_profile")
                        }
                        // 0x6b9bc9 converts the final operand using exact equality to one.
                        let request = ScriptStorage.GeneratorRequest(index: index,
                            arguments: Array(values[1..<9]),persistent: values[9] == 1)
                        if camera {
                            candidate.cameraGeneratorRequests[index] = request
                            action = "camera_generator_request_candidate"
                        } else {
                            candidate.images[handle]?.generatorRequests[index] = request
                            action = "image_generator_request_candidate"
                        }
                        break
                    }
                    try arity(1)
                    guard candidate.frames.last!.tableScope == [ScriptStorage.saveDataHandle] else {
                        throw ResourceError.rejected("save_data_scope_required")
                    }
                    let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                        write: { _,_ in throw ResourceError.rejected("mutating_save_operand_outside_profile") },
                        readIndexed: { try candidate.readIndexed($0,$1) })
                    guard case .string(let name) = value else {
                        throw ResourceError.rejected("save_name_requires_string")
                    }
                    let present = try candidate.containsSessionSave(name)
                    candidate.clearResultBindings()
                    try candidate.resultInteger(present ? 1 : 0)
                    action = "session_save_presence_candidate"
                case "et", "nt":
                    try arity(1)
                    guard candidate.frames.last!.tableScope == [ScriptStorage.replacementHandle] else {
                        throw ResourceError.rejected("reader_prefix_requires_replacement_scope")
                    }
                    let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                        write: { _,_ in throw ResourceError.rejected("mutating_reader_prefix_operand") },
                        readIndexed: { try candidate.readIndexed($0,$1) })
                    guard case .string(let prefix) = value, prefix.utf8.count <= 8192,
                          !prefix.unicodeScalars.contains(where: { $0.value < 32 }) else {
                        throw ResourceError.rejected("reader_prefix_outside_profile")
                    }
                    if command == "et" {
                        candidate.exceptTextPrefix = prefix
                    } else {
                        candidate.noWordLineText = prefix
                    }
                    action = "reader_prefix_\(command)_candidate"
                case "rep", "div":
                    let numericDivide = command == "div" && record.fields.count == 5
                    if !numericDivide, command != "rep" || record.fields.count != 3 { try arity(2) }
                    func stringOperand(_ slot: Int) throws -> String {
                        let value = try ScriptExpression.parse(field(slot)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_string_operand_outside_profile") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard case .string(let string) = value else {
                            throw ResourceError.rejected("string_command_requires_strings")
                        }
                        return string
                    }
                    if command == "div" {
                        let delimiter = try stringOperand(0), input = try stringOperand(1)
                        guard [",", ":", ";", "＠"].contains(delimiter), let separator = delimiter.first,
                              !input.contains("\r"), !input.contains("\n") else {
                            throw ResourceError.rejected("divide_delimiter_or_quoting_outside_profile")
                        }
                        if numericDivide {
                            guard try field(2) == "1", try field(3) == "1", try field(4) == "0" else {
                                throw ResourceError.rejected("divide_options_outside_profile")
                            }
                        }
                        let fields = ScriptStringList.splitUnquoted(input, separator: separator, stripSpacing: numericDivide)
                        guard fields.count <= 16 else {
                            throw ResourceError.rejected("divide_field_limit")
                        }
                        candidate.clearResultBindings()
                        // TScriptRoutineResult declares sixteen string slots.
                        let values = fields.map { ScriptValue.string(String($0)) }
                        try candidate.setConfigResultArray(values + Array(repeating: .string(""),count: 16-values.count),string: true)
                        if numericDivide {
                            // 0x6b0e24 converts each field with the supplied integer fallback.
                            let numbers = fields.map { ScriptValue.integer(ScriptExpression.integerTextCache(String($0)) ?? 0) }
                            try candidate.setConfigResultArray(numbers + Array(repeating: .integer(0),count: 16-numbers.count),string: false)
                        } else {
                            try candidate.resultInteger(Int32(fields.count))
                        }
                        switch separator {
                        case ":": action = "colon_divide_candidate"
                        case ";": action = "semicolon_divide_candidate"
                        case "＠": action = "fullwidth_at_divide_candidate"
                        default: action = numericDivide ? "comma_divide_numeric_candidate" : "comma_divide_candidate"
                        }
                        break
                    }
                    let input = try stringOperand(0), needle = try stringOperand(1)
                    let replacement = record.fields.count == 3 ? try stringOperand(2) : ""
                    let output = needle.isEmpty && record.fields.count == 2 ? input :
                        try scriptLiteralReplace(input, needle: needle, replacement: replacement)
                    candidate.clearResultBindings()
                    try candidate.resultString(output)
                    action = "literal_replace_candidate"
                case "brep":
                    try arity(1)
                    guard candidate.frames.last!.tableScope.count == 1,
                          let handle = candidate.frames.last!.tableScope.first,
                          let table = candidate.tables[handle] else {
                        throw ResourceError.rejected("table_replacement_requires_single_scope")
                    }
                    // 0x6ce356 evaluates the operand before clearing results
                    // and assigning ResultStr[0], which can itself be the operand.
                    let result = try table.replacingLiteralKeys(in: callLabel())
                    candidate.clearResultBindings()
                    try candidate.resultString(result)
                    action = "table_literal_replacement_candidate"
                case "?r":
                    try arity(1)
                    guard candidate.frames.last!.tableScope == [ScriptStorage.replacementHandle] else {
                        throw ResourceError.rejected("replacement_query_requires_scope")
                    }
                    var text = try callLabel()
                    // 0x696a8c copies its input before applying registered rules.
                    for key in candidate.replacementOrder {
                        guard let rule = candidate.replacementRules[key] else { continue }
                        text = try scriptLiteralReplace(text, needle: rule.key, replacement: rule.value)
                    }
                    candidate.clearResultBindings()
                    try candidate.resultString(text)
                    action = "registered_literal_replacement_candidate"
                case "trim":
                    try arity(1)
                    let text = try callLabel()
                    // 0x414ef4 trims UTF-16 units through U+0020 at both ends.
                    let scalars = text.unicodeScalars
                    let start = scalars.firstIndex(where: { $0.value > 0x20 })
                    let end = scalars.lastIndex(where: { $0.value > 0x20 })
                    let trimmed = if let start, let end { String(scalars[start...end]) } else { "" }
                    candidate.clearResultBindings()
                    try candidate.resultString(trimmed)
                    action = "trim_string_candidate"
                case "copy", "cpy":
                    try arity(3)
                    func copyOperand(_ slot: Int) throws -> ScriptValue {
                        try ScriptExpression.parse(field(slot)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_string_copy_operand") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                    }
                    guard case .string(let text) = try copyOperand(0), text.utf8.count <= 8192,
                          let start = try copyOperand(1).integer, start > 0,
                          let count = try copyOperand(2).integer, count >= 0 else {
                        throw ResourceError.rejected("string_copy_operand_outside_profile")
                    }
                    // The script uses one-based positions. Preserve UTF-16 indexing
                    // and stop if a range cuts a surrogate pair.
                    let units = Array(text.utf16)
                    let offset = min(units.count, Int(start) - 1)
                    let end = min(units.count, offset + Int(count))
                    let slice = units[offset..<end]
                    let result = String(decoding: slice, as: UTF16.self)
                    guard result.utf16.elementsEqual(slice) else {
                        throw ResourceError.rejected("string_copy_partial_scalar")
                    }
                    candidate.clearResultBindings()
                    try candidate.resultString(result)
                    action = "string_copy_candidate"
                case "pos":
                    try arity(2)
                    let strings: [String] = try record.fields.indices.map { slot in
                        let value = try ScriptExpression.parse(field(slot)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_position_operand") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard case .string(let text) = value, text.utf8.count <= 8192 else {
                            throw ResourceError.rejected("position_requires_bounded_string")
                        }
                        return asciiLower(text)
                    }
                    // 0x6af748 calls the UTF-16 substring search; the result is one-based.
                    let match = (strings[1] as NSString).range(of: strings[0], options: .literal)
                    candidate.clearResultBindings()
                    try candidate.resultInteger(strings[0].isEmpty || match.location == NSNotFound ? 0 : Int32(match.location + 1))
                    action = "string_position_candidate"
                case "bpos":
                    try arity(1)
                    guard candidate.frames.last!.tableScope.count == 1,
                          let handle = candidate.frames.last!.tableScope.first,
                          let table = candidate.tables[handle] else {
                        throw ResourceError.rejected("table_position_requires_single_table")
                    }
                    let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                        write: { _,_ in throw ResourceError.rejected("mutating_table_position_operand") },
                        readIndexed: { try candidate.readIndexed($0,$1) })
                    guard case .string(let text) = value else {
                        throw ResourceError.rejected("table_position_requires_string")
                    }
                    // 0x563c79 initializes -1, then scans table names in reverse.
                    let match = try table.lastLiteralMatch(in: text)
                    candidate.clearResultBindings()
                    try candidate.setConfigResultArray([.integer(match?.index ?? -1),
                        .integer(match.flatMap { ScriptExpression.integerTextCache($0.value) } ?? 0)],string: false)
                    try candidate.setConfigResultArray([.string(match?.name ?? ""),.string(match?.value ?? "")],string: true)
                    action = "table_reverse_position_candidate"
                case "sort":
                    try arity(0)
                    guard candidate.frames.last!.tableScope.count == 1,
                          let handle = candidate.frames.last!.tableScope.first,
                          var table = candidate.tables[handle] else {
                        throw ResourceError.rejected("sort_requires_single_table")
                    }
                    table.sortKeys()
                    candidate.tables[handle] = table
                    action = "table_sort_candidate"
                case "asn", "comb":
                    try arity(1)
                    let handles = try candidate.scopedTables()
                    let operand = try ScriptExpression.parse(field(0))
                    guard case .name(let name) = operand, case .object(let source) = try candidate.read(name),
                          let sourceTable = candidate.tables[source], handles.allSatisfy({ candidate.tables[$0] != nil })
                    else { throw ResourceError.rejected("table_transfer_requires_named_tables") }
                    for handle in handles {
                        if command == "asn" {
                            candidate.tables[handle] = sourceTable
                        } else {
                            try candidate.tables[handle]!.overlayNonemptyValues(from: sourceTable)
                        }
                    }
                    try candidate.validate()
                    action = command == "asn" ? "table_assign_candidate" : "table_overlay_nonempty_candidate"
                case "fn2", "faa2", "fst2", "fsc2":
                    try arity(2)
                    guard candidate.frames.last!.tableScope == [ScriptStorage.configHandle] else {
                        throw ResourceError.rejected("config_object_scope_required")
                    }
                    func operand(_ slot: Int) throws -> ScriptValue {
                        try ScriptExpression.parse(field(slot)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_font_operand_outside_profile") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                    }
                    guard let index = try operand(0).integer else {
                        throw ResourceError.rejected("font_index_requires_integer")
                    }
                    let rawValue = try operand(1)
                    let property = ["fn2":"Name", "faa2":"AA", "fst2":"Style", "fsc2":"StyleColor"][command]!
                    let value: ScriptValue
                    if command == "fn2" {
                        guard case .string(let name) = rawValue, name.utf8.count <= 8192 else {
                            throw ResourceError.rejected("font_name_requires_bounded_string")
                        }
                        value = rawValue
                    } else {
                        guard let integer = rawValue.integer else {
                            throw ResourceError.rejected("font_property_requires_integer")
                        }
                        value = .integer(command == "fsc2" ? integer & 0x00ff_ffff : integer)
                    }
                    if (0..<8).contains(index) {
                        candidate.fontOverrides["Font[\(index)].\(property)"] = value
                    }
                    action = "config_font_write_candidate"
                case "?fn", "?faa", "?fst", "?fsc":
                    try arity(0)
                    guard candidate.frames.last!.tableScope == [ScriptStorage.configHandle] else {
                        throw ResourceError.rejected("font_configuration_required")
                    }
                    let property = ["?fn":"Name", "?faa":"AA", "?fst":"Style", "?fsc":"StyleColor"][command]!
                    let values: [ScriptValue] = try (0..<8).map { slot in
                        let key = "Font[\(slot)].\(property)"
                        if let override = candidate.fontOverrides[key] { return override }
                        guard let value = try candidate.configuration?.value(for: key) else {
                            throw ResourceError.rejected("font_configuration_slot_missing")
                        }
                        if command == "?fn" { return .string(value) }
                        guard let integer = ScriptExpression.integerTextCache(value) else {
                            throw ResourceError.rejected("font_configuration_integer_invalid")
                        }
                        return .integer(integer)
                    }
                    candidate.clearResultBindings()
                    try candidate.setConfigResultArray(values, string: command == "?fn")
                    action = "config_font_query_candidate"
                case "vtv", "vtm":
                    try arity(2)
                    guard candidate.frames.last!.tableScope == [ScriptStorage.configHandle] else {
                        throw ResourceError.rejected("config_object_scope_required")
                    }
                    func integerOperand(_ slot: Int) throws -> Int32 {
                        let value = try ScriptExpression.parse(field(slot)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_config_operand_outside_profile") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard let integer = value.integer else { throw ResourceError.rejected("config_operand_requires_integer") }
                        return integer
                    }
                    let index = try integerOperand(0), value = try integerOperand(1)
                    // The original updates one of two 32-entry arrays and notifies a host callback.
                    // The CLI retains state for a future host and has no registered callback.
                    if (0..<32).contains(index) {
                        if command == "vtv" { candidate.configVoiceValues[index] = max(0,value) }
                        else { candidate.configVoiceModes[index] = value }
                    }
                    action = "config_\(command)_candidate"
                case "tab":
                    try arity(1)
                    guard let handle = candidate.frames.last!.tableScope.first,
                          candidate.frames.last!.tableScope.count == 1,
                          candidate.buttonResources[handle] != nil || candidate.images[handle] != nil else {
                        throw ResourceError.rejected("button_tab_requires_loaded_scope")
                    }
                    let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                        write: { _,_ in throw ResourceError.rejected("mutating_button_tab_operand") },
                        readIndexed: { try candidate.readIndexed($0,$1) })
                    guard let order = value.integer else { throw ResourceError.rejected("button_tab_requires_integer") }
                    if candidate.images[handle] != nil {
                        // 0x6c74e1 writes the image field without publishing a result.
                        candidate.images[handle]?.tabOrder = order
                        action = "image_tab_order_candidate"
                        break
                    }
                    candidate.buttonTabOrder[handle] = order
                    candidate.clearResultBindings()
                    try candidate.resultInteger(order)
                    action = "button_tab_order_candidate"
                case "ui":
                    guard (1...4).contains(record.fields.count),
                          candidate.frames.last!.tableScope.count == 1,
                          let handle = candidate.frames.last!.tableScope.first,
                          candidate.buttons.contains(handle) else {
                        throw ResourceError.rejected("button_user_integer_shape")
                    }
                    // 0x6c7df4 processes four optional slots in order.
                    for slot in record.fields.indices {
                        let raw = try field(slot)
                        if raw.isEmpty { continue }
                        let value = try ScriptExpression.parse(raw).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_button_user_integer_operand") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard let integer = value.integer else {
                            throw ResourceError.rejected("button_user_integer_requires_integer")
                        }
                        candidate.buttonUserIntegers[handle,default: [:]][slot] = integer
                    }
                    action = "button_user_integer_candidate"
                case "us":
                    guard (1...4).contains(record.fields.count) else {
                        throw ResourceError.rejected("unsupported_command_arity")
                    }
                    guard let handle = candidate.frames.last!.tableScope.first,
                          candidate.frames.last!.tableScope.count == 1,
                          candidate.buttonResources[handle] != nil else {
                        throw ResourceError.rejected("button_target_requires_loaded_scope")
                    }
                    // 0x6c7e7c visits up to four optional string slots.
                    for slot in record.fields.indices {
                        if try field(slot).isEmpty { continue }
                        candidate.buttonUserStrings[handle,default: [:]][slot] = try callLabel(slot)
                    }
                    action = "button_user_string_candidate"
                    // Preserve the title replay's existing single-label dispatch adapter.
                    guard record.fields.count == 1,
                          let label = candidate.buttonUserStrings[handle]?[0],
                          label.hasPrefix("@@") else { break }
                    let destination = try program.label(label)
                    guard program.ancestors[destination].isEmpty else {
                        throw ResourceError.rejected("button_target_inside_control_block")
                    }
                    let location = records[destination].location
                    candidate.buttonScriptTargets[handle] = label
                    target = location
                    action = "button_script_target_candidate"
                case "?m":
                    try arity(0)
                    let scope = candidate.frames.last!.tableScope
                    guard scope.count == 1, let handle = scope.first, let image = candidate.images[handle] else {
                        throw ResourceError.rejected("image_member_query_requires_image_scope")
                    }
                    var name = ""
                    if let index = image.selectedMember, let resource = image.resource {
                        guard let names = imageMotionNames?(resource), names.indices.contains(Int(index)) else {
                            throw ResourceError.rejected("named_image_member_metadata_required")
                        }
                        name = names[Int(index)]
                    }
                    candidate.clearResultBindings()
                    try candidate.resultString(name)
                    action = "image_selected_member_name_candidate"
                case "midx":
                    try arity(1)
                    guard candidate.frames.last!.tableScope.count == 1,
                          let handle = candidate.frames.last!.tableScope.first,
                          let image = candidate.images[handle] else {
                        throw ResourceError.rejected("image_member_query_requires_image_scope")
                    }
                    let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                        write: { _,_ in throw ResourceError.rejected("mutating_image_member_operand") },
                        readIndexed: { try candidate.readIndexed($0,$1) })
                    guard case .string(let name) = value else {
                        throw ResourceError.rejected("image_member_query_requires_name")
                    }
                    let names: [String]
                    if let resource = image.resource {
                        guard let indexed = imageMotionNames?(resource) else {
                            throw ResourceError.rejected("named_image_member_metadata_required")
                        }
                        names = indexed
                    } else {
                        names = []
                    }
                    // 0x5800ae initializes the lookup to -1 before scanning members.
                    candidate.clearResultBindings()
                    try candidate.resultInteger(motionIndex(name, in: names))
                    action = names.isEmpty ? "image_empty_member_index_candidate" : "image_named_member_index_candidate"
                case "exv":
                    try arity(2)
                    let scope = candidate.frames.last!.tableScope
                    guard scope.count == 1, let handle = scope.first,
                          var image = candidate.images[handle] else {
                        throw ResourceError.rejected("image_extended_value_requires_image_scope")
                    }
                    let operands = try record.fields.indices.map { slot in
                        try ScriptExpression.parse(field(slot)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_image_operand_outside_profile") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                    }
                    guard let index = operands[0].integer, (0..<32).contains(index),
                          let value = operands[1].integer else {
                        throw ResourceError.rejected("image_extended_value_outside_profile")
                    }
                    // 0x6c7d46 writes the numeric operand into the indexed extended slot.
                    image.extendedScalarValues[Int(index)] = value
                    candidate.images[handle] = image
                    action = "image_extended_value_write_candidate"
                case "exr":
                    try arity(0)
                    guard candidate.frames.last!.tableScope.count == 1,
                          let handle = candidate.frames.last!.tableScope.first else {
                        throw ResourceError.rejected("image_extended_resource_metadata_outside_profile")
                    }
                    if var message = candidate.messages[handle] {
                        if let background = message.background, imageExtendedValues?(background)?.isEmpty != true {
                            throw ResourceError.rejected("image_extended_resource_metadata_outside_profile")
                        }
                        // Message image forwarding at 0x6b7d63 reaches the
                        // same extended-state initializer via 0x6c7dea.
                        message.backgroundExtendedDefaultsPrepared = true
                        candidate.messages[handle] = message
                        action = "message_extended_defaults_candidate"
                        break
                    }
                    guard var image = candidate.images[handle] else {
                        throw ResourceError.rejected("image_extended_resource_metadata_outside_profile")
                    }
                    // 0x581e5c initializes the extended state before looking up resource metadata.
                    if let resource = image.resource, !image.standaloneDPNG {
                        guard let values = imageExtendedValues?(resource) else {
                            throw ResourceError.rejected("image_extended_resource_metadata_outside_profile")
                        }
                        image.extendedScalarValues = values
                    }
                    image.extendedDefaultsPrepared = true
                    candidate.images[handle] = image
                    action = "image_extended_defaults_candidate"
                case "fo":
                    if candidate.frames.last!.tableScope.count == 1,
                       let stream = candidate.frames.last!.tableScope.first, ScriptStorage.isStreamHandle(stream) {
                        try arity(1)
                        let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_sound_filter_operand") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard case .string(let filter) = value, filter.utf8.count <= 8192 else {
                            throw ResourceError.rejected("sound_filter_requires_bounded_string")
                        }
                        // 0x6b571b forwards the string to the stream filter helper.
                        candidate.soundChannels[stream,default: .init()].filterRequest = filter
                        action = "sound_filter_request_candidate"
                        break
                    }
                    try arity(2)
                    guard candidate.frames.last!.tableScope.count == 1,
                          let handle = candidate.frames.last!.tableScope.first,
                          var image = candidate.images[handle] else {
                        throw ResourceError.rejected("image_filter_requires_image_scope")
                    }
                    func filterOperand(_ slot: Int) throws -> ScriptValue {
                        try ScriptExpression.parse(field(slot)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_image_filter_operand") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                    }
                    guard let index = try filterOperand(0).integer, (0..<32).contains(index),
                          case .string(let filter) = try filterOperand(1), filter.utf8.count <= 8192 else {
                        throw ResourceError.rejected("image_filter_operand_outside_profile")
                    }
                    // 0x5aeb58 assigns a filter string to one of 32 slots.
                    image.filterOverrides[index] = filter.isEmpty ? nil : filter
                    candidate.images[handle] = image
                    action = "image_filter_override_candidate"
                case "li", "ls":
                    try arity(2)
                    guard let handle = candidate.frames.last!.tableScope.first,
                          candidate.frames.last!.tableScope.count == 1,
                          candidateRepository != nil else {
                        throw ResourceError.rejected("image_binding_requires_single_scope")
                    }
                    let imageBinding = command == "li" && candidate.images[handle] != nil
                    guard let container = candidate.buttonResources[handle] ?? (imageBinding ? candidate.images[handle]?.resource : nil) else {
                        throw ResourceError.rejected("button_image_binding_requires_loaded_scope")
                    }
                    func operand(_ slot: Int) throws -> ScriptValue {
                        try ScriptExpression.parse(field(slot)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_button_operand_outside_profile") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                    }
                    guard let slot = try operand(0).integer, (0...(command == "li" ? 2 : 1)).contains(slot),
                          case .string(let path) = try operand(1) else {
                        throw ResourceError.rejected("button_image_binding_shape")
                    }
                    if imageBinding, path.isEmpty {
                        candidate.images[handle]?.boundImages.removeValue(forKey: slot)
                        action = "image_slot_release_candidate"
                        break
                    }
                    if command == "li", let range = try imageMemberLookup?(container, path) {
                        let member = ScriptLocation(sourceFile: container.sourceFile,sourceSHA256: container.sourceSHA256,
                            byteOffset: range.offset,byteLength: range.length,rangeSHA256: range.sha256,lineNumber: 1)
                        resourceLocation = member
                        if imageBinding {
                            candidate.images[handle]?.boundImages[slot] = member
                            action = "image_container_slot_bind_candidate"
                        } else {
                            candidate.buttonImages[handle,default: [:]][slot] = member
                            action = "button_container_image_bind_candidate"
                        }
                        break
                    }
                    let catalog = candidateRepository!.catalog
                    let logical = try (command == "ls" || imageBinding) && path.hasPrefix("..")
                        ? catalog.relativeResourcePath(path,currentSourceFile: record.location.sourceFile)
                        : catalog.resourcePath(path,currentSourceFile: record.location.sourceFile)
                    let (reference, data) = try candidateRepository!.readResource(logical)
                    if command == "li" {
                        guard let imageLoader else { throw ResourceError.rejected("image_object_decoder_required") }
                        _ = try imageLoader(data)
                    } else {
                        guard data.count >= 12, data.prefix(4) == Data("RIFF".utf8),
                              data[8..<12] == Data("WAVE".utf8) else {
                            throw ResourceError.rejected("button_sound_requires_wave")
                        }
                    }
                    let location = ScriptLocation(sourceFile: reference.sourceFile,sourceSHA256: reference.sourceSHA256,
                        byteOffset: 0,byteLength: data.count,rangeSHA256: data.sha256Hex,lineNumber: 1)
                    resourceLocation = location
                    if imageBinding {
                        candidate.images[handle]?.boundImages[slot] = location
                        action = "image_slot_bind_candidate"
                    } else if command == "li" {
                        candidate.buttonImages[handle,default: [:]][slot] = location
                        action = "button_image_bind_candidate"
                    } else {
                        candidate.buttonSounds[handle,default: [:]][slot] = location
                        action = "button_sound_bind_candidate"
                    }
                case "l", "?v":
                    if command == "?v", candidate.frames.last!.tableScope.count == 1,
                       let stream = candidate.frames.last!.tableScope.first, ScriptStorage.isStreamHandle(stream) {
                        try arity(0)
                        // 0x6b537c reads the requested channel gain written by
                        // 0x5a0882. Channel reset initializes it to 256.
                        let volume = candidate.soundChannels[stream]?.volume ?? 256
                        candidate.clearResultBindings()
                        try candidate.resultInteger(volume)
                        action = "sound_volume_query_candidate"
                        break
                    }
                    if command == "l", candidate.frames.last!.tableScope.count == 1,
                       let stream = candidate.frames.last!.tableScope.first, ScriptStorage.isStreamHandle(stream) {
                        try arity(1)
                        let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_sound_operand_outside_profile") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard case .string(let path) = value, candidateRepository != nil else {
                            throw ResourceError.rejected("sound_load_shape_outside_profile")
                        }
                        let logical = try candidateRepository!.catalog.resourcePath(path,currentSourceFile: record.location.sourceFile)
                        let (reference, data) = try candidateRepository!.readResource(logical)
                        try ScriptMovieHeader.validateVorbis(data)
                        let location = ScriptLocation(sourceFile: reference.sourceFile,sourceSHA256: reference.sourceSHA256,
                            byteOffset: 0,byteLength: data.count,rangeSHA256: data.sha256Hex,lineNumber: 1)
                        resourceLocation = location
                        // The original load dispatch at 0x6b50cc takes the
                        // channel index directly, without a script-side reset.
                        candidate.soundChannels[stream, default: .init()].resource = location
                        action = "sound_resource_load_candidate"
                        break
                    }
                    if command == "l", let handle = candidate.frames.last!.tableScope.first,
                       candidate.frames.last!.tableScope.count == 1, candidate.movies[handle] != nil {
                        try arity(2)
                        func operand(_ slot: Int) throws -> ScriptValue {
                            try ScriptExpression.parse(field(slot)).evaluate(read: { try candidate.read($0) },
                                write: { _,_ in throw ResourceError.rejected("mutating_movie_operand_outside_profile") },
                                readIndexed: { try candidate.readIndexed($0,$1) })
                        }
                        guard candidate.movies[handle]?.initialized == true,
                              case .string(let path) = try operand(0), try operand(1).integer == 1,
                              candidateRepository != nil else {
                            throw ResourceError.rejected("theora_load_shape_outside_profile")
                        }
                        let logical = try candidateRepository!.catalog.resourcePath(path,currentSourceFile: record.location.sourceFile)
                        let (reference, data) = try candidateRepository!.readResource(logical)
                        try ScriptMovieHeader.validateTheora(data)
                        let location = ScriptLocation(sourceFile: reference.sourceFile,sourceSHA256: reference.sourceSHA256,
                            byteOffset: 0,byteLength: data.count,rangeSHA256: data.sha256Hex,lineNumber: 1)
                        resourceLocation = location
                        candidate.movies[handle]!.resource = location
                        action = "theora_resource_load_candidate"
                        break
                    }
                    if command == "l", let handle = candidate.frames.last!.tableScope.first,
                       candidate.frames.last!.tableScope.count == 1,
                       candidate.images[handle] != nil || candidate.buttons.contains(handle) || candidate.messages[handle] != nil {
                        try arity(1)
                        let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_image_operand_outside_profile") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard case .string(let path) = value, candidateRepository != nil else {
                            throw ResourceError.rejected("image_resource_path_or_catalog")
                        }
                        if path.isEmpty, candidate.messages[handle] != nil {
                            // 0x67dd6c forwards empty slots to the image release path at 0x5ad744.
                            candidate.messages[handle]?.background = nil
                            candidate.messages[handle]?.backgroundMemberCount = 0
                            candidate.messages[handle]?.backgroundSelectedMember = nil
                            candidate.messages[handle]?.backgroundExtendedDefaultsPrepared = false
                            action = "message_empty_background_release_candidate"
                            break
                        }
                        if path.isEmpty, var image = candidate.images[handle] {
                            // The nil filename branch at 0x5ad775 releases the image payload.
                            image.resource = nil
                            image.standaloneDPNG = false
                            image.extendedDefaultsPrepared = false
                            image.extendedScalarValues.removeAll()
                            image.width = nil
                            image.height = nil
                            image.selectedMember = nil
                            image.memberCount = 0
                            candidate.images[handle] = image
                            action = "image_empty_path_release_candidate"
                            break
                        }
                        let logical = try candidateRepository!.catalog.resourcePath(path,currentSourceFile: record.location.sourceFile)
                        let (reference, data) = try candidateRepository!.readResource(logical)
                        resourceLocation = ScriptLocation(sourceFile: reference.sourceFile,sourceSHA256: reference.sourceSHA256,
                            byteOffset: 0,byteLength: data.count,rangeSHA256: data.sha256Hex,lineNumber: 1)
                        guard let imageLoader else { throw ResourceError.rejected("image_object_decoder_required") }
                        let (width, height, memberCount) = try imageLoader(data)
                        guard (1...8192).contains(width), (1...8192).contains(height) else {
                            throw ResourceError.rejected("image_object_dimensions")
                        }
                        if candidate.buttons.contains(handle) {
                            candidate.buttonResources[handle] = resourceLocation
                            action = "button_resource_load_candidate"
                        } else if candidate.messages[handle] != nil {
                            // 0x6cbc40 resolves the file and calls the message image loader.
                            candidate.messages[handle]?.background = resourceLocation
                            candidate.messages[handle]?.backgroundMemberCount = memberCount
                            candidate.messages[handle]?.backgroundSelectedMember = nil
                            candidate.messages[handle]?.backgroundExtendedDefaultsPrepared = false
                            action = "message_background_load_candidate"
                        } else {
                            var image = candidate.images[handle]!
                            image.extendedDefaultsPrepared = false
                            image.extendedScalarValues.removeAll()
                            image.resource = resourceLocation
                            // A fully bounded standalone DPNG has only tile records,
                            // unlike the ABMP resource with an extended data table.
                            image.standaloneDPNG = data.starts(with: Data("DPNG".utf8)) &&
                                (try? DPNGDescriptor.parse(data)) != nil
                            image.width = width
                            image.height = height
                            image.memberCount = memberCount
                            image.selectedMember = nil
                            candidate.images[handle] = image
                            action = "image_load_candidate"
                        }
                        break
                    }
                    let handles = try candidate.scopedTables()
                    guard command == "l" ? record.fields.count == 1 : (1...2).contains(record.fields.count)
                    else { throw ResourceError.rejected("unsupported_table_command_arity") }
                    let operand = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },write: { _,_ in
                        throw ResourceError.rejected("mutating_table_operand_outside_profile")
                    },readIndexed: { try candidate.readIndexed($0,$1) })
                    guard case .string(let string) = operand else { throw ResourceError.rejected("table_operand_requires_string") }
                    if command == "l" {
                        guard candidateRepository != nil else { throw ResourceError.rejected("module_catalog_required") }
                        let logical = try candidateRepository!.catalog.resourcePath(string,currentSourceFile: record.location.sourceFile)
                        pendingModuleCandidates = try candidateRepository!.catalog.variants(for: logical)
                        let (reference,data) = try candidateRepository!.readResource(logical)
                        resourceLocation = ScriptLocation(sourceFile: reference.sourceFile,sourceSHA256: reference.sourceSHA256,
                            byteOffset: 0,byteLength: data.count,rangeSHA256: data.sha256Hex,lineNumber: 1)
                        for handle in handles {
                            if candidate.tables[handle] != nil { candidate.tables[handle] = try ScriptTable(data: data,relativePath: reference.sourceFile,allowWideKeys: true) }
                            else { candidate.lists[handle] = try ScriptStringList(data: data,relativePath: reference.sourceFile) }
                        }
                        try candidate.validate(); action = "load_table_candidate"
                    } else {
                        var defaultString = "", defaultInteger: Int32 = 0
                        if record.fields.count == 2 {
                            let raw = try field(1), expression = try ScriptExpression.parse(raw)
                            let fallback = try expression.evaluate(read: { try candidate.read($0) },write: { _,_ in
                                throw ResourceError.rejected("mutating_table_default_outside_profile")
                            },readIndexed: { try candidate.readIndexed($0,$1) })
                            switch fallback {
                            case .string(let text):
                                defaultString = text
                                defaultInteger = ScriptExpression.integerTextCache(text) ?? 0
                            case .integer(let value):
                                defaultString = raw.range(of: #"^\$[0-9A-Fa-f]{1,8}$"#,options: .regularExpression) != nil
                                    ? raw : String(value)
                                defaultInteger = value
                            case .object:
                                throw ResourceError.rejected("table_default_value_cache_unverified")
                            }
                        }
                        for handle in handles {
                            if let table = candidate.tables[handle] {
                                let found = try table.value(for: string)
                                try candidate.results(string: found ?? defaultString,
                                    integer: found.flatMap(ScriptExpression.integerTextCache) ?? defaultInteger)
                            } else {
                                let found = try candidate.lists[handle]!.value(for: string)
                                try candidate.results(string: found ?? defaultString,
                                    integer: try found.map(ScriptStringList.integerCache) ?? defaultInteger)
                            }
                        }
                        action = "query_table_candidate"
                    }
                case "fmt":
                    guard (2...32).contains(record.fields.count), record.fields.count % 2 == 0 else {
                        throw ResourceError.rejected("format_requires_bounded_pairs")
                    }
                    var formatted = ""
                    for i in stride(from: 0,to: record.fields.count,by: 2) {
                        func readOperand(_ slot: Int) throws -> ScriptValue {
                            try ScriptExpression.parse(field(slot)).evaluate(read: { try candidate.read($0) },write: { _,_ in
                                throw ResourceError.rejected("mutating_format_operand_outside_profile")
                            },readIndexed: { try candidate.readIndexed($0,$1) })
                        }
                        guard case .string(let format) = try readOperand(i) else { throw ResourceError.rejected("format_requires_string") }
                        formatted += try ScriptFormat.pair(format,readOperand(i+1))
                        guard formatted.utf8.count <= 8192 else { throw ResourceError.rejected("format_output_limit") }
                    }
                    try candidate.resultString(formatted); action = "format_pairs_candidate"
                case "vexs":
                    try arity(1)
                    guard case .name(let name) = try ScriptExpression.parse(field(0))
                    else { throw ResourceError.rejected("variable_exists_requires_bare_name") }
                    let category = candidate.lookupCategory(name)
                    try candidate.resultInteger(category); action = "variable_exists_category_candidate"
                case "cal", "if":
                    if command == "if" { try arity(1) }
                    else if !(1...32).contains(record.fields.count) {
                        throw ResourceError.rejected("calculate_operand_count_outside_profile")
                    }
                    var evaluated = ScriptValue.integer(0)
                    for slot in record.fields.indices {
                        let raw = try field(slot)
                        // The original cal dispatch advances past a null field (0x6b02b7).
                        if command == "cal", raw.isEmpty { continue }
                        if command == "cal", raw.hasSuffix("++") || raw.hasSuffix("--") {
                            guard case .name(let name) = try ScriptExpression.parse(String(raw.dropLast(2))) else {
                                throw ResourceError.rejected("calculate_update_requires_named_target")
                            }
                            try candidate.updateInteger(name,delta: raw.hasSuffix("++") ? 1 : -1)
                            evaluated = .integer(1)
                            continue
                        }
                        let expression = try ScriptExpression.parse(raw)
                        if command == "if", case .binary("=",_,_) = expression { throw ResourceError.rejected("assignment_condition_outside_profile") }
                        // Capturing a copy permits a single atomic command commit; not original-engine error behavior.
                        evaluated = try expression.evaluate(read: { try candidate.read($0) },write: { try candidate.write($0,$1) },
                            readIndexed: { try candidate.readIndexed($0,$1) },writeIndexed: { try candidate.writeIndexed($0,$1,$2) })
                    }
                    result = evaluated; action = "calculate"
                    if command == "if" {
                        guard let value = evaluated.integer, let block = program.blocks[pc], block.family == "if" else { throw ResourceError.rejected("if_type_or_structure_outside_profile") }
                        let thenMarkers = block.markers.filter { asciiLower(records[$0].command ?? "") == "then" }
                        let elseMarkers = block.markers.filter { asciiLower(records[$0].command ?? "") == "else" }
                        let significant = ((pc+1)..<block.end).first { ![ScriptRecordKind.bom,.layout,.empty].contains(records[$0].kind) }
                        guard thenMarkers.count <= 1, thenMarkers.isEmpty || significant == thenMarkers.first,
                              elseMarkers.count <= 1,
                              block.markers.count == thenMarkers.count + elseMarkers.count,
                              block.markers.allSatisfy({ records[$0].fields.isEmpty })
                        else { throw ResourceError.rejected("if_marker_shape_outside_profile") }
                        if value == 1 { candidate.frames[candidate.frames.count-1].controls.append(pc); action = "if_exact_one_true" }
                        else {
                            let destination = elseMarkers.first ?? block.end
                            next = destination+1; skip = try skipped((pc+1)..<next); action = "if_not_exact_one"
                            if !elseMarkers.isEmpty { candidate.frames[candidate.frames.count-1].controls.append(pc) }
                        }
                    }
                case "case":
                    try arity(1)
                    guard let block = program.blocks[pc], block.family == "case",
                          block.markers.allSatisfy({ ["of","ans","else"].contains(asciiLower(records[$0].command ?? "")) }) else {
                        throw ResourceError.rejected("case_marker_shape_outside_profile")
                    }
                    func readCaseOperand(_ raw: String) throws -> ScriptValue {
                        try ScriptExpression.parse(raw).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_case_operand") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                    }
                    let selector = try readCaseOperand(field(0))
                    var selected: Int?, fallback: Int?
                    for marker in block.markers {
                        let branch = records[marker]
                        if asciiLower(branch.command ?? "") == "else" {
                            guard fallback == nil, branch.fields.isEmpty, marker == block.markers.last else {
                                throw ResourceError.rejected("case_default_shape_outside_profile")
                            }
                            fallback = marker
                            continue
                        }
                        guard !branch.fields.isEmpty, branch.fields.allSatisfy({ $0.key == nil }) else {
                            throw ResourceError.rejected("case_branch_shape_outside_profile")
                        }
                        if selected != nil { continue }
                        for operand in branch.fields {
                            let match = try readCaseOperand(operand.raw)
                            switch (selector,match) {
                            case (.integer(let lhs),.integer(let rhs)):
                                if lhs == rhs { selected = marker }
                            case (.string(let lhs),.string(let rhs)):
                                if asciiLower(lhs).utf8.elementsEqual(asciiLower(rhs).utf8) { selected = marker }
                            default: throw ResourceError.rejected("case_operand_type_outside_profile")
                            }
                            if selected != nil { break }
                        }
                    }
                    if let destination = selected ?? fallback {
                        candidate.frames[candidate.frames.count-1].controls.append(pc)
                        next = destination+1
                    } else {
                        next = block.end+1
                    }
                    skip = try skipped((pc+1)..<next)
                    action = "case_dispatch_candidate"
                case "for":
                    guard let block = program.blocks[pc], block.family == "for",
                          block.markers.allSatisfy({ ["brk", "cnt"].contains(asciiLower(records[$0].command ?? "")) && records[$0].fields.isEmpty }) else {
                        throw ResourceError.rejected("for_control_markers_outside_profile")
                    }
                    let plan = try ScriptForPlan(record.fields)
                    if try plan.enter(&candidate) {
                        candidate.frames[candidate.frames.count-1].controls.append(pc)
                        candidate.frames[candidate.frames.count-1].forPlans[pc] = plan
                        action = "for_enter_candidate"
                    } else {
                        next = block.end+1; skip = try skipped((pc+1)..<next); action = "for_initial_condition_false"
                    }
                case "brk", "cnt":
                    try arity(0)
                    let frame = candidate.frames.count-1
                    guard let start = program.startsByMarker[pc], let block = program.blocks[start],
                          block.family == "for", candidate.frames[frame].forPlans[start] != nil,
                          let index = candidate.frames[frame].controls.lastIndex(of: start),
                          candidate.frames[frame].controls.dropFirst(index+1).allSatisfy({ program.blocks[$0]?.family == "if" })
                    else { throw ResourceError.rejected("loop_transfer_without_supported_loop") }
                    candidate.frames[frame].controls.removeSubrange((index+1)...)
                    if command == "brk" {
                        // 0x6b7139 selects the break path. Remove the loop
                        // without running its update at the end marker.
                        candidate.frames[frame].controls.removeLast()
                        candidate.frames[frame].forPlans.removeValue(forKey: start)
                        next = block.end + 1
                        action = "for_break_candidate"
                    } else {
                        next = block.end
                        action = "for_continue_to_update_candidate"
                    }
                    skip = try skipped((pc+1)..<next)
                case "then":
                    try arity(0)
                    guard candidate.frames.last?.controls.last == program.startsByMarker[pc] else { throw ResourceError.rejected("then_without_active_if") }
                    action = "then_marker"
                case "of", "ans", "else":
                    if command == "else" { try arity(0) }
                    guard let start = program.startsByMarker[pc], candidate.frames.last?.controls.last == start,
                          let block = program.blocks[start], block.family == "case" || (command == "else" && block.family == "if") else { throw ResourceError.rejected("branch_marker_without_active_block") }
                    candidate.frames[candidate.frames.count-1].controls.removeLast(); next = block.end+1
                    skip = try skipped((pc+1)..<next); action = block.family == "case" ? "case_skip_remaining_candidate" : "skip_else_after_true"
                case "end":
                    try arity(0)
                    guard let start = program.startsByEnd[pc], candidate.frames.last?.controls.last == start else { throw ResourceError.rejected("end_without_active_if") }
                    if program.blocks[start]?.family == "for" {
                        guard let plan = candidate.frames.last?.forPlans[start] else { throw ResourceError.rejected("for_plan_missing") }
                        if try plan.advance(&candidate) { next = start+1; action = "for_update_then_repeat" }
                        else {
                            candidate.frames[candidate.frames.count-1].controls.removeLast()
                            candidate.frames[candidate.frames.count-1].forPlans.removeValue(forKey: start); action = "for_update_then_exit"
                        }
                    } else {
                        candidate.frames[candidate.frames.count-1].controls.removeLast(); action = program.blocks[start]?.family == "case" ? "end_case_candidate" : "end_if"
                    }
                case "go":
                    try arity(2)
                    let file = try ScriptExpression.parse(field(1)).evaluate(read: { try candidate.read($0) },
                        write: { _,_ in throw ResourceError.rejected("mutating_go_operand_outside_profile") },
                        readIndexed: { try candidate.readIndexed($0,$1) })
                    guard case .string(let path) = file, !path.isEmpty, candidateRepository != nil else {
                        throw ResourceError.rejected("go_requires_module_path")
                    }
                    pendingModuleCandidates = try candidateRepository!.catalog.variants(for: path)
                    nextProgram = try candidateRepository!.load(path)
                    next = try nextProgram.label(callLabel())
                    guard nextProgram.ancestors[next].isEmpty else {
                        throw ResourceError.rejected("go_target_inside_control_block")
                    }
                    candidate.frames.removeSubrange(1...)
                    candidate.frames[0].controls.removeAll()
                    candidate.frames[0].forPlans.removeAll()
                    action = "module_go_candidate"
                case "sub", "subp", "jmp":
                    guard command != "jmp" ? (1...18).contains(record.fields.count) : (1...2).contains(record.fields.count)
                    else { throw ResourceError.rejected("unsupported_call_argument_slots") }
                    if record.fields.count >= 2 {
                        let raw = try field(1)
                        guard !raw.isEmpty || record.fields.count > 2 else { throw ResourceError.rejected("empty_module_field_mapping_not_verified") }
                        let file: String
                        if raw.isEmpty || asciiLower(raw) == "self" { file = "self" }
                        else {
                            let value = try ScriptExpression.parse(raw).evaluate(read: { try candidate.read($0) },write: { _,_ in
                                throw ResourceError.rejected("mutating_module_selector_outside_profile")
                            },readIndexed: { try candidate.readIndexed($0,$1) })
                            guard case .string(let string) = value else { throw ResourceError.rejected("non_string_module_selector") }
                            file = string
                        }
                        if asciiLower(file) != "self" {
                            guard candidateRepository != nil else { throw ResourceError.rejected("module_catalog_required") }
                            pendingModuleCandidates = try candidateRepository!.catalog.variants(for: file)
                            nextProgram = try candidateRepository!.load(file)
                        }
                    }
                    let label = try callLabel()
                    let destination = try nextProgram.label(label)
                    if command != "jmp" {
                        guard nextProgram.ancestors[destination].isEmpty else { throw ResourceError.rejected("call_target_inside_control_block") }
                        guard candidate.frames.count < maximumFrames else { throw ResourceError.rejected("call_frame_limit") }
                        var parameters = Array(repeating: Int32(0),count: 16)
                        var objectNames: [Data: UInt64] = [:]
                        var strings = Array(repeating: "",count: 16)
                        var arguments = try record.fields.indices.dropFirst(2).map { try field($0) }
                        if command == "subp" {
                            // The native subp path merges the tail before shared evaluation.
                            while arguments.last == "" { arguments.removeLast() }
                            if arguments.count > 1 { arguments = [arguments.joined(separator: ",")] }
                        }
                        for (slot, raw) in arguments.enumerated() {
                            if raw.isEmpty { continue }
                            let value = try ScriptExpression.parse(raw).evaluate(read: { try candidate.read($0) },
                                write: { _,_ in throw ResourceError.rejected("mutating_call_parameter_outside_profile") },
                                readIndexed: { try candidate.readIndexed($0,$1) })
                            switch value {
                            case .integer(let integer):
                                parameters[slot] = integer
                                strings[slot] = raw.hasPrefix("$") ? raw : String(integer)
                            case .string(let string):
                                guard string.utf8.count <= 8192 else { throw ResourceError.rejected("call_string_parameter_limit") }
                                strings[slot] = string
                                parameters[slot] = ScriptExpression.integerTextCache(string) ?? 0
                            case .object(let handle):
                                guard candidate.isAliasTarget(handle) else {
                                    throw ResourceError.rejected("object_call_parameter_outside_profile")
                                }
                                let name: String
                                switch try ScriptExpression.parse(raw) {
                                case .name(let identifier):
                                    name = identifier
                                case .indexed where candidate.messages[handle] != nil:
                                    // The message setup routine resolves ParamStr[0] to
                                    // an object alias. Capture the evaluated element here.
                                    name = raw
                                default:
                                    throw ResourceError.rejected("object_call_parameter_outside_profile")
                                }
                                strings[slot] = name
                                objectNames[Data(asciiLower(name).utf8)] = handle
                            }
                        }
                        candidate.frames.append(ScriptFrame(returnIndex: pc+1,returnProgram: program,entryLabel: label,parameterCount: Int32(arguments.count),integerParameters: parameters,objectParameterNames: objectNames,stringParameters: strings))
                        action = Data(nextProgram.document.source.relativePath.utf8) == Data(program.document.source.relativePath.utf8) ? "local_call" : "module_call"
                    } else {
                        let sameProgram = nextProgram.document.source.relativePath == program.document.source.relativePath
                        if sameProgram {
                            guard candidate.frames.last!.controls == program.ancestors[destination] else {
                                throw ResourceError.rejected("jump_crosses_control_scope")
                            }
                            action = "local_jump"
                        } else {
                            guard candidate.frames.last!.controls.isEmpty, nextProgram.ancestors[destination].isEmpty else {
                                throw ResourceError.rejected("jump_crosses_control_scope")
                            }
                            candidate.frames[candidate.frames.count-1].entryLabel = label
                            action = "module_jump_candidate"
                        }
                    }
                    next = destination
                case "ret":
                    try arity(0)
                    guard candidate.frames.count > 1, let destination = candidate.frames.last!.returnIndex else { throw ResourceError.rejected("root_return_outside_profile") }
                    guard let returnProgram = candidate.frames.last!.returnProgram else { throw ResourceError.rejected("missing_return_source_snapshot") }
                    nextProgram = returnProgram
                    action = Data(nextProgram.document.source.relativePath.utf8) == Data(program.document.source.relativePath.utf8) ? "local_return" : "module_return"
                    if stopCallbackFrameDepth == candidate.frames.count {
                        stopCallbackFrameDepth = nil
                        pendingButton = nil
                        pendingClick = false
                        callbackElapsedTicks = nil
                        pointerPosition = nil
                        if stopCallback != nil { phase = .waitingForEvent }
                    }
                    candidate.frames.removeLast(); next = destination
                default: throw ResourceError.rejected("unsupported_command")
                }
            default: throw ResourceError.rejected("unsupported_record_\(record.kind.rawValue)")
            }
            let nextRecords = nextProgram.document.records
            if target == nil, (next != oldPC+1 || Data(nextProgram.document.source.relativePath.utf8) != Data(program.document.source.relativePath.utf8)), next < nextRecords.count { target = nextRecords[next].location }
            storage = candidate; repository = candidateRepository; pc = next; program = nextProgram; pendingModuleCandidates = []
            if let result { lastResult = result }
            let item = trace(.inferred,action,target: target,skipped: skip,resultType: result?.typeName,resource: resourceLocation)
            recordTrace(item); return item
        } catch {
            if let failure = error as? ScriptTableFailure { resourceLocation = failure.location }
            stopReason = String(describing: error); phase = .stopped
            if stopReason == "ambiguous_module_variants", let variants = candidateRepository?.pendingVariants, !variants.isEmpty {
                pendingModuleCandidates = variants
            }
            let item = trace(.unsupported,"stop",reason: stopReason,resource: resourceLocation)
            recordTrace(item); return item
        }
    }
    private mutating func recordTrace(_ item: ScriptTrace) {
        executedSteps += 1
        traces.append(item)
        if !retainFullTrace, traces.count == 2048 {
            traces.removeFirst(1024)
        }
    }

}
