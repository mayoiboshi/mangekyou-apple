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

public enum ScriptMachinePhase: String, Encodable, Sendable { case ready, finished, stopped }

public struct ScriptMachineSummary: Encodable, Sendable {
    public let status: EvidenceStatus
    public let phase: ScriptMachinePhase
    public let profile = "experimental_static_contracts_v6"
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
    public private(set) var traces: [ScriptTrace] = []
    public private(set) var lastResult: ScriptValue?
    public private(set) var stopReason: String?
    public private(set) var pc: Int
    private var storage = ScriptStorage()
    private var repository: ScriptRepository?
    public private(set) var pendingModuleCandidates: [ScriptModuleReference] = []
    private let maximumSteps: Int
    private let maximumFrames: Int

    public init(program: ScriptProgram, allowExperimental: Bool, entryLabel: String? = nil,
                maximumSteps: Int = 10_000, maximumFrames: Int = 64, repository: ScriptRepository? = nil) throws {
        guard allowExperimental else { throw ResourceError.rejected("experimental_execution_not_enabled") }
        guard (1...100_000).contains(maximumSteps), (1...64).contains(maximumFrames) else { throw ResourceError.rejected("machine_limits") }
        self.maximumSteps = maximumSteps; self.maximumFrames = maximumFrames
        var pinnedRepository = repository
        let prepared = try pinnedRepository?.attachRoot(program) ?? program
        self.program = prepared; self.repository = pinnedRepository
        pc = try entryLabel.map { try prepared.label($0) } ?? 0
        if pc < prepared.ancestors.count, !prepared.ancestors[pc].isEmpty { throw ResourceError.rejected("entry_inside_control_block") }
    }

    public func value(named name: String) throws -> ScriptValue { try storage.read(name) }
    public var summary: ScriptMachineSummary {
        let records = program.document.records
        return ScriptMachineSummary(status: phase == .stopped ? .unsupported : .inferred,phase: phase,
            steps: traces.count,currentLocation: pc < records.count ? records[pc].location : nil,
            stopReason: stopReason,callDepth: storage.frames.count,
            variableCounts: ["system":storage.system.count,"global":storage.global.count,
                "all_local_frames":storage.frames.reduce(0) { $0+$1.locals.count }],
            moduleSnapshotCount: repository?.loadedModuleCount ?? 0,moduleSnapshotBytes: repository?.snapshotBytes ?? 0,
            sourceSnapshotCount: repository?.sourceSnapshotCount ?? 0,tableObjectCount: storage.tables.count,
            tableEntryCount: storage.tables.values.reduce(0) { $0+$1.count },
            tableSnapshots: storage.tables.keys.sorted().compactMap { storage.tables[$0]?.summary },
            listObjectCount: storage.lists.count,listLineCount: storage.lists.values.reduce(0) { $0+$1.lineCount },
            listSnapshots: storage.lists.keys.sorted().compactMap { storage.lists[$0]?.summary },trace: traces)
    }

    public mutating func run(stepQuota: Int = 10_000) throws {
        guard (1...100_000).contains(stepQuota) else { throw ResourceError.rejected("invalid_step_quota") }
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(10))
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
            ScriptTrace(sequence: traces.count+1,location: record.location,recordType: record.kind,command: safeCommand,
                commandSHA256: raw.map { Data($0.utf8).sha256Hex },status: status,action: action,reason: reason,
                target: target,callDepth: storage.frames.count,skipped: skipped,resultType: resultType,resource: resource)
        }
        guard traces.count < maximumSteps else { stopReason = "machine_total_step_limit"; phase = .stopped; return nil }
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
            case .bom, .layout, .empty, .label, .comment: break
            case .include:
                guard program.includesExpanded else { throw ResourceError.rejected("include_preprocessing_required") }
                action = "include_expansion_marker"
            case .command:
                guard let raw, safeCommand != nil else { throw ResourceError.rejected("invalid_command_identifier") }
                let command = asciiLower(raw)
                switch command {
                case "var", "gvar", "svar":
                    guard (2...129).contains(record.fields.count) else { throw ResourceError.rejected("declaration_field_count_limit") }
                    let type = asciiLower(try field(0))
                    var created = 0
                    for slot in 1..<record.fields.count {
                        let declaration = try ScriptExpression.parse(field(slot)), name: String, count: Int
                        switch declaration {
                        case .name(let raw): name = raw; count = 1
                        case .indexed(let raw, let coordinate):
                            guard ["int","str"].contains(type) else { throw ResourceError.rejected("object_array_outside_profile") }
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
                        guard case .object(let handle) = value, candidate.tables[handle] != nil || candidate.lists[handle] != nil
                        else { throw ResourceError.rejected("non_table_or_string_scope_selector_unverified") }
                        handles.append(handle)
                    }
                    candidate.frames[candidate.frames.count-1].tableScope = handles
                    action = sawEmpty ? "select_scope_empty_suffix_candidate" : "select_table_scope_candidate"
                case "l", "?v":
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
                            if candidate.tables[handle] != nil { candidate.tables[handle] = try ScriptTable(data: data,relativePath: reference.sourceFile) }
                            else { candidate.lists[handle] = try ScriptStringList(data: data,relativePath: reference.sourceFile) }
                        }
                        try candidate.validate(); action = "load_table_candidate"
                    } else {
                        var defaultString = "", defaultInteger: Int32 = 0
                        if record.fields.count == 2 {
                            let raw = try field(1), expression = try ScriptExpression.parse(raw)
                            if case .string(let text) = expression {
                                defaultString = text; defaultInteger = ScriptExpression.integerTextCache(text) ?? 0
                            } else {
                                guard raw.range(of: #"^-?(0|[1-9][0-9]*)$"#,options: .regularExpression) != nil,
                                      let value = try expression.evaluate(read: { try candidate.read($0) },write: { _,_ in
                                          throw ResourceError.rejected("mutating_table_default_outside_profile")
                                      },readIndexed: { try candidate.readIndexed($0,$1) }).integer
                                else { throw ResourceError.rejected("table_default_value_cache_unverified") }
                                defaultString = String(value); defaultInteger = value
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
                    try arity(1)
                    let expression = try ScriptExpression.parse(field(0))
                    if command == "if", case .binary("=",_,_) = expression { throw ResourceError.rejected("assignment_condition_outside_profile") }
                    // Capturing a copy permits a single atomic command commit; not original-engine error behavior.
                    let evaluated = try expression.evaluate(read: { try candidate.read($0) },write: { try candidate.write($0,$1) },
                        readIndexed: { try candidate.readIndexed($0,$1) },writeIndexed: { try candidate.writeIndexed($0,$1,$2) })
                    result = evaluated; action = "calculate"
                    if command == "if" {
                        guard let value = evaluated.integer, let block = program.blocks[pc], block.family == "if" else { throw ResourceError.rejected("if_type_or_structure_outside_profile") }
                        let thenMarkers = block.markers.filter { asciiLower(records[$0].command ?? "") == "then" }
                        let elseMarkers = block.markers.filter { asciiLower(records[$0].command ?? "") == "else" }
                        let significant = ((pc+1)..<block.end).first { ![ScriptRecordKind.bom,.layout,.empty].contains(records[$0].kind) }
                        guard thenMarkers.count == 1, significant == thenMarkers[0], elseMarkers.count <= 1,
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
                case "for":
                    guard let block = program.blocks[pc], block.family == "for", block.markers.isEmpty else {
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
                case "then":
                    try arity(0)
                    guard candidate.frames.last?.controls.last == program.startsByMarker[pc] else { throw ResourceError.rejected("then_without_active_if") }
                    action = "then_marker"
                case "else":
                    try arity(0)
                    guard let start = program.startsByMarker[pc], candidate.frames.last?.controls.last == start,
                          let block = program.blocks[start], block.family == "if" else { throw ResourceError.rejected("else_without_active_if") }
                    candidate.frames[candidate.frames.count-1].controls.removeLast(); next = block.end+1
                    skip = try skipped((pc+1)..<next); action = "skip_else_after_true"
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
                        candidate.frames[candidate.frames.count-1].controls.removeLast(); action = "end_if"
                    }
                case "sub", "jmp":
                    guard command == "sub" ? (1...2).contains(record.fields.count) : record.fields.count == 1
                    else { throw ResourceError.rejected("unsupported_call_argument_slots") }
                    if command == "sub", record.fields.count == 2 {
                        let raw = try field(1)
                        guard !raw.isEmpty else { throw ResourceError.rejected("empty_module_field_mapping_not_verified") }
                        let file: String
                        if asciiLower(raw) == "self" { file = "self" }
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
                    let destination = try nextProgram.label(field(0))
                    if command == "sub" {
                        guard nextProgram.ancestors[destination].isEmpty else { throw ResourceError.rejected("call_target_inside_control_block") }
                        guard candidate.frames.count < maximumFrames else { throw ResourceError.rejected("call_frame_limit") }
                        candidate.frames.append(ScriptFrame(returnIndex: pc+1,returnProgram: program))
                        action = Data(nextProgram.document.source.relativePath.utf8) == Data(program.document.source.relativePath.utf8) ? "local_call" : "module_call"
                    } else {
                        guard candidate.frames.last!.controls == program.ancestors[destination] else { throw ResourceError.rejected("jump_crosses_control_scope") }
                        action = "local_jump"
                    }
                    next = destination
                case "ret":
                    try arity(0)
                    guard candidate.frames.count > 1, let destination = candidate.frames.last!.returnIndex else { throw ResourceError.rejected("root_return_outside_profile") }
                    guard let returnProgram = candidate.frames.last!.returnProgram else { throw ResourceError.rejected("missing_return_source_snapshot") }
                    nextProgram = returnProgram
                    action = Data(nextProgram.document.source.relativePath.utf8) == Data(program.document.source.relativePath.utf8) ? "local_return" : "module_return"
                    candidate.frames.removeLast(); next = destination
                default: throw ResourceError.rejected("unsupported_command")
                }
            default: throw ResourceError.rejected("unsupported_record_\(record.kind.rawValue)")
            }
            let nextRecords = nextProgram.document.records
            if (next != oldPC+1 || Data(nextProgram.document.source.relativePath.utf8) != Data(program.document.source.relativePath.utf8)), next < nextRecords.count { target = nextRecords[next].location }
            storage = candidate; repository = candidateRepository; pc = next; program = nextProgram; pendingModuleCandidates = []
            if let result { lastResult = result }
            let item = trace(.inferred,action,target: target,skipped: skip,resultType: result?.typeName,resource: resourceLocation)
            traces.append(item); return item
        } catch {
            if let failure = error as? ScriptTableFailure { resourceLocation = failure.location }
            stopReason = String(describing: error); phase = .stopped
            if stopReason == "ambiguous_module_variants", let variants = candidateRepository?.pendingVariants, !variants.isEmpty {
                pendingModuleCandidates = variants
            }
            let item = trace(.unsupported,"stop",reason: stopReason,resource: resourceLocation)
            traces.append(item); return item
        }
    }
}
