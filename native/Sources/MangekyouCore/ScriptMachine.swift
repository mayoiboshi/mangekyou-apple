import Foundation

public struct ScriptControlBlock: Sendable {
    let start: Int
    let end: Int
    let family: String
    let markers: [Int]
    let conditionalElse: Int?
    let conditionalShapeSupported: Bool
}

public struct ScriptProgram: Sendable {
    public let document: ScriptDocument
    let sources: [Data: ScriptSource]
    let includesExpanded: Bool
    let labels: [Data: [Int]]
    let labelProgressAnchors: [Int?]
    let labelHistorySimpleSpans: [Bool]
    let blocks: [Int: ScriptControlBlock]
    let startsByEnd: [Int: Int]
    let startsByMarker: [Int: Int]
    let ancestors: [[Int]]
    let traceCommands: [Data: (safe: String?, sha256: String)]

    public init(_ document: ScriptDocument) throws {
        try self.init(document,sources: [:],includesExpanded: false)
    }
    init(_ originalDocument: ScriptDocument, sources: [Data: ScriptSource], includesExpanded: Bool) throws {
        var allSources = sources
        allSources[Data(originalDocument.source.relativePath.utf8)] = originalDocument.source
        let document = try Self.individualEmptyLines(originalDocument, sources: allSources)
        self.document = document
        self.sources = allSources; self.includesExpanded = includesExpanded
        var labels: [Data: [Int]] = [:], stack: [(start: Int, family: String, markers: [Int])] = []
        var blocks: [Int: ScriptControlBlock] = [:], ends: [Int: Int] = [:], markers: [Int: Int] = [:], ancestors: [[Int]] = []
        var traceCommands: [Data: (safe: String?, sha256: String)] = [:]
        for (i,record) in document.records.enumerated() {
            if let raw = record.command {
                let key = Data(raw.utf8)
                if traceCommands[key] == nil {
                    let safe = raw.range(of: #"^[A-Za-z?][A-Za-z_0-9?]{0,15}$"#, options: .regularExpression) == nil ? nil : raw
                    traceCommands[key] = (safe, key.sha256Hex)
                }
            }
            ancestors.append(stack.map(\.start))
            if record.kind == .label, let name = record.identifier { labels[Data(asciiLower(name).utf8),default: []].append(i) }
            guard record.kind == .command, let command = record.command else { continue }
            let token = asciiLower(command)
            if ["if","for","case"].contains(token) {
                stack.append((i,token,[]))
                guard stack.count <= 64 else { throw ResourceError.rejected("control_nesting_limit") }
            } else if token == "end" {
                guard let block = stack.popLast() else { throw ResourceError.rejected("unmatched_control_end_at_byte_\(record.location.byteOffset)") }
                var conditionalElse: Int?
                var conditionalShapeSupported = false
                if block.family == "if" {
                    let thenMarkers = block.markers.filter { asciiLower(document.records[$0].command ?? "") == "then" }
                    let elseMarkers = block.markers.filter { asciiLower(document.records[$0].command ?? "") == "else" }
                    let significant = ((block.start + 1)..<i).first {
                        ![ScriptRecordKind.bom, .layout, .empty].contains(document.records[$0].kind)
                    }
                    conditionalElse = elseMarkers.first
                    conditionalShapeSupported = thenMarkers.count <= 1 &&
                        (thenMarkers.isEmpty || significant == thenMarkers.first) && elseMarkers.count <= 1 &&
                        block.markers.count == thenMarkers.count + elseMarkers.count &&
                        block.markers.allSatisfy { document.records[$0].fields.isEmpty }
                }
                blocks[block.start] = ScriptControlBlock(start: block.start, end: i, family: block.family,
                    markers: block.markers, conditionalElse: conditionalElse,
                    conditionalShapeSupported: conditionalShapeSupported)
                ends[i] = block.start
            } else if ["brk", "cnt"].contains(token), let loop = stack.lastIndex(where: { $0.family == "for" }) {
                stack[loop].markers.append(i); markers[i] = stack[loop].start
            } else if ["then","else","of","ans","brk","cnt"].contains(token) {
                guard !stack.isEmpty else { throw ResourceError.rejected("unmatched_control_marker_at_byte_\(record.location.byteOffset)") }
                stack[stack.count-1].markers.append(i); markers[i] = stack.last!.start
            }
        }
        guard stack.isEmpty else { throw ResourceError.rejected("unterminated_control_block") }
        var progressAnchors: [Int?] = []
        var simpleSpans: [Bool] = []
        var currentAnchor: Int?
        var segmentHasInclude = false
        var segmentHasForeign = false
        for (index, record) in document.records.enumerated() {
            if record.kind == .label {
                currentAnchor = index
                segmentHasInclude = false
                segmentHasForeign = false
            } else if record.kind == .include {
                segmentHasInclude = true
            }
            progressAnchors.append(currentAnchor)
            if let anchor = currentAnchor {
                if record.location.sourceFile != document.records[anchor].location.sourceFile ||
                    record.location.sourceSHA256 != document.records[anchor].location.sourceSHA256 {
                    segmentHasForeign = true
                }
                simpleSpans.append(!segmentHasInclude && !segmentHasForeign)
            } else { simpleSpans.append(false) }
        }
        labelProgressAnchors = progressAnchors
        labelHistorySimpleSpans = simpleSpans
        self.traceCommands = traceCommands
        self.labels = labels; self.blocks = blocks; startsByEnd = ends; startsByMarker = markers; self.ancestors = ancestors
    }

    /// Lexical reports may group adjacent blank lines, but the reader advances
    /// one physical line at a time. Keep each execution record byte-pinned.
    private static func individualEmptyLines(_ document: ScriptDocument,
                                             sources: [Data: ScriptSource]) throws -> ScriptDocument {
        guard document.records.contains(where: { $0.kind == .empty && $0.lineCount > 1 }) else { return document }
        var records: [ScriptRecord] = []
        records.reserveCapacity(document.records.count)
        let clock = ContinuousClock(), started = ContinuousClock.now
        for record in document.records {
            guard !Task.isCancelled, clock.now - started < .seconds(15) else {
                throw ResourceError.rejected("script_empty_line_expansion_time_or_cancel_limit")
            }
            guard record.kind == .empty, record.lineCount > 1 else {
                records.append(record)
                continue
            }
            guard let source = sources[Data(record.location.sourceFile.utf8)],
                  source.sha256 == record.location.sourceSHA256 else {
                throw ResourceError.rejected("script_empty_line_source_unavailable")
            }
            let start = record.location.byteOffset, end = start + record.location.byteLength
            guard start >= 0, end <= source.data.count else {
                throw ResourceError.rejected("script_empty_line_range_outside_source")
            }
            var lo = 0, hi = source.scalars.count
            while lo < hi {
                let middle = lo + (hi - lo) / 2
                if source.scalars[middle].bytes.lowerBound < start { lo = middle + 1 } else { hi = middle }
            }
            var cursor = start, line = record.location.lineNumber, count = 0
            func appendLine(_ endOffset: Int) throws {
                guard cursor < endOffset, records.count < 200_000 else {
                    throw ResourceError.rejected("script_execution_record_limit")
                }
                records.append(ScriptRecord(kind: .empty, command: nil, identifier: nil, fields: [],
                    location: source.location(cursor..<endOffset, line: line), lineCount: 1))
                cursor = endOffset; line += 1; count += 1
            }
            while lo < source.scalars.count, source.scalars[lo].bytes.lowerBound < end {
                let scalar = source.scalars[lo]
                guard scalar.bytes.upperBound <= end else {
                    throw ResourceError.rejected("script_empty_line_scalar_boundary")
                }
                if scalar.value.value == 10 { try appendLine(scalar.bytes.upperBound) }
                lo += 1
            }
            if cursor < end { try appendLine(end) }
            guard cursor == end, count == record.lineCount else {
                throw ResourceError.rejected("script_empty_line_count_mismatch")
            }
        }
        guard records.count <= 200_000 else { throw ResourceError.rejected("script_execution_record_limit") }
        return ScriptDocument(expandedSource: document.source, records: records)
    }

    func label(_ raw: String) throws -> Int {
        guard raw.hasPrefix("@@"), !raw.hasPrefix("@@@"), raw.count > 2 else { throw ResourceError.rejected("dynamic_or_nonliteral_target") }
        let matches = labels[Data(asciiLower(String(raw.dropFirst(2))).utf8)] ?? []
        guard matches.count == 1 else { throw ResourceError.rejected(matches.isEmpty ? "unresolved_same_file_target" : "ambiguous_same_file_target") }
        return matches[0]
    }

    // A single, label-free include may be expanded into the reader's lines.
    // This is a research candidate, not a verified reader position.
    func candidateLabelRelativeLine(anchor: Int, position: Int) -> Int? {
        let records = document.records
        guard records.indices.contains(anchor), records.indices.contains(position), anchor <= position else { return nil }
        // The precomputed span proves this segment has no includes or
        // foreign-source records, so the full scan below cannot change it.
        if labelProgressAnchors[position] == anchor && labelHistorySimpleSpans[position] {
            let relative = records[position].location.lineNumber - records[anchor].location.lineNumber
            return relative >= 0 ? relative : nil
        }
        let span = records[anchor...position]
        let base = records[anchor].location, location = records[position].location
        let includes = span.filter { $0.kind == .include }
        let foreign = span.filter {
            $0.location.sourceFile != base.sourceFile || $0.location.sourceSHA256 != base.sourceSHA256
        }
        let sameSource = location.sourceFile == base.sourceFile && location.sourceSHA256 == base.sourceSHA256
        let physical = location.lineNumber - base.lineNumber
        if sameSource, physical < 0 { return nil }
        if includes.isEmpty && foreign.isEmpty { return physical }
        guard includes.count == 1, includes[0].location.sourceFile == base.sourceFile,
              includes[0].location.sourceSHA256 == base.sourceSHA256,
              !foreign.contains(where: { $0.kind == .include || $0.kind == .label }) else { return nil }
        let sources = Set(foreign.map { $0.location.sourceFile + "\u{0}" + $0.location.sourceSHA256 })
        guard sources.count <= 1 else { return nil }
        if !sameSource {
            guard sources.count == 1, location.lineNumber > 0,
                  includes[0].location.lineNumber > base.lineNumber else { return nil }
            return includes[0].location.lineNumber - base.lineNumber - 1 + location.lineNumber
        }
        var lines = 0, lastLine: Int?
        for record in foreign where record.kind != .bom && record.kind != .layout {
            let line = record.location.lineNumber
            guard line > 0, lastLine == nil || line >= lastLine! else { return nil }
            if let lastLine, line <= lastLine { continue }
            let count = record.kind == .empty ? record.lineCount : 1
            guard count > 0, line <= 100_000 - count + 1 else { return nil }
            lines += count
            lastLine = line + count - 1
        }
        return physical - 1 + lines
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

package struct StreamChannelTransition: Encodable, Sendable {
    package let step: Int
    package let location: ScriptLocation
    package let action: String
    package let before: [Int32]
    package let after: [Int32]
    package let swappedHandles: [UInt64]?
}

public struct ScriptSkippedSpan: Encodable, Sendable {
    public let status: EvidenceStatus = .notTested
    public let reason = "Not executed under the experimental branch model"
    public let location: ScriptLocation
    public let recordCount: Int
    public let recordTypes: [String: Int]
}

public struct ScriptSourceVisit: Encodable, Sendable {
    public let firstStep: Int
    public let firstLocation: ScriptLocation
    public var lastStep: Int
    public var lastLocation: ScriptLocation
    public var entries: Int
    public let status: EvidenceStatus = .inferred
}

public struct ScriptSourceCoverageEntry: Encodable, Sendable {
    public let location: ScriptLocation
    public let recordType: ScriptRecordKind
    public let firstStep: Int
    public var lastStep: Int
    public var executions: Int
    public let status: EvidenceStatus = .inferred
}

public struct ScriptSourceCoverage: Encodable, Sendable {
    public let sourceFile: String
    public let entries: [ScriptSourceCoverageEntry]
    public let truncated: Bool
}

/// Research-only comparison of local frame anchors with imported label-log keys.
package struct LabelHistoryProbe: Encodable, Sendable {
    package struct Frame: Encodable, Sendable {
        let depth: Int
        let programSource: ScriptLocation
        let position: ScriptLocation
        let nearestLabel: ScriptLocation?
        let eligibleLabel: Bool
        let readerEligibleLabel: Bool
        let uniqueLabel: Bool
        let logicalPathAvailable: Bool
        let keyMatchWithMarker: Bool?
        let keyMatchWithoutMarker: Bool?
        let candidateReadStatus: Int32?
        let candidateStoredLine: Int32?
        let relativeLine: Int?
    }
    let status: EvidenceStatus = .inferred
    let scope = "Local lexical frame anchors only; original reader mapping not_tested"
    let frames: [Frame]
}

package struct ResearchUnreadLabelQuery: Encodable, Sendable {
    let step: Int
    let location: ScriptLocation
    let probe: LabelHistoryProbe
}

package struct ResearchPlacementConflict: Encodable, Sendable {
    let location: ScriptLocation
    let elapsed: Int32
    let duration: Int32
    let requestedDuration: Int32
    let origin: [Int32]
    let previousTarget: [Int32]
    let requestedTarget: [Int32]
    let previousTransform: [Int32]?
    let requestedTransform: [Int32]
    let motionMode: UInt8?
    let motionStrength: Int32?
    let savedMode: UInt8?
}

public enum ScriptMachinePhase: String, Encodable, Sendable {
    case ready, waiting, waitingForEvent, waitingForFrame, waitingForMedia, waitingForSoundPosition, waitingForSoundSeek, waitingForSoundSwap, waitingForSoundFilter, waitingForSystemTask, waitingForScreenCapture, waitingForPrimarySave, finished, stopped
}

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
    public let saveWriteIssue: String?
    public let displayConfigurationHostStatus: EvidenceStatus
    public let displayRefreshRequested: Bool
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
    public let sourceVisits: [ScriptSourceVisit]?
    public let sourceVisitsTruncated: Bool?
    public let sourceCoverage: ScriptSourceCoverage?
}

/// Explicit opt-in required. Unknowns are terminal; they are never advanced past.
public struct ScriptMachine: Sendable {
    package struct ScriptStepFailure: Sendable {
        package let location: ScriptLocation
        package let programSourceFile: String
        package let programSourceSHA256: String
        package let programCounter: Int
        package let reason: String
    }
    private struct MacExceptionBackupContinuation: Sendable {
        let programSourceFile: String
        let programSourceSHA256: String
        let returnIndex: Int
        let returnFrameDepth: Int
        let failureReason: String
        var saveCommitted = false
        var saveIssue: String?
    }

    public private(set) var program: ScriptProgram
    public private(set) var phase: ScriptMachinePhase = .ready
    private let retainFullTrace: Bool
    package var allowLabelHistoryCandidate = false
    package var allowResearchVideoImageDimensions = false
    package private(set) var labelHistoryReadOutcomes: [String: Int] = [:]
    package private(set) var researchUnreadLabelQueries: [ResearchUnreadLabelQuery] = []
    package private(set) var researchUnreadLabelQueriesTruncated = false
    package var allowLabelProgressCandidate = false
    package var allowResearchSkipFrameCandidate = false
    package private(set) var researchSkipFrameSamples = 0
    package private(set) var researchPlacementConflict: ResearchPlacementConflict?
    package var allowResearchSkipTimeCandidate = false
    package var researchStopAtDrawBoundary = false
    package var researchPendingDrawCount: Int32? { storage.drawRequestCount }
    package private(set) var researchDrawZeroClockFrames = 0
    package private(set) var researchWaitZeroClockFrames = 0
    package var researchZeroWaitClockPending: Bool {
        (researchStopAtDrawBoundary || storage.researchSkipTime > 0) && (storage.engineField98 ?? 0) > 0
    }
    package var pendingResearchSkipTime: Int32 { storage.researchSkipTime }
    package private(set) var researchSkipTimeConsumed: Int64 = 0
    package private(set) var labelProgressCandidateOutcomes: [String: Int] = [:]
    package private(set) var labelProgressReturnOutcomes: [String: Int] = [:]
    package struct LabelProgressContext: Encodable, Sendable {
        let position: ScriptLocation
        let anchor: ScriptLocation?
        let programSource: ScriptLocation
        let callDepth: Int
    }
    package private(set) var labelProgressFirstContexts: [String: LabelProgressContext] = [:]
    package var allowImageFileLogCandidate = false
    package var allowAudioFileLogCandidate = false
    package private(set) var audioFileLogCandidateAttempts = 0
    package private(set) var audioFileLogCandidateOutcomes: [String: Int] = [:]
    package private(set) var imageFileLogCandidateAttempts = 0
    package private(set) var imageFileLogCandidateMatches = 0
    package private(set) var imageFileLogCandidateOutcomes: [String: Int] = [:]
    package private(set) var firstImageFileLogNoMatchSnapshot: FileLogPatternSnapshot?
    package private(set) var executedSteps = 0
    private var callDepthProbeMinimum: Int?
    package private(set) var streamChannelTransitions: [StreamChannelTransition] = []
    package private(set) var streamChannelTransitionsOmitted = 0
    public private(set) var traces: [ScriptTrace] = []
    public var captureSourceVisits = false
    private var sourceVisits: [String: ScriptSourceVisit] = [:]
    private var previousVisitSource: String?
    private var sourceVisitsTruncated = false
    public var coverageSourceFile: String?
    private var sourceCoverage: [ScriptLocation: ScriptSourceCoverageEntry] = [:]
    private var sourceCoverageTruncated = false
    public private(set) var lastResult: ScriptValue?
    public private(set) var stopReason: String?
    public private(set) var pc: Int
    package private(set) var scriptStepFailure: ScriptStepFailure?
    private var macExceptionBackupTestFailure: (programSourceSHA256: String, programCounter: Int, reason: String)?
    private var macExceptionBackupAttempted = false
    private var macExceptionBackupContinuation: MacExceptionBackupContinuation?
    private var storage = ScriptStorage()
    // CLI research only: expose enabled slider state while rendering and hit
    // testing remain explicitly unsupported. Normal execution stays strict.
    package var inspectUnrenderedBars = false
    package struct UnrenderedBarSnapshot: Encodable, Sendable {
        package let handle: UInt64
        package let resources: [ScriptLocation?]
        package let resourceLoadMode: Int32
        package let childVolumeType: Int32?
        package let trackEnableMotion: Int32?
        package let thumbEnableMotion: Int32?
        package let progressEnableMotion: Int32?
        package let placement: [Int32]
        package let placementSet: Bool
        package let value: Int32
        package let maximum: Int32
        package let locked: Bool
        package let lockStateChanged: Bool
        package let transitionStart: Int32
        package let transitionDuration: Int32
        package let transitionRemaining: Int32
        let rendering: EvidenceStatus = .unsupported
        let pointerInput: EvidenceStatus = .unsupported
    }
    package var unrenderedBarSnapshots: [UnrenderedBarSnapshot] {
        storage.bars.keys.sorted().compactMap { handle in
            guard let bar = storage.bars[handle], bar.enabled else { return nil }
            return .init(handle: handle, resources: bar.resources, resourceLoadMode: bar.resourceLoadMode,
                         childVolumeType: bar.childVolumeType, trackEnableMotion: bar.trackEnableMotion,
                         thumbEnableMotion: bar.thumbEnableMotion, progressEnableMotion: bar.progressEnableMotion,
                         placement: bar.placement, placementSet: bar.placementSet,
                         value: bar.value, maximum: bar.maximum, locked: bar.locked, lockStateChanged: bar.lockStateChanged,
                         transitionStart: bar.transitionStart,
                         transitionDuration: bar.transition, transitionRemaining: bar.transitionRemaining)
        }
    }

    package struct DialogueLogScrollbar: Encodable, Sendable {
        package static let trackWidth: Int32 = 34
        package static let trackHeight: Int32 = 528
        package static let knobWidth: Int32 = 24
        package static let knobHeight: Int32 = 47
        fileprivate let handle: UInt64
        package let track: ScriptLocation
        package let knob: ScriptLocation
        package let x: Int32
        package let y: Int32
        package let priority: Int32
        package let value: Int32
        package let maximum: Int32
        package let locked: Bool
        package let knobOffset: Int32
    }

    package var dialogueLogScrollbar: DialogueLogScrollbar? {
        guard isWaitingInDialogueLog, case .object(let handle) = try? storage.read("ScrollBar"),
              let bar = storage.bars[handle], bar.enabled, bar.resourceLoadMode == 1,
              bar.userStrings[0].map(asciiLower) == "@@!bar", bar.resources.count == 3,
              let knob = bar.resources[0], let track = bar.resources[1], bar.resources[2] == nil,
              knob.sourceSHA256 == "f4f238be53e65eddc88edea69066997baae63ca63ca4f0c409cd4010685dbc0f",
              track.sourceSHA256 == "49a4d1956f6081a3942a2c1bbe78e5f273f7994613c29546e03f6cd28c17c879",
              let placement = bar.placementSet ? bar.placement : bar.dialogueLogPlacement,
              let geometry = BarPointerGeometry(knobLength: DialogueLogScrollbar.knobHeight,
                                                trackLength: DialogueLogScrollbar.trackHeight, maximum: bar.maximum),
              let ratio = BarMotionSampling.animationTime(start: bar.transitionStart, target: bar.value,
                  maximum: bar.maximum, duration: max(0, bar.transition), remaining: bar.transitionRemaining,
                  animationDuration: 1, easing: .power) else { return nil }
        // The vertical branch at 0x67ec21 uses the interpolated ratio along the Y axis.
        let knobOffset = Int32((Float(geometry.end - geometry.start) * ratio).rounded(.toNearestOrEven))
        return .init(handle: handle, track: track, knob: knob, x: placement[0], y: placement[1], priority: placement[2],
                     value: bar.value, maximum: bar.maximum, locked: bar.locked, knobOffset: knobOffset)
    }

    @discardableResult
    package mutating func dispatchDialogueLogScrollbar(y: Int32) throws -> Bool {
        guard let scrollbar = dialogueLogScrollbar else {
            throw ResourceError.rejected("dialogue_log_scrollbar_unavailable")
        }
        guard !scrollbar.locked, scrollbar.maximum > 0,
              let geometry = BarPointerGeometry(knobLength: DialogueLogScrollbar.knobHeight,
                                                trackLength: DialogueLogScrollbar.trackHeight, maximum: scrollbar.maximum),
              let value = geometry.value(pointer: y, origin: scrollbar.y, rounding: .nearestEven),
              value != scrollbar.value else { return false }
        try dispatchStopCallback()
        // 0x67e41f sets the value; 0x67e424 marks it for the existing gsc callback.
        storage.bars[scrollbar.handle]?.movePointer(to: value, changeCycles: 4)
        return true
    }
    package func unrenderedBarSnapshot(named name: String) throws -> UnrenderedBarSnapshot {
        guard inspectUnrenderedBars, case .object(let handle) = try storage.read(name),
              let snapshot = unrenderedBarSnapshots.first(where: { $0.handle == handle }) else {
            throw ResourceError.rejected("unrendered_bar_not_available")
        }
        return snapshot
    }
    package var unrenderedButtonLineAdvanceCount: Int {
        storage.buttonText.values.reduce(0) { total, button in
            total + button.pendingOutput.filter {
                if case .directive("n", let operands) = $0 { return operands.count == 1 }
                return false
            }.count
        }
    }
    package func researchButtonTextOperationCounts(_ handle: UInt64) -> (pending: Int, committed: Int, text: Int, parameterizedNewlines: Int)? {
        guard let message = storage.buttonText[handle], storage.buttonTextBounds[handle] != nil else { return nil }
        let operations = message.committedOutput + message.pendingOutput
        return (message.pendingOutput.count, message.committedOutput.count,
                operations.filter { if case .text = $0 { return true }; return false }.count,
                operations.filter { if case .directive("n", let values) = $0 { return !values.isEmpty }; return false }.count)
    }
    package func researchButtonTextShape(_ handle: UInt64) -> (bounds: [Int32], operations: [String])? {
        guard let message = storage.buttonText[handle], let bounds = storage.buttonTextBounds[handle] else { return nil }
        let operations = message.committedOutput.map { operation in
            switch operation {
            case .text(let value): return "text_length:\(value.utf16.count)"
            case .ruby(let base, let annotation): return "ruby_lengths:\(base.utf16.count),\(annotation.utf16.count)"
            case .directive(let name, let operands): return name + ":" + operands.map(String.init).joined(separator: ",")
            }
        }
        return (bounds, operations)
    }
    private var directSoundLockMilliseconds: Int32?

    /// Opt in only when the host provides the game's sound-manager settings.
    public mutating func configureHeadlessDirectSound(channelCount: Int32, lockMilliseconds: Int32) throws {
        guard executedSteps == 0, (1...16).contains(channelCount), (0...60_000).contains(lockMilliseconds) else {
            throw ResourceError.rejected("direct_sound_configuration_outside_profile")
        }
        storage.directSoundChannelCount = channelCount
        directSoundLockMilliseconds = lockMilliseconds
    }
    private var saveDirectory: SafeDirectory?
    private var macExceptionBackupLiveWaitOverride: (remaining: Int32, initial: Int32, mode: UInt8, command: String, stopLabel: String?, commandIndex: Int)?
    private var inferSaveStateSeed = false
    private var saveHeaderTemplate: Data?
    private var saveSources: [Data: (name: String, sha256: String, verifyHeader: Bool)] = [:]
    package var saveImageFilterValidator: (@Sendable (ScriptLocation, String) throws -> Void)?
    package var researchVideoSaveProfiles: [String: ResearchVideoSaveProfile] = [:]
    // Internal so the publication/refresh failure boundary can be fault-injected in tests.
    struct SlotPublication: Sendable {
        let receipt: SafeDirectory.AtomicReplacementReceipt
        let name: String
        let sha256: String
        var systemDataSHA256: String? = nil
    }
    package struct PrimarySaveRequest: Sendable {
        package let priority: Int32
        package let name: String
        fileprivate var memoryOptions: Int32? = nil
        fileprivate var temporaryMode: Int32? = nil
        fileprivate var macSafetyBackupWithoutThumbnail = false
        fileprivate var temporary: Bool { temporaryMode != nil }
        package var needsThumbnail: Bool { memoryOptions == nil && !macSafetyBackupWithoutThumbnail }
        fileprivate let metadata: [String]
        fileprivate let resumeIndex: Int
    }
    package var allowPrimarySave = false
    package private(set) var primarySaveRequest: PrimarySaveRequest?
    var saveWriteHandler: (@Sendable (String, [String], ScriptStorage, String?) throws -> SlotPublication)?
    private struct SystemDataSaveTarget: Sendable {
        let name: String
        let headerTemplate: Data
        var sha256: String?
    }
    private var systemDataSaveTarget: SystemDataSaveTarget?
    package private(set) var lastSaveWriteIssue: String?
    package enum SavedDisplayPreview: Sendable {
        case externalImage(Data, SaveStatePrefix.DisplaySummary.Reload.Transform)
        case rectangle(SaveStatePrefix.DisplaySummary.ProceduralRect)
        case capturedSurface(Data)
    }

    package struct SavedDisplayDraw: Encodable, Sendable {
        package var interfaceBackgroundPreviews: [ScriptLocation]? = nil
        package var status: EvidenceStatus
        let width: Int?
        let height: Int?
        let pixelSHA256: String?
        package var issue: String?

        package struct OmittedLayer: Encodable, Sendable {
            let resource: ScriptLocation
            let reason: String

            package init(resource: ScriptLocation, reason: String) {
                self.resource = resource
                self.reason = reason
            }
        }

        let omittedLayers: [OmittedLayer]?
        let textIssues: [UInt64: String]?
        package struct Coverage: Encodable, Sendable {
            let rasterLayers: Int
            let motionLayers: Int
            let staticInterfaceFallbacks: Int
            let nonDrawingLayers: Int
            let nonDrawingReasons: [String: Int]
            let textLayers: Int
            let textLayersWithoutCoverage: Int

            package init(rasterLayers: Int, motionLayers: Int, staticInterfaceFallbacks: Int, nonDrawingLayers: Int,
                         nonDrawingReasons: [String: Int],
                         textLayers: Int, textLayersWithoutCoverage: Int) {
                self.rasterLayers = rasterLayers
                self.motionLayers = motionLayers
                self.staticInterfaceFallbacks = staticInterfaceFallbacks
                self.nonDrawingLayers = nonDrawingLayers
                self.nonDrawingReasons = nonDrawingReasons
                self.textLayers = textLayers
                self.textLayersWithoutCoverage = textLayersWithoutCoverage
            }
        }

        package var coverage: Coverage? = nil
        package var sceneVideoCandidateTicks: [Int32]? = nil
        package var savedLayerTimeCandidateCount: Int? = nil
        package struct SavedLayerTimeSample: Encodable, Sendable {
            let resource: ScriptLocation
            let selectedMember: Int32
            let keyOffsets: [Int]
            let advanceDelta: Int32?
            let advancedTimeSHA256: String?
            let advancedAuxiliarySHA256: String?
            package init(resource: ScriptLocation, selectedMember: Int32, keyOffsets: [Int],
                         advanceDelta: Int32? = nil, advancedTimeSHA256: String? = nil,
                         advancedAuxiliarySHA256: String? = nil) {
                self.resource = resource
                self.selectedMember = selectedMember
                self.keyOffsets = keyOffsets
                self.advanceDelta = advanceDelta
                self.advancedTimeSHA256 = advancedTimeSHA256
                self.advancedAuxiliarySHA256 = advancedAuxiliarySHA256
            }
        }
        package var savedLayerTimeSamples: [SavedLayerTimeSample]? = nil
        package struct ClippedRaster: Encodable, Sendable {
            let resource: ScriptLocation
            let scriptPosition: SIMD2<Int32>
            let alignmentPercent: SIMD2<Int32>
            let scalePercent: SIMD2<Int32>
            let origin: SIMD2<Double>
            let size: SIMD2<Double>

            package init(layer: StaticImageLayer, alignmentPercent: SIMD2<Int32>,
                         origin: SIMD2<Double>, size: SIMD2<Double>) {
                resource = layer.resource
                scriptPosition = SIMD2(layer.x, layer.y)
                self.alignmentPercent = alignmentPercent
                scalePercent = SIMD2(layer.scaleXPercent, layer.scaleYPercent)
                self.origin = origin
                self.size = size
            }
        }
        package var clippedRasters: [ClippedRaster]? = nil
        package struct UncoveredMotion: Encodable, Sendable {
            let resource: ScriptLocation
            let member: Int32
            let ticks: Int32
            let drawOffsets: [Int]

            package init(resource: ScriptLocation, member: Int32, ticks: Int32, drawOffsets: [Int]) {
                self.resource = resource
                self.member = member
                self.ticks = ticks
                self.drawOffsets = drawOffsets
            }
        }
        package var uncoveredMotions: [UncoveredMotion]? = nil
        package var transitionMidpointSHA256: String? = nil
        var transitionEndpointSHA256: [String]? = nil
        struct TransitionTiming: Encodable, Sendable {
            let duration: Int32
            let mode: UInt8?
            let power: Int32?
            let capturePriority: Int32
            let fadePriority: Int32?
            let sampleTicks: [Int32]?
            let sampleTimingStatus: EvidenceStatus
        }
        var transitionTiming: TransitionTiming? = nil
        var issueForTransitionPreview: String? = nil

        package init(status: EvidenceStatus, width: Int? = nil, height: Int? = nil,
                     pixelSHA256: String? = nil, issue: String? = nil,
                     omittedLayers: [OmittedLayer]? = nil, textIssues: [UInt64: String]? = nil) {
            self.status = status
            self.width = width
            self.height = height
            self.pixelSHA256 = pixelSHA256
            self.issue = issue
            self.omittedLayers = omittedLayers
            self.textIssues = textIssues
        }
    }

    private var savedDisplayPreview: SavedDisplayPreview?
    package func savedTextureBytes(_ source: ScriptLocation) -> Data? { storage.savedTextureData[source] }

    package var savedCapturedDisplay: Data? {
        if case .capturedSurface(let bytes) = savedDisplayPreview { return bytes }
        return nil
    }
    package var verifiedEmptyImageResourceCounts: (total: Int, active: Int) {
        guard let boundary = saveResumeBoundary else { return (0, 0) }
        let emptyOffsets = Set((boundary.savedImageResourceChecks ?? []).compactMap { check in
            check.resource.resolution == "empty_filename_and_no_serialized_texture_slots"
                ? check.objectDecodedOffset : nil
        })
        let active = (boundary.savedImageVisibility ?? []).count {
            $0.drawGate != 0 && $0.enableFlag != 0 && emptyOffsets.contains($0.objectDecodedOffset)
        }
        return (emptyOffsets.count, active)
    }
    package var compactSavedReplay = false
    package var inspectSaveRestoreBoundary = true
    package var savedMotionUpdateThreshold: (@Sendable (ScriptLocation) -> Int32?)?
    package var savedReplayStepLimit = 512
    package var savedAutoWaitClicks = 0
    package var savedDialogueClicks = 0
    package var clickAfterSavedMovie = false
    package var savedSoundDecodeHandler: (@Sendable (ScriptLocation, Int32?) throws -> Void)?
    package var savedMovieDecodeHandler: (@Sendable (MoviePlaybackRequest) throws -> Int32)?
    package enum SavedScenePass: Sendable {
        case scene
        case frozenLayerScene
        case capture(Int32)
        case overlapSample(Int32, elapsed: UInt32, duration: UInt32)
    }
    package var savedEventSampleTicks: Int32?
    package var savedFrozenLayerPreview = false
    package var savedSceneDrawHandler: (@Sendable (ScriptMachine, SavedScenePass) throws -> (SavedDisplayDraw, Data?))?
    package var savedOverlapPreviewSurface: Data? {
        guard storage.fadeInMode == 0, (storage.fadeInDuration ?? 0) > 0,
              storage.fadeInRule == nil, storage.fadeInAnimation == nil,
              storage.fadeTransform == [0, 0, 100, 100, 0] else { return nil }
        return replayEffectSurface
    }
    private var replayEffectSurface: Data?
    package var savedCaptureIsBound: Bool { replayEffectSurface != nil }
    package var savedCaptureFade: (priority: Int32, opacity: UInt8)? {
        guard savedOverlapPreviewSurface != nil, let priority = storage.effectCapturePriority,
              storage.fadeInPriority == priority, storage.fadeTiming?.mode == 1,
              storage.fadeTiming?.power == 100, let duration = storage.fadeInDuration,
              let start = storage.fadeInStartTick else { return nil }
        let remaining = Int64(duration) - (storage.visualTicks - start)
        guard remaining > 0 else { return nil }
        return (priority, UInt8(remaining * 255 / Int64(duration)))
    }
    package var savedDisplayDrawHandler: (@Sendable (SavedDisplayPreview) throws -> SavedDisplayDraw)?
    package var savedDisplayDrawReceipt: SavedDisplayDraw? {
        saveResumeBoundary?.isolatedContinuation?.previewDraw
    }

    package struct SaveResumeBoundary: Encodable, Sendable {
        var location: ScriptLocation? = nil
        var controlDepth: Int? = nil
        var instructionIndex: Int? = nil
        var isolatedCalculation: ScriptTrace? = nil
        var isolatedContinuation: SavedCalculationContinuation? = nil
        package var replaySceneDraw: SavedDisplayDraw? {
            guard let replay = isolatedContinuation else { return nil }
            let frames = [replay.sceneDraw, replay.textDraw, replay.eventFrame, replay.advancedEventFrame].compactMap { $0 }
            return frames.first { $0.status == .unsupported } ?? frames.last
        }
        var isolatedCallFrameStatus: EvidenceStatus? = nil
        var isolatedReturnScalarFrameCount: Int? = nil
        package var isolatedCallFrameIssue: String? = nil
        var isolatedActiveLoopStatus: EvidenceStatus? = nil
        var isolatedActiveLoopIssue: String? = nil
        var isolatedActiveControlStatus: EvidenceStatus? = nil
        var isolatedActiveControlIssue: String? = nil
        var cursorIssue: String? = nil
        let routineCount: Int
        let resultSnapshotCount: Int
        let controlBlockCount: Int
        var controlAlignment: ControlAlignment? = nil
        struct RoutineReturnCandidate: Encodable, Sendable {
            let routineOffset: Int
            let blockOffset: Int?
            let location: ScriptLocation?
            let instructionIndex: Int?
            let status: EvidenceStatus
            let resolution: String
            let scope: String
            let issue: String?
        }
        var routineReturnCandidates: [RoutineReturnCandidate]? = nil
        var loopReturnCandidates: [LoopReturnCandidate]? = nil
        var loopReturnCandidateOmittedCount: Int? = nil
        struct LoopReturnCandidate: Encodable, Sendable {
            let blockOffset: Int
            let location: ScriptLocation?
            let status: EvidenceStatus
            let issue: String?
        }
        struct ControlAlignment: Encodable, Sendable {
            let savedBlockOffsets: [Int]
            let staticBlockLocations: [ScriptLocation]
            let status: EvidenceStatus
            let issue: String?
        }
        let unresolvedResultObjectReferenceCount: Int
        var unresolvedResultButtonReferenceCount: Int? = nil
        package struct SoundResumeRequest: Encodable, Sendable {
            package let recordOffset: Int
            package let source: ScriptLocation
            package let minimumDecodedBytes: Int?
            let slotIndex: Int
            let startOffset: Int
            let looping: Bool
            let volumeInput: Int32
            let status: EvidenceStatus = .inferred
        }

        package var stagedSoundRequests: [SoundResumeRequest] {
            guard let statePrefix, let directSoundResources else { return [] }
            let sources = Dictionary(uniqueKeysWithValues: directSoundResources.compactMap { match in
                match.stagedLocation.map { (match.recordOffset, $0) }
            })
            return statePrefix.dsndReferences.enumerated().compactMap { slot, record in
                let offset = record.record.decodedOffset
                guard let source = sources[offset], let channel = record.directChannel,
                      let start = channel.requestedStartOffset, let looping = channel.loopingRequested else { return nil }
                return SoundResumeRequest(recordOffset: offset, source: source,
                                          minimumDecodedBytes: channel.minimumDecodedBufferBytes,
                                          slotIndex: slot, startOffset: start, looping: looping,
                                          volumeInput: channel.volumeInput)
            }
        }
        package var stagedStreamSeeks: [(recordOffset: Int, source: ScriptLocation, seconds: Double,
                                        milliseconds: Int32?, status: EvidenceStatus, issue: String?)] {
            (streamedSoundResources ?? []).compactMap { match in
                guard let source = match.stagedLocation, let seconds = match.requestedSeekSeconds,
                      let status = match.seekStatus else { return nil }
                return (match.recordOffset, source, seconds, match.requestedSeekMilliseconds, status, match.seekIssue)
            }
        }

        struct SavedSoundWait: Encodable, Sendable {
            let routineOffset: Int
            let channel: Int32
            let rawTarget: Int32
            let streamRecordOffset: Int?
            let status: EvidenceStatus
        }
        var savedSoundWaits: [SavedSoundWait]? = nil
        struct SavedTimedWait: Encodable, Sendable {
            let routineOffset: Int
            let remaining: Int32
            let skipTime: Int32
            let status: EvidenceStatus
        }
        var savedTimedWaits: [SavedTimedWait]? = nil
        struct EmbeddedImageCheck: Encodable, Sendable {
            let decodedOffset: Int
            let status: EvidenceStatus
            var width: Int? = nil
            var height: Int? = nil
            var issue: String? = nil
            var argbHeader: SaveStatePrefix.ARGBHeader? = nil
        }
        var imageLibraries: [SaveStatePrefix.ImageLibrarySummary]? = nil
        var savedDisplay: SaveStatePrefix.DisplaySummary? = nil
        struct DisplayResourceCheck: Encodable, Sendable {
            let status: EvidenceStatus
            var sourceSHA256: String? = nil
            var width: Int? = nil
            var height: Int? = nil
            var issue: String? = nil
        }
        var displayResourceCheck: DisplayResourceCheck? = nil
        struct NestedDisplayResourceCheck: Encodable, Sendable {
            let status: EvidenceStatus
            var sourceSHA256: String? = nil
            var sourceName: String? = nil
            var sourceNameSHA256: String? = nil
            var signature: String? = nil
            var resolution: String? = nil
            var issue: String? = nil
        }
        var nestedDisplayResourceCheck: NestedDisplayResourceCheck? = nil
        struct SavedButtonImageCheck: Encodable, Sendable {
            let objectDecodedOffset: Int
            let resource: NestedDisplayResourceCheck
        }
        var savedButtonImageChecks: [SavedButtonImageCheck]? = nil
        var savedImageResourceChecks: [SavedButtonImageCheck]? = nil
        var savedMessageResourceChecks: [SavedButtonImageCheck]? = nil
        struct SavedMessageTextCheck: Encodable, Sendable {
            let objectDecodedOffset: Int
            let status: EvidenceStatus
            let displayedUTF16Units: Int?
            let pendingUTF16Units: Int?
            let displayedOperationCount: Int?
            let pendingOperationCount: Int?
            let issue: String?
        }
        var savedMessageTextChecks: [SavedMessageTextCheck]? = nil
        struct SavedMessagePreview: Encodable, Sendable {
            let status: EvidenceStatus
            let scope = "partial isolated preview; not a restored execution candidate"
            let arrayCount: Int?
            let visibleTextLayerCount: Int?
            let draw: SavedDisplayDraw?
            let issue: String?
        }
        var savedMessagePreview: SavedMessagePreview? = nil
        struct SavedTextureBindingCheck: Encodable, Sendable {
            let objectOffset: Int
            let slot: Int
            let status: EvidenceStatus
            let issue: String?
        }
        var savedTextureBindings: [SavedTextureBindingCheck]? = nil
        var savedButtonSoundBindings: [SavedTextureBindingCheck]? = nil
        var savedImageStaticPlacements: [Int: SIMD3<Int32>]? = nil
        struct SavedImageVisibility: Encodable, Sendable {
            let objectDecodedOffset: Int
            let drawGateDecodedOffset: Int
            let enableFlagDecodedOffset: Int
            let drawGate: UInt8
            let enableFlag: UInt8
        }
        var savedImageVisibility: [SavedImageVisibility]? = nil
        var savedImageFixedRecords: [SaveReaderCursor.Reference]? = nil
        var embeddedImageChecks: [EmbeddedImageCheck]? = nil
        var displaySurfaceChecks: [EmbeddedImageCheck]? = nil
        var statePrefix: SaveStatePrefix?
        var directSoundResources: [SaveStatePrefix.SoundResourceMatch]?
        var streamedSoundResources: [SaveStatePrefix.SoundResourceMatch]?
        var variableArrays: SaveVariableArrays.Summary?
        var indexedScalarGroups: [IndexedScalarGroup]? = nil
        struct IndexedScalarGroup: Encodable, Sendable {
            let slot: Int
            let decodedOffset: Int
            let scalarCount: Int?
            let status: EvidenceStatus
            let issue: String?
        }
        var stagedRootResultScalarSnapshot: EvidenceStatus? = nil
        var rootResultScalarIssue: String? = nil
        var rootResultObjectChecks: [ScriptStorage.SavedResultObjectCheck]? = nil
        var inferredRootResultObjectMatchCount: Int? = nil
        var rootResultObjectIssue: String? = nil
        var stagedGlobalScalarCount: Int? = nil
        var globalScalarIssue: String? = nil
        var stagedGlobalListCount: Int? = nil
        var stagedGlobalTableCount: Int? = nil
        var stagedGlobalSoundAliasCount: Int? = nil
        var globalSoundAliasIssue: String? = nil
        var stagedGlobalObjectAliasCount: Int? = nil
        var globalObjectAliasIssue: String? = nil
        var unstagedGlobalObjectArrayCount: Int? = nil
        var stagedGlobalButtonIdentityArrayCount: Int? = nil
        var globalButtonIdentityIssue: String? = nil
        var stagedGlobalImageIdentityArrayCount: Int? = nil
        var stagedGlobalMessageIdentityArrayCount: Int? = nil
        var globalMessageIdentityIssue: String? = nil
        var stagedGlobalInactiveTimerArrayCount: Int? = nil
        var stagedGlobalActiveCallbackTimerArrayCount: Int? = nil
        var globalTimerIdentityIssue: String? = nil
        var globalImageIdentityIssue: String? = nil
        var isolatedStorageIssue: String? = nil
        var firstAbsentGlobalBindingOffset: Int? = nil
        var globalTextObjectIssue: String? = nil
        var engineState: SaveEngineState? = nil
        var stagedMemoryCheckpointCount: Int? = nil
        var stagedSystemNameSlotCount: Int? = nil
        var stateSeedInference: EvidenceStatus? = nil
        var slotHeaderVerification: EvidenceStatus? = nil
        var status: EvidenceStatus = .unsupported
    }
    package private(set) var saveResumeBoundary: SaveResumeBoundary?
    private var repository: ScriptRepository?
    private var calculationExpressions: [Data: ScriptExpression] = [:]

    private mutating func calculationExpression(_ text: String) throws -> ScriptExpression {
        let key = Data(text.utf8)
        if let cached = calculationExpressions[key] { return cached }
        let expression = try ScriptExpression.parse(text)
        if calculationExpressions.count < 4096, key.count <= 512 {
            calculationExpressions[key] = expression
        }
        return expression
    }
    public private(set) var pendingModuleCandidates: [ScriptModuleReference] = []
    package static let maximumFullSavedReplaySteps = 262_144
    package static let maximumCompactSavedReplaySteps = 524_288
    public static let maximumSupportedSteps = 96_000_000
    private let maximumSteps: Int
    private let maximumFrames: Int
    public private(set) var clickWaitRemaining: Int32?
    private var clickWaitInitial: Int32?
    private struct LogJumpCheckpoint: Sendable {
        let name: String
        let options: Int32
        let mode: Int32
        let storage: ScriptStorage
        let program: ScriptProgram
        let resumeIndex: Int
    }
    private var memoryCheckpoints: [Data: LogJumpCheckpoint] = [:]
    private var logJumpLimit = 16
    private struct TemporaryCheckpoint: Sendable {
        let key: Data
        let stream: Data?
    }
    private var logJumpCheckpoints: [TemporaryCheckpoint] = []
    private var linkedLogJumpCheckpoints: [TemporaryCheckpoint]?

    private var callbackElapsedTicks: Int32?
    private var pendingClick = false
    private var pendingLoadEscape = false
    private var pendingDialogueLogNavigation: DialogueLogNavigation?
    private var pendingDialogueLogWheel: Int32?
    private var syntheticBarCallbackActive = false
    private var pendingButton: UInt64?
    private var pointerPosition: (x: Int32, y: Int32)?
    // Last explicitly supplied host sample; it can outlive an event callback.
    private var lastPointerPosition: (x: Int32, y: Int32)?
    public private(set) var timedStopRequest: (duration: Int32, alternateDuration: Int32)?
    private var stopCallback: Int?
    private var stopCallbackFrameDepth: Int?
    package var researchStopCallbackRunning: Bool { stopCallbackFrameDepth != nil }
    private var timerReturn: (depth: Int, phase: ScriptMachinePhase, clickWait: Int32?, clickInitial: Int32?)?

    public var ticksUntilTimer: Int32? {
        guard timerReturn == nil else { return nil }
        return storage.timers.values.filter { $0.enabled && $0.callback != nil }
            .map { $0.interval - $0.elapsed }.min()
    }

    public mutating func dispatchDueTimer() throws -> Bool {
        guard timerReturn == nil, phase == .ready || phase == .waiting || phase == .waitingForEvent,
              let handle = storage.timers.keys.sorted().first(where: {
                  guard let timer = storage.timers[$0], timer.enabled, timer.callback != nil else { return false }
                  return timer.elapsed >= timer.interval
              }), let timer = storage.timers[handle], let callback = timer.callback else { return false }
        guard storage.frames.count < maximumFrames, timer.argument.isEmpty else {
            throw ResourceError.rejected("timer_callback_arguments_or_frame_limit")
        }
        storage.timers[handle]?.elapsed = 0
        storage.frames.append(ScriptFrame(returnIndex: pc, returnProgram: program, entryLabel: callback.label))
        timerReturn = (storage.frames.count, phase, clickWaitRemaining, clickWaitInitial)
        clickWaitRemaining = nil
        program = callback.program
        pc = callback.index
        phase = .ready
        return true
    }

    /// Remaining ticks to the next modeled placement endpoint.
    public var ticksUntilPlacementEndpoint: Int32? {
        storage.placementTransitions.values.map { $0.duration - $0.elapsed }.min()
    }

    /// Placement animations for which the native canvas can show intermediate positions.
    public var hasSampledPlacementTransition: Bool {
        storage.placementTransitions.contains { handle, transition in
            if let image = storage.images[handle] {
                guard image.isDrawable, image.resource != nil else { return false }
                if let savedMode = transition.savedMode { return savedMode == 1 || savedMode == 3 }
                return canStartFromTitle || image.motion?.mode == 3
            }
            return storage.enabledButtons.contains(handle)
                && (canStartFromTitle || storage.buttonMotion[handle]?.mode == 3)
        }
    }

    package func hasAdvancingImage(sourceSHA256: String) -> Bool {
        storage.images.values.contains {
            $0.isDrawable && $0.resource?.sourceSHA256 == sourceSHA256 &&
                $0.motionStartTick != nil && ($0.playbackSpeed ?? 100) > 0 &&
                !$0.standaloneVideoIsPaused(in: researchVideoSaveProfiles)
        }
    }

    public var pendingOpacityImages: Set<UInt64> {
        Set(storage.images.compactMap { handle, image in
            image.opacityEndpoint == nil ? nil : handle
        })
    }

    public var ticksUntilOpacityEndpoint: Int32? {
        storage.images.values.compactMap { $0.opacityEndpoint.map { max(1, $0.remaining) } }.min()
    }

    package var researchHasActiveTimers: Bool { storage.timers.values.contains { $0.enabled } }

    package func validateResearchChoiceWaitClock() throws {
        guard phase == .waiting, storage.researchSkipTime == 0,
              !researchZeroWaitClockPending, !storage.researchZeroClockHistoryUncertain,
              storage.linkedPrimaryPlayMode == nil,
              !storage.movies.values.contains(where: { ($0.remainingTicks ?? 0) > 0 }),
              storage.soundChannels.filter({ $0.value.playing }).keys.allSatisfy(ScriptStorage.isStreamHandle) else {
            throw ResourceError.rejected("research_choice_wait_clock_outside_profile")
        }
    }

    /// Explicit research frame: only the observed counter and existing headless clocks.
    package mutating func advanceResearchDrawFrame(ticks: Int32, allowObservedStreams: Bool = false,
                                                   consumePendingSkipTime: Bool = false,
                                                   allowObservedDirectSounds: Bool = false) throws {
        guard phase == .waitingForFrame, let count = storage.drawRequestCount, count > 0, ticks > 0,
              storage.linkedPrimaryPlayMode == nil else {
            throw ResourceError.rejected("draw_frame_invalid_state")
        }
        let pendingSkip = storage.researchSkipTime
        guard pendingSkip == 0 || (consumePendingSkipTime && allowResearchSkipTimeCandidate) else {
            throw ResourceError.rejected("draw_frame_pending_skip_time_unsupported")
        }
        let baseTicks: Int32 = (storage.engineField98 ?? 0) > 0 ? 0 : ticks
        let (effectiveTicks, overflow) = baseTicks.addingReportingOverflow(pendingSkip)
        guard !overflow, effectiveTicks <= 60_000 else { throw ResourceError.rejected("draw_frame_skip_time_limit") }
        guard !storage.researchZeroClockHistoryUncertain else {
            throw ResourceError.rejected("draw_frame_zero_history_unmodelled")
        }
        guard (storage.engineField98 ?? 0) >= 0 else { throw ResourceError.rejected("draw_frame_zero_clock_unsupported") }
        guard !storage.timers.values.contains(where: { $0.enabled }) else { throw ResourceError.rejected("draw_frame_active_timer_unsupported") }
        let activeAudio = storage.soundChannels.filter { $0.value.playing }
        guard activeAudio.keys.allSatisfy({ handle in
            (allowObservedStreams && ScriptStorage.isStreamHandle(handle)) ||
            (allowObservedDirectSounds && ScriptStorage.isDirectSoundHandle(handle))
        }) else { throw ResourceError.rejected("draw_frame_active_audio_unsupported") }
        guard !storage.movies.values.contains(where: { ($0.remainingTicks ?? 0) > 0 }) else { throw ResourceError.rejected("draw_frame_active_movie_unsupported") }
        if (storage.engineField98 ?? 0) > 0 {
            // 0x6ac25d...0x6ac270 clears +0x98 and zeroes the base
            // elapsed value before the pending-time field is applied.
            storage.engineField98 = 0
            researchDrawZeroClockFrames += 1
            // The skip-mode flag is sampled earlier in the same native update,
            // even when this later zero-clock branch suppresses elapsed time.
            if allowResearchSkipFrameCandidate {
                storage.researchSystemSkip = (3...5).contains(storage.systemPlayMode)
                researchSkipFrameSamples += 1
            }
            try advancePlacementClock(ticks: effectiveTicks)
        } else {
            try advancePlacementClock(ticks: effectiveTicks)
        }
        researchSkipTimeConsumed += Int64(pendingSkip)
        storage.researchSkipTime = 0
        storage.drawRequestCount = count > 1 ? count - 1 : nil
        if count == 1 { phase = .ready }
    }

    package var researchVisualTicks: Int64 { storage.visualTicks }

    /// Advance the headless visual clock to known endpoints.
    package mutating func consumeResearchWaitZeroClock(hostTicks: Int32, allowObservedStreams: Bool = false,
                                                       allowObservedTimers: Bool = false,
                                                       allowFreshTimedWait: Bool = false,
                                                       allowUntimedEventFrame: Bool = false) throws -> Int32 {
        guard hostTicks >= 0 else { throw ResourceError.rejected("zero_clock_negative_host_ticks") }
        // The caller of the fresh-timed-wait path must establish that the last
        // zero was executed in the same uninterrupted script continuation.
        let freshTimedZero = allowFreshTimedWait && isResearchMessageClickTimedWait && (storage.engineField98 ?? 0) > 0
        guard (researchZeroWaitClockPending || freshTimedZero), hostTicks > 0 else { return hostTicks }
        guard phase == .waiting || (phase == .waitingForEvent && (timedStopRequest != nil || allowUntimedEventFrame)),
              storage.linkedPrimaryPlayMode == nil else { throw ResourceError.rejected("zero_clock_wait_state_unsupported") }
        guard !storage.researchZeroClockHistoryUncertain else { throw ResourceError.rejected("zero_clock_history_unmodelled") }
        let pendingSkip = storage.researchSkipTime
        if pendingSkip != 0 {
            // The selected native update zeroes the base delta first and adds
            // +0x90 afterwards. Restrict this combined candidate to a finite
            // wait with no live timers or movies. Active streams require the
            // host's explicit identity-checked observation for this frame.
            let active = storage.soundChannels.filter { $0.value.playing }
            guard allowResearchSkipTimeCandidate,
                  (phase == .waiting || (phase == .waitingForEvent && timedStopRequest == nil && allowUntimedEventFrame)),
                  !storage.timers.values.contains(where: { $0.enabled }),
                  (active.isEmpty || (allowObservedStreams && active.keys.allSatisfy(ScriptStorage.isStreamHandle))),
                  !storage.movies.values.contains(where: { ($0.remainingTicks ?? 0) > 0 }) else {
                throw ResourceError.rejected("zero_clock_pending_skip_time_unsupported")
            }
        }
        guard allowObservedTimers || !storage.timers.values.contains(where: { $0.enabled }) else {
            throw ResourceError.rejected("zero_clock_active_timer_unsupported")
        }
        let activeAudio = storage.soundChannels.filter { $0.value.playing }
        guard activeAudio.isEmpty || (allowObservedStreams && activeAudio.keys.allSatisfy(ScriptStorage.isStreamHandle)) else {
            throw ResourceError.rejected("zero_clock_active_audio_unsupported")
        }
        guard !storage.movies.values.contains(where: { ($0.remainingTicks ?? 0) > 0 }) else { throw ResourceError.rejected("zero_clock_active_movie_unsupported") }
        // 0x6ac25d...0x6ac270 clears +0x98 and zeroes the base elapsed
        // amount; the separate mode flag is sampled earlier in this update.
        storage.engineField98 = 0
        researchWaitZeroClockFrames += 1
        if allowResearchSkipFrameCandidate {
            storage.researchSystemSkip = (3...5).contains(storage.systemPlayMode)
            researchSkipFrameSamples += 1
        }
        researchSkipTimeConsumed += Int64(pendingSkip)
        storage.researchSkipTime = 0
        return pendingSkip
    }

    package mutating func consumeResearchSkipTime(hostTicks: Int32) throws -> Int32 {
        guard hostTicks >= 0 else { throw ResourceError.rejected("negative_placement_ticks") }
        guard allowResearchSkipTimeCandidate, hostTicks > 0, storage.researchSkipTime > 0 else { return hostTicks }
        guard phase == .waiting, storage.linkedPrimaryPlayMode == nil else {
            throw ResourceError.rejected("skip_time_scheduler_unsupported")
        }
        guard !storage.timers.values.contains(where: { $0.enabled }) else {
            throw ResourceError.rejected("skip_time_active_timer_unsupported")
        }
        guard !storage.soundChannels.values.contains(where: { $0.playing }) else {
            throw ResourceError.rejected("skip_time_active_audio_unsupported")
        }
        guard !storage.movies.values.contains(where: { ($0.remainingTicks ?? 0) > 0 }) else {
            throw ResourceError.rejected("skip_time_active_movie_unsupported")
        }
        let (total, overflow) = hostTicks.addingReportingOverflow(storage.researchSkipTime)
        guard !overflow else { throw ResourceError.rejected("skip_time_overflow") }
        researchSkipTimeConsumed += Int64(storage.researchSkipTime)
        storage.researchSkipTime = 0
        return total
    }

    public mutating func advancePlacementClock(ticks: Int32) throws {
        guard ticks >= 0 else { throw ResourceError.rejected("negative_placement_ticks") }
        if ticks > 0, allowResearchSkipFrameCandidate, (storage.engineField98 ?? 0) > 0 {
            // This generic host path has not modelled the native zero branch.
            storage.researchZeroClockHistoryUncertain = true
        }
        if allowResearchSkipFrameCandidate, ticks > 0, storage.linkedPrimaryPlayMode == nil {
            // 0x6abb12...0x6abb71 resets the flag and sets it for modes 3...5.
            // This candidate assumes the separate context flag is clear and
            // does not model the remaining native flag writers.
            storage.researchSystemSkip = (3...5).contains(storage.systemPlayMode)
            researchSkipFrameSamples += 1
        }
        advanceTimerClock(ticks: ticks)
        for (handle, var movie) in storage.movies {
            if let remaining = movie.remainingTicks, remaining > 0 {
                movie.remainingTicks = max(0, remaining - ticks)
                storage.movies[handle] = movie
            }
        }
        advanceVisualClock(ticks: ticks)
    }

    package mutating func advanceTimerClock(ticks: Int32) {
        guard ticks > 0 else { return }
        for (handle, var timer) in storage.timers {
            let elapsed = timer.enabled ? timer.elapsed + min(ticks, timer.interval - timer.elapsed) : 0
            if elapsed != timer.elapsed {
                timer.elapsed = elapsed
                storage.timers[handle] = timer
            }
        }
    }

    public mutating func advanceVisualClock(ticks: Int32) {
        guard ticks > 0 else { return }
        let previousVisualTicks = storage.visualTicks
        let advancedTicks = min(Int64(ticks), Int64.max - storage.visualTicks)
        storage.visualTicks += advancedTicks
        let generatorDelta = UInt32(truncatingIfNeeded: ticks)
        for (handle, var image) in storage.images where image.enabled &&
            (!image.generatorRequests.isEmpty || image.generatorFilterModeClock != nil) {
            for (index, var request) in image.generatorRequests {
                request.currentTime = (request.currentTime &+ generatorDelta) & 0x0fff_ffff
                image.generatorRequests[index] = request
            }
            image.advanceGeneratorFilterModeClock(generatorDelta)
            storage.images[handle] = image
        }
        for (handle, var image) in storage.images {
            guard let snapshot = image.savedLayerTimeSnapshot,
                  snapshot.visualTick == previousVisualTicks else { continue }
            if !image.enabled || image.selectedMember == nil ||
               (!image.isTheoraResource && !image.hasExtendedContainerMetadata && image.resource != nil && image.memberCount <= 1) {
                // 0x5ab268 skips motion updates while disabled. An object with
                // no selected action has no layer clock to advance either.
                image.savedLayerTimeSnapshot = .init(times: snapshot.times, auxiliary: snapshot.auxiliary,
                                                     visualTick: storage.visualTicks)
                storage.images[handle] = image
                continue
            }
            let nativeVideoDuration = image.canUseStandaloneVideoClock &&
                image.researchVideoProfile(in: researchVideoSaveProfiles) == nil ? image.standaloneVideoDuration : nil
            // ps writes manager +0x440. The normal layer update reads +0x43c,
            // which receives the animation speed independently of ps.
            guard (0...3_000).contains(image.animationSpeed ?? 100),
                  image.hasIndependentActionClock || (image.playbackSpeed ?? 100) == 100,
                  let resource = image.resource, let action = image.selectedMember,
                  nativeVideoDuration != nil || imageLayerClockAdvance != nil else { continue }
            let cycle = nativeVideoDuration != nil ? 1 : max(1, savedMotionUpdateThreshold?(resource) ?? 1)
            let speed = Float(Double(image.animationSpeed ?? 100) * 0.01)
            let scaled = Float(Double(Float(ticks)) * Double(speed) + Double(image.layerClockRemainder))
            guard scaled.isFinite, (0...1_000_000_000).contains(scaled) else { continue }
            let effectiveDelta: Float
            if scaled < Float(cycle) {
                image.layerClockRemainder = scaled
                effectiveDelta = 0
            } else if cycle == 1 {
                image.layerClockRemainder = 0
                effectiveDelta = scaled
            } else {
                let rounded = Int64(scaled.rounded(.toNearestOrEven))
                let quantized = (rounded / Int64(cycle)) * Int64(cycle)
                effectiveDelta = Float(quantized)
                image.layerClockRemainder = Float(Double(scaled) - Double(effectiveDelta))
            }
            var remaining = effectiveDelta
            var times = snapshot.times
            var auxiliary = snapshot.auxiliary
            var canAdvance = true
            while remaining > 0 {
                // 0x57fcf0 calls the layer updater in 50-tick quanta, then
                // makes one final call for the residual delta.
                let delta = min(remaining, 50)
                let advanced: (times: [Int32], auxiliary: [Int32])?
                if let duration = nativeVideoDuration, action == 0, let step = Int32(exactly: delta) {
                    advanced = StandaloneVideoClockCandidate.advance(times: times, auxiliary: auxiliary,
                                                                     delta: step, duration: duration)
                } else {
                    advanced = imageLayerClockAdvance?(resource, action, times, auxiliary, delta)
                }
                guard let advanced else {
                    canAdvance = false
                    break
                }
                times = advanced.times
                auxiliary = advanced.auxiliary
                remaining -= delta
            }
            guard canAdvance else { continue }
            image.savedLayerTimeSnapshot = .init(times: times, auxiliary: auxiliary,
                                                 visualTick: storage.visualTicks)
            storage.images[handle] = image
        }
        for (handle, var message) in storage.messages {
            if let threshold = message.backgroundRestoredMotionThreshold,
               message.backgroundMotionStartTick != nil {
                message.backgroundRestoredMotionRemainder += Int64(ticks) * Int64(message.backgroundPlaybackSpeed)
                if message.backgroundRestoredMotionRemainder >= threshold {
                    message.backgroundMotionElapsedBeforeSpeedChange = min(
                        message.backgroundMotionElapsedBeforeSpeedChange + message.backgroundRestoredMotionRemainder,
                        Int64(Int32.max) * 100)
                    message.backgroundRestoredMotionRemainder = 0
                }
                storage.messages[handle] = message
            }
            guard let snapshot = message.backgroundSavedLayerTimeSnapshot,
                  snapshot.visualTick == previousVisualTicks else { continue }
            if !message.enabled || message.backgroundSelectedMember == nil ||
               (!message.backgroundHasExtendedContainerMetadata && message.background != nil &&
                message.backgroundMemberCount <= 1) {
                message.backgroundSavedLayerTimeSnapshot = .init(times: snapshot.times,
                    auxiliary: snapshot.auxiliary, visualTick: storage.visualTicks)
                storage.messages[handle] = message
                continue
            }
            guard let resource = message.background, let action = message.backgroundSelectedMember,
                  let imageLayerClockAdvance else { continue }
            var remaining = Int64(ticks)
            var times = snapshot.times
            var auxiliary = snapshot.auxiliary
            var canAdvance = true
            while remaining > 0 {
                let delta = Float(min(remaining, 50))
                guard let advanced = imageLayerClockAdvance(resource, action, times, auxiliary, delta) else {
                    canAdvance = false
                    break
                }
                times = advanced.times
                auxiliary = advanced.auxiliary
                remaining -= Int64(delta)
            }
            guard canAdvance else { continue }
            message.backgroundSavedLayerTimeSnapshot = .init(times: times, auxiliary: auxiliary,
                visualTick: storage.visualTicks)
            storage.messages[handle] = message
        }
        for handle in storage.buttons {
            guard var snapshot = storage.buttonSavedLayerTimeSnapshots[handle],
                  snapshot.visualTick == previousVisualTicks else { continue }
            if !storage.enabledButtons.contains(handle) || storage.buttonSelectedMembers[handle] == nil ||
               (!storage.buttonHasExtendedContainerMetadata.contains(handle) &&
                storage.buttonResources[handle] != nil && storage.buttonResourceMemberCounts[handle, default: 0] <= 1) {
                storage.buttonSavedLayerTimeSnapshots[handle] = .init(times: snapshot.times,
                    auxiliary: snapshot.auxiliary, visualTick: storage.visualTicks)
                continue
            }
            guard let resource = storage.buttonResources[handle],
                  let action = storage.buttonSelectedMembers[handle], let imageLayerClockAdvance else { continue }
            var remaining = Int64(ticks)
            var times = snapshot.times
            var auxiliary = snapshot.auxiliary
            var canAdvance = true
            while remaining > 0 {
                let delta = Float(min(remaining, 50))
                guard let advanced = imageLayerClockAdvance(resource, action, times, auxiliary, delta) else {
                    canAdvance = false
                    break
                }
                times = advanced.times
                auxiliary = advanced.auxiliary
                remaining -= Int64(delta)
            }
            guard canAdvance else { continue }
            snapshot = .init(times: times, auxiliary: auxiliary, visualTick: storage.visualTicks)
            storage.buttonSavedLayerTimeSnapshots[handle] = snapshot
        }
        // Disabled objects in these profiles skip the update. At zero animation speed, the
        // native manager scales ticks before advancing either clock.
        for (handle, var image) in storage.images
            where (image.isTheoraResource || image.hasIndependentActionClock) && image.restoredMotionThreshold == nil {
            guard !image.enabled || image.standaloneVideoIsPaused(in: researchVideoSaveProfiles) else { continue }
            if let start = image.motionStartTick {
                image.motionStartTick = start + advancedTicks
                storage.images[handle] = image
            }
        }
        advanceOpacityClock(ticks: ticks)
        for (handle, var bar) in storage.bars {
            // 0x67def4 reduces the transition countdown during an object update.
            if bar.transitionRemaining != 0 {
                bar.transitionRemaining = bar.transitionRemaining > 0
                    ? bar.transitionRemaining - min(ticks, bar.transitionRemaining) : 0
                storage.bars[handle] = bar
            }
        }
        for (handle, var image) in storage.images where image.restoredMotionThreshold != nil {
            image.advanceRestoredMotion(ticks: ticks)
            storage.images[handle] = image
        }
        for (handle,var transition) in storage.placementTransitions {
            transition.elapsed += min(ticks,transition.duration-transition.elapsed)
            if transition.elapsed == transition.duration {
                if storage.buttons.contains(handle) {
                    storage.buttonPlacement[handle] = transition.destination
                } else {
                    storage.images[handle]?.placement = transition.destination
                    if let transform = transition.destinationTransform {
                        storage.images[handle]?.transform = transform
                    }
                }
                storage.placementTransitions.removeValue(forKey: handle)
            } else {
                storage.placementTransitions[handle] = transition
            }
        }
    }

    public mutating func advanceOpacityClock(ticks: Int32) {
        guard ticks > 0 else { return }
        for (handle, var image) in storage.images where image.opacityEndpoint != nil {
            image.advanceOpacity(ticks: ticks)
            storage.images[handle] = image
        }
    }

    public var movieStopRemaining: Int32? {
        guard phase == .waitingForEvent, stopCallbackFrameDepth == nil,
              stopCallback != nil, stopCallback == (try? program.label("@@!Avg_MovieOnStopEvent")),
              case .object(let handle) = try? storage.read("Avg_TheoraMovie") else { return nil }
        return storage.movies[handle]?.remainingTicks
    }

    package var researchStopCallbackLocation: ScriptLocation? {
        guard phase == .waitingForEvent, stopCallbackFrameDepth == nil, let callback = stopCallback,
              program.document.records.indices.contains(callback) else { return nil }
        return program.document.records[callback].location
    }

    public var hasScopedStop: Bool {
        phase == .waitingForEvent && stopCallback != nil && stopCallbackFrameDepth == nil &&
            storage.frames.last?.controls.isEmpty == false
    }

    package var researchMessageWaitPlayMode: Int32 {
        storage.selectsPrimaryScriptSource ? storage.linkedPrimaryPlayMode ?? storage.systemPlayMode : storage.systemPlayMode
    }

    package var researchMessageWaitPendingCount: Int {
        storage.messages.values.filter { !$0.pendingOutput.isEmpty }.count
    }

    package struct ResearchStreamScopeObservation: Encodable {
        package let channel: Int32
        package let status: Int32
        package let source: ScriptLocation?
        package let playbackStartStep: Int?
    }

    package var researchStreamScopeObservation: ResearchStreamScopeObservation? {
        guard storage.frames.last?.tableScope.count == 1,
              let handle = storage.frames.last?.tableScope.first,
              let index = Self.streamSaveChannelIndex(handle) else { return nil }
        let channel = storage.soundChannels[handle]
        let status: Int32 = channel?.playing == true ? (channel?.loopRequest == -1 ? 2 : 1) : 0
        return .init(channel: index, status: status, source: channel?.resource,
                     playbackStartStep: channel?.playbackStartStep)
    }

    package var isResearchMessageTextWait: Bool {
        hasScopedStop && stopCallback == (try? program.label("@@!Imo_MesWaitTextOnStop")) &&
            timedStopRequest == nil && !isWaitingForStoryChoice
    }

    package var isResearchMessageAutoWait: Bool {
        hasScopedStop && stopCallback == (try? program.label("@@!Imo_MesWaitAutoOnStop")) &&
            timedStopRequest == nil && !isWaitingForStoryChoice
    }

    package var isResearchMessageClickTimedWait: Bool {
        phase == .waitingForEvent && stopCallbackFrameDepth == nil && timedStopRequest != nil &&
            stopCallback == (try? program.label("@@!Imo_ClickWait")) && !isWaitingForStoryChoice
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

    /// Present the audited center-text action during its timed wait without dispatching the stop callback.
    public mutating func commitTimedCenterText() throws -> Bool {
        guard timedStopRequest != nil else { return false }
        let handles = storage.messages.keys.filter { handle in
            guard let message = storage.messages[handle] else { return false }
            return message.enabled && !message.pendingOutput.isEmpty && message.usesTimedCenterText
        }
        guard !handles.isEmpty else { return false }
        var messages = storage.messages
        for handle in handles {
            try messages[handle]?.commitOutput()
        }
        storage.messages = messages
        return true
    }

    public struct StaticImageLayer: Sendable {
        public let id: UInt64
        public let resource: ScriptLocation
        public let x: Int32
        public let y: Int32
        public let priority: Int32
        public let selectedMember: Int32?
        public let motionElapsedTicks: Int32?
        public let motionIsAdvancing: Bool
        public let opacity: UInt8
        public let scaleXPercent: Int32
        public let scaleYPercent: Int32
        public let hoverResource: ScriptLocation?
        public let boundRasterPreview: ScriptLocation?
        public let hasExplicitAlignment: Bool
        public let alignmentXPercent: Int32
        public let alignmentYPercent: Int32
        public let textureFilter: Int32?
        public let unappliedTransform: Bool
        public let drawChannel: Int32?
        public var fractionalScalePercent: SIMD2<Float>? = nil
        public var isTheoraResource = false
        package var researchVideoLayerTicks: Int32? = nil
        package var standaloneVideoLayerTicks: Int32? = nil
        package var researchButtonChecked: Bool? = nil
        package var researchButtonLocked: Bool? = nil
        package var boundTextureLocations: [Int32: ScriptLocation] = [:]
        package var savedLayerTimeCandidate: [Int32]? = nil
        package var savedLayerAuxiliaryCandidate: [Int32]? = nil
        package var filterOverrides: [Int32: String] = [:]
    }

    /// State for the audited window animation's effect on separately drawn controls.
    public var dialogueWindowMotion: (closing: Bool, ticks: Int32, advancing: Bool)? {
        for image in storage.images.values {
            guard image.isDialogueWindowAnimation,
                  image.selectedMember == (image.enabled ? 0 : 1),
                  let elapsed = image.motionElapsedHundredths(at: storage.visualTicks),
                  elapsed < 100_000 else { continue }
            return (!image.enabled, Int32(elapsed / 100), (image.playbackSpeed ?? 100) > 0)
        }
        return nil
    }

    public func imageLoadLocation(_ id: UInt64) -> ScriptLocation? {
        storage.images[id]?.resourceLoadLocation
    }

    package func particleRandomTable() throws -> Data? {
        guard var repository else { throw ResourceError.rejected("particle_table_catalog_required") }
        let path = "system/etc/RandomTable.dat"
        if try repository.catalog.isIndexed(path) || !repository.catalog.variants(for: path).isEmpty {
            return try repository.readResource(path, byteLimit: 4096).1
        }
        guard repository.catalog.hasResourceIndex else {
            throw ResourceError.rejected("particle_table_catalog_index_required")
        }
        return nil
    }

    // Read-only candidate for fresh CLI scene previews. Image/button masks
    // default to 0xff on the audited native construction path; message masks
    // must be explicit until their default is independently established. The
    // native system draw path can override its output mask per invocation.
    package func researchSceneOutputVisibility(_ handle: UInt64) -> Bool? {
        let output = storage.selectsPrimaryScriptSource ? (storage.linkedPrimaryOutputMask ?? storage.systemOutputMask) : storage.systemOutputMask
        let mask: Int32
        if let image = storage.images[handle] { mask = image.outputMask ?? 0xff }
        else if storage.buttons.contains(handle) { mask = storage.buttonOutputMasks[handle] ?? 0xff }
        else if let message = storage.messages[handle], let explicit = message.outputMask { mask = explicit }
        else { return nil }
        return (mask & output) != 0
    }

    private func sampledImageTransitionSettings(_ handle: UInt64, _ motion: ScriptStorage.PlacementTransition)
        -> ScriptStorage.MotionSettings? {
        guard (1...Int32.max / 1024).contains(motion.duration),
              (0...motion.duration).contains(motion.elapsed),
              let image = storage.images[handle], let origin = image.placement, origin.count == 3, motion.destination.count == 3,
              let source = image.transform, let target = motion.destinationTransform,
              source.scale.count == 3, target.scale.count == 3,
              source.depth == 0, target.depth == 0, source.rotation == [0, 0, 0], target.rotation == [0, 0, 0],
              source.scale[2] == 100, target.scale[2] == 100 else { return nil }
        let mode = motion.savedMode ?? image.motion?.mode ?? image.savedPlacementMode ?? 1
        let strength = image.motion?.strength ?? image.savedPlacementStrength ?? 100
        guard ScriptStorage.PlacementTransition.canSample(mode: mode, strength: strength),
              (origin + motion.destination + source.scale + target.scale)
                  .allSatisfy({ (-16_777_216...16_777_216).contains($0) }) else { return nil }
        return .init(mode: mode, strength: strength)
    }

    private func sampledPosition(_ handle: UInt64, _ placement: [Int32],
                                 sampleTitlePlacement: Bool) -> (Int32, Int32) {
        let settings = storage.images[handle]?.motion ?? storage.buttonMotion[handle]
        guard let motion = storage.placementTransitions[handle], motion.savedMode != 0 else {
            return (placement[0], placement[1])
        }
        if let sampled = sampledImageTransitionSettings(handle, motion) {
            return (
                motion.sampleSavedAxis(from: placement[0], to: motion.destination[0], mode: sampled.mode, strength: sampled.strength),
                motion.sampleSavedAxis(from: placement[1], to: motion.destination[1], mode: sampled.mode, strength: sampled.strength)
            )
        }
        guard sampleTitlePlacement || settings?.mode == 3 || motion.savedMode == 1 || motion.savedMode == 3 else {
            return (placement[0], placement[1])
        }
        // Script queries still see the committed placement. The original
        // position evaluator quantizes remaining time to 1/1024 (0x5ab3ee).
        let fraction = motion.quantizedProgress
        let progress: Double
        if settings?.mode == 3 || motion.savedMode == 3 {
            // Mode 3 dispatches to 0x50ba30. The original executable
            // initializes the alternate-curve flag to zero.
            let strength = settings?.strength ?? storage.images[handle]?.savedPlacementStrength ?? 100
            progress = 1 - pow(1 - fraction, 1 + 1.4 * Double(strength) / 100)
        } else {
            progress = fraction
        }
        func axis(_ index: Int) -> Int32 {
            if motion.savedMode == 1 {
                return motion.sampleSavedAxis(from: placement[index], to: motion.destination[index])
            }
            let start = Double(placement[index])
            return Int32((start + (Double(motion.destination[index]) - start) * progress).rounded())
        }
        return (axis(0), axis(1))
    }

    private struct VisualAnchorOffset {
        var x: Int64 = 0
        var y: Int64 = 0
        var priority: Int64 = 0
        var unappliedTransform = false
    }

    private func visualAnchorOffset(_ handle: UInt64, sampleTitlePlacement: Bool) -> VisualAnchorOffset {
        guard var reference = storage.visualAnchorNames[handle] else { return .init() }
        var offset = VisualAnchorOffset()
        var seen: Set<UInt64> = [handle]
        func translationOnly(_ transform: ScriptStorage.ImageTransform?) -> Bool {
            guard let transform else { return true }
            return transform.depth == 0 && transform.scale == [100, 100, 100] && transform.rotation == [0, 0, 0]
        }
        while let parent = storage.visualAnchorTarget(reference), let image = storage.images[parent] {
            let motion = storage.placementTransitions[parent]
            guard seen.insert(parent).inserted, translationOnly(image.transform),
                  translationOnly(motion?.destinationTransform),
                  (image.alignment?.x ?? 0) == 0, (image.alignment?.y ?? 0) == 0 else {
                return .init(unappliedTransform: true)
            }
            let placement = image.placement ?? [0, 0, 0]
            let (x, y) = sampledPosition(parent, placement, sampleTitlePlacement: sampleTitlePlacement)
            offset.x += Int64(x)
            offset.y += Int64(y)
            if seen.count == 2 {
                // 0x5adf03 copies only the immediate parent's evaluated Z.
                if let motion, let sampled = sampledImageTransitionSettings(parent, motion) {
                    offset.priority = Int64(motion.sampleSavedAxis(from: placement[2], to: motion.destination[2],
                                                                   mode: sampled.mode, strength: sampled.strength))
                } else {
                    offset.priority = Int64(placement[2])
                }
            }
            guard let next = storage.visualAnchorNames[parent] else { break }
            reference = next
        }
        return offset
    }

    public var staticImageLayers: [StaticImageLayer] {
        let sampleTitlePlacement = canStartFromTitle
        func hasUnappliedTransform(_ transform: ScriptStorage.ImageTransform?) -> Bool {
            guard let transform else { return false }
            return transform.depth != 0 || transform.scale[2] != 100 || transform.rotation.contains { $0 != 0 }
        }
        let images: [StaticImageLayer] = storage.images.compactMap { handle, image in
            guard image.isDrawable, let resource = image.resource,
                  let placement = image.placement, placement.count >= 3 else { return nil }
            let (x, y) = sampledPosition(handle, placement, sampleTitlePlacement: sampleTitlePlacement)
            let anchor = visualAnchorOffset(handle, sampleTitlePlacement: sampleTitlePlacement)
            let researchVideoLayerTicks: Int32? = {
                guard image.isTheoraResource, let snapshot = image.savedLayerTimeSnapshot,
                      snapshot.visualTick == storage.visualTicks, let bits = snapshot.times.first else { return nil }
                let value = Float(bitPattern: UInt32(bitPattern: bits))
                guard value.isFinite, value >= 0 else { return nil }
                return Int32(exactly: value.rounded(.towardZero))
            }()
            var scale = image.transform?.scale ?? [100, 100, 100]
            var priority = placement[2]
            var unresolvedScaleTransition = false
            var fractionalScale: SIMD2<Float>?
            if let motion = storage.placementTransitions[handle], let target = motion.destinationTransform {
                if let settings = sampledImageTransitionSettings(handle, motion) {
                    priority = motion.sampleSavedAxis(from: priority, to: motion.destination[2],
                                                      mode: settings.mode, strength: settings.strength)
                    var sampled = SIMD2<Float>(repeating: 0)
                    for axis in 0..<2 {
                        let value = motion.sampleAxis(from: scale[axis], to: target.scale[axis],
                                                      mode: settings.mode, strength: settings.strength)
                        sampled[axis] = value
                        if let exact = Int32(exactly: value) { scale[axis] = exact }
                        else { unresolvedScaleTransition = true }
                    }
                    if unresolvedScaleTransition { fractionalScale = sampled }
                } else if motion.elapsed > 0, target.scale != scale || hasUnappliedTransform(target) {
                    unresolvedScaleTransition = true
                }
            }
            return StaticImageLayer(id: handle, resource: resource,
                                    x: Int32(clamping: Int64(x) + anchor.x),
                                    y: Int32(clamping: Int64(y) + anchor.y),
                                    priority: Int32(clamping: Int64(priority) + anchor.priority), selectedMember: image.selectedMember,
                                    motionElapsedTicks: image.motionElapsedHundredths(at: storage.visualTicks).map { Int32($0 / 100) },
                                    motionIsAdvancing: image.motionStartTick != nil &&
                                        (!(image.isTheoraResource || image.hasIndependentActionClock) || image.enabled) &&
                                        image.actionAdvancePercent > 0 && !image.standaloneVideoIsPaused(in: researchVideoSaveProfiles),
                                    opacity: image.presentedOpacity,
                                    scaleXPercent: scale[0],
                                    scaleYPercent: scale[1], hoverResource: nil,
                                    boundRasterPreview: image.boundImages[0],
                                    hasExplicitAlignment: image.alignment != nil, alignmentXPercent: image.alignment?.x ?? 0, alignmentYPercent: image.alignment?.y ?? 0, textureFilter: image.textureFilter,
                                    unappliedTransform: anchor.unappliedTransform || hasUnappliedTransform(image.transform) ||
                                        unresolvedScaleTransition || storage.configDisplayNeedsHostUpdate, drawChannel: image.drawChannel,
                                    fractionalScalePercent: fractionalScale,
                                    isTheoraResource: image.isTheoraResource, researchVideoLayerTicks: researchVideoLayerTicks,
                                    standaloneVideoLayerTicks: image.standaloneVideoLayerTick(at: storage.visualTicks),
                                    boundTextureLocations: image.boundImages,
                                    savedLayerTimeCandidate: executedSteps == 0 && image.savedLayerTimeSnapshot?.visualTick == storage.visualTicks
                                        ? image.savedLayerTimeSnapshot?.times : nil,
                                    savedLayerAuxiliaryCandidate: executedSteps == 0 && image.savedLayerTimeSnapshot?.visualTick == storage.visualTicks
                                        ? image.savedLayerTimeSnapshot?.auxiliary : nil,
                                    filterOverrides: image.filterOverrides)
        }
        let buttons: [StaticImageLayer] = storage.enabledButtons.compactMap { handle in
            let container = storage.buttonResources[handle]
            // The audited load-page *OnCheck action draws texture slot 1.
            let checkedPage = storage.buttonCheckVisual[handle, default: 0] != 0 &&
                container.map { asciiLower($0.sourceFile).hasSuffix("/script/saveload/button_page.b") } == true
            let textures = storage.buttonImages[handle]
            let checkedTexture = checkedPage ? textures?[1] : nil
            let extendedContainer = storage.buttonHasExtendedContainerMetadata.contains(handle)
            guard let resource = checkedTexture ?? (extendedContainer ? container : textures?[0] ?? container),
                  let placement = storage.buttonPlacement[handle], placement.count >= 3 else { return nil }
            let (x, y) = sampledPosition(handle, placement, sampleTitlePlacement: sampleTitlePlacement)
            let anchor = visualAnchorOffset(handle, sampleTitlePlacement: sampleTitlePlacement)
            let scale = storage.savedButtonPlacementScale[handle] ?? SIMD2(100, 100)
            let motionSnapshot = storage.buttonSavedLayerTimeSnapshots[handle]
            return StaticImageLayer(id: handle, resource: resource,
                                    x: Int32(clamping: Int64(x) + anchor.x), y: Int32(clamping: Int64(y) + anchor.y),
                                    priority: Int32(clamping: Int64(placement[2]) + anchor.priority), selectedMember: storage.buttonSelectedMembers[handle],
                                    motionElapsedTicks: storage.buttonMotionStartTicks[handle].map {
                                        Int32(clamping: storage.visualTicks - $0)
                                    },
                                    motionIsAdvancing: storage.enabledButtons.contains(handle) &&
                                        storage.buttonSelectedMembers[handle] != nil,
                                    opacity: 255, scaleXPercent: scale.x, scaleYPercent: scale.y,
                                    hoverResource: !checkedPage && storage.buttonIsKnownUnlocked(handle) ? textures?[1] : nil,
                                    boundRasterPreview: nil, hasExplicitAlignment: false, alignmentXPercent: 0, alignmentYPercent: 0, textureFilter: nil,
                                    unappliedTransform: anchor.unappliedTransform || storage.unknownSavedButtonChecks.contains(handle) ||
                                        storage.unknownSavedButtonLocks.contains(handle) || storage.configDisplayNeedsHostUpdate, drawChannel: nil,
                                    researchButtonChecked: storage.unknownSavedButtonChecks.contains(handle) ? nil : storage.buttonCheckVisual[handle, default: 0] != 0,
                                    researchButtonLocked: storage.unknownSavedButtonLocks.contains(handle) ? nil : storage.buttonLocks[handle, default: 0] != 0,
                                    boundTextureLocations: extendedContainer ? (textures ?? [:]) : [:],
                                    savedLayerTimeCandidate: executedSteps == 0 && motionSnapshot?.visualTick == storage.visualTicks
                                        ? motionSnapshot?.times : nil,
                                    savedLayerAuxiliaryCandidate: executedSteps == 0 && motionSnapshot?.visualTick == storage.visualTicks
                                        ? motionSnapshot?.auxiliary : nil)
        }
        let backgrounds: [StaticImageLayer] = storage.messages.compactMap { handle, message in
            guard message.enabled, let resource = message.background,
                  let placement = message.placement, placement.count >= 3 else { return nil }
            let anchor = visualAnchorOffset(handle, sampleTitlePlacement: sampleTitlePlacement)
            return StaticImageLayer(id: handle, resource: resource,
                                    x: Int32(clamping: Int64(placement[0]) + anchor.x),
                                    y: Int32(clamping: Int64(placement[1]) + anchor.y),
                                    priority: Int32(clamping: Int64(placement[2]) + anchor.priority), selectedMember: message.backgroundSelectedMember,
                                    motionElapsedTicks: message.backgroundMotionStartTick.map { Int32(clamping: storage.visualTicks - $0) },
                                    motionIsAdvancing: message.backgroundMotionStartTick != nil, opacity: 255,
                                    scaleXPercent: message.transform?.scale[0] ?? 100,
                                    scaleYPercent: message.transform?.scale[1] ?? 100, hoverResource: nil,
                                    boundRasterPreview: message.backgroundBoundImages[0],
                                    hasExplicitAlignment: message.alignment != nil, alignmentXPercent: message.alignment?.0 ?? 0, alignmentYPercent: message.alignment?.1 ?? 0, textureFilter: nil,
                                    unappliedTransform: anchor.unappliedTransform || hasUnappliedTransform(message.transform) ||
                                        storage.configMessageAlphaNeedsRendering || storage.configDisplayNeedsHostUpdate, drawChannel: message.drawChannel,
                                    boundTextureLocations: message.backgroundBoundImages)
        }
        return (images + buttons + backgrounds).sorted { ($0.priority, $0.id) < ($1.priority, $1.id) }
    }

    public struct MessageTextLayer: Sendable {
        public struct LineBreakCandidate: Sendable {
            public let reserve: Int32
            public let prohibitedLineStart: String
            public let prohibitedLineEnd: String
        }

        public struct ReturnSpacing: Sendable {
            public let matching: Int32
            public let ordinary: Int32
            public let words: String
        }

        public struct Ruby: Sendable {
            public let text: String
            public let fontName: String?
            public let width: Int32?
            public let height: Int32?
            public let colorARGB: UInt32?
        }

        public struct Run: Sendable {
            public let text: String
            public let width: Int32
            public let height: Int32
            public let ruby: Ruby?
            public let colorARGB: UInt32
            public let fontName: String?
            public var estimatedTracking: Int32 = 0
            public var horizontalAdvance: Int32? = nil
        }

        public let id: UInt64
        public let runs: [Run]
        public var unhandledDirectives: [String] = []
        public var lineBreakCandidate: LineBreakCandidate? = nil
        public var returnSpacing: ReturnSpacing? = nil
        public var text: String { runs.map(\.text).joined() }
        public let canvasBounds: [Int64]?
        public let surfaceMargins: [Int32]
        public let x: Int32
        public let y: Int32
        public let scaleXPercent: Int32
        public let scaleYPercent: Int32
        public let isVisible: Bool
        public let priority: Int32?

        package var unscaledSurface: Self {
            Self(id: id, runs: runs, unhandledDirectives: unhandledDirectives, lineBreakCandidate: lineBreakCandidate,
                 returnSpacing: returnSpacing,
                 canvasBounds: canvasBounds, surfaceMargins: surfaceMargins, x: x, y: y,
                 scaleXPercent: 100, scaleYPercent: 100, isVisible: isVisible, priority: priority)
        }
    }

    public func messageSurfaceStatus(_ id: UInt64) -> (pending: Int, committed: Int, hasBounds: Bool)? {
        guard let message = storage.messages[id] else { return nil }
        let bounds = message.textBounds
        let hasBounds = bounds.map { $0.count == 4 && $0[2] > $0[0] && $0[3] > $0[1] } ?? false
        return (message.pendingOutput.count, message.committedOutput.count, hasBounds)
    }

    /// Projects committed message operations and their script-defined text surfaces.
    public var messageTextLayers: [MessageTextLayer] {
        storage.messages.keys.sorted().compactMap { handle in
            guard let message = storage.messages[handle] else { return nil }
            return projectedMessageTextLayer(handle: handle, message: message)
        }
    }

    package func researchButtonTextLayer(_ handle: UInt64) -> (layer: MessageTextLayer, leadingVerticalOffset: Int32)? {
        guard storage.enabledButtons.contains(handle), var message = storage.buttonText[handle],
              let bounds = storage.buttonTextBounds[handle], bounds.count == 4,
              message.pendingOutput.isEmpty, !message.committedOutput.isEmpty else { return nil }
        message.textBounds = bounds
        message.placement = [0, 0, 0]
        message.enabled = true
        var leadingVerticalOffset: Int32 = 0
        for (index, operation) in message.committedOutput.enumerated() {
            switch operation {
            case .directive("f", _), .directive("s", _), .directive("c", _): continue
            case .directive("n", let operands) where operands.count == 1 && operands[0] > 0 &&
                 Int64(operands[0]) < Int64(bounds[3]) - Int64(bounds[1]):
                leadingVerticalOffset = operands[0]
                message.committedOutput.remove(at: index)
            default: break
            }
            break
        }
        guard var layer = projectedMessageTextLayer(handle: handle, message: message, includeAnchor: false) else { return nil }
        if leadingVerticalOffset > 0 { layer.unhandledDirectives.append("button_text_original_vertical_placement_unverified") }
        return (layer, leadingVerticalOffset)
    }

    private static func messageFontName(_ slot: Int32, storage: ScriptStorage) -> String? {
        let key = "Font[\(slot)].Name"
        if case .string(let override) = storage.fontOverrides[key] { return override }
        return try? storage.configuration?.value(for: key)
    }

    private func projectedMessageTextLayer(handle: UInt64, message: ScriptStorage.MessageObject,
                                           includeAnchor: Bool = true) -> MessageTextLayer? {
            var runs: [MessageTextLayer.Run] = []
            var width: Int32 = 24
            var height: Int32 = 24
            var colorARGB: UInt32 = 0xffff_ffff
            func fontName(_ slot: Int32) -> String? {
                Self.messageFontName(slot, storage: storage)
            }
            var currentFont = fontName(0)
            var rubyFont: String?
            var rubyWidth: Int32?
            var rubyHeight: Int32?
            var rubyColor: UInt32?
            var unhandledDirectives = Set<String>()
            if storage.configMessageAlphaNeedsRendering { unhandledDirectives.insert("config_message_alpha") }
            if storage.configDisplayNeedsHostUpdate { unhandledDirectives.insert("config_display_state") }
            // Both native classifiers (0x67bf08/0x67bf3c) return false
            // before consulting their tables when the reserve is zero.
            if message.kinsokuWordLength != 0 {
                if !message.prohibitedLineStart.isEmpty { unhandledDirectives.insert("kwb") }
                if !message.prohibitedLineEnd.isEmpty { unhandledDirectives.insert("kwe") }
            }
            if !message.ignoredReturnWords.isEmpty { unhandledDirectives.insert("nsw") }
            if let length = message.kinsokuWordLength, length != 0 { unhandledDirectives.insert("kwl") }
            var estimatedTracking: Int32 = 0
            for operation in message.committedOutput {
                switch operation {
                case .text(let text):
                    if !text.isEmpty { runs.append(.init(text: text, width: width, height: height, ruby: nil, colorARGB: colorARGB, fontName: currentFont, estimatedTracking: estimatedTracking)) }
                case .ruby(let base, let annotation):
                    if !base.isEmpty {
                        let ruby = MessageTextLayer.Ruby(text: annotation, fontName: rubyFont,
                                                        width: rubyWidth, height: rubyHeight, colorARGB: rubyColor)
                        runs.append(.init(text: base, width: width, height: height, ruby: ruby,
                                          colorARGB: colorARGB, fontName: currentFont, estimatedTracking: estimatedTracking))
                    }
                case .directive("n", let operands):
                    runs.append(.init(text: "\n", width: width, height: height, ruby: nil, colorARGB: colorARGB, fontName: currentFont))
                    if !operands.isEmpty { unhandledDirectives.insert("n") }
                case .directive("i", let operands) where operands[0] > 0:
                    runs.append(.init(text: "", width: width, height: height, ruby: nil, colorARGB: colorARGB,
                                      fontName: currentFont, horizontalAdvance: operands[0]))
                case .directive("i", let operands) where operands[0] == 0:
                    break
                case .directive("pi", let operands) where operands.count == 2:
                    // The original uses this field in glyph measurement. CoreText
                    // tracking is only an approximation; vertical pitch and exact
                    // original glyph placement are not implemented here.
                    estimatedTracking = min(8192, max(-8192, operands[0]))
                    unhandledDirectives.insert("pi")
                case .directive("s", let size) where size.count >= 2:
                    width = min(8192, max(1, size[0]))
                    height = min(8192, max(1, size[1]))
                case .directive("f", let slots) where slots.count == 1:
                    currentFont = fontName(slots[0])
                case .directive("rf", let slots) where slots.count == 1:
                    rubyFont = fontName(slots[0])
                case .directive("rs", let size) where size.count == 2:
                    rubyWidth = min(8192, max(1, size[0]))
                    rubyHeight = min(8192, max(1, size[1]))
                case .directive("rc", let color) where color.count == 1:
                    rubyColor = UInt32(bitPattern: color[0])
                case .directive("c", let color) where color.count == 1:
                    colorARGB = UInt32(bitPattern: color[0])
                case .directive(let name, _):
                    unhandledDirectives.insert(name)
                }
            }
            guard !runs.isEmpty else { return nil }
            let anchor = includeAnchor && storage.visualAnchorNames[handle] != nil
                ? visualAnchorOffset(handle, sampleTitlePlacement: canStartFromTitle) : VisualAnchorOffset()
            if anchor.unappliedTransform { unhandledDirectives.insert("visual_anchor_transform") }
            var canvasBounds: [Int64]?
            if message.enabled, let placement = message.placement, placement.count >= 3,
               let bounds = message.textBounds, bounds.count == 4, bounds[2] > bounds[0], bounds[3] > bounds[1] {
                var origin = [Int64(placement[0]) + anchor.x, Int64(placement[1]) + anchor.y]
                if message.usesTimedCenterText, bounds[0] == 0, bounds[1] == 0 {
                    // The audited type-4 key anchors the live message surface at 50% on both axes.
                    origin[0] -= (Int64(bounds[2]) + 1) / 2
                    origin[1] -= (Int64(bounds[3]) + 1) / 2
                }
                canvasBounds = bounds.enumerated().map { index, endpoint in
                    Int64(endpoint) + origin[index % 2]
                }
            }
            var lineBreakCandidate = message.kinsokuWordLength.map {
                MessageTextLayer.LineBreakCandidate(reserve: $0, prohibitedLineStart: message.prohibitedLineStart,
                                                    prohibitedLineEnd: message.prohibitedLineEnd)
            }
            if message.returnSpacing == nil, unhandledDirectives.contains("kwe"),
               unhandledDirectives.isSubset(of: ["kwe", "kwl"]),
               (message.kinsokuWordLength ?? 1) == 1, message.prohibitedLineStart.isEmpty {
                let explicitEndUnits = Set(message.prohibitedLineEnd.utf16)
                // The fixed executable's default end table contains opening punctuation
                // and the two less-than signs. With neither table matching any text,
                // the override and default give the same result at 0x67bf3c.
                if runs.allSatisfy({ run in
                    run.ruby == nil && run.horizontalAdvance == nil &&
                        run.text.rangeOfCharacter(from: .newlines) == nil &&
                        explicitEndUnits.isDisjoint(with: run.text.utf16) &&
                        run.text.unicodeScalars.allSatisfy {
                            $0.properties.generalCategory != .openPunctuation &&
                                $0.value != 0x003c && $0.value != 0xff1c
                        }
                }) {
                    unhandledDirectives.remove("kwe")
                    unhandledDirectives.remove("kwl")
                    lineBreakCandidate = nil
                }
            }
            let returnSpacing = message.returnSpacing.map {
                MessageTextLayer.ReturnSpacing(matching: $0.0, ordinary: $0.1, words: message.ignoredReturnWords)
            }
            if let returnSpacing {
                if returnSpacing.matching != 0 || returnSpacing.ordinary != 0 {
                    unhandledDirectives.insert("ns")
                } else {
                    unhandledDirectives.remove("nsw")
                }
            }
            return MessageTextLayer(id: handle, runs: runs, unhandledDirectives: unhandledDirectives.sorted(),
                                    lineBreakCandidate: lineBreakCandidate, returnSpacing: returnSpacing,
                                    canvasBounds: canvasBounds,
                                    surfaceMargins: message.textMargins ?? [0, 0],
                                    x: Int32(clamping: Int64(message.placement?[0] ?? 0) + anchor.x),
                                    y: Int32(clamping: Int64(message.placement?[1] ?? 0) + anchor.y),
                                    scaleXPercent: message.transform?.scale[0] ?? 100,
                                    scaleYPercent: message.transform?.scale[1] ?? 100, isVisible: message.enabled,
                                    priority: canvasBounds == nil ? nil :
                                        message.placement.map { Int32(clamping: Int64($0[2]) + anchor.priority) })
    }

    public struct DialogueHistoryLine: Sendable {
        public let speaker: String
        public let text: String
    }

    public var recentDialogueHistory: [DialogueHistoryLine] {
        storage.dialogueLogEntries.suffix(256).map { .init(speaker: $0.speaker, text: $0.text) }
    }

    package var hasVisibleMessageSurface: Bool { storage.messages.values.contains(where: \.enabled) }

    public var committedMessageText: [String] { messageTextLayers.map(\.text) }

    public var titleButtons: [UInt64: Int32] {
        guard phase == .waitingForEvent, stopCallbackFrameDepth == nil,
              stopCallback != nil, stopCallback == (try? program.label("@@!OnStopEvent")),
              pc > 0, asciiLower(program.document.records[pc - 1].location.sourceFile).hasSuffix("/script/title/main.s")
        else { return [:] }
        var buttons: [UInt64: Int32] = [:]
        for index: Int32 in 0...5 {
            guard case .object(let handle) = try? storage.readIndexed("Button", index),
                  storage.enabledButtons.contains(handle), storage.buttonIsKnownUnlocked(handle),
                  storage.buttonScriptTargets[handle] != nil else { continue }
            if buttons[handle] == nil { buttons[handle] = index }
        }
        return buttons
    }

    public var loadMenuButtons: Set<UInt64> {
        guard phase == .waitingForEvent, stopCallbackFrameDepth == nil,
              stopCallback != nil, stopCallback == (try? program.label("@@!OnStopEvent")),
              pc > 0, asciiLower(program.document.records[pc - 1].location.sourceFile).hasSuffix("/script/saveload/main_load.s")
        else { return [] }
        return Set(storage.enabledButtons.filter {
            storage.buttonIsKnownUnlocked($0) &&
            ["@@!pagechange", "@@!cancel", "@@!data", "@@!quickload", "@@!delete"].contains((storage.buttonUserStrings[$0]?[0]).map(asciiLower) ?? "")
        })
    }

    public var saveMenuButtons: Set<UInt64> {
        guard phase == .waitingForEvent, stopCallbackFrameDepth == nil,
              stopCallback != nil, stopCallback == (try? program.label("@@!OnStopEvent")),
              pc > 0, asciiLower(program.document.records[pc - 1].location.sourceFile).hasSuffix("/script/saveload/main_save.s")
        else { return [] }
        return Set(storage.enabledButtons.filter {
            storage.buttonIsKnownUnlocked($0) &&
            ["@@!pagechange", "@@!cancel", "@@!data", "@@!delete"].contains((storage.buttonUserStrings[$0]?[0]).map(asciiLower) ?? "")
        })
    }

    package var isWaitingInDialogueLog: Bool {
        isLinkedLogTask && phase == .waitingForEvent && stopCallbackFrameDepth == nil &&
            stopCallback != nil && stopCallback == (try? program.label("@@!OnStopEvent")) &&
            pc > 0 && asciiLower(program.document.records[pc - 1].location.sourceFile).hasSuffix("/script/log/main.s")
    }

    package var dialogueLogButtons: Set<UInt64> {
        guard isWaitingInDialogueLog else { return [] }
        return Set(storage.enabledButtons.filter {
            storage.buttonIsKnownUnlocked($0) &&
                ["@@!logjump", "@@!cancel"].contains(storage.buttonUserStrings[$0]?[0].map(asciiLower) ?? "")
        })
    }

    private var logJumpButtons: Set<UInt64> {
        dialogueLogButtons.filter { storage.buttonUserStrings[$0]?[0].map(asciiLower) == "@@!logjump" }
    }

    package var systemTaskMenuButtons: Set<UInt64> { loadMenuButtons.union(saveMenuButtons).union(dialogueLogButtons) }

    package func logJumpButton(named name: String) throws -> UInt64? {
        let matches = logJumpButtons.filter { storage.buttonUserStrings[$0]?[1].map(asciiLower) == asciiLower(name) }
        guard matches.count <= 1 else { throw ResourceError.rejected("log_jump_button_ambiguous") }
        return matches.first
    }

    package var visibleLogJumpCheckpoints: [String] {
        logJumpButtons.compactMap { storage.buttonUserStrings[$0]?[1] }.sorted()
    }

    public var systemTaskSlotAccessibilityLabels: [UInt64: String] {
        let buttons = systemTaskMenuButtons.filter {
            let action = storage.buttonUserStrings[$0]?[0].map(asciiLower)
            return action == "@@!data" || action == "@@!delete" || action == "@@!logjump"
        }
        return buttons.reduce(into: [:]) { labels, handle in
            let action = storage.buttonUserStrings[handle]?[0].map(asciiLower)
            if action == "@@!logjump" {
                labels[handle] = "回到这条对白"
                return
            }
            let verb = action == "@@!delete" ? "删除" : (saveMenuButtons.contains(handle) ? "保存" : "读取")
            let rawName = storage.buttonUserStrings[handle]?[1] ?? ""
            let filename = (rawName as NSString).lastPathComponent
            let stem = (filename as NSString).deletingPathExtension
            let prefix = "savedata"
            let suffix = asciiLower(stem).hasPrefix(prefix) ? String(stem.dropFirst(prefix.count)) : ""
            guard filename.lowercased().hasSuffix(".svd"), let index = Int(suffix), index >= 0 else {
                labels[handle] = "\(verb)存档槽"
                return
            }
            labels[handle] = "\(verb)存档槽 \(index + 1)"
        }
    }

    package func saveSlotButton(named name: String) throws -> UInt64? {
        let matches = saveMenuButtons.filter {
            storage.buttonUserStrings[$0]?[0].map(asciiLower) == "@@!data" &&
                storage.buttonUserStrings[$0]?[1].map(asciiLower) == asciiLower(name)
        }
        guard matches.count <= 1 else { throw ResourceError.rejected("save_slot_button_ambiguous") }
        return matches.first
    }

    package func registeredSaveSlotSHA256(named name: String) -> String? {
        saveSources[Data(asciiLower(name).utf8)]?.sha256
    }

    package func deleteSlotButton(named name: String) throws -> UInt64? {
        guard try storage.containsSessionSave(name) else { return nil }
        let matches = systemTaskMenuButtons.filter {
            storage.buttonUserStrings[$0]?[0].map(asciiLower) == "@@!delete" &&
                storage.buttonUserStrings[$0]?[1].map(asciiLower) == asciiLower(name)
        }
        guard matches.count <= 1 else { throw ResourceError.rejected("delete_slot_button_ambiguous") }
        return matches.first
    }

    public func isLoadMenuCancelButton(_ handle: UInt64) -> Bool {
        (storage.buttonUserStrings[handle]?[0]).map(asciiLower) == "@@!cancel"
    }

    package func loadSlotButton(named name: String) throws -> UInt64? {
        guard try storage.containsSessionSave(name) else { return nil }
        let matches = loadMenuButtons.filter {
            storage.buttonUserStrings[$0]?[0].map(asciiLower) == "@@!data" &&
                storage.buttonUserStrings[$0]?[1].map(asciiLower) == asciiLower(name)
        }
        guard matches.count <= 1 else { throw ResourceError.rejected("load_slot_button_ambiguous") }
        return matches.first
    }

    package var isWaitingForLoadConfirmation: Bool {
        guard phase == .waitingForEvent, stopCallbackFrameDepth == nil,
              let stopCallback, stopCallback == (try? program.label("@@!Dialog_YesNoOnStop")),
              pc > 0 else { return false }
        return asciiLower(program.document.records[pc - 1].location.sourceFile)
            .hasSuffix("/script/dialog/main.s")
    }

    private static func isStartupBackupSite(_ location: ScriptLocation, line: Int) -> Bool {
        location.sourceFile == "data7.pack/script/exceptionbackup/main.s" &&
            location.sourceSHA256 == "49ed941ece01f3c525dcefa8d99a79d7c5b9e2c9b6f9b9c2248afd820ce99929" &&
            location.lineNumber == line
    }

    private static func isStartupCleanupSite(_ location: ScriptLocation, line: Int) -> Bool {
        location.sourceFile == "data0.pack/startup.s" &&
            location.sourceSHA256 == "793c5f20ea7b732168e3211642853e19c4a4be969f2aab84f660616f3c7294d1" &&
            location.lineNumber == line
    }

    private var cleanShutdownInProgress = false
    package var allowTitleQuit = false
    package private(set) var titleQuitShutdownRequested = false

    package mutating func beginCleanShutdown() throws {
        guard phase == .waiting || phase == .waitingForEvent || phase == .finished,
              storage.linkedPrimaryPlayMode == nil, !isWaitingForStartupBackupConfirmation,
              !cleanShutdownInProgress else {
            throw ResourceError.rejected("clean_shutdown_requires_initialized_session")
        }
        try enterCleanShutdownScript()
    }

    package mutating func beginCleanShutdown(afterQuit task: ScriptMachine) throws {
        guard systemTaskEntryLabel.map(asciiLower) == "@@!quit", task.titleQuitShutdownRequested,
              task.lastSaveWriteIssue == nil else {
            throw ResourceError.rejected(task.lastSaveWriteIssue ?? "confirmed_title_quit_required")
        }
        var closing = self
        try closing.finishSystemLoadTask(task)
        if closing.saveDirectory != nil, closing.saveHeaderTemplate != nil {
            try closing.enterCleanShutdownScript()
        } else {
            closing.lastSaveWriteIssue = closing.saveDirectory == nil ? nil : "save_write_header_template_unavailable"
            closing.storage.soundChannels.removeAll()
            closing.storage.directSoundChannels.removeAll()
            closing.storage.timers.removeAll()
            closing.phase = .finished
        }
        self = closing
    }

    private mutating func enterCleanShutdownScript() throws {
        guard var pinned = repository, saveDirectory != nil, saveHeaderTemplate != nil else {
            throw ResourceError.rejected("clean_shutdown_requires_initialized_session")
        }
        let startup = try pinned.load("startup.s")
        let entry = try startup.label("@@Free")
        guard Self.isStartupCleanupSite(startup.document.records[entry].location, line: 35),
              startup.ancestors[entry].isEmpty else {
            throw ResourceError.rejected("startup_cleanup_entry_not_verified")
        }
        if systemDataSaveTarget != nil {
            // Publish the live system state before cleanup can remove the recovery slot.
            let seed = try Self.currentSaveTiming().seed
            try publishStandaloneSystemData(storage, seed: seed)
        } else {
            lastSaveWriteIssue = nil
        }
        repository = pinned
        program = startup
        pc = entry
        storage.frames = [ScriptFrame(returnIndex: nil, entryLabel: "@@Free")]
        // The cleanup entry starts a fresh reader. A restored dialogue
        // reader may still have a story-only prefix for empty lines.
        storage.noWordLineText = nil
        storage.exceptTextPrefix = nil
        cleanShutdownInProgress = true
        phase = .ready
    }

    private static func isTitleQuitRequest(_ location: ScriptLocation) -> Bool {
        location.sourceFile == "data8.pack/script/title/main.s" && location.lineNumber == 81 &&
            location.sourceSHA256 == "affc85eb52bd090afa48af71c74910eb4bf11f13ac8123de3957a5dc2c3e141c"
    }

    private static func isTitleQuitCompletion(_ location: ScriptLocation) -> Bool {
        location.sourceFile == "data8.pack/script/sequence/onquit.s" && location.lineNumber == 23 &&
            location.sourceSHA256 == "259ef0822d0b06c5d24b2178f8886f19070951097471c44546111ca8efb61a98"
    }

    package var isWaitingForStartupBackupConfirmation: Bool {
        guard isWaitingForLoadConfirmation, storage.linkedPrimaryPlayMode == nil else { return false }
        return storage.frames.contains { frame in
            guard let caller = frame.returnProgram, let next = frame.returnIndex,
                  caller.document.records.indices.contains(next - 1) else { return false }
            return Self.isStartupBackupSite(caller.document.records[next - 1].location, line: 25)
        }
    }

    package var isWaitingForSaveDeletionConfirmation: Bool {
        pendingSlotDeletion != nil && isWaitingForLoadConfirmation
    }

    package var loadConfirmationButtons: [UInt64: Bool] {
        guard isWaitingForLoadConfirmation else { return [:] }
        var buttons: [UInt64: Bool] = [:]
        for handle in storage.enabledButtons where storage.buttonIsKnownUnlocked(handle) {
            switch storage.buttonUserStrings[handle]?[0].map(asciiLower) {
            case "yes": buttons[handle] = true
            case "no": buttons[handle] = false
            default: break
            }
        }
        return buttons
    }

    package mutating func dispatchLoadConfirmation(accept: Bool) throws -> Bool {
        guard isWaitingForLoadConfirmation else { return false }
        let buttons = loadConfirmationButtons
        let matches = staticImageLayers.filter { buttons[$0.id] == accept }
        guard matches.count == 1, let button = matches.first else {
            throw ResourceError.rejected("load_confirmation_button_unavailable")
        }
        try dispatchStopCallback(pointer: (button.x, button.y), click: true)
        pendingButton = button.id
        if accept { pendingSlotDeletion?.confirmed = true }
        else { pendingSlotDeletion = nil }
        return true
    }

    public func loadPageIndex(_ handle: UInt64) -> Int32? {
        guard let label = storage.buttonUserStrings[handle]?[0], asciiLower(label) == "@@!pagechange",
              let page = storage.buttonUserIntegers[handle]?[0], page >= 0 else { return nil }
        return page
    }

    public func isLoadPageChecked(_ handle: UInt64) -> Bool {
        loadPageIndex(handle) != nil && storage.buttonCheckVisual[handle, default: 0] != 0
    }

    public mutating func dispatchLoadMenuEscape() throws {
        guard isWaitingInDialogueLog || !systemTaskMenuButtons.isEmpty else {
            throw ResourceError.rejected("load_menu_escape_outside_profile")
        }
        try dispatchStopCallback()
        pendingLoadEscape = true
        pendingSlotDeletion = nil
    }

    package enum DialogueLogNavigation: String, Sendable {
        case up, down, pageUp = "page-up", pageDown = "page-down"

        fileprivate var keyCode: Int32 {
            switch self {
            case .up: 0x26
            case .down: 0x28
            case .pageUp: 0x21
            case .pageDown: 0x22
            }
        }
    }

    package mutating func dispatchDialogueLogNavigation(_ navigation: DialogueLogNavigation) throws {
        guard isWaitingInDialogueLog else { throw ResourceError.rejected("dialogue_log_navigation_unavailable") }
        try dispatchStopCallback()
        pendingDialogueLogNavigation = navigation
    }

    package static let maximumDialogueLogWheelDelta: Int32 = 4_096

    package mutating func dispatchDialogueLogWheel(_ delta: Int32) throws {
        guard isWaitingInDialogueLog, delta != 0,
              (-Self.maximumDialogueLogWheelDelta...Self.maximumDialogueLogWheelDelta).contains(delta) else {
            throw ResourceError.rejected("dialogue_log_wheel_event_unavailable")
        }
        try dispatchStopCallback()
        pendingDialogueLogWheel = delta
    }

    public mutating func dispatchLoadMenuButton(_ handle: UInt64, x: Int32, y: Int32) throws {
        guard loadMenuButtons.contains(handle) else {
            throw ResourceError.rejected("load_menu_button_not_selectable")
        }
        try dispatchStopCallback(pointer: (x, y), click: true)
        pendingButton = handle
    }

    package mutating func dispatchSystemTaskMenuButton(_ handle: UInt64, x: Int32, y: Int32) throws {
        guard systemTaskMenuButtons.contains(handle) else {
            throw ResourceError.rejected("system_task_menu_button_not_selectable")
        }
        try dispatchStopCallback(pointer: (x, y), click: true)
        pendingButton = handle
        if systemLoadTaskID != nil, storage.buttonUserStrings[handle]?[0].map(asciiLower) == "@@!delete",
           let name = storage.buttonUserStrings[handle]?[1].map(asciiLower),
           let source = saveSources[Data(name.utf8)] {
            pendingSlotDeletion = (name, source.sha256, false)
        } else {
            pendingSlotDeletion = nil
        }
    }

    public func titleButtonTarget(_ handle: UInt64) -> String? {
        storage.buttonScriptTargets[handle].map(asciiLower)
    }

    public func buttonSound(_ handle: UInt64, slot: Int32) -> ScriptLocation? {
        storage.buttonSounds[handle]?[slot]
    }

    public var titleStartButton: UInt64? {
        titleButtons.first { handle, index in
            index == 0 && titleButtonTarget(handle) == "@@!start"
        }?.key
    }

    public var canStartFromTitle: Bool { titleStartButton != nil }

    public var isWaitingForStoryChoice: Bool {
        phase == .waitingForEvent && stopCallbackFrameDepth == nil &&
            stopCallback == (try? program.label("@@!Avg_SelectOnStopEvent")) && stopCallback != nil
    }

    public var visibleStoryChoiceButtons: [UInt64: Int32] {
        guard isWaitingForStoryChoice else { return [:] }
        var buttons: [UInt64: Int32] = [:]
        for index: Int32 in 0..<6 {
            guard case .object(let handle) = try? storage.readIndexed("SelectButton", index),
                  storage.enabledButtons.contains(handle),
                  storage.buttonUserIntegers[handle]?[0] == index else { continue }
            buttons[handle] = index
        }
        return buttons
    }

    public var storyChoiceButtons: [UInt64: Int32] {
        visibleStoryChoiceButtons.filter { storage.buttonIsKnownUnlocked($0.key) }
    }

    public var availableStoryChoices: [Int32] { storyChoiceButtons.values.sorted() }

    public func storyChoiceTextSize(_ handle: UInt64) -> (width: Int32, height: Int32)? {
        guard let bounds = storage.buttonTextBounds[handle], bounds.count == 4,
              bounds[2] > bounds[0], bounds[3] > bounds[1] else { return nil }
        return (Int32(clamping: Int64(bounds[2]) - Int64(bounds[0])),
                Int32(clamping: Int64(bounds[3]) - Int64(bounds[1])))
    }

    public struct ChoiceTextStyle: Sendable {
        public let fontName: String?
        public let height: Int32
        public let colorARGB: UInt32
    }

    public func storyChoiceTextStyle(_ handle: UInt64) -> ChoiceTextStyle {
        var slot: Int32 = 0
        var height: Int32 = 24
        var color: UInt32 = 0xffff_ffff
        for operation in storage.buttonText[handle]?.pendingOutput ?? [] {
            guard case .directive(let name, let values) = operation else { break }
            switch name {
            case "f" where values.count == 1: slot = values[0]
            case "s" where values.count == 2: height = min(8192, max(1, values[1]))
            case "c" where values.count == 1: color = UInt32(bitPattern: values[0])
            default: break
            }
        }
        let key = "Font[\(slot)].Name"
        let fontName: String?
        if case .string(let name) = storage.fontOverrides[key] {
            fontName = name
        } else {
            fontName = try? storage.configuration?.value(for: key)
        }
        return ChoiceTextStyle(fontName: fontName, height: height, colorARGB: color)
    }

    public func storyChoiceText(_ index: Int32) -> String? {
        guard isWaitingForStoryChoice,
              case .object(let list) = try? storage.read("SelectButtonList") else { return nil }
        return try? storage.lists[list]?.line(at: index)
    }

    public mutating func dispatchStoryChoice(_ index: Int32) throws {
        guard isWaitingForStoryChoice, index >= 0,
              case .object(let handle) = try storage.readIndexed("SelectButton", index),
              storage.enabledButtons.contains(handle), storage.buttonIsKnownUnlocked(handle),
              storage.buttonUserIntegers[handle]?[0] == index else {
            throw ResourceError.rejected("story_choice_not_selectable")
        }
        try dispatchStopCallback()
        pendingButton = handle
    }

    public var isDialogueWindowHidden: Bool { storage.systemPlayMode == 1 }

    public mutating func restoreDialogueWindow() {
        if isDialogueWindowHidden { storage.systemPlayMode = 0 }
    }

    public var windowViewButton: UInt64? {
        guard phase == .waitingForEvent, stopCallback != nil, stopCallbackFrameDepth == nil,
              timedStopRequest == nil, !isWaitingForStoryChoice,
              case .object(let handle) = try? storage.readIndexed("SysButton", 0),
              storage.enabledButtons.contains(handle), storage.buttonIsKnownUnlocked(handle),
              let target = storage.buttonUserStrings[handle]?[1],
              asciiLower(target) == "@@!avg_onsysbutton_view" else { return nil }
        return handle
    }

    package var researchWindowAutoButton: UInt64? {
        guard researchWindowAutoUnavailableReason == nil,
              case .object(let handle) = try? storage.readIndexed("SysButton", 2) else { return nil }
        return handle
    }

    package var researchWindowAutoUnavailableReason: String? {
        if phase != .waitingForEvent { return "phase" }
        if stopCallback == nil { return "no_stop_callback" }
        if stopCallbackFrameDepth != nil { return "callback_active" }
        if timedStopRequest != nil { return "timed_stop" }
        if isWaitingForStoryChoice { return "story_choice" }
        if isDialogueWindowHidden { return "window_hidden" }
        // MGFuncToLock tests _lkAuto, registered as 0x40 at 0x6bd34e.
        if storage.systemLockMask & 0x40 != 0 { return "system_auto_locked" }
        guard case .object(let handle) = try? storage.readIndexed("SysButton", 2) else { return "missing_button" }
        if !storage.enabledButtons.contains(handle) { return "button_disabled" }
        if !storage.buttonIsKnownUnlocked(handle) { return "button_locked_or_unverified" }
        if storage.buttonUserStrings[handle]?[0].map(asciiLower) != "auto" { return "button_name" }
        if storage.buttonUserStrings[handle]?[1].map(asciiLower) != "@@!avg_onsysbutton_auto" { return "button_target" }
        return nil
    }

    package mutating func dispatchResearchWindowAutoButton(_ handle: UInt64) throws {
        guard researchWindowAutoButton == handle, storage.frames.count < maximumFrames,
              var repository else { throw ResourceError.rejected("window_auto_button_not_selectable") }
        // The verified layout binds this button to the loaded script callback.
        // This direct research event does not simulate pointer hit testing.
        let callback = try repository.load("avg/avgsystem_custom.s")
        let destination = try callback.label("@@!AVG_OnSysButton_Auto")
        guard callback.ancestors[destination].isEmpty else {
            throw ResourceError.rejected("button_target_inside_control_block")
        }
        self.repository = repository
        storage.frames.append(ScriptFrame(returnIndex: pc, returnProgram: program))
        stopCallbackFrameDepth = storage.frames.count
        program = callback
        pc = destination
        phase = .ready
    }

    package var researchWindowSkipButton: UInt64? {
        guard researchWindowSkipUnavailableReason == nil,
              case .object(let handle) = try? storage.readIndexed("SysButton", 3) else { return nil }
        return handle
    }

    // Diagnostic only: report the first failed eligibility check at a host boundary.
    package var researchWindowSkipUnavailableReason: String? {
        if phase != .waitingForEvent { return "phase" }
        if stopCallback == nil { return "no_stop_callback" }
        if stopCallbackFrameDepth != nil { return "callback_active" }
        if timedStopRequest != nil { return "timed_stop" }
        if isWaitingForStoryChoice { return "story_choice" }
        if isDialogueWindowHidden { return "window_hidden" }
        if storage.systemLockMask & 0x80 != 0 { return "system_lock" }
        guard case .object(let handle) = try? storage.readIndexed("SysButton", 3) else { return "missing_button" }
        if !storage.enabledButtons.contains(handle) { return "button_disabled" }
        if storage.unknownSavedButtonLocks.contains(handle) { return "button_lock_unverified" }
        if !storage.buttonIsKnownUnlocked(handle) { return "button_locked" }
        if storage.buttonUserStrings[handle]?[0].map(asciiLower) != "skip" { return "button_name" }
        if storage.buttonUserStrings[handle]?[1].map(asciiLower) != "@@!avg_onsysbutton_skip" { return "button_target" }
        return nil
    }

    package mutating func dispatchResearchWindowSkipButton(_ handle: UInt64) throws {
        guard researchWindowSkipButton == handle, storage.frames.count < maximumFrames,
              var repository else { throw ResourceError.rejected("window_skip_button_not_selectable") }
        // The real layout binds SysButton[3] to this callback; MGFuncToLock
        // tests _lkSkip (0x80). The direct call is an injected research event.
        let callback = try repository.load("avg/avgsystem_custom.s")
        let destination = try callback.label("@@!AVG_OnSysButton_Skip")
        guard callback.ancestors[destination].isEmpty else {
            throw ResourceError.rejected("button_target_inside_control_block")
        }
        self.repository = repository
        storage.frames.append(ScriptFrame(returnIndex: pc, returnProgram: program))
        stopCallbackFrameDepth = storage.frames.count
        program = callback
        pc = destination
        phase = .ready
    }

    package var windowLoadButton: UInt64? {
        let canOpenMenu = (phase == .waitingForEvent && stopCallback != nil) ||
            (phase == .waiting && liveSaveWait != nil)
        guard canOpenMenu, stopCallbackFrameDepth == nil,
              timedStopRequest == nil, !isWaitingForStoryChoice, !isDialogueWindowHidden,
              case .object(let handle) = try? storage.readIndexed("SysButton", 5),
              storage.enabledButtons.contains(handle), storage.buttonIsKnownUnlocked(handle),
              storage.buttonUserStrings[handle]?[0].map(asciiLower) == "load",
              storage.buttonUserStrings[handle]?[1].map(asciiLower) == "@@!load" else { return nil }
        return handle
    }

    package var windowSaveButton: UInt64? {
        let canOpenMenu = (phase == .waitingForEvent && stopCallback != nil) ||
            (phase == .waiting && liveSaveWait != nil)
        guard canOpenMenu, stopCallbackFrameDepth == nil,
              timedStopRequest == nil, !isWaitingForStoryChoice, !isDialogueWindowHidden,
              case .object(let handle) = try? storage.readIndexed("SysButton", 4),
              storage.enabledButtons.contains(handle), storage.buttonIsKnownUnlocked(handle),
              storage.buttonUserStrings[handle]?[0].map(asciiLower) == "save",
              storage.buttonUserStrings[handle]?[1].map(asciiLower) == "@@!save" else { return nil }
        return handle
    }

    package var researchWindowSaveUnavailableReason: String? {
        if phase == .waiting {
            guard liveSaveWait != nil else { return "wait_state_unsupported" }
        } else if phase == .waitingForEvent {
            guard stopCallback != nil else { return "no_stop_callback" }
        } else {
            return "phase"
        }
        if stopCallbackFrameDepth != nil { return "callback_active" }
        if timedStopRequest != nil { return "timed_stop" }
        if isWaitingForStoryChoice { return "story_choice" }
        if isDialogueWindowHidden { return "window_hidden" }
        guard case .object(let handle) = try? storage.readIndexed("SysButton", 4) else { return "missing_button" }
        if !storage.enabledButtons.contains(handle) { return "button_disabled" }
        if !storage.buttonIsKnownUnlocked(handle) { return "button_locked_or_unverified" }
        if storage.buttonUserStrings[handle]?[0].map(asciiLower) != "save" { return "button_name" }
        if storage.buttonUserStrings[handle]?[1].map(asciiLower) != "@@!save" { return "button_target" }
        return nil
    }

    package mutating func dispatchWindowSaveButton(_ handle: UInt64) throws {
        guard windowSaveButton == handle, let source = playbackStatus.currentLocation else {
            throw ResourceError.rejected("window_save_button_not_selectable")
        }
        // SysButton[4] in layout_window.s routes to sysstartup.s / @@!Save.
        systemTaskResumeState = (phase, clickWaitRemaining, clickWaitInitial)
        systemTaskRequest = SystemTaskRequest(entryLabel: "@@!Save", source: source)
        returnsToDialogueAfterLoad = true
        phase = .waitingForSystemTask
    }

    /// Research-only entry for the native quick-save system label. The caller
    /// supplies an already validated ordinary save wait; no key mapping is implied.
    package mutating func dispatchResearchQuickSave(_ handle: UInt64) throws {
        guard windowSaveButton == handle, let source = playbackStatus.currentLocation else {
            throw ResourceError.rejected("window_save_button_not_selectable")
        }
        systemTaskResumeState = (phase, clickWaitRemaining, clickWaitInitial)
        systemTaskRequest = SystemTaskRequest(entryLabel: "@@!QuickSave", source: source)
        returnsToDialogueAfterLoad = true
        phase = .waitingForSystemTask
    }

    private var canDispatchQuickSystemTask: Bool {
        guard repository != nil, saveDirectory != nil, systemLoadRollback == nil,
              stopCallbackFrameDepth == nil, timedStopRequest == nil else { return false }
        return (phase == .waiting && clickWaitRemaining != nil) ||
            (phase == .waitingForEvent && stopCallback != nil)
    }

    package var canDispatchQuickSave: Bool {
        // The engine checks bit 1 for quicksave. Save assembly also needs a
        // verified continuation at the point where the host paused the VM.
        canDispatchQuickSystemTask && storage.systemLockMask & 0x02 == 0 && liveSaveWait != nil
    }

    package var canDispatchQuickLoad: Bool {
        canDispatchQuickSystemTask && storage.systemLockMask & 0x04 == 0
    }

    package mutating func dispatchQuickSave() throws {
        guard canDispatchQuickSave else { throw ResourceError.rejected("quick_save_unavailable") }
        try beginQuickSystemTask("@@!QuickSave")
    }

    package mutating func dispatchQuickLoad() throws {
        guard canDispatchQuickLoad else { throw ResourceError.rejected("quick_load_unavailable") }
        try beginQuickSystemTask("@@!QuickLoad")
    }

    private mutating func beginQuickSystemTask(_ label: String) throws {
        guard let source = playbackStatus.currentLocation else {
            throw ResourceError.rejected("quick_system_task_location_unavailable")
        }
        // Native 0x6d5a59/0x6d5a80 pass the default label through the
        // shared system-thread launcher at 0x6d5528.
        systemTaskResumeState = (phase, clickWaitRemaining, clickWaitInitial)
        systemTaskRequest = SystemTaskRequest(entryLabel: label, source: source)
        returnsToDialogueAfterLoad = true
        phase = .waitingForSystemTask
    }

    package mutating func dispatchWindowLoadButton(_ handle: UInt64) throws {
        guard windowLoadButton == handle, let source = playbackStatus.currentLocation else {
            throw ResourceError.rejected("window_load_button_not_selectable")
        }
        // Native host entry for the audited SysButton[5] registration.
        systemTaskResumeState = (phase, clickWaitRemaining, clickWaitInitial)
        systemTaskRequest = SystemTaskRequest(entryLabel: "@@!Load", source: source)
        returnsToDialogueAfterLoad = true
        phase = .waitingForSystemTask
    }

    package func canDispatchDialogueLogShortcut(keyCode: Int32) -> Bool {
        guard phase == .waitingForEvent, stopCallbackFrameDepth == nil,
              isResearchMessageTextWait || isResearchMessageAutoWait,
              !isDialogueWindowHidden, storage.systemKeyEnabled == true,
              let binding = storage.systemKeyBindings[keyCode], asciiLower(binding.name) == "log",
              binding.target.map(asciiLower) == "@@!log" else { return false }
        // The native action classifier returns 6 for log and checks lock bit 0x10 at 0x6c08b7.
        return storage.systemLockMask & 0x10 == 0
    }

    package mutating func dispatchDialogueLogShortcut(keyCode: Int32) throws {
        guard canDispatchDialogueLogShortcut(keyCode: keyCode), let source = playbackStatus.currentLocation else {
            throw ResourceError.rejected("dialogue_log_shortcut_unavailable")
        }
        systemTaskResumeState = (phase, clickWaitRemaining, clickWaitInitial)
        systemTaskRequest = SystemTaskRequest(entryLabel: "@@!Log", source: source)
        phase = .waitingForSystemTask
    }

    public mutating func dispatchWindowViewButton(_ handle: UInt64) throws {
        guard windowViewButton == handle, storage.frames.count < maximumFrames,
              var repository else {
            throw ResourceError.rejected("window_view_button_not_selectable")
        }
        let callback = try repository.load("avg/avgsystem_custom.s")
        let destination = try callback.label("@@!Avg_OnSysButton_View")
        guard callback.ancestors[destination].isEmpty else {
            throw ResourceError.rejected("button_target_inside_control_block")
        }
        self.repository = repository
        storage.frames.append(ScriptFrame(returnIndex: pc, returnProgram: program))
        stopCallbackFrameDepth = storage.frames.count
        program = callback
        pc = destination
        phase = .ready
    }

    /// Dispatch one event cycle while the script is suspended at stop.
    public mutating func dispatchStopCallback(pointer: (x: Int32, y: Int32)? = nil, buttonIndex: Int32? = nil, buttonArray: String = "Button", click: Bool = false, elapsedTicks: Int32 = 0) throws {
        guard phase == .waitingForEvent, let callback = stopCallback,
              stopCallbackFrameDepth == nil, storage.frames.count < maximumFrames, elapsedTicks >= 0 else {
            throw ResourceError.rejected("pending_stop_callback_required")
        }
        if let buttonIndex {
            guard !buttonArray.isEmpty, buttonArray.utf8.count <= 64,
                  buttonArray.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }),
                  case .object(let handle) = try storage.readIndexed(buttonArray,buttonIndex),
                  storage.enabledButtons.contains(handle), storage.buttonIsKnownUnlocked(handle),
                  storage.buttonScriptTargets[handle] != nil else {
                throw ResourceError.rejected("stop_button_not_selectable")
            }
            pendingButton = handle
        }
        if let request = timedStopRequest {
            // The original stop update publishes +0x50 before invoking its callback.
            storage.resultStopInt = request.duration
        }
        storage.frames.append(ScriptFrame(returnIndex: pc,returnProgram: program))
        callbackElapsedTicks = elapsedTicks
        pendingClick = click
        pointerPosition = pointer
        if let pointer { lastPointerPosition = pointer }
        stopCallbackFrameDepth = storage.frames.count
        pc = callback
        phase = .ready
    }

    /// Supply the host's current pointer position before the first script step.
    /// This is an input sample only; it does not dispatch a mouse event.
    package mutating func supplyInitialPointerSample(_ position: (x: Int32, y: Int32)) throws {
        guard phase == .ready, (-32768...32767).contains(position.x),
              (-32768...32767).contains(position.y) else {
            throw ResourceError.rejected("initial_pointer_sample_outside_profile")
        }
        pointerPosition = position
        lastPointerPosition = position
    }

    /// Research-only value event; the host may attach a pointer sample after a bounded
    /// resource-region candidate. Native hit-region selection and visual updates remain unproven.
    package mutating func dispatchSyntheticBarChange(name: String, value: Int32,
        pointer: (x: Int32, y: Int32)? = nil, objectUpdates: Int32 = 0) throws {
        guard inspectUnrenderedBars, allowLiveSoundPositionQuery,
              (0...4).contains(objectUpdates),
              case .object(let handle) = try storage.read(name), let bar = storage.bars[handle],
              bar.enabled, !bar.locked, value >= 0, value <= bar.maximum, value != bar.value,
              bar.changeCyclesRemaining == 0, !(bar.userStrings[0] ?? "").isEmpty else {
            throw ResourceError.rejected("synthetic_bar_change_outside_profile")
        }
        try dispatchStopCallback(pointer: pointer)
        syntheticBarCallbackActive = true
        // 0x67e424 sets the native change marker to four after a value change.
        // Explicit synthetic updates only; generic elapsed ticks do not establish
        // how many times the native host scheduled this object.
        storage.bars[handle]?.movePointer(to: value, changeCycles: 4 - objectUpdates)
    }

    public struct MoviePlaybackRequest: Sendable {
        public let resource: ScriptLocation
        public let placement: [Int32]
        public let size: (Int32, Int32)
        public let volume: Int32?
        fileprivate let handle: UInt64
    }
    public private(set) var moviePlaybackRequest: MoviePlaybackRequest?

    public struct SystemTaskRequest: Sendable {
        public let entryLabel: String
        public let source: ScriptLocation
    }
    public private(set) var systemTaskRequest: SystemTaskRequest?
    public private(set) var systemTaskExitRequested = false
    private var systemTaskEntryLabel: String?
    private var systemLoadTaskID: UUID?
    package var retainExperimentalSaveCandidate = false
    private struct SavedExecutionCandidate: Sendable {
        let program: ScriptProgram
        let index: Int
        var storage: ScriptStorage
        var repository: ScriptRepository?
        let wait: Int32?
        let clickInitial: Int32?
        let stopLabel: String?
        let streamNames: [Int32: String]
        let directNames: [Int: String]
        let streamFilters: [Int32: String]
    }
    private var savedExecutionCandidate: SavedExecutionCandidate?
    private var savedAudioStarts: [UInt64] = []
    private var phaseAfterSavedAudioStarts: ScriptMachinePhase?

    private mutating func startNextSavedAudio() {
        guard !savedAudioStarts.isEmpty else {
            if let previous = phaseAfterSavedAudioStarts { phase = previous }
            phaseAfterSavedAudioStarts = nil
            return
        }
        let channel = savedAudioStarts.removeFirst()
        storage.soundChannels[channel]?.playing = true
        storage.soundChannels[channel]?.playbackStartStep = executedSteps
        storage.soundChannels[channel]?.naturalCompletionStep = nil
        storage.soundChannels[channel]?.volumeControlToken = nil
        storage.soundChannels[channel]?.panControlToken = nil
        soundPlaybackChannel = channel
        soundPlaybackRequest = storage.soundChannels[channel]?.resource
        phase = .waitingForMedia
    }

    package struct ExperimentalSaveAudio: Encodable, Sendable {
        package var validatedImageFilterCount = 0
        package struct Gap: Encodable, Sendable {
            let recordOffset: Int
            let reason: String
            let status: EvidenceStatus = .unsupported
        }
        package var stagedStreams = 0
        package var scheduledStreams = 0
        package var scheduledDirectSounds = 0
        package var restoredStreamNames = 0
        package var unrestoredSavedStreamNames = 0
        package var restoredStreamFilters = 0
        package var unrestoredSavedStreamFilters = 0
        package var gaps: [Gap] = []
    }

    package struct ExperimentalScopeSnapshot: Encodable, Sendable {
        package let handleCount: Int
        package let handleKinds: [String]
        package let cameraInitialized: Bool
    }

    package var experimentalScopeSnapshot: ExperimentalScopeSnapshot {
        let handles = storage.frames.last?.tableScope ?? []
        let kinds = handles.map { handle -> String in
            if handle == ScriptStorage.cameraHandle { return "camera" }
            if storage.images[handle] != nil { return "image" }
            if storage.messages[handle] != nil { return "message" }
            if storage.buttons.contains(handle) { return "button" }
            if storage.tables[handle] != nil { return "table" }
            if storage.lists[handle] != nil { return "list" }
            return "unresolved"
        }
        return ExperimentalScopeSnapshot(handleCount: handles.count, handleKinds: kinds,
                                         cameraInitialized: storage.cameraInitialized)
    }

    @discardableResult
    package mutating func adoptExperimentalSaveCandidate(
        from task: ScriptMachine, directBufferBytes: ((ScriptLocation) throws -> Int)? = nil
    ) throws -> ExperimentalSaveAudio {
        guard retainExperimentalSaveCandidate, phase == .waitingForSystemTask,
              let rollback = systemLoadRollback, rollback.id == task.systemLoadTaskID,
              task.phase == .stopped, task.stopReason == "save_restore_candidate_ready",
              let staged = task.savedExecutionCandidate else {
            throw ResourceError.rejected("saved_execution_candidate_unavailable")
        }
        return try adoptSavedExecution(staged, boundary: task.saveResumeBoundary, capturedDisplay: task.savedCapturedDisplay,
                                       directBufferBytes: directBufferBytes)
    }

    package var stoppedAtStartupBackupLoad: Bool {
        guard phase == .stopped, storage.linkedPrimaryPlayMode == nil,
              let location = playbackStatus.currentLocation else { return false }
        return Self.isStartupBackupSite(location, line: 31)
    }

    package mutating func adoptStartupBackupCandidate(
        directBufferBytes: ((ScriptLocation) throws -> Int)?
    ) throws -> ExperimentalSaveAudio {
        guard retainExperimentalSaveCandidate, stoppedAtStartupBackupLoad,
              stopReason == "save_restore_candidate_ready", let staged = savedExecutionCandidate else {
            throw ResourceError.rejected("startup_backup_candidate_unavailable")
        }
        return try adoptSavedExecution(staged, boundary: saveResumeBoundary, capturedDisplay: savedCapturedDisplay,
                                       directBufferBytes: directBufferBytes)
    }

    package mutating func continueStartupAfterBackupFailure() throws {
        guard stoppedAtStartupBackupLoad else {
            throw ResourceError.rejected("startup_backup_load_not_active")
        }
        try continueAfterFailedInPlaceSaveRestore()
    }

    package var stoppedAtMemoryCheckpointLoad: Bool {
        phase == .stopped && pendingMemoryCheckpointRestore != nil && storage.linkedPrimaryPlayMode == nil
    }

    package func stageResearchSelectionCheckpointRestore() throws -> (machine: ScriptMachine, sha256: String, boundary: ScriptLocation)? {
        guard storage.linkedPrimaryPlayMode == nil, systemTaskRequest == nil, phase != .stopped, phase != .finished else {
            throw ResourceError.rejected("selection_checkpoint_probe_requires_restored_primary")
        }
        let source = #"""
        \scp,mdat
        \l,"SelectSaveData.svd"
        """#
        var staged = self
        staged.program = try ScriptProgram(ScriptDocument(data: Data(source.utf8),
            relativePath: "research/selection-checkpoint-restore.s"))
        staged.pc = 0
        staged.storage.frames = [ScriptFrame(returnIndex: nil)]
        staged.stopCallback = nil
        staged.stopCallbackFrameDepth = nil
        staged.inspectSaveRestoreBoundary = true
        staged.phase = .ready
        try staged.run(stepQuota: 64)
        if staged.stoppedAtMemoryCheckpointLoad,
           let index = storage.serializedMemoryCheckpointIndex(named: "SelectSaveData.svd"),
           let boundary = staged.saveResumeBoundary?.location {
            return (staged, storage.serializedMemoryCheckpoints[index].stream.sha256Hex, boundary)
        }
        if staged.phase == .finished, try staged.storage.readIndexed("ResultInt", 0).integer == 0 { return nil }
        throw ResourceError.rejected(staged.stopReason ?? "selection_checkpoint_probe_did_not_reach_load")
    }

    package mutating func adoptMemoryCheckpointCandidate(
        directBufferBytes: ((ScriptLocation) throws -> Int)?
    ) throws -> ExperimentalSaveAudio {
        guard stoppedAtMemoryCheckpointLoad,
              stopReason == "save_restore_candidate_ready", let staged = savedExecutionCandidate else {
            throw ResourceError.rejected("memory_checkpoint_candidate_unavailable")
        }
        return try adoptSavedExecution(staged, boundary: saveResumeBoundary, capturedDisplay: savedCapturedDisplay,
                                       directBufferBytes: directBufferBytes,
                                       preserveTemporaryCheckpoints: pendingMemoryCheckpointRestore == .temporary)
    }

    package var isLinkedLogTask: Bool { linkedLogJumpCheckpoints != nil }

    package var completedLinkedLogJump: Bool {
        phase == .finished && systemTaskExitRequested && isLinkedLogTask &&
            pendingMemoryCheckpointRestore == .temporary && savedExecutionCandidate != nil
    }

    private func prepareSavedExecution(
        _ staged: SavedExecutionCandidate, maximumSteps: Int, retainFullTrace: Bool
    ) throws -> ScriptMachine {
        guard let restored = try Self.makeSavedExecutionMachine(
            program: staged.program, index: staged.index, storage: staged.storage,
            repository: staged.repository, wait: staged.wait, clickInitial: staged.clickInitial, stopLabel: staged.stopLabel,
            maximumSteps: maximumSteps, maximumFrames: maximumFrames, retainFullTrace: retainFullTrace,
            imageLoader: imageLoader, imageMemberLookup: imageMemberLookup,
            imageExtendedValues: imageExtendedValues, imageMotionNames: imageMotionNames,
            imageLayerFlags: imageLayerFlags, imageLayerClockAdvance: imageLayerClockAdvance,
            saveTextureJPEGEncoder: saveTextureJPEGEncoder
        ) else { throw ResourceError.rejected("saved_execution_candidate_invalid") }
        return restored
    }

    private func runRestoredSubroutine(
        at destination: Int, label: String, staged: SavedExecutionCandidate, failurePrefix: String
    ) throws -> SavedExecutionCandidate {
        guard staged.program.ancestors[destination].isEmpty else {
            throw ResourceError.rejected("call_target_inside_control_block")
        }
        let callerDepth = staged.storage.frames.count
        guard callerDepth < maximumFrames else { throw ResourceError.rejected("call_frame_limit") }
        var restored = try prepareSavedExecution(staged, maximumSteps: 2048, retainFullTrace: false)

        // Run on a staged copy so the caller can commit changes at its restore boundary.
        let callerProgram = restored.program
        restored.storage.frames.append(.init(returnIndex: restored.pc, returnProgram: callerProgram, entryLabel: label,
            parameterCount: 0, integerParameters: Array(repeating: 0, count: 16),
            stringParameters: Array(repeating: "", count: 16)))
        restored.pc = try callerProgram.label(label)
        restored.phase = .ready
        while restored.phase == .ready && restored.storage.frames.count > callerDepth {
            if Task.isCancelled { throw ResourceError.rejected("machine_cancelled") }
            restored.step()
        }
        guard restored.phase == .ready, restored.storage.frames.count == callerDepth, restored.pc == staged.index,
              restored.program.document.records.indices.contains(restored.pc),
              restored.program.document.records[restored.pc].location == callerProgram.document.records[staged.index].location else {
            throw ResourceError.rejected("\(failurePrefix)_\(restored.stopReason ?? restored.phase.rawValue)")
        }
        var updated = staged
        updated.storage = restored.storage
        updated.repository = restored.repository
        return updated
    }

    package mutating func adoptLinkedLogJump(
        from task: ScriptMachine, directBufferBytes: ((ScriptLocation) throws -> Int)?
    ) throws -> ExperimentalSaveAudio {
        guard phase == .waitingForSystemTask, systemTaskEntryLabel.map(asciiLower) == "@@!log",
              let rollback = systemLoadRollback, rollback.id == task.systemLoadTaskID,
              task.completedLinkedLogJump, let staged = task.savedExecutionCandidate else {
            throw ResourceError.rejected("linked_log_jump_candidate_unavailable")
        }
        return try adoptSavedExecution(staged, boundary: task.saveResumeBoundary, capturedDisplay: task.savedCapturedDisplay,
                                       directBufferBytes: directBufferBytes, preserveTemporaryCheckpoints: true)
    }

    package mutating func continueAfterMemoryCheckpointFailure() throws {
        guard stoppedAtMemoryCheckpointLoad else {
            throw ResourceError.rejected("memory_checkpoint_load_not_active")
        }
        try continueAfterFailedInPlaceSaveRestore()
    }

    private mutating func continueAfterFailedInPlaceSaveRestore() throws {
        storage.clearResultBindings()
        try storage.resultInteger(0)
        pc += 1
        failedSaveRestore = false
        pendingMemoryCheckpointRestore = nil
        savedExecutionCandidate = nil
        stopReason = nil
        phase = .ready
    }

    private mutating func adoptSavedExecution(
        _ staged: SavedExecutionCandidate, boundary: SaveResumeBoundary?, capturedDisplay: Data?,
        directBufferBytes: ((ScriptLocation) throws -> Int)?, preserveTemporaryCheckpoints: Bool = false
    ) throws -> ExperimentalSaveAudio {
        try staged.storage.requireKnownSavedButtonStatesForAdoption()
        let verifiedFilters: Int
        if let saveImageFilterValidator {
            verifiedFilters = try staged.storage.validateSavedImageFilters(saveImageFilterValidator,
                                                                                videoProfiles: researchVideoSaveProfiles)
        } else {
            try staged.storage.requireSupportedSavedImageFiltersForAdoption()
            verifiedFilters = 0
        }
        guard !staged.storage.images.values.contains(where: {
            $0.isTheoraResource && $0.researchVideoProfile(in: researchVideoSaveProfiles) == nil &&
                $0.standaloneVideoLayerTick(at: staged.storage.visualTicks) == nil
        }) else {
            throw ResourceError.rejected("saved_standalone_video_clock_unverified")
        }
        var restored = try prepareSavedExecution(staged, maximumSteps: maximumSteps, retainFullTrace: retainFullTrace)
        restored.storage.unknownStreamFieldsOnRestore = true
        for handle in Array(restored.storage.soundChannels.keys) where ScriptStorage.isStreamHandle(handle) {
            restored.storage.soundChannels[handle]?.requestedSourceNameKnown = false
            restored.storage.soundChannels[handle]?.filterRequestKnown = false
            restored.storage.soundChannels[handle]?.volumeFilterCandidate = nil
            restored.storage.soundChannels[handle]?.filterChainCandidateText = nil
        }
        var audio = ExperimentalSaveAudio()
        audio.validatedImageFilterCount = verifiedFilters
        if let boundary, let prefix = boundary.statePrefix {
            // 0x5a0390 reloads the channel, restores player flags, and
            // applies the written delay triplets if their gates are positive.
            let volumeDelays = try prefix.ssndReferences.map { try $0.streamChannel?.savedVolumeDelay() }
            restored.storage.unknownStreamFieldsOnRestore =
                !prefix.streamPlayerFlagsMatchFreshLoadDefaults
            let seeks = Dictionary(uniqueKeysWithValues: boundary.stagedStreamSeeks
                .filter { $0.status == .verified }.map { ($0.recordOffset, $0) })
            let directResources = Dictionary(uniqueKeysWithValues: (boundary.directSoundResources ?? [])
                .compactMap { match in match.stagedLocation.map { (match.recordOffset, $0) } })
            restored.storage.directSoundChannelCount = storage.directSoundChannelCount
            restored.storage.directSoundChannels.removeAll()
            var directProbes = 0
            for (index, record) in prefix.dsndReferences.enumerated() {
                let offset = record.record.decodedOffset
                guard let channel = record.directChannel, channel.resumeDispatch != .bypassed else { continue }
                let resource = directResources[offset]
                let path = staged.directNames[index]
                // Native mode 1 and a short mode-2 buffer still have a
                // loaded resource. Stage the script-visible channel first.
                guard index < Int(restored.storage.directSoundChannelCount) else {
                    if record.directReloadRequested == true || channel.rawMode != 0 {
                        audio.gaps.append(.init(recordOffset: offset, reason: "saved_direct_channel_restore_unsupported"))
                    }
                    continue
                }
                guard channel.rawMode <= 3, channel.rawValueAt09 <= 31, (0...256).contains(channel.volumeInput),
                      (record.directReloadRequested == true || channel.rawMode != 0)
                        ? (resource != nil && path != nil) : resource == nil else {
                    audio.gaps.append(.init(recordOffset: offset,
                                            reason: "saved_direct_channel_restore_unsupported"))
                    continue
                }
                let handle = ScriptStorage.directSoundHandle(index)
                let type = Int32(channel.rawValueAt09)
                restored.storage.directSoundChannels[handle] = .init(resource: resource, resourceName: path,
                    volume: channel.volumeInput, volumeType: type)
                guard let looping = channel.loopingRequested, let resource else { continue }
                if let minimum = channel.minimumDecodedBufferBytes {
                    guard let directBufferBytes, directProbes < 4 else {
                        audio.gaps.append(.init(recordOffset: offset, reason: "saved_direct_buffer_check_unavailable"))
                        continue
                    }
                    directProbes += 1
                    do {
                        // A short buffer intentionally does not start in mode 2.
                        guard try directBufferBytes(resource) >= minimum else { continue }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        audio.gaps.append(.init(recordOffset: offset, reason: "saved_direct_buffer_check_failed"))
                        continue
                    }
                }
                // 0x5a100c dispatches direct buffers to a separate bank.
                // Keep their host playback IDs outside the indexed stream range.
                restored.storage.soundChannels[handle] = .init(loopRequest: looping ? -1 : 0,
                    volumeType: type, appliedVolumeType: type, volume: channel.volumeInput, resource: resource)
                restored.savedAudioStarts.append(handle)
                audio.scheduledDirectSounds += 1
            }
            for (index, record) in prefix.ssndReferences.enumerated() where record.streamChannel?.rawMode != 0 {
                guard let stream = record.streamChannel, let seek = seeks[record.record.decodedOffset],
                      case .object(let handle) = try? restored.storage.readIndexed("snd", Int32(index)) else {
                    audio.gaps.append(.init(recordOffset: record.record.decodedOffset,
                                            reason: "saved_stream_source_position_or_channel_unresolved"))
                    continue
                }
                guard let filter = staged.streamFilters[Int32(index)], filter.isEmpty else {
                    audio.gaps.append(.init(recordOffset: record.record.decodedOffset,
                                            reason: "saved_stream_filter_application_unverified"))
                    continue
                }
                // 0x5a053e and 0x5a0560 set volume and pan before the play gate.
                restored.storage.soundChannels[handle] = .init(seekSecondsRequest: seek.seconds,
                    panRequest: (stream.resumePan, 0, 0), volume: stream.resumeVolume, resource: seek.source)
                restored.storage.soundChannels[handle]?.requestedSourceNameKnown = false
                restored.storage.soundChannels[handle]?.filterRequestKnown = false
                audio.stagedStreams += 1
                if let repeats = stream.resumeRepeatCount {
                    if repeats >= -1 {
                        restored.storage.soundChannels[handle]?.loopRequest = repeats
                        // 0x5a0528–0x5a056a sets zero gain, requests a 2000 ms
                        // transition to the stored gain, and restores pan immediately.
                        restored.storage.soundChannels[handle]?.volumeDuration = 2000
                        restored.storage.soundChannels[handle]?.volumeLastDuration = 2000
                        restored.storage.soundChannels[handle]?.volumeChangePending = true
                        if let control = volumeDelays[index] {
                            restored.storage.soundChannels[handle]?.savedVolumeRampTarget = stream.resumeVolume
                            restored.storage.soundChannels[handle]?.volume = control.target
                            restored.storage.soundChannels[handle]?.volumeDuration = control.duration
                            restored.storage.soundChannels[handle]?.volumeDelay = control.delay
                            if let pan = stream.savedPanDelay {
                                restored.storage.soundChannels[handle]?.savedPanBaseline = stream.resumePan
                                restored.storage.soundChannels[handle]?.savedPanDelayOperands = (pan.targetBits, pan.durationBits)
                                restored.storage.soundChannels[handle]?.panRequest = (control.target, control.duration, pan.delay)
                                restored.storage.soundChannels[handle]?.panChangePending = true
                            }
                        }
                        restored.savedAudioStarts.append(handle)
                        audio.scheduledStreams += 1
                    } else {
                        audio.gaps.append(.init(recordOffset: record.record.decodedOffset,
                                                reason: "saved_stream_repeat_counter_unresolved"))
                    }
                }
            }
            audio.restoredStreamNames = restored.storage.stageSavedStreamNames(staged.streamNames)
            audio.unrestoredSavedStreamNames = min(32, prefix.ssndReferences.count) - audio.restoredStreamNames
            audio.restoredStreamFilters = restored.storage.stageSavedStreamFilters(staged.streamFilters)
            audio.unrestoredSavedStreamFilters = min(32, prefix.ssndReferences.count) - audio.restoredStreamFilters
            let savedVolumeTypes = Dictionary(uniqueKeysWithValues: prefix.ssndReferences.prefix(32).enumerated().compactMap { index, entry in
                entry.streamChannel.map { (Int32(index), $0.rawVolumeType) }
            })
            try restored.storage.stageSavedStreamVolumeTypes(savedVolumeTypes)
            // The native reader applies volume and pan even when +0x10 says
            // there is no loaded stream. Preserve those controls so a later
            // play or save cannot mistake an idle nonzero pan for the default.
            for (index, entry) in prefix.ssndReferences.prefix(32).enumerated() {
                guard let stream = entry.streamChannel, stream.rawMode == 0 else { continue }
                try restored.storage.stageSavedIdleStreamControls(stream, index: Int32(index))
            }
        }
        if !restored.savedAudioStarts.isEmpty {
            restored.phaseAfterSavedAudioStarts = restored.phase
            restored.startNextSavedAudio()
        }
        restored.replayEffectSurface = capturedDisplay
        restored.saveDirectory = saveDirectory
        restored.allowPrimarySave = allowPrimarySave
        restored.allowTitleQuit = allowTitleQuit
        if boundary?.engineState == nil {
            restored.storage.formCloseSaveFilename = storage.formCloseSaveFilename
        }
        restored.systemDataSaveTarget = systemDataSaveTarget
        restored.saveSources = saveSources
        restored.saveHeaderTemplate = saveHeaderTemplate
        restored.inferSaveStateSeed = inferSaveStateSeed
        restored.retainExperimentalSaveCandidate = retainExperimentalSaveCandidate
        restored.saveImageFilterValidator = saveImageFilterValidator
        restored.researchVideoSaveProfiles = researchVideoSaveProfiles
        restored.allowLiveSoundSwapHandoff = allowLiveSoundSwapHandoff
        restored.directSoundLockMilliseconds = directSoundLockMilliseconds
        restored.savedMotionUpdateThreshold = savedMotionUpdateThreshold
        // Explicit label-research options belong to the host session, not to
        // the serialized slot. Preserve them without enabling either by default.
        restored.allowLabelHistoryCandidate = allowLabelHistoryCandidate
        restored.allowLabelProgressCandidate = allowLabelProgressCandidate
        restored.allowImageFileLogCandidate = allowImageFileLogCandidate
        restored.allowAudioFileLogCandidate = allowAudioFileLogCandidate
        restored.captureSourceVisits = captureSourceVisits
        restored.coverageSourceFile = coverageSourceFile
        if preserveTemporaryCheckpoints {
            // The log-jump load keeps the temporary ring in the running interpreter.
            // Its serialized state carries only the separate mdat container.
            restored.logJumpLimit = logJumpLimit
            restored.logJumpCheckpoints = logJumpCheckpoints
            // In-place restoration keeps the primary session's registered inputs.
            // The log task has its own key table and clears it before exiting.
            restored.storage.systemKeyEnabled = storage.systemKeyEnabled
            restored.storage.systemKeyBindings = storage.systemKeyBindings
        } else if restored.storage.systemKeyBindings.isEmpty,
                  (try? restored.storage.read("Avg_InitFlag").integer) == 1,
                  let destination = try? staged.program.label("@@!Avg_OnKeySet"),
                  ["data7.pack/avg/avgsystem_custom.s", "data8.pack/avg/avgsystem_custom.s"].contains(
                    asciiLower(staged.program.document.records[destination].location.sourceFile)) {
            // The disk candidate lacks the transient input table. Use the same
            // registration routine as Avg_Create, with the staged settings.
            let inputs = try runRestoredSubroutine(at: destination, label: "@@!Avg_OnKeySet", staged: staged,
                                                   failurePrefix: "saved_story_input_initialization").storage
            restored.storage.systemKeyEnabled = inputs.systemKeyEnabled
            restored.storage.systemKeyBindings = inputs.systemKeyBindings
            restored.storage.mouseGestureMode = inputs.mouseGestureMode
            restored.storage.swipeSettings = inputs.swipeSettings
        }
        self = restored
        return audio
    }

    private var failedSaveRestore = false
    private var pendingMemoryCheckpointRestore: CheckpointScope?
    private var returnsToDialogueAfterLoad = false
    private var pendingSlotDeletion: (name: String, sha256: String, confirmed: Bool)?
    private var systemTaskResumeState: (phase: ScriptMachinePhase,
                                        clickWaitRemaining: Int32?, clickWaitInitial: Int32?)?
    private var systemLoadRollback: (id: UUID, bindings: [Data: ScriptBinding], mask: Int32, outputMask: Int32, mode: Int32, nameSlots: [String])?

    public mutating func finishSystemLoadTask(_ task: ScriptMachine) throws {
        guard phase == .waitingForSystemTask, task.systemTaskExitRequested,
              let rollback = systemLoadRollback, task.systemLoadTaskID == rollback.id,
              !task.completedLinkedLogJump else {
            throw ResourceError.rejected("system_task_exit_required")
        }
        systemLoadRollback = nil
        systemTaskEntryLabel = nil
        if let resume = systemTaskResumeState {
            phase = resume.phase
            clickWaitRemaining = resume.clickWaitRemaining
            clickWaitInitial = resume.clickWaitInitial
        } else {
            phase = returnsToDialogueAfterLoad ? .waitingForEvent : .ready
        }
        systemTaskResumeState = nil
        returnsToDialogueAfterLoad = false
    }

    /// Host recovery for a failed save restore. The failed guest task
    /// remains stopped so the caller can retain its diagnostics.
    package mutating func discardFailedSaveLoadTask(_ task: ScriptMachine) throws {
        guard phase == .waitingForSystemTask, task.phase == .stopped,
              task.failedSaveRestore,
              let rollback = systemLoadRollback, task.systemLoadTaskID == rollback.id else {
            throw ResourceError.rejected("failed_save_load_task_required")
        }
        _ = abortSystemLoad()
    }

    package mutating func abortSystemLoad() -> Bool {
        guard phase == .waitingForSystemTask else { return false }
        if let rollback = systemLoadRollback {
            storage.system = rollback.bindings
            storage.systemInputMask = rollback.mask
            storage.systemOutputMask = rollback.outputMask
            storage.systemPlayMode = rollback.mode
            storage.systemNameSlots = rollback.nameSlots
        }
        systemLoadRollback = nil
        systemTaskRequest = nil
        systemTaskEntryLabel = nil
        if let resume = systemTaskResumeState {
            phase = resume.phase
            clickWaitRemaining = resume.clickWaitRemaining
            clickWaitInitial = resume.clickWaitInitial
        } else {
            phase = returnsToDialogueAfterLoad ? .waitingForEvent : .ready
        }
        systemTaskResumeState = nil
        returnsToDialogueAfterLoad = false
        return true
    }

    public struct ScreenCaptureRequest: Sendable {
        package enum Scene: String, Encodable, Sendable {
            case suspendedPrimary, restoredCheckpoint
        }
        public let priority: Int32
        package let scene: Scene
        package let location: ScriptLocation
        fileprivate let handle: UInt64
    }
    public private(set) var screenCaptureRequest: ScreenCaptureRequest?

    package func systemTaskCaptureScene(for task: ScriptMachine) throws -> ScriptMachine {
        guard phase == .waitingForSystemTask, let rollback = systemLoadRollback, rollback.id == task.systemLoadTaskID,
              let request = task.screenCaptureRequest else {
            throw ResourceError.rejected("game_thread_capture_scene_unavailable")
        }
        if request.scene == .restoredCheckpoint {
            guard task.isLinkedLogTask, task.pendingMemoryCheckpointRestore == .temporary,
                  let staged = task.savedExecutionCandidate else {
                throw ResourceError.rejected("game_thread_capture_checkpoint_unavailable")
            }
            // Render a disposable snapshot. The menu can still fail before the host adopts the checkpoint.
            return try prepareSavedExecution(staged, maximumSteps: maximumSteps, retainFullTrace: false)
        }
        return try pausedSystemTaskScene()
    }

    package func pausedSystemTaskScene() throws -> ScriptMachine {
        guard phase == .waitingForSystemTask, systemLoadRollback != nil,
              let resume = systemTaskResumeState else {
            throw ResourceError.rejected("game_thread_capture_scene_unavailable")
        }
        var paused = self
        paused.phase = resume.phase
        paused.clickWaitRemaining = resume.clickWaitRemaining
        paused.clickWaitInitial = resume.clickWaitInitial
        return paused
    }

    public mutating func supplyScreenCapture(_ source: ScriptLocation, width: Int, height: Int) throws {
        guard phase == .waitingForScreenCapture, let request = screenCaptureRequest,
              var image = storage.images[request.handle],
              width == 1280, height == 720, source.byteOffset == 0,
              (1...8 * 1024 * 1024).contains(source.byteLength) else {
            throw ResourceError.rejected("invalid_game_thread_image_capture")
        }
        image.resource = source
        image.resourceName = nil
        image.isTheoraResource = false
        image.standaloneVideoDuration = nil
        image.resourceLoadLocation = request.location
        image.width = width
        image.height = height
        image.memberCount = 1
        image.selectedMember = nil
        image.motionStartTick = nil
        image.savedLayerTimeSnapshot = nil
        image.layerAuxiliaryFlags = Array(repeating: 1, count: 256)
        image.restoredMotionThreshold = nil
        image.restoredMotionRemainder = 0
        image.layerClockRemainder = 0
        image.boundImages.removeAll()
        image.boundImageNames.removeAll()
        image.extendedDefaultsPrepared = false
        image.extendedScalarValues.removeAll()
        image.hasExtendedContainerMetadata = false
        storage.images[request.handle] = image
        screenCaptureRequest = nil
        phase = .ready
    }

    public mutating func startSystemLoadTask() throws -> ScriptMachine {
        guard phase == .waitingForSystemTask, let request = systemTaskRequest,
              var taskRepository = repository else {
            throw ResourceError.rejected("pending_system_task_required")
        }
        let startup = try taskRepository.load("sysstartup.s")
        var task = try ScriptMachine(program: startup, allowExperimental: true, entryLabel: request.entryLabel,
            maximumSteps: 15_000, maximumFrames: maximumFrames, repository: taskRepository,
            configuration: storage.configuration, imageLoader: imageLoader, imageMemberLookup: imageMemberLookup,
            imageExtendedValues: imageExtendedValues, imageMotionNames: imageMotionNames,
            imageLayerFlags: imageLayerFlags,
            imageLayerClockAdvance: imageLayerClockAdvance,
            saveTextureJPEGEncoder: saveTextureJPEGEncoder,
            retainFullTrace: retainFullTrace)
        // FUN_006bca4c initializes these names in each native script thread;
        // the regular load menu also references _SelectSaveFilename.
        for (name, value) in [("_selectsavefilename", "SelectSaveData.svd"),
                              ("_backupsavefilename", "BackupSaveData.svd"),
                              ("_quicksavefilename", "QuickSaveData.svd")] {
            task.storage.global[Data(name.utf8)] = .init(elements: [.string(value)])
        }
        task.allowTitleQuit = allowTitleQuit && asciiLower(request.entryLabel) == "@@!quit"
        task.storage.linkedPrimaryPlayMode = storage.systemPlayMode
        task.storage.linkedPrimaryInputMask = storage.systemInputMask
        task.storage.linkedPrimaryOutputMask = storage.systemOutputMask
        task.storage.linkedPrimaryFormCloseSaveFilename = storage.formCloseSaveFilename
        task.storage.fileLogValues = storage.fileLogValues
        task.storage.lineLogValues = storage.lineLogValues
        task.storage.syncDialogueLog(from: storage)
        if asciiLower(request.entryLabel) == "@@!log" {
            task.linkedLogJumpCheckpoints = logJumpCheckpoints
            task.storage.isLogMenu = true
        }
        task.storage.importedLabelHistory = storage.importedLabelHistory
        task.storage.sessionSaveNames = storage.sessionSaveNames
        task.storage.sessionSaveMetadata = storage.sessionSaveMetadata
        task.storage.sessionSaveThumbnails = storage.sessionSaveThumbnails
        task.storage.systemNameSlots = storage.systemNameSlots
        task.saveDirectory = saveDirectory
        task.inferSaveStateSeed = inferSaveStateSeed
        task.saveHeaderTemplate = saveHeaderTemplate
        task.systemDataSaveTarget = systemDataSaveTarget
        task.inspectSaveRestoreBoundary = inspectSaveRestoreBoundary
        task.savedMotionUpdateThreshold = savedMotionUpdateThreshold
        task.researchVideoSaveProfiles = researchVideoSaveProfiles
        task.saveSources = saveSources
        task.retainExperimentalSaveCandidate = retainExperimentalSaveCandidate
        let taskID = UUID()
        task.systemLoadTaskID = taskID
        systemLoadRollback = (taskID, storage.system, storage.systemInputMask, storage.systemOutputMask, storage.systemPlayMode, storage.systemNameSlots)
        systemTaskEntryLabel = request.entryLabel
        systemTaskRequest = nil
        return task
    }

    package mutating func startAutosaveLoadTask(slot: String) throws -> ScriptMachine {
        guard Self.isPrimaryAutosaveSlotName(slot), systemTaskRequest?.entryLabel == "@@!QuickLoad" else {
            throw ResourceError.rejected("autosave_load_task_requires_autosave_slot")
        }
        var task = try startSystemLoadTask()
        // Reuse the direct load flow with a per-task path. The normal quick slot
        // and the primary thread's bindings keep their original names.
        task.storage.global[Data("_selectsavefilename".utf8)] = .init(elements: [.string(slot)])
        return task
    }

    public mutating func runSystemLoadTask(_ task: inout ScriptMachine,
                                           streamPositions: [Int32: Int32] = [:],
                                           streamPans: [Int32: SavedStreamPanSample] = [:],
                                           streamVolumes: [Int32: SavedDelayedVolumeSample] = [:],
                                           streamRepeats: [Int32: SavedFiniteRepeatSample] = [:],
                                           displaySurfaces: [Int: Data] = [:],
                                           thumbnail: Data? = nil) throws {
        guard phase == .waitingForSystemTask, task.storage.linkedPrimaryPlayMode != nil,
              let rollback = systemLoadRollback, task.systemLoadTaskID == rollback.id else {
            throw ResourceError.rejected("linked_system_task_required")
        }
        task.storage.linkedPrimaryPlayMode = storage.systemPlayMode
        task.storage.linkedPrimaryInputMask = storage.systemInputMask
        task.storage.linkedPrimaryOutputMask = storage.systemOutputMask
        task.storage.linkedPrimaryFormCloseSaveFilename = storage.formCloseSaveFilename
        task.storage.systemNameSlots = storage.systemNameSlots
        // The primary machine is suspended while the task uses the shared svar table.
        task.storage.system = storage.system
        let saveSnapshot = self
        task.saveWriteHandler = { name, metadata, taskStorage, expectedSystemSHA256 in
            var writer = saveSnapshot
            return try writer.publishSaveSlot(name, metadata: metadata, taskStorage: taskStorage,
                expectedSystemSHA256: expectedSystemSHA256, streamPositions: streamPositions, streamPans: streamPans,
                streamVolumes: streamVolumes, streamRepeats: streamRepeats,
                displaySurfaces: displaySurfaces, thumbnail: thumbnail)
        }
        defer {
            systemDataSaveTarget = task.systemDataSaveTarget
            storage.system = task.storage.system
            storage.systemNameSlots = task.storage.systemNameSlots
            storage.sessionSaveNames = task.storage.sessionSaveNames
            storage.sessionSaveMetadata = task.storage.sessionSaveMetadata
            storage.sessionSaveThumbnails = task.storage.sessionSaveThumbnails
            saveSources = task.saveSources
            storage.syncDialogueLog(from: task.storage)
            if let mask = task.storage.linkedPrimaryInputMask { storage.systemInputMask = mask }
            if let mask = task.storage.linkedPrimaryOutputMask { storage.systemOutputMask = mask }
            if let mode = task.storage.linkedPrimaryPlayMode { storage.systemPlayMode = mode }
        }
        try task.run(stepQuota: 15_000)
    }

    private mutating func publishSaveSlot(_ name: String, metadata: [String], taskStorage: ScriptStorage,
                                          expectedSystemSHA256: String?, streamPositions: [Int32: Int32],
                                          streamPans: [Int32: SavedStreamPanSample],
                                          streamVolumes: [Int32: SavedDelayedVolumeSample],
                                          streamRepeats: [Int32: SavedFiniteRepeatSample],
                                          displaySurfaces: [Int: Data], thumbnail: Data?) throws -> SlotPublication {
        guard let directory = saveDirectory else {
            throw ResourceError.rejected("save_write_directory_unavailable")
        }
        return try SaveTransaction.withRecoveredDirectory(directory) { transaction in
            let systemTarget = systemDataSaveTarget
            let originalSystem = try systemTarget.flatMap {
                try directory.readIfPresent($0.name, limit: SaveEnvelope.maxFileBytes)
            }
            if systemTarget != nil, originalSystem?.sha256Hex != expectedSystemSHA256 {
                throw ResourceError.rejected("system_data_changed_since_session_load")
            }
            let destination = try Self.resolveSaveSlotName(name, entries: directory.entries())
            let slot = try prepareTimedWaitSlotCandidate(destination, metadata: metadata,
                streamPositions: streamPositions, streamPans: streamPans,
                streamVolumes: streamVolumes, streamRepeats: streamRepeats,
                displaySurfaces: displaySurfaces, thumbnail: thumbnail)
            if let systemTarget {
                let updated: Data
                if let originalSystem {
                    let source = try SaveSystemData(data: originalSystem, headerTemplate: systemTarget.headerTemplate)
                    updated = try source.replacingScalars(from: taskStorage)
                } else {
                    updated = try SaveSystemData.encodeNew(from: taskStorage, headerTemplate: systemTarget.headerTemplate, seed: slot.seed)
                }
                if updated != originalSystem {
                    let receipt = try transaction.replacePair(slotName: destination, slotData: slot.data, slotSeed: slot.seed,
                        expectedSlot: slot.expectedDestination, systemName: systemTarget.name,
                        originalSystem: originalSystem, updatedSystem: updated)
                    return .init(receipt: receipt, name: destination, sha256: slot.data.sha256Hex,
                                 systemDataSHA256: updated.sha256Hex)
                }
            }
            let receipt = try SaveEnvelope.replaceSlotAtomically(destination, in: directory,
                with: slot.data, seed: slot.seed, expectedDestination: slot.expectedDestination)
            return .init(receipt: receipt, name: destination, sha256: slot.data.sha256Hex)
        }
    }

    @discardableResult
    private mutating func recordSlotPublication(_ publication: SlotPublication, into candidate: inout ScriptStorage) -> String {
        if let sha256 = publication.systemDataSHA256 { systemDataSaveTarget?.sha256 = sha256 }
        var sessionRefreshIssue: String?
        if let saveDirectory {
            do {
                let bytes = try saveDirectory.read(publication.name, limit: SaveEnvelope.maxFileBytes)
                guard bytes.sha256Hex == publication.sha256 else {
                    throw ResourceError.rejected("save_slot_changed_after_publication")
                }
                try candidate.recordSessionSaveSlot(name: publication.name, bytes: bytes)
                saveSources[Data(asciiLower(publication.name).utf8)] =
                    (publication.name, publication.sha256, true)
            } catch {
                // Publication already occurred; an old digest or
                // partially refreshed metadata must not describe it.
                let key = Data(asciiLower(publication.name).utf8)
                candidate.forgetSessionSaveSlot(key)
                saveSources.removeValue(forKey: key)
                sessionRefreshIssue = String(describing: error)
            }
        }
        let durabilityIssue = publication.receipt.directorySyncError.map {
            "save_committed_directory_sync_unconfirmed_errno_\($0)"
        } ?? publication.receipt.cleanupIssue
        if var issue = durabilityIssue {
            if let sessionRefreshIssue {
                issue += "; save_committed_session_slot_refresh_unconfirmed: \(sessionRefreshIssue)"
            }
            lastSaveWriteIssue = issue
            return "save_slot_write_durability_unconfirmed"
        } else if let sessionRefreshIssue {
            lastSaveWriteIssue = "save_committed_session_slot_refresh_unconfirmed: \(sessionRefreshIssue)"
            return "save_slot_write_committed_index_refresh_unconfirmed"
        } else {
            lastSaveWriteIssue = nil
            return "save_slot_write_candidate"
        }
    }

    // Both primary save commands in the fixed fourth-title misc.s return
    // immediately after the slot write.
    private static let primarySaveSources = [
        "data7.pack/misc/misc.s": "2bab8e247a68c514c82533bf4aee67f22009a0827efe7b7f841f82a3fb300c5c",
        "data8.pack/misc/misc.s": "4d500449080cb39b3399d757ba1208496ff4d3fad6dac226dec69b9fcd532305",
        "local-cn.pack/script/misc/misc.s": "567caa42ce08c020373dc9e0d647ede683748598c1949aa709f8bb08be469428",
    ]

    private static let temporarySaveSources = [
        "data7.pack/avg/avgsystem_logjump.s": "202d77c8eb8147897c836c3f2ec43061a9e3ccad008fae405a3541117d6c2e8b",
        "data8.pack/avg/avgsystem_logjump.s": "e9b23c788e8c27e8bbafa8a93ec17446fd3309060b69f16cc349f605ecf28aaf",
    ]

    enum CheckpointScope: String, Sendable {
        case disk = "dat"
        case memory = "mdat"
        case temporary = "tdat"

        var handle: UInt64 {
            switch self {
            case .disk: ScriptStorage.saveDataHandle
            case .memory: ScriptStorage.memoryDataHandle
            case .temporary: ScriptStorage.temporaryDataHandle
            }
        }
    }

    private static func checkpointScope(at resume: ScriptRecord) -> CheckpointScope? {
        if isPrimarySaveReturn(resume) { return .disk }
        if isPrimaryMemorySaveResume(resume) { return .memory }
        if resume.kind == .command && resume.command.map(asciiLower) == "ret" && resume.fields.isEmpty &&
            resume.location.lineNumber == 107 &&
            temporarySaveSources[resume.location.sourceFile] == resume.location.sourceSHA256 {
            return .temporary
        }
        return nil
    }

    private func makePrimaryTemporarySaveRequest(record: ScriptRecord, next: Int, name: String,
                                                 options: Int32, mode: Int32, candidate: ScriptStorage) -> PrimarySaveRequest? {
        guard allowPrimarySave, saveHeaderTemplate != nil, candidate.linkedPrimaryPlayMode == nil,
              options == 14, (1...2).contains(mode), logJumpLimit > 0,
              candidate.frames.last?.entryLabel.map(asciiLower) == "@@!avg_logjumpgamesave",
              record.location.lineNumber == 106,
              Self.temporarySaveSources[record.location.sourceFile] == record.location.sourceSHA256,
              let resume = program.document.records.indices.dropFirst(next).first(where: { index in
                  let kind = program.document.records[index].kind
                  return kind != .layout && kind != .empty
              }), Self.checkpointScope(at: program.document.records[resume]) == .temporary,
              program.document.records[resume].location.sourceFile == record.location.sourceFile else { return nil }
        return .init(priority: 0, name: name, memoryOptions: options, temporaryMode: mode,
                     metadata: candidate.systemNameSlots + [""], resumeIndex: resume)
    }

    private mutating func storeTemporaryCheckpoint(_ checkpoint: TemporaryCheckpoint) {
        guard logJumpLimit > 0 else { return }
        logJumpCheckpoints.removeAll { $0.key == checkpoint.key }
        if logJumpCheckpoints.count == logJumpLimit { logJumpCheckpoints.removeFirst() }
        logJumpCheckpoints.append(checkpoint)
    }

    private static func isPrimarySaveReturn(_ record: ScriptRecord) -> Bool {
        record.kind == .command && record.command.map(asciiLower) == "ret" && record.fields.isEmpty &&
            [388, 441].contains(record.location.lineNumber) &&
            primarySaveSources[record.location.sourceFile] == record.location.sourceSHA256
    }

    private static func isPrimaryMemorySaveResume(_ record: ScriptRecord) -> Bool {
        record.kind == .command && record.command.map(asciiLower) == "scp" &&
            record.fields.count == 1 && asciiLower(record.fields[0].value) == "mdat" &&
            record.location.lineNumber == 424 &&
            primarySaveSources[record.location.sourceFile] == record.location.sourceSHA256
    }

    private func makePrimaryMemorySaveRequest(record: ScriptRecord, next: Int, name: String,
                                              options: Int32, mode: Int32, candidate: ScriptStorage) -> PrimarySaveRequest? {
        let key = asciiLower(name)
        guard allowPrimarySave, systemDataSaveTarget != nil, saveDirectory != nil, saveHeaderTemplate != nil,
              candidate.linkedPrimaryPlayMode == nil, mode == 2,
              (key == "selectsavedata.svd" && options == 0x0b) || (key == "scenesavedata.svd" && options == 0x0a),
              candidate.frames.last?.entryLabel.map(asciiLower) == "@@!misc_memorysave",
              record.location.lineNumber == 422,
              Self.primarySaveSources[record.location.sourceFile] == record.location.sourceSHA256,
              let resume = program.document.records.indices.dropFirst(next).first(where: { index in
                  let kind = program.document.records[index].kind
                  return kind != .layout && kind != .empty
              }), Self.isPrimaryMemorySaveResume(program.document.records[resume]),
              program.document.records[resume].location.sourceFile == record.location.sourceFile else { return nil }
        // Both supported memory-save options omit the thumbnail capture.
        return .init(priority: 0, name: name, memoryOptions: options,
                     metadata: candidate.systemNameSlots + [""], resumeIndex: resume)
    }

    package static func isPrimaryAutosaveSlotName(_ name: String) -> Bool {
        let name = asciiLower(name)
        let prefix = "autosavedata"
        let suffix = ".svd"
        guard name.utf8.count <= 255, name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
        let digits = name.utf8.dropFirst(prefix.utf8.count).dropLast(suffix.utf8.count)
        return !digits.isEmpty && digits.allSatisfy { (48...57).contains($0) }
    }

    private func makePrimarySaveRequest(record: ScriptRecord, next: Int, name: String,
                                        metadata: [String], candidate: ScriptStorage) -> PrimarySaveRequest? {
        let line = record.location.lineNumber
        let label = candidate.frames.last?.entryLabel.map(asciiLower)
        let auto = line == 387 && label == "@@!misc_autosave" && Self.isPrimaryAutosaveSlotName(name)
        let backup = line == 440 && label == "@@!misc_exceptionerrorsave" && asciiLower(name) == "exceptionbackup.svd"
        guard auto || backup,
              Self.primarySaveSources[record.location.sourceFile] == record.location.sourceSHA256,
              let priority = candidate.thumbnailPriorities?.0,
              systemDataSaveTarget != nil, saveDirectory != nil,
              let resumeIndex = program.document.records.indices.dropFirst(next).first(where: { index in
                  let kind = program.document.records[index].kind
                  return kind != .layout && kind != .empty
              }) else { return nil }
        let resume = program.document.records[resumeIndex]
        guard Self.isPrimarySaveReturn(resume),
              resume.location.sourceFile == record.location.sourceFile,
              resume.location.lineNumber == line + 1 else { return nil }
        return .init(priority: priority, name: name, metadata: metadata, resumeIndex: resumeIndex)
    }

    package mutating func publishPrimarySave(streamPositions: [Int32: Int32],
                                             streamPans: [Int32: SavedStreamPanSample],
                                             streamVolumes: [Int32: SavedDelayedVolumeSample],
                                             streamRepeats: [Int32: SavedFiniteRepeatSample],
                                             thumbnail: Data) throws {
        guard phase == .waitingForPrimarySave, let request = primarySaveRequest else {
            throw ResourceError.rejected("primary_save_not_pending")
        }
        var candidate = storage
        candidate.clearResultBindings()
        try candidate.resultInteger(1)
        if request.memoryOptions != nil {
            guard let header = saveHeaderTemplate, let name = request.name.data(using: .utf16LittleEndian) else {
                throw ResourceError.rejected("memory_checkpoint_capture_configuration")
            }
            let thread = try encodeTimedWaitThread(readerOpaqueFields: Data(repeating: 0, count: 64), allowsIndexedLocals: true)
            let template = try TimedWaitSaveTemplate.emptyState(thread: thread)
            let timing = try Self.currentSaveTiming()
            let stream = try encodeTimedWaitResearchSlot(template: template, positions: streamPositions, streamPans: streamPans,
                streamVolumes: streamVolumes, streamRepeats: streamRepeats, metadata: request.metadata,
                thumbnail: Data(), savedDays: timing.days, seed: timing.seed, packedCodec: request.temporaryMode == 1 ? 0 : 1,
                clearHeaderTemplate: header, headerSeed: timing.seed, channelCount: Self.streamSaveChannelCount)
            _ = try SaveEnvelope.decodeSlotState(stream, seed: SaveEnvelope.validatedSlotSeed(stream, clearTemplate: header))
            let key = Data(asciiLower(request.name).utf8)
            if request.temporary {
                storeTemporaryCheckpoint(.init(key: key, stream: stream))
                lastSaveWriteIssue = nil
            } else {
                let fields = withUnsafeBytes(of: timing.days.bitPattern.littleEndian) { Data($0) }
                let checkpoint = SaveEngineState.MemoryCheckpoint(nameUTF16: name, fixedFields: fields, stream: stream)
                if let index = candidate.serializedMemoryCheckpointIndex(named: request.name) {
                    candidate.serializedMemoryCheckpoints[index] = checkpoint
                } else {
                    candidate.serializedMemoryCheckpoints.append(checkpoint)
                }
                try publishStandaloneSystemData(candidate, seed: timing.seed)
                memoryCheckpoints.removeValue(forKey: key)
            }
        } else {
            var writer = self
            let publication = try writer.publishSaveSlot(request.name, metadata: request.metadata, taskStorage: candidate,
                expectedSystemSHA256: systemDataSaveTarget?.sha256, streamPositions: streamPositions, streamPans: streamPans,
                streamVolumes: streamVolumes, streamRepeats: streamRepeats, displaySurfaces: [:], thumbnail: thumbnail)
            recordSlotPublication(publication, into: &candidate)
            if macExceptionBackupContinuation != nil, asciiLower(request.name) == "exceptionbackup.svd" {
                macExceptionBackupContinuation?.saveCommitted = true
            }
        }
        storage = candidate
        primarySaveRequest = nil
        macExceptionBackupLiveWaitOverride = nil
        phase = .ready
    }

    package mutating func failPrimarySave(_ error: Error) throws {
        guard phase == .waitingForPrimarySave, let request = primarySaveRequest else {
            throw ResourceError.rejected("primary_save_not_pending")
        }
        if request.temporary {
            let key = Data(asciiLower(request.name).utf8)
            if !logJumpCheckpoints.contains(where: { $0.key == key }) {
                storeTemporaryCheckpoint(.init(key: key, stream: nil))
            }
        } else if let options = request.memoryOptions, storage.serializedMemoryCheckpointIndex(named: request.name) == nil {
            // Preserve the bounded runtime snapshot used by the script's retry loop.
            // It remains distinct from an encoded checkpoint that can be adopted.
            memoryCheckpoints[Data(asciiLower(request.name).utf8)] = .init(name: request.name, options: options,
                mode: 2, storage: storage, program: program, resumeIndex: request.resumeIndex)
        }
        storage.clearResultBindings()
        try storage.resultInteger(0)
        lastSaveWriteIssue = String(describing: error)
        if macExceptionBackupContinuation != nil, asciiLower(request.name) == "exceptionbackup.svd" {
            macExceptionBackupContinuation?.saveIssue = String(describing: error)
        }
        primarySaveRequest = nil
        macExceptionBackupLiveWaitOverride = nil
        phase = .ready
    }

    package mutating func synchronizeSystemDataAfterRestore(from previous: ScriptMachine) -> String? {
        guard systemDataSaveTarget != nil else { return nil }
        // Keep the session-wide values and read history from before the restore.
        // The host invokes this only after the restored playback passes preflight.
        do {
            try publishStandaloneSystemData(previous.storage, seed: Self.currentSaveTiming().seed)
            return lastSaveWriteIssue
        } catch {
            return String(describing: error)
        }
    }

    private mutating func publishStandaloneSystemData(_ snapshot: ScriptStorage, seed: UInt32) throws {
        guard let directory = saveDirectory, let systemTarget = systemDataSaveTarget else {
            throw ResourceError.rejected("memory_checkpoint_system_data_unavailable")
        }
        let (digest, issue) = try SaveTransaction.withRecoveredDirectory(directory) { _ in
            let original = try directory.readIfPresent(systemTarget.name, limit: SaveEnvelope.maxFileBytes)
            guard original?.sha256Hex == systemTarget.sha256 else {
                throw ResourceError.rejected("system_data_changed_since_session_load")
            }
            let updated: Data
            if let original {
                let source = try SaveSystemData(data: original, headerTemplate: systemTarget.headerTemplate)
                updated = try source.replacingScalars(from: snapshot)
            } else {
                updated = try SaveSystemData.encodeNew(from: snapshot, headerTemplate: systemTarget.headerTemplate, seed: seed)
            }
            let digest = updated.sha256Hex
            guard updated != original else { return (digest, nil as String?) }
            let expected = systemTarget.sha256.map(SafeDirectory.AtomicDestinationExpectation.sha256) ?? .absent
            let receipt = try directory.replaceAtomically(systemTarget.name, data: updated, expectedDestination: expected)
            return (digest, receipt.directorySyncError.map { "save_committed_directory_sync_unconfirmed_errno_\($0)" })
        }
        systemDataSaveTarget?.sha256 = digest
        lastSaveWriteIssue = issue
    }

    public private(set) var soundPlaybackRequest: ScriptLocation?
    public private(set) var soundPlaybackChannel: UInt64?
    public private(set) var soundPlaybackPreservesPosition = false
    package struct SoundPositionRequest: Sendable {
        package let channel: UInt64
        package let source: ScriptLocation
        package let playbackStep: Int
    }
    package struct SoundSeekRequest: Sendable {
        package let channel: UInt64
        package let source: ScriptLocation
        package let playbackStep: Int
        package let milliseconds: Int32
    }
    package struct SoundSwapRequest: Sendable, Equatable {
        package let first: UInt64
        package let second: UInt64
    }
    package struct SoundFilterRequest: Sendable {
        package let channel: UInt64
        package let source: ScriptLocation
        package let playbackStep: Int
        package let previous: StreamVolumeFilterCandidate?
        package let updated: StreamVolumeFilterCandidate?
        package let previousChain: String?
    }
    package var allowLiveSoundPositionQuery = false
    package var allowLiveSoundSwapHandoff = false
    package var allowLiveSoundFilterHandoff = false
    package var allowLiveSoundFilterChainHandoff = false
    package private(set) var soundPositionRequest: SoundPositionRequest?
    package private(set) var soundSeekRequest: SoundSeekRequest?
    package private(set) var soundSwapRequest: SoundSwapRequest?
    package private(set) var soundFilterRequest: SoundFilterRequest?
    package mutating func acknowledgeSoundFilter(_ request: SoundFilterRequest) throws {
        guard phase == .waitingForSoundFilter, let pending = soundFilterRequest,
              pending.channel == request.channel, pending.source == request.source,
              pending.playbackStep == request.playbackStep, pending.previous == request.previous,
              pending.updated == request.updated, pending.previousChain == request.previousChain,
              let sound = storage.soundChannels[request.channel],
              sound.playing, sound.resource == request.source, sound.playbackStartStep == request.playbackStep,
              sound.filterRequestKnown, sound.volumeFilterCandidate == request.updated,
              sound.filterChainCandidateText == nil,
              request.updated != nil || (sound.filterRequest ?? "").isEmpty else {
            throw ResourceError.rejected("sound_filter_identity_or_state_mismatch")
        }
        soundFilterRequest = nil
        phase = .ready
    }
    package mutating func acknowledgeSoundSwap(_ request: SoundSwapRequest) throws {
        guard phase == .waitingForSoundSwap, soundSwapRequest == request else {
            throw ResourceError.rejected("sound_swap_request_mismatch")
        }
        soundSwapRequest = nil
        phase = .ready
    }
    package mutating func acknowledgeSoundSeek(_ request: SoundSeekRequest) throws {
        guard phase == .waitingForSoundSeek, let pending = soundSeekRequest,
              pending.channel == request.channel, pending.source == request.source,
              pending.playbackStep == request.playbackStep, pending.milliseconds == request.milliseconds,
              let sound = storage.soundChannels[request.channel], sound.playing,
              sound.resource == request.source, sound.playbackStartStep == request.playbackStep,
              sound.seekRequest == request.milliseconds else {
            throw ResourceError.rejected("sound_seek_identity_or_state_mismatch")
        }
        storage.soundChannels[request.channel]?.seekRequest = nil
        soundSeekRequest = nil
        phase = .ready
    }
    package mutating func acknowledgeSoundPosition(_ position: Int32, for request: SoundPositionRequest) throws {
        guard phase == .waitingForSoundPosition, position >= 0,
              let pending = soundPositionRequest, pending.channel == request.channel,
              pending.source == request.source, pending.playbackStep == request.playbackStep,
              let sound = storage.soundChannels[request.channel], sound.playing,
              sound.resource == request.source, sound.playbackStartStep == request.playbackStep else {
            throw ResourceError.rejected("sound_position_identity_or_state_mismatch")
        }
        storage.clearResultBindings()
        try storage.resultInteger(position)
        soundPositionRequest = nil
        phase = .ready
    }
    public var activeSoundChannels: Set<UInt64> {
        Set(storage.soundChannels.compactMap { $0.value.playing ? $0.key : nil })
    }
    package var researchLiveStreamFilterIssue: String? {
        researchLiveStreamFilterIssue(accepting: [:])
    }
    package var researchActiveStreamVolumeFilters: [UInt64: StreamVolumeFilterCandidate] {
        storage.soundChannels.reduce(into: [:]) { result, item in
            guard ScriptStorage.isStreamHandle(item.key), item.value.playing,
                  item.value.filterRequestKnown, !(item.value.filterRequest ?? "").isEmpty,
                  let volume = item.value.volumeFilterCandidate else { return }
            result[item.key] = volume
        }
    }
    package var researchActiveStreamFilterChains: [UInt64: String] {
        storage.soundChannels.reduce(into: [:]) { result, item in
            guard ScriptStorage.isStreamHandle(item.key), item.value.playing,
                  item.value.filterRequestKnown, let text = item.value.filterChainCandidateText,
                  item.value.filterRequest == text else { return }
            result[item.key] = text
        }
    }
    package func researchLiveStreamFilterIssue(accepting accepted: [UInt64: StreamVolumeFilterCandidate],
                                               chains: [UInt64: String] = [:]) -> String? {
        if storage.activeStreamFilterApplicationUnverified {
            return "live_audio_stream_filter_application_unverified"
        }
        for (handle, channel) in storage.soundChannels where ScriptStorage.isStreamHandle(handle) && channel.playing {
            if !channel.filterRequestKnown {
                return "live_audio_stream_filter_application_unverified"
            }
            if !(channel.filterRequest ?? "").isEmpty &&
                (channel.volumeFilterCandidate == nil || accepted[handle] != channel.volumeFilterCandidate) &&
                (channel.filterChainCandidateText == nil || chains[handle] != channel.filterChainCandidateText) {
                return "live_audio_stream_filter_application_unverified"
            }
        }
        return nil
    }
    package struct ResearchActiveAudioSnapshot: Encodable, Sendable, Equatable {
        let kind: String
        let index: Int32?
        let source: ScriptLocation?
        let playbackStartStep: Int?
        let probedDurationMilliseconds: Int32?
        let loopRequest: Int32?
        let filterRequest: String?
        let volumeFilterCandidate: StreamVolumeFilterCandidate?
        let filterChainCandidateText: String?
        let volumeType: Int32?
        let appliedVolumeType: Int32?
        let volumeTarget: Int32?
        let volumeDuration: Int32?
        let volumeDelay: Int32?
        let volumeChangePending: Bool
        let volumeAcknowledgementPending: Bool
        let panDuration: Int32?
        let panDelay: Int32?
        let panTarget: Int32?
        let panInvariantDiagnostic: String?
        let panChangePending: Bool
        let panAcknowledgementPending: Bool
        let seekPending: Bool
        let seekTarget: Int32?

        package static func == (lhs: Self, rhs: Self) -> Bool {
            func sameBytes(_ a: String?, _ b: String?) -> Bool {
                switch (a, b) {
                case (nil, nil): return true
                case let (a?, b?): return a.utf8.elementsEqual(b.utf8)
                default: return false
                }
            }
            func sameSource(_ a: ScriptLocation?, _ b: ScriptLocation?) -> Bool {
                switch (a, b) {
                case (nil, nil): return true
                case let (a?, b?):
                    return sameBytes(a.sourceFile, b.sourceFile) && sameBytes(a.sourceSHA256, b.sourceSHA256) &&
                        sameBytes(a.rangeSHA256, b.rangeSHA256) && a.byteOffset == b.byteOffset &&
                        a.byteLength == b.byteLength && a.lineNumber == b.lineNumber
                default: return false
                }
            }
            return sameBytes(lhs.kind, rhs.kind) && lhs.index == rhs.index && sameSource(lhs.source, rhs.source) &&
                lhs.playbackStartStep == rhs.playbackStartStep && lhs.probedDurationMilliseconds == rhs.probedDurationMilliseconds &&
                lhs.loopRequest == rhs.loopRequest && sameBytes(lhs.filterRequest, rhs.filterRequest) &&
                lhs.volumeFilterCandidate == rhs.volumeFilterCandidate &&
                sameBytes(lhs.filterChainCandidateText, rhs.filterChainCandidateText) &&
                lhs.volumeType == rhs.volumeType && lhs.appliedVolumeType == rhs.appliedVolumeType &&
                lhs.volumeTarget == rhs.volumeTarget && lhs.volumeDuration == rhs.volumeDuration && lhs.volumeDelay == rhs.volumeDelay &&
                lhs.volumeChangePending == rhs.volumeChangePending && lhs.volumeAcknowledgementPending == rhs.volumeAcknowledgementPending &&
                lhs.panDuration == rhs.panDuration && lhs.panDelay == rhs.panDelay && lhs.panTarget == rhs.panTarget &&
                lhs.panChangePending == rhs.panChangePending && lhs.panAcknowledgementPending == rhs.panAcknowledgementPending &&
                lhs.seekPending == rhs.seekPending && lhs.seekTarget == rhs.seekTarget
        }
    }
    package var researchActiveAudioSnapshots: [ResearchActiveAudioSnapshot] {
        researchActiveAudioSnapshots(excluding: [])
    }
    package struct ResearchPendingSoundControl {
        package let target: Int32
        package let duration: Int32
        package let delay: Int32
    }
    package func researchHasPendingSoundChanges(channel: UInt64) -> Bool {
        guard let sound = storage.soundChannels[channel], sound.playing else { return true }
        return sound.volumeChangePending || sound.panChangePending
    }
    package func researchPendingSoundControl(channel: UInt64, pan: Bool) -> ResearchPendingSoundControl? {
        guard ScriptStorage.isStreamHandle(channel), let sound = storage.soundChannels[channel], sound.playing else { return nil }
        if pan {
            guard sound.panChangePending, let change = sound.panRequest, (-256...256).contains(change.position),
                  change.duration >= 0, change.delay >= 0 else { return nil }
            return .init(target: change.position, duration: change.duration, delay: change.delay)
        }
        guard sound.volumeChangePending, let target = sound.volume, (0...256).contains(target),
              let duration = sound.volumeDuration, let delay = sound.volumeDelay, duration >= 0, delay >= 0 else { return nil }
        return .init(target: target, duration: duration, delay: delay)
    }
    package func researchActiveAudioSnapshots(excluding excluded: Set<UInt64>) -> [ResearchActiveAudioSnapshot] {
        storage.soundChannels.keys.sorted().compactMap { handle in
            guard !excluded.contains(handle), let audio = storage.soundChannels[handle], audio.playing else { return nil }
            let stream = ScriptStorage.isStreamHandle(handle)
            let direct = ScriptStorage.isDirectSoundHandle(handle)
            return ResearchActiveAudioSnapshot(kind: stream ? "stream" : (direct ? "direct" : "unknown"),
                index: stream ? Self.streamSaveChannelIndex(handle) : ScriptStorage.directSoundIndex(handle),
                source: audio.resource, playbackStartStep: audio.playbackStartStep,
                probedDurationMilliseconds: audio.probedDurationMilliseconds,
                loopRequest: audio.loopRequest, filterRequest: audio.filterRequest,
                volumeFilterCandidate: audio.volumeFilterCandidate,
                filterChainCandidateText: audio.filterChainCandidateText,
                volumeType: audio.volumeType, appliedVolumeType: audio.appliedVolumeType, volumeTarget: audio.volume,
                volumeDuration: audio.volumeDuration, volumeDelay: audio.volumeDelay,
                volumeChangePending: audio.volumeChangePending, volumeAcknowledgementPending: audio.volumeControlToken != nil,
                panDuration: audio.panRequest?.duration, panDelay: audio.panRequest?.delay, panTarget: audio.panRequest?.position,
                panInvariantDiagnostic: audio.panInvariantDiagnostic,
                panChangePending: audio.panChangePending, panAcknowledgementPending: audio.panControlToken != nil,
                seekPending: audio.seekRequest != nil, seekTarget: audio.seekRequest)
        }
    }
    package var activeStreamPlaybackSnapshots: [UInt64: (source: ScriptLocation?, step: Int?)] {
        storage.soundChannels.compactMapValues { channel in
            channel.playing ? (channel.resource, channel.playbackStartStep) : nil
        }.filter { ScriptStorage.isStreamHandle($0.key) }
    }
    package var activeDirectPlaybackSnapshots: [UInt64: (source: ScriptLocation?, step: Int?)] {
        storage.soundChannels.compactMapValues { channel in
            channel.playing ? (channel.resource, channel.playbackStartStep) : nil
        }.filter { ScriptStorage.isDirectSoundHandle($0.key) }
    }

    package static func directSoundChannelIndex(_ handle: UInt64) -> Int32? {
        ScriptStorage.directSoundIndex(handle)
    }

    /// Independent configured gain; the host must combine it with the channel
    /// volume envelope, without replacing an in-progress volume change.
    public func soundCategoryGains(only channels: Set<UInt64>? = nil) throws -> [UInt64: Int32] {
        var result: [UInt64: Int32] = [:]
        for (handle, sound) in storage.soundChannels where sound.playing && (channels?.contains(handle) ?? true) {
            let gain = try storage.soundCategoryGain(sound)
            guard (0...256).contains(gain) else {
                throw ResourceError.rejected("sound_category_gain_outside_host_profile")
            }
            result[handle] = gain
        }
        return result
    }

    public var immediateSoundVolumes: [UInt64: Int32] {
        storage.soundChannels.compactMapValues { channel in
            guard channel.playing, (channel.volumeDuration ?? 0) == 0,
                  (channel.volumeDelay ?? 0) == 0 else { return nil }
            return channel.volume ?? 256
        }
    }
    public struct SoundControlChange: Sendable {
        public let target: Int32
        public let duration: Int32
        public let delay: Int32
        public let token: UUID
        package var savedVolumeRampTarget: Int32? = nil

        package func sample(initial: Float, target: Float, elapsedMilliseconds: Double) -> (value: Float, completed: Bool) {
            let remainingDelay = Double(delay)
            let delayedStart: Float
            if let savedVolumeRampTarget {
                let restoredVolume = Float(savedVolumeRampTarget) / 256
                let elapsedRamp = min(elapsedMilliseconds, remainingDelay, 2_000)
                delayedStart = initial + (restoredVolume - initial) * Float(elapsedRamp / 2_000)
            } else {
                delayedStart = initial
            }
            guard elapsedMilliseconds >= remainingDelay else { return (delayedStart, false) }
            let elapsedControl = elapsedMilliseconds - remainingDelay
            guard elapsedControl < Double(duration) else { return (target, true) }
            return (delayedStart + (target - delayedStart) * Float(elapsedControl / Double(duration)), false)
        }
    }

    public struct SavedStreamPanSample: Sendable {
        package let playbackStep: Int
        package let controlToken: UUID
        package let position: Int32
        package let remainingFrames: Int32?

        package init?(playbackStep: Int, controlToken: UUID, normalizedPan: Float,
                      delay: Int32 = 0, elapsedMilliseconds: Double = 0, started: Bool = false) {
            guard (-1...1).contains(normalizedPan), delay >= 0,
                  elapsedMilliseconds.isFinite, elapsedMilliseconds >= 0 else { return nil }
            self.playbackStep = playbackStep
            self.controlToken = controlToken
            position = Int32((normalizedPan * 256).rounded(.toNearestOrEven))
            if delay == 0 {
                remainingFrames = nil
            } else if started {
                remainingFrames = 0
            } else {
                guard elapsedMilliseconds < Double(delay),
                      let frames = Int32(exactly: ((Double(delay) - elapsedMilliseconds) * 44.1).rounded(.toNearestOrEven)) else { return nil }
                remainingFrames = max(1, frames)
            }
        }
    }

    public struct SavedFiniteRepeatSample: Sendable {
        package let playbackStep: Int
        package let requested: Int32
        package let remaining: Int32
        package let positionMilliseconds: Int32

        package init?(playbackStep: Int, requested: Int32, remaining: Int32, positionSeconds: Double) {
            guard requested > 0, (0...requested).contains(remaining), positionSeconds >= 0,
                  let milliseconds = Int32(exactly: (positionSeconds * 1_000).rounded(.down)) else { return nil }
            self.playbackStep = playbackStep
            self.requested = requested
            self.remaining = remaining
            positionMilliseconds = milliseconds
        }
    }

    public struct SavedDelayedVolumeSample: Sendable {
        package let playbackStep: Int
        package let controlToken: UUID
        package let remainingFrames: Int32
        package let baselineVolume: Int32?

        package init?(playbackStep: Int, change: SoundControlChange, elapsedMilliseconds: Double,
                      baselineGain: Float?, started: Bool) {
            guard change.delay > 0, elapsedMilliseconds.isFinite, elapsedMilliseconds >= 0 else { return nil }
            self.playbackStep = playbackStep
            controlToken = change.token
            if started {
                remainingFrames = 0
                baselineVolume = nil
                return
            }
            guard let baselineGain, (0...1).contains(baselineGain),
                  let baseline = Int32(exactly: baselineGain * 256), elapsedMilliseconds < Double(change.delay),
                  let frames = Int32(exactly: ((Double(change.delay) - elapsedMilliseconds) * 44.1).rounded(.toNearestOrEven)) else { return nil }
            remainingFrames = max(1, frames)
            baselineVolume = baseline
        }
    }

    public enum SoundControlKind: Sendable { case volume, pan }

    /// The host may acknowledge only after the specified change has actually
    /// reached its target. Stale, replaced or stopped-playback tokens are ignored.
    @discardableResult
    public mutating func acknowledgeSoundControlChange(_ change: SoundControlChange, channel: UInt64,
                                                       kind: SoundControlKind) -> Bool {
        storage.acknowledgeSoundControl(channel: channel, token: change.token, volume: kind == .volume)
    }

    public mutating func takeSoundVolumeChanges(only channels: Set<UInt64>? = nil) -> [UInt64: SoundControlChange] {
        var changes: [UInt64: SoundControlChange] = [:]
        for channel in activeSoundChannels where channels?.contains(channel) ?? true {
            guard var sound = storage.soundChannels[channel], sound.volumeChangePending,
                  let target = sound.volume else { continue }
            let token = UUID()
            changes[channel] = SoundControlChange(target: target, duration: sound.volumeDuration ?? 0,
                                                delay: sound.volumeDelay ?? 0, token: token,
                                                savedVolumeRampTarget: sound.savedVolumeRampTarget)
            sound.volumeChangePending = false
            sound.savedVolumeRampTarget = nil
            sound.volumeControlToken = token
            sound.volumeControlPlaybackStep = sound.playbackStartStep
            storage.soundChannels[channel] = sound
        }
        return changes
    }

    public mutating func takeSoundPanChanges(only channels: Set<UInt64>? = nil) -> [UInt64: SoundControlChange] {
        var changes: [UInt64: SoundControlChange] = [:]
        for channel in activeSoundChannels where channels?.contains(channel) ?? true {
            guard var sound = storage.soundChannels[channel], sound.panChangePending,
                  let pan = sound.panRequest else { continue }
            let token = UUID()
            changes[channel] = SoundControlChange(target: pan.position, duration: pan.duration, delay: pan.delay, token: token)
            sound.panChangePending = false
            sound.savedPanBaseline = nil
            sound.panControlToken = token
            sound.panControlPlaybackStep = sound.playbackStartStep
            storage.soundChannels[channel] = sound
        }
        return changes
    }

    public var immediateSoundPans: [UInt64: Int32] {
        storage.soundChannels.compactMapValues { channel in
            guard channel.playing else { return nil }
            if let baseline = channel.savedPanBaseline { return baseline }
            guard let (position, duration, delay) = channel.panRequest else { return 0 }
            guard duration == 0, delay == 0 else { return nil }
            return position
        }
    }

    public mutating func takeActiveSoundSeeks() -> [UInt64: Int32] {
        var seeks: [UInt64: Int32] = [:]
        for channel in activeSoundChannels {
            guard let position = storage.soundChannels[channel]?.seekRequest else { continue }
            seeks[channel] = position
            storage.soundChannels[channel]?.seekRequest = nil
        }
        return seeks
    }

    public mutating func takeActiveSoundSeekSeconds() -> [UInt64: Double] {
        var seeks: [UInt64: Double] = [:]
        for channel in activeSoundChannels {
            guard let position = storage.soundChannels[channel]?.seekSecondsRequest else { continue }
            seeks[channel] = position
            storage.soundChannels[channel]?.seekSecondsRequest = nil
        }
        return seeks
    }

    package mutating func takePendingPlaybackSeek() -> Int32? {
        guard let channel = soundPlaybackChannel,
              let seek = storage.soundChannels[channel]?.seekRequest else { return nil }
        storage.soundChannels[channel]?.seekRequest = nil
        return seek
    }

    package mutating func takePendingPlaybackSeekSeconds() -> Double? {
        guard let channel = soundPlaybackChannel,
              let seek = storage.soundChannels[channel]?.seekSecondsRequest else { return nil }
        storage.soundChannels[channel]?.seekSecondsRequest = nil
        return seek
    }

    package var soundPlaybackInitialVolume: Int32? {
        guard phaseAfterSavedAudioStarts != nil, let channel = soundPlaybackChannel,
              let sound = storage.soundChannels[channel],
              sound.volumeDuration == 2000 || sound.savedVolumeRampTarget != nil else { return nil }
        return 0
    }

    public var soundPlaybackRepeatCount: Int32 {
        // At EOF, 0x57594b stops at zero and 0x575966 decrements a positive count before restarting.
        soundPlaybackChannel.flatMap { storage.soundChannels[$0]?.loopRequest } ?? 0
    }
    package var soundPlaybackIsStream: Bool {
        soundPlaybackChannel.map(ScriptStorage.isStreamHandle) ?? false
    }
    package var researchSoundPlaybackHasPendingSeek: Bool {
        soundPlaybackChannel.flatMap { storage.soundChannels[$0]?.seekRequest } != nil
    }

    public mutating func acknowledgeSoundPlayback(durationMilliseconds: Int32? = nil) throws {
        guard phase == .waitingForMedia, soundPlaybackRequest != nil else {
            throw ResourceError.rejected("pending_sound_required")
        }
        if let durationMilliseconds {
            guard durationMilliseconds > 0, let channel = soundPlaybackChannel,
                  storage.soundChannels[channel]?.resource == soundPlaybackRequest else {
                throw ResourceError.rejected("sound_duration_requires_matching_pending_resource")
            }
            storage.soundChannels[channel]?.probedDurationMilliseconds = durationMilliseconds
        }
        if phaseAfterSavedAudioStarts != nil, let channel = soundPlaybackChannel,
           ScriptStorage.isDirectSoundHandle(channel) {
            // The native reload calls the regular play path, which refreshes its cooldown.
            storage.directSoundChannels[channel]?.lastStartTick =
                UInt32(truncatingIfNeeded: DispatchTime.now().uptimeNanoseconds / 1_000_000)
        }
        soundPlaybackRequest = nil
        soundPlaybackChannel = nil
        soundPlaybackPreservesPosition = false
        if phaseAfterSavedAudioStarts != nil {
            startNextSavedAudio()
        } else {
            phase = .ready
        }
    }

    public mutating func acknowledgeSoundCompletion(channel: UInt64, playbackStartStep: Int) {
        guard storage.soundChannels[channel]?.playing == true,
              storage.soundChannels[channel]?.playbackStartStep == playbackStartStep else { return }
        storage.soundChannels[channel]?.playing = false
        storage.soundChannels[channel]?.naturalCompletionStep = playbackStartStep
        if (storage.soundChannels[channel]?.loopRequest ?? 0) > 0 {
            storage.soundChannels[channel]?.loopRequest = 0
        }
    }

    /// Resume after a host has started decoding and supplied the duration in engine ticks.
    public mutating func acknowledgeMoviePlayback(durationTicks: Int32) throws {
        guard phase == .waitingForMedia, let request = moviePlaybackRequest,
              storage.movies[request.handle]?.resource != nil, durationTicks > 0 else {
            throw ResourceError.rejected("pending_movie_and_positive_duration_required")
        }
        storage.movies[request.handle]!.durationTicks = durationTicks
        storage.movies[request.handle]!.remainingTicks = durationTicks
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
    public mutating func completeIndefiniteClickWait() throws {
        guard phase == .waiting, clickWaitRemaining == -1 else {
            throw ResourceError.rejected("indefinite_click_wait_required")
        }
        try completeClickWait()
    }

    private mutating func completeClickWait() throws {
        guard phase == .waiting, let remaining = clickWaitRemaining else {
            throw ResourceError.rejected("click_wait_required")
        }
        // 0x6ad9cf publishes the remaining countdown before clearing the wait.
        var candidate = storage
        try candidate.setClickResult(remaining)
        storage = candidate
        clickWaitRemaining = nil
        phase = .ready
    }

    public mutating func advanceTimedStop(ticks: Int32) throws {
        guard phase == .waitingForEvent, stopCallbackFrameDepth == nil,
              let request = timedStopRequest, ticks >= 0 else {
            throw ResourceError.rejected("timed_stop_wait_required")
        }
        // 0x6ac296 advances both fields only while the first is positive.
        // 0x6cad38 publishes the first field and 0x6cad4e resumes at zero.
        let remaining = request.duration > 0 ? max(0, request.duration - ticks) : request.duration
        let alternate = request.duration > 0 ? max(0, request.alternateDuration - ticks) : request.alternateDuration
        storage.resultStopInt = remaining
        if remaining == 0 {
            timedStopRequest = nil
            stopCallback = nil
            phase = .ready
        } else {
            timedStopRequest = (remaining, alternate)
        }
    }

    /// Observed-stream callers must independently verify playback identities and controls;
    /// this validates only the machine-side clock and subsystem restrictions.
    package func validateResearchTimedStopFrame(allowZeroClock: Bool = false, allowObservedStreams: Bool = false,
                                               allowRealtimeObservedStreams: Bool = false,
                                               allowFreshTimedWait: Bool = false) throws {
        guard phase == .waitingForEvent, stopCallbackFrameDepth == nil, timedStopRequest != nil,
              storage.linkedPrimaryPlayMode == nil else {
            throw ResourceError.rejected("timed_stop_frame_state_unsupported")
        }
        guard !storage.researchZeroClockHistoryUncertain else {
            throw ResourceError.rejected("timed_stop_frame_clock_history_uncertain")
        }
        guard storage.researchSkipTime == 0 else {
            throw ResourceError.rejected("timed_stop_frame_clock_pending_skip")
        }
        guard (storage.engineField98 ?? 0) == 0 || (allowZeroClock &&
            (researchZeroWaitClockPending || (allowFreshTimedWait && isResearchMessageClickTimedWait))) else {
            throw ResourceError.rejected("timed_stop_frame_clock_reset_pending")
        }
        let activeAudio = storage.soundChannels.filter { $0.value.playing }
        guard !storage.timers.values.contains(where: { $0.enabled }),
              (activeAudio.isEmpty || ((allowZeroClock || allowRealtimeObservedStreams) && allowObservedStreams &&
                  activeAudio.keys.allSatisfy(ScriptStorage.isStreamHandle))),
              !storage.movies.values.contains(where: { ($0.remainingTicks ?? 0) > 0 }) else {
            throw ResourceError.rejected("timed_stop_frame_active_subsystem_unsupported")
        }
    }
    private let imageMemberLookup: (@Sendable (ScriptLocation, String) throws -> (offset: Int, length: Int, sha256: String)?)?
    private func motionIndex(_ name: String, in names: [String]) -> Int32 {
        let key = Data(asciiLower(name).utf8)
        return Int32(names.lastIndex { Data(asciiLower($0).utf8) == key } ?? -1)
    }

    private let imageMotionNames: (@Sendable (ScriptLocation) -> [String]?)?
    private let imageExtendedValues: (@Sendable (ScriptLocation) -> [Int: Int32]?)?
    private let imageLayerFlags: (@Sendable (ScriptLocation, Int32) -> [UInt8]?)?
    private let imageLayerClockAdvance: (@Sendable (ScriptLocation, Int32, [Int32], [Int32], Float)
        -> (times: [Int32], auxiliary: [Int32])?)?
    private let imageLoader: (@Sendable (Data) throws -> (Int, Int, Int))?
    private let saveTextureJPEGEncoder: (@Sendable (Data) throws -> Data)?

    public init(program: ScriptProgram, allowExperimental: Bool, entryLabel: String? = nil,
                entryArguments: [ScriptValue] = [], maximumSteps: Int = 10_000, maximumFrames: Int = 64, repository: ScriptRepository? = nil, configuration: ScriptTable? = nil,
                imageLoader: (@Sendable (Data) throws -> (Int, Int, Int))? = nil,
                imageMemberLookup: (@Sendable (ScriptLocation, String) throws -> (offset: Int, length: Int, sha256: String)?)? = nil,
                imageExtendedValues: (@Sendable (ScriptLocation) -> [Int: Int32]?)? = nil,
                imageMotionNames: (@Sendable (ScriptLocation) -> [String]?)? = nil,
                imageLayerFlags: (@Sendable (ScriptLocation, Int32) -> [UInt8]?)? = nil,
                imageLayerClockAdvance: (@Sendable (ScriptLocation, Int32, [Int32], [Int32], Float)
                    -> (times: [Int32], auxiliary: [Int32])?)? = nil,
                saveTextureJPEGEncoder: (@Sendable (Data) throws -> Data)? = nil,
                retainFullTrace: Bool = true) throws {
        guard allowExperimental else { throw ResourceError.rejected("experimental_execution_not_enabled") }
        guard (1...Self.maximumSupportedSteps).contains(maximumSteps), (1...64).contains(maximumFrames) else { throw ResourceError.rejected("machine_limits") }
        self.retainFullTrace = retainFullTrace
        self.maximumSteps = maximumSteps; self.maximumFrames = maximumFrames
        self.imageLoader = imageLoader
        self.imageMemberLookup = imageMemberLookup
        self.imageExtendedValues = imageExtendedValues
        self.imageMotionNames = imageMotionNames
        self.imageLayerFlags = imageLayerFlags
        self.imageLayerClockAdvance = imageLayerClockAdvance
        self.saveTextureJPEGEncoder = saveTextureJPEGEncoder
        storage.configuration = configuration
        var pinnedRepository = repository
        let prepared = try pinnedRepository?.attachRoot(program) ?? program
        self.program = prepared; self.repository = pinnedRepository
        storage.frames[0].entryLabel = entryLabel
        guard entryArguments.count <= 16, entryArguments.isEmpty || entryLabel != nil else {
            throw ResourceError.rejected("entry_arguments_outside_profile")
        }
        if !entryArguments.isEmpty {
            var integers = Array(repeating: Int32(0), count: 16)
            var strings = Array(repeating: "", count: 16)
            for (index, value) in entryArguments.enumerated() {
                switch value {
                case .integer(let integer):
                    integers[index] = integer
                    strings[index] = String(integer)
                case .string(let string):
                    guard string.utf8.count <= 8192 else { throw ResourceError.rejected("call_string_parameter_limit") }
                    strings[index] = string
                    integers[index] = ScriptExpression.integerTextCache(string) ?? 0
                case .object:
                    throw ResourceError.rejected("entry_object_argument_unsupported")
                }
            }
            storage.frames[0].parameterCount = Int32(entryArguments.count)
            storage.frames[0].integerParameters = integers
            storage.frames[0].stringParameters = strings
        }
        pc = try entryLabel.map { try prepared.label($0) } ?? 0
        if pc < prepared.ancestors.count, !prepared.ancestors[pc].isEmpty { throw ResourceError.rejected("entry_inside_control_block") }
    }

    struct SavedCalculationContinuation: Encodable, Sendable {
        var steps: [ScriptTrace]
        let nextLocation: ScriptLocation?
        let stopReason: String
        var waitRemaining: Int32? = nil
        var simulatedSavedWaitTicks: Int32? = nil
        var pendingDrawCount: Int32? = nil
        var previewDraw: SavedDisplayDraw? = nil
        var sceneDraw: SavedDisplayDraw? = nil
        var frozenSceneDraw: SavedDisplayDraw? = nil
        var captureDraw: SavedDisplayDraw? = nil
        var textDraw: SavedDisplayDraw? = nil
        var omittedStepCount: Int? = nil
        struct InputCounts: Encodable, Sendable {
            let dialogueClicks: Int
            let autoWaitClicks: Int
            let movieClick: Bool
        }
        var consumedInput: InputCounts? = nil
        var decodedSoundRequestCount: Int? = nil
        var nextTableScope: [UInt64]? = nil
        var nextStopCallbackFrameDepth: Int? = nil
        var nextPendingClick: Bool? = nil
        var savedStopCallbackLabel: String? = nil
        struct EventWait: Encodable, Sendable {
            let kind: String
            let callbackLocation: ScriptLocation?
            let remainingReplayClicks: Int?
        }
        var eventWait: EventWait? = nil
        var eventFrame: SavedDisplayDraw? = nil
        var advancedEventFrame: SavedDisplayDraw? = nil
        var eventSampleTicks: Int32? = nil

        mutating func retainRecentSteps() {
            let limit = 256
            guard steps.count > limit else { return }
            omittedStepCount = (omittedStepCount ?? 0) + steps.count - limit
            steps = Array(steps.suffix(limit))
        }
    }

    static func stageSavedActiveControls(program: ScriptProgram, index: Int,
                                      blocks: [SaveReaderCursor.ControlBlock],
                                      returnLocations: [Int: ScriptLocation],
                                      storage: inout ScriptStorage, frameIndex: Int = 0) throws {
        guard program.ancestors.indices.contains(index) else {
            throw ResourceError.rejected("saved_active_control_stack_shape")
        }
        let starts = program.ancestors[index]
        guard !starts.isEmpty, starts.count == blocks.count, storage.frames.indices.contains(frameIndex) else {
            throw ResourceError.rejected("saved_active_control_stack_shape")
        }
        var plans: [Int: ScriptForPlan] = [:]
        var conditions: [Int: Int32] = [:]
        let records = program.document.records
        for (start, saved) in zip(starts, blocks) {
            guard let block = program.blocks[start], let position = returnLocations[saved.decodedOffset] else {
                throw ResourceError.rejected("saved_active_control_position_unavailable")
            }
            if block.family == "if", saved.rawState == 2 {
                let opening = records[start].location
                let expected = block.conditionalElse.map { index > $0 } == true ? "0" : "1"
                let expectedBytes = Data(expected.utf16.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8($0 >> 8)] })
                let condition = saved.stringReferences[2]
                // The native if handler stores its evaluated condition text
                // before capturing the reader position at 0x6bb484–0x6bb4e0.
                guard block.conditionalShapeSupported, index != block.conditionalElse,
                      position.sourceSHA256 == opening.sourceSHA256,
                      position.sourceFile.utf8.elementsEqual(opening.sourceFile.utf8),
                      position.lineNumber == opening.lineNumber, position.byteOffset >= opening.byteOffset,
                      condition.length == expectedBytes.count, condition.sha256 == expectedBytes.sha256Hex else {
                    throw ResourceError.rejected("saved_active_if_position_or_condition_not_matched")
                }
                conditions[start] = expected == "1" ? 1 : 0
                continue
            }
            guard saved.rawState == 3, block.family == "for",
                  saved.matchesThreeFieldLoop(records[start].fields),
                  let body = ((start + 1)..<block.end).first(where: {
                      ![.bom, .layout, .label, .comment].contains(records[$0].kind)
                  }),
                  try program.saveCommandIndex(position) == body else {
                throw ResourceError.rejected("saved_active_loop_return_not_matched")
            }
            plans[start] = try ScriptForPlan(records[start].fields)
        }
        storage.frames[frameIndex].controls = starts
        storage.frames[frameIndex].ifConditions = conditions
        storage.frames[frameIndex].forPlans = plans
    }

    static func stageSavedFrameControls(program: ScriptProgram, index: Int, anchor: ScriptLocation,
                                        blocks: [SaveReaderCursor.ControlBlock], state: Data,
                                        repository: inout ScriptRepository?, storage: inout ScriptStorage,
                                        frameIndex: Int) throws {
        guard program.ancestors.indices.contains(index) else {
            throw ResourceError.rejected("saved_active_control_stack_shape")
        }
        if blocks.isEmpty {
            guard program.ancestors[index].isEmpty else {
                throw ResourceError.rejected("saved_active_control_stack_shape")
            }
            return
        }
        guard var pinned = repository else {
            throw ResourceError.rejected("saved_active_control_position_unavailable")
        }
        var positions: [Int: ScriptLocation] = [:]
        for block in blocks {
            let (position, _, _, resolvedAnchor, _, _) = try SaveReaderCursor.routineReturnPosition(
                block, in: state, repository: &pinned)
            guard resolvedAnchor == anchor else {
                throw ResourceError.rejected("saved_active_control_anchor_not_matched")
            }
            positions[block.decodedOffset] = position
        }
        repository = pinned
        try stageSavedActiveControls(program: program, index: index, blocks: blocks,
            returnLocations: positions, storage: &storage, frameIndex: frameIndex)
    }

    // Reuse an expanded local-call context only when both saved locations map
    // unambiguously to exactly the same pinned source records.
    static func mapSavedPosition(_ saved: (program: ScriptProgram, index: Int, anchor: ScriptLocation),
                                 to context: ScriptProgram) throws -> (program: ScriptProgram, index: Int, anchor: ScriptLocation) {
        guard saved.program.document.records.indices.contains(saved.index) else {
            throw ResourceError.rejected("saved_expanded_position_unavailable")
        }
        let record = saved.program.document.records[saved.index]
        let matches = context.document.records.indices.filter {
            context.document.records[$0].kind == record.kind && context.document.records[$0].location == record.location
        }
        let anchors = context.document.records.filter { $0.kind == .label && $0.location == saved.anchor }
        guard matches.count == 1, anchors.count == 1 else {
            throw ResourceError.rejected("saved_expanded_position_ambiguous")
        }
        return (context, matches[0], saved.anchor)
    }

    static func savedCallUsesLocalContext(_ caller: ScriptProgram, returnIndex: Int) -> Bool {
        guard caller.document.records.indices.contains(returnIndex), returnIndex > 0 else { return false }
        let records = caller.document.records
        if records[returnIndex - 1].kind == .empty || records[returnIndex - 1].kind == .lineTag { return true }
        guard let callIndex = (0..<returnIndex).reversed().first(where: {
            ![.layout, .comment].contains(records[$0].kind)
        }), records[callIndex].command.map(asciiLower) == "sub" else { return false }
        let fields = records[callIndex].fields
        return fields.count == 1 || (fields.count > 1 && asciiLower(fields[1].raw) == "self") ||
            (fields.count > 2 && fields[1].raw.isEmpty)
    }

    static func stageSavedCall(callee: ScriptProgram, anchor: ScriptLocation,
                               caller: ScriptProgram, returnIndex: Int, catalog: ScriptModuleCatalog?,
                               locals: [Data: ScriptBinding] = [:], storage: inout ScriptStorage) throws {
        let records = caller.document.records
        if !storage.frames.isEmpty, storage.frames.count < 64, records.indices.contains(returnIndex),
           returnIndex > 0, records[returnIndex - 1].kind == .empty,
           caller.ancestors[returnIndex] == storage.frames.last?.controls,
           caller.ancestors[returnIndex - 1] == storage.frames.last?.controls,
           let prefix = storage.noWordLineText, prefix.hasPrefix("\\subp,@@") {
            let fields = prefix.split(separator: ",", omittingEmptySubsequences: false)
            let blankIndex = returnIndex - 1
            let internalLabel = caller.labelProgressAnchors[blankIndex].flatMap {
                records[$0].identifier
            }?.hasPrefix("!") == true
            guard fields.count == 2, !internalLabel else {
                throw ResourceError.rejected("saved_blank_call_prefix_not_matched")
            }
            let label = String(fields[1])
            let labelKey = Data(asciiLower(label).utf8)
            guard !storage.frames.contains(where: {
                $0.entryLabel.map { Data(asciiLower($0).utf8) == labelKey } ?? false
            }) else { throw ResourceError.rejected("saved_blank_call_prefix_recursive") }
            let target = try callee.label(label)
            guard callee.document.records[target].location == anchor,
                  let callerTarget = try? caller.label(label),
                  caller.document.records[callerTarget].location == anchor else {
                throw ResourceError.rejected("saved_blank_call_target_not_matched")
            }
            storage.frames.append(ScriptFrame(returnIndex: returnIndex, returnProgram: caller,
                                              entryLabel: label, locals: locals,
                                              completedLineReturnCandidate: true))
            return
        }
        guard !storage.frames.isEmpty, storage.frames.count < 64, records.indices.contains(returnIndex),
              caller.ancestors[returnIndex] == storage.frames.last?.controls,
              let callIndex = (0..<returnIndex).reversed().first(where: {
                  ![.layout, .comment].contains(records[$0].kind)
              }), caller.ancestors[callIndex] == storage.frames.last?.controls else {
            throw ResourceError.rejected("saved_call_site_not_matched")
        }
        let callRecord = records[callIndex]
        let label: String
        let arguments: [String]
        let objectArgumentExpressions: [String]
        let localSourceCall: Bool
        let moduleSourcePath: String?
        let completedLineReturnCandidate: Bool
        func savedStringOperand(_ raw: String, issue: String) throws -> String {
            switch try ScriptExpression.parse(raw) {
            case .string(let value):
                return value
            case .indexed(let name, .literal(let rawIndex)) where asciiLower(name) == "paramstr":
                guard let index = Int32(rawIndex), (0..<16).contains(index),
                      case .string(let value) = try storage.readIndexed(name, index),
                      value.utf8.count <= 4096 else {
                    throw ResourceError.rejected(issue)
                }
                return value
            default:
                throw ResourceError.rejected(issue)
            }
        }
        if callRecord.command.map(asciiLower) == "sub" {
            let fields = callRecord.fields
            guard (1...18).contains(fields.count), fields.allSatisfy({ $0.key == nil }) else {
                throw ResourceError.rejected("saved_call_site_not_matched")
            }
            let rawLabel = fields[0].raw
            label = rawLabel.hasPrefix("@@") ? rawLabel
                : try savedStringOperand(rawLabel, issue: "saved_call_target_not_matched")
            arguments = fields.dropFirst(2).map(\.raw)
            objectArgumentExpressions = arguments
            localSourceCall = fields.count == 1 || asciiLower(fields[1].raw) == "self" ||
                (fields.count > 2 && fields[1].raw.isEmpty)
            moduleSourcePath = localSourceCall ? nil : fields[1].raw
            completedLineReturnCandidate = false
        } else if callRecord.kind == .lineTag, let tag = callRecord.command {
            let key = Data(asciiLower("^" + tag).utf8)
            guard let rule = storage.replacementRules[key], rule.key.hasPrefix("^") else {
                throw ResourceError.rejected("saved_line_tag_replacement_unavailable")
            }
            let fields = rule.value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            let packed = fields.count >= 3 && fields[0] == "\\subp" && fields[2].isEmpty
            let ordinary = (2...3).contains(fields.count) && fields[0] == "\\sub" &&
                ((fields.count == 3 && (fields[2].isEmpty || asciiLower(fields[2]) == "self")) ||
                 callRecord.fields.isEmpty)
            guard packed || ordinary else {
                throw ResourceError.rejected("saved_line_tag_replacement_outside_profile")
            }
            label = fields[1]
            if packed {
                var tail = Array(fields.dropFirst(3)) + callRecord.fields.map(\.raw)
                while tail.last == "" { tail.removeLast() }
                arguments = tail.isEmpty ? [] : [tail.joined(separator: ",")]
            } else {
                guard callRecord.fields.allSatisfy({ $0.key == nil }) else {
                    throw ResourceError.rejected("saved_line_tag_argument_outside_profile")
                }
                arguments = callRecord.fields.map(\.value)
            }
            objectArgumentExpressions = []
            localSourceCall = true
            moduleSourcePath = nil
            completedLineReturnCandidate = true
        } else {
            throw ResourceError.rejected("saved_call_site_not_matched")
        }
        guard let target = try? callee.label(label) else {
            throw ResourceError.rejected("saved_call_target_not_matched")
        }
        let entry = callee.document.records[target].location
        // AVG's expanded header supplies TOP before the scenario's MAIN anchor.
        let main = try? callee.label("@@MAIN")
        let headerEntry = callee.includesExpanded && asciiLower(label) == "@@top" &&
            asciiLower(entry.sourceFile).hasSuffix("/avg/header.s") &&
            main.map { target < $0 && callee.document.records[$0].location == anchor &&
                anchor.sourceFile == callee.document.source.relativePath } == true
        guard entry == anchor || headerEntry else {
            throw ResourceError.rejected("saved_call_target_not_matched")
        }
        let source = callee.document.source
        if localSourceCall {
            let sameRoot = caller.document.source.sha256 == source.sha256 &&
                caller.document.source.relativePath.utf8.elementsEqual(source.relativePath.utf8)
            let sharedEntry = (try? caller.label(label)).map {
                caller.document.records[$0].location == entry
            } ?? false
            guard sameRoot || sharedEntry else {
                throw ResourceError.rejected("saved_local_call_source_not_matched")
            }
        } else {
            guard let catalog, let moduleSourcePath,
                  let path = try? savedStringOperand(moduleSourcePath, issue: "saved_module_call_source_not_matched"),
                  let reference = try? catalog.resolve(path),
                  reference.sourceSHA256 == source.sha256,
                  reference.sourceFile.utf8.elementsEqual(source.relativePath.utf8) else {
                throw ResourceError.rejected("saved_module_call_source_not_matched")
            }
        }
        var integers = Array(repeating: Int32(0), count: 16)
        var strings = Array(repeating: "", count: 16)
        var objectNames: [Data: UInt64] = [:]
        var locals = locals
        let count = locals.removeValue(forKey: Data("paramcount".utf8))
        let ints = locals.removeValue(forKey: Data("paramint".utf8))
        let strs = locals.removeValue(forKey: Data("paramstr".utf8))
        if count != nil || ints != nil || strs != nil {
            guard let count, count.elements.count == 1,
                  case .integer(let savedCount) = count.first, savedCount == Int32(arguments.count),
                  let ints, ints.elements.count == 16, let strs, strs.elements.count == 16 else {
                throw ResourceError.rejected("saved_call_parameter_shape")
            }
            for slot in integers.indices {
                guard case .integer(let integer) = ints.elements[slot],
                      case .string(let string) = strs.elements[slot] else {
                    throw ResourceError.rejected("saved_call_parameter_type")
                }
                integers[slot] = integer
                strings[slot] = string
            }
        } else {
            for (slot, raw) in arguments.enumerated() where !raw.isEmpty {
                let expression = try ScriptExpression.parse(raw)
                switch expression {
                case .literal, .string, .unary("-", .literal), .unary("+", .literal):
                    break
                default:
                    throw ResourceError.rejected("saved_call_argument_not_literal")
                }
                let value = try expression.evaluate(read: { _ in
                    throw ResourceError.rejected("saved_call_argument_not_literal")
                }, write: { _, _ in
                    throw ResourceError.rejected("saved_call_argument_not_literal")
                })
                switch value {
                case .integer(let integer):
                    integers[slot] = integer
                    strings[slot] = raw.hasPrefix("$") ? raw : String(integer)
                case .string(let string):
                    guard string.utf8.count <= 8192 else { throw ResourceError.rejected("call_string_parameter_limit") }
                    strings[slot] = string
                    integers[slot] = ScriptExpression.integerTextCache(string) ?? 0
                case .object:
                    throw ResourceError.rejected("saved_call_argument_not_literal")
                }
            }
        }
        let callerStorage = storage
        for (slot, raw) in objectArgumentExpressions.enumerated() where !raw.isEmpty {
            let expression = try ScriptExpression.parse(raw)
            guard let value = try? expression.evaluate(read: { try callerStorage.read($0) },
                write: { _, _ in throw ResourceError.rejected("saved_call_argument_not_literal") },
                readIndexed: { try callerStorage.readIndexed($0, $1) }) else { continue }
            guard case .object(let handle) = value else { continue }
            guard storage.isAliasTarget(handle) else {
                throw ResourceError.rejected("saved_call_object_parameter_outside_profile")
            }
            let name: String
            switch expression {
            case .name(let identifier): name = identifier
            case .indexed where storage.messages[handle] != nil || storage.tables[handle] != nil:
                name = raw
            default: throw ResourceError.rejected("saved_call_object_parameter_expression_outside_profile")
            }
            let key = Data(asciiLower(name).utf8)
            guard strings[slot].utf8.elementsEqual(name.utf8), objectNames[key] == nil else {
                throw ResourceError.rejected("saved_call_object_parameter_identity_mismatch")
            }
            objectNames[key] = handle
        }
        storage.frames.append(ScriptFrame(returnIndex: callIndex + 1, returnProgram: caller,
                                          entryLabel: label, locals: locals, parameterCount: Int32(arguments.count),
                                          integerParameters: integers, objectParameterNames: objectNames,
                                          stringParameters: strings,
                                          completedLineReturnCandidate: completedLineReturnCandidate))
    }

    static func makeSavedExecutionMachine(
        program: ScriptProgram, index: Int, storage: ScriptStorage,
        repository: ScriptRepository?, wait: Int32?, clickInitial: Int32? = nil, stopLabel: String? = nil, maximumSteps: Int, maximumFrames: Int = 64, retainFullTrace: Bool,
        imageLoader: (@Sendable (Data) throws -> (Int, Int, Int))?,
        imageMemberLookup: (@Sendable (ScriptLocation, String) throws -> (offset: Int, length: Int, sha256: String)?)?,
        imageExtendedValues: (@Sendable (ScriptLocation) -> [Int: Int32]?)?,
        imageMotionNames: (@Sendable (ScriptLocation) -> [String]?)?,
        imageLayerFlags: (@Sendable (ScriptLocation, Int32) -> [UInt8]?)? = nil,
        imageLayerClockAdvance: (@Sendable (ScriptLocation, Int32, [Int32], [Int32], Float)
            -> (times: [Int32], auxiliary: [Int32])?)? = nil,
        saveTextureJPEGEncoder: (@Sendable (Data) throws -> Data)? = nil
    ) throws -> ScriptMachine? {
        let records = program.document.records
        guard records.indices.contains(index), let frame = storage.frames.last,
              program.ancestors[index] == frame.controls,
              [.command, .lineTag].contains(records[index].kind) || wait != nil || stopLabel != nil else { return nil }
        if let wait, wait < -1 { throw ResourceError.rejected("invalid_saved_wait") }
        guard wait == nil || stopLabel == nil else { throw ResourceError.rejected("saved_wait_state_conflict") }
        try storage.validate()
        var machine = try ScriptMachine(program: program, allowExperimental: true, maximumSteps: maximumSteps,
                                        maximumFrames: maximumFrames, repository: repository, imageLoader: imageLoader,
                                        imageMemberLookup: imageMemberLookup, imageExtendedValues: imageExtendedValues,
                                        imageMotionNames: imageMotionNames, imageLayerFlags: imageLayerFlags,
                                        imageLayerClockAdvance: imageLayerClockAdvance,
                                        saveTextureJPEGEncoder: saveTextureJPEGEncoder,
                                        retainFullTrace: retainFullTrace)
        let prepared = machine.program
        guard prepared.document.records.indices.contains(index),
              prepared.document.records[index].location == records[index].location,
              prepared.ancestors[index] == frame.controls else {
            throw ResourceError.rejected("saved_resume_position_changed_during_preparation")
        }
        machine.storage = storage
        machine.pc = index
        if let wait {
            machine.phase = .waiting
            machine.clickWaitRemaining = wait
            machine.clickWaitInitial = clickInitial
        } else if let stopLabel {
            let callback = try prepared.label(stopLabel)
            guard prepared.ancestors[callback].isEmpty else {
                throw ResourceError.rejected("saved_stop_callback_inside_control")
            }
            machine.stopCallback = callback
            machine.phase = .waitingForEvent
        }
        return machine
    }

    static func probeSavedCalculations(program: ScriptProgram, index: Int,
                                       storage: ScriptStorage, repository: ScriptRepository? = nil,
                                       savedWait: Int32? = nil, savedStopLabel: String? = nil, drawPreview: (() throws -> SavedDisplayDraw)? = nil,
                                       drawScene: ((ScriptMachine, SavedScenePass) throws -> (SavedDisplayDraw, Data?))? = nil,
                                       frozenLayerPreview: Bool = false,
                                       eventSampleTicks: Int32? = nil,
                                       decodeMovie: ((MoviePlaybackRequest) throws -> Int32)? = nil,
                                       decodeSound: ((ScriptLocation, Int32?) throws -> Void)? = nil,
                                       clickAfterMovie: Bool = false, dialogueClicks: Int = 0, autoWaitClicks: Int = 0, limit: Int = 512, compact: Bool = false,
                                       imageLoader: (@Sendable (Data) throws -> (Int, Int, Int))? = nil,
                                       imageMemberLookup: (@Sendable (ScriptLocation, String) throws -> (offset: Int, length: Int, sha256: String)?)? = nil,
                                       imageExtendedValues: (@Sendable (ScriptLocation) -> [Int: Int32]?)? = nil,
                                       imageMotionNames: (@Sendable (ScriptLocation) -> [String]?)? = nil,
                                       imageLayerFlags: (@Sendable (ScriptLocation, Int32) -> [UInt8]?)? = nil,
                                       imageLayerClockAdvance: (@Sendable (ScriptLocation, Int32, [Int32], [Int32], Float)
                                           -> (times: [Int32], auxiliary: [Int32])?)? = nil) throws -> SavedCalculationContinuation? {
        var autoWaitClicksRemaining = autoWaitClicks
        var dialogueClicksRemaining = dialogueClicks
        var clickPending = clickAfterMovie
        let maximumReplaySteps = compact ? maximumCompactSavedReplaySteps : maximumFullSavedReplaySteps
        guard (1...maximumReplaySteps).contains(limit) else { throw ResourceError.rejected("saved_replay_step_limit") }
        guard var probe = try makeSavedExecutionMachine(
            program: program, index: index, storage: storage, repository: repository,
            wait: savedWait, stopLabel: savedStopLabel, maximumSteps: limit, retainFullTrace: !compact,
            imageLoader: imageLoader, imageMemberLookup: imageMemberLookup,
            imageExtendedValues: imageExtendedValues, imageMotionNames: imageMotionNames,
            imageLayerFlags: imageLayerFlags, imageLayerClockAdvance: imageLayerClockAdvance
        ) else { return nil }
        var restoringWait = savedWait != nil
        var advancingMovieWait = false
        var advancedSavedWait: Int32 = 0
        var simulatedSavedWaitTicks: Int32? { savedWait.map { _ in advancedSavedWait } }
        var consumedInput: SavedCalculationContinuation.InputCounts? {
            guard dialogueClicks > 0 || autoWaitClicks > 0 || clickAfterMovie else { return nil }
            return .init(dialogueClicks: dialogueClicks - dialogueClicksRemaining,
                         autoWaitClicks: autoWaitClicks - autoWaitClicksRemaining,
                         movieClick: clickAfterMovie && !clickPending)
        }
        var steps: [ScriptTrace] = []
        var droppedSteps = 0
        var previewDraw: SavedDisplayDraw?
        var sceneDraw: SavedDisplayDraw?
        var frozenSceneDraw: SavedDisplayDraw?
        if frozenLayerPreview, let drawScene {
            do { frozenSceneDraw = try drawScene(probe, .frozenLayerScene).0 }
            catch { frozenSceneDraw = .init(status: .unsupported, issue: String(describing: error)) }
        }
        var acknowledgedSceneDraws = 0
        var captureDraw: SavedDisplayDraw?
        var textDraw: SavedDisplayDraw?
        var decodedSounds = 0
        var decodedSoundRequestCount: Int? { decodeSound.map { _ in decodedSounds } }
        var movieDecoded = false
        while steps.count + droppedSteps < limit {
            if savedStopLabel == "@@!Imo_MesWaitAutoOnStop", autoWaitClicksRemaining > 0,
               probe.phase == .waitingForEvent, probe.stopCallbackFrameDepth == nil,
               probe.stopCallback == (try? probe.program.label("@@!Imo_MesWaitAutoOnStop")) {
                try probe.dispatchStopCallback(click: true)
                autoWaitClicksRemaining -= 1
                continue
            }
            if (restoringWait || advancingMovieWait), probe.timerReturn == nil,
               try !probe.dispatchDueTimer() {
                if probe.phase == .waiting, let remaining = probe.clickWaitRemaining, remaining >= 0 {
                    let ticks = min(remaining, max(0, probe.ticksUntilTimer ?? remaining))
                    try probe.advanceClickWait(ticks: ticks)
                    try probe.advancePlacementClock(ticks: ticks)
                    if restoringWait { advancedSavedWait += ticks }
                    continue
                }
                restoringWait = false
                advancingMovieWait = false
            }
            if movieDecoded, let remaining = probe.movieStopRemaining, probe.timerReturn == nil {
                if try probe.dispatchDueTimer() {
                    continue
                }
                if remaining > 0 {
                    let ticks = min(remaining, probe.ticksUntilTimer ?? remaining)
                    try probe.advancePlacementClock(ticks: ticks)
                } else {
                    try probe.dispatchStopCallback()
                }
                continue
            }
            guard probe.phase == .ready, probe.program.document.records.indices.contains(probe.pc) else { break }
            let program = probe.program
            let record = program.document.records[probe.pc]
            let supported: Bool
            switch record.kind {
            case .bom, .layout, .label, .comment:
                supported = true
            case .include:
                supported = program.includesExpanded
            case .lineTag:
                supported = record.command.map {
                    probe.storage.replacementRules[Data(asciiLower("^" + $0).utf8)] != nil
                } ?? false
            case .empty:
                // The interpreter validates the configured sentence handler before dispatch.
                supported = true
            case .text, .sound:
                supported = probe.storage.exceptTextPrefix?.isEmpty == false
            case .command:
                let scope = probe.storage.frames.last?.tableScope ?? []
                let movieScope = scope.count == 1 && probe.storage.movies[scope[0]] != nil
                let streamScope = scope.count == 1 && scope.allSatisfy(ScriptStorage.isStreamHandle)
                let buttonScope = scope.count == 1 && scope.allSatisfy { probe.storage.buttons.contains($0) }
                let messageScope = scope.count == 1 && scope.allSatisfy { probe.storage.messages[$0] != nil }
                let imageScope = scope.count == 1 && scope.allSatisfy { probe.storage.images[$0] != nil }
                let cameraScope = scope == [ScriptStorage.cameraHandle]
                let listScope = scope.count == 1 && scope.allSatisfy { probe.storage.lists[$0] != nil }
                let tableScope = scope.count == 1 && scope.allSatisfy { probe.storage.tables[$0] != nil }
                switch record.command.map(asciiLower) {
                case "cal", "if", "for", "case", "scp", "fmt", "vexs", "jmp", "sub", "subp", "wait", "clk", "draw", "zero":
                    supported = true
                case "var", "gvar", "svar":
                    let type = record.fields.first.map { asciiLower($0.raw) }
                    supported = type == "int" || type == "str" || type == "table" || type == "list" || type == "obj" || type == "img" || type == "msg" || type == "sbtn" || type == "simg" || type == "btn" ||
                        (record.command.map(asciiLower) == "gvar" && type == "theora")
                case "rep", "div", "garr", "pos": supported = true
                case "d":
                    // A saved drawable identity supports the disable endpoint,
                    // even though its previous drawable state is not staged.
                    supported = (scope == [ScriptStorage.fileLogHandle] && record.fields.count == 1) ||
                        (record.fields.isEmpty && scope.count == 1 &&
                         scope.allSatisfy { probe.storage.buttons.contains($0) || probe.storage.images[$0] != nil || probe.storage.messages[$0] != nil })
                case "c" where probe.storage.frames.last?.tableScope == [ScriptStorage.effectHandle]:
                    // Mode 1 bypasses replacement even when the host flag is unknown.
                    guard (probe.storage.effectCapturePriority != nil && probe.storage.fadeInDuration == nil) ||
                          (drawScene != nil && record.fields.count == 1) else {
                        return .init(steps: steps, nextLocation: record.location,
                                     stopReason: "saved_effect_capture_requires_restored_state",
                                     simulatedSavedWaitTicks: simulatedSavedWaitTicks, previewDraw: previewDraw, sceneDraw: sceneDraw, frozenSceneDraw: frozenSceneDraw, captureDraw: captureDraw, textDraw: textDraw, omittedStepCount: droppedSteps == 0 ? nil : droppedSteps, consumedInput: consumedInput, decodedSoundRequestCount: decodedSoundRequestCount)
                    }
                    supported = true
                case "stid": supported = record.fields.count == 2
                case "fdm", "fdp": supported = scope == [ScriptStorage.effectHandle]
                case "fdi": supported = scope == [ScriptStorage.effectHandle] && probe.replayEffectSurface != nil
                case "dc", "bg":
                    supported = record.fields.count == 1 &&
                        (scope == [ScriptStorage.effectHandle] || (record.command.map(asciiLower) == "dc" && (imageScope || messageScope)))
                case "in", "out": supported = (imageScope || messageScope || buttonScope) && record.fields.count == 1
                case "o": supported = messageScope || (buttonScope && scope.allSatisfy { probe.storage.buttonTextBounds[$0] != nil })
                case "ap" where scope == [ScriptStorage.systemHandle]: supported = record.fields.count == 1
                case "cc": supported = messageScope || scope == [ScriptStorage.fileLogHandle] || scope == [ScriptStorage.lineLogHandle]
                case "ap", "as", "nsw", "kwl", "kwb", "kwe", "ns": supported = messageScope
                case "?c" where scope == [ScriptStorage.effectHandle] || scope == [ScriptStorage.dialogueLogHandle]:
                    supported = probe.storage.effectCapturePriority != nil || probe.replayEffectSurface != nil
                case "fexs": supported = probe.repository != nil
                case "?v": supported = streamScope || (try? probe.storage.scopedTables()) != nil
                case "g" where scope == [ScriptStorage.saveDataHandle],
                     "?g" where scope == [ScriptStorage.saveDataHandle],
                     "?gd" where scope == [ScriptStorage.saveDataHandle]:
                    supported = record.fields.count == 1
                case "?g":
                    supported = scope == [ScriptStorage.fileLogHandle] || scope == [ScriptStorage.lineLogHandle] ||
                        scope == [ScriptStorage.dialogueLogHandle]
                case "?k2": supported = scope == [ScriptStorage.lineLogHandle] && record.fields.isEmpty
                case "lim": supported = scope == [ScriptStorage.temporaryDataHandle] && record.fields.count == 1
                case "s" where scope == [ScriptStorage.temporaryDataHandle]:
                    supported = record.fields.count == 3
                case "s": supported = streamScope || scope == [ScriptStorage.fileLogHandle]
                case "swap": supported = record.fields.count == 2
                case "mge", "swe":
                    supported = probe.storage.frames.last?.tableScope == [ScriptStorage.inputHandle]
                case "eve", "tz", "?mrd", "?mt": supported = scope == [ScriptStorage.systemHandle]
                case "prm": supported = scope == [ScriptStorage.miscHandle] && record.fields.isEmpty
                case "?cv", "?cvv", "?cvm", "?vtv", "?vtm":
                    supported = scope == [ScriptStorage.configHandle] && record.fields.count == 1
                case "?mcw": supported = scope == [ScriptStorage.configHandle] && record.fields.isEmpty
                case "?ap": supported = scope == [ScriptStorage.systemHandle] && record.fields.isEmpty
                case "lk" where scope == [ScriptStorage.systemKeyHandle] ||
                    scope == [ScriptStorage.fileLogHandle] || scope == [ScriptStorage.lineLogHandle]:
                    supported = record.fields.count == 1
                case "?lk", "?lkc", "lk", "lkc":
                    supported = scope == [ScriptStorage.systemHandle] ||
                        (record.command.map(asciiLower) == "?lk" &&
                         (scope == [ScriptStorage.fileLogHandle] || scope == [ScriptStorage.lineLogHandle]) &&
                         probe.storage.fileLogLocked != nil) ||
                        ((record.command.map(asciiLower) == "lk" || record.command.map(asciiLower) == "?lk") && scope.count == 1 &&
                         scope.first.map { probe.storage.bars[$0] != nil } == true)
                case "i" where movieDecoded && scope == [ScriptStorage.effectHandle]:
                    supported = true
                case "stop":
                    supported = (movieDecoded && record.fields.count == 1 &&
                        record.fields.first?.raw == "@@!Avg_MovieOnStopEvent") ||
                        (savedStopLabel != nil && record.fields.count == 1 &&
                         record.fields.first?.raw == savedStopLabel) ||
                        (sceneDraw?.status == .inferred && record.fields.count == 3 &&
                         record.fields.first?.raw == "@@!Imo_ClickWait") ||
                        (sceneDraw?.status == .inferred && record.fields.count == 1 &&
                         record.fields.first.map { ["@@!Imo_MesWaitTextOnStop", "@@!Imo_MesWaitAutoOnStop"].contains($0.raw) } == true) ||
                        (savedStopLabel == "@@!Imo_MesWaitAutoOnStop" && record.fields.count == 1 &&
                         record.fields.first?.raw == "@@!Imo_MesWaitTextOnStop")
                case "sc":
                    supported = (movieDecoded || savedStopLabel != nil) && probe.stopCallbackFrameDepth != nil &&
                        scope == [ScriptStorage.inputHandle]
                case "play":
                    supported = (movieDecoded || savedStopLabel != nil) && probe.stopCallbackFrameDepth != nil
                case "?p" where imageScope || buttonScope || messageScope:
                    supported = record.fields.isEmpty
                case "?p" where streamScope: supported = record.fields.isEmpty
                case "?l" where streamScope, "?fo" where streamScope: supported = record.fields.isEmpty
                case "?p" where movieScope:
                    supported = movieDecoded
                case "del":
                    let names = record.fields.map { asciiLower($0.raw) }
                    // The movie and play-state cleanup routines delete these temporary scalars.
                    let cleanup = ["avg_moviesystemlockvalue", "misc_keepplaystate",
                                   "avg_movieclicklock", "avg_movieforcewait", "avg_moviefadetime",
                                   "avg_moviefadefile"]
                    supported = movieDecoded && (names == ["avg_theoramovie"] ||
                        (!names.isEmpty && names.allSatisfy { name in
                            guard cleanup.contains(name) else { return false }
                            let key = Data(name.utf8)
                            guard probe.storage.frames.last?.locals[key] == nil else { return false }
                            switch probe.storage.global[key]?.first {
                            case .integer, .string: return true
                            case .object: return false
                            case nil: return probe.storage.lookupCategory(name) == 0
                            }
                        }))
                case "e":
                    supported = movieScope || messageScope || (scope.count == 1 && scope.allSatisfy { handle in
                        probe.storage.buttonResources[handle] != nil ||
                            probe.storage.images[handle]?.resource != nil ||
                            (probe.storage.images[handle] != nil && storage.images[handle] == nil)
                    })
                case "fo":
                    supported = (imageScope && record.fields.count == 2) || (streamScope && record.fields.count == 1)
                case "sk": supported = streamScope && record.fields.count == 1
                case "m", "exr": supported = imageScope || messageScope
                case "l":
                    supported = movieScope || (probe.repository != nil &&
                        (streamScope || ((imageScope || messageScope || buttonScope) && imageLoader != nil) ||
                         (try? probe.storage.scopedTables()) != nil))
                case "i" where scope == [ScriptStorage.systemKeyHandle],
                     "a" where scope == [ScriptStorage.systemKeyHandle]:
                    supported = true
                case "i":
                    supported = movieScope || listScope || tableScope ||
                        ((streamScope || scope == [ScriptStorage.cameraHandle]) && record.fields.isEmpty)
                case "?r": supported = scope == [ScriptStorage.replacementHandle] && record.fields.count == 1
                case "copy", "cpy", "exop", "trim": supported = true
                case "et", "nt":
                    supported = scope == [ScriptStorage.replacementHandle] && record.fields.count == 1
                case "a" where scope == [ScriptStorage.replacementHandle]:
                    supported = record.fields.count == 2
                case "comb": supported = tableScope && record.fields.count == 1
                case "asn": supported = (listScope || tableScope) && record.fields.count == 1
                case "sort": supported = tableScope && record.fields.isEmpty
                case "a" where scope == [ScriptStorage.dialogueLogHandle]:
                    supported = (3...4).contains(record.fields.count)
                case "a": supported = (listScope || scope == [ScriptStorage.fileLogHandle]) && record.fields.count == 1
                case "ad": supported = listScope && record.fields.count == 2
                case "?n": supported = tableScope
                case "bpos": supported = tableScope && record.fields.count == 1
                case "brep": supported = tableScope && record.fields.count == 1
                case "?c", "?s": supported = listScope || tableScope
                case "v": supported = movieScope || listScope || tableScope || imageScope || streamScope
                case "pan", "p2": supported = streamScope
                case "pri": supported = cameraScope || imageScope
                case "?pri": supported = imageScope
                case "anc", "?anc": supported = imageScope || buttonScope || messageScope
                case "mi", "?mi": supported = imageScope || buttonScope
                case "p4", "alg2": supported = imageScope || messageScope
                case "ts": supported = messageScope || (buttonScope && scope.allSatisfy { probe.storage.buttonResources[$0] != nil })
                case "tmg": supported = messageScope
                case "?tmg", "?tp", "?tda": supported = messageScope && record.fields.isEmpty
                case "?mc": supported = messageScope
                case "mc": supported = messageScope && record.fields.isEmpty
                case "mm", "bm": supported = cameraScope || imageScope
                case "ps", "?dc", "?e": supported = imageScope
                case "midx": supported = imageScope && record.fields.count == 1
                case "?m": supported = imageScope && record.fields.isEmpty
                case "exv": supported = imageScope && (1...2).contains(record.fields.count)
                case "col":
                    supported = (cameraScope && (3...4).contains(record.fields.count)) ||
                        (imageScope && (4...5).contains(record.fields.count))
                case "g": supported = (cameraScope || imageScope) && record.fields.count == 10
                case "g2": supported = (cameraScope || imageScope || messageScope) && record.fields.count == 2
                case "tf": supported = movieScope || cameraScope || imageScope
                case "vtn": supported = movieScope || imageScope || streamScope || messageScope || buttonScope
                case "tab", "sp": supported = imageScope || buttonScope
                case "us", "ui": supported = buttonScope
                case "ds": supported = buttonScope || imageScope
                case "li": supported = (buttonScope || imageScope) && probe.repository != nil
                case "ls": supported = buttonScope && probe.repository != nil
                case "pp", "ss":
                    supported = movieScope
                case "p" where movieScope || cameraScope || imageScope || buttonScope || messageScope || streamScope:
                    supported = true
                case "?skp", "dskp", "?p", "p":
                    // Successful native load resets both values through 0x6b9c54.
                    supported = probe.storage.restoredSystemSkip != nil &&
                        probe.storage.frames.last?.tableScope == [ScriptStorage.systemHandle]
                case "ret":
                    guard probe.storage.frames.count > 1 else {
                        return .init(steps: steps, nextLocation: record.location,
                                     stopReason: "saved_return_requires_caller_frame",
                                     simulatedSavedWaitTicks: simulatedSavedWaitTicks, previewDraw: previewDraw, sceneDraw: sceneDraw, frozenSceneDraw: frozenSceneDraw, captureDraw: captureDraw, textDraw: textDraw, omittedStepCount: droppedSteps == 0 ? nil : droppedSteps, consumedInput: consumedInput, decodedSoundRequestCount: decodedSoundRequestCount)
                    }
                    supported = true
                case "of", "ans":
                    supported = program.startsByMarker[probe.pc].flatMap { program.blocks[$0]?.family } == "case"
                case "then":
                    supported = program.startsByMarker[probe.pc].flatMap { program.blocks[$0]?.family } == "if"
                case "else":
                    let family = program.startsByMarker[probe.pc].flatMap { program.blocks[$0]?.family }
                    supported = family == "if" || family == "case"
                case "brk", "cnt":
                    supported = program.startsByMarker[probe.pc].flatMap { program.blocks[$0]?.family } == "for"
                case "end":
                    let family = program.startsByEnd[probe.pc].flatMap { program.blocks[$0]?.family }
                    supported = family == "if" || family == "for" || family == "case"
                default: supported = false
                }
            default:
                supported = false
            }
            guard supported else {
                guard !steps.isEmpty || savedWait != nil else { return nil }
                return .init(steps: steps, nextLocation: record.location,
                    stopReason: "next_record_outside_calculation_profile", simulatedSavedWaitTicks: simulatedSavedWaitTicks,
                    previewDraw: previewDraw, sceneDraw: sceneDraw, frozenSceneDraw: frozenSceneDraw,
                    captureDraw: captureDraw, textDraw: textDraw, omittedStepCount: droppedSteps == 0 ? nil : droppedSteps,
                    consumedInput: consumedInput, decodedSoundRequestCount: decodedSoundRequestCount,
                    nextTableScope: probe.storage.frames.last?.tableScope,
                    nextStopCallbackFrameDepth: probe.stopCallbackFrameDepth, nextPendingClick: probe.pendingClick,
                    savedStopCallbackLabel: savedStopLabel)
            }
            if let trace = probe.step() {
                steps.append(trace)
                if compact, steps.count == 513 {
                    // Preserve the first record for isolatedCalculation.
                    steps.removeSubrange(1...256)
                    droppedSteps += 256
                }
                if let request = probe.soundPlaybackRequest, let decodeSound {
                    do {
                        try decodeSound(request, probe.takePendingPlaybackSeek())
                        try probe.acknowledgeSoundPlayback()
                        decodedSounds += 1
                    } catch {
                        let records = probe.program.document.records
                        let next = records.indices.contains(probe.pc) ? records[probe.pc].location : nil
                        return .init(steps: steps, nextLocation: next, stopReason: "saved_sound_host: \(error)",
                                     simulatedSavedWaitTicks: simulatedSavedWaitTicks, previewDraw: previewDraw,
                                     sceneDraw: sceneDraw, frozenSceneDraw: frozenSceneDraw, captureDraw: captureDraw, textDraw: textDraw, omittedStepCount: droppedSteps == 0 ? nil : droppedSteps, consumedInput: consumedInput, decodedSoundRequestCount: decodedSoundRequestCount)
                    }
                }
                if let request = probe.moviePlaybackRequest, let decodeMovie {
                    do {
                        try probe.acknowledgeMoviePlayback(durationTicks: decodeMovie(request))
                        movieDecoded = true
                    } catch {
                        let records = probe.program.document.records
                        let next = records.indices.contains(probe.pc) ? records[probe.pc].location : nil
                        return .init(steps: steps, nextLocation: next, stopReason: "saved_movie_host: \(error)",
                                     simulatedSavedWaitTicks: simulatedSavedWaitTicks, previewDraw: previewDraw, sceneDraw: sceneDraw, frozenSceneDraw: frozenSceneDraw, captureDraw: captureDraw, textDraw: textDraw, omittedStepCount: droppedSteps == 0 ? nil : droppedSteps, consumedInput: consumedInput, decodedSoundRequestCount: decodedSoundRequestCount)
                    }
                }
                if movieDecoded, trace.command == "wait", probe.phase == .waiting,
                   let ticks = probe.clickWaitRemaining, (0...600_000).contains(ticks) {
                    advancingMovieWait = true
                }
                if trace.action == "stop_callback_wait_candidate",
                   record.fields.first?.raw == "@@!Imo_MesWaitTextOnStop", let drawScene {
                    var presented = probe
                    if try presented.commitHeadlessMessageOutput() {
                        do {
                            textDraw = try drawScene(presented, .scene).0
                            if textDraw?.status == .inferred {
                                try presented.dispatchStopCallback()
                                probe = presented
                            }
                        } catch {
                            textDraw = .init(status: .unsupported, issue: String(describing: error))
                        }
                    } else if probe.storage.messages.values.allSatisfy({ $0.pendingOutput.isEmpty }) {
                        // Let the script's EOT query observe the already drained queues.
                        try probe.dispatchStopCallback()
                    }
                }
                if autoWaitClicksRemaining > 0, trace.action == "stop_callback_wait_candidate",
                   record.fields.first?.raw == "@@!Imo_MesWaitAutoOnStop" {
                    try probe.dispatchStopCallback(click: true)
                    autoWaitClicksRemaining -= 1
                }
                if dialogueClicksRemaining > 0, trace.action == "timed_stop_callback_wait_candidate",
                   record.fields.first?.raw == "@@!Imo_ClickWait" {
                    try probe.advanceTimedStop(ticks: 0)
                    if probe.phase == .waitingForEvent {
                        try probe.dispatchStopCallback(click: true)
                        dialogueClicksRemaining -= 1
                    }
                }
                if clickPending, movieDecoded, trace.command == "clk", probe.phase == .waiting {
                    try probe.completeClickWait()
                    clickPending = false
                }
                if trace.action == "effect_fade_in_request_candidate",
                   probe.savedOverlapPreviewSurface != nil,
                   let priority = probe.storage.effectCapturePriority,
                   let duration = probe.storage.fadeInDuration, let drawScene {
                    captureDraw?.transitionMidpointSHA256 = nil
                    captureDraw?.transitionEndpointSHA256 = nil
                    captureDraw?.issueForTransitionPreview = nil
                    let matchingPriorities = probe.storage.fadeInPriority == priority
                    // The shipped move-mode table maps "linear" to 1.
                    // Treat 100-power linear timing as a candidate mapping only.
                    let linear = probe.storage.fadeTiming?.mode == 1 && probe.storage.fadeTiming?.power == 100
                    let midpoint = duration / 2
                    let sampleDuration = linear ? UInt32(duration) : 2
                    let sampleMidpoint = linear ? UInt32(midpoint) : 1
                    captureDraw?.transitionTiming = .init(duration: duration,
                        mode: probe.storage.fadeTiming?.mode, power: probe.storage.fadeTiming?.power,
                        capturePriority: priority, fadePriority: probe.storage.fadeInPriority,
                        sampleTicks: linear && matchingPriorities ? [0, midpoint, duration] : nil,
                        sampleTimingStatus: linear && matchingPriorities ? .inferred : .notTested)
                    guard matchingPriorities else {
                        captureDraw?.issueForTransitionPreview = "saved_overlap_priority_mismatch"
                        continue
                    }
                    do {
                        let preview = try drawScene(probe, .overlapSample(priority, elapsed: sampleMidpoint, duration: sampleDuration)).0
                        if preview.status == .inferred {
                            captureDraw?.transitionMidpointSHA256 = preview.transitionMidpointSHA256
                            let endpoints = try [UInt32(0), sampleDuration].map {
                                try drawScene(probe, .overlapSample(priority, elapsed: $0, duration: sampleDuration)).0
                            }
                            if endpoints.allSatisfy({ $0.status == .inferred }),
                               let start = endpoints[0].transitionMidpointSHA256,
                               let end = endpoints[1].transitionMidpointSHA256 {
                                captureDraw?.transitionEndpointSHA256 = [start, end]
                            } else {
                                captureDraw?.issueForTransitionPreview = "saved_overlap_endpoint_incomplete"
                            }
                        } else {
                            captureDraw?.issueForTransitionPreview = preview.issue ?? "saved_overlap_preview_incomplete"
                        }
                    } catch {
                        captureDraw?.issueForTransitionPreview = String(describing: error)
                    }
                }
                if trace.action == "effect_capture_request_candidate", let drawScene,
                   let priority = probe.storage.effectCapturePriority {
                    do {
                        let (receipt, surface) = try drawScene(probe, .capture(priority))
                        captureDraw = receipt
                        if receipt.status == .inferred, let surface, !surface.isEmpty,
                           surface.count <= 16 * 1024 * 1024 {
                            probe.replayEffectSurface = surface
                            continue
                        }
                    } catch {
                        captureDraw = .init(status: .unsupported, issue: String(describing: error))
                    }
                    let records = probe.program.document.records
                    let next = records.indices.contains(probe.pc) ? records[probe.pc].location : nil
                    return .init(steps: steps, nextLocation: next, stopReason: "saved_effect_capture_requires_surface_binding",
                                 simulatedSavedWaitTicks: simulatedSavedWaitTicks, previewDraw: previewDraw,
                                 sceneDraw: sceneDraw, frozenSceneDraw: frozenSceneDraw, captureDraw: captureDraw, textDraw: textDraw, omittedStepCount: droppedSteps == 0 ? nil : droppedSteps, consumedInput: consumedInput, decodedSoundRequestCount: decodedSoundRequestCount)
                }
                if trace.action == "draw_request_candidate" {
                    if probe.storage.drawRequestCount == 1, previewDraw == nil, let drawPreview {
                        do {
                            previewDraw = try drawPreview()
                            if previewDraw?.status == .inferred {
                                probe.storage.drawRequestCount = nil
                                continue
                            }
                        } catch {
                            previewDraw = .init(status: .unsupported, issue: String(describing: error))
                        }
                    }
                    if previewDraw?.status == .inferred, acknowledgedSceneDraws < 32,
                       probe.storage.drawRequestCount == 1, let drawScene {
                        do { sceneDraw = try drawScene(probe, .scene).0 }
                        catch { sceneDraw = .init(status: .unsupported, issue: String(describing: error)) }
                        if sceneDraw?.status == .inferred {
                            acknowledgedSceneDraws += 1
                            probe.storage.drawRequestCount = nil
                            continue
                        }
                    }
                    let nextRecords = probe.program.document.records
                    let next = nextRecords.indices.contains(probe.pc) ? nextRecords[probe.pc].location : nil
                    return .init(steps: steps, nextLocation: next, stopReason: "saved_draw_requires_restored_scene",
                                 simulatedSavedWaitTicks: simulatedSavedWaitTicks, pendingDrawCount: probe.storage.drawRequestCount,
                                 previewDraw: previewDraw, sceneDraw: sceneDraw, frozenSceneDraw: frozenSceneDraw, captureDraw: captureDraw, textDraw: textDraw, omittedStepCount: droppedSteps == 0 ? nil : droppedSteps, consumedInput: consumedInput, decodedSoundRequestCount: decodedSoundRequestCount)
                }
            }
        }
        let finalRecords = probe.program.document.records
        let nextLocation = finalRecords.indices.contains(probe.pc) ? finalRecords[probe.pc].location : nil
        if probe.phase == .waitingForMedia, probe.soundPlaybackRequest != nil {
            return .init(steps: steps, nextLocation: nextLocation, stopReason: "saved_sound_requires_media_host",
                         simulatedSavedWaitTicks: simulatedSavedWaitTicks, previewDraw: previewDraw, sceneDraw: sceneDraw, frozenSceneDraw: frozenSceneDraw, captureDraw: captureDraw, textDraw: textDraw, omittedStepCount: droppedSteps == 0 ? nil : droppedSteps, consumedInput: consumedInput, decodedSoundRequestCount: decodedSoundRequestCount)
        }
        if probe.phase == .waitingForMedia, probe.moviePlaybackRequest != nil {
            return .init(steps: steps, nextLocation: nextLocation, stopReason: "saved_movie_requires_media_host",
                         simulatedSavedWaitTicks: simulatedSavedWaitTicks, previewDraw: previewDraw, sceneDraw: sceneDraw, frozenSceneDraw: frozenSceneDraw, captureDraw: captureDraw, textDraw: textDraw, omittedStepCount: droppedSteps == 0 ? nil : droppedSteps, consumedInput: consumedInput, decodedSoundRequestCount: decodedSoundRequestCount)
        }
        if probe.phase == .waitingForEvent {
            let callback = probe.stopCallback
            let kind: String
            let remainingClicks: Int?
            if let callback, callback == (try? probe.program.label("@@!Imo_ClickWait")) {
                kind = "dialogue_click"
                remainingClicks = dialogueClicksRemaining
            } else if let callback, callback == (try? probe.program.label("@@!Imo_MesWaitAutoOnStop")) {
                kind = "message_auto_wait"
                remainingClicks = autoWaitClicksRemaining
            } else if let callback, callback == (try? probe.program.label("@@!Imo_MesWaitTextOnStop")) {
                kind = "message_output_wait"
                remainingClicks = nil
            } else {
                kind = "unclassified_callback"
                remainingClicks = nil
            }
            let callbackLocation = callback.flatMap { finalRecords.indices.contains($0) ? finalRecords[$0].location : nil }
            var eventFrame: SavedDisplayDraw?
            var advancedEventFrame: SavedDisplayDraw?
            if let drawScene, let eventSampleTicks {
                func sample(_ machine: ScriptMachine) -> SavedDisplayDraw {
                    do { return try drawScene(machine, .scene).0 }
                    catch { return .init(status: .unsupported, issue: String(describing: error)) }
                }
                eventFrame = sample(probe)
                var advanced = probe
                advanced.advanceVisualClock(ticks: eventSampleTicks)
                advancedEventFrame = sample(advanced)
            }
            return .init(steps: steps, nextLocation: nextLocation, stopReason: "waiting_for_script_event",
                         waitRemaining: probe.timedStopRequest?.duration, simulatedSavedWaitTicks: simulatedSavedWaitTicks,
                         previewDraw: previewDraw, sceneDraw: sceneDraw, frozenSceneDraw: frozenSceneDraw, captureDraw: captureDraw, textDraw: textDraw, omittedStepCount: droppedSteps == 0 ? nil : droppedSteps, consumedInput: consumedInput, decodedSoundRequestCount: decodedSoundRequestCount,
                         eventWait: .init(kind: kind, callbackLocation: callbackLocation,
                                          remainingReplayClicks: remainingClicks),
                         eventFrame: eventFrame, advancedEventFrame: advancedEventFrame,
                         eventSampleTicks: eventSampleTicks)
        }
        if probe.phase == .waiting {
            return .init(steps: steps, nextLocation: nextLocation, stopReason: "waiting_for_input_or_timer",
                         waitRemaining: probe.clickWaitRemaining, simulatedSavedWaitTicks: simulatedSavedWaitTicks, previewDraw: previewDraw, sceneDraw: sceneDraw, frozenSceneDraw: frozenSceneDraw, captureDraw: captureDraw, textDraw: textDraw, omittedStepCount: droppedSteps == 0 ? nil : droppedSteps, consumedInput: consumedInput, decodedSoundRequestCount: decodedSoundRequestCount)
        }
        return .init(steps: steps, nextLocation: nextLocation,
                     stopReason: probe.stopReason ?? (steps.count + droppedSteps == limit ? "calculation_probe_step_limit" : "script_end"),
                     simulatedSavedWaitTicks: simulatedSavedWaitTicks, previewDraw: previewDraw, sceneDraw: sceneDraw, frozenSceneDraw: frozenSceneDraw, captureDraw: captureDraw, textDraw: textDraw, omittedStepCount: droppedSteps == 0 ? nil : droppedSteps, consumedInput: consumedInput, decodedSoundRequestCount: decodedSoundRequestCount)
    }

    public func value(named name: String) throws -> ScriptValue { try storage.read(name) }
    /// Explicit research import; automatic label-history tracking remains unsupported.
    package mutating func stageSystemDataScalars(_ source: SaveSystemData) throws -> Int {
        guard executedSteps == 0, phase == .ready, storage.system.isEmpty else {
            throw ResourceError.rejected("system_data_requires_fresh_session")
        }
        let bindings = try source.scalarBindings()
        var candidate = storage
        candidate.system = bindings
        candidate.fileLogValues = source.fileLog.values
        candidate.lineLogValues = source.labelLog.values
        candidate.importedLabelHistory = true
        try candidate.validate()
        storage = candidate
        return bindings.count
    }
    package mutating func configureSystemDataSave(name: String, headerTemplate: Data, expectedSHA256: String?) throws {
        guard executedSteps == 0, phase == .ready,
              try SafeDirectory.components(name).count == 1, headerTemplate.count == 44 else {
            throw ResourceError.rejected("system_data_save_configuration_invalid")
        }
        systemDataSaveTarget = .init(name: name, headerTemplate: headerTemplate, sha256: expectedSHA256)
    }
    package func encodeResearchSystemData(_ source: SaveSystemData) throws -> Data {
        try source.replacingScalars(from: storage)
    }
    package mutating func setReadOnlySaveSlots(_ entries: [SaveSlotInventory.Entry], directory: SafeDirectory? = nil,
                                               inferStateSeed: Bool = false, headerTemplate: Data? = nil,
                                               verifyUntransformedHeaders: Bool = true) throws {
        guard executedSteps == 0, phase == .ready else {
            throw ResourceError.rejected("save_slots_require_fresh_session")
        }
        if let headerTemplate, headerTemplate.count != 40 || inferStateSeed {
            throw ResourceError.rejected("invalid_save_header_template_configuration")
        }
        storage.sessionSaveNames = Set(entries.compactMap {
            guard $0.status == .verified, $0.envelope?.kind == "slot" else { return nil }
            return Data(asciiLower($0.name).utf8)
        })
        storage.sessionSaveMetadata.removeAll()
        storage.sessionSaveThumbnails.removeAll()
        saveDirectory = directory
        inferSaveStateSeed = inferStateSeed
        saveHeaderTemplate = headerTemplate
        saveSources.removeAll()
        for entry in entries where entry.status == .verified {
            guard let slot = entry.envelope?.slot, let strings = entry.metadata else { continue }
            let key = Data(asciiLower(entry.name).utf8)
            storage.sessionSaveMetadata[key] = (strings, slot.savedLocalTime)
            storage.sessionSaveThumbnails[key] = entry.thumbnail
            if let digest = entry.sourceSHA256 {
                saveSources[key] = (entry.name, digest, verifyUntransformedHeaders || slot.transformed)
            }
        }
    }
    package static func resolveSaveSlotName(_ name: String, entries: [DirectoryEntry]) throws -> String {
        let key = Data(asciiLower(name).utf8)
        let matches = entries.filter { Data(asciiLower($0.name).utf8) == key }
        guard matches.count <= 1 else { throw ResourceError.rejected("ambiguous_save_slot_name") }
        return matches.first?.name ?? name
    }
    private var liveSaveWait: (remaining: Int32, initial: Int32, mode: UInt8, command: String, stopLabel: String?, commandIndex: Int)? {
        guard timerReturn == nil, pc > 0 else { return nil }
        if phase == .waitingForPrimarySave, let request = primarySaveRequest {
            if request.macSafetyBackupWithoutThumbnail, let macExceptionBackupLiveWaitOverride {
                return macExceptionBackupLiveWaitOverride
            }
            return (0, 0, 0, "ret", nil, request.resumeIndex)
        }
        let records = program.document.records
        var previousCommand: ScriptRecord?
        var previousCommandIndex: Int?
        for index in records.indices.prefix(pc).reversed() {
            let record = records[index]
            if record.kind == .command {
                previousCommand = record
                previousCommandIndex = index
                break
            }
            guard record.kind == .bom || record.kind == .layout || record.kind == .empty else { return nil }
        }
        guard let previousCommand, let previousCommandIndex,
              let command = previousCommand.command.map(asciiLower) else { return nil }
        if allowTitleQuit, phase == .waitingForSystemTask, systemTaskEntryLabel == "@@!Quit",
           systemTaskResumeState?.phase == .ready, stopCallbackFrameDepth == nil,
           !storage.formCloseSaveFilename.isEmpty, command == "thrd",
           Self.isTitleQuitRequest(previousCommand.location),
           let resumeIndex = records.indices.dropFirst(pc).first(where: { records[$0].kind != .layout }) {
            let resume = records[resumeIndex]
            if resume.command.map(asciiLower) == "jmp", resume.fields.count == 1,
               asciiLower(resume.fields[0].raw) == "@@!selectpage",
               resume.location.sourceFile == previousCommand.location.sourceFile,
               resume.location.sourceSHA256 == previousCommand.location.sourceSHA256,
               resume.location.lineNumber == previousCommand.location.lineNumber + 1 {
                // The title thread is suspended after thrd; loading resumes
                // at its ordinary jump back to the title selection page.
                return (0, 0, 0, "jmp", nil, resumeIndex)
            }
        }
        let waitState: (remaining: Int32, initial: Int32?)?
        if phase == .waiting {
            waitState = clickWaitRemaining.map { ($0, clickWaitInitial) }
        } else if phase == .waitingForSystemTask, ["@@!Save", "@@!QuickSave"].contains(systemTaskEntryLabel ?? ""),
                  let resume = systemTaskResumeState, resume.phase == .waiting,
                  let remaining = resume.clickWaitRemaining {
            waitState = (remaining, resume.clickWaitInitial)
        } else {
            waitState = nil
        }
        if stopCallback == nil, let waitState {
            if command == "wait", waitState.remaining > 0 {
                return (waitState.remaining, waitState.initial ?? 0, 3, command, nil, previousCommandIndex)
            }
            if command == "clk", let initial = waitState.initial,
               (waitState.remaining == -1 && initial == -1) ||
                (waitState.remaining >= 0 && waitState.remaining <= initial) {
                return (waitState.remaining, initial, 4, command, nil, previousCommandIndex)
            }
        }
        let waitingAtSaveMenu = phase == .waitingForSystemTask && ["@@!Save", "@@!QuickSave"].contains(systemTaskEntryLabel ?? "")
        if (phase == .waitingForEvent || waitingAtSaveMenu), command == "stop", timedStopRequest == nil,
           stopCallbackFrameDepth == nil, let callback = stopCallback {
            let fields = previousCommand.fields
            if fields.count == 1, fields[0].key == nil, fields[0].raw.hasPrefix("@@"),
               (try? program.label(fields[0].raw)) == callback {
                return (-1, -1, 2, command, fields[0].raw, previousCommandIndex)
            }
        }
        return nil
    }

    private static func isSaveScopedTimer(_ timer: ScriptStorage.TimerObject) -> Bool {
        if !timer.enabled && timer.elapsed == 0 && timer.callback == nil && timer.argument.isEmpty { return true }
        return timer.hasSupportedActiveSaveState
    }

    static func liveObjectParametersAreRepresentable(_ frame: ScriptFrame, storage: ScriptStorage) -> Bool {
        guard !frame.objectParameterNames.isEmpty else { return true }
        guard let parameterCount = frame.parameterCount, (0...16).contains(parameterCount),
              let strings = frame.stringParameters, strings.count == 16 else { return false }
        let serializedNames = strings.prefix(Int(parameterCount)).map { Data(asciiLower($0).utf8) }
        return frame.objectParameterNames.allSatisfy { name, handle in
            serializedNames.contains(name) && storage.isAliasTarget(handle)
        }
    }

    private static func savedScopeName(_ handles: [UInt64], storage: ScriptStorage, frame: ScriptFrame,
                                       checkpointScope: CheckpointScope? = nil) throws -> String? {
        guard !handles.isEmpty else { return nil }
        guard handles.count == 1, let handle = handles.first else {
            throw ResourceError.rejected("save_scope_selector_count_outside_profile")
        }
        if handle == ScriptStorage.effectHandle { return "eff" }
        if handle == ScriptStorage.systemHandle { return "sys" }
        if handle == ScriptStorage.replacementHandle { return "rep" }
        if let checkpointScope, handle == checkpointScope.handle { return checkpointScope.rawValue }
        let isSaveableTimer = storage.timers[handle].map(Self.isSaveScopedTimer) ?? false
        guard storage.tables[handle] != nil || storage.lists[handle] != nil ||
                  storage.images[handle] != nil || isSaveableTimer else {
            if storage.timers[handle] != nil {
                throw ResourceError.rejected("save_scope_active_timer_outside_profile")
            }
            let kinds = [
                storage.images[handle] != nil ? "image" : nil,
                storage.buttons.contains(handle) ? "button" : nil,
                storage.messages[handle] != nil ? "message" : nil,
                storage.soundChannels[handle] != nil ? "sound" : nil,
                storage.timers[handle] != nil ? "timer" : nil,
                storage.movies[handle] != nil ? "movie" : nil,
                storage.bars[handle] != nil ? "bar" : nil
            ].compactMap { $0 }.joined(separator: ",")
            let object = ScriptValue.object(handle)
            let globalKeys = storage.global.compactMap { key, binding in
                binding.elements.contains(object) ? key.sha256Hex : nil
            }.sorted().prefix(8).joined(separator: ",")
            let localKeys = frame.locals.compactMap { key, binding in
                binding.elements.contains(object) ? key.sha256Hex : nil
            }.sorted().prefix(8).joined(separator: ",")
            throw ResourceError.rejected(
                "save_scope_object_type_outside_profile:handle=\(String(handle, radix: 16)):object_kinds=\(kinds.isEmpty ? "none" : kinds):global_key_sha256=\(globalKeys):local_key_sha256=\(localKeys)")
        }
        let matches = storage.global.filter { _, binding in
            binding.elements.count == 1 && binding.first == .object(handle)
        }
        guard matches.count == 1, let key = matches.first?.key,
              !storage.globalObjectAliases.contains(key), frame.locals[key] == nil,
              let name = String(data: key, encoding: .utf8),
              name.range(of: #"^#?[a-z_][a-z_0-9]*$"#, options: .regularExpression) != nil else {
            throw ResourceError.rejected("save_scope_table_identity_ambiguous")
        }
        return name
    }

    static func restoredScope(_ name: String?, storage: ScriptStorage, frame: ScriptFrame,
                              checkpointScope: CheckpointScope? = nil) throws -> [UInt64] {
        guard let name else { return [] }
        if let checkpointScope, asciiLower(name) == checkpointScope.rawValue {
            return [checkpointScope.handle]
        }
        switch asciiLower(name) {
        case "eff": return [ScriptStorage.effectHandle]
        case "sys": return [ScriptStorage.systemHandle]
        case "rep": return [ScriptStorage.replacementHandle]
        default:
            let key = Data(asciiLower(name).utf8)
            guard frame.locals[key] == nil, !storage.globalObjectAliases.contains(key),
                  let binding = storage.global[key], binding.elements.count == 1,
                  case .object(let handle) = binding.first,
                  storage.tables[handle] != nil || storage.lists[handle] != nil || storage.images[handle] != nil ||
                      (storage.timers[handle].map(Self.isSaveScopedTimer) ?? false),
                  try savedScopeName([handle], storage: storage, frame: frame) == asciiLower(name) else {
                throw ResourceError.rejected("saved_routine_scope_outside_profile")
            }
            return [handle]
        }
    }

    static func stageSavedDialogueLog(_ prefix: SaveStatePrefix?, state: Data,
                                     location: ScriptLocation, storage: inout ScriptStorage) throws {
        guard let prefix else { return }
        try prefix.requireEmptyInactiveDialogueLogRecords()
        let entries = try prefix.decodedDialogueLog(in: state)
        let byteCount = entries.reduce(0) {
            $0 + $1.speaker.utf8.count + $1.text.utf8.count + $1.voice.utf8.count + $1.extra.utf8.count
        }
        guard byteCount <= 16 * 1024 * 1024 else {
            throw ResourceError.rejected("saved_dialogue_log_budget")
        }
        // The serialized ring is read newest-first, while the live log appends
        // oldest-to-newest and resolves ?g,0 from its end.
        storage.dialogueLogEntries = entries.reversed().map {
            .init(location: location, speaker: $0.speaker, text: $0.text, voice: $0.voice,
                 extra: $0.extra, integerFields: $0.integerFields)
        }
        storage.dialogueLogBytes = byteCount
    }

    /// Serialize the thread of a timed wait with resolved call sites. Other engine state
    /// belongs to subsequent sections of the save stream.
    package func encodeTimedWaitThread(scriptPath requestedPath: String? = nil, readerOpaqueFields: Data, allowsIndexedLocals: Bool = false) throws -> Data {
        guard let wait = liveSaveWait else {
            throw ResourceError.rejected("save_thread_live_wait_outside_profile")
        }
        let checkpointScope = wait.mode == 0 ? Self.checkpointScope(at: program.document.records[wait.commandIndex]) : nil
        let label: String
        if wait.command == "jmp", systemTaskEntryLabel == "@@!Quit" {
            label = "@@!Quit"
        } else if let entryLabel = storage.frames.last?.entryLabel {
            label = entryLabel
        } else {
            // A root launched without an explicit entry can still encode a
            // relative cursor against a unique preceding label in its source.
            let records = program.document.records
            let waitSource = records[pc - 1].location
            guard storage.frames.count == 1,
                  let index = records.indices.prefix(pc - 1).last(where: {
                      let record = records[$0]
                      return record.kind == .label && record.location.sourceFile == waitSource.sourceFile &&
                          record.location.sourceSHA256 == waitSource.sourceSHA256
                  }), let name = records[index].identifier,
                  try program.label("@@" + name) == index else {
                throw ResourceError.rejected("save_thread_live_entry_label_unavailable")
            }
            label = "@@" + name
        }
        for (index, frame) in storage.frames.enumerated() {
            let scopeIssue: String?
            do {
                _ = try Self.savedScopeName(frame.tableScope, storage: storage, frame: frame,
                    checkpointScope: index == storage.frames.count - 1 ? checkpointScope : nil)
                scopeIssue = nil
            }
            catch { scopeIssue = String(describing: error) }
            guard frame.savedReturnScalars == nil, scopeIssue == nil else {
                throw ResourceError.rejected(
                    "save_thread_live_frame_outside_profile: frame=\(index) controls=\(frame.controls.count) scope=\(frame.tableScope.count) scope_handles=\(frame.tableScope.map { String($0, radix: 16) }.joined(separator: ",")) scope_issue=\(scopeIssue ?? "none") return_scalars=\(frame.savedReturnScalars != nil)")
            }
        }
        for (index, frame) in storage.frames.enumerated() {
            guard (allowsIndexedLocals || (frame.locals.isEmpty && frame.objectAliases.isEmpty && (frame.parameterCount ?? 0) == 0)),
                  Self.liveObjectParametersAreRepresentable(frame, storage: storage) else {
                let keys = frame.objectParameterNames.keys.map(\.sha256Hex).sorted().joined(separator: ",")
                throw ResourceError.rejected(
                    "save_thread_live_bindings_outside_profile:frame=\(index):locals=\(frame.locals.count):object_aliases=\(frame.objectAliases.count):object_parameters=\(frame.objectParameterNames.count):object_parameter_key_sha256=\(keys)")
            }
        }
        let anchor = program.document.records[try program.label(label)].location
        let scriptPath: String
        if let catalog = repository?.catalog {
            guard let path = requestedPath ?? catalog.reference(forPhysical: anchor.sourceFile)?.logicalPath else {
                throw ResourceError.rejected("save_thread_live_reader_source_mismatch")
            }
            scriptPath = path
            let reference = try catalog.resolve(scriptPath)
            guard reference.sourceFile.utf8.elementsEqual(anchor.sourceFile.utf8),
                  reference.sourceSHA256 == anchor.sourceSHA256 else {
                throw ResourceError.rejected("save_thread_live_reader_source_mismatch")
            }
        } else {
            scriptPath = requestedPath ?? anchor.sourceFile
            guard try ScriptModuleCatalog.key(scriptPath) == ScriptModuleCatalog.key(anchor.sourceFile) else {
                throw ResourceError.rejected("save_thread_live_reader_source_mismatch")
            }
        }
        let fields = try program.savedReaderFields(commandIndex: wait.commandIndex, anchor: anchor,
                                                   afterWaitCommand: wait.mode == 0 ? nil : wait.command)
        let replacements = try storage.replacementOrder.map { key -> (String, String, Int32) in
            guard let rule = storage.replacementRules[key], rule.key.hasPrefix("^") else {
                throw ResourceError.rejected("saved_reader_replacement_outside_profile")
            }
            return (rule.key, rule.value, 0)
        }
        let reader = try SaveReaderCursor.encodeRecord(relativeLine: fields.line, utf16Position: fields.position,
            replaceEnableByte: replacements.isEmpty ? 0 : 1, opaqueFields: readerOpaqueFields, lineBuffer: fields.text,
            scriptPath: scriptPath, label: String(label.dropFirst(2)), textPrefix: storage.exceptTextPrefix ?? "",
            emptyLineText: storage.noWordLineText ?? "", replacements: replacements)
        func sourceAnchor(_ script: ScriptProgram, _ frame: ScriptFrame, _ position: Int) throws -> (String, Int) {
            let records = script.document.records
            guard records.indices.contains(position) else { throw ResourceError.rejected("save_frame_anchor_unavailable") }
            let location = records[position].location
            let limit = min(position, frame.controls.first ?? position)
            func matches(_ index: Int) -> Bool {
                let candidate = records[index].location
                return index <= limit && candidate.sourceFile == location.sourceFile &&
                    candidate.sourceSHA256 == location.sourceSHA256
            }
            if let label = frame.entryLabel, let index = try? script.label(label), matches(index) {
                return (label, index)
            }
            for index in (0...limit).reversed() where records[index].kind == .label && matches(index) {
                guard let identifier = records[index].identifier else { continue }
                let label = "@@" + identifier
                if (try? script.label(label)) == index { return (label, index) }
            }
            throw ResourceError.rejected("save_frame_source_anchor_unavailable")
        }
        let routines = try storage.frames.enumerated().map { index, frame in
            let active = index == storage.frames.count - 1
            var blocks: [Data] = []
            if index > 0 {
                guard let caller = frame.returnProgram, let destination = frame.returnIndex,
                      destination > 0, caller.document.records.indices.contains(destination) else {
                    throw ResourceError.rejected("save_thread_live_return_outside_profile: frame=\(index) missing_caller_or_destination")
                }
                let (callerLabel, callerAnchorIndex) = try sourceAnchor(caller, storage.frames[index - 1], destination - 1)
                let callRecord = caller.document.records[destination - 1]
                let prefix: String?
                if callRecord.kind == .empty, let text = storage.noWordLineText,
                   text == "\\subp," + (frame.entryLabel ?? ""), frame.parameterCount == nil {
                    prefix = text
                } else if callRecord.command.map(asciiLower) == "sub" {
                    prefix = nil
                } else if callRecord.kind == .lineTag, frame.completedLineReturnCandidate {
                    prefix = nil
                } else {
                    throw ResourceError.rejected("save_thread_live_return_outside_profile: frame=\(index) call_record=\(callRecord.kind.rawValue)")
                }
                let call = callRecord.location
                let callerAnchor = caller.document.records[callerAnchorIndex].location
                guard let source = caller.sources[Data(call.sourceFile.utf8)] else {
                    throw ResourceError.rejected("save_thread_live_return_outside_profile")
                }
                let path: String
                if call.sourceFile == anchor.sourceFile, call.sourceSHA256 == anchor.sourceSHA256 {
                    path = scriptPath
                } else if let catalog = repository?.catalog,
                          let entry = catalog.reference(forPhysical: call.sourceFile) {
                    path = entry.logicalPath
                    let reference = try catalog.resolve(path)
                    guard reference.sourceFile == call.sourceFile, reference.sourceSHA256 == call.sourceSHA256 else {
                        throw ResourceError.rejected("save_thread_live_return_source_mismatch")
                    }
                } else {
                    throw ResourceError.rejected("save_thread_live_return_outside_profile")
                }
                let end = prefix == nil ? call.byteOffset + call.byteLength : call.byteOffset
                let position = source.location(end..<end, line: call.lineNumber)
                let fields = try SaveReaderCursor.sourceRecordFields(position: position, anchor: callerAnchor, source: source)
                guard let cursorPosition = Int32(exactly: prefix?.utf16.count ?? Int(fields.position)) else {
                    throw ResourceError.rejected("save_thread_live_return_outside_profile")
                }
                blocks = [try SaveReaderCursor.ControlBlock.encode(rawState: 1,
                    rawValueAt38: fields.line, rawValueAt3C: cursorPosition,
                    strings: [path, String(callerLabel.dropFirst(2))] + Array(repeating: "", count: 8))]
            }
            if !frame.controls.isEmpty {
                let frameProgram: ScriptProgram
                let framePosition: Int
                if active {
                    frameProgram = program; framePosition = pc
                } else {
                    let child = storage.frames[index + 1]
                    guard let caller = child.returnProgram, let destination = child.returnIndex else {
                        throw ResourceError.rejected("save_active_if_frame_unavailable")
                    }
                    frameProgram = caller; framePosition = destination
                }
                guard frameProgram.document.records.indices.contains(framePosition),
                      frameProgram.ancestors[framePosition] == frame.controls else {
                    throw ResourceError.rejected("save_active_if_frame_unavailable")
                }
                let (frameLabel, frameAnchorIndex) = try sourceAnchor(frameProgram, frame, framePosition)
                let frameAnchor = frameProgram.document.records[frameAnchorIndex].location
                for start in frame.controls {
                    guard let block = frameProgram.blocks[start], block.family == "if", block.conditionalShapeSupported,
                          let condition = frame.ifConditions[start], (0...1).contains(condition),
                          framePosition != block.conditionalElse,
                          condition == (block.conditionalElse.map { framePosition > $0 } == true ? 0 : 1),
                          start > frameAnchorIndex else {
                        throw ResourceError.rejected("save_active_if_outside_profile")
                    }
                    let opening = frameProgram.document.records[start].location
                    guard opening.sourceFile == frameAnchor.sourceFile, opening.sourceSHA256 == frameAnchor.sourceSHA256,
                          !frameProgram.document.records[(frameAnchorIndex + 1)..<start].contains(where: {
                              $0.kind == .label && $0.location.sourceFile == frameAnchor.sourceFile
                          }), let source = frameProgram.sources[Data(opening.sourceFile.utf8)] else {
                        throw ResourceError.rejected("save_active_if_anchor_ambiguous")
                    }
                    let path: String
                    if let catalog = repository?.catalog,
                       let entry = catalog.reference(forPhysical: opening.sourceFile) {
                        let resolved = try catalog.resolve(entry.logicalPath)
                        guard resolved.sourceFile == opening.sourceFile, resolved.sourceSHA256 == opening.sourceSHA256 else {
                            throw ResourceError.rejected("save_active_if_source_mismatch")
                        }
                        path = entry.logicalPath
                    } else if opening.sourceFile == anchor.sourceFile && opening.sourceSHA256 == anchor.sourceSHA256 {
                        path = scriptPath
                    } else {
                        throw ResourceError.rejected("save_active_if_source_mismatch")
                    }
                    let end = opening.byteOffset + opening.byteLength
                    let position = source.location(end..<end, line: opening.lineNumber)
                    let controlFields = try SaveReaderCursor.sourceRecordFields(position: position, anchor: frameAnchor, source: source)
                    blocks.append(try SaveReaderCursor.ControlBlock.encode(rawState: 2,
                        rawValueAt38: controlFields.line, rawValueAt3C: controlFields.position,
                        strings: [path, String(frameLabel.dropFirst(2)), String(condition)] + Array(repeating: "", count: 7)))
                }
            }
            var scope = Array(repeating: "", count: 16)
            if let name = try Self.savedScopeName(frame.tableScope, storage: storage, frame: frame,
                checkpointScope: active ? checkpointScope : nil) { scope[0] = name }
            return try SaveReaderCursor.Routine.encode(scope: scope,
                rawState: active ? wait.mode : 0, waitTime: active ? wait.remaining : 0,
                skipTime: active ? wait.initial : 0, channel: 0,
                jumpLabel: "", eventLabel: active ? (wait.stopLabel ?? "") : "", eventName: "", resultSnapshot: nil, controlBlocks: blocks)
        }
        return try SaveReaderCursor.encodeThread(routines: routines, reader: reader)
    }

    /// Verify return cursors and active controls against the live, pinned
    /// execution frames before combining with donor state. This is a local
    /// structural check, not a claim about original-engine save equivalence.
    package func validateTimedWaitReturnCursors(_ thread: Data) throws {
        guard var pinned = repository else { throw ResourceError.rejected("save_thread_catalog_required") }
        let cursor = try SaveReaderCursor(threadState: thread)
        guard cursor.routines.count == storage.frames.count else {
            throw ResourceError.rejected("save_thread_roundtrip_frame_count")
        }
        let emptyPrefix = try cursor.emptyLineText.utf16Text(in: thread)
        var callers: [(program: ScriptProgram, index: Int, anchor: ScriptLocation)] = []
        for index in 1..<storage.frames.count {
            let frame = storage.frames[index]
            guard let block = cursor.routines[index].controlBlocks.first, block.rawState == 1,
                  let caller = frame.returnProgram, let expected = frame.returnIndex,
                  caller.document.records.indices.contains(expected) else {
                throw ResourceError.rejected("save_thread_roundtrip_return_missing: frame=\(index)")
            }
            let (_, resolved, source, anchor, _, _) = try SaveReaderCursor.routineReturnPosition(
                block, in: thread, repository: &pinned, emptyLineText: emptyPrefix)
            guard let resolved else {
                throw ResourceError.rejected("save_thread_roundtrip_return_unresolved: frame=\(index)")
            }
            let mapped = try Self.mapSavedPosition((source, resolved, anchor), to: caller)
            guard mapped.index == expected else {
                throw ResourceError.rejected("save_thread_roundtrip_return_mismatch: frame=\(index)")
            }
            if frame.completedLineReturnCandidate, expected > 0,
               [.empty, .lineTag].contains(caller.document.records[expected - 1].kind) {
                // Exercise the same frame reconstruction used by loading,
                // before any unrelated global-object template is required.
                let callee = index + 1 < storage.frames.count
                    ? storage.frames[index + 1].returnProgram : program
                guard let callee, let label = frame.entryLabel else {
                    throw ResourceError.rejected("save_thread_blank_call_context_unavailable")
                }
                let entry = callee.document.records[try callee.label(label)].location
                var prefixStorage = storage
                prefixStorage.frames = Array(storage.frames.prefix(index))
                var savedLocals = frame.locals
                if let parameterCount = frame.parameterCount, parameterCount != 0 {
                    let keys = ["paramcount", "paramint", "paramstr"].map { Data($0.utf8) }
                    guard frame.returnIndex != nil, (0...16).contains(parameterCount),
                          let integers = frame.integerParameters, integers.count == 16,
                          let strings = frame.stringParameters, strings.count == 16,
                          keys.allSatisfy({ savedLocals[$0] == nil }) else {
                        throw ResourceError.rejected("save_thread_roundtrip_call_parameter_shape: frame=\(index)")
                    }
                    savedLocals[keys[0]] = .init(elements: [.integer(parameterCount)])
                    savedLocals[keys[1]] = .init(elements: integers.map(ScriptValue.integer))
                    savedLocals[keys[2]] = .init(elements: strings.map(ScriptValue.string))
                }
                try Self.stageSavedCall(callee: callee, anchor: entry, caller: caller,
                    returnIndex: expected, catalog: pinned.catalog, locals: savedLocals, storage: &prefixStorage)
                guard prefixStorage.frames.count == index + 1,
                      prefixStorage.frames.last?.returnIndex == expected,
                      prefixStorage.frames.last?.entryLabel == label,
                      prefixStorage.frames.last?.completedLineReturnCandidate == frame.completedLineReturnCandidate else {
                    throw ResourceError.rejected("save_thread_blank_call_roundtrip_mismatch")
                }
            }
            callers.append(mapped)
        }
        var staged = storage
        var controlRepository: ScriptRepository? = pinned
        for (index, caller) in callers.enumerated() {
            let allBlocks = cursor.routines[index].controlBlocks
            let blocks = index == 0 ? allBlocks : Array(allBlocks.dropFirst())
            try Self.stageSavedFrameControls(program: caller.program, index: caller.index, anchor: caller.anchor,
                blocks: blocks, state: thread, repository: &controlRepository, storage: &staged, frameIndex: index)
            guard staged.frames[index].controls == storage.frames[index].controls,
                  staged.frames[index].ifConditions == storage.frames[index].ifConditions else {
                throw ResourceError.rejected("save_thread_roundtrip_controls_mismatch: frame=\(index)")
            }
        }
        let active = try cursor.resolveResumeInstruction(in: thread, repository: &pinned)
        let activePosition = try Self.mapSavedPosition((active.program, active.index, active.location), to: program)
        if let request = primarySaveRequest, activePosition.index != request.resumeIndex {
            throw ResourceError.rejected("primary_save_resume_instruction_mismatch: request=\(request.resumeIndex) actual=\(activePosition.index) wait=\(macExceptionBackupLiveWaitOverride?.commandIndex ?? -1)")
        }
        let last = storage.frames.count - 1
        let blocks = last == 0 ? cursor.routines[last].controlBlocks : Array(cursor.routines[last].controlBlocks.dropFirst())
        try Self.stageSavedFrameControls(program: program, index: activePosition.index, anchor: active.location,
            blocks: blocks, state: thread, repository: &controlRepository, storage: &staged, frameIndex: last)
        guard staged.frames[last].controls == storage.frames[last].controls,
              staged.frames[last].ifConditions == storage.frames[last].ifConditions else {
            throw ResourceError.rejected("save_thread_roundtrip_controls_mismatch: frame=\(last)")
        }
    }

    /// Experimental local overlay, bound to the exact input configuration.
    /// It does not write or claim compatibility with the original config file.
    package func encodeResearchConfigurationOverlay() throws -> Data {
        guard let sha = storage.configuration?.summary?.source.sourceSHA256 else {
            throw ResourceError.rejected("research_config_overlay_requires_base_configuration")
        }
        var fonts: [String: ResearchConfigurationOverlay.FontValue] = [:]
        for (key, value) in storage.fontOverrides {
            switch value {
            case .integer(let integer): fonts[key] = .init(text: nil, integer: integer)
            case .string(let text): fonts[key] = .init(text: text, integer: nil)
            case .object: throw ResourceError.rejected("research_config_overlay_font_outside_profile")
            }
        }
        let hasActors = !storage.actorVolumeOverrides.isEmpty || !storage.actorMuteOverrides.isEmpty
        let actorHash: String?
        if hasActors, let aliases = storage.voiceActorAliases {
            actorHash = try JSONEncoder().encode(aliases).sha256Hex
        } else { actorHash = hasActors ? storage.researchExpectedActorAliasSHA256 : nil }
        let overlay = ResearchConfigurationOverlay(schemaVersion: 1, baseConfigurationSHA256: sha,
            messageValues: storage.configMessageOverrides, messageAlphaNeedsRendering: storage.configMessageAlphaNeedsRendering,
            displayValues: storage.configDisplayOverrides.isEmpty ? nil : storage.configDisplayOverrides,
            displayNeedsHostUpdate: storage.configDisplayNeedsHostUpdate ? true : nil,
            displayRefreshRequested: storage.configDisplayRefreshRequested ? true : nil,
            actorVolumes: storage.actorVolumeOverrides, actorMutes: storage.actorMuteOverrides, actorAliasSHA256: actorHash,
            audioVolumes: storage.configVoiceValues, audioMutes: storage.configVoiceModes, fonts: fonts)
        try overlay.validate(baseSHA256: sha)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(overlay)
        guard data.count <= 64 * 1024 else { throw ResourceError.rejected("research_config_overlay_size_limit") }
        return data
    }

    package mutating func applyResearchConfigurationOverlay(_ data: Data) throws {
        guard data.count <= 64 * 1024, executedSteps == 0,
              let sha = storage.configuration?.summary?.source.sourceSHA256 else {
            throw ResourceError.rejected("research_config_overlay_requires_fresh_configured_session")
        }
        let allowed: Set<String> = ["schemaVersion", "baseConfigurationSHA256", "messageValues", "messageAlphaNeedsRendering", "displayValues", "displayNeedsHostUpdate", "displayRefreshRequested",
            "actorVolumes", "actorMutes", "actorAliasSHA256", "audioVolumes", "audioMutes", "fonts"]
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: allowed), let fonts = object["fonts"] as? [String: Any],
              fonts.values.allSatisfy({ value in
                  guard let fields = value as? [String: Any] else { return false }
                  return Set(fields.keys).isSubset(of: ["text", "integer"])
              }) else { throw ResourceError.rejected("research_config_overlay_unknown_field") }
        let overlay = try JSONDecoder().decode(ResearchConfigurationOverlay.self, from: data)
        try overlay.validate(baseSHA256: sha)
        var staged = storage
        staged.configMessageOverrides = overlay.messageValues
        staged.configMessageAlphaNeedsRendering = overlay.messageAlphaNeedsRendering
        staged.configDisplayOverrides = overlay.displayValues ?? [:]
        staged.configDisplayNeedsHostUpdate = overlay.displayNeedsHostUpdate ?? false
        staged.configDisplayRefreshRequested = overlay.displayRefreshRequested ?? false
        staged.actorVolumeOverrides = overlay.actorVolumes
        staged.actorMuteOverrides = overlay.actorMutes
        staged.researchExpectedActorAliasSHA256 = overlay.actorAliasSHA256
        staged.configVoiceValues = overlay.audioVolumes
        staged.configVoiceModes = overlay.audioMutes
        staged.fontOverrides = try overlay.fonts.mapValues { value in
            if let integer = value.integer { return .integer(integer) }
            guard let text = value.text else { throw ResourceError.rejected("research_config_overlay_font_outside_profile") }
            return .string(text)
        }
        try staged.validate()
        storage = staged
    }

    package struct ResearchMessagePrimaryProbe: Encodable {
        let status: EvidenceStatus
        let scope = "isolated_primary_text_and_layout_not_full_message_or_slot"
        let templateSHA256: String
        let messageCount: Int
        let attempted: Int
        let completed: Int
        let failures: Int
        let firstIssue: String?
        let layoutAttempted: Int
        let layoutCompleted: Int
        let layoutSkippedWithoutExplicitKwl: Int
        let layoutBoundsWritten: Int
        let layoutMarginsWritten: Int
        let layoutFailures: Int
        let layoutFirstIssue: String?
        let layoutStatus: EvidenceStatus
    }

    package func probeMessagePrimaryWrites(templateState: Data) throws -> ResearchMessagePrimaryProbe {
        guard liveSaveWait != nil, templateState.count <= SaveEnvelope.maxFileBytes else {
            throw ResourceError.rejected("message_primary_probe_requires_live_wait")
        }
        let reader = try SaveReaderCursor(threadState: templateState)
        let prefix = try SaveStatePrefix(state: templateState, after: reader)
        let calVal = try prefix.locateCalVal(in: templateState)
        let arrays = try SaveVariableArrays.readCalVal(state: templateState, at: calVal)
        guard let recordIndex = arrays.records.firstIndex(where: { record in
            guard asciiLower(record.textFields[1]) == "msg", case .objectText(let elements) = record.values else { return false }
            return elements.contains { $0.messagePayload != nil }
        }), case .objectText(let elements) = arrays.records[recordIndex].values,
              let elementIndex = elements.firstIndex(where: { $0.messagePayload != nil }) else {
            throw ResourceError.rejected("message_primary_probe_template_missing")
        }
        let handles = storage.messages.keys.sorted()
        guard handles.count <= 64 else { throw ResourceError.rejected("message_primary_probe_count_limit") }
        var attempted = 0, completed = 0, firstIssue: String?
        var layoutAttempted = 0, layoutCompleted = 0, layoutFirstIssue: String?
        var layoutBoundsWritten = 0, layoutMarginsWritten = 0
        for handle in handles {
            guard let message = storage.messages[handle] else { continue }
            attempted += 1
            var primaryState: Data?
            do {
                primaryState = try SaveVariableArrays.replacingMessagePrimaryCandidate(in: templateState,
                    decodedOffset: calVal + 16, recordIndex: recordIndex, elementIndex: elementIndex, message: message)
                completed += 1
            } catch {
                if firstIssue == nil { firstIssue = String(describing: error) }
            }
            if message.kinsokuWordLength != nil {
                layoutAttempted += 1
                do {
                    guard let primaryState else { throw ResourceError.rejected("saved_message_layout_primary_write_failed") }
                    _ = try SaveVariableArrays.replacingMessageLayoutCandidate(in: primaryState,
                        decodedOffset: calVal + 16, recordIndex: recordIndex, elementIndex: elementIndex, message: message)
                    layoutCompleted += 1
                    if message.textBounds != nil { layoutBoundsWritten += 1 }
                    if message.textMargins != nil { layoutMarginsWritten += 1 }
                } catch {
                    if layoutFirstIssue == nil { layoutFirstIssue = String(describing: error) }
                }
            }
        }
        return .init(status: attempted == 0 ? .notTested :
                        (attempted == completed && layoutAttempted == layoutCompleted ? .inferred : .unsupported),
                     templateSHA256: templateState.sha256Hex, messageCount: handles.count,
                     attempted: attempted, completed: completed, failures: attempted - completed, firstIssue: firstIssue,
                     layoutAttempted: layoutAttempted, layoutCompleted: layoutCompleted,
                     layoutSkippedWithoutExplicitKwl: handles.count - layoutAttempted,
                     layoutBoundsWritten: layoutBoundsWritten, layoutMarginsWritten: layoutMarginsWritten,
                     layoutFailures: layoutAttempted - layoutCompleted, layoutFirstIssue: layoutFirstIssue,
                     layoutStatus: layoutAttempted == 0 ? .notTested :
                        (layoutAttempted == layoutCompleted ? .inferred : .unsupported))
    }

    package struct ResearchImagePlacementProbe: Encodable {
        let status: EvidenceStatus
        let scope = "isolated_static_placement_and_user_integers_not_full_image_or_slot"
        let templateSHA256: String
        let imageCount: Int
        let attempted: Int
        let completed: Int
        let skipped: Int
        let skipReasons: [String: Int]
        let failures: Int
        let firstIssue: String?
        let userIntegerAttempted: Int
        let userIntegerCompleted: Int
        let userIntegerFirstIssue: String?
    }

    package func probeImagePlacementWrites(templateState: Data) throws -> ResearchImagePlacementProbe {
        guard liveSaveWait != nil, templateState.count <= SaveEnvelope.maxFileBytes else {
            throw ResourceError.rejected("image_placement_probe_requires_live_wait")
        }
        let reader = try SaveReaderCursor(threadState: templateState)
        let prefix = try SaveStatePrefix(state: templateState, after: reader)
        let calVal = try prefix.locateCalVal(in: templateState)
        let arrays = try SaveVariableArrays.readCalVal(state: templateState, at: calVal)
        guard let recordIndex = arrays.records.firstIndex(where: { record in
            guard ["img", "simg"].contains(asciiLower(record.textFields[1])),
                  case .objectText(let elements) = record.values else { return false }
            return elements.contains { $0.imagePayload != nil }
        }), case .objectText(let elements) = arrays.records[recordIndex].values,
              let elementIndex = elements.firstIndex(where: { $0.imagePayload != nil }) else {
            throw ResourceError.rejected("image_placement_probe_template_missing")
        }
        let handles = storage.images.keys.sorted()
        guard handles.count <= 256 else { throw ResourceError.rejected("image_placement_probe_count_limit") }
        var attempted = 0, completed = 0, skipped = 0, firstIssue: String?
        var userIntegerAttempted = 0, userIntegerCompleted = 0, userIntegerFirstIssue: String?
        var skipReasons: [String: Int] = [:]
        for handle in handles {
            guard let image = storage.images[handle] else { skipped += 1; skipReasons["missing_image", default: 0] += 1; continue }
            userIntegerAttempted += 1
            do {
                let values = storage.buttonUserIntegers[handle] ?? [:]
                _ = try SaveVariableArrays.replacingImageUserIntegersCandidate(in: templateState,
                    decodedOffset: calVal + 16, recordIndex: recordIndex, elementIndex: elementIndex,
                    values: (0..<4).map { values[$0] ?? 0 })
                userIntegerCompleted += 1
            } catch {
                if userIntegerFirstIssue == nil { userIntegerFirstIssue = String(describing: error) }
            }
            guard let p = image.placement, p.count == 3 else { skipped += 1; skipReasons["placement_unavailable", default: 0] += 1; continue }
            guard let transform = image.transform, transform.scale.count == 3 else { skipped += 1; skipReasons["transform_unavailable", default: 0] += 1; continue }
            guard transform.rotation == [0, 0, 0], transform.depth == 0, transform.loop == 0 else {
                skipped += 1; skipReasons["transform_outside_profile", default: 0] += 1; continue
            }
            guard storage.placementTransitions[handle] == nil else { skipped += 1; skipReasons["active_placement_transition", default: 0] += 1; continue }
            attempted += 1
            do {
                _ = try SaveVariableArrays.replacingImagePlacementCandidate(in: templateState,
                    decodedOffset: calVal + 16, recordIndex: recordIndex, elementIndex: elementIndex,
                    placement: SIMD3(p[0], p[1], p[2]),
                    scale: SIMD3(transform.scale[0], transform.scale[1], transform.scale[2]))
                completed += 1
            } catch {
                if firstIssue == nil { firstIssue = String(describing: error) }
            }
        }
        return .init(status: attempted == 0 && userIntegerAttempted == 0 ? .notTested :
                        (attempted == completed && userIntegerAttempted == userIntegerCompleted ? .inferred : .unsupported),
                     templateSHA256: templateState.sha256Hex, imageCount: handles.count,
                     attempted: attempted, completed: completed, skipped: skipped, skipReasons: skipReasons,
                     failures: attempted - completed, firstIssue: firstIssue,
                     userIntegerAttempted: userIntegerAttempted, userIntegerCompleted: userIntegerCompleted,
                     userIntegerFirstIssue: userIntegerFirstIssue)
    }

    /// Encode the template's declared global bindings at the same suspension
    /// boundary used for the experimental thread writer.
    package func encodeTimedWaitGlobals(template: Data,
                                        objectPayloads: [UInt64: Data] = [:]) throws -> Data {
        guard liveSaveWait != nil else {
            throw ResourceError.rejected("save_globals_live_wait_outside_profile")
        }
        let arrays = try SaveVariableArrays.readCalVal(state: template, at: 0)
        let covered = Set(arrays.records.map { Data(asciiLower($0.textFields[0]).utf8) })
        // Result registers are maintained by the interpreter and are separate
        // from ordinary CalVal declarations in the saved routine format.
        let resultKeys = Set(["resultint", "resultstr", "resultobj", "resultclkint", "resultsubint", "resultsubstr"]
            .map { Data($0.utf8) })
        let missing = Set(storage.global.keys).subtracting(covered).subtracting(resultKeys)
        var encodedObjectPayloads = objectPayloads
        var visualPayloadIssues: [Data: String] = [:]
        var visualBindingKeys = missing
        for record in arrays.records where SaveVariableArrays.visualPayloadTypes.contains(asciiLower(record.textFields[1])) {
            guard case .objectText(let elements) = record.values, !elements.isEmpty else { continue }
            visualBindingKeys.insert(Data(asciiLower(record.textFields[0]).utf8))
        }
        for key in visualBindingKeys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            guard let binding = storage.global[key], !binding.elements.isEmpty else { continue }
            let handles = binding.elements.compactMap { value -> UInt64? in
                guard case .object(let handle) = value else { return nil }; return handle
            }
            guard handles.count == binding.elements.count else { continue }
            let imageArray = handles.allSatisfy({ storage.images[$0] != nil })
            let buttonArray = handles.allSatisfy({ storage.buttons.contains($0) })
            let messageArray = handles.allSatisfy({ storage.messages[$0] != nil })
            guard imageArray || buttonArray || messageArray else { continue }
            do {
                for handle in handles where encodedObjectPayloads[handle] == nil {
                    if imageArray {
                        encodedObjectPayloads[handle] = try SaveVisualObjectEncoder.encodeImageObjectPayload(
                            handle: handle, storage: storage, repository: repository,
                            jpegEncoder: saveTextureJPEGEncoder, researchVideoProfiles: researchVideoSaveProfiles)
                    } else if buttonArray {
                        encodedObjectPayloads[handle] = try SaveVisualObjectEncoder.encodeButtonObjectPayload(
                            handle: handle, storage: storage, repository: repository,
                            jpegEncoder: saveTextureJPEGEncoder)
                    } else {
                        encodedObjectPayloads[handle] = try SaveVisualObjectEncoder.encodeMessageObjectPayload(
                            handle: handle, storage: storage, repository: repository,
                            jpegEncoder: saveTextureJPEGEncoder)
                    }
                }
            } catch {
                let payloadsForKey = Set(handles)
                visualPayloadIssues[key] = String(describing: error)
                // A partially encoded array cannot be emitted. Keep valid
                // payloads for shared handles that may appear in other arrays.
                for handle in payloadsForKey where encodedObjectPayloads[handle] == nil {
                    encodedObjectPayloads.removeValue(forKey: handle)
                }
            }
        }
        let newBindingKeys = missing.filter {
            SaveVariableArrays.generatedBindingType($0, in: storage, objectPayloads: encodedObjectPayloads) != nil
        }
        if let issue = visualPayloadIssues.first(where: { covered.contains($0.key) || newBindingKeys.contains($0.key) }) {
            throw ResourceError.rejected("save_visual_object_payload_encode_failed:key_sha256=\(issue.key.sha256Hex):\(issue.value)")
        }
        let missingObjects = missing.subtracting(newBindingKeys)
        let aliasKeys = newBindingKeys.filter { storage.globalObjectAliases.contains($0) }
        if !aliasKeys.isEmpty {
            // Verify generated reference-only records in isolation before
            // reporting unrelated unsupported global objects.
            let empty = Data("CalVal\0\0".utf8) + Data([1, 0, 0, 0]) + Data(repeating: 0, count: 8)
            let encoded = try SaveVariableArrays.encodeCalValValues(template: empty, storage: storage, newBindingKeys: aliasKeys)
            let decoded = try SaveVariableArrays.readCalVal(state: encoded, at: 0)
            var staged = ScriptStorage()
            guard try staged.stageSavedSoundAliases(decoded) == aliasKeys.count else {
                throw ResourceError.rejected("save_sound_alias_roundtrip_count")
            }
            for key in aliasKeys {
                guard staged.global[key]?.elements == storage.global[key]?.elements,
                      staged.savedSoundAliasTexts(key) == storage.savedSoundAliasTexts(key) else {
                    throw ResourceError.rejected("save_sound_alias_roundtrip_mismatch")
                }
            }
        }
        guard missingObjects.isEmpty else {
            var counts: [String: Int] = [:]
            var visualElements: [String: Int] = [:]
            for key in missingObjects {
                let elements = storage.global[key]?.elements ?? []
                let kinds = Set(elements.map { value -> String in
                    guard case .object(let handle) = value else { return value.typeName }
                    if handle == ScriptStorage.nullHandle { return "null" }
                    if ScriptStorage.isStreamHandle(handle) { return "stream" }
                    if handle == ScriptStorage.cameraHandle { return "camera" }
                    if let image = storage.images[handle] {
                        visualElements[image.resource == nil ? "image_unbound" : "image_bound", default: 0] += 1
                        if let type = storage.visualObjectTypes[handle] { visualElements["declared_" + type, default: 0] += 1 }
                        return "image"
                    }
                    if storage.buttons.contains(handle) {
                        visualElements[storage.buttonResources[handle] == nil ? "button_unbound" : "button_bound", default: 0] += 1
                        if let type = storage.visualObjectTypes[handle] { visualElements["declared_" + type, default: 0] += 1 }
                        return "button"
                    }
                    if storage.messages[handle] != nil { return "message" }
                    if storage.tables[handle] != nil { return "table" }
                    if storage.lists[handle] != nil { return "list" }
                    if storage.timers[handle] != nil { return "timer" }
                    return "object"
                })
                let kind = kinds.count > 1 ? "mixed" : (kinds.first ?? "empty")
                counts[kind, default: 0] += 1
                if kind == "image" {
                    let images = elements.compactMap { value -> ScriptStorage.ImageObject? in
                        guard case .object(let handle) = value else { return nil }
                        return storage.images[handle]
                    }
                    if images.count == elements.count, !images.isEmpty {
                        let unbound = images.allSatisfy({ $0.resource == nil && $0.boundImages.isEmpty })
                        let nondrawing = images.allSatisfy({ !$0.isDrawable })
                        if unbound {
                            counts["image_arrays_all_unbound", default: 0] += 1
                        }
                        if nondrawing {
                            counts["image_arrays_all_nondrawing", default: 0] += 1
                        }
                        if unbound && nondrawing {
                            counts["image_arrays_unbound_nondrawing", default: 0] += 1
                            counts["image_unbound_nondrawing_elements", default: 0] += images.count
                            for image in images {
                                if image.placement != nil { counts["image_unbound_has_placement", default: 0] += 1 }
                                if image.transform != nil { counts["image_unbound_has_transform", default: 0] += 1 }
                                if image.motion != nil || image.selectedMember != nil { counts["image_unbound_has_motion", default: 0] += 1 }
                                if image.colorRequest != nil { counts["image_unbound_has_color", default: 0] += 1 }
                                if image.opacityEndpoint != nil || image.immediateOpacity != 255 { counts["image_unbound_has_opacity", default: 0] += 1 }
                                if !image.generatorRequests.isEmpty || !image.generatorFilterRequests.isEmpty || !image.filterOverrides.isEmpty {
                                    counts["image_unbound_has_generator_or_filter", default: 0] += 1
                                }
                            }
                        }
                        if unbound && nondrawing && images.allSatisfy({
                            $0.generatorRequests.isEmpty && $0.generatorFilterRequests.isEmpty &&
                            $0.filterOverrides.isEmpty && $0.transform == nil && $0.placement == nil &&
                            $0.motion == nil && $0.selectedMember == nil && $0.colorRequest == nil &&
                            $0.opacityEndpoint == nil && $0.immediateOpacity == 255
                        }) {
                            counts["image_arrays_selected_fields_default", default: 0] += 1
                        }
                    }
                } else if kind == "button" {
                    for value in elements {
                        guard case .object(let handle) = value else { continue }
                        if storage.enabledButtons.contains(handle) { counts["button_enabled", default: 0] += 1 }
                        if !(storage.buttonImages[handle] ?? [:]).isEmpty { counts["button_has_textures", default: 0] += 1 }
                        if !(storage.buttonSounds[handle] ?? [:]).isEmpty { counts["button_has_sounds", default: 0] += 1 }
                        if !(storage.buttonUserStrings[handle] ?? [:]).isEmpty { counts["button_has_user_strings", default: 0] += 1 }
                        if storage.buttonScriptTargets[handle] != nil { counts["button_has_script_target", default: 0] += 1 }
                        if storage.buttonText[handle] != nil { counts["button_has_text", default: 0] += 1 }
                        if storage.buttonPlacement[handle] != nil { counts["button_has_placement", default: 0] += 1 }
                        if storage.buttonMotion[handle] != nil { counts["button_has_motion", default: 0] += 1 }
                    }
                } else if kind == "message" {
                    let messages = elements.compactMap { value -> ScriptStorage.MessageObject? in
                        guard case .object(let handle) = value else { return nil }
                        return storage.messages[handle]
                    }
                    if messages.count == elements.count, !messages.isEmpty {
                        counts["message_elements", default: 0] += messages.count
                        counts["message_enabled", default: 0] += messages.count { $0.enabled }
                        counts["message_has_background", default: 0] += messages.count { $0.background != nil }
                        counts["message_has_pending_output", default: 0] += messages.count { !$0.pendingOutput.isEmpty }
                        counts["message_has_committed_output", default: 0] += messages.count { !$0.committedOutput.isEmpty }
                        counts["message_primary_source_available", default: 0] += messages.count { $0.primaryTextWriteCandidate() != nil }
                        let textEmpty = messages.allSatisfy({ $0.pendingOutput.isEmpty && $0.committedOutput.isEmpty })
                        let hiddenUnbound = messages.allSatisfy({ !$0.enabled && $0.background == nil && $0.backgroundBoundImages.isEmpty })
                        if textEmpty {
                            counts["message_arrays_all_text_empty", default: 0] += 1
                        }
                        if hiddenUnbound {
                            counts["message_arrays_all_hidden_unbound", default: 0] += 1
                        }
                        if textEmpty && hiddenUnbound {
                            counts["message_arrays_empty_hidden_unbound", default: 0] += 1
                        }
                    }
                }
                if storage.globalObjectAliases.contains(key) {
                    counts["alias", default: 0] += 1
                    let references = storage.globalAliasReferences[key] ?? []
                    counts["alias_reference_known", default: 0] += references.compactMap { $0 }.count
                    counts["alias_reference_unknown", default: 0] += references.count - references.compactMap { $0 }.count
                }
            }
            let detail = counts.merging(visualElements, uniquingKeysWith: +).sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            let payloadIssueDetail = visualPayloadIssues.sorted(by: { $0.key.lexicographicallyPrecedes($1.key) }).map { key, issue in
                "\(String(data: key, encoding: .utf8) ?? key.sha256Hex)=\(issue)"
            }.joined(separator: ";")
            let missingBindingDetails = missingObjects.sorted(by: { $0.lexicographicallyPrecedes($1) }).prefix(64).map { key -> String in
                let name = String(data: key, encoding: .utf8) ?? "sha256:\(key.sha256Hex.prefix(16))"
                let elements = storage.global[key]?.elements ?? []
                let handles = elements.compactMap { value -> UInt64? in
                    guard case .object(let handle) = value else { return nil }
                    return handle
                }
                let kinds = Set(elements.map { value -> String in
                    guard case .object(let handle) = value else { return value.typeName }
                    if storage.buttons.contains(handle) { return "button" }
                    if storage.images[handle] != nil { return "image" }
                    if storage.messages[handle] != nil { return "message" }
                    if storage.tables[handle] != nil { return "table" }
                    if storage.lists[handle] != nil { return "list" }
                    if storage.timers[handle] != nil { return "timer" }
                    if ScriptStorage.isStreamHandle(handle) { return "stream" }
                    return "object"
                })
                let kind = kinds.count == 1 ? (kinds.first ?? "empty") : "mixed:\(kinds.sorted().joined(separator: "+"))"
                var state: [String: Int] = [:]
                let images = handles.compactMap { storage.images[$0] }
                if !images.isEmpty {
                    state["image_resource"] = images.count { $0.resource != nil }
                    state["image_drawable"] = images.count { $0.isDrawable }
                    state["image_saved_layer_times"] = images.count { $0.savedLayerTimeSnapshot != nil }
                    state["image_bound_textures"] = images.reduce(0) { $0 + $1.boundImages.count }
                    state["image_placement"] = images.count { $0.placement != nil }
                    state["image_transform"] = images.count { $0.transform != nil }
                    state["image_motion"] = images.count { $0.motion != nil || $0.selectedMember != nil }
                    state["image_opacity_transition"] = images.count { $0.opacityEndpoint != nil }
                    state["image_generators"] = images.reduce(0) { $0 + $1.generatorRequests.count }
                    state["image_generator_filters"] = images.reduce(0) { $0 + $1.generatorFilterRequests.count }
                    state["image_selected_member_set"] = images.count { $0.selectedMember != nil }
                    state["image_motion_start_tick_set"] = images.count { $0.motionStartTick != nil }
                    state["image_extended_container"] = images.count { $0.hasExtendedContainerMetadata }
                    state["image_enabled"] = images.count { $0.enabled }
                    state["image_animation_speed_set"] = images.count { $0.animationSpeed != nil }
                    state["image_animation_speed_nondefault"] = images.count { $0.animationSpeed != nil && $0.animationSpeed != 100 }
                    state["image_playback_speed_nondefault"] = images.count { $0.playbackSpeed != nil && $0.playbackSpeed != 100 }
                    state["image_action_clock_stale"] = images.count {
                        ($0.selectedMember != nil || $0.motionStartTick != nil) &&
                            $0.savedLayerTimeSnapshot?.visualTick != storage.visualTicks
                    }
                    let staleImages = images.filter {
                        ($0.selectedMember != nil || $0.motionStartTick != nil) &&
                            $0.savedLayerTimeSnapshot?.visualTick != storage.visualTicks
                    }
                    for (source, values) in Dictionary(grouping: staleImages, by: {
                        String(($0.resource?.sourceSHA256 ?? "unbound").prefix(12))
                    }) {
                        state["image_action_clock_stale_source_\(source)"] = values.count
                        state["image_action_clock_stale_missing_snapshot_\(source)"] = values.count { $0.savedLayerTimeSnapshot == nil }
                        state["image_action_clock_stale_enabled_\(source)"] = values.count { $0.enabled }
                        state["image_action_clock_stale_extended_\(source)"] = values.count { $0.hasExtendedContainerMetadata }
                        state["image_action_clock_stale_static_single_\(source)"] = values.count {
                            !$0.hasExtendedContainerMetadata && $0.resource != nil && $0.memberCount <= 1
                        }
                        state["image_action_clock_stale_layer_flags_\(source)"] = values.count {
                            $0.layerAuxiliaryFlags?.count == 256
                        }
                        state["image_action_clock_stale_max_tick_gap_\(source)"] = Int(values.compactMap {
                            $0.savedLayerTimeSnapshot.map { storage.visualTicks - $0.visualTick }
                        }.max() ?? 0)
                    }
                    let motionAges = images.compactMap { image -> Int64? in
                        guard let start = image.motionStartTick else { return nil }
                        return max(0, storage.visualTicks - start)
                    }
                    state["image_motion_age_max_ticks"] = Int(motionAges.max() ?? 0)
                    for actionIndex in Set(images.compactMap(\.selectedMember)) {
                        state["image_selected_member_\(actionIndex)"] = images.count { $0.selectedMember == actionIndex }
                    }
                    state["image_member_count_total"] = images.reduce(0) { $0 + $1.memberCount }
                    state["image_member_count_max"] = images.map(\.memberCount).max() ?? 0
                    let requests = Dictionary(grouping: images.flatMap { $0.generatorRequests.values },
                                              by: { $0.arguments.first ?? -1 })
                    for mode in 0...12 {
                        state["image_generator_mode_\(mode)"] = requests[Int32(mode)]?.count ?? 0
                    }
                    let generatorTimes = images.flatMap { $0.generatorRequests.values.map(\.currentTime) }
                    state["image_generator_nonzero_current_time"] = generatorTimes.count { $0 > 0 }
                    state["image_generator_max_current_time"] = Int(generatorTimes.max() ?? 0)
                }
                let buttons = handles.filter { storage.buttons.contains($0) }
                if !buttons.isEmpty {
                    state["button_enabled"] = buttons.count { storage.enabledButtons.contains($0) }
                    state["button_resources"] = buttons.count { storage.buttonResources[$0] != nil }
                    state["button_textures"] = buttons.reduce(0) { $0 + (storage.buttonImages[$1]?.count ?? 0) }
                    state["button_sounds"] = buttons.reduce(0) { $0 + (storage.buttonSounds[$1]?.count ?? 0) }
                    state["button_user_strings"] = buttons.reduce(0) { $0 + (storage.buttonUserStrings[$1]?.count ?? 0) }
                    state["button_user_integers"] = buttons.reduce(0) { $0 + (storage.buttonUserIntegers[$1]?.count ?? 0) }
                    state["button_text"] = buttons.count { storage.buttonText[$0] != nil }
                    state["button_placement"] = buttons.count { storage.buttonPlacement[$0] != nil }
                    state["button_motion"] = buttons.count { storage.buttonMotion[$0] != nil }
                }
                let messages = handles.compactMap { storage.messages[$0] }
                if !messages.isEmpty {
                    state["message_enabled"] = messages.count { $0.enabled }
                    state["message_background"] = messages.count { $0.background != nil }
                    state["message_bound_background_textures"] = messages.reduce(0) { $0 + $1.backgroundBoundImages.count }
                    state["message_committed_operations"] = messages.reduce(0) { $0 + $1.committedOutput.count }
                    state["message_pending_operations"] = messages.reduce(0) { $0 + $1.pendingOutput.count }
                    state["message_primary_text_writable"] = messages.count { $0.primaryTextWriteCandidate() != nil }
                    state["message_text_bounds"] = messages.count { $0.textBounds != nil }
                    state["message_text_margins"] = messages.count { $0.textMargins != nil }
                    state["message_placement_set"] = messages.count { $0.placement != nil }
                    state["message_transform_set"] = messages.count { $0.transform != nil }
                    state["message_alignment_set"] = messages.count { $0.alignment != nil }
                    state["message_volume_type_set"] = messages.count { $0.volumeType != nil }
                    state["message_input_mask_set"] = messages.count { $0.inputMask != nil }
                    state["message_output_mask_set"] = messages.count { $0.outputMask != nil }
                    state["message_draw_channel_set"] = messages.count { $0.drawChannel != nil }
                    state["message_background_extended"] = messages.count { $0.backgroundHasExtendedContainerMetadata }
                    state["message_background_extended_defaults"] = messages.count { $0.backgroundExtendedDefaultsPrepared }
                    state["message_background_selected_member"] = messages.count { $0.backgroundSelectedMember != nil }
                    state["message_background_motion_start"] = messages.count { $0.backgroundMotionStartTick != nil }
                    state["message_background_layer_flags"] = messages.count { $0.backgroundLayerAuxiliaryFlags?.count == 256 }
                    state["message_background_clock_snapshot_current"] = messages.count {
                        $0.backgroundSavedLayerTimeSnapshot?.visualTick == storage.visualTicks
                    }
                    state["message_background_clock_snapshot_stale"] = messages.count {
                        $0.backgroundSavedLayerTimeSnapshot != nil &&
                            $0.backgroundSavedLayerTimeSnapshot?.visualTick != storage.visualTicks
                    }
                    state["message_generator_filters"] = messages.reduce(0) { $0 + $1.generatorFilterRequests.count }
                    state["message_generator_filters_nonempty"] = messages.reduce(0) {
                        $0 + $1.generatorFilterRequests.count(where: { !$0.isEmpty })
                    }
                    for (source, values) in Dictionary(grouping: messages.filter { $0.background != nil }, by: {
                        String(($0.background?.sourceSHA256 ?? "unbound").prefix(12))
                    }) {
                        state["message_background_source_\(source)_objects"] = values.count
                        state["message_background_source_\(source)_extended"] = values.count { $0.backgroundHasExtendedContainerMetadata }
                        state["message_background_source_\(source)_full_location"] = values.count {
                            guard let background = $0.background else { return false }
                            return background.byteOffset == 0 && background.sourceSHA256 == background.rangeSHA256
                        }
                        state["message_background_source_\(source)_recipe_motion_names"] = values.count { message in
                            guard let background = message.background else { return false }
                            return imageMotionNames?(background)?.isEmpty == false
                        }
                        state["message_background_source_\(source)_selected"] = values.count { $0.backgroundSelectedMember != nil }
                        state["message_background_source_\(source)_has_flags"] = values.count {
                            $0.backgroundLayerAuxiliaryFlags?.count == 256
                        }
                        state["message_background_source_\(source)_has_current_clock"] = values.count {
                            $0.backgroundSavedLayerTimeSnapshot?.visualTick == storage.visualTicks
                        }
                        for member in Set(values.compactMap(\.backgroundSelectedMember)) {
                            state["message_background_source_\(source)_member_\(member)"] = values.count {
                                $0.backgroundSelectedMember == member
                            }
                            state["message_background_source_\(source)_member_\(member)_recipe_flags"] = values.count { message in
                                guard let background = message.background else { return false }
                                return imageLayerFlags?(background, member)?.count == 256
                            }
                        }
                    }
                }
                let stateText = state.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: ",")
                return "\(name):\(kind)x\(elements.count){\(stateText)}"
            }.joined(separator: ";")
            throw ResourceError.rejected(
                "save_globals_template_missing_bindings: count=\(missingObjects.count) \(detail) missing=\(missingBindingDetails) visual_payload_issues=\(payloadIssueDetail)")
        }
        return try SaveVariableArrays.encodeCalValValues(template: template, storage: storage,
                                                         newBindingKeys: newBindingKeys,
                                                         objectPayloads: encodedObjectPayloads)
    }

    package func encodeTimedWaitSystemFields(template: Data) throws -> Data {
        guard liveSaveWait != nil else {
            throw ResourceError.rejected("save_system_fields_live_wait_outside_profile")
        }
        let updated = try SaveEngineState.replacingSystemFields(in: template, at: 0, names: storage.systemNameSlots,
            releaseArgument: storage.systemReleaseArgument,
            formCloseSaveFilename: storage.formCloseSaveFilename,
            lockMask: storage.systemLockMask, customLockMask: storage.systemCustomLockMask)
        let checkpoints = (primarySaveRequest?.memoryOptions ?? 0) & 1 == 0 ? storage.serializedMemoryCheckpoints : []
        return try SaveEngineState(state: updated, at: 0).replacingMemoryCheckpoints(in: updated, with: checkpoints)
    }

    /// The native slot writer stores seven live system name slots followed by
    /// one empty metadata field. `\n2` writes these slots from system tasks.
    package var nativeSaveMetadata: [String] { storage.systemNameSlots + [""] }

    package static func streamSaveChannelIndex(_ playbackHandle: UInt64) -> Int32? {
        ScriptStorage.streamChannelIndex(playbackHandle)
    }

    package static var streamSaveChannelCount: Int {
        Int(ScriptStorage.streamChannelCount)
    }

    package func encodeTimedWaitStreams(template: Data, positions: [Int32: Int32],
                                        streamPans: [Int32: SavedStreamPanSample] = [:],
                                        streamVolumes: [Int32: SavedDelayedVolumeSample] = [:],
                                        streamRepeats: [Int32: SavedFiniteRepeatSample] = [:],
                                        channelCount: Int? = nil) throws -> Data {
        guard liveSaveWait != nil, let catalog = repository?.catalog else {
            throw ResourceError.rejected("save_streams_live_wait_outside_profile")
        }
        let reader = try SaveReaderCursor(threadState: template)
        let prefix = try SaveStatePrefix(state: template, after: reader)
        return try prefix.replacingLiveStreams(in: template, storage: storage, catalog: catalog,
                                               positions: positions, streamPans: streamPans, streamVolumes: streamVolumes,
                                               streamRepeats: streamRepeats,
                                               channelCount: channelCount)
    }

    /// Build an experimental slot in memory from a validated timed-wait snapshot.
    package func encodeTimedWaitResearchSlot(template: Data, positions: [Int32: Int32],
                                             streamPans: [Int32: SavedStreamPanSample] = [:],
                                             streamVolumes: [Int32: SavedDelayedVolumeSample] = [:],
                                             streamRepeats: [Int32: SavedFiniteRepeatSample] = [:],
                                             displaySurfaces: [Int: Data] = [:],
                                             metadata: [String], thumbnail: Data, savedDays: Double,
                                             seed: UInt32? = nil, headerVerification: Data? = nil,
                                             packedCodec: UInt32? = nil, clearHeaderTemplate: Data? = nil,
                                             headerSeed: UInt32? = nil,
                                             channelCount: Int? = nil) throws -> Data {
        let state = try assembleTimedWaitResearchState(template: template, positions: positions, streamPans: streamPans,
                                                      streamVolumes: streamVolumes, streamRepeats: streamRepeats,
                                                      displaySurfaces: displaySurfaces,
                                                      channelCount: channelCount)
        return try SaveEnvelope.encodeSlot(state: state, metadata: metadata, thumbnail: thumbnail,
                                           savedDays: savedDays, seed: seed, headerVerification: headerVerification,
                                           packedCodec: packedCodec, clearHeaderTemplate: clearHeaderTemplate,
                                           headerSeed: headerSeed)
    }

    private mutating func prepareTimedWaitSlotCandidate(_ name: String, metadata: [String],
                                                        streamPositions: [Int32: Int32],
                                                        streamPans: [Int32: SavedStreamPanSample],
                                                        streamVolumes: [Int32: SavedDelayedVolumeSample],
                                                        streamRepeats: [Int32: SavedFiniteRepeatSample],
                                                        displaySurfaces: [Int: Data],
                                                        thumbnail suppliedThumbnail: Data?)
        throws -> (data: Data, seed: UInt32, expectedDestination: SafeDirectory.AtomicDestinationExpectation) {
        guard liveSaveWait != nil else {
            let previous = program.document.records.indices.contains(pc - 1)
                ? program.document.records[pc - 1] : nil
            let stopTargetMatches: Bool
            if let previous, previous.command.map(asciiLower) == "stop",
               previous.fields.count == 1, previous.fields[0].key == nil,
               previous.fields[0].raw.hasPrefix("@@"), let stopCallback {
                stopTargetMatches = (try? program.label(previous.fields[0].raw)) == stopCallback
            } else {
                stopTargetMatches = false
            }
            throw ResourceError.rejected(
                "save_write_live_wait_unsupported:phase=\(phase.rawValue):resume_phase=\(systemTaskResumeState?.phase.rawValue ?? "none"):entry=\(systemTaskEntryLabel ?? "none"):previous_command=\(previous?.command ?? "none"):stop_callback=\(stopCallback == nil ? 0 : 1):stop_callback_frame=\(stopCallbackFrameDepth.map(String.init) ?? "none"):stop_target_match=\(stopTargetMatches ? 1 : 0):frames=\(storage.frames.count)")
        }
        guard let directory = saveDirectory else { throw ResourceError.rejected("save_write_directory_unavailable") }
        if let saveImageFilterValidator {
            _ = try storage.validateSavedImageFilters(saveImageFilterValidator,
                                                        videoProfiles: researchVideoSaveProfiles)
        } else if storage.images.values.contains(where: { !$0.filterOverrides.isEmpty }) {
            throw ResourceError.rejected("save_image_filter_rendering_unverified")
        }
        guard metadata.count == 8, metadata[7].isEmpty else {
            throw ResourceError.rejected("save_write_metadata_outside_profile")
        }
        guard let clearHeaderTemplate = saveHeaderTemplate else {
            throw ResourceError.rejected("save_write_header_template_unavailable")
        }
        let entry = try directory.entries().first { $0.name == name }
        let stateTemplate: Data
        let thumbnail: Data
        let expectedDestination: SafeDirectory.AtomicDestinationExpectation
        let indexedSource = saveSources[Data(asciiLower(name).utf8)]
        if let entry {
            guard case .regular = entry.kind else {
                throw ResourceError.rejected("save_slot_target_not_regular")
            }
            let existing = try directory.read(name, limit: SaveEnvelope.maxFileBytes)
            let envelope = try SaveEnvelope(existing)
            guard let slot = envelope.slot else {
                throw ResourceError.rejected("save_slot_required")
            }
            guard let indexedSource, indexedSource.name == name,
                  indexedSource.sha256 == existing.sha256Hex else {
                throw ResourceError.rejected("save_slot_changed_since_inventory")
            }
            expectedDestination = .sha256(indexedSource.sha256)
            let existingSeed = indexedSource.verifyHeader
                ? try SaveEnvelope.validatedSlotSeed(existing, clearTemplate: clearHeaderTemplate)
                : nil
            stateTemplate = try SaveEnvelope.decodeSlotState(existing, seed: existingSeed)
            let thumbStart = slot.thumbnail.offset
            thumbnail = suppliedThumbnail ?? Data(existing[thumbStart..<(thumbStart + slot.thumbnail.length)])
        } else {
            guard indexedSource == nil, try !storage.containsSessionSave(name) else {
                throw ResourceError.rejected("save_slot_changed_since_inventory")
            }
            expectedDestination = .absent
            let thread = try encodeTimedWaitThread(readerOpaqueFields: Data(repeating: 0, count: 64),
                                                   allowsIndexedLocals: true)
            stateTemplate = try TimedWaitSaveTemplate.emptyState(thread: thread)
            thumbnail = suppliedThumbnail ?? Data()
        }
        guard thumbnail.count <= 1024 * 1024,
              thumbnail.isEmpty || InventoryScanner.signature(thumbnail) == "JPEG" else {
            throw ResourceError.rejected("save_thumbnail_requires_bounded_jpeg")
        }
        storage.systemNameSlots = Array(metadata.prefix(7))

        let timing = try Self.currentSaveTiming()
        let seed = timing.seed
        let data = try encodeTimedWaitResearchSlot(template: stateTemplate,
            positions: streamPositions, streamPans: streamPans, streamVolumes: streamVolumes,
            streamRepeats: streamRepeats,
            displaySurfaces: displaySurfaces,
            metadata: metadata, thumbnail: thumbnail, savedDays: timing.days,
            seed: seed, packedCodec: 1, clearHeaderTemplate: clearHeaderTemplate,
            headerSeed: seed, channelCount: Self.streamSaveChannelCount)
        try SaveEnvelope.verifySlotHeader(data, clearTemplate: clearHeaderTemplate, seed: seed)
        _ = try SaveEnvelope.decodeSlotState(data, seed: seed)
        return (data, seed, expectedDestination)
    }

    private static func currentSaveTiming() throws -> (days: Double, seed: UInt32) {
        let now = Date()
        let localSeconds = now.timeIntervalSince1970 + Double(TimeZone.current.secondsFromGMT(for: now))
        guard localSeconds.isFinite, localSeconds >= 0 else {
            throw ResourceError.rejected("save_local_time_outside_profile")
        }
        return (localSeconds / 86_400 + 25_569, UInt32(truncatingIfNeeded: Int64((localSeconds * 1000).rounded())))
    }

    /// Research-only assembly against a parsed donor. Host captures can
    /// replace embedded surfaces. Other image state remains template data.
    package func assembleTimedWaitResearchState(template: Data, positions: [Int32: Int32],
                                                streamPans: [Int32: SavedStreamPanSample] = [:],
                                                streamVolumes: [Int32: SavedDelayedVolumeSample] = [:],
                                                streamRepeats: [Int32: SavedFiniteRepeatSample] = [:],
                                                displaySurfaces: [Int: Data] = [:],
                                                channelCount: Int? = nil) throws -> Data {
        guard template.count <= SaveEnvelope.maxFileBytes else {
            throw ResourceError.rejected("save_research_template_size_limit")
        }
        let originalReader = try SaveReaderCursor(threadState: template)
        let originalPrefix = try SaveStatePrefix(state: template, after: originalReader)
        let opaqueStart = originalReader.decodedOffset + 13
        let opaqueFields = Data(template[(template.startIndex + opaqueStart)..<(template.startIndex + opaqueStart + 64)])
        let thread = try encodeTimedWaitThread(readerOpaqueFields: opaqueFields, allowsIndexedLocals: true)
        try validateTimedWaitReturnCursors(thread)
        let logEntries = storage.dialogueLogEntries.map {
            SaveStatePrefix.DialogueLogEntry(speaker: $0.speaker, text: $0.text, voice: $0.voice,
                                             extra: $0.extra, integerFields: $0.integerFields)
        }
        let logUpdated = try originalPrefix.replacingDialogueLog(in: template, entries: logEntries)
        let logUpdatedPrefix = try SaveStatePrefix(state: logUpdated, after: originalReader)
        if channelCount == nil { try SaveStatePrefix.validateNoLiveDirectSounds(storage) }
        // Check the live call-frame variable representation before audio: an
        // audio mismatch must not hide an independently unsupported frame.
        let originalCalVal = try logUpdatedPrefix.locateCalVal(in: logUpdated)
        let originalGlobalEnd = try SaveVariableArrays.readCalVal(state: logUpdated, at: originalCalVal).nextDecodedOffset
        _ = try SaveVariableArrays.encodeIndexedLocals(in: logUpdated, at: originalGlobalEnd,
            frames: storage.frames, liveStorage: storage)
        let globalTemplate = Data(logUpdated[(logUpdated.startIndex + originalCalVal)..<(logUpdated.startIndex + originalGlobalEnd)])
        _ = try encodeTimedWaitGlobals(template: globalTemplate)
        let directUpdated: Data
        if channelCount != nil {
            guard let repository else { throw ResourceError.rejected("saved_direct_write_catalog_required") }
            directUpdated = try logUpdatedPrefix.replacingLiveDirectBank(in: logUpdated, storage: storage,
                                                                         catalog: repository.catalog)
        } else {
            directUpdated = logUpdated
        }
        let audio = try encodeTimedWaitStreams(template: directUpdated, positions: positions, streamPans: streamPans,
                                               streamVolumes: streamVolumes, streamRepeats: streamRepeats,
                                               channelCount: channelCount)
        let audioReader = try SaveReaderCursor(threadState: audio)
        guard audioReader.nextDecodedOffset == originalReader.nextDecodedOffset else {
            throw ResourceError.rejected("save_audio_thread_boundary_changed")
        }
        let audioPrefix = try SaveStatePrefix(state: audio, after: audioReader)
        var updated = channelCount == nil ? audioPrefix.bypassingDonorDirectReloads(in: audio) : audio
        for (index, payload) in displaySurfaces.sorted(by: { $0.key < $1.key }) {
            updated = try audioPrefix.replacingDisplaySurface(in: updated, index: index, payload: payload)
        }
        let calVal = try audioPrefix.locateCalVal(in: updated)
        let globalEnd = try SaveVariableArrays.readCalVal(state: updated, at: calVal).nextDecodedOffset
        let indexed = try SaveVariableArrays.encodeIndexedLocals(in: updated, at: globalEnd,
            frames: storage.frames, liveStorage: storage)
        func span(_ start: Int, _ end: Int) -> Data {
            Data(updated[(updated.startIndex + start)..<(updated.startIndex + end)])
        }
        let globals = try encodeTimedWaitGlobals(template: span(calVal, globalEnd)) + indexed.bytes
        let tail = try encodeTimedWaitSystemFields(template: span(indexed.end, updated.count))
        let middle = span(originalReader.nextDecodedOffset, calVal)
        guard thread.count + middle.count + globals.count + tail.count <= SaveEnvelope.maxFileBytes else {
            throw ResourceError.rejected("save_research_state_size_limit")
        }
        let state = thread + middle + globals + tail
        let reader = try SaveReaderCursor(threadState: state)
        let prefix = try SaveStatePrefix(state: state, after: reader)
        let rebuiltCalVal = try prefix.locateCalVal(in: state)
        let rebuiltArrays = try SaveVariableArrays.inspectCalVal(state: state, at: rebuiltCalVal)
        let rebuiltEngine = rebuiltArrays.indexed.nextDecodedOffset ?? rebuiltArrays.nextDecodedOffset
        guard reader.nextDecodedOffset == thread.count, rebuiltCalVal == thread.count + middle.count,
              rebuiltEngine == rebuiltCalVal + globals.count,
              try SaveEngineState(state: state, at: rebuiltEngine).status == .verified else {
            throw ResourceError.rejected("save_research_state_section_boundary")
        }
        return state
    }

    package mutating func beginCallDepthProbe() {
        callDepthProbeMinimum = storage.frames.count
    }

    package mutating func takeStreamChannelTransitions() -> ([StreamChannelTransition], Int) {
        let result = (streamChannelTransitions, streamChannelTransitionsOmitted)
        streamChannelTransitions.removeAll(keepingCapacity: true)
        streamChannelTransitionsOmitted = 0
        return result
    }

    public var playbackStatus: (phase: ScriptMachinePhase, steps: Int, stopReason: String?, currentLocation: ScriptLocation?, callDepth: Int, callDepthMinimum: Int) {
        let records = program.document.records
        return (phase, executedSteps, stopReason, pc < records.count ? records[pc].location : nil,
                storage.frames.count, callDepthProbeMinimum ?? storage.frames.count)
    }

    package var labelHistoryProbe: LabelHistoryProbe {
        var contexts: [(Int, ScriptProgram, Int)] = [(storage.frames.count - 1, program, pc)]
        if storage.frames.count > 1 {
            for index in stride(from: storage.frames.count - 1, through: 1, by: -1) {
                let child = storage.frames[index]
                if let caller = child.returnProgram, let next = child.returnIndex, next > 0 {
                    contexts.append((index - 1, caller, next - 1))
                }
            }
        }
        let frames: [LabelHistoryProbe.Frame] = contexts.compactMap { depth, script, position in
            let records = script.document.records
            guard records.indices.contains(position) else { return nil }
            let location = records[position].location
            let anchor = script.labelProgressAnchors[position]
            let anchorLocation = anchor.map { records[$0].location }
            let label = anchor.flatMap { records[$0].identifier }
            let eligible = label.map { !$0.isEmpty && !$0.hasPrefix("!") } ?? false
            let readerEligible = label.map { !$0.isEmpty } ?? false
            let unique = label.flatMap { try? script.label("@@" + $0) } == anchor && anchor != nil
            let reference = anchorLocation.flatMap { repository?.catalog.reference(forPhysical: $0.sourceFile) }
            let path = reference.flatMap { ref -> String? in
                guard let anchorLocation, ref.sourceSHA256 == anchorLocation.sourceSHA256,
                      let resolved = try? repository?.catalog.resolve(ref.logicalPath),
                      resolved.sourceFile == anchorLocation.sourceFile, resolved.sourceSHA256 == anchorLocation.sourceSHA256 else { return nil }
                return ref.logicalPath
            }
            var withMarker: Bool?, withoutMarker: Bool?
            var candidateStatus: Int32?
            var storedLine: Int32?
            let relative = anchor.flatMap { script.candidateLabelRelativeLine(anchor: $0, position: position) }
            if readerEligible, let label, let path {
                let base = asciiLower(path.replacingOccurrences(of: "/", with: "\\"))
                let value = storage.lineLogValues[Data(asciiLower(base + "@@" + label).utf8)]
                storedLine = value
                withMarker = value != nil
                withoutMarker = storage.lineLogValues[Data(asciiLower(base + label).utf8)] != nil
                if let relative, relative >= 0, let line = Int32(exactly: relative) {
                    candidateStatus = (value ?? -1) > line ? 1 : 0
                }
            }
            return LabelHistoryProbe.Frame(depth: depth,
                programSource: script.document.source.location(0..<0, line: 1), position: location,
                nearestLabel: anchor.map { records[$0].location }, eligibleLabel: eligible,
                readerEligibleLabel: readerEligible, uniqueLabel: unique,
                logicalPathAvailable: path != nil, keyMatchWithMarker: withMarker,
                keyMatchWithoutMarker: withoutMarker, candidateReadStatus: candidateStatus,
                candidateStoredLine: storedLine, relativeLine: relative)
        }
        return LabelHistoryProbe(frames: frames)
    }

    package var labelHistoryStorageShape: [String: Int] {
        ["storedKeys": storage.lineLogValues.count,
         "storedKeysWithDoubleAt": storage.lineLogValues.keys.reduce(0) { count, key in
             count + (key.range(of: Data("@@".utf8)) == nil ? 0 : 1)
         },
         "importedHistory": storage.importedLabelHistory ? 1 : 0,
         "automaticProgressCandidateEnabled": allowLabelProgressCandidate ? 1 : 0]
    }

    public var summary: ScriptMachineSummary {
        let records = program.document.records
        return ScriptMachineSummary(status: phase == .stopped ? .unsupported : .inferred,phase: phase,
            steps: executedSteps,currentLocation: pc < records.count ? records[pc].location : nil,
            stopReason: stopReason,saveWriteIssue: lastSaveWriteIssue,
            displayConfigurationHostStatus: storage.configDisplayNeedsHostUpdate ? .unsupported : .notTested,
            displayRefreshRequested: storage.configDisplayRefreshRequested,
            callDepth: storage.frames.count,
            variableCounts: ["system":storage.system.count,"global":storage.global.count,
                "all_local_frames":storage.frames.reduce(0) { $0+$1.locals.count }],
            moduleSnapshotCount: repository?.loadedModuleCount ?? 0,moduleSnapshotBytes: repository?.snapshotBytes ?? 0,
            sourceSnapshotCount: repository?.sourceSnapshotCount ?? 0,tableObjectCount: storage.tables.count,
            tableEntryCount: storage.tables.values.reduce(0) { $0+$1.count },
            tableSnapshots: storage.tables.keys.sorted().compactMap { storage.tables[$0]?.summary },
            listObjectCount: storage.lists.count,listLineCount: storage.lists.values.reduce(0) { $0+($1.summary?.lineCount ?? 0) },
            listSnapshots: storage.lists.keys.sorted().compactMap { storage.lists[$0]?.summary },trace: traces,
            sourceVisits: captureSourceVisits ? sourceVisits.values.sorted { $0.firstStep < $1.firstStep } : nil,
            sourceVisitsTruncated: captureSourceVisits ? sourceVisitsTruncated : nil,
            sourceCoverage: coverageSourceFile.map { name in
                ScriptSourceCoverage(sourceFile: name,
                    entries: sourceCoverage.values.sorted { $0.firstStep < $1.firstStep },
                    truncated: sourceCoverageTruncated)
            })
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

    /// Mac-only safety extension: publish the last stable stop wait through
    /// the ordinary slot writer. This deliberately does not model the original
    /// engine's debug-refresh callback.
    package mutating func beginMacExceptionBackup(fromSafeWait failure: ScriptStepFailure) throws -> Bool {
        guard phase == .waitingForEvent, stopCallback != nil, stopCallbackFrameDepth == nil,
              !macExceptionBackupAttempted, macExceptionBackupContinuation == nil,
              allowPrimarySave, saveDirectory != nil, saveHeaderTemplate != nil,
              systemDataSaveTarget != nil, primarySaveRequest == nil, var pinned = repository,
              let safeWait = liveSaveWait else { return false }
        let thread = try encodeTimedWaitThread(readerOpaqueFields: Data(repeating: 0, count: 64),
                                               allowsIndexedLocals: true)
        try validateTimedWaitReturnCursors(thread)
        let cursor = try SaveReaderCursor(threadState: thread)
        let active = try cursor.resolveResumeInstruction(in: thread, repository: &pinned)
        let activePosition = try Self.mapSavedPosition((active.program, active.index, active.location), to: program)
        var metadata = Array(storage.systemNameSlots.prefix(7))
        if metadata.count < 7 { metadata.append(contentsOf: repeatElement("", count: 7 - metadata.count)) }
        let priority = storage.thumbnailPriorities?.0 ?? 0
        repository = pinned
        macExceptionBackupLiveWaitOverride = safeWait
        primarySaveRequest = .init(priority: priority, name: "ExceptionBackup.svd",
                                   macSafetyBackupWithoutThumbnail: true, metadata: metadata + [""],
                                   resumeIndex: activePosition.index)
        phase = .waitingForPrimarySave
        stopReason = nil
        macExceptionBackupAttempted = true
        macExceptionBackupContinuation = MacExceptionBackupContinuation(
            programSourceFile: program.document.source.relativePath,
            programSourceSHA256: program.document.source.sha256, returnIndex: pc,
            returnFrameDepth: storage.frames.count, failureReason: failure.reason)
        return true
    }

    /// Private-player verification hook. The next actual step throws a
    /// controlled error inside the ordinary atomic instruction boundary.
    package mutating func injectMacExceptionBackupFailureForTesting(reason: String) throws {
        guard phase == .waitingForEvent, scriptStepFailure == nil,
              macExceptionBackupContinuation == nil, pc < program.document.records.count else {
            throw ResourceError.rejected("mac_exception_backup_test_injection_outside_wait")
        }
        guard let target = program.document.records.indices.dropFirst(pc).first(where: { index in
            let kind = program.document.records[index].kind
            return kind == .command || kind == .lineTag
        }) else {
            throw ResourceError.rejected("mac_exception_backup_test_instruction_unavailable")
        }
        macExceptionBackupTestFailure = (program.document.source.sha256, target, reason)
        phase = .ready
    }

    @discardableResult public mutating func step() -> ScriptTrace? {
        if phase == .ready, let continuation = macExceptionBackupContinuation,
           pc == continuation.returnIndex, storage.frames.count == continuation.returnFrameDepth,
           program.document.source.relativePath == continuation.programSourceFile,
           program.document.source.sha256 == continuation.programSourceSHA256 {
            phase = .stopped
            stopReason = continuation.saveCommitted
                ? "mac_exception_backup_written: \(continuation.failureReason)"
                : "mac_exception_backup_failed: \(continuation.saveIssue ?? "exception-save-script-returned-without-commit")"
            return nil
        }
        guard phase == .ready else { return nil }
        let records = program.document.records
        guard pc < records.count else {
            if storage.frames.count > 1 { phase = .stopped; stopReason = "callee_reached_EOF_without_return" }
            else { phase = .finished }
            return nil
        }
        let record = records[pc], oldPC = pc
        let raw = record.command
        let traceCommand = raw.flatMap { program.traceCommands[Data($0.utf8)] }
        let safeCommand = traceCommand?.safe
        func trace(_ status: EvidenceStatus, _ action: String, reason: String? = nil,
                   target: ScriptLocation? = nil, skipped: ScriptSkippedSpan? = nil, resultType: String? = nil,
                   resource: ScriptLocation? = nil) -> ScriptTrace {
            ScriptTrace(sequence: executedSteps+1,location: record.location,recordType: record.kind,command: safeCommand,
                commandSHA256: traceCommand?.sha256,status: status,action: action,reason: reason,
                target: target,callDepth: storage.frames.count,skipped: skipped,resultType: resultType,resource: resource)
        }
        guard executedSteps < maximumSteps else { stopReason = "machine_total_step_limit"; phase = .stopped; return nil }
        // These records only advance the reader when the progress candidate
        // cannot observe a completed source line. Keep the regular path for
        // every record which could update that candidate.
        let following = pc + 1 < records.count ? records[pc + 1] : nil
        let progressCannotChange = !allowLabelProgressCandidate ||
            [.bom, .include, .label].contains(record.kind) || following == nil ||
            following?.location.sourceFile != record.location.sourceFile ||
            following?.location.sourceSHA256 != record.location.sourceSHA256 ||
            (following?.location.lineNumber ?? 0) <= record.location.lineNumber
        if progressCannotChange {
            let action: String?
            switch record.kind {
            case .bom, .layout, .label, .comment: action = "advance"
            case .include where program.includesExpanded: action = "include_expansion_marker"
            case .empty where storage.noWordLineText?.isEmpty ?? true: action = "advance"
            default: action = nil
            }
            if let action {
                let item = trace(.inferred, action)
                pc += 1
                pendingModuleCandidates = []
                recordTrace(item)
                return item
            }
        }
        let activeStreamsBefore = Set(storage.soundChannels.compactMap { handle, channel -> Int32? in
            guard channel.playing else { return nil }
            return ScriptStorage.streamChannelIndex(handle)
        })
        var candidate = storage, nextProgram = program, next = pc+1, target: ScriptLocation?, skip: ScriptSkippedSpan?, result: ScriptValue?
        var candidateRepository = repository, resourceLocation: ScriptLocation?
        var labelProgressReturnedLine: (program: ScriptProgram, index: Int)?
        var imageFileLogOutcome: ScriptStorage.ImageFileLogOutcome?
        var audioFileLogOutcome: ScriptStorage.ImageFileLogOutcome?
        var swappedStreamHandles: [UInt64]?
        var labelHistoryReadOutcome: Int32?
        var unreadLabelProbe: LabelHistoryProbe?
        var imageFileLogSnapshot: FileLogPatternSnapshot?
        var pendingSaveWrite: (name: String, metadata: [String])?
        var pendingSaveDeletion: String?
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
            if let injected = macExceptionBackupTestFailure,
               injected.programCounter == oldPC,
               injected.programSourceSHA256 == program.document.source.sha256 {
                macExceptionBackupTestFailure = nil
                throw ResourceError.rejected(injected.reason)
            }
            switch record.kind {
            case .bom, .layout, .label, .comment: break
            case .include:
                guard program.includesExpanded else { throw ResourceError.rejected("include_preprocessing_required") }
                action = "include_expansion_marker"
            case .empty:
                guard let prefix = candidate.noWordLineText, !prefix.isEmpty else { break }
                // 0x6963fa applies the empty-line prefix after preprocessing;
                // the preceding record is not used as a condition. The reader
                // excludes labels marked internal before that path.
                if let anchor = program.labelProgressAnchors[pc],
                   records[anchor].identifier?.hasPrefix("!") == true { break }
                let fields = prefix.split(separator: ",", omittingEmptySubsequences: false)
                guard fields.count == 2, fields[0] == "\\subp" else {
                    throw ResourceError.rejected("blank_line_prefix_outside_profile")
                }
                let label = String(fields[1])
                // Unknown recursive prefix behavior must not be silently skipped.
                let labelKey = Data(asciiLower(label).utf8)
                guard !candidate.frames.contains(where: {
                    $0.entryLabel.map { Data(asciiLower($0).utf8) == labelKey } ?? false
                }) else {
                    throw ResourceError.rejected("blank_line_prefix_recursive_unsupported")
                }
                let destination = try program.label(label)
                guard program.ancestors[destination].isEmpty, candidate.frames.count < maximumFrames else {
                    throw ResourceError.rejected("blank_line_prefix_call_boundary")
                }
                candidate.frames.append(ScriptFrame(returnIndex: pc+1, returnProgram: program, entryLabel: label,
                    completedLineReturnCandidate: true))
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
                    stringParameters: [text] + Array(repeating: "", count: 15), completedLineReturnCandidate: true))
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
                    ((fields.count == 3 && (fields[2].isEmpty || asciiLower(String(fields[2])) == "self")) || record.fields.isEmpty)) else {
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
                    parameterCount: Int32(arguments.count), integerParameters: integers, stringParameters: strings,
                    completedLineReturnCandidate: true))
                next = destination
                action = "line_tag_replacement_call_candidate"
            case .command:
                guard let raw, safeCommand != nil else { throw ResourceError.rejected("invalid_command_identifier") }
                let command = asciiLower(raw)
                if candidate.selectsPrimaryScriptSource, candidate.linkedPrimaryPlayMode != nil {
                    // 0x6cb45c returns the current instance when its +0xc8 parent is nil;
                    // a standalone machine therefore has no cross-instance routing here.
                    let selectsSystem = command == "scp" && record.fields.count == 1 &&
                        asciiLower(record.fields[0].raw) == "sys"
                    let usesSystem = (command == "p" || command == "?p" || command == "n2" || command == "?fcs") &&
                        candidate.frames.last?.tableScope == [ScriptStorage.systemHandle]
                    let selectsSaveData = command == "scp" && record.fields.count == 1 &&
                        asciiLower(record.fields[0].raw) == "dat"
                    let usesSaveData = (command == "l" || command == "s") &&
                        candidate.frames.last?.tableScope == [ScriptStorage.saveDataHandle]
                    let usesLinkedLog = linkedLogJumpCheckpoints != nil &&
                        ((command == "scp" && record.fields.count == 1 && asciiLower(record.fields[0].raw) == "tdat") ||
                         (command == "l" && candidate.frames.last?.tableScope == [ScriptStorage.temporaryDataHandle]))
                    let queriesRestoredVariable = command == "vexs" && isLinkedLogTask &&
                        pendingMemoryCheckpointRestore == .temporary && savedExecutionCandidate != nil
                    guard command == "srct" || selectsSystem || usesSystem || selectsSaveData || usesSaveData ||
                          usesLinkedLog || queriesRestoredVariable else {
                        throw ResourceError.rejected("script_source_target_outside_profile")
                    }
                }
                switch command {
                case "tsub":
                    try arity(1)
                    let label = try field(0)
                    guard isLinkedLogTask, pendingMemoryCheckpointRestore == .temporary,
                          let staged = savedExecutionCandidate,
                          label.hasPrefix("@@"), !label.hasPrefix("@@@"), label.count > 2 else {
                        throw ResourceError.rejected("linked_log_load_callback_outside_profile")
                    }
                    candidate.clearResultBindings()
                    let matches = staged.program.labels[Data(asciiLower(String(label.dropFirst(2))).utf8)] ?? []
                    if matches.isEmpty {
                        try candidate.resultInteger(0)
                        action = "linked_log_load_callback_absent"
                    } else {
                        let destination = try staged.program.label(label)
                        let updated = try runRestoredSubroutine(at: destination, label: label, staged: staged,
                                                                failurePrefix: "linked_log_load_callback")
                        try candidate.resultInteger(1)
                        savedExecutionCandidate = updated
                        target = staged.program.document.records[destination].location
                        action = "linked_log_load_callback_returned"
                    }
                case "srct":
                    try arity(1)
                    let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                        write: { _,_ in throw ResourceError.rejected("mutating_script_source_selector") },
                        readIndexed: { try candidate.readIndexed($0,$1) })
                    guard let selector = value.integer, selector == 0 || selector == 1 else {
                        throw ResourceError.rejected("script_source_selector_outside_profile")
                    }
                    // 0x6b076a writes the per-instance source selector.
                    candidate.selectsPrimaryScriptSource = selector == 1
                    action = "script_source_selector_candidate"
                case "exop":
                    try arity(1)
                    let text = try callLabel()
                    let document = try ScriptDocument(data: Data([0xff, 0xfe]) + Data(text.utf16.flatMap {
                        [UInt8(truncatingIfNeeded: $0), UInt8($0 >> 8)]
                    }), relativePath: record.location.sourceFile)
                    let commands = document.records.filter { $0.kind != .bom && $0.kind != .layout }
                    guard commands.count == 1, let operation = commands.first, operation.kind == .command,
                          let opcode = operation.command.map(asciiLower), ["sub", "subp", "cal"].contains(opcode),
                          (1...18).contains(operation.fields.count) else {
                        throw ResourceError.rejected("dynamic_operation_outside_profile")
                    }
                    if opcode == "cal" {
                        guard operation.fields.count == 1, operation.fields[0].key == nil else {
                            throw ResourceError.rejected("dynamic_calculate_operand_outside_profile")
                        }
                        let expression = try ScriptExpression.parse(operation.fields[0].raw)
                        result = try expression.evaluate(read: { try candidate.read($0) },
                            write: { try candidate.write($0,$1) },
                            readIndexed: { try candidate.readIndexed($0,$1) },
                            writeIndexed: { try candidate.writeIndexed($0,$1,$2) })
                        action = "dynamic_calculate_candidate"
                        break
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
                        let declaration = try ScriptExpression.parse(spelling), name: String, count: Int, isArray: Bool
                        switch declaration {
                        case .name(let raw): name = raw; count = 1; isArray = false
                        case .indexed(let raw, let coordinate):
                            guard ["int","str","btn","sbtn","table","list","img","simg","obj","msg"].contains(type) else { throw ResourceError.rejected("object_array_outside_profile") }
                            let value = try coordinate.evaluate(read: { try candidate.read($0) },write: { _,_ in
                                throw ResourceError.rejected("mutating_array_dimension_outside_profile")
                            },readIndexed: { try candidate.readIndexed($0,$1) })
                            guard let integer = value.integer else { throw ResourceError.rejected("array_dimension_requires_integer") }
                            name = raw; count = max(1,Int(integer)); isArray = true
                        default: throw ResourceError.rejected("non_scalar_declaration_name")
                        }
                        if try candidate.declare(name,category: command,type: type,count: count,explicitArray: isArray) { created += 1 }
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
                        guard case .object(let handle) = value, handle == ScriptStorage.configHandle || handle == ScriptStorage.saveDataHandle || handle == ScriptStorage.temporaryDataHandle || handle == ScriptStorage.memoryDataHandle || handle == ScriptStorage.systemKeyHandle || handle == ScriptStorage.fileLogHandle || handle == ScriptStorage.dialogHandle || handle == ScriptStorage.lineLogHandle || handle == ScriptStorage.dialogueLogHandle || handle == ScriptStorage.mathHandle || handle == ScriptStorage.miscHandle || handle == ScriptStorage.systemHandle || handle == ScriptStorage.effectHandle || ScriptStorage.isStreamHandle(handle) || ScriptStorage.isDirectSoundHandle(handle) || handle == ScriptStorage.inputHandle || handle == ScriptStorage.replacementHandle || handle == ScriptStorage.cameraHandle || candidate.tables[handle] != nil || candidate.lists[handle] != nil || candidate.images[handle] != nil || candidate.movies[handle] != nil || candidate.timers[handle] != nil || candidate.buttons.contains(handle) || candidate.messages[handle] != nil || candidate.bars[handle] != nil
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
                    let camera = handle == ScriptStorage.cameraHandle
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
                        // 0x5acb8c maps operands 3/4/5 to repeat count, duration,
                        // and the second 24-bit color channel respectively.
                        let add: Int32 = values.count == 5 ? values[4] : 0
                        if var image = candidate.images[handle] {
                            image.colorRequest = (values[0], values[1], values[2], values[3], add)
                            if values[3] >= 0 {
                                if values[1] != -1 { image.colorMultiply = min(0x00ff_ffff, max(0, values[1])) }
                                if add != -1 { image.colorAdd = min(0x00ff_ffff, max(0, add)) }
                                if values[2] > -2 { image.colorRepeatCount = values[2] }
                                image.colorTransitionActive = values[3] > 0
                            }
                            candidate.images[handle] = image
                        }
                        // 0x5acb64 clamps explicit alpha; 0x5acc5c copies the zero-duration endpoint.
                        if values[0] != -1, values[3] >= 0, var image = candidate.images[handle] {
                            let alpha = UInt8(clamping: values[0])
                            let origin = image.presentedOpacity
                            if values[3] == 0 || origin == alpha {
                                image.immediateOpacity = alpha
                                image.opacityEndpoint = nil
                            } else {
                                image.immediateOpacity = origin
                                image.opacityEndpoint = (alpha, values[3], values[3], values[2])
                            }
                            candidate.images[handle] = image
                        }
                        action = "image_color_request_candidate"
                    }
                case "pri":
                    let scope = candidate.frames.last!.tableScope
                    if scope.count == 1, let handle = scope.first, candidate.images[handle] != nil {
                        try arity(1)
                        let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_image_priority_operand") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard let priority = value.integer else {
                            throw ResourceError.rejected("image_priority_requires_integer")
                        }
                        // 0x6c65a9 writes the base object's +0x14 word. The objd writer saves that same word.
                        candidate.savedObjectBaseWords[handle] = priority
                        action = "image_base_priority_candidate"
                        break
                    }
                    try arity(2)
                    guard scope == [ScriptStorage.cameraHandle] else {
                        throw ResourceError.rejected("camera_priority_requires_camera_scope")
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
                case "?pri":
                    try arity(0)
                    guard candidate.frames.last!.tableScope.count == 1,
                          let handle = candidate.frames.last!.tableScope.first, candidate.images[handle] != nil else {
                        throw ResourceError.rejected("image_priority_query_requires_image_scope")
                    }
                    // 0x6c65c1 reads the base word independently of the position.
                    candidate.clearResultBindings()
                    try candidate.resultInteger(candidate.savedObjectBaseWords[handle] ?? 0)
                    action = "image_base_priority_query_candidate"
                case "anc", "?anc":
                    let scope = candidate.frames.last!.tableScope
                    guard scope.count == 1, let handle = scope.first,
                          candidate.images[handle] != nil || candidate.messages[handle] != nil ||
                            candidate.buttons.contains(handle) else {
                        throw ResourceError.rejected("visual_anchor_requires_drawable_scope")
                    }
                    if command == "?anc" {
                        try arity(0)
                        candidate.clearResultBindings()
                        try candidate.resultString(candidate.visualAnchorNames[handle] ?? "")
                        action = "visual_anchor_query_candidate"
                        break
                    }
                    try arity(1)
                    let name: String
                    let reference: String
                    switch try ScriptExpression.parse(field(0)) {
                    case .name(let raw):
                        name = raw
                        reference = raw
                    case .indexed(let raw, let coordinate):
                        let index = try coordinate.evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_visual_anchor_operand") },
                            readIndexed: { try candidate.readIndexed($0, $1) })
                        guard let integer = index.integer, integer >= 0 else {
                            throw ResourceError.rejected("visual_anchor_index_outside_profile")
                        }
                        name = raw
                        reference = "\(raw)[\(integer)]"
                    default:
                        throw ResourceError.rejected("visual_anchor_requires_named_image")
                    }
                    // 0x6c6992 stores the resolved object name, which the image writer can persist.
                    guard reference.utf16.count <= 4096, candidate.lookupCategory(name) == 2,
                          let anchor = candidate.visualAnchorTarget(reference) else {
                        throw ResourceError.rejected("visual_anchor_requires_named_image")
                    }
                    // The native image reset zeros placement and sets default scale (0x5ae22d–0x5ae292).
                    if candidate.images[anchor]?.resource == nil, candidate.images[anchor]?.placement == nil {
                        candidate.images[anchor]?.placement = [0, 0, 0]
                    }
                    candidate.visualAnchorNames[handle] = reference
                    action = "visual_anchor_set_candidate"
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
                    if candidate.unknownSavedButtonText.contains(handle) {
                        candidate.dirtySavedButtonText.insert(handle)
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
                    let shortBounds = command == "ts" && record.fields.count == 2
                    try arity(command == "ts" && !button && !shortBounds ? 4 : 2)
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
                        if candidate.unknownSavedButtonText.contains(handle) {
                            candidate.dirtySavedButtonText.insert(handle)
                        }
                        // The missing third slot at 0x6c9209 selects the
                        // zero-origin form with two far endpoints.
                        candidate.buttonTextBounds[handle] = [
                            min(0, values[0]), min(0, values[1]),
                            min(4096, max(0, values[0])), min(4096, max(0, values[1]))
                        ]
                        candidate.buttonText[handle] = .init()
                        action = "button_text_bounds_candidate"
                        break
                    }
                    var message = candidate.messages[handle]!
                    if command == "ts" {
                        // 0x67bc00 rejects reversed bounds. 0x67bc12–0x67bc39
                        // caps the span relative to the origin, not the endpoint.
                        // 0x6c9209 uses zero origins when the third operand is absent.
                        let endpoints = shortBounds ? [0, 0] + values : values
                        guard endpoints[2] >= endpoints[0], endpoints[3] >= endpoints[1] else {
                            action = "message_reversed_text_bounds_ignored_candidate"
                            break
                        }
                        let bounds = [endpoints[0], endpoints[1],
                                      Int32(min(Int64(endpoints[2]), Int64(endpoints[0]) + 4096)),
                                      Int32(min(Int64(endpoints[3]), Int64(endpoints[1]) + 4096))]
                        if bounds != message.textBounds {
                            message.clearOutput()
                        }
                        message.textBounds = bounds
                        action = "message_text_bounds_candidate"
                    } else {
                        // 0x67bccc writes both margins and forces the surface refresh.
                        message.textMargins = values
                        message.clearOutput()
                        action = "message_text_margins_candidate"
                    }
                    candidate.messages[handle] = message
                case "?l", "?fo":
                    try arity(0)
                    guard candidate.frames.last!.tableScope.count == 1,
                          let stream = candidate.frames.last!.tableScope.first,
                          ScriptStorage.isStreamHandle(stream) else {
                        throw ResourceError.rejected("sound_string_query_requires_stream_scope")
                    }
                    let channel = candidate.soundChannels[stream]
                    let unavailable = command == "?l" ? "sound_load_name_query_unavailable" : "sound_filter_query_unavailable"
                    guard channel != nil || !candidate.unknownStreamFieldsOnRestore else {
                        throw ResourceError.rejected(unavailable)
                    }
                    guard (command == "?l" ? channel?.requestedSourceNameKnown : channel?.filterRequestKnown) != false else {
                        throw ResourceError.rejected(unavailable)
                    }
                    guard command != "?l" || channel?.resource == nil || channel?.requestedSourceName != nil else {
                        throw ResourceError.rejected("sound_load_name_query_unavailable")
                    }
                    candidate.clearResultBindings()
                    try candidate.resultString(command == "?l" ? (channel?.requestedSourceName ?? "") : (channel?.filterRequest ?? ""))
                    action = command == "?l" ? "sound_load_name_query_candidate" : "sound_filter_query_candidate"
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
                case "?tda":
                    try arity(0)
                    let scope = candidate.frames.last!.tableScope
                    guard scope.count == 1, let handle = scope.first, let message = candidate.messages[handle] else {
                        throw ResourceError.rejected("message_draw_area_requires_message_scope")
                    }
                    // 0x6c94bd–0x6c950b returns the occupied rectangle, filled only by committed glyphs.
                    let bounds = message.drawnTextArea { Self.messageFontName($0, storage: candidate) }
                    candidate.clearResultBindings()
                    try candidate.setConfigResultArray(bounds.map(ScriptValue.integer), string: false)
                    action = "message_text_draw_area_candidate"
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
                    try arity(command == "ns" && record.fields.count != 1 ? 2 : 1)
                    let scope = candidate.frames.last!.tableScope
                    guard scope.count == 1, let handle = scope.first, var message = candidate.messages[handle] ?? candidate.buttonText[handle] else {
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
                        // 0x6c96ed copies the first value when slot two is absent.
                        let spacing = record.fields.count == 1 ? value : try layoutOperand(1)
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
                    if candidate.unknownSavedButtonText.contains(handle) {
                        candidate.dirtySavedButtonText.insert(handle)
                    }
                    if candidate.buttonText[handle] != nil { candidate.buttonText[handle] = message }
                    else { candidate.messages[handle] = message }
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
                    if scope == [ScriptStorage.fileLogHandle] {
                        // 0x6be58b → 0x5b1918 → 0x5b15cc clears the log backend.
                        candidate.fileLogValues.removeAll()
                        action = "file_log_clear_candidate"
                        break
                    }
                    if scope == [ScriptStorage.lineLogHandle] {
                        // 0x6be7c5 → 0x5b1698 clears the separate label-log backend.
                        candidate.lineLogValues.removeAll()
                        action = "line_log_clear_candidate"
                        break
                    }
                    guard scope.count == 1, let handle = scope.first, var message = candidate.messages[handle] ?? candidate.buttonText[handle] else {
                        throw ResourceError.rejected("message_clear_requires_message_scope")
                    }
                    // 0x6c8f64 calls 0x6787b0, which drains output and clears
                    // the message surface and transient text. The CLI only queues
                    // output without rendering glyphs.
                    message.clearOutput()
                    candidate.unknownSavedButtonText.remove(handle)
                    candidate.savedButtonTextOpaque.removeValue(forKey: handle)
                    candidate.dirtySavedButtonText.remove(handle)
                    if candidate.buttonText[handle] != nil { candidate.buttonText[handle] = message }
                    else { candidate.messages[handle] = message }
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
                    guard scope.count == 1, let handle = scope.first, var message = candidate.messages[handle] ?? candidate.buttonText[handle] else {
                        throw ResourceError.rejected("message_flush_requires_message_scope")
                    }
                    guard !candidate.unknownSavedButtonText.contains(handle) else {
                        throw ResourceError.rejected("saved_button_text_unverified")
                    }
                    // 0x6c954b calls 0x678b00, which drains the pending queue.
                    // Keep the committed operations available for the rendering host.
                    try message.commitOutput()
                    if candidate.buttonText[handle] != nil { candidate.buttonText[handle] = message }
                    else { candidate.messages[handle] = message }
                    action = "message_flush_output_candidate"
                case "o":
                    try arity(1)
                    let scope = candidate.frames.last!.tableScope
                    guard scope.count == 1, let handle = scope.first, candidate.messages[handle] != nil || candidate.buttonTextBounds[handle] != nil else {
                        throw ResourceError.rejected("message_output_requires_message_scope")
                    }
                    guard !candidate.unknownSavedButtonText.contains(handle) else {
                        throw ResourceError.rejected("saved_button_text_unverified")
                    }
                    let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                        write: { _,_ in throw ResourceError.rejected("mutating_message_operand_outside_profile") },
                        readIndexed: { try candidate.readIndexed($0,$1) })
                    guard case .string(let text) = value, text.utf8.count <= 8192 else {
                        throw ResourceError.rejected("message_output_requires_bounded_directive_string")
                    }
                    // A blank save display field contributes no operations to the preview queue.
                    if text.isEmpty {
                        action = "message_empty_output_candidate"
                        break
                    }
                    // 0x6c9778 forwards the string to 0x6782a8. The renderer at
                    // 0x6794ee distinguishes text from bracketed directives.
                    // Queue the supported text and directives for the future host.
                    let output = try ScriptStorage.MessageObject.parseOutput(text)
                    // Preserve each output batch in script order for headless replay.
                    // The original renderer drains output at 0x6789e8.
                    if candidate.messages[handle] == nil {
                        guard output.count <= 128 - (candidate.buttonText[handle]?.pendingOutput.count ?? 0) else {
                            throw ResourceError.rejected("message_pending_output_limit")
                        }
                        candidate.buttonText[handle, default: .init()].enqueueOutput(text, parsed: output)
                        action = "button_queue_output_candidate"
                        break
                    }
                    var message = candidate.messages[handle]!
                    guard output.count <= 128 - message.pendingOutput.count else {
                        throw ResourceError.rejected("message_pending_directive_limit")
                    }
                    message.enqueueOutput(text, parsed: output)
                    candidate.messages[handle] = message
                    action = "message_queue_output_candidate"
                case "?in", "?out", "dc", "bg", "in", "out", "ps":
                    if ["in", "?in", "out", "?out"].contains(command),
                       candidate.frames.last!.tableScope == [ScriptStorage.systemHandle] {
                        let output = command == "out" || command == "?out"
                        let usesPrimary = candidate.selectsPrimaryScriptSource &&
                            (output ? candidate.linkedPrimaryOutputMask != nil : candidate.linkedPrimaryInputMask != nil)
                        if command == "?in" || command == "?out" {
                            try arity(0)
                            // 0x6b2d72 / 0x6b2de9 read fields +0x164 / +0x168.
                            let mask = output ? (usesPrimary ? candidate.linkedPrimaryOutputMask! : candidate.systemOutputMask) :
                                (usesPrimary ? candidate.linkedPrimaryInputMask! : candidate.systemInputMask)
                            candidate.clearResultBindings()
                            try candidate.resultInteger(mask)
                            action = output ? "system_output_mask_query_candidate" : "system_input_mask_query_candidate"
                        } else {
                            // 0x6b2d2b / 0x6b2da2 reset each mask when no operand is supplied.
                            var mask: Int32 = 0xffffff
                            if !record.fields.isEmpty {
                                try arity(1)
                                let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                                    write: { _,_ in throw ResourceError.rejected("mutating_system_input_mask") },
                                    readIndexed: { try candidate.readIndexed($0,$1) })
                                guard let integer = value.integer else {
                                    throw ResourceError.rejected("system_input_mask_requires_integer")
                                }
                                mask = integer
                            }
                            if output {
                                if usesPrimary { candidate.linkedPrimaryOutputMask = mask }
                                else { candidate.systemOutputMask = mask }
                            } else if usesPrimary { candidate.linkedPrimaryInputMask = mask }
                            else { candidate.systemInputMask = mask }
                            action = output ? "system_output_mask_write_candidate" : "system_input_mask_write_candidate"
                        }
                        break
                    }
                    guard command != "?in" && command != "?out" else { throw ResourceError.rejected("unsupported_command") }
                    try arity(1)
                    let scope = candidate.frames.last!.tableScope
                    let imageHandle = scope.count == 1 ? scope.first : nil
                    let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                        write: { _,_ in throw ResourceError.rejected("mutating_effect_operand_outside_profile") },
                        readIndexed: { try candidate.readIndexed($0,$1) })
                    if command == "in" || command == "out" {
                        guard !scope.isEmpty, let mask = value.integer else {
                            throw ResourceError.rejected("drawable_mask_requires_scope_and_integer")
                        }
                        for handle in scope {
                            if candidate.buttons.contains(handle) {
                                // The shared drawable handler writes +0xbf5 / +0xbf9.
                                if command == "in" { candidate.buttonInputMasks[handle] = mask }
                                else { candidate.buttonOutputMasks[handle] = mask }
                            } else if candidate.messages[handle] != nil {
                                if command == "in" { candidate.messages[handle]?.inputMask = mask }
                                else { candidate.messages[handle]?.outputMask = mask }
                            } else if candidate.images[handle] != nil {
                                if command == "in" { candidate.images[handle]?.inputMask = mask }
                                else { candidate.images[handle]?.outputMask = mask }
                            } else {
                                throw ResourceError.rejected("drawable_mask_requires_drawable_scope")
                            }
                        }
                        action = "drawable_\(command)_mask_candidate"
                        break
                    }
                    if command == "dc", let handle = imageHandle,
                       var message = candidate.messages[handle] {
                        guard let integer = value.integer else {
                            throw ResourceError.rejected("message_setting_requires_integer")
                        }
                        // 0x6cba9d validates the channel; 0x67ea0c forwards it to all three image components.
                        guard (0...3).contains(integer) else {
                            throw ResourceError.rejected("message_draw_channel_outside_profile")
                        }
                        message.drawChannel = integer
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
                        case "ps":
                            if let elapsed = image.motionElapsedHundredths(at: candidate.visualTicks) {
                                image.motionElapsedBeforeSpeedChange = elapsed
                                image.motionStartTick = candidate.visualTicks
                            }
                            let rate = min(3000, max(0, integer))
                            if image.hasExtendedContainerMetadata, !image.isTheoraResource,
                               (image.playbackSpeed ?? 100) == 100, rate != 100 {
                                image.hasIndependentActionClock = true
                            }
                            image.playbackSpeed = rate
                        default: throw ResourceError.rejected("unsupported_image_setting")
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
                    if command != "fdi" || !(3...5).contains(record.fields.count) { try arity(command == "fdp" ? 5 : 2) }
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
                    guard (mode == 0 || mode == 4), (0...60_000).contains(duration) else {
                        throw ResourceError.rejected("fade_in_mode_or_duration_outside_profile")
                    }
                    candidate.fadeInRule = nil
                    candidate.fadeInAnimation = nil
                    if record.fields.count >= 3 {
                        let path = try callLabel(2)
                        if !path.isEmpty {
                            guard mode == 0, candidateRepository != nil, let imageLoader else {
                                throw ResourceError.rejected("fade_in_resource_outside_profile")
                            }
                            let logical = try candidateRepository!.catalog.resourcePath(path,currentSourceFile: record.location.sourceFile)
                            let (reference, data) = try candidateRepository!.readResource(logical)
                            _ = try imageLoader(data)
                            let location = ScriptLocation(sourceFile: reference.sourceFile,sourceSHA256: reference.sourceSHA256,
                                byteOffset: 0,byteLength: data.count,rangeSHA256: data.sha256Hex,lineNumber: 1)
                            resourceLocation = location
                            if record.fields.count == 5 {
                                candidate.fadeInRule = (location,try integerOperand(4))
                            } else {
                                // The third field names the animation when no rule power is supplied.
                                candidate.fadeInAnimation = location
                            }
                        }
                        // The mode-0 dispatcher calls 0x6be204 with 60000
                        // for the fourth field when its text pointer is null.
                        candidate.fadeInPriority = try record.fields.count == 3 || field(3).isEmpty ? 60_000 : integerOperand(3)
                    } else {
                        candidate.fadeInPriority = nil
                    }
                    // The shipped sentence script selects mode 4 for mosaic.
                    candidate.fadeInMode = mode
                    candidate.fadeInDuration = duration
                    candidate.fadeInStartTick = candidate.visualTicks
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
                        replayEffectSurface = nil
                        candidate.effectCapturePriority = priority
                        candidate.fadeInMode = nil
                        candidate.fadeInDuration = nil
                        candidate.fadeInPriority = nil
                        candidate.fadeInRule = nil
                        candidate.fadeInAnimation = nil
                        candidate.effectFillColor = 0xff00_0000
                        action = record.fields.isEmpty ? "effect_black_fill_candidate" : "effect_capture_request_candidate"
                    } else {
                        action = "effect_capture_preserved_candidate"
                    }
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
                    if !record.fields.isEmpty { try arity(1) }
                    let value = record.fields.isEmpty ? ScriptValue.integer(1) : try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                        write: { _,_ in throw ResourceError.rejected("mutating_draw_operand") },
                        readIndexed: { try candidate.readIndexed($0,$1) })
                    guard let count = value.integer else { throw ResourceError.rejected("draw_requires_integer") }
                    // 0x6bc98c stores the request, clamped to at least one.
                    candidate.drawRequestCount = max(1,count)
                    action = "draw_request_candidate"
                    if researchStopAtDrawBoundary || (allowResearchSkipTimeCandidate && candidate.researchSkipTime > 0) {
                        // 0x6ac45f stops the native dispatch loop when +0x94 is positive.
                        // The next frame and its audio effects remain unmodelled.
                        phase = .waitingForFrame
                    }
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
                        // 0x6b0055 changes a zero primary operand to an indefinite wait.
                        timedStopRequest = (ticks[0] == 0 ? -1 : ticks[0], ticks[1])
                    }
                    stopCallback = callback
                    phase = .waitingForEvent
                    action = timed ? "timed_stop_callback_wait_candidate" : "stop_callback_wait_candidate"
                case "clk", "wait":
                    if command == "wait" {
                        try arity(1)
                        guard !(try field(0)).isEmpty else {
                            throw ResourceError.rejected("timed_wait_requires_integer")
                        }
                    }
                    guard record.fields.count <= 1 else { throw ResourceError.rejected("click_wait_arity") }
                    var countdown: Int32 = -1
                    if !record.fields.isEmpty, !(try field(0)).isEmpty {
                        let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_wait_operand_outside_profile") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard let integer = value.integer else { throw ResourceError.rejected("click_wait_requires_integer") }
                        countdown = max(-1,integer)
                    }
                    try candidate.setClickResult(0)
                    if command == "wait" {
                        // 0x6b1903 clears ResultClkInt; 0x6b195f only enters mode 3 for positive durations.
                        if countdown > 0 {
                            clickWaitRemaining = countdown
                            phase = .waiting
                        }
                        action = "timed_wait_candidate"
                    } else {
                        clickWaitRemaining = countdown
                        clickWaitInitial = countdown
                        phase = .waiting
                        action = "click_wait_enter_candidate"
                    }
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
                    swappedStreamHandles = channels
                    candidate.soundChannels[channels[0]] = second
                    candidate.soundChannels[channels[1]] = first
                    if allowLiveSoundSwapHandoff {
                        // 0x59d270 swaps the stream player pointers, including
                        // the timed controls bound to each player.
                        soundSwapRequest = .init(first: channels[0], second: channels[1])
                        phase = .waitingForSoundSwap
                    } else {
                        for channel in channels {
                            candidate.soundChannels[channel]?.volumeControlToken = nil
                            candidate.soundChannels[channel]?.panControlToken = nil
                        }
                    }
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
                case "s" where candidate.frames.last!.tableScope == [ScriptStorage.saveDataHandle]:
                    try arity(1)
                    let name = try callLabel(0)
                    guard name.hasSuffix(".svd"), try SafeDirectory.components(name).count == 1 else {
                        throw ResourceError.rejected("save_slot_name_outside_profile")
                    }
                    pendingSaveWrite = (name, candidate.systemNameSlots + [""])
                    action = "save_slot_write_request_candidate"
                case "s" where candidate.frames.last!.tableScope != [ScriptStorage.saveDataHandle],
                     "?g" where candidate.frames.last!.tableScope != [ScriptStorage.saveDataHandle]:
                    if command == "s", candidate.frames.last!.tableScope.count == 1,
                       let handle = candidate.frames.last!.tableScope.first, var list = candidate.lists[handle] {
                        try arity(2)
                        let indexValue = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_list_line_index") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        let textValue = try ScriptExpression.parse(field(1)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_list_line_value") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard let index = indexValue.integer, case .string(let text) = textValue else {
                            throw ResourceError.rejected("list_line_write_requires_index_and_string")
                        }
                        // 0x6cd334–0x6cd352 bounds-checks before the list setter.
                        try list.setLine(text, at: index, location: record.location)
                        candidate.lists[handle] = list
                        try candidate.validate()
                        action = "list_line_write_candidate"
                        break
                    }
                    if command == "s", candidate.frames.last!.tableScope.count == 1,
                       let stream = candidate.frames.last!.tableScope.first, ScriptStorage.isStreamHandle(stream) {
                        try arity(0)
                        // 0x6b5168 takes the zero/default stop path for this channel.
                        candidate.soundChannels[stream]?.playing = false
                        action = "sound_channel_stop_candidate"
                        break
                    }
                    if candidate.frames.last!.tableScope == [ScriptStorage.memoryDataHandle] {
                        if command == "?g" {
                            try arity(1)
                            let name = try callLabel()
                            let exists = memoryCheckpoints[Data(asciiLower(name).utf8)] != nil ||
                                candidate.serializedMemoryCheckpointIndex(named: name) != nil
                            // 0x6cc8c2 queries the named checkpoint and returns its presence.
                            candidate.clearResultBindings()
                            try candidate.resultInteger(exists ? 1 : 0)
                            action = "memory_checkpoint_query_candidate"
                        } else {
                            guard (2...3).contains(record.fields.count) else {
                                throw ResourceError.rejected("memory_checkpoint_capture_arity")
                            }
                            let name = try callLabel()
                            let operands = try record.fields.indices.dropFirst().map { slot in
                                try ScriptExpression.parse(field(slot)).evaluate(read: { try candidate.read($0) },
                                    write: { _,_ in throw ResourceError.rejected("mutating_memory_checkpoint_operand") },
                                    readIndexed: { try candidate.readIndexed($0,$1) })
                            }
                            let key = Data(asciiLower(name).utf8)
                            let serializedIndex = candidate.serializedMemoryCheckpointIndex(named: name)
                            guard !key.isEmpty, key.count <= 1024,
                                  memoryCheckpoints.count + candidate.serializedMemoryCheckpoints.count < 64 ||
                                    memoryCheckpoints[key] != nil || serializedIndex != nil,
                                  let options = operands[0].integer,
                                  let mode = operands.count == 1 ? 2 : operands[1].integer else {
                                throw ResourceError.rejected("memory_checkpoint_operands_or_budget")
                            }
                            if let request = makePrimaryMemorySaveRequest(record: record, next: next, name: name,
                                                                          options: options, mode: mode, candidate: candidate) {
                                primarySaveRequest = request
                                phase = .waitingForPrimarySave
                                action = "memory_checkpoint_capture_requested"
                                break
                            }
                            if let serializedIndex { candidate.serializedMemoryCheckpoints.remove(at: serializedIndex) }
                            // 0x6cc856 supplies mode 2 when the third field is absent.
                            memoryCheckpoints[key] = .init(name: name, options: options, mode: mode,
                                storage: candidate, program: program, resumeIndex: pc+1)
                            candidate.clearResultBindings()
                            try candidate.resultInteger(1)
                            action = "memory_checkpoint_capture_candidate"
                        }
                        break
                    }
                    if candidate.frames.last!.tableScope == [ScriptStorage.temporaryDataHandle] {
                        if command == "?g" {
                            try arity(1)
                            let key = Data(asciiLower(try callLabel()).utf8)
                            let exists = (linkedLogJumpCheckpoints ?? logJumpCheckpoints).contains { $0.key == key }
                            candidate.clearResultBindings()
                            try candidate.resultInteger(exists ? 1 : 0)
                            action = "temporary_checkpoint_query_candidate"
                            break
                        }
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
                        if let request = makePrimaryTemporarySaveRequest(record: record, next: next, name: name,
                                                                         options: options, mode: mode, candidate: candidate) {
                            primarySaveRequest = request
                            phase = .waitingForPrimarySave
                            action = "temporary_checkpoint_capture_requested"
                            break
                        }
                        storeTemporaryCheckpoint(.init(key: Data(asciiLower(name).utf8), stream: nil))
                        action = "temporary_checkpoint_capture_candidate"
                        break
                    }
                    if command == "s", candidate.frames.last!.tableScope == [ScriptStorage.dialogueLogHandle] {
                        try arity(5)
                        let index = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_dialogue_log_index") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard let offset = index.integer else {
                            throw ResourceError.rejected("dialogue_log_update_requires_integer")
                        }
                        let values = try (1...4).map { try callLabel($0) }
                        // 0x6b81fc calls 0x5b03b0, which replaces an existing newest-first entry.
                        if offset >= 0, Int(offset) < min(256, candidate.dialogueLogEntries.count) {
                            let slot = candidate.dialogueLogEntries.count - 1 - Int(offset)
                            let old = candidate.dialogueLogEntries[slot]
                            let oldBytes = old.speaker.utf8.count + old.text.utf8.count + old.voice.utf8.count + old.extra.utf8.count
                            let bytes = candidate.dialogueLogBytes - oldBytes + values.reduce(0) { $0 + $1.utf8.count }
                            guard bytes <= 16 * 1024 * 1024 else {
                                throw ResourceError.rejected("dialogue_log_budget")
                            }
                            candidate.dialogueLogEntries[slot] = .init(location: record.location,
                                speaker: values[0], text: values[1], voice: values[2], extra: values[3],
                                integerFields: old.integerFields)
                            candidate.dialogueLogBytes = bytes
                        }
                        action = "dialogue_log_update_candidate"
                        break
                    }
                    if candidate.frames.last!.tableScope == [ScriptStorage.fileLogHandle] {
                        try arity(command == "s" ? 2 : 1)
                        // 0x4e7700 normalizes UTF-16 ASCII capitals through 0x41493c.
                        let key = Data(asciiLower(try callLabel()).utf8)
                        if command == "?g" {
                            // 0x6be566 reads a stored Int32, with -1 for a missing key.
                            candidate.clearResultBindings()
                            try candidate.resultInteger(candidate.fileLogValues[key] ?? -1)
                            action = "file_log_integer_query_candidate"
                        } else {
                            let value = try ScriptExpression.parse(field(1)).evaluate(read: { try candidate.read($0) },
                                write: { _,_ in throw ResourceError.rejected("mutating_file_log_operand") },
                                readIndexed: { try candidate.readIndexed($0,$1) })
                            guard let integer = value.integer, key.count <= 8192,
                                  candidate.fileLogValues.count < 20_000 || candidate.fileLogValues[key] != nil else {
                                throw ResourceError.rejected("file_log_write_outside_profile")
                            }
                            // 0x6be5ef passes the overwrite flag to the file-log setter.
                            if !key.isEmpty { candidate.fileLogValues[key] = integer }
                            action = "file_log_integer_write_candidate"
                        }
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
                        try candidate.setConfigResultArray(
                            (entry?.integerFields ?? Array(repeating: 0, count: 4)).map(ScriptValue.integer), string: false)
                        action = "dialogue_log_reverse_query_candidate"
                        break
                    }
                    guard candidate.frames.last!.tableScope == [ScriptStorage.lineLogHandle] else {
                        throw ResourceError.rejected("line_log_command_requires_line_log_scope")
                    }
                    let name = try callLabel()
                    let key = Data(asciiLower(name).utf8)
                    if command == "s" {
                        let value = try ScriptExpression.parse(field(1)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_line_log_operand") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard let integer = value.integer,
                              key.isEmpty || candidate.lineLogValues.count < 4096 || candidate.lineLogValues[key] != nil else {
                            throw ResourceError.rejected("line_log_write_outside_profile")
                        }
                        // 0x6be824 forwards the overwrite flag to TLabelLog.Add;
                        // 0x5b13ac ignores an empty string key.
                        if !key.isEmpty { candidate.lineLogValues[key] = integer }
                        action = "line_log_integer_write_candidate"
                    } else {
                        // 0x6be79d calls TLabelLog.Get, whose backend returns -1 for an absent key.
                        candidate.clearResultBindings()
                        try candidate.resultInteger(candidate.lineLogValues[key] ?? -1)
                        action = "line_log_integer_query_candidate"
                    }
                case "?k2":
                    try arity(0)
                    guard candidate.frames.last!.tableScope == [ScriptStorage.lineLogHandle] else {
                        throw ResourceError.rejected("read_status_query_requires_line_log_scope")
                    }
                    // A missing entry has a native-backed result regardless
                    // of unrelated label-log entries: TLabelLog.Get returns
                    // -1, and the reader comparison yields unread (0). The
                    // local reader-key mapping remains inferred, so require a
                    // unique resolvable label and reject both known key forms
                    // if either is present; present-key comparison stays in
                    // the explicit research path below.
                    let probe = labelHistoryProbe
                    if probe.frames.count == candidate.frames.count,
                       let selected = probe.frames.first(where: {
                       $0.readerEligibleLabel && $0.nearestLabel?.sourceFile == program.document.source.relativePath &&
                               $0.nearestLabel?.sourceSHA256 == program.document.source.sha256
                       }), selected.uniqueLabel, selected.logicalPathAvailable,
                       selected.relativeLine.map({ $0 >= 0 }) == true,
                       selected.keyMatchWithMarker == false, selected.keyMatchWithoutMarker == false,
                       selected.candidateReadStatus == 0 {
                        candidate.clearResultBindings()
                        try candidate.resultInteger(0)
                        labelHistoryReadOutcome = 0
                        action = "label_read_status_missing_key_candidate"
                        break
                    }
                    // If either candidate key is present, exact reader-key
                    // formation and read-position mapping remain research-only.
                    guard allowLabelHistoryCandidate else {
                        throw ResourceError.rejected("label_read_status_unsupported")
                    }
                    guard probe.frames.count == candidate.frames.count,
                          let selected = probe.frames.first(where: {
                              $0.readerEligibleLabel && $0.nearestLabel?.sourceFile == program.document.source.relativePath &&
                                  $0.nearestLabel?.sourceSHA256 == program.document.source.sha256
                          }),
                          selected.uniqueLabel, selected.logicalPathAvailable,
                          let observed = selected.candidateReadStatus else {
                        throw ResourceError.rejected("label_read_status_context_unsupported")
                    }
                    candidate.clearResultBindings()
                    try candidate.resultInteger(observed)
                    labelHistoryReadOutcome = observed
                    if observed == 0 && allowResearchSkipFrameCandidate { unreadLabelProbe = probe }
                    action = "label_read_status_context_candidate"
                case "?mcw", "?ap":
                    try arity(0)
                    let scope = candidate.frames.last!.tableScope
                    let value: Int32
                    if command == "?mcw", scope == [ScriptStorage.configHandle] {
                        // 0x6c3234 reads the field populated by AutoPlayClickTime at 0x50025f.
                        let configured = try candidate.configuration?.value(for: "AutoPlayClickTime")
                        let override = candidate.configMessageOverrides["AutoPlayClickTime"]
                        value = override ?? configured.flatMap(ScriptExpression.integerTextCache) ?? 1500
                        action = override == nil ? "config_autoplay_click_time_candidate" : "config_autoplay_click_time_override_candidate"
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
                        if let expected = candidate.researchExpectedActorAliasSHA256,
                           try JSONEncoder().encode(aliases).sha256Hex != expected {
                            throw ResourceError.rejected("research_config_overlay_actor_identity_mismatch")
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
                case "sr", "?sr":
                    guard candidate.frames.last!.tableScope == [ScriptStorage.systemHandle] else {
                        throw ResourceError.rejected("system_release_argument_requires_system_scope")
                    }
                    if command == "sr" {
                        try arity(1)
                        // 0x6b32a8 evaluates the string and writes receiver +0x18.
                        candidate.systemReleaseArgument = try callLabel()
                        action = "system_release_argument_set_candidate"
                    } else {
                        try arity(0)
                        // 0x6b2650 resets results and copies receiver +0x18 to ResultStr[0].
                        candidate.clearResultBindings()
                        try candidate.resultString(candidate.systemReleaseArgument)
                        action = "system_release_argument_query_candidate"
                    }
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
                    guard let requestedDepth = value.integer, requestedDepth > 0 else {
                        throw ResourceError.rejected("reader_query_depth_outside_profile")
                    }
                    let depth = Int(requestedDepth)
                    let callerIndex = candidate.frames.count - 1 - depth
                    guard callerIndex >= 0,
                          let caller = candidate.frames[callerIndex+1].returnProgram,
                          let index = candidate.frames[callerIndex+1].returnIndex,
                          index > 0, index <= caller.document.records.count else {
                        throw ResourceError.rejected("reader_query_depth_outside_profile")
                    }
                    // 0x6b2798 selects the saved reader by subtracting the requested depth.
                    let source = caller.document.records[index-1].location.sourceFile
                    let parts = source.split(separator: "/", maxSplits: 1)
                    let logical = parts.count == 2 && parts[0].hasSuffix(".pack") ? String(parts[1]) : source
                    candidate.clearResultBindings()
                    let callerLabel = candidate.frames[callerIndex].entryLabel ?? ""
                    try candidate.setConfigResultArray([.string(logical), .string(callerLabel)], string: true)
                    action = "caller_reader_identity_candidate"
                case "?gs":
                    try arity(0)
                    guard candidate.frames.last!.tableScope == [ScriptStorage.systemHandle] else {
                        throw ResourceError.rejected("game_size_requires_system_scope")
                    }
                    let dimensions = try [("AspectWidth", Int32(1280)), ("AspectHeight", Int32(720))].map { key, fallback in
                        guard let raw = try candidate.configuration?.value(for: key) else { return fallback }
                        guard let value = ScriptExpression.integerTextCache(raw), (1...8192).contains(value) else {
                            throw ResourceError.rejected("game_size_configuration_outside_profile")
                        }
                        return value
                    }
                    // 0x6b26a9 writes the two logical canvas dimensions to ResultInt.
                    candidate.clearResultBindings()
                    try candidate.setConfigResultArray(dimensions.map(ScriptValue.integer), string: false)
                    action = "logical_game_size_query_candidate"
                case "n2":
                    guard candidate.frames.last!.tableScope == [ScriptStorage.systemHandle] else {
                        throw ResourceError.rejected("system_name_slots_require_system_scope")
                    }
                    try arity(2)
                    let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                        write: { _,_ in throw ResourceError.rejected("mutating_system_name_slot_operand") },
                        readIndexed: { try candidate.readIndexed($0,$1) })
                    guard let slot = value.integer else { throw ResourceError.rejected("system_name_slot_requires_integer") }
                    let name = try callLabel(1)
                    // 0x6b2e9a ignores out-of-range indexes after evaluating both operands.
                    if candidate.systemNameSlots.indices.contains(Int(slot)) {
                        candidate.systemNameSlots[Int(slot)] = name
                    }
                    action = "system_name_slot_set_candidate"
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
                case "tef":
                    guard candidate.frames.last!.tableScope == [ScriptStorage.systemHandle] else {
                        throw ResourceError.rejected("thumbnail_filter_requires_system_scope")
                    }
                    try arity(1)
                    // Mode zero takes neither filtered-capture branch at 0x6ae5ad.
                    guard try field(0) == "0" else {
                        throw ResourceError.rejected("thumbnail_filter_mode_unsupported")
                    }
                    action = "system_thumbnail_filter_clear_candidate"
                case "eve":
                    try arity(2)
                    guard candidate.frames.last!.tableScope == [ScriptStorage.systemHandle],
                          asciiLower(try callLabel(0)) == "onframe" else {
                        throw ResourceError.rejected("system_event_outside_profile")
                    }
                    let label = try callLabel(1)
                    if label.isEmpty {
                        candidate.systemFrameEvent = nil
                        action = "system_frame_event_clear_candidate"
                        break
                    }
                    let destination = try program.label(label)
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
                    if command == "?lk", [ScriptStorage.fileLogHandle, ScriptStorage.lineLogHandle]
                        .contains(candidate.frames.last!.tableScope.first ?? 0),
                       candidate.frames.last!.tableScope.count == 1 {
                        try arity(0)
                        guard let locked = candidate.fileLogLocked else {
                            throw ResourceError.rejected("file_log_lock_unknown")
                        }
                        // Both 0x6be4c1 and 0x6be752 read the file-log +0x10 byte.
                        candidate.clearResultBindings()
                        try candidate.resultInteger(locked ? 1 : 0)
                        action = "file_log_lock_query_candidate"
                        break
                    }
                    if command == "?lk", candidate.frames.last!.tableScope.count == 1,
                       let handle = candidate.frames.last!.tableScope.first, candidate.buttons.contains(handle) {
                        try arity(0)
                        // 0x6c5677 returns whether the button's +0xf09 byte is nonzero.
                        guard !candidate.unknownSavedButtonLocks.contains(handle) else {
                            throw ResourceError.rejected("saved_button_lock_unverified")
                        }
                        candidate.clearResultBindings()
                        try candidate.resultInteger(candidate.buttonLocks[handle, default: 0] == 0 ? 0 : 1)
                        action = "button_lock_query_candidate"
                        break
                    }
                    if command == "?lk", candidate.frames.last!.tableScope.count == 1,
                       let handle = candidate.frames.last!.tableScope.first, let bar = candidate.bars[handle] {
                        try arity(0)
                        candidate.clearResultBindings()
                        try candidate.resultInteger(bar.locked ? 1 : 0)
                        action = "bar_lock_query_candidate"
                        break
                    }
                    try arity(0)
                    guard candidate.frames.last!.tableScope == [ScriptStorage.systemHandle] else {
                        throw ResourceError.rejected("lock_query_requires_system_scope")
                    }
                    // 0x6b25de and 0x6b2636 read their respective lock fields.
                    let custom = command == "?lkc"
                    let mask = custom ? candidate.systemCustomLockMask : candidate.systemLockMask
                    candidate.clearResultBindings()
                    try candidate.resultInteger(mask)
                    action = custom ? "system_custom_lock_query_candidate" : "system_lock_query_candidate"
                case "?ver":
                    try arity(0)
                    guard candidate.frames.last!.tableScope == [ScriptStorage.systemHandle] else {
                        throw ResourceError.rejected("engine_version_query_requires_system_scope")
                    }
                    // 0x6b3d84 passes the fixed UTF-16 "392" to the integer converter.
                    candidate.clearResultBindings()
                    try candidate.resultInteger(392)
                    action = "engine_version_query_candidate"
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
                    // Modes 3...5 can set the engine skip flag during the native
                    // frame update at 0x6abb2c. The host does not model that
                    // update (or all other flag writers), so returning the fresh
                    // session value here would silently select the wrong branch.
                    if command == "?skp",
                       (candidate.systemPlayMode >= 3 || (candidate.linkedPrimaryPlayMode ?? 0) >= 3),
                       !(allowResearchSkipFrameCandidate && candidate.researchSystemSkip != nil &&
                         candidate.linkedPrimaryPlayMode == nil) {
                        throw ResourceError.rejected("system_skip_frame_state_unsupported")
                    }
                    candidate.clearResultBindings()
                    // 0x6b249c reads the engine flag; 0x6b3b73 reads the context flag.
                    if command == "?skp", allowResearchSkipFrameCandidate, let skip = candidate.researchSystemSkip {
                        try candidate.resultInteger(skip ? 1 : 0)
                        action = "system_skip_frame_candidate"
                    } else if command == "?skp", let skip = candidate.restoredSystemSkip {
                        try candidate.resultInteger(skip ? 1 : 0)
                        action = "system_skip_after_load_reset_candidate"
                    } else {
                        try candidate.resultInteger(0)
                        action = command == "dskp" ? "context_skip_fresh_session_candidate" : "system_skip_fresh_session_candidate"
                    }
                case "rnd":
                    guard candidate.frames.last!.tableScope == [ScriptStorage.mathHandle],
                          record.fields.count <= 1 else {
                        throw ResourceError.rejected("random_scope_or_arity")
                    }
                    var bound: UInt32 = 0x00ff_ffff
                    if !record.fields.isEmpty {
                        let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_random_operand") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard let integer = value.integer else {
                            throw ResourceError.rejected("random_requires_integer")
                        }
                        bound = UInt32(bitPattern: integer)
                    }
                    // 0x6a6e98 returns zero for a zero divisor and otherwise an unsigned remainder.
                    // This host uses its own random sequence.
                    let random = bound == 0 ? 0 : UInt32.random(in: .min ... .max) % bound
                    candidate.clearResultBindings()
                    try candidate.resultInteger(Int32(bitPattern: random))
                    action = "math_random_candidate"
                case "max":
                    guard candidate.frames.last!.tableScope == [ScriptStorage.mathHandle],
                          (1...128).contains(record.fields.count) else {
                        throw ResourceError.rejected("math_max_scope_or_arity")
                    }
                    func operand(_ text: String) throws -> Int32 {
                        let value = try ScriptExpression.parse(text).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_math_max_operand") },
                            readIndexed: { try candidate.readIndexed($0, $1) })
                        guard let integer = value.integer else {
                            throw ResourceError.rejected("math_max_requires_integer")
                        }
                        return integer
                    }
                    var maximum = try operand(field(0))
                    for slot in record.fields.indices.dropFirst() {
                        let text = try field(slot)
                        if !text.isEmpty { maximum = max(maximum, try operand(text)) }
                    }
                    // 0x6c0134 compares signed values; 0x6c015b writes ResultInt[0].
                    candidate.clearResultBindings()
                    try candidate.resultInteger(maximum)
                    action = "math_max_candidate"
                case "zero":
                    try arity(0)
                    candidate.engineField98 = 2
                    candidate.researchZeroClockHistoryUncertain = false
                    action = "engine_field_98_write_candidate"
                case "skip":
                    guard allowResearchSkipTimeCandidate else { throw ResourceError.rejected("unsupported_command") }
                    try arity(1)
                    let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                        write: { _,_ in throw ResourceError.rejected("mutating_skip_time") },
                        readIndexed: { try candidate.readIndexed($0,$1) })
                    guard let ticks = value.integer, ticks >= 0 else { throw ResourceError.rejected("skip_time_negative_or_noninteger_unsupported") }
                    let (sum, overflow) = candidate.researchSkipTime.addingReportingOverflow(ticks)
                    guard !overflow else { throw ResourceError.rejected("skip_time_overflow") }
                    candidate.researchSkipTime = sum
                    action = "skip_time_accumulation_candidate"
                case "sc":
                    try arity(0)
                    guard candidate.frames.last!.tableScope == [ScriptStorage.inputHandle],
                          stopCallbackFrameDepth != nil, pendingButton == nil || !pendingClick else {
                        throw ResourceError.rejected("input_click_query_outside_profile")
                    }
                    // 0x6c9b4c scans type-8 events separately; a synthetic
                    // button-only event does not imply such an event.
                    candidate.clearResultBindings()
                    try candidate.resultInteger(pendingClick ? 1 : 0)
                    action = pendingClick ? "input_click_consumed_candidate" : "input_click_empty_cycle_candidate"
                    pendingClick = false
                case "k2":
                    if !isLinkedLogTask { try arity(2) }
                    let keys = try record.fields.indices.map { try field($0) }
                    let standardKeys = keys == ["$10002", "$1001B"]
                    let logKeys = isLinkedLogTask && keys == ["$10002", "$1001B", "$10009"]
                    let logWheel = isLinkedLogTask && keys == ["$400F0", "$400F1"]
                    let logNavigation = isLinkedLogTask && keys == ["$00026", "$00028", "$00021", "$00022",
                        "$30026", "$30028", "$30021", "$30022", "$2000D"]
                    guard candidate.frames.last!.tableScope == [ScriptStorage.inputHandle],
                          stopCallbackFrameDepth != nil,
                          (pointerPosition != nil || pendingLoadEscape || pendingDialogueLogNavigation != nil ||
                           pendingDialogueLogWheel != nil || syntheticBarCallbackActive),
                          !pendingClick, standardKeys || logKeys || logWheel || logNavigation else {
                        throw ResourceError.rejected("input_key_range_outside_pointer_profile")
                    }
                    // 0x6ca240 dispatches k2 to 0x6ca068. The inclusive key scan
                    // clears results at 0x6ca12c and writes only matching keys.
                    candidate.clearResultBindings()
                    let escape = pendingLoadEscape && (standardKeys || logKeys)
                    if logNavigation, let navigation = pendingDialogueLogNavigation {
                        try candidate.resultInteger(navigation.keyCode)
                        pendingDialogueLogNavigation = nil
                        action = "input_dialogue_log_navigation_candidate"
                    } else if logWheel, let wheel = pendingDialogueLogWheel {
                        // 0x5a3851–0x5a387a publishes F0 or F1 and retains the signed wheel delta for ?mw.
                        try candidate.resultInteger(wheel > 0 ? 0x400f0 : 0x400f1)
                        action = "input_dialogue_log_wheel_candidate"
                    } else {
                        try candidate.resultInteger(escape ? 0x1001b : 0)
                        action = escape ? "input_load_escape_candidate" : "input_key_range_empty_pointer_cycle_candidate"
                        if escape { pendingLoadEscape = false }
                    }
                case "swp":
                    try arity(1)
                    guard isLinkedLogTask, candidate.frames.last!.tableScope == [ScriptStorage.inputHandle],
                          try field(0) == "1" else { throw ResourceError.rejected("input_swipe_reset_outside_profile") }
                    // 0x6caaa3 clears the active swipe at 0x5a48a8. This host path has no active swipe.
                    action = "input_dialogue_log_swipe_reset_candidate"
                case "?mw":
                    try arity(0)
                    guard isLinkedLogTask, stopCallbackFrameDepth != nil,
                          candidate.frames.last!.tableScope == [ScriptStorage.inputHandle] else {
                        throw ResourceError.rejected("dialogue_log_wheel_query_outside_profile")
                    }
                    candidate.clearResultBindings()
                    try candidate.resultInteger(pendingDialogueLogWheel ?? 0)
                    action = "input_dialogue_log_wheel_delta_candidate"
                case "gsc":
                    try arity(0)
                    guard candidate.frames.last!.tableScope == [ScriptStorage.inputHandle], stopCallbackFrameDepth != nil else {
                        throw ResourceError.rejected("input_scope_required")
                    }
                    if inspectUnrenderedBars, pointerPosition != nil, !syntheticBarCallbackActive,
                       candidate.bars.values.contains(where: { $0.enabled }) {
                        throw ResourceError.rejected("bar_pointer_input_unsupported")
                    }
                    // 0x6c9cc4 searches type 9 objects for an input-change marker.
                    // Input production and native marker aging remain unsupported.
                    try candidate.setBarChangeResults()
                    action = "input_bar_change_result_candidate"
                case "gbc":
                    try arity(0)
                    guard candidate.frames.last!.tableScope == [ScriptStorage.inputHandle],
                          stopCallbackFrameDepth != nil else {
                        throw ResourceError.rejected("button_event_scope_required")
                    }
                    let handle = pendingButton ?? ScriptStorage.nullHandle
                    try candidate.setButtonResults(handle: handle,label: candidate.buttonScriptTargets[handle] ?? "")
                    if let values = candidate.buttonUserIntegers[handle] {
                        try candidate.setConfigResultArray((0..<4).map { .integer(values[$0] ?? 0) }, string: false)
                    }
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
                case "?wh":
                    try arity(0)
                    guard candidate.frames.last!.tableScope.count == 1,
                          let handle = candidate.frames.last!.tableScope.first,
                          let image = candidate.images[handle], image.resource != nil,
                          !image.hasExtendedContainerMetadata,
                          let width = image.width, let height = image.height,
                          (1...8192).contains(width), (1...8192).contains(height) else {
                        throw ResourceError.rejected("image_dimensions_query_outside_profile")
                    }
                    // 0x6c87e3/0x6c87fa query the loaded image's two dimensions.
                    // Standalone Theora uses 0x5803d0/0x580490 and the
                    // 0x562bf0/0x562b04 callbacks for the header picture size.
                    candidate.clearResultBindings()
                    try candidate.setConfigResultArray([.integer(Int32(width)), .integer(Int32(height))], string: false)
                    action = image.isTheoraResource
                        ? (allowResearchVideoImageDimensions ? "video_image_header_dimensions_research_candidate" : "video_image_header_dimensions_candidate")
                        : "image_dimensions_query_candidate"
                case "?mp":
                    try arity(0)
                    guard candidate.frames.last!.tableScope == [ScriptStorage.inputHandle],
                          let pointerPosition = pointerPosition ?? lastPointerPosition else {
                        throw ResourceError.rejected("input_pointer_sample_required")
                    }
                    // 0x6ca602 reads persistent input-manager fields. Outside
                    // callbacks this is only the last host-supplied sample.
                    candidate.clearResultBindings()
                    try candidate.setConfigResultArray([.integer(pointerPosition.x),.integer(pointerPosition.y)],string: false)
                    action = "input_pointer_query_candidate"
                case "mm", "tf", "bm", "alg", "alg2":
                    if command == "tf", candidate.frames.last!.tableScope.count == 1,
                       let handle = candidate.frames.last!.tableScope.first, candidate.movies[handle] != nil {
                        try arity(1)
                        let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_movie_operand_outside_profile") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard let integer = value.integer else { throw ResourceError.rejected("movie_filter_requires_integer") }
                        // 0x6b8c71 stores the low byte.
                        candidate.movies[handle]?.textureFilter = UInt8(truncatingIfNeeded: integer)
                        action = "theora_texture_filter_candidate"
                        break
                    }
                    guard (1...2).contains(record.fields.count),
                          let handle = candidate.frames.last!.tableScope.first,
                          candidate.frames.last!.tableScope.count == 1,
                          handle == ScriptStorage.cameraHandle ||
                            candidate.images[handle] != nil ||
                            (command == "alg2" && candidate.messages[handle] != nil) ||
                            (command == "mm" && candidate.buttonResources[handle] != nil) else {
                        throw ResourceError.rejected("motion_mode_requires_loaded_scope")
                    }
                    if handle == ScriptStorage.cameraHandle {
                        guard command != "alg2" && command != "alg" else { throw ResourceError.rejected("image_alignment_requires_image_scope") }
                        try arity(command == "mm" ? 2 : 1)
                    } else if command != "mm" {
                        try arity(command == "alg2" || command == "alg" ? 2 : 1)
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
                    if command == "alg2" || command == "alg" {
                        // 0x5adb2c stores both alignment operands as integers.
                        // 0x6c6762–0x6c676d multiplies alg operands by 50.
                        let x = command == "alg" ? operands[0] &* 50 : operands[0]
                        let y = command == "alg" ? operands[1] &* 50 : operands[1]
                        if candidate.messages[handle] != nil {
                            candidate.messages[handle]?.alignment = (x,y)
                            action = "message_alignment_candidate"
                        } else {
                            candidate.images[handle]?.alignment = (x,y)
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
                        let mode = candidate.selectsPrimaryScriptSource
                            ? candidate.linkedPrimaryPlayMode ?? candidate.systemPlayMode : candidate.systemPlayMode
                        try candidate.resultInteger(mode)
                        action = "system_play_mode_query_candidate"
                        break
                    }
                    if candidate.frames.last!.tableScope.count == 1,
                       let handle = candidate.frames.last!.tableScope.first, let movie = candidate.movies[handle] {
                        // 0x6b871b exposes the playback byte as ResultInt[0].
                        candidate.clearResultBindings()
                        try candidate.resultInteger((movie.remainingTicks ?? 0) > 0 ? 1 : 0)
                        action = "theora_play_status_query_candidate"
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
                    // The native getters read the drawable's own placement.
                    candidate.clearResultBindings()
                    try candidate.setConfigResultArray(placement.map(ScriptValue.integer),string: false)
                    action = candidate.buttons.contains(handle) ? "button_position_query_candidate" : "image_position_query_candidate"
                    if candidate.messages[handle] != nil { action = "message_position_query_candidate" }

                case "d":
                    if candidate.frames.last!.tableScope == [ScriptStorage.saveDataHandle] {
                        try arity(1)
                        pendingSaveDeletion = try callLabel()
                        candidate.clearResultBindings()
                        try candidate.resultInteger(1)
                        action = "save_slot_delete_request_candidate"
                        break
                    }
                    if candidate.frames.last!.tableScope == [ScriptStorage.fileLogHandle] {
                        try arity(1)
                        // 0x5b1878 removes the first matching normalized path.
                        let path = try callLabel()
                        candidate.removeFileLogPath(path)
                        action = "file_log_path_remove_candidate"
                        break
                    }
                    if inspectUnrenderedBars, candidate.frames.last!.tableScope.count == 1,
                       let handle = candidate.frames.last!.tableScope.first, candidate.bars[handle] != nil {
                        try arity(0)
                        candidate.bars[handle]?.enabled = false
                        action = "bar_disable_unrendered_candidate"
                        break
                    }
                    if candidate.frames.last!.tableScope.count == 1,
                       let handle = candidate.frames.last!.tableScope.first, candidate.timers[handle] != nil {
                        try arity(0)
                        // 0x6ac849 clears the enable byte; the next update clears elapsed time.
                        candidate.timers[handle]?.enabled = false
                        action = "timer_disable_candidate"
                        break
                    }
                    if candidate.frames.last!.tableScope == [ScriptStorage.memoryDataHandle] {
                        try arity(1)
                        let name = try callLabel()
                        if memoryCheckpoints.removeValue(forKey: Data(asciiLower(name).utf8)) == nil,
                           let index = candidate.serializedMemoryCheckpointIndex(named: name) {
                            candidate.serializedMemoryCheckpoints.remove(at: index)
                        }
                        action = "memory_checkpoint_delete_candidate"
                        break
                    }
                    if candidate.frames.last!.tableScope == [ScriptStorage.replacementHandle] {
                        try arity(1)
                        let key = Data(asciiLower(try callLabel()).utf8)
                        candidate.replacementRules.removeValue(forKey: key)
                        candidate.replacementOrder.removeAll { $0 == key }
                        action = "replacement_delete_candidate"
                        break
                    }
                    if !record.fields.isEmpty {
                        try arity(1)
                        guard candidate.frames.last!.tableScope.count == 1,
                              let handle = candidate.frames.last!.tableScope.first,
                              candidate.images[handle] != nil || candidate.buttons.contains(handle),
                              try field(0) == "1" else {
                            throw ResourceError.rejected("visual_disable_operand_outside_profile")
                        }
                        // The observed choice teardown uses literal mode 1 after its wait.
                        // Model the disabled endpoint in the headless host.
                    }
                    let scope = candidate.frames.last!.tableScope
                    guard !scope.isEmpty else {
                        throw ResourceError.rejected("drawable_disable_requires_scope")
                    }
                    for handle in scope {
                        if candidate.messages[handle] != nil {
                            // 0x67e67c forwards disable to the message components.
                            candidate.messages[handle]?.enabled = false
                            action = "message_disable_candidate"
                        } else if candidate.buttons.contains(handle) {
                            candidate.enabledButtons.remove(handle)
                            action = "button_disable_candidate"
                        } else if var image = candidate.images[handle] {
                            // 0x5ac9e3–0x5ac9f4 selects *Disable without forcing a restart.
                            if image.enabled, let resource = image.resource, let names = imageMotionNames?(resource) {
                                let index = motionIndex("*Disable", in: names)
                                if index >= 0, image.selectedMember != index {
                                    image.selectNativeMotion(index, at: candidate.visualTicks,
                                        rowFlags: imageLayerFlags?(resource, index))
                                }
                            }
                            image.enabled = false
                            image.savedDrawGate = nil
                            candidate.images[handle] = image
                            action = "image_disable_candidate"
                        } else {
                            throw ResourceError.rejected("drawable_disable_requires_scope")
                        }
                    }
                    if scope.count > 1 { action = "drawable_group_disable_candidate" }
                case "l2":
                    try arity(4)
                    guard candidate.frames.last!.tableScope.count == 1,
                          let handle = candidate.frames.last!.tableScope.first, candidate.bars[handle] != nil,
                          candidateRepository != nil, let imageLoader else {
                        throw ResourceError.rejected("bar_load_requires_single_scope_and_catalog")
                    }
                    func barOperand(_ slot: Int) throws -> ScriptValue {
                        try ScriptExpression.parse(field(slot)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_bar_operand") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                    }
                    let values = try (0..<4).map { try barOperand($0) }
                    guard case .string(let first) = values[0],
                          case .string(let second) = values[1], !second.isEmpty,
                          case .string(let third) = values[2], let mode = values[3].integer,
                          (mode == 0 && first.isEmpty && !third.isEmpty) ||
                            (mode == 1 && !first.isEmpty && third.isEmpty) else {
                        throw ResourceError.rejected("bar_load_shape_outside_profile")
                    }
                    var references: [ScriptLocation?] = [nil, nil, nil]
                    for (index, path) in [first, second, third].enumerated() where !path.isEmpty {
                        let logical = try candidateRepository!.catalog.resourcePath(path, currentSourceFile: record.location.sourceFile)
                        let (reference, data) = try candidateRepository!.readResource(logical)
                        let (width, height, _) = try imageLoader(data)
                        guard (1...8192).contains(width), (1...8192).contains(height) else {
                            throw ResourceError.rejected("bar_resource_dimensions")
                        }
                        references[index] = ScriptLocation(sourceFile: reference.sourceFile, sourceSHA256: reference.sourceSHA256,
                            byteOffset: 0, byteLength: data.count, rangeSHA256: data.sha256Hex, lineNumber: 1)
                    }
                    candidate.bars[handle] = .init(resources: references, resourceLoadMode: mode)
                    action = "bar_resources_loaded_candidate"
                case "e":
                    if allowTitleQuit, systemLoadTaskID != nil, Self.isTitleQuitCompletion(record.location),
                       candidate.frames.last!.tableScope == [ScriptStorage.systemHandle] {
                        try arity(0)
                        titleQuitShutdownRequested = true
                        systemTaskExitRequested = true
                        phase = .finished
                        action = "title_quit_shutdown_requested"
                        break
                    }
                    if cleanShutdownInProgress, Self.isStartupCleanupSite(record.location, line: 39),
                       candidate.frames.last!.tableScope == [ScriptStorage.systemHandle] {
                        try arity(0)
                        // The host is already closing after running the startup cleanup entry.
                        cleanShutdownInProgress = false
                        candidate.soundChannels.removeAll()
                        candidate.directSoundChannels.removeAll()
                        candidate.timers.removeAll()
                        phase = .finished
                        action = "clean_shutdown_finished"
                        break
                    }
                    if record.fields.count == 1,
                       let handle = candidate.frames.last!.tableScope.first,
                       candidate.frames.last!.tableScope.count == 1, candidate.buttonResources[handle] != nil {
                        let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_button_enable_operand") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard let integer = value.integer, integer != 0 else {
                            throw ResourceError.rejected("button_enable_operand_outside_profile")
                        }
                        guard !candidate.unknownSavedButtonText.contains(handle) else {
                            throw ResourceError.rejected("saved_button_text_unverified")
                        }
                        // 0x6c7a8a chooses the immediate virtual method for
                        // nonzero; TButtonLib's slot calls 0x5ab98c without
                        // selecting an enable motion.
                        candidate.enabledButtons.insert(handle)
                        action = "button_enable_immediate_candidate"
                        break
                    }
                    try arity(0)
                    if candidate.frames.last!.tableScope.count == 1,
                       let handle = candidate.frames.last!.tableScope.first, var bar = candidate.bars[handle] {
                        let verticalLog = isLinkedLogTask && bar.resourceLoadMode == 1
                        let childSlot = verticalLog ? 0 : 2
                        guard inspectUnrenderedBars || verticalLog, bar.resources.count == 3,
                              let track = bar.resources[1], let child = bar.resources[childSlot] else {
                            throw ResourceError.rejected("bar_rendering_and_input_unsupported")
                        }
                        guard let trackNames = imageMotionNames?(track), let childNames = imageMotionNames?(child) else {
                            throw ResourceError.rejected("bar_enable_motion_metadata_unavailable")
                        }
                        let trackEnable = motionIndex("*Enable", in: trackNames)
                        let childEnable = motionIndex("*Enable", in: childNames)
                        guard trackEnable >= 0, childEnable >= 0 else {
                            throw ResourceError.rejected("bar_enable_motion_unavailable")
                        }
                        bar.trackEnableMotion = trackEnable
                        if verticalLog { bar.thumbEnableMotion = childEnable }
                        else { bar.progressEnableMotion = childEnable }
                        bar.enabled = true
                        candidate.bars[handle] = bar
                        action = "bar_enable_motion_candidate"
                        break
                    }
                    if candidate.frames.last!.tableScope.count == 1,
                       let handle = candidate.frames.last!.tableScope.first, let timer = candidate.timers[handle] {
                        guard timer.interval > 0, timer.callback != nil, timer.argument.isEmpty else {
                            throw ResourceError.rejected("timer_enable_outside_profile")
                        }
                        // 0x6ac823 sets the underlying enable byte.
                        candidate.timers[handle]?.enabled = true
                        action = "timer_enable_candidate"
                        break
                    }
                    if candidate.frames.last!.tableScope.count == 1,
                       let handle = candidate.frames.last!.tableScope.first, candidate.messages[handle] != nil {
                        // 0x67e67c / 0x67e6a4 forward disable / enable to all message components.
                        candidate.messages[handle]?.enabled = true
                        action = "message_enable_candidate"
                        break
                    }
                    if let handle = candidate.frames.last!.tableScope.first,
                       candidate.frames.last!.tableScope.count == 1, candidate.buttonResources[handle] != nil {
                        guard !candidate.unknownSavedButtonText.contains(handle) else {
                            throw ResourceError.rejected("saved_button_text_unverified")
                        }
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
                    // 0x5aca20 selects the cached *Enable action only on the disabled-to-enabled edge.
                    if !image.enabled, let resource = image.resource, let names = imageMotionNames?(resource) {
                        let index = motionIndex("*Enable", in: names)
                        if index >= 0 {
                            image.selectNativeMotion(index, at: candidate.visualTicks,
                                rowFlags: imageLayerFlags?(resource, index))
                        }
                    }
                    image.enabled = true
                    image.savedDrawGate = nil
                    candidate.images[handle] = image
                    action = image.selectedMember == nil ? "image_enable_default_candidate" : "image_enable_candidate"
                case "skp":
                    try arity(1)
                    guard candidate.frames.last!.tableScope.count == 1,
                          let handle = candidate.frames.last!.tableScope.first,
                          var image = candidate.images[handle] else {
                        throw ResourceError.rejected("image_skip_requires_image_scope")
                    }
                    let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                        write: { _,_ in throw ResourceError.rejected("mutating_image_operand_outside_profile") },
                        readIndexed: { try candidate.readIndexed($0,$1) })
                    guard let ticks = value.integer else {
                        throw ResourceError.rejected("image_skip_requires_integer")
                    }
                    // 0x6c6ab6 dispatches skp to 0x5ab3b4, which ignores nonpositive increments.
                    // The real window hide routine calls the skip helper after d
                    // (imoscripter_custom.s:1332,1341). Its exit clock is still live.
                    let canSkipExit = image.isDialogueWindowAnimation && image.selectedMember == 1
                    if ticks > 0, (image.enabled || canSkipExit),
                       !image.standaloneVideoIsPaused(in: researchVideoSaveProfiles),
                       let elapsed = image.motionElapsedHundredths(at: candidate.visualTicks) {
                        let speed = Int64(image.playbackSpeed ?? 100)
                        image.motionElapsedBeforeSpeedChange = min(Int64(Int32.max) * 100, elapsed + Int64(ticks) * speed)
                        image.motionStartTick = candidate.visualTicks
                        candidate.images[handle] = image
                    }
                    action = "image_skip_clock_candidate"
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
                    candidate.ensureStreamChannel(stream)
                    candidate.soundChannels[stream]?.seekRequest = position
                    if allowLiveSoundPositionQuery, let sound = candidate.soundChannels[stream], sound.playing {
                        guard let source = sound.resource, let playbackStep = sound.playbackStartStep else {
                            throw ResourceError.rejected("sound_seek_identity_unavailable")
                        }
                        soundSeekRequest = .init(channel: stream, source: source,
                            playbackStep: playbackStep, milliseconds: position)
                        phase = .waitingForSoundSeek
                        action = "sound_live_seek_request_candidate"
                    } else {
                        action = "sound_seek_request_candidate"
                    }
                case "?sk":
                    try arity(0)
                    guard allowLiveSoundPositionQuery, candidate.frames.last!.tableScope.count == 1,
                          let channel = candidate.frames.last!.tableScope.first, ScriptStorage.isStreamHandle(channel),
                          let sound = candidate.soundChannels[channel], sound.playing,
                          let source = sound.resource, let playbackStep = sound.playbackStartStep else {
                        throw ResourceError.rejected("sound_position_observation_unavailable")
                    }
                    soundPositionRequest = .init(channel: channel, source: source, playbackStep: playbackStep)
                    phase = .waitingForSoundPosition
                    action = "sound_position_observation_request_candidate"
                case "ck", "?ck":
                    let scope = candidate.frames.last!.tableScope
                    guard scope.count == 1, let handle = scope.first, candidate.buttons.contains(handle) else {
                        throw ResourceError.rejected("button_ck_requires_button_scope")
                    }
                    if command == "?ck" {
                        try arity(0)
                        // 0x6c56d4 tests the byte written by the ck setter.
                        guard !candidate.unknownSavedButtonChecks.contains(handle) else {
                            throw ResourceError.rejected("saved_button_check_unverified")
                        }
                        candidate.clearResultBindings()
                        try candidate.resultInteger(candidate.buttonCheckVisual[handle, default: 0] == 0 ? 0 : 1)
                        action = "button_ck_query_candidate"
                        break
                    }
                    try arity(1)
                    let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                        write: { _,_ in throw ResourceError.rejected("mutating_button_ck") },
                        readIndexed: { try candidate.readIndexed($0,$1) })
                    guard let integer = value.integer else {
                        throw ResourceError.rejected("button_ck_requires_integer")
                    }
                    // 0x67c774 stores the low byte and selects a button motion.
                    let checkByte = UInt8(truncatingIfNeeded: integer)
                    candidate.buttonCheckVisual[handle] = checkByte
                    candidate.unknownSavedButtonChecks.remove(handle)
                    if checkByte == 0 { candidate.buttonActionSelectionUnknown.remove(handle) }
                    else { candidate.buttonActionSelectionUnknown.insert(handle) }
                    action = "button_ck_state_candidate"
                case "mi", "?mi":
                    let scope = candidate.frames.last!.tableScope
                    guard scope.count == 1, let handle = scope.first,
                          candidate.buttons.contains(handle) || candidate.images[handle] != nil else {
                        throw ResourceError.rejected("mi_requires_image_or_button_scope")
                    }
                    if command == "?mi" {
                        try arity(0)
                        candidate.clearResultBindings()
                        let enabled = candidate.images[handle].map { $0.miFlag != 0 } ?? candidate.buttonMI.contains(handle)
                        try candidate.resultInteger(enabled ? 1 : 0)
                    } else {
                        try arity(1)
                        let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_mi_operand") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard let integer = value.integer else {
                            throw ResourceError.rejected("mi_requires_integer")
                        }
                        // Both command handlers store the result of an exact comparison with 1.
                        if candidate.images[handle] != nil {
                            candidate.images[handle]?.miFlag = integer == 1 ? 1 : 0
                        } else if integer == 1 { candidate.buttonMI.insert(handle) }
                        else { candidate.buttonMI.remove(handle) }
                    }
                    action = candidate.images[handle] != nil ? "image_mi_state_candidate" : "button_mi_state_candidate"
                case "mv", "vt":
                    try arity(1)
                    guard candidate.frames.last!.tableScope.count == 1,
                          let handle = candidate.frames.last!.tableScope.first, var bar = candidate.bars[handle] else {
                        throw ResourceError.rejected("bar_setting_requires_single_scope")
                    }
                    let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                        write: { _,_ in throw ResourceError.rejected("mutating_bar_operand") },
                        readIndexed: { try candidate.readIndexed($0,$1) })
                    guard let integer = value.integer else { throw ResourceError.rejected("bar_setting_requires_integer") }
                    if command == "mv" {
                        // 0x67ed4c clamps the current value directly and
                        // updates geometry without the value-change callback.
                        if integer >= 0 {
                            bar.maximum = integer
                            bar.value = min(bar.value, integer)
                            bar.transitionRemaining = min(bar.transitionRemaining, bar.transition)
                        }
                    } else { bar.transition = integer }
                    candidate.bars[handle] = bar
                    action = command == "mv" ? "bar_maximum_candidate" : "bar_transition_candidate"
                case "vtn", "v", "vi", "pan":
                    if command == "vi" {
                        let scope = candidate.frames.last!.tableScope
                        guard scope.count == 1, let handle = scope.first, candidate.bars[handle] != nil else {
                            throw ResourceError.rejected("bar_inverse_value_requires_single_scope")
                        }
                    }
                    if command == "vtn", candidate.frames.last!.tableScope.count == 1,
                       let handle = candidate.frames.last!.tableScope.first, candidate.bars[handle] != nil {
                        try arity(1)
                        let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_bar_operand") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard let integer = value.integer else { throw ResourceError.rejected("bar_volume_type_requires_integer") }
                        // 0x6cc25d and 0x6cc26e set the first two children to the same volume group.
                        candidate.bars[handle]?.childVolumeType = integer
                        action = "bar_child_volume_type_candidate"
                        break
                    }
                    if command != "pan", candidate.frames.last!.tableScope.count == 1,
                       let handle = candidate.frames.last!.tableScope.first, ScriptStorage.isDirectSoundHandle(handle) {
                        try arity(1)
                        let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_direct_sound_operand") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard let integer = value.integer else { throw ResourceError.rejected("direct_sound_requires_integer") }
                        if command == "vtn" { candidate.directSoundChannels[handle, default: .init()].volumeType = integer }
                        else { candidate.directSoundChannels[handle, default: .init()].volume = integer }
                        action = "direct_sound_\(command)_candidate"
                        break
                    }
                    if command == "v" || command == "vi", candidate.frames.last!.tableScope.count == 1,
                       let handle = candidate.frames.last!.tableScope.first, var bar = candidate.bars[handle] {
                        guard (1...2).contains(record.fields.count) else { throw ResourceError.rejected("unsupported_command_arity") }
                        let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_bar_operand") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard let integer = value.integer else { throw ResourceError.rejected("bar_value_requires_integer") }
                        var immediate = false
                        if record.fields.count == 2 {
                            let flag = try ScriptExpression.parse(field(1)).evaluate(read: { try candidate.read($0) },
                                write: { _,_ in throw ResourceError.rejected("mutating_bar_operand") },
                                readIndexed: { try candidate.readIndexed($0,$1) })
                            guard let mode = flag.integer else { throw ResourceError.rejected("bar_value_mode_outside_profile") }
                            // 0x6cc06f passes (mode == 0) as the animated flag.
                            immediate = mode != 0
                        }
                        // 0x6cc0e2 subtracts the inverse input from +0xb0 before the ordinary setter.
                        let requested = command == "vi" ? bar.maximum &- integer : integer
                        let next = min(max(requested, 0), bar.maximum)
                        // Script-created bars have a null native callback (0x67db99).
                        // User strings at +0x74 are separate event data, not that callback.
                        if next != bar.value {
                            bar.transitionStart = bar.value
                            bar.value = next
                            if immediate {
                                bar.transitionRemaining = 0
                                bar.transitionStart = next
                            } else {
                                bar.transitionRemaining = bar.transition
                            }
                        }
                        // 0x67eb51 clamps remaining time when geometry is refreshed.
                        bar.transitionRemaining = min(bar.transitionRemaining, bar.transition)
                        candidate.bars[handle] = bar
                        action = command == "vi" ? "bar_inverse_value_candidate" : "bar_value_candidate"
                        break
                    }
                    let scope = candidate.frames.last!.tableScope
                    if command != "pan", scope.count == 1, let handle = scope.first,
                       var movie = candidate.movies[handle] {
                        try arity(1)
                        let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_movie_operand_outside_profile") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard let integer = value.integer else { throw ResourceError.rejected("movie_volume_requires_integer") }
                        // 0x6b89b2 and 0x6b86a6 store independent Int32 fields.
                        if command == "vtn" { movie.volumeTarget = integer }
                        else { movie.volume = integer }
                        candidate.movies[handle] = movie
                        action = "theora_volume_setting_candidate"
                        break
                    }
                    if command == "v", scope.count == 1, let handle = scope.first,
                       candidate.tables[handle] != nil || candidate.lists[handle] != nil {
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
                        if candidate.tables[handle] != nil {
                            try candidate.tables[handle]?.setValue(value, for: name)
                        } else {
                            try candidate.lists[handle]?.setValue(value, for: name, at: record.location)
                        }
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
                    if let stream { candidate.ensureStreamChannel(stream) }
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
                            candidate.requestStreamPan(stream!, position: integer, duration: timing[0], delay: timing[1])
                        } else {
                            // 0x5a0848 reapplies the selected type before setting the envelope.
                            let appliedType = candidate.soundChannels[stream!]?.volumeType ?? 0
                            candidate.soundChannels[stream!]?.appliedVolumeType = appliedType
                            candidate.soundChannels[stream!]?.volume = integer
                            candidate.soundChannels[stream!]?.volumeDuration = timing[0]
                            candidate.soundChannels[stream!]?.volumeLastDuration = timing[0]
                            candidate.soundChannels[stream!]?.volumeDelay = timing[1]
                            candidate.soundChannels[stream!]?.savedVolumeRampTarget = nil
                            candidate.soundChannels[stream!]?.volumeChangePending = true
                            candidate.soundChannels[stream!]?.volumeControlToken = nil
                        }
                    }
                    action = "sound_\(command)_candidate"
                case "ss":
                    try arity(2)
                    guard candidate.frames.last!.tableScope.count == 1,
                          let handle = candidate.frames.last!.tableScope.first, candidate.movies[handle] != nil else {
                        throw ResourceError.rejected("movie_size_requires_movie_scope")
                    }
                    let sizes = try record.fields.indices.map { slot in
                        let value = try ScriptExpression.parse(field(slot)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_movie_operand_outside_profile") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard let integer = value.integer else { throw ResourceError.rejected("movie_size_requires_integer") }
                        return integer
                    }
                    // 0x683f94 stores the two size operands.
                    candidate.movies[handle]?.size = (sizes[0], sizes[1])
                    action = "theora_size_candidate"
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
                    if imageSpeed, var image = candidate.images[handle] {
                        // 0x6c58df reads only the first slot and calls the
                        // animation speed setter at 0x5ae608.
                        if image.hasIndependentActionClock, image.restoredMotionThreshold == nil,
                           let elapsed = image.motionElapsedHundredths(at: candidate.visualTicks) {
                            image.motionElapsedBeforeSpeedChange = elapsed
                            image.motionStartTick = candidate.visualTicks
                        }
                        image.animationSpeed = min(3000, max(0, operands[0]))
                        candidate.images[handle] = image
                        action = "image_animation_speed_candidate"
                    } else if command == "sp" {
                        guard candidate.buttonResources[handle] != nil else {
                            throw ResourceError.rejected("button_scale_requires_loaded_scope")
                        }
                        candidate.buttonSP[handle] = operands
                        action = "button_sp_candidate"
                    } else {
                        guard var movie = candidate.movies[handle], movie.resource != nil else {
                            throw ResourceError.rejected("movie_placement_requires_loaded_scope")
                        }
                        movie.placement = operands
                        candidate.movies[handle] = movie
                        action = "theora_placement_candidate"
                    }
                case "?t":
                    try arity(0)
                    guard let handle = candidate.frames.last!.tableScope.first,
                          candidate.frames.last!.tableScope.count == 1,
                          let timer = candidate.timers[handle] else {
                        throw ResourceError.rejected("timer_interval_query_requires_timer_scope")
                    }
                    // 0x6ac969 reads the interval set by 0x6ac954.
                    candidate.clearResultBindings()
                    try candidate.resultInteger(timer.interval)
                    action = "timer_interval_query_candidate"
                case "?tt":
                    try arity(0)
                    if candidate.frames.last!.tableScope.count == 1,
                       let stream = candidate.frames.last!.tableScope.first, ScriptStorage.isStreamHandle(stream) {
                        guard let duration = candidate.soundChannels[stream]?.probedDurationMilliseconds else {
                            throw ResourceError.rejected("sound_duration_unavailable")
                        }
                        candidate.clearResultBindings()
                        try candidate.resultInteger(duration)
                        action = "sound_probed_duration_query_candidate"
                        break
                    }
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
                    if duration == 0 {
                        image.transform = transform
                        image.placement = placement
                        candidate.placementTransitions.removeValue(forKey: handle)
                    } else {
                        guard image.placement != nil else {
                            throw ResourceError.rejected("timed_placement_origin_unavailable")
                        }
                        if let previous = candidate.placementTransitions[handle], previous.elapsed > 0 {
                            // 0x5ac7e4...0x5ac856 returns without restarting when
                            // the zero-loop request matches the existing target and duration.
                            if previous.matchesUnchangedRequest(destination: placement, duration: duration, transform: transform) {
                                action = "image_extended_placement_unchanged_candidate"
                                break
                            }
                            if allowResearchSkipFrameCandidate, let origin = image.placement {
                                let oldTransform = previous.destinationTransform.map { [$0.depth] + $0.scale + $0.rotation + [$0.loop] }
                                researchPlacementConflict = .init(location: record.location, elapsed: previous.elapsed,
                                    duration: previous.duration, requestedDuration: duration, origin: origin,
                                    previousTarget: previous.destination, requestedTarget: placement,
                                    previousTransform: oldTransform,
                                    requestedTransform: [transform.depth] + transform.scale + transform.rotation + [transform.loop],
                                    motionMode: image.motion?.mode, motionStrength: image.motion?.strength,
                                    savedMode: previous.savedMode)
                            }
                            throw ResourceError.rejected("timed_placement_active_transition_unsupported")
                        }
                        candidate.placementTransitions[handle] = .init(destination: placement, duration: duration, destinationTransform: transform)
                    }
                    candidate.images[handle] = image
                    action = "image_extended_placement_candidate"
                case "p2":
                    if candidate.frames.last!.tableScope.count == 1,
                       let handle = candidate.frames.last!.tableScope.first,
                       var image = candidate.images[handle] {
                        guard (6...7).contains(record.fields.count) else {
                            throw ResourceError.rejected("unsupported_command_arity")
                        }
                        let values = try record.fields.indices.map { slot -> Int32 in
                            let value = try ScriptExpression.parse(field(slot)).evaluate(read: { try candidate.read($0) },
                                write: { _,_ in throw ResourceError.rejected("mutating_image_operand_outside_profile") },
                                readIndexed: { try candidate.readIndexed($0,$1) })
                            guard let integer = value.integer else { throw ResourceError.rejected("image_operand_requires_integer") }
                            return integer
                        }
                        let duration = values[5], loop: Int32 = values.count == 7 ? values[6] : 0
                        guard duration >= 0, loop == 0 else {
                            throw ResourceError.rejected("extended_placement_timing_outside_profile")
                        }
                        // 0x6c5c13 -> 0x5ae718 forwards x/y, priority,
                        // x/y scale, duration and loop to 0x5ac7b0.
                        let placement = [values[0], values[1], values[2]]
                        let transform = ScriptStorage.ImageTransform(depth: 0,
                            scale: [values[3], values[4], 100], rotation: [0, 0, 0], loop: loop)
                        if duration == 0 {
                            image.transform = transform
                            image.placement = placement
                            candidate.placementTransitions.removeValue(forKey: handle)
                        } else {
                            guard image.placement != nil, (candidate.placementTransitions[handle]?.elapsed ?? 0) == 0 else {
                                throw ResourceError.rejected("timed_placement_origin_unavailable")
                            }
                            candidate.placementTransitions[handle] = .init(destination: placement, duration: duration, destinationTransform: transform)
                        }
                        candidate.images[handle] = image
                        action = "image_scaled_placement_candidate"
                        break
                    }
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
                    // 0x6b5201 clamps negative p2 operands to -1; the
                    // 0x5745d0 path sets the play flag without resetting the cursor.
                    let alreadyPlaying = candidate.soundChannels[stream]?.playing == true
                    soundPlaybackPreservesPosition = alreadyPlaying
                    candidate.soundChannels[stream]?.loopRequest = max(-1, loop)
                    let appliedType = candidate.soundChannels[stream]?.volumeType ?? 0
                    candidate.soundChannels[stream]?.appliedVolumeType = appliedType
                    candidate.soundChannels[stream]?.playing = true
                    if !alreadyPlaying {
                        candidate.soundChannels[stream]?.playbackStartStep = executedSteps + 1
                        candidate.soundChannels[stream]?.naturalCompletionStep = nil
                        candidate.soundChannels[stream]?.volumeControlToken = nil
                        candidate.soundChannels[stream]?.panControlToken = nil
                    }
                    soundPlaybackChannel = stream
                    soundPlaybackRequest = resource
                    phase = .waitingForMedia
                    action = "sound_playback_request_candidate"
                case "p", "m":
                    if command == "p", candidate.frames.last!.tableScope.count == 1,
                       let handle = candidate.frames.last!.tableScope.first, ScriptStorage.isDirectSoundHandle(handle) {
                        guard let lock = directSoundLockMilliseconds else {
                            throw ResourceError.rejected("direct_sound_playback_unsupported")
                        }
                        guard record.fields.isEmpty else { throw ResourceError.rejected("direct_sound_playback_mode_unsupported") }
                        guard let direct = candidate.directSoundChannels[handle], let resource = direct.resource else {
                            action = "direct_sound_empty_playback_ignored_candidate"
                            break
                        }
                        let now = UInt32(truncatingIfNeeded: DispatchTime.now().uptimeNanoseconds / 1_000_000)
                        guard DirectSoundTiming.permitsPlayback(now: now, previous: direct.lastStartTick, lockMilliseconds: lock) else {
                            action = "direct_sound_cooldown_candidate"
                            break
                        }
                        let gain = try candidate.configAudioSlot(direct.volumeType, volume: true)
                        let mute = try candidate.configAudioSlot(direct.volumeType, volume: false)
                        guard (0...256).contains(direct.volume), (0...256).contains(gain), (0...1).contains(mute) else {
                            throw ResourceError.rejected("direct_sound_gain_outside_profile")
                        }
                        candidate.directSoundChannels[handle]?.lastStartTick = now
                        candidate.soundChannels[handle] = .init(playing: true, playbackStartStep: executedSteps + 1,
                            volumeType: direct.volumeType, appliedVolumeType: direct.volumeType,
                            volume: direct.volume, resource: resource)
                        soundPlaybackPreservesPosition = false
                        soundPlaybackChannel = handle
                        soundPlaybackRequest = resource
                        phase = .waitingForMedia
                        action = "direct_sound_playback_request_candidate"
                        break
                    }
                    if command == "p", candidate.frames.last!.tableScope.count == 1,
                       let handle = candidate.frames.last!.tableScope.first, var bar = candidate.bars[handle] {
                        // The native bar handler reads arguments 1 through 4
                        // from the complete split list. If one is missing,
                        // TStringList.Get raises; the handler's SEH path marks
                        // the command handled and returns without placement.
                        // Keep that outcome as a candidate because runtime
                        // exception presentation has not been exercised.
                        let logLayoutPlacement = isLinkedLogTask && record.fields.count == 3 &&
                            record.location.sourceFile == "data8.pack/script/log/layout.s" && record.location.lineNumber == 53 &&
                            record.location.sourceSHA256 == "5a8d61c0ac918fb2e2dc6c09c3e0f70f7eac3c03a4d29385192de86036b9e844"
                        guard record.fields.count >= 4 || logLayoutPlacement else {
                            action = "bar_placement_missing_argument_handled_candidate"
                            break
                        }
                        let values = try record.fields.prefix(4).indices.map { slot -> Int32 in
                            let value = try ScriptExpression.parse(field(slot)).evaluate(read: { try candidate.read($0) },
                                write: { _,_ in throw ResourceError.rejected("mutating_bar_operand") },
                                readIndexed: { try candidate.readIndexed($0,$1) })
                            guard let integer = value.integer else { throw ResourceError.rejected("bar_placement_requires_integer") }
                            return integer
                        }
                        guard values.count == 3 || values[3] == 0 else { throw ResourceError.rejected("bar_animated_placement_unsupported") }
                        if logLayoutPlacement {
                            // Use the declared point for the Apple host's log track. The native handler above reads a fourth field.
                            bar.dialogueLogPlacement = values
                        } else {
                            bar.setImmediatePlacement(Array(values.prefix(3)))
                        }
                        candidate.bars[handle] = bar
                        action = logLayoutPlacement ? "dialogue_log_scrollbar_host_placement" : "bar_placement_candidate"
                        break
                    }
                    if command == "p", candidate.frames.last!.tableScope == [ScriptStorage.systemHandle] {
                        try arity(1)
                        let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_system_play_mode") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard let mode = value.integer, (0...5).contains(mode) else {
                            throw ResourceError.rejected("system_play_mode_outside_profile")
                        }
                        // 0x6b2369 dispatches 0 through 5 to the mode setters.
                        if candidate.selectsPrimaryScriptSource, candidate.linkedPrimaryPlayMode != nil {
                            candidate.linkedPrimaryPlayMode = mode
                        } else {
                            candidate.systemPlayMode = mode
                        }
                        if allowResearchSkipFrameCandidate {
                            // Mode zero invokes the native reset helper. Other
                            // setters write only the mode byte, so the last
                            // sampled engine flag remains until a later frame.
                            if mode == 0 { candidate.researchSystemSkip = false }
                        }
                        action = "system_play_mode_write_candidate"
                        break
                    }
                    if command == "p", candidate.frames.last!.tableScope == [ScriptStorage.cameraHandle] {
                        guard (10...11).contains(record.fields.count) else {
                            throw ResourceError.rejected("unsupported_command_arity")
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
                        guard record.fields.count <= 1 else { throw ResourceError.rejected("unsupported_command_arity") }
                        let loop: Int32
                        if record.fields.isEmpty {
                            // 0x69bb17–0x69bb28 gives the missing expression a zero integer result.
                            loop = 0
                        } else {
                            let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                                write: { _,_ in throw ResourceError.rejected("mutating_sound_operand_outside_profile") },
                                readIndexed: { try candidate.readIndexed($0,$1) })
                            guard let integer = value.integer else {
                                throw ResourceError.rejected("sound_playback_loop_requires_integer")
                            }
                            loop = integer
                        }
                        guard let resource = candidate.soundChannels[stream]?.resource else {
                            action = "sound_empty_playback_ignored_candidate"
                            break
                        }
                        // 0x6b51aa tests for exactly one, and 0x573648
                        // translates that flag to the indefinite loop count.
                        candidate.soundChannels[stream]?.loopRequest = loop == 1 ? -1 : 0
                        soundPlaybackPreservesPosition = false
                        let appliedType = candidate.soundChannels[stream]?.volumeType ?? 0
                        candidate.soundChannels[stream]?.appliedVolumeType = appliedType
                        candidate.soundChannels[stream]?.playing = true
                        candidate.soundChannels[stream]?.playbackStartStep = executedSteps + 1
                        candidate.soundChannels[stream]?.naturalCompletionStep = nil
                        candidate.soundChannels[stream]?.volumeControlToken = nil
                        candidate.soundChannels[stream]?.panControlToken = nil
                        soundPlaybackChannel = stream
                        soundPlaybackRequest = resource
                        phase = .waitingForMedia
                        action = "sound_playback_request_candidate"
                        break
                    }
                    if command == "p", let handle = candidate.frames.last!.tableScope.first,
                       candidate.frames.last!.tableScope.count == 1, let movie = candidate.movies[handle] {
                        try arity(0)
                        guard movie.enabled, let resource = movie.resource, let placement = movie.placement, let size = movie.size else {
                            throw ResourceError.rejected("movie_playback_requires_prepared_movie")
                        }
                        // The movie audio callback multiplies by the selected
                        // configuration volume, unless that slot is muted.
                        let effectiveVolume = try candidate.effectiveMovieVolume(movie)
                        moviePlaybackRequest = MoviePlaybackRequest(resource: resource, placement: placement, size: size, volume: effectiveVolume, handle: handle)
                        phase = .waitingForMedia
                        action = "theora_playback_request_candidate"
                        break
                    }
                    guard let handle = candidate.frames.last!.tableScope.first,
                          candidate.frames.last!.tableScope.count == 1,
                          candidate.images[handle] != nil || candidate.messages[handle] != nil ||
                            (command == "p" && candidate.buttons.contains(handle)) else {
                        throw ResourceError.rejected("placement_or_member_requires_loaded_scope")
                    }
                    if command == "m", var message = candidate.messages[handle] {
                        try arity(1)
                        let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_image_operand_outside_profile") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        let motionNames = message.background.flatMap { imageMotionNames?($0) }
                        let index: Int32
                        if case .string(let name) = value, let motionNames {
                            index = motionIndex(name, in: motionNames)
                        } else if let integer = value.integer {
                            index = integer
                        } else {
                            throw ResourceError.rejected("message_member_outside_profile")
                        }
                        // 0x6b7d63 forwards to the image member dispatcher.
                        if index == -1 || (index == 0 && message.backgroundMemberCount == 0) {
                            action = "message_empty_member_ignored_candidate"
                        } else {
                            guard index >= 0, Int(index) < (motionNames?.count ?? message.backgroundMemberCount) else {
                                throw ResourceError.rejected("message_member_outside_profile")
                            }
                            let rowFlags = message.background.flatMap { imageLayerFlags?($0, index) }
                            message.selectNativeBackgroundMotion(index, at: candidate.visualTicks, rowFlags: rowFlags)
                            candidate.messages[handle] = message
                            action = "message_background_member_selection_candidate"
                        }
                        break
                    }
                    let hasDuration = command == "p" && record.fields.count == 4
                    if !hasDuration && !(command == "m" && record.fields.count == 2) {
                        try arity(command == "p" ? 3 : 1)
                    }
                    let motionNames = candidate.images[handle]?.resource.flatMap { imageMotionNames?($0) }
                    let operands: [Int32] = try record.fields.indices.map { slot in
                        let value = try ScriptExpression.parse(field(slot)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_image_operand_outside_profile") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        if command == "m", slot == 0, case .string(let name) = value {
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
                            candidate.messages[handle]?.transform = .init(depth: 0, scale: [100, 100, 100],
                                                                          rotation: [0, 0, 0], loop: 0)
                            action = "message_placement_candidate"
                            break
                        }
                        if duration > 0 {
                            guard (candidate.images[handle]?.placement ?? candidate.messages[handle]?.placement ?? candidate.buttonPlacement[handle]) != nil,
                                  (candidate.placementTransitions[handle]?.elapsed ?? 0) == 0 else {
                                throw ResourceError.rejected("timed_placement_origin_unavailable")
                            }
                            // 0x5ac85f stores the target separately from the current position.
                            let transform = candidate.images[handle] == nil ? nil : ScriptStorage.ImageTransform(
                                depth: 0, scale: [100, 100, 100], rotation: [0, 0, 0], loop: 0)
                            candidate.placementTransitions[handle] = .init(destination: Array(operands.prefix(3)),
                                duration: duration, destinationTransform: transform)
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
                        image.transform = .init(depth: 0, scale: [100, 100, 100], rotation: [0, 0, 0], loop: 0)
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
                            // 0x6c7b30 forces a restart when the second operand is zero.
                            // The original evaluator returns zero for a missing operand (0x69bb17).
                            let restart = operands.count == 1 || operands[1] == 0
                            if restart || image.selectedMember != operands[0] {
                                if let resource = image.resource {
                                    image.selectNativeMotion(operands[0], at: candidate.visualTicks,
                                        rowFlags: imageLayerFlags?(resource, operands[0]))
                                } else {
                                    image.selectedMember = operands[0]
                                    image.motionStartTick = candidate.visualTicks
                                    image.motionElapsedBeforeSpeedChange = 0
                                    image.restoredMotionRemainder = 0
                                    image.layerClockRemainder = 0
                                }
                            }
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
                    // The real history script queries its Message array before
                    // indexing a parallel VoiceButton array.
                    let count = try candidate.scriptObjectArrayCount(name)
                    candidate.clearResultBindings()
                    try candidate.resultInteger(count)
                    action = "object_array_count_candidate"
                case "sarr":
                    guard (1...128).contains(record.fields.count) else {
                        throw ResourceError.rejected("array_resize_field_count_limit")
                    }
                    for slot in record.fields.indices {
                        let spelling = try field(slot)
                        guard !spelling.isEmpty else { continue }
                        guard case .indexed(let name, let dimension) = try ScriptExpression.parse(spelling) else {
                            throw ResourceError.rejected("sarr_requires_indexed_dimension")
                        }
                        let value = try dimension.evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_array_dimension_outside_profile") },
                            readIndexed: { try candidate.readIndexed($0, $1) })
                        guard let count = value.integer else {
                            throw ResourceError.rejected("array_dimension_requires_integer")
                        }
                        // 0x69d815–0x69d824 clamps each size to a minimum of one.
                        try candidate.resizeGlobalVisualArray(name, requestedCount: count)
                    }
                    action = "visual_array_resize_candidate"
                case "lk":
                    if let handle = candidate.frames.last!.tableScope.first,
                       candidate.frames.last!.tableScope.count == 1, candidate.bars[handle] != nil {
                        try arity(1)
                        let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_lock_operand_outside_profile") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard let lock = value.integer else { throw ResourceError.rejected("bar_lock_requires_integer") }
                        // 0x6cc2d1 compares with one before calling 0x67f374.
                        candidate.bars[handle]?.setLock(lock == 1)
                        action = "bar_lock_candidate"
                        break
                    }
                    if let handle = candidate.frames.last!.tableScope.first,
                       candidate.frames.last!.tableScope.count == 1, candidate.buttons.contains(handle) {
                        try arity(1)
                        let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_lock_operand_outside_profile") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard let lock = value.integer else { throw ResourceError.rejected("button_lock_requires_integer") }
                        let lockByte = UInt8(truncatingIfNeeded: lock)
                        candidate.buttonLocks[handle] = lockByte
                        if lockByte == 0 { candidate.buttonActionSelectionUnknown.remove(handle) }
                        else { candidate.buttonActionSelectionUnknown.insert(handle) }
                        candidate.unknownSavedButtonLocks.remove(handle)
                        action = "button_lock_candidate"
                        break
                    }
                    if candidate.frames.last!.tableScope == [ScriptStorage.lineLogHandle] {
                        try arity(1)
                        let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_lock_operand_outside_profile") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard let lock = value.integer else { throw ResourceError.rejected("line_log_lock_requires_integer") }
                        // 0x6be730 sets the label-log lock only for integer one.
                        candidate.lineLogLockTag = lock == 1 ? 1 : 0
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
                case "?sp":
                    try arity(0)
                    guard candidate.frames.last!.tableScope.count == 1,
                          let handle = candidate.frames.last!.tableScope.first,
                          candidate.buttons.contains(handle) else {
                        throw ResourceError.rejected("button_sp_query_requires_single_button")
                    }
                    let values = candidate.buttonSP[handle] ?? [0, 0]
                    guard values.count == 2 else { throw ResourceError.rejected("button_sp_query_shape") }
                    candidate.clearResultBindings()
                    try candidate.setConfigResultArray(values.map(ScriptValue.integer), string: false)
                    action = "button_sp_query_candidate"
                case "?c", "?s", "?n":
                    if command == "?n", candidate.frames.last!.tableScope == [ScriptStorage.systemHandle] {
                        try arity(0)
                        // 0x6b2ec5 clears results and copies all seven receiver slots.
                        candidate.clearResultBindings()
                        try candidate.setConfigResultArray(candidate.systemNameSlots.map(ScriptValue.string), string: true)
                        action = "system_name_slots_query_candidate"
                        break
                    }
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
                    if command == "?c", candidate.frames.last!.tableScope == [ScriptStorage.dialogueLogHandle] {
                        // The native query reads the count of the 256-entry dialogue ring at +0x04.
                        candidate.clearResultBindings()
                        try candidate.resultInteger(Int32(min(256, candidate.dialogueLogEntries.count)))
                        action = "dialogue_log_count_candidate"
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
                    guard record.fields.count == 2 || record.fields.count == 5 else {
                        throw ResourceError.rejected("unsupported_command_arity")
                    }
                    let scope = candidate.frames.last!.tableScope
                    guard scope.count == 1, let handle = scope.first, var list = candidate.lists[handle] else {
                        throw ResourceError.rejected("list_split_requires_list_scope")
                    }
                    let strings: [String] = try (0..<2).map { slot in
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
                    var minimumParts = 0
                    if record.fields.count == 5 {
                        let options = try (2..<5).map { slot -> Int32 in
                            let value = try ScriptExpression.parse(field(slot)).evaluate(read: { try candidate.read($0) },
                                write: { _,_ in throw ResourceError.rejected("mutating_list_split_operand") },
                                readIndexed: { try candidate.readIndexed($0,$1) })
                            guard let integer = value.integer else { throw ResourceError.rejected("list_split_option_requires_integer") }
                            return integer
                        }
                        // 0x6cd66a–0x6cd682 maps these operands to the
                        // split helper; the last operand pads the temporary
                        // result to a minimum count at 0x4e2aa4–0x4e2ac2.
                        guard options[0] == 0, options[1] == 0,
                              (0...10_000).contains(options[2]), !strings[1].contains("\"") else {
                            throw ResourceError.rejected("list_split_options_outside_profile")
                        }
                        minimumParts = Int(options[2])
                    }
                    var parts = ScriptStringList.splitUnquoted(strings[1], separator: separator)
                    guard max(parts.count, minimumParts) <= 10_000 - list.lineCount else {
                        throw ResourceError.rejected("list_append_line_outside_profile")
                    }
                    if parts.count < minimumParts {
                        parts.append(contentsOf: repeatElement("", count: minimumParts - parts.count))
                    }
                    for part in parts {
                        try list.append(part, at: record.location)
                    }
                    candidate.lists[handle] = list
                    try candidate.validate()
                    action = "list_split_append_candidate"
                case "i", "a":
                    if command == "i", candidate.frames.last!.tableScope.count == 1,
                       let handle = candidate.frames.last!.tableScope.first, candidate.timers[handle] != nil {
                        try arity(0)
                        // 0x6ac88f resets the underlying timer.
                        candidate.timers[handle] = .init()
                        action = "timer_initialize_candidate"
                        break
                    }
                    if command == "i", candidate.frames.last!.tableScope == [ScriptStorage.memoryDataHandle] {
                        try arity(0)
                        memoryCheckpoints.removeAll()
                        candidate.serializedMemoryCheckpoints.removeAll()
                        action = "memory_checkpoint_clear_candidate"
                        break
                    }
                    if command == "i", candidate.frames.last!.tableScope == [ScriptStorage.lineLogHandle] {
                        try arity(0)
                        // TLabelLog.Init resets local fields and its lock; LogInit clears the backend separately.
                        candidate.lineLogLockTag = 0
                        action = "line_log_initialize_candidate"
                        break
                    }
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
                            guard (3...4).contains(record.fields.count) else {
                                throw ResourceError.rejected("dialogue_log_append_arity")
                            }
                            let values = try record.fields.indices.map { try callLabel($0) }
                            let strings = values + (values.count == 3 ? [""] : [])
                            let bytes = values.reduce(0) { $0 + $1.utf8.count }
                            guard candidate.dialogueLogEntries.count < 20_000,
                                  candidate.dialogueLogBytes + bytes <= 16 * 1024 * 1024 else {
                                throw ResourceError.rejected("dialogue_log_budget")
                            }
                            candidate.dialogueLogEntries.append(.init(location: record.location,
                                speaker: strings[0], text: strings[1], voice: strings[2], extra: strings[3],
                                integerFields: Array(repeating: 0, count: 4)))
                            candidate.dialogueLogBytes += bytes
                            action = "dialogue_log_append_candidate"
                        }
                        break
                    }
                    if candidate.frames.last!.tableScope == [ScriptStorage.fileLogHandle] {
                        if command == "i" {
                            try arity(0)
                            // 0x6be46c → 0x5b18d0 resets fields and the path list,
                            // without calling the separate log-backend clear.
                            candidate.fileLogPaths.removeAll()
                            candidate.fileLogLocked = false
                            action = "file_log_initialize_candidate"
                        } else {
                            try arity(1)
                            let path = try callLabel()
                            // 0x5b17dc normalizes and adds only absent paths.
                            try candidate.addFileLogPath(path)
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
                        replayEffectSurface = nil
                        candidate.effectCapturePriority = nil
                        candidate.fadeInMode = nil
                        candidate.fadeInDuration = nil
                        candidate.fadeInPriority = nil
                        candidate.fadeInRule = nil
                        candidate.fadeInAnimation = nil
                        candidate.fadeTiming = nil
                        candidate.fadeTransform = nil
                        action = "effect_reset_candidate"
                        break
                    }
                    if command == "i", candidate.frames.last!.tableScope.count == 1,
                       let handle = candidate.frames.last!.tableScope.first, ScriptStorage.isDirectSoundHandle(handle) {
                        try arity(0)
                        candidate.directSoundChannels[handle] = .init()
                        candidate.soundChannels.removeValue(forKey: handle)
                        action = "direct_sound_reset_candidate"
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
                        candidate.visualAnchorNames.removeValue(forKey: handle)
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
                    // 0x6b1411 leaves the result clear if the resolved filename is empty.
                    let found = path.isEmpty ? false : try catalog.resourceExists(path, currentSourceFile: record.location.sourceFile)
                    candidate.clearResultBindings()
                    try candidate.resultInteger(found ? 1 : 0)
                    action = "resource_exists_snapshot_candidate"
                case "g2":
                    try arity(2)
                    let scope = candidate.frames.last!.tableScope
                    // Native 0x6b9843 dispatches against the scoped camera
                    // object directly; cameraInitialized is not a native
                    // precondition for the g2 filter/reset operation.
                    guard scope.count == 1, let handle = scope.first,
                          handle == ScriptStorage.cameraHandle || candidate.images[handle] != nil || candidate.messages[handle] != nil else {
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
                        let previous = candidate.images[handle]?.generatorFilterRequests.last
                        if filter == "mode" {
                            if reset == 1 || previous != filter {
                                candidate.images[handle]?.generatorFilterModeClock = 1
                            }
                        } else {
                            candidate.images[handle]?.generatorFilterModeClock = nil
                        }
                        candidate.images[handle]?.generatorFilterRequests = filters
                        action = "image_generator_filter_request_candidate"
                    }
                case "g", "?g":
                    // The save dispatcher routes g and ?g to the same branch at 0x6b419c.
                    let scope = candidate.frames.last!.tableScope
                    if command == "g", scope.count == 1, let handle = scope.first,
                       handle == ScriptStorage.cameraHandle || candidate.images[handle] != nil {
                        try arity(10)
                        let camera = handle == ScriptStorage.cameraHandle
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
                        let arguments = Array(values[1..<9])
                        let persistent = values[9] == 1
                        let previousTime = camera ? nil : candidate.images[handle]?.generatorRequests[index]?.currentTime
                        let currentTime = persistent ? (previousTime ?? 1) : (arguments[1] <= 0 ? 1 : 0)
                        let request = ScriptStorage.GeneratorRequest(index: index,
                            arguments: arguments, persistent: persistent, currentTime: currentTime)
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
                case "?gd":
                    try arity(1)
                    guard candidate.frames.last!.tableScope == [ScriptStorage.saveDataHandle] else {
                        throw ResourceError.rejected("save_data_scope_required")
                    }
                    let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                        write: { _,_ in throw ResourceError.rejected("mutating_save_operand_outside_profile") },
                        readIndexed: { try candidate.readIndexed($0,$1) })
                    guard case .string(let name) = value, try candidate.containsSessionSave(name),
                          let metadata = candidate.sessionSaveMetadata[Data(asciiLower(name).utf8)],
                          let time = metadata.time else {
                        throw ResourceError.rejected("save_display_metadata_unavailable")
                    }
                    let date = [time.year, time.month, time.day, time.hour, time.minute, time.second]
                    guard date.allSatisfy({ $0 != nil }) else {
                        throw ResourceError.rejected("save_display_date_unavailable")
                    }
                    candidate.clearResultBindings()
                    try candidate.setConfigResultArray(metadata.strings.map(ScriptValue.string), string: true)
                    try candidate.setConfigResultArray(date.compactMap { $0 }.map { .integer(Int32($0)) }, string: false)
                    action = "session_save_display_metadata_candidate"
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
                case "bmat":
                    try arity(2)
                    guard try callLabel(0) == "/[0-9]+/" else {
                        throw ResourceError.rejected("regex_match_pattern_outside_profile")
                    }
                    let input = try callLabel(1)
                    // 0x6afc67 produces a match list. The dispatcher returns its count and at most 16 strings.
                    let runs = input.utf8.split { !(48...57).contains($0) }
                    let matches = runs.prefix(16).map { ScriptValue.string(String(decoding: $0, as: UTF8.self)) }
                    candidate.clearResultBindings()
                    try candidate.resultInteger(Int32(runs.count))
                    try candidate.setConfigResultArray(
                        matches + Array(repeating: .string(""), count: 16 - matches.count), string: true)
                    action = "decimal_regex_match_candidate"
                case "bsub":
                    try arity(3)
                    let input = try callLabel(0)
                    let pattern = try callLabel(1)
                    let replacement = try callLabel(2)
                    let output = try ScriptRegexSubstitution.replace(input: input, pattern: pattern,
                                                                      with: replacement)
                    candidate.clearResultBindings()
                    try candidate.resultString(output)
                    action = "bounded_regex_substitution_candidate"
                case "zenc":
                    try arity(1)
                    let input = try callLabel(0)
                    let output = try ScriptCharacterConversion.zenc(input)
                    candidate.clearResultBindings()
                    try candidate.resultString(output)
                    action = "zenc_empty_input_candidate"
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
                    let replacement: String
                    if record.fields.count == 3 {
                        let value = try ScriptExpression.parse(field(2)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_string_operand_outside_profile") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        switch value {
                        case .string(let text): replacement = text
                        case .integer(let integer): replacement = String(integer)
                        case .object: throw ResourceError.rejected("string_command_requires_strings")
                        }
                    } else { replacement = "" }
                    let output = needle.isEmpty && record.fields.count == 2 ? input :
                        try scriptLiteralReplace(input, needle: needle, replacement: replacement)
                    candidate.clearResultBindings()
                    try candidate.resultString(output)
                    action = "literal_replace_candidate"
                case "efn", "efe", "cfe":
                    try arity(command == "cfe" ? 2 : 1)
                    guard candidate.frames.last!.tableScope == [ScriptStorage.miscHandle] else {
                        throw ResourceError.rejected("filename_operation_requires_misc_scope")
                    }
                    let path = try callLabel(0)
                    let result: String
                    if command == "efn" {
                        // 0x6c4821 calls the filename extraction helper.
                        result = String(path.split(whereSeparator: { $0 == "/" || $0 == "\\" || $0 == ":" }).last ?? "")
                    } else if command == "efe" {
                        // 0x6c486d calls 0x416610, which searches backwards
                        // among dot, backslash and colon and returns from a dot.
                        if let boundary = path.lastIndex(where: { $0 == "." || $0 == "\\" || $0 == ":" }),
                           path[boundary] == "." {
                            result = String(path[boundary...])
                        } else {
                            result = ""
                        }
                    } else {
                        // 0x6c493b calls the extension replacement helper.
                        let suffix = try callLabel(1)
                        let boundary = path.lastIndex(where: { $0 == "/" || $0 == "\\" || $0 == ":" })
                        if let dot = path.lastIndex(of: "."), boundary.map({ dot > $0 }) ?? true {
                            result = String(path[..<dot]) + suffix
                        } else {
                            result = path + suffix
                        }
                    }
                    candidate.clearResultBindings()
                    try candidate.resultString(result)
                    action = "misc_filename_\(command)_candidate"
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
                    guard case .name(let name) = operand, case .object(let source) = try candidate.read(name)
                    else { throw ResourceError.rejected("table_transfer_requires_named_tables") }
                    if command == "asn", let sourceList = candidate.lists[source],
                       handles.allSatisfy({ candidate.lists[$0] != nil }) {
                        for handle in handles { candidate.lists[handle] = sourceList }
                        try candidate.validate()
                        action = "list_assign_candidate"
                        break
                    }
                    guard let sourceTable = candidate.tables[source], handles.allSatisfy({ candidate.tables[$0] != nil })
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
                case "smr":
                    try arity(0)
                    guard candidate.frames.last!.tableScope == [ScriptStorage.configHandle] else {
                        throw ResourceError.rejected("config_object_scope_required")
                    }
                    // 0x6c22f4 invokes the host callback and marks the
                    // associated object at 0x6934ec. The host effect is pending.
                    candidate.configDisplayRefreshRequested = true
                    candidate.configDisplayNeedsHostUpdate = true
                    action = "config_display_refresh_host_unapplied_candidate"
                case "fs", "il":
                    try arity(1)
                    guard candidate.frames.last!.tableScope == [ScriptStorage.configHandle] else {
                        throw ResourceError.rejected("config_object_scope_required")
                    }
                    let operand = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                        write: { _,_ in throw ResourceError.rejected("mutating_config_operand_outside_profile") },
                        readIndexed: { try candidate.readIndexed($0,$1) })
                    guard let integer = operand.integer else { throw ResourceError.rejected("config_operand_requires_integer") }
                    let key = command == "fs" ? "FullScreen" : "Interlace"
                    let text = try candidate.configuration?.value(for: key)
                    let previous = candidate.configDisplayOverrides[key] ?? text.flatMap(ScriptExpression.integerTextCache) ?? 0
                    let value: Int32 = integer == 0 ? 0 : 1
                    if previous != value {
                        candidate.configDisplayOverrides[key] = value
                        candidate.configDisplayNeedsHostUpdate = true
                    }
                    action = "config_display_write_host_unapplied_candidate"
                case "?fs", "?il":
                    try arity(0)
                    guard candidate.frames.last!.tableScope == [ScriptStorage.configHandle] else {
                        throw ResourceError.rejected("config_object_scope_required")
                    }
                    // The original configuration loader reads each named
                    // integer with a zero fallback; the query returns that field.
                    let key = command == "?fs" ? "FullScreen" : "Interlace"
                    let text = try candidate.configuration?.value(for: key)
                    let value = candidate.configDisplayOverrides[key] ?? text.flatMap(ScriptExpression.integerTextCache) ?? 0
                    candidate.clearResultBindings()
                    try candidate.resultInteger(value)
                    action = command == "?fs" ? "config_fullscreen_query_candidate" : "config_interlace_query_candidate"
                case "?fcs":
                    try arity(0)
                    let scope = candidate.frames.last!.tableScope
                    candidate.clearResultBindings()
                    switch scope {
                    case [ScriptStorage.configHandle]:
                        // 0x4ffbe8 loads FormCloseSave with fallback 1; 0x6c410b returns it.
                        let value = try candidate.configuration?.value(for: "FormCloseSave")
                        try candidate.resultInteger(value.flatMap(ScriptExpression.integerTextCache) ?? 1)
                        action = "config_form_close_save_query_candidate"
                    case [ScriptStorage.systemHandle]:
                        // 0x6b3ddc selects the thread's stored filename.
                        let name = candidate.selectsPrimaryScriptSource
                            ? candidate.linkedPrimaryFormCloseSaveFilename ?? candidate.formCloseSaveFilename
                            : candidate.formCloseSaveFilename
                        try candidate.setConfigResultArray([.string(name)], string: true)
                        action = "system_form_close_filename_query_candidate"
                    default:
                        throw ResourceError.rejected("form_close_save_query_scope_unsupported")
                    }
                case "fcs":
                    try arity(1)
                    guard candidate.frames.last!.tableScope == [ScriptStorage.systemHandle] else {
                        throw ResourceError.rejected("form_close_filename_requires_system_scope")
                    }
                    candidate.formCloseSaveFilename = try callLabel()
                    action = "system_form_close_filename_candidate"
                case "ma", "ma2":
                    guard candidate.frames.last!.tableScope == [ScriptStorage.configHandle] else {
                        throw ResourceError.rejected("config_object_scope_required")
                    }
                    func alphaOperand(_ slot: Int) throws -> Int32 {
                        let value = try ScriptExpression.parse(field(slot)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_config_operand_outside_profile") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard let integer = value.integer else { throw ResourceError.rejected("config_operand_requires_integer") }
                        return integer
                    }
                    let keys = ["MessageAlpha", "MessageAlpha1", "MessageAlpha2", "MessageAlpha3"]
                    var updates: [(Int, Int32)] = []
                    if command == "ma2" {
                        try arity(2)
                        let index = min(3, max(0, try alphaOperand(0)))
                        updates.append((Int(index), try alphaOperand(1)))
                    } else {
                        guard (1...4).contains(record.fields.count) else { throw ResourceError.rejected("unsupported_command_arity") }
                        for slot in record.fields.indices where try !field(slot).isEmpty {
                            updates.append((slot, min(255, max(0, try alphaOperand(slot)))))
                        }
                    }
                    for (slot, value) in updates {
                        let key = keys[slot]
                        let text = try candidate.configuration?.value(for: key)
                        let previous = candidate.configMessageOverrides[key] ?? text.flatMap(ScriptExpression.integerTextCache) ?? 255
                        if previous != value {
                            candidate.configMessageOverrides[key] = value
                            // Native 0x6c1d7c invokes a host callback whose visual
                            // consequences have not yet been reconstructed.
                            candidate.configMessageAlphaNeedsRendering = true
                        }
                    }
                    action = "config_message_alpha_write_candidate"
                case "ms", "mtw", "mcw":
                    try arity(1)
                    guard candidate.frames.last!.tableScope == [ScriptStorage.configHandle] else {
                        throw ResourceError.rejected("config_object_scope_required")
                    }
                    let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                        write: { _,_ in throw ResourceError.rejected("mutating_config_operand_outside_profile") },
                        readIndexed: { try candidate.readIndexed($0,$1) })
                    guard let integer = value.integer else { throw ResourceError.rejected("config_operand_requires_integer") }
                    let key = command == "ms" ? "MessageSpeed" : (command == "mtw" ? "AutoPlayWaitTime" : "AutoPlayClickTime")
                    candidate.configMessageOverrides[key] = integer
                    action = "config_message_timing_write_candidate"
                case "?ma", "?ms", "?mtw":
                    try arity(0)
                    guard candidate.frames.last!.tableScope == [ScriptStorage.configHandle] else {
                        throw ResourceError.rejected("config_object_scope_required")
                    }
                    let keys: [String]
                    let fallback: Int32
                    switch command {
                    case "?ma": keys = ["MessageAlpha", "MessageAlpha1", "MessageAlpha2", "MessageAlpha3"]; fallback = 255
                    case "?ms": keys = ["MessageSpeed"]; fallback = 10
                    default: keys = ["AutoPlayWaitTime"]; fallback = 30
                    }
                    let values = try keys.map { key -> ScriptValue in
                        let text = try candidate.configuration?.value(for: key)
                        return .integer(candidate.configMessageOverrides[key] ?? text.flatMap(ScriptExpression.integerTextCache) ?? fallback)
                    }
                    candidate.clearResultBindings()
                    try candidate.setConfigResultArray(values, string: false)
                    action = "config_message_query_candidate"
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
                case "?vtv", "?vtm":
                    try arity(1)
                    guard candidate.frames.last!.tableScope == [ScriptStorage.configHandle] else {
                        throw ResourceError.rejected("config_object_scope_required")
                    }
                    let operand = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                        write: { _,_ in throw ResourceError.rejected("mutating_config_operand_outside_profile") },
                        readIndexed: { try candidate.readIndexed($0,$1) })
                    guard let index = operand.integer else {
                        throw ResourceError.rejected("config_operand_requires_integer")
                    }
                    let volume = command == "?vtv"
                    var value: Int32 = 0
                    if index >= (volume ? 0 : 1), index < 32 {
                        value = try candidate.configAudioSlot(index, volume: volume)
                    }
                    candidate.clearResultBindings()
                    try candidate.resultInteger(value)
                    action = volume ? "config_vtv_query_candidate" : "config_vtm_query_candidate"
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
                    // 0x6d3110 refreshes active channels only when the
                    // effective category table differs from the previous one.
                    if (0..<32).contains(index) {
                        let hasActive = candidate.soundChannels.values.contains { $0.playing }
                        var probe = ScriptStorage.SoundChannel()
                        probe.volumeType = index
                        let oldGain = hasActive ? try candidate.soundCategoryGain(probe) : nil
                        if command == "vtv" { candidate.configVoiceValues[index] = max(0,value) }
                        else { candidate.configVoiceModes[index] = value }
                        if let oldGain, oldGain != (try candidate.soundCategoryGain(probe)) {
                            for handle in candidate.soundChannels.keys where candidate.soundChannels[handle]?.playing == true {
                                let appliedType = candidate.soundChannels[handle]?.volumeType ?? 0
                                candidate.soundChannels[handle]?.appliedVolumeType = appliedType
                            }
                        }
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
                          candidate.buttons.contains(handle) || candidate.images[handle] != nil || candidate.bars[handle] != nil else {
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
                        if candidate.bars[handle] != nil { candidate.bars[handle]?.userIntegers[slot] = integer }
                        else { candidate.buttonUserIntegers[handle,default: [:]][slot] = integer }
                    }
                    action = candidate.bars[handle] != nil ? "bar_user_integer_candidate" :
                        (candidate.images[handle] != nil ? "image_user_integer_candidate" : "button_user_integer_candidate")
                case "?ui":
                    try arity(0)
                    guard candidate.frames.last!.tableScope.count == 1,
                          let handle = candidate.frames.last!.tableScope.first else {
                        throw ResourceError.rejected("user_integer_query_requires_single_scope")
                    }
                    let values: [Int: Int32]
                    if let bar = candidate.bars[handle] {
                        values = bar.userIntegers
                        action = "bar_user_integer_query_candidate"
                    } else if candidate.buttons.contains(handle) {
                        values = candidate.buttonUserIntegers[handle] ?? [:]
                        action = "button_user_integer_query_candidate"
                    } else if candidate.images[handle] != nil {
                        values = candidate.buttonUserIntegers[handle] ?? [:]
                        action = "image_user_integer_query_candidate"
                    } else {
                        throw ResourceError.rejected("user_integer_query_requires_button_or_bar")
                    }
                    candidate.clearResultBindings()
                    try candidate.setConfigResultArray((0..<4).map { .integer(values[$0] ?? 0) }, string: false)
                case "us":
                    guard (1...4).contains(record.fields.count) else {
                        throw ResourceError.rejected("unsupported_command_arity")
                    }
                    if candidate.frames.last!.tableScope.count == 1,
                       let handle = candidate.frames.last!.tableScope.first, var bar = candidate.bars[handle] {
                        for slot in record.fields.indices where try !field(slot).isEmpty {
                            let text = try callLabel(slot)
                            guard text.utf8.count <= 8192 else { throw ResourceError.rejected("bar_user_string_limit") }
                            bar.userStrings[slot] = text
                        }
                        candidate.bars[handle] = bar
                        action = "bar_user_string_candidate"
                        break
                    }
                    if candidate.frames.last!.tableScope.count == 1,
                       let handle = candidate.frames.last!.tableScope.first, candidate.images[handle] != nil {
                        for slot in record.fields.indices where try !field(slot).isEmpty {
                            let value = try callLabel(slot)
                            guard value.utf8.count <= 8192 else { throw ResourceError.rejected("image_user_string_limit") }
                            candidate.buttonUserStrings[handle, default: [:]][slot] = value
                        }
                        action = "image_user_string_candidate"
                        break
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
                    if !record.fields.isEmpty, try !field(0).isEmpty {
                        candidate.buttonScriptTargets.removeValue(forKey: handle)
                    }
                    guard record.fields.count == 1,
                          let label = candidate.buttonUserStrings[handle]?[0],
                          label.hasPrefix("@@") else { break }
                    candidate.buttonScriptTargets[handle] = label
                    if let destination = try? program.label(label) {
                        guard program.ancestors[destination].isEmpty else {
                            throw ResourceError.rejected("button_target_inside_control_block")
                        }
                        target = records[destination].location
                    }
                    action = "button_script_target_candidate"
                case "?us":
                    try arity(0)
                    guard candidate.frames.last!.tableScope.count == 1,
                          let handle = candidate.frames.last!.tableScope.first,
                          candidate.buttons.contains(handle) || candidate.images[handle] != nil else {
                        throw ResourceError.rejected("user_string_query_requires_image_or_button")
                    }
                    let values = candidate.buttonUserStrings[handle] ?? [:]
                    candidate.clearResultBindings()
                    try candidate.setConfigResultArray((0..<4).map { .string(values[$0] ?? "") }, string: true)
                    action = "image_or_button_user_string_query_candidate"
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
                    guard (1...2).contains(record.fields.count) else {
                        throw ResourceError.rejected("unsupported_command_arity")
                    }
                    let scope = candidate.frames.last!.tableScope
                    guard scope.count == 1, let handle = scope.first,
                          candidate.images[handle] != nil || candidate.buttons.contains(handle) else {
                        throw ResourceError.rejected("image_extended_value_requires_image_scope")
                    }
                    let operands = try record.fields.indices.map { slot in
                        try ScriptExpression.parse(field(slot)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_image_operand_outside_profile") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                    }
                    guard let index = operands[0].integer, (0..<32).contains(index),
                          let value = operands.count == 1 ? 0 : operands[1].integer else {
                        throw ResourceError.rejected("image_extended_value_outside_profile")
                    }
                    // 0x6c7d46 writes the numeric operand into the indexed extended slot.
                    if candidate.images[handle] != nil {
                        candidate.images[handle]?.extendedScalarValues[Int(index)] = value
                        action = "image_extended_value_write_candidate"
                    } else {
                        candidate.buttonExtendedScalarValues[handle, default: [:]][Int(index)] = value
                        action = "button_extended_value_write_candidate"
                    }
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
                    if let resource = image.resource, image.hasExtendedContainerMetadata {
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
                        candidate.ensureStreamChannel(stream)
                        let previous = candidate.soundChannels[stream]
                        if let previous {
                            let model: StreamVolumeFilterCandidate?
                            if filter.isEmpty {
                                model = nil
                            } else if let volume = previous.volumeFilterCandidate {
                                model = try? volume.updating(researchFilterText: filter)
                            } else if previous.filterRequestKnown && (previous.filterRequest ?? "").isEmpty {
                                model = try? StreamVolumeFilterCandidate(researchFilterText: filter)
                            } else {
                                // Restored or unsupported earlier filters do not supply reliable defaults.
                                model = nil
                            }
                            candidate.soundChannels[stream]?.volumeFilterCandidate = model
                            // A chain is reconstructible only when installed on a known empty channel.
                            if !filter.isEmpty, model == nil, previous.filterRequestKnown,
                               (previous.filterRequest ?? "").isEmpty,
                               ((try? StreamFilterChainCandidate(researchFilterText: filter)) != nil ||
                                (try? StreamTimeScaleCandidate.pitch(researchFilterText: filter)) != nil) {
                                candidate.soundChannels[stream]?.filterChainCandidateText = filter
                            } else {
                                candidate.soundChannels[stream]?.filterChainCandidateText = nil
                            }
                        }
                        if let previous, previous.playing {
                            let updated = candidate.soundChannels[stream]?.volumeFilterCandidate
                            let old = previous.volumeFilterCandidate
                            let oldChain = previous.filterChainCandidateText
                            let clearKnownChain = allowLiveSoundFilterChainHandoff && filter.isEmpty &&
                                previous.filterRequestKnown && oldChain != nil && previous.filterRequest == oldChain
                            let oldSupported = previous.filterRequestKnown &&
                                ((previous.filterRequest ?? "").isEmpty || old != nil || clearKnownChain)
                            let newSupported = filter.isEmpty || updated != nil
                            if allowLiveSoundFilterHandoff, oldSupported, newSupported,
                               let source = previous.resource, let playbackStep = previous.playbackStartStep {
                                if old != updated || clearKnownChain {
                                    soundFilterRequest = .init(channel: stream, source: source,
                                        playbackStep: playbackStep, previous: old, updated: updated,
                                        previousChain: clearKnownChain ? oldChain : nil)
                                    phase = .waitingForSoundFilter
                                }
                            } else if !filter.isEmpty || !previous.filterRequestKnown ||
                                        !(previous.filterRequest ?? "").isEmpty {
                                candidate.activeStreamFilterApplicationUnverified = true
                            }
                        }
                        candidate.soundChannels[stream]?.filterRequest = filter
                        candidate.soundChannels[stream]?.filterRequestKnown = true
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
                        candidate.images[handle]?.boundImageNames.removeValue(forKey: slot)
                        action = "image_slot_release_candidate"
                        break
                    }
                    let saveImagePrefix = "$$$saveimage,"
                    if imageBinding, asciiLower(path).hasPrefix(saveImagePrefix) {
                        let logical = asciiLower(path)
                        guard slot == 0, logical.hasSuffix(".bmp"),
                              logical.count > saveImagePrefix.count + 4 else {
                            throw ResourceError.rejected("save_thumbnail_binding_unavailable")
                        }
                        let key = Data(logical.dropFirst(saveImagePrefix.count).dropLast(4).utf8)
                        guard let thumbnail = candidate.sessionSaveThumbnails[key] else {
                            guard candidate.sessionSaveMetadata[key] != nil,
                                  asciiLower(container.sourceFile).hasSuffix("/script/saveload/thumimage.b") else {
                                throw ResourceError.rejected("save_thumbnail_binding_unavailable")
                            }
                            candidate.images[handle]?.boundImages.removeValue(forKey: slot)
                            action = "session_save_thumbnail_embedded_placeholder"
                            break
                        }
                        candidate.images[handle]?.boundImages[slot] = thumbnail
                        candidate.images[handle]?.boundImageNames[slot] = path
                        resourceLocation = thumbnail
                        action = "session_save_thumbnail_bind_candidate"
                        break
                    }
                    if command == "li", let range = try imageMemberLookup?(container, path) {
                        let member = ScriptLocation(sourceFile: container.sourceFile,sourceSHA256: container.sourceSHA256,
                            byteOffset: range.offset,byteLength: range.length,rangeSHA256: range.sha256,lineNumber: 1)
                        resourceLocation = member
                        if imageBinding {
                            candidate.images[handle]?.boundImages[slot] = member
                            candidate.images[handle]?.boundImageNames[slot] = path
                            action = "image_container_slot_bind_candidate"
                        } else {
                            candidate.buttonImages[handle,default: [:]][slot] = member
                            candidate.buttonImageNames[handle,default: [:]][slot] = path
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
                        candidate.images[handle]?.boundImageNames[slot] = path
                        action = "image_slot_bind_candidate"
                    } else if command == "li" {
                        candidate.buttonImages[handle,default: [:]][slot] = location
                        candidate.buttonImageNames[handle,default: [:]][slot] = path
                        action = "button_image_bind_candidate"
                    } else {
                        candidate.buttonSounds[handle,default: [:]][slot] = location
                        candidate.buttonSoundNames[handle,default: [:]][slot] = path
                        action = "button_sound_bind_candidate"
                    }
                case "t":
                    try arity(1)
                    guard candidate.frames.last!.tableScope.count == 1,
                          let handle = candidate.frames.last!.tableScope.first, candidate.timers[handle] != nil else {
                        throw ResourceError.rejected("timer_interval_requires_timer_scope")
                    }
                    let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                        write: { _,_ in throw ResourceError.rejected("mutating_timer_interval_operand") },
                        readIndexed: { try candidate.readIndexed($0,$1) })
                    guard let interval = value.integer else { throw ResourceError.rejected("timer_interval_requires_integer") }
                    // 0x6ac954 writes the interval field without enabling the timer.
                    guard interval > 0 else { throw ResourceError.rejected("timer_interval_outside_profile") }
                    candidate.timers[handle]?.interval = interval
                    candidate.timers[handle]?.elapsed = 0
                    action = "timer_interval_candidate"
                case "?vtn":
                    guard candidate.frames.last!.tableScope.count == 1,
                          let handle = candidate.frames.last!.tableScope.first,
                          ScriptStorage.isDirectSoundHandle(handle) else {
                        throw ResourceError.rejected("direct_sound_type_query_requires_scope")
                    }
                    try arity(0)
                    candidate.clearResultBindings()
                    try candidate.resultInteger(candidate.directSoundChannels[handle]?.volumeType ?? 0)
                    action = "direct_sound_type_query_candidate"
                case "?vi":
                    try arity(0)
                    let scope = candidate.frames.last!.tableScope
                    guard scope.count == 1, let handle = scope.first, let bar = candidate.bars[handle] else {
                        throw ResourceError.rejected("bar_inverse_value_requires_single_scope")
                    }
                    // 0x6cc138–0x6cc141 subtracts the current target from the maximum.
                    candidate.clearResultBindings()
                    try candidate.resultInteger(bar.maximum &- bar.value)
                    action = "bar_inverse_value_query_candidate"
                case "l", "?v":
                    if command == "?v", candidate.frames.last!.tableScope.count == 1,
                       let handle = candidate.frames.last!.tableScope.first, ScriptStorage.isDirectSoundHandle(handle) {
                        try arity(0)
                        candidate.clearResultBindings()
                        try candidate.resultInteger(candidate.directSoundChannels[handle]?.volume ?? 256)
                        action = "direct_sound_volume_query_candidate"
                        break
                    }
                    if command == "?v", candidate.frames.last!.tableScope.count == 1,
                       let handle = candidate.frames.last!.tableScope.first, let bar = candidate.bars[handle] {
                        try arity(0)
                        candidate.clearResultBindings()
                        try candidate.resultInteger(bar.value)
                        action = "bar_value_query_candidate"
                        break
                    }
                    let loadScope = candidate.frames.last!.tableScope
                    let linkedLogLoad = loadScope == [ScriptStorage.temporaryDataHandle] && linkedLogJumpCheckpoints != nil
                    var memoryStream: Data?
                    if command == "l", loadScope == [ScriptStorage.memoryDataHandle] ||
                        loadScope == [ScriptStorage.temporaryDataHandle] {
                        try arity(1)
                        let name = try callLabel()
                        let key = Data(asciiLower(name).utf8)
                        let usesMemory = loadScope == [ScriptStorage.memoryDataHandle]
                        if linkedLogLoad {
                            guard candidate.selectsPrimaryScriptSource else {
                                throw ResourceError.rejected("linked_log_jump_requires_primary_target")
                            }
                            pendingMemoryCheckpointRestore = nil
                            savedExecutionCandidate = nil
                            saveResumeBoundary = nil
                        }
                        if usesMemory {
                            guard memoryCheckpoints[key] == nil else {
                                throw ResourceError.rejected("memory_checkpoint_restore_unsupported")
                            }
                            if let index = candidate.serializedMemoryCheckpointIndex(named: name) {
                                memoryStream = candidate.serializedMemoryCheckpoints[index].stream
                            }
                        } else if let checkpoint = (linkedLogJumpCheckpoints ?? logJumpCheckpoints).first(where: { $0.key == key }) {
                            guard let stream = checkpoint.stream else {
                                throw ResourceError.rejected("temporary_checkpoint_restore_unsupported")
                            }
                            memoryStream = stream
                        }
                        if memoryStream == nil {
                            // 0x6cc73e initializes the result to zero; only a successful restore sets it to one.
                            candidate.clearResultBindings()
                            try candidate.resultInteger(0)
                            action = usesMemory ? "memory_checkpoint_restore_not_found" : "temporary_checkpoint_restore_not_found"
                            break
                        }
                    }
                    if command == "l", loadScope == [ScriptStorage.saveDataHandle] || memoryStream != nil {
                        let retainCandidate = retainExperimentalSaveCandidate || memoryStream != nil
                        savedDisplayPreview = nil
                        saveResumeBoundary = nil
                        savedExecutionCandidate = nil
                        var bytes: Data?
                        var template: Data?
                        if let memoryStream {
                            pendingMemoryCheckpointRestore = loadScope == [ScriptStorage.temporaryDataHandle] ? .temporary : .memory
                            // The named container holds the same checked stream as the disk loader.
                            guard let saveHeaderTemplate else {
                                throw ResourceError.rejected("memory_checkpoint_header_template_unavailable")
                            }
                            template = saveHeaderTemplate
                            bytes = memoryStream
                        } else {
                            // Keep disk task provenance separate from its eventual stop reason.
                            failedSaveRestore = true
                            try arity(1)
                            let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                                write: { _,_ in throw ResourceError.rejected("mutating_save_operand_outside_profile") },
                                readIndexed: { try candidate.readIndexed($0,$1) })
                            guard case .string(let name) = value, try candidate.containsSessionSave(name) else {
                                throw ResourceError.rejected("save_restore_slot_unavailable")
                            }
                            if let directory = saveDirectory,
                               let source = saveSources[Data(asciiLower(name).utf8)] {
                                let diskBytes = try directory.read(source.name, limit: SaveEnvelope.maxFileBytes)
                                guard diskBytes.sha256Hex == source.sha256 else {
                                    throw ResourceError.rejected("save_restore_slot_changed")
                                }
                                bytes = diskBytes
                                template = source.verifyHeader ? saveHeaderTemplate : nil
                            }
                        }
                        if let bytes {
                            let inferred = inferSaveStateSeed ? try SaveEnvelope(bytes).slot?.transformed == true : false
                            let seed = try template.map { try SaveEnvelope.validatedSlotSeed(bytes, clearTemplate: $0) }
                            let state = try SaveEnvelope.decodeSlotState(bytes, seed: seed, inferSeed: inferred)
                            let cursor = try SaveReaderCursor(playbackState: state)
                            guard inspectSaveRestoreBoundary else {
                                guard cursor.routines.count <= maximumFrames else {
                                    throw ResourceError.rejected("saved_return_frame_limit")
                                }
                                _ = try cursor.validateRoutinePayloads(in: state)
                                let emptyLineText = try cursor.emptyLineText.utf16Text(in: state)
                                if var pinned = candidateRepository {
                                    _ = try cursor.resolveResumeInstruction(in: state, repository: &pinned)
                                    for routine in cursor.routines.dropFirst() {
                                        guard let block = routine.controlBlocks.first, block.rawState == 1 else {
                                            throw ResourceError.rejected("saved_return_block_unavailable")
                                        }
                                        let (_, instruction, _, _, _, _) = try SaveReaderCursor.routineReturnPosition(
                                            block, in: state, repository: &pinned,
                                            emptyLineText: emptyLineText)
                                        guard instruction != nil else {
                                            throw ResourceError.rejected("saved_return_not_command_boundary")
                                        }
                                    }
                                }
                                throw ResourceError.rejected("save_restore_execution_state_unsupported")
                            }
                            let snapshotCount = try cursor.validateRoutinePayloads(in: state)
                            saveResumeBoundary = SaveResumeBoundary(routineCount: cursor.routines.count,
                                resultSnapshotCount: snapshotCount,
                                controlBlockCount: cursor.routines.reduce(0) { $0 + $1.controlBlocks.count },
                                unresolvedResultObjectReferenceCount: cursor.routines.reduce(0) {
                                    $0 + $1.nonEmptyResultObjectReferenceCount
                                }, variableArrays: nil)
                            saveResumeBoundary?.unresolvedResultButtonReferenceCount = cursor.routines.count {
                                ($0.resultButtonReference?.length ?? 0) > 0
                            }
                            if inferred { saveResumeBoundary?.stateSeedInference = .inferred }
                            if template != nil { saveResumeBoundary?.slotHeaderVerification = .verified }
                            var resumeInstruction: (program: ScriptProgram, index: Int, anchor: ScriptLocation)?
                            var savedReturns: [(program: ScriptProgram, index: Int, anchor: ScriptLocation)] = []
                            if var pinned = candidateRepository {
                                if cursor.routines.count > 1 {
                                    var returnRepository = pinned
                                    // The native return path uses block zero of the first removed routine.
                                    let returns: [SaveResumeBoundary.RoutineReturnCandidate] = cursor.routines.dropFirst().enumerated().map { index, routine in
                                        let block = routine.controlBlocks.first
                                        guard index < maximumFrames else {
                                            return .init(routineOffset: routine.decodedOffset, blockOffset: block?.decodedOffset,
                                                location: nil, instructionIndex: nil, status: .notTested,
                                                resolution: "not_tested_frame_limit",
                                                scope: "pinned local source boundary; original-engine execution equivalence not_tested",
                                                issue: "saved_return_frame_limit")
                                        }
                                        guard let block, block.rawState == 1 else {
                                            return .init(routineOffset: routine.decodedOffset, blockOffset: block?.decodedOffset,
                                                location: nil, instructionIndex: nil, status: .unsupported,
                                                resolution: "unsupported_control_block_state",
                                                scope: "pinned local source boundary; original-engine execution equivalence not_tested",
                                                issue: "saved_return_block_unavailable")
                                        }
                                        do {
                                            let (position, instruction, returnProgram, returnAnchor, returnStatus, resolution) = try SaveReaderCursor.routineReturnPosition(
                                                block, in: state, repository: &returnRepository,
                                                emptyLineText: try cursor.emptyLineText.utf16Text(in: state))
                                            if let instruction {
                                                savedReturns.append((returnProgram, instruction, returnAnchor))
                                            }
                                            return .init(routineOffset: routine.decodedOffset, blockOffset: block.decodedOffset,
                                                location: position, instructionIndex: instruction, status: returnStatus,
                                                resolution: resolution,
                                                scope: "pinned local source-record mapping only; original-engine execution equivalence not_tested",
                                                issue: instruction == nil ? "saved_return_not_command_boundary" : nil)
                                        } catch {
                                            return .init(routineOffset: routine.decodedOffset, blockOffset: block.decodedOffset,
                                                location: nil, instructionIndex: nil, status: .unsupported,
                                                resolution: "resolution_failed",
                                                scope: "pinned local source-record mapping only; original-engine execution equivalence not_tested",
                                                issue: String(describing: error))
                                        }
                                    }
                                    saveResumeBoundary?.routineReturnCandidates = returns
                                }
                                do {
                                    let resolved = try cursor.resolveResumeInstruction(in: state, repository: &pinned)
                                    let index = resolved.index
                                    resumeInstruction = (resolved.program, index, resolved.location)
                                    saveResumeBoundary?.instructionIndex = index
                                    saveResumeBoundary?.location = resolved.program.document.records[index].location
                                    let ancestors = resolved.program.ancestors[index]
                                    saveResumeBoundary?.controlDepth = ancestors.count
                                    if cursor.routines.count == 1, let routine = cursor.routines.first,
                                       !routine.controlBlocks.isEmpty || !ancestors.isEmpty {
                                        let staticFamilies = ancestors.map { resolved.program.blocks[$0]?.family }
                                        let savedFamilies = routine.controlBlocks.map(\.declaredControlFamily)
                                        let familiesMatch = staticFamilies == savedFamilies && !savedFamilies.contains(nil)
                                        let issue: String?
                                        if !familiesMatch {
                                            issue = "save_control_families_do_not_align"
                                        } else if !zip(ancestors, routine.controlBlocks).allSatisfy({ start, block in
                                            guard block.rawState == 3 || block.rawState == 9 else { return true }
                                            return block.matchesThreeFieldLoop(resolved.program.document.records[start].fields)
                                        }) {
                                            issue = "saved_loop_options_do_not_match_supported_source"
                                        } else {
                                            issue = nil
                                        }
                                        saveResumeBoundary?.controlAlignment = .init(
                                            savedBlockOffsets: routine.controlBlocks.map(\.decodedOffset),
                                            staticBlockLocations: ancestors.map { resolved.program.document.records[$0].location },
                                            status: issue == nil ? .inferred : .unsupported, issue: issue)
                                    }
                                    if let root = cursor.routines.count == 1 ? cursor.routines.first : nil {
                                        let loops = root.controlBlocks.filter { $0.rawState == 3 || $0.rawState == 9 }
                                        if !loops.isEmpty {
                                            saveResumeBoundary?.loopReturnCandidateOmittedCount = max(0, loops.count - 64)
                                            saveResumeBoundary?.loopReturnCandidates = loops.prefix(64).map { block in
                                                do {
                                                    let candidate = try SaveReaderCursor.controlPosition(block, in: state,
                                                        reader: cursor, anchor: resolved.location, program: resolved.program)
                                                    return .init(blockOffset: block.decodedOffset, location: candidate,
                                                                 status: .inferred, issue: nil)
                                                } catch {
                                                    return .init(blockOffset: block.decodedOffset, location: nil,
                                                                 status: .unsupported, issue: String(describing: error))
                                                }
                                            }
                                        }
                                    }
                                    saveResumeBoundary?.status = .verified
                                } catch {
                                    saveResumeBoundary?.cursorIssue = String(describing: error)
                                }
                            } else {
                                saveResumeBoundary?.cursorIssue = "save_reader_repository_unavailable"
                            }
                            // Native mode 3 polls routine +0x50 for zero without rerunning wait.
                            let timedWaits = cursor.routines.filter { $0.rawState == 3 }.map { routine in
                                SaveResumeBoundary.SavedTimedWait(routineOffset: routine.decodedOffset,
                                    remaining: routine.waitTime, skipTime: routine.skipTime,
                                    status: routine.waitTime >= 0 ? .verified : .unsupported)
                            }
                            if !timedWaits.isEmpty { saveResumeBoundary?.savedTimedWaits = timedWaits }
                            if cursor.nextDecodedOffset < state.count {
                                let prefix = try SaveStatePrefix(state: state, after: cursor)
                                saveResumeBoundary?.statePrefix = prefix
                                // ssSndTimer (0x6bbb14) queries the stream bank using routine +0x5c.
                                let soundWaits = cursor.routines.filter { $0.rawState == 6 }.map { routine in
                                    let index = Int(routine.channel)
                                    let streamOffset = prefix.ssndReferences.indices.contains(index)
                                        ? prefix.ssndReferences[index].record.decodedOffset : nil
                                    return SaveResumeBoundary.SavedSoundWait(routineOffset: routine.decodedOffset,
                                        channel: routine.channel, rawTarget: routine.waitTime,
                                        streamRecordOffset: streamOffset, status: streamOffset == nil ? .unsupported : .inferred)
                                }
                                if !soundWaits.isEmpty { saveResumeBoundary?.savedSoundWaits = soundWaits }
                                if let repository = candidateRepository {
                                    saveResumeBoundary?.directSoundResources = prefix.soundResources(in: state, repository: repository)
                                    saveResumeBoundary?.streamedSoundResources = prefix.soundResources(in: state, repository: repository, streamed: true)
                                }
                                let displayState = try prefix.inspectDisplayState(in: state)
                                let offset = displayState.calValOffset
                                let imageLibraries = displayState.imageLibraries
                                let display = displayState.display
                                saveResumeBoundary?.imageLibraries = imageLibraries
                                saveResumeBoundary?.savedDisplay = display
                                if let rect = display.proceduralRect, display.postReplacementReloadRequested == false {
                                    savedDisplayPreview = .rectangle(rect)
                                }
                                if let reference = display.nestedImageLibrarySource, var repository = candidateRepository {
                                    do {
                                        let path = try reference.utf16Text(in: state)
                                        guard path.utf8.count <= 4096 else {
                                            throw ResourceError.rejected("saved_display_resource_name_outside_profile")
                                        }
                                        if asciiLower(path).hasPrefix("rect,") {
                                            saveResumeBoundary?.nestedDisplayResourceCheck = .init(status: .unsupported,
                                                issue: display.proceduralRectIssue ?? "saved_display_procedural_rect_unrestored")
                                        } else {
                                            let (source, data) = try repository.readResource(path, byteLimit: 16 * 1024 * 1024)
                                            let signature = InventoryScanner.signature(Data(data.prefix(16)))
                                            saveResumeBoundary?.nestedDisplayResourceCheck = .init(status: .inferred,
                                                sourceSHA256: source.sourceSHA256, signature: signature)
                                        }
                                    } catch {
                                        saveResumeBoundary?.nestedDisplayResourceCheck = .init(status: .unsupported,
                                            issue: String(describing: error))
                                    }
                                }
                                if let reload = display.externalReload {
                                    var check = SaveResumeBoundary.DisplayResourceCheck(status: .notTested,
                                        issue: "saved_display_repository_unavailable")
                                    if var repository = candidateRepository {
                                        var sourceSHA256: String?
                                        do {
                                            let (source, data) = try reload.readImage(in: state, repository: &repository)
                                            sourceSHA256 = source.sourceSHA256
                                            if let loader = imageLoader {
                                                let (width, height, _) = try loader(data)
                                                check = .init(status: .inferred, sourceSHA256: sourceSHA256,
                                                              width: width, height: height)
                                                savedDisplayPreview = .externalImage(data, reload.transform)
                                            } else {
                                                check = .init(status: .notTested, sourceSHA256: sourceSHA256,
                                                              issue: "saved_display_decoder_unavailable")
                                            }
                                        } catch {
                                            check = .init(status: .unsupported, sourceSHA256: sourceSHA256,
                                                          issue: String(describing: error))
                                        }
                                    }
                                    saveResumeBoundary?.displayResourceCheck = check
                                }

                                let embeddedSlots = imageLibraries.flatMap(\.slots).filter { $0.embeddedLength != 0 }
                                let displaySurfaces = display.surfaces
                                if !embeddedSlots.isEmpty || !displaySurfaces.isEmpty {
                                    var remainingBytes = 32 * 1024 * 1024
                                    let loader = imageLoader
                                    func check(_ slot: SaveStatePrefix.ImageLibrarySummary.Slot) -> SaveResumeBoundary.EmbeddedImageCheck {
                                        let offset = slot.embeddedOffset
                                        guard let signature = slot.embeddedSignature,
                                              ["PNG", "JPEG", "BMP", "DPNG", "ARGB"].contains(signature) else {
                                            return .init(decodedOffset: offset, status: .unsupported,
                                                         issue: "saved_embedded_image_format_unsupported")
                                        }
                                        guard SaveStatePrefix.imageDecoder(slot.nativeDecoder, accepts: signature) else {
                                            return .init(decodedOffset: offset, status: .unsupported,
                                                         issue: "saved_embedded_image_native_decoder_mismatch")
                                        }
                                        guard let loader else {
                                            return .init(decodedOffset: offset, status: .notTested,
                                                         issue: "saved_embedded_image_decoder_unavailable")
                                        }
                                        guard slot.embeddedLength <= min(16 * 1024 * 1024, remainingBytes) else {
                                            return .init(decodedOffset: offset, status: .unsupported,
                                                         issue: "saved_embedded_image_decode_budget")
                                        }
                                        remainingBytes -= slot.embeddedLength
                                        do {
                                            let start = state.startIndex + offset
                                            let payload = state[start..<(start + slot.embeddedLength)]
                                            let header = signature == "ARGB" ? try SaveStatePrefix.ARGBHeader(payload) : nil
                                            do {
                                                let (width, height, _) = try loader(Data(payload))
                                                return .init(decodedOffset: offset, status: .verified, width: width, height: height,
                                                             argbHeader: header)
                                            } catch {
                                                return .init(decodedOffset: offset, status: .unsupported,
                                                             issue: String(describing: error), argbHeader: header)
                                            }
                                        } catch {
                                            return .init(decodedOffset: offset, status: .unsupported, issue: String(describing: error))
                                        }
                                    }
                                    if !displaySurfaces.isEmpty {
                                        let checks = displaySurfaces.map(check)
                                        saveResumeBoundary?.displaySurfaceChecks = checks
                                        // Mode 1 dispatches to 0x692a70 and submits the +0x20 surface (slot 0).
                                        if display.rawMode == 1,
                                           let index = displaySurfaces.firstIndex(where: { $0.index == 0 }),
                                           checks[index].status == .verified, checks[index].width == 1280,
                                           checks[index].height == 720 {
                                            let slot = displaySurfaces[index]
                                            let start = state.startIndex + slot.embeddedOffset
                                            savedDisplayPreview = .capturedSurface(Data(state[start..<(start + slot.embeddedLength)]))
                                        }
                                    }
                                    if !embeddedSlots.isEmpty {
                                        saveResumeBoundary?.embeddedImageChecks = embeddedSlots.map(check)
                                    }
                                }

                                let arrays = try SaveVariableArrays.readCalVal(state: state, at: offset)
                                let root = cursor.routines.count == 1 ? cursor.routines.first : nil
                                let rootReferences = try Set((root?.resultObjectReferences ?? []).filter { $0.length != 0 }
                                    .map { Data(asciiLower(try $0.utf16Text(in: state)).utf8) })
                                var shadowed = Set<Data>()
                                var indexedGroups: [SaveResumeBoundary.IndexedScalarGroup] = []
                                let frameLocalLimit = min(cursor.routines.count, maximumFrames)
                                var frameLocals: [Int: [Data: ScriptBinding]] = [:]
                                var frameAliases: [Int: Set<Data>] = [:]
                                var frameAliasReferences: [Int: [Data: [String?]]] = [:]
                                let summary = try arrays.summary(in: state, at: offset) { slot, decodedOffset, group in
                                    if !rootReferences.isEmpty {
                                        for record in group.records {
                                            let key = Data(asciiLower(record.textFields[0]).utf8)
                                            if rootReferences.contains(key) { shadowed.insert(key) }
                                        }
                                    }
                                    do {
                                        var storage = try ScriptStorage.stageSavedGlobalScalars(group)
                                        _ = try storage.stageSavedGlobalTextObjects(group)
                                        _ = try storage.stageSavedSoundAliases(group)
                                        _ = try storage.stageSavedObjectAliasReferences(group)
                                        let complete = storage.global.count == group.records.count
                                        if slot < frameLocalLimit, complete {
                                            frameLocals[slot] = storage.global
                                            frameAliases[slot] = storage.globalObjectAliases
                                            frameAliasReferences[slot] = storage.globalAliasReferences
                                        }
                                        indexedGroups.append(.init(slot: slot, decodedOffset: decodedOffset,
                                                                   scalarCount: storage.global.count - storage.globalObjectAliases.count,
                                                                   status: complete ? (storage.globalObjectAliases.isEmpty ? .verified : .inferred) : .unsupported,
                                                                   issue: complete ? nil : "save_indexed_nonscalar_bindings_unrestored"))
                                    } catch {
                                        indexedGroups.append(.init(slot: slot, decodedOffset: decodedOffset,
                                                                   scalarCount: nil, status: .unsupported,
                                                                   issue: String(describing: error)))
                                    }
                                }
                                let indexedFrameScalarsAvailable = summary.indexed.status != .unsupported &&
                                    ((summary.indexed.groupCount ?? 0) == 0 ||
                                     (summary.indexed.groupCount == cursor.routines.count &&
                                      frameLocals.count == cursor.routines.count))
                                if summary.indexed.groupSpans != nil {
                                    saveResumeBoundary?.indexedScalarGroups = indexedGroups
                                }
                                saveResumeBoundary?.variableArrays = summary
                                var savedTextureData: [ScriptLocation: Data] = [:]
                                var savedButtonSounds: [Int: [Int32: ScriptLocation]] = [:]
                                var savedVisualResources: [Int: ScriptStorage.SavedImageResource] = [:]
                                if !summary.buttonPayloads.isEmpty || !summary.imagePayloads.isEmpty || !summary.messagePayloads.isEmpty {
                                    var remaining = 32 * 1024 * 1024
                                    func checkImage(offset: Int, source: SaveReaderCursor.Reference?)
                                        -> SaveResumeBoundary.SavedButtonImageCheck {
                                        var result: SaveResumeBoundary.NestedDisplayResourceCheck
                                        var sourceName: String?
                                        var sourceNameSHA256: String?
                                        if let reference = source, var repository = candidateRepository {
                                            do {
                                                guard remaining > 0 else {
                                                    throw ResourceError.rejected("saved_button_image_read_budget")
                                                }
                                                let path = try reference.utf16Text(in: state)
                                                sourceName = path
                                                sourceNameSHA256 = Data(path.utf8).sha256Hex
                                                guard path.utf8.count <= 4096 else {
                                                    throw ResourceError.rejected("saved_button_image_name_outside_profile")
                                                }
                                                let (source, bytes) = try repository.readResource(path,
                                                    byteLimit: min(16 * 1024 * 1024, remaining))
                                                remaining -= bytes.count
                                                let signature = InventoryScanner.signature(Data(bytes.prefix(16)))
                                                result = .init(status: .inferred, sourceSHA256: source.sourceSHA256,
                                                               signature: signature)
                                                if let imageLoader, let (width, height, memberCount) = try? imageLoader(bytes) {
                                                    let location = ScriptLocation(
                                                        sourceFile: source.sourceFile, sourceSHA256: source.sourceSHA256,
                                                        byteOffset: 0, byteLength: bytes.count,
                                                        rangeSHA256: source.sourceSHA256, lineNumber: 1)
                                                    let theoraDimensions = bytes.starts(with: Data("OggS".utf8))
                                                        ? try? ScriptMovieHeader.theoraDimensions(bytes) : nil
                                                    if bytes.starts(with: Data("OggS".utf8)) {
                                                        guard let theoraDimensions, memberCount == 1,
                                                              theoraDimensions.0 == width, theoraDimensions.1 == height else {
                                                            throw ResourceError.rejected("theora_image_header_dimensions_mismatch")
                                                        }
                                                    }
                                                    let motionCount = theoraDimensions == nil ? imageMotionNames?(location)?.count : 1
                                                    let motionOnly = width == 0 && height == 0 && memberCount == 0 &&
                                                        (motionCount ?? 0) > 0
                                                    if motionOnly || ((1...8192).contains(width) && (1...8192).contains(height)) {
                                                        savedVisualResources[offset] = .init(location: location, resourceName: path,
                                                            width: width,
                                                            height: height, memberCount: memberCount,
                                                            hasExtendedContainerMetadata: bytes.starts(with: Data("abmp12".utf8)),
                                                            isTheoraResource: theoraDimensions != nil,
                                                            motionCount: motionCount,
                                                            motionUpdateThreshold: savedMotionUpdateThreshold?(location),
                                                            standaloneVideoDuration: theoraDimensions != nil
                                                                && path.lowercased().hasSuffix(".ogv")
                                                                ? try? ScriptMovieHeader.standaloneTheoraDuration(bytes) : nil)
                                                    } else {
                                                        result.issue = "saved_button_image_decoder_or_dimensions"
                                                    }
                                                } else {
                                                    result.issue = "saved_button_image_decoder_or_dimensions"
                                                }
                                            } catch {
                                                result = .init(status: .unsupported, issue: String(describing: error))
                                            }
                                            result.sourceName = sourceName
                                            result.sourceNameSHA256 = sourceNameSHA256
                                        } else {
                                            result = .init(status: .notTested, issue: source == nil
                                                ? "saved_button_image_source_absent" : "saved_button_image_repository_unavailable")
                                        }
                                        return SaveResumeBoundary.SavedButtonImageCheck(objectDecodedOffset: offset, resource: result)
                                    }
                                    if !summary.buttonPayloads.isEmpty {
                                        let checks = summary.buttonPayloads.map { checkImage(offset: $0.decodedOffset, source: $0.imageSource) }
                                        saveResumeBoundary?.savedButtonImageChecks = checks
                                        func soundPath(_ path: String, catalog: ScriptModuleCatalog) throws -> String {
                                            guard path.hasPrefix("..") else { return path }
                                            guard let source = resumeInstruction?.program.document.source.relativePath else {
                                                throw ResourceError.rejected("saved_button_sound_module_unresolved")
                                            }
                                            return try catalog.relativeResourcePath(path, currentSourceFile: source)
                                        }
                                        var soundChecks: [SaveResumeBoundary.SavedTextureBindingCheck] = []
                                        for button in summary.buttonPayloads {
                                            for (slot, name) in button.soundNames.prefix(2).enumerated() where name.length > 0 {
                                                let offset = button.decodedOffset
                                                guard name.length <= 8192, remaining > 0,
                                                      let path = try? name.utf16Text(in: state),
                                                      var repository = candidateRepository,
                                                      let logical = try? soundPath(path, catalog: repository.catalog),
                                                      let (reference, bytes) = try? repository.readResource(logical,
                                                        byteLimit: min(remaining, 8 * 1024 * 1024)) else {
                                                    soundChecks.append(.init(objectOffset: offset, slot: slot,
                                                        status: .unsupported, issue: "saved_button_sound_source_unresolved"))
                                                    continue
                                                }
                                                remaining -= bytes.count
                                                guard bytes.count >= 12, bytes.prefix(4) == Data("RIFF".utf8),
                                                      bytes.dropFirst(8).prefix(4) == Data("WAVE".utf8) else {
                                                    soundChecks.append(.init(objectOffset: offset, slot: slot,
                                                        status: .unsupported, issue: "saved_button_sound_requires_wave"))
                                                    continue
                                                }
                                                savedButtonSounds[offset, default: [:]][Int32(slot)] =
                                                    reference.wholeFileLocation(byteLength: bytes.count)
                                                soundChecks.append(.init(objectOffset: offset, slot: slot, status: .inferred, issue: nil))
                                            }
                                        }
                                        if !soundChecks.isEmpty { saveResumeBoundary?.savedButtonSoundBindings = soundChecks }
                                    }
                                    if !summary.imagePayloads.isEmpty {
                                        saveResumeBoundary?.savedImageFixedRecords = summary.imagePayloads.map(\.fixedRecord)
                                        saveResumeBoundary?.savedImageVisibility = summary.imagePayloads.map {
                                            .init(objectDecodedOffset: $0.decodedOffset,
                                                  drawGateDecodedOffset: $0.fixedRecord.decodedOffset + 0x9f9,
                                                  enableFlagDecodedOffset: $0.fixedRecord.decodedOffset + 0x9fa,
                                                  drawGate: $0.drawGate, enableFlag: $0.enableFlag)
                                        }
                                        saveResumeBoundary?.savedImageStaticPlacements = Dictionary(uniqueKeysWithValues:
                                            summary.imagePayloads.compactMap { image in
                                                image.staticPlacement.map { (image.decodedOffset, $0) }
                                            })
                                        let checks = summary.imagePayloads.map { image in
                                            if SaveVariableArrays.ImagePayload.hasVerifiedEmptyFileResource(
                                                source: image.imageSource, textureSlots: image.textureSlots) {
                                                return SaveResumeBoundary.SavedButtonImageCheck(
                                                    objectDecodedOffset: image.decodedOffset,
                                                    resource: .init(status: .verified,
                                                        resolution: "empty_filename_and_no_serialized_texture_slots"))
                                            }
                                            return checkImage(offset: image.decodedOffset, source: image.imageSource)
                                        }
                                        saveResumeBoundary?.savedImageResourceChecks = checks
                                    }
                                    if !summary.messagePayloads.isEmpty {
                                        let checks = summary.messagePayloads.map { message in
                                            if SaveVariableArrays.MessagePayload.hasVerifiedEmptyFileResource(
                                                source: message.imageSource, textureSlots: message.textureSlots) {
                                                return SaveResumeBoundary.SavedButtonImageCheck(
                                                    objectDecodedOffset: message.decodedOffset,
                                                    resource: .init(status: .verified,
                                                        resolution: "empty_filename_and_no_serialized_texture_slots"))
                                            }
                                            return checkImage(offset: message.decodedOffset, source: message.imageSource)
                                        }
                                        saveResumeBoundary?.savedMessageResourceChecks = checks
                                        saveResumeBoundary?.savedMessageTextChecks = summary.messagePayloads.map { message in
                                            do {
                                                let text = try message.primaryText(in: state)
                                                return .init(objectDecodedOffset: message.decodedOffset, status: .inferred,
                                                    displayedUTF16Units: text.displayed.utf16.count,
                                                    pendingUTF16Units: text.pending.utf16.count,
                                                    displayedOperationCount: text.displayedOutput.count,
                                                    pendingOperationCount: text.pendingOutput.count, issue: nil)
                                            } catch {
                                                return .init(objectDecodedOffset: message.decodedOffset, status: .unsupported,
                                                    displayedUTF16Units: nil, pendingUTF16Units: nil,
                                                    displayedOperationCount: nil, pendingOperationCount: nil,
                                                    issue: String(describing: error))
                                            }
                                        }
                                    }
                                    if !summary.buttonPayloads.isEmpty || !summary.imagePayloads.isEmpty || !summary.messagePayloads.isEmpty {
                                        // The original reload pass calls 0x5ae808 for named slots 0–31.
                                        // Only the player's existing ordinary raster binding is staged here.
                                        let owners = summary.imagePayloads.map { ($0.decodedOffset, $0.textureSlots) } +
                                            summary.buttonPayloads.map { ($0.decodedOffset, $0.textureSlots.filter { (0...1).contains($0.index) }) } +
                                            summary.messagePayloads.map { ($0.decodedOffset, $0.textureSlots.filter { (0...1).contains($0.index) }) }
                                        let bindings = owners.flatMap { offset, slots in
                                            slots.map { slot -> SaveResumeBoundary.SavedTextureBindingCheck in
                                                guard savedVisualResources[offset] != nil, (0..<32).contains(slot.index),
                                                      let name = slot.name, name.length <= 8192, remaining > 0,
                                                      let path = try? name.utf16Text(in: state) else {
                                                    return .init(objectOffset: offset, slot: slot.index, status: .unsupported,
                                                                 issue: "saved_texture_slot_or_source_unresolved")
                                                }
                                                let bytes: Data
                                                let location: ScriptLocation
                                                if slot.embeddedLength > 0 {
                                                    let suffix = asciiLower((path as NSString).pathExtension)
                                                    let expected = SaveStatePrefix.imageDecoder(for: path)
                                                    guard let expected, slot.embeddedLength <= min(remaining, 16 * 1024 * 1024),
                                                          slot.embeddedOffset >= 0, slot.embeddedOffset <= state.count,
                                                          slot.embeddedLength <= state.count - slot.embeddedOffset else {
                                                        return .init(objectOffset: offset, slot: slot.index, status: .unsupported,
                                                                     issue: "saved_embedded_texture_bounds_or_decoder")
                                                    }
                                                    let start = state.startIndex + slot.embeddedOffset
                                                    bytes = Data(state[start..<(start + slot.embeddedLength)])
                                                    guard SaveStatePrefix.imageDecoder(expected, accepts: InventoryScanner.signature(Data(bytes.prefix(16)))) else {
                                                        return .init(objectOffset: offset, slot: slot.index, status: .unsupported,
                                                                     issue: "saved_embedded_texture_signature_mismatch")
                                                    }
                                                    let digest = bytes.sha256Hex
                                                    location = ScriptModuleReference(logicalPath: "saved-texture/\(digest).\(suffix)",
                                                        sourceFile: "saved-texture/\(digest).\(suffix)", sourceSHA256: digest)
                                                        .wholeFileLocation(byteLength: bytes.count)
                                                } else {
                                                    guard var repository = candidateRepository,
                                                          let (reference, resource) = try? repository.readResource(path,
                                                            byteLimit: min(remaining, 16 * 1024 * 1024)) else {
                                                        return .init(objectOffset: offset, slot: slot.index, status: .unsupported,
                                                                     issue: "saved_texture_slot_or_source_unresolved")
                                                    }
                                                    bytes = resource
                                                    location = reference.wholeFileLocation(byteLength: bytes.count)
                                                }
                                                remaining -= bytes.count
                                                guard ["PNG", "JPEG", "BMP", "DPNG"].contains(InventoryScanner.signature(Data(bytes.prefix(16)))),
                                                      let dimensions = try? imageLoader?(bytes),
                                                      (1...8192).contains(dimensions.0), (1...8192).contains(dimensions.1) else {
                                                    return .init(objectOffset: offset, slot: slot.index, status: .unsupported,
                                                                 issue: "saved_texture_raster_unsupported")
                                                }
                                                savedVisualResources[offset]?.boundTextures[Int32(slot.index)] = location
                                                savedVisualResources[offset]?.boundTextureNames[Int32(slot.index)] = path
                                                if slot.embeddedLength > 0 { savedTextureData[location] = bytes }
                                                return .init(objectOffset: offset, slot: slot.index, status: .inferred, issue: nil)
                                            }
                                        }
                                        if !bindings.isEmpty { saveResumeBoundary?.savedTextureBindings = bindings }
                                    }
                                }
                                var staged: ScriptStorage?
                                do {
                                    var scalars = try ScriptStorage.stageSavedGlobalScalars(arrays)
                                    // Native load replaces the auxiliary list at +0x08.
                                    // flog ?g reads the separate backing store at +0x04.
                                    // Settings such as #MouseGestureEnable are initialized
                                    // by misc/value.s in the primary machine's shared svar table.
                                    scalars.system = candidate.system.filter { key, binding in
                                        key.first == 0x23 && binding.elements.allSatisfy {
                                            switch $0 {
                                            case .integer, .string: return true
                                            default: return false
                                            }
                                        }
                                    }
                                    scalars.savedTextureData = savedTextureData
                                    scalars.configuration = candidate.configuration
                                    scalars.fileLogValues = candidate.fileLogValues
                                    scalars.lineLogValues = candidate.lineLogValues
                                    scalars.importedLabelHistory = candidate.importedLabelHistory
                                    // Slot availability belongs to the host session, not the saved execution stack.
                                    scalars.sessionSaveNames = candidate.sessionSaveNames
                                    scalars.sessionSaveMetadata = candidate.sessionSaveMetadata
                                    scalars.sessionSaveThumbnails = candidate.sessionSaveThumbnails
                                    scalars.effectCapturePriority = display.capturePriority
                                    staged = scalars
                                    saveResumeBoundary?.stagedGlobalScalarCount = scalars.global.count
                                } catch {
                                    saveResumeBoundary?.globalScalarIssue = String(describing: error)
                                }
                                do {
                                    let counts = try staged?.stageSavedGlobalTextObjects(arrays)
                                    saveResumeBoundary?.stagedGlobalListCount = counts?.lists
                                    saveResumeBoundary?.stagedGlobalTableCount = counts?.tables
                                } catch {
                                    saveResumeBoundary?.globalTextObjectIssue = String(describing: error)
                                }
                                do {
                                    saveResumeBoundary?.stagedGlobalSoundAliasCount = try staged?.stageSavedSoundAliases(arrays)
                                } catch {
                                    saveResumeBoundary?.globalSoundAliasIssue = String(describing: error)
                                }
                                do {
                                    saveResumeBoundary?.stagedGlobalObjectAliasCount =
                                        try staged?.stageSavedObjectAliasReferences(arrays)
                                } catch {
                                    saveResumeBoundary?.globalObjectAliasIssue = String(describing: error)
                                }
                                do {
                                    saveResumeBoundary?.stagedGlobalButtonIdentityArrayCount =
                                        try staged?.stageSavedGlobalButtonIdentities(arrays, resources: savedVisualResources.mapValues(\.location),
                                            resourceNames: savedVisualResources.compactMapValues(\.resourceName),
                                            textures: savedVisualResources.mapValues(\.boundTextures),
                                            textureNames: savedVisualResources.mapValues(\.boundTextureNames), sounds: savedButtonSounds,
                                            resourceDetails: savedVisualResources,
                                            savedState: state, program: resumeInstruction?.program)
                                } catch {
                                    saveResumeBoundary?.globalButtonIdentityIssue = String(describing: error)
                                }
                                do {
                                    saveResumeBoundary?.stagedGlobalImageIdentityArrayCount =
                                        try staged?.stageSavedGlobalImageIdentities(arrays, resources: savedVisualResources,
                                            savedState: state, researchVideoProfiles: researchVideoSaveProfiles)
                                } catch {
                                    saveResumeBoundary?.globalImageIdentityIssue = String(describing: error)
                                }
                                do {
                                    saveResumeBoundary?.stagedGlobalMessageIdentityArrayCount =
                                        try staged?.stageSavedGlobalMessageIdentities(arrays, state: state,
                                            resources: savedVisualResources)
                                } catch {
                                    saveResumeBoundary?.globalMessageIdentityIssue = String(describing: error)
                                }
                                // Hidden images can be enabled after resume, so a named source
                                // must survive adoption even when it is not currently drawn.
                                if saveResumeBoundary?.globalImageIdentityIssue == nil,
                                   let image = summary.imagePayloads.first(where: {
                                       ($0.imageSource != nil || !$0.textureSlots.isEmpty) &&
                                           savedVisualResources[$0.decodedOffset] == nil
                                   }) {
                                    let reason = image.drawGate != 0
                                        ? "saved_drawable_image_resource_unrestored" : "saved_hidden_image_resource_unrestored"
                                    saveResumeBoundary?.globalImageIdentityIssue = "\(reason):\(image.decodedOffset)"
                                }
                                if !summary.messagePayloads.isEmpty, var previewStorage = staged {
                                    do {
                                        let count = try previewStorage.stageSavedMessagePreviews(
                                            arrays, state: state, resources: savedVisualResources)
                                        var previewMachine = self
                                        previewMachine.storage = previewStorage
                                        let visible = previewMachine.messageTextLayers.count { $0.isVisible }
                                        var draw: SavedDisplayDraw?
                                        if let handler = savedSceneDrawHandler {
                                            do { draw = try handler(previewMachine, .scene).0 }
                                            catch { draw = .init(status: .unsupported, issue: String(describing: error)) }
                                        } else { draw = nil }
                                        // A disposable message preview can still be drawn after a
                                        // different visual object failed staging. Do not present
                                        // that partial scene as a successful restoration.
                                        let visualIssue = saveResumeBoundary?.globalImageIdentityIssue ??
                                            saveResumeBoundary?.globalButtonIdentityIssue ??
                                            saveResumeBoundary?.globalMessageIdentityIssue
                                        if visualIssue != nil, draw != nil {
                                            draw?.status = .unsupported
                                            draw?.issue = "saved_visual_object_restore_incomplete"
                                        }
                                        saveResumeBoundary?.savedMessagePreview = .init(
                                            status: visualIssue == nil ? .inferred : .unsupported,
                                            arrayCount: count, visibleTextLayerCount: visible, draw: draw, issue: visualIssue)
                                    } catch {
                                        saveResumeBoundary?.savedMessagePreview = .init(status: .unsupported,
                                            arrayCount: nil, visibleTextLayerCount: nil, draw: nil, issue: String(describing: error))
                                    }
                                }
                                // A single root snapshot can share the isolated restored global storage.
                                // Multiple routines require a verified mapping to live interpreter frames.
                                if let root,
                                   root.hasResultSnapshot, staged != nil {
                                    do {
                                        try staged?.stageRoutineResultScalars(from: root, in: state)
                                        saveResumeBoundary?.stagedRootResultScalarSnapshot = .verified
                                    } catch {
                                        saveResumeBoundary?.stagedRootResultScalarSnapshot = .unsupported
                                        saveResumeBoundary?.rootResultScalarIssue = String(describing: error)
                                    }
                                    if root.nonEmptyResultObjectReferenceCount != 0 {
                                        let checks = try staged?.savedResultObjectChecks(from: root, in: state, indexedStatus: summary.indexed.status, shadowed: shadowed)
                                        saveResumeBoundary?.rootResultObjectChecks = checks
                                        saveResumeBoundary?.inferredRootResultObjectMatchCount = checks?.count { $0.status == .inferred }
                                        saveResumeBoundary?.rootResultObjectIssue = "save_result_object_identity_unresolved"
                                    }
                                }
                                do {
                                    saveResumeBoundary?.stagedGlobalInactiveTimerArrayCount =
                                        try staged?.stageSavedInactiveTimers(arrays)
                                } catch {
                                    saveResumeBoundary?.globalTimerIdentityIssue = String(describing: error)
                                }
                                do {
                                    saveResumeBoundary?.stagedGlobalActiveCallbackTimerArrayCount =
                                        try staged?.stageSavedEnabledCallbackTimers(arrays, state: state,
                                            program: resumeInstruction?.program)
                                } catch {
                                    saveResumeBoundary?.globalTimerIdentityIssue = String(describing: error)
                                }
                                do {
                                    try staged?.resolveSavedGlobalObjectAliases()
                                } catch {
                                    saveResumeBoundary?.globalObjectAliasIssue = String(describing: error)
                                }
                                let stagedObjectCount = (saveResumeBoundary?.stagedGlobalListCount ?? 0)
                                    + (saveResumeBoundary?.stagedGlobalTableCount ?? 0)
                                let unstagedObjects = summary.objectArrayCount - stagedObjectCount
                                    - (saveResumeBoundary?.stagedGlobalButtonIdentityArrayCount ?? 0)
                                    - (saveResumeBoundary?.stagedGlobalImageIdentityArrayCount ?? 0)
                                    - (saveResumeBoundary?.stagedGlobalMessageIdentityArrayCount ?? 0)
                                    - (saveResumeBoundary?.stagedGlobalInactiveTimerArrayCount ?? 0)
                                    - (saveResumeBoundary?.stagedGlobalActiveCallbackTimerArrayCount ?? 0)
                                    - (saveResumeBoundary?.stagedGlobalSoundAliasCount ?? 0)
                                    - (saveResumeBoundary?.stagedGlobalObjectAliasCount ?? 0)
                                saveResumeBoundary?.unstagedGlobalObjectArrayCount = unstagedObjects
                                if summary.absentValueCount != 0 {
                                    saveResumeBoundary?.firstAbsentGlobalBindingOffset = arrays.records.first {
                                        if case .absent = $0.values { return true }
                                        return false
                                    }?.decodedOffset
                                }
                                let storageIssue: String?
                                if let issue = saveResumeBoundary?.globalScalarIssue ??
                                    saveResumeBoundary?.globalTextObjectIssue ?? saveResumeBoundary?.globalSoundAliasIssue ??
                                    saveResumeBoundary?.globalObjectAliasIssue ??
                                    saveResumeBoundary?.globalButtonIdentityIssue ??
                                    saveResumeBoundary?.globalMessageIdentityIssue ??
                                    saveResumeBoundary?.globalTimerIdentityIssue {
                                    storageIssue = issue
                                } else if unstagedObjects != 0 {
                                    storageIssue = "save_global_object_arrays_unrestored"
                                } else if let issue = saveResumeBoundary?.globalImageIdentityIssue {
                                    storageIssue = issue
                                } else if summary.absentValueCount != 0 {
                                    storageIssue = "save_global_absent_bindings_unrestored"
                                } else if !indexedFrameScalarsAvailable {
                                    storageIssue = "save_indexed_frame_bindings_unrestored"
                                } else {
                                    storageIssue = nil
                                }
                                saveResumeBoundary?.isolatedStorageIssue = storageIssue
                                if summary.indexed.status != .unsupported {
                                    let engineOffset = summary.indexed.nextDecodedOffset ?? summary.nextDecodedOffset
                                    if engineOffset < state.count {
                                        let engine = try SaveEngineState(state: state, at: engineOffset)
                                        saveResumeBoundary?.engineState = engine
                                        let names = try engine.systemNameSlots(in: state)
                                        guard names.count == candidate.systemNameSlots.count else {
                                            throw ResourceError.rejected("save_system_name_slot_count")
                                        }
                                        // Keep restored values in the same isolated storage.
                                        // The live interpreter still owns its existing handles.
                                        staged?.systemNameSlots = names
                                        staged?.systemLockMask = engine.systemLockMask
                                        staged?.systemCustomLockMask = engine.systemCustomLockMask
                                        staged?.systemReleaseArgument = try engine.systemReleaseArgument(in: state)
                                        staged?.formCloseSaveFilename = try engine.formCloseSaveFilename(in: state)
                                        if engine.status == .verified {
                                            staged?.serializedMemoryCheckpoints = try engine.memoryCheckpoints(in: state)
                                            saveResumeBoundary?.stagedMemoryCheckpointCount = staged?.serializedMemoryCheckpoints.count
                                            // 0x6ae1c5 calls 0x6b9c54 before returning success.
                                            staged?.restoredSystemSkip = false
                                            staged?.systemPlayMode = 0
                                        }
                                        saveResumeBoundary?.stagedSystemNameSlotCount = staged?.systemNameSlots.count
                                    }
                                }
                                var readerPrefixesSupported = true
                                do {
                                    var readerStorage = staged ?? ScriptStorage()
                                    try readerStorage.restoreReaderPrefixes(cursor, in: state)
                                    if staged != nil { staged = readerStorage }
                                } catch ResourceError.rejected("saved_reader_prefix_outside_profile") {
                                    readerPrefixesSupported = false
                                    if storageIssue == nil {
                                        saveResumeBoundary?.isolatedStorageIssue = "saved_reader_prefix_outside_profile"
                                    }
                                }
                                var readerRulesSupported = true
                                if cursor.replaceEnableByte != 0, var readerStorage = staged {
                                    do {
                                        try readerStorage.restoreReaderReplacements(cursor, in: state)
                                        staged = readerStorage
                                    } catch {
                                        readerRulesSupported = false
                                        if storageIssue == nil, readerPrefixesSupported {
                                            saveResumeBoundary?.isolatedStorageIssue = String(describing: error)
                                        }
                                    }
                                }
                                var drawPreview: (() throws -> SavedDisplayDraw)?
                                if let preview = savedDisplayPreview, let handler = savedDisplayDrawHandler {
                                    drawPreview = { try handler(preview) }
                                }
                                let activeRoutine = cursor.routines.last
                                let savedWait: Int32? = activeRoutine.flatMap { routine in
                                    if routine.rawState == 3, routine.waitTime >= 0 { return routine.waitTime }
                                    if routine.rawState == 4,
                                       (routine.waitTime == -1 && routine.skipTime == -1) ||
                                       (routine.waitTime >= 0 && routine.waitTime <= routine.skipTime) {
                                        return routine.waitTime
                                    }
                                    return nil
                                }
                                let savedStopLabel: String? = {
                                    guard let routine = activeRoutine, routine.rawState == 2,
                                          routine.waitTime == -1, routine.skipTime == -1, routine.channel == 0,
                                          routine.jumpLabel.length == 0, routine.eventName.length == 0,
                                          let target = resumeInstruction else { return nil }
                                    do {
                                        let label = try routine.eventLabel.utf16Text(in: state)
                                        let position = try target.program.sourcePosition(for: cursor, anchor: target.anchor)
                                        try target.program.validateSavedStop(position, label: label)
                                        return label
                                    } catch { return nil }
                                }()
                                let activeRoutineCanResume = activeRoutine?.rawState == 0 || savedWait != nil || savedStopLabel != nil
                                let restoredScopeNames = try? cursor.routines.map { routine -> String? in
                                    if routine.scope.allSatisfy({ $0.length == 0 }) { return nil }
                                    guard let first = routine.scope.first,
                                          routine.scope.dropFirst().allSatisfy({ $0.length == 0 }) else {
                                        throw ResourceError.rejected("saved_routine_scope_outside_profile")
                                    }
                                    return try first.utf16Text(in: state)
                                }
                                if var staged, let target = resumeInstruction,
                                   (2...maximumFrames).contains(cursor.routines.count),
                                   savedReturns.count == cursor.routines.count - 1,
                                   !cursor.routines[0].hasResultSnapshot,
                                   activeRoutineCanResume, cursor.routines.dropLast().allSatisfy({ $0.rawState == 0 }),
                                   cursor.routines.allSatisfy({
                                       $0.nonEmptyResultObjectReferenceCount == 0 && ($0.resultButtonReference?.length ?? 0) == 0 }),
                                   let restoredScopeNames,
                                   cursor.routines.dropFirst().allSatisfy({ $0.controlBlocks.first?.rawState == 1 }),
                                   storageIssue == nil, readerPrefixesSupported, readerRulesSupported,
                                   saveResumeBoundary?.globalTextObjectIssue == nil {
                                    do {
                                        staged.frames[0].locals = frameLocals[0] ?? [:]
                                        staged.frames[0].objectAliases = frameAliases[0] ?? []
                                        staged.frames[0].objectAliasReferences = frameAliasReferences[0] ?? [:]
                                        try staged.resolveSavedFrameObjectAliases(0)
                                        var localContext: ScriptProgram?
                                        for (index, savedCaller) in savedReturns.enumerated() {
                                            let caller = try localContext.map { try Self.mapSavedPosition(savedCaller, to: $0) } ?? savedCaller
                                            let callee = index + 1 < savedReturns.count ? savedReturns[index + 1] : target
                                            let blocks = cursor.routines[index].controlBlocks
                                            try Self.stageSavedFrameControls(program: caller.program, index: caller.index,
                                                anchor: caller.anchor, blocks: index == 0 ? blocks : Array(blocks.dropFirst()),
                                                state: state, repository: &candidateRepository, storage: &staged, frameIndex: index)
                                            try Self.stageSavedCall(callee: callee.program, anchor: callee.anchor,
                                                caller: caller.program, returnIndex: caller.index,
                                                catalog: candidateRepository?.catalog, locals: frameLocals[index + 1] ?? [:],
                                                storage: &staged)
                                            staged.frames[index + 1].objectAliases = frameAliases[index + 1] ?? []
                                            staged.frames[index + 1].objectAliasReferences = frameAliasReferences[index + 1] ?? [:]
                                            try staged.resolveSavedFrameObjectAliases(index + 1)
                                            let routine = cursor.routines[index + 1]
                                            staged.frames[index + 1].savedReturnScalars = try routine.savedResultScalars(in: state)
                                            localContext = Self.savedCallUsesLocalContext(caller.program, returnIndex: caller.index)
                                                ? caller.program : nil
                                        }
                                        let restoredTarget = try localContext.map { try Self.mapSavedPosition(target, to: $0) } ?? target
                                        try Self.stageSavedFrameControls(program: restoredTarget.program, index: restoredTarget.index,
                                            anchor: restoredTarget.anchor, blocks: Array(cursor.routines.last!.controlBlocks.dropFirst()),
                                            state: state, repository: &candidateRepository, storage: &staged,
                                            frameIndex: cursor.routines.count - 1)
                                        for (index, name) in restoredScopeNames.enumerated() {
                                            let isActive = index == cursor.routines.count - 1 && activeRoutine?.rawState == 0
                                            let resume = restoredTarget.program.document.records[restoredTarget.index]
                                            staged.frames[index].tableScope = try Self.restoredScope(name, storage: staged,
                                                frame: staged.frames[index],
                                                checkpointScope: isActive ? Self.checkpointScope(at: resume) : nil)
                                        }
                                        try Self.stageSavedDialogueLog(saveResumeBoundary?.statePrefix, state: state,
                                                                       location: record.location, storage: &staged)
                                        try staged.validate()
                                        saveResumeBoundary?.isolatedReturnScalarFrameCount = staged.frames.count {
                                            $0.savedReturnScalars != nil
                                        }
                                        saveResumeBoundary?.isolatedCallFrameStatus = .inferred
                                        if retainCandidate {
                                            savedExecutionCandidate = .init(program: restoredTarget.program, index: restoredTarget.index,
                                                storage: staged, repository: candidateRepository, wait: savedWait,
                                                clickInitial: activeRoutine?.rawState == 4 ? activeRoutine?.skipTime : nil,
                                                stopLabel: savedStopLabel,
                                                streamNames: saveResumeBoundary?.statePrefix?.savedStreamNameCandidates(in: state) ?? [:],
                                                directNames: saveResumeBoundary?.statePrefix?.savedDirectNameCandidates(in: state) ?? [:],
                                                streamFilters: saveResumeBoundary?.statePrefix?.savedStreamFilterCandidates(in: state) ?? [:])
                                        }
                                        var continuation = try Self.probeSavedCalculations(
                                            program: restoredTarget.program, index: restoredTarget.index, storage: staged,
                                            repository: candidateRepository, savedWait: savedWait, savedStopLabel: savedStopLabel, drawPreview: drawPreview, drawScene: savedSceneDrawHandler, frozenLayerPreview: savedFrozenLayerPreview, eventSampleTicks: savedEventSampleTicks,
                                            decodeMovie: savedMovieDecodeHandler, decodeSound: savedSoundDecodeHandler, clickAfterMovie: clickAfterSavedMovie, dialogueClicks: savedDialogueClicks, autoWaitClicks: savedAutoWaitClicks, limit: savedReplayStepLimit, compact: compactSavedReplay,
                                            imageLoader: imageLoader, imageMemberLookup: imageMemberLookup,
                                            imageExtendedValues: imageExtendedValues,
                                            imageMotionNames: imageMotionNames)
                                        if compactSavedReplay { continuation?.retainRecentSteps() }
                                        saveResumeBoundary?.isolatedContinuation = continuation
                                    } catch {
                                        saveResumeBoundary?.isolatedCallFrameStatus = .unsupported
                                        saveResumeBoundary?.isolatedCallFrameIssue = String(describing: error)
                                    }
                                }
                                if cursor.routines.count == 1, var staged, let target = resumeInstruction, let root,
                                   activeRoutineCanResume,
                                   let restoredScopeNames, restoredScopeNames.count == 1,
                                   root.nonEmptyResultObjectReferenceCount == 0,
                                   (root.resultButtonReference?.length ?? 0) == 0,
                                   storageIssue == nil, readerPrefixesSupported, readerRulesSupported,
                                   saveResumeBoundary?.globalTextObjectIssue == nil,
                                   saveResumeBoundary?.rootResultScalarIssue == nil {
                                    staged.frames[0].locals = frameLocals[0] ?? [:]
                                    staged.frames[0].objectAliases = frameAliases[0] ?? []
                                    staged.frames[0].objectAliasReferences = frameAliasReferences[0] ?? [:]
                                    try staged.resolveSavedFrameObjectAliases(0)
                                    staged.frames[0].tableScope = try Self.restoredScope(restoredScopeNames[0], storage: staged,
                                        frame: staged.frames[0], checkpointScope: root.rawState == 0
                                            ? Self.checkpointScope(at: target.program.document.records[target.index]) : nil)
                                    try Self.stageSavedDialogueLog(saveResumeBoundary?.statePrefix, state: state,
                                                                   location: record.location, storage: &staged)
                                    try staged.validate()
                                    var canProbe = root.controlBlocks.isEmpty
                                    if !canProbe {
                                        do {
                                            let positions = Dictionary(uniqueKeysWithValues:
                                                (saveResumeBoundary?.loopReturnCandidates ?? []).compactMap { item in
                                                    item.location.map { (item.blockOffset, $0) }
                                                })
                                            var controlPositions = positions
                                            for block in root.controlBlocks where block.rawState == 2 {
                                                controlPositions[block.decodedOffset] = try SaveReaderCursor.controlPosition(
                                                    block, in: state, reader: cursor, anchor: target.anchor, program: target.program)
                                            }
                                            try Self.stageSavedActiveControls(program: target.program, index: target.index,
                                                blocks: root.controlBlocks, returnLocations: controlPositions, storage: &staged)
                                            saveResumeBoundary?.isolatedActiveControlStatus = .inferred
                                            if root.controlBlocks.allSatisfy({ $0.rawState == 3 }) {
                                                saveResumeBoundary?.isolatedActiveLoopStatus = .inferred
                                            }
                                            canProbe = true
                                        } catch {
                                            saveResumeBoundary?.isolatedActiveControlStatus = .unsupported
                                            saveResumeBoundary?.isolatedActiveControlIssue = String(describing: error)
                                            if root.controlBlocks.allSatisfy({ $0.rawState == 3 }) {
                                                saveResumeBoundary?.isolatedActiveLoopStatus = .unsupported
                                                saveResumeBoundary?.isolatedActiveLoopIssue = String(describing: error)
                                            }
                                        }
                                    }
                                    if canProbe {
                                        if retainCandidate {
                                            savedExecutionCandidate = .init(program: target.program, index: target.index,
                                                storage: staged, repository: candidateRepository, wait: savedWait,
                                                clickInitial: activeRoutine?.rawState == 4 ? activeRoutine?.skipTime : nil,
                                                stopLabel: savedStopLabel,
                                                streamNames: saveResumeBoundary?.statePrefix?.savedStreamNameCandidates(in: state) ?? [:],
                                                directNames: saveResumeBoundary?.statePrefix?.savedDirectNameCandidates(in: state) ?? [:],
                                                streamFilters: saveResumeBoundary?.statePrefix?.savedStreamFilterCandidates(in: state) ?? [:])
                                        }
                                        var continuation = try Self.probeSavedCalculations(
                                            program: target.program, index: target.index, storage: staged,
                                            repository: candidateRepository, savedWait: savedWait, savedStopLabel: savedStopLabel, drawPreview: drawPreview, drawScene: savedSceneDrawHandler, frozenLayerPreview: savedFrozenLayerPreview, eventSampleTicks: savedEventSampleTicks,
                                            decodeMovie: savedMovieDecodeHandler, decodeSound: savedSoundDecodeHandler, clickAfterMovie: clickAfterSavedMovie, dialogueClicks: savedDialogueClicks, autoWaitClicks: savedAutoWaitClicks, limit: savedReplayStepLimit, compact: compactSavedReplay,
                                            imageLoader: imageLoader, imageMemberLookup: imageMemberLookup,
                                            imageExtendedValues: imageExtendedValues,
                                            imageMotionNames: imageMotionNames)
                                        saveResumeBoundary?.isolatedCalculation = continuation?.steps.first.flatMap {
                                            $0.command.map(asciiLower) == "cal" ? $0 : nil
                                        }
                                        if compactSavedReplay { continuation?.retainRecentSteps() }
                                        saveResumeBoundary?.isolatedContinuation = continuation
                                    }
                                }
                            }
                        }
                        let stopReason = savedExecutionCandidate == nil
                            ? "save_restore_execution_state_unsupported" : "save_restore_candidate_ready"
                        if linkedLogLoad, savedExecutionCandidate != nil {
                            // The log task still owns the post-load transition. Commit only after thrd,0.
                            candidate.clearResultBindings()
                            try candidate.resultInteger(1)
                            action = "linked_log_jump_staged"
                            break
                        }
                        throw ResourceError.rejected(stopReason)
                    }
                    if command == "l", candidate.frames.last!.tableScope.count == 1,
                       let handle = candidate.frames.last!.tableScope.first, candidate.timers[handle] != nil {
                        guard (1...2).contains(record.fields.count) else {
                            throw ResourceError.rejected("timer_callback_arity")
                        }
                        let label = try callLabel()
                        let destination = try program.label(label)
                        guard program.ancestors[destination].isEmpty else {
                            throw ResourceError.rejected("timer_callback_inside_control_block")
                        }
                        // 0x6ac8b3 resolves the callback label and 0x6ac8e6 stores the optional argument.
                        candidate.timers[handle]?.callback = (program, destination, label)
                        candidate.timers[handle]?.argument = record.fields.count == 2 ? try callLabel(1) : ""
                        action = "timer_callback_bind_candidate"
                        break
                    }
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
                       let handle = candidate.frames.last!.tableScope.first, ScriptStorage.isDirectSoundHandle(handle) {
                        try arity(1)
                        let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_direct_sound_operand") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard case .string(let path) = value, candidateRepository != nil else {
                            throw ResourceError.rejected("direct_sound_load_shape_outside_profile")
                        }
                        let logical = try candidateRepository!.catalog.resourcePath(path, currentSourceFile: record.location.sourceFile)
                        let (reference, data) = try candidateRepository!.readResource(logical)
                        guard data.count >= 12, data.prefix(4) == Data("RIFF".utf8), data[8..<12] == Data("WAVE".utf8) else {
                            throw ResourceError.rejected("direct_sound_requires_wave")
                        }
                        if allowAudioFileLogCandidate {
                            audioFileLogOutcome = try candidate.recordImageFileLogCandidate(logical)
                        }
                        let location = ScriptLocation(sourceFile: reference.sourceFile, sourceSHA256: reference.sourceSHA256,
                            byteOffset: 0, byteLength: data.count, rangeSHA256: data.sha256Hex, lineNumber: 1)
                        if candidate.directSoundChannels[handle]?.resource != location {
                            // The selected script load dispatch passes type 2.
                            candidate.directSoundChannels[handle] = .init(resource: location,
                                resourceName: reference.logicalPath, volumeType: 2)
                            candidate.soundChannels.removeValue(forKey: handle)
                        } else {
                            // 0x59f83d writes the requested type before the
                            // same-resource fast return at 0x59f87e.
                            candidate.directSoundChannels[handle]?.volumeType = 2
                        }
                        resourceLocation = location
                        action = "direct_sound_resource_load_candidate"
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
                        let location = try ScriptRepository.vorbisLocation(reference, data: data)
                        if allowAudioFileLogCandidate {
                            audioFileLogOutcome = try candidate.recordImageFileLogCandidate(logical)
                        }
                        resourceLocation = location
                        // The original load dispatch at 0x6b50cc takes the
                        // channel index directly, without a script-side reset.
                        candidate.ensureStreamChannel(stream)
                        candidate.soundChannels[stream]?.resource = location
                        candidate.soundChannels[stream]?.naturalCompletionStep = nil
                        candidate.soundChannels[stream]?.requestedSourceName = path
                        candidate.soundChannels[stream]?.requestedSourceNameKnown = true
                        candidate.soundChannels[stream]?.probedDurationMilliseconds = nil
                        candidate.soundChannels[stream]?.seekRequest = nil
                        candidate.soundChannels[stream]?.volumeControlToken = nil
                        candidate.soundChannels[stream]?.panControlToken = nil
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
                        let movie = try candidateRepository!.movieLocation(logical)
                        resourceLocation = movie.location
                        candidate.movies[handle]!.resource = movie.location
                        candidate.movies[handle]!.size = movie.size
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
                        if path.isEmpty, candidate.buttons.contains(handle) {
                            // The drawable loader at 0x6c7093 forwards nil to 0x5ad775.
                            candidate.buttonResources.removeValue(forKey: handle)
                            candidate.buttonResourceMemberCounts.removeValue(forKey: handle)
                            candidate.buttonHasExtendedContainerMetadata.remove(handle)
                            candidate.buttonSelectedMembers.removeValue(forKey: handle)
                            candidate.buttonMotionStartTicks.removeValue(forKey: handle)
                            candidate.buttonLayerAuxiliaryFlags.removeValue(forKey: handle)
                            candidate.buttonSavedLayerTimeSnapshots.removeValue(forKey: handle)
                            candidate.buttonActionSelectionUnknown.remove(handle)
                            candidate.buttonImages.removeValue(forKey: handle)
                            candidate.buttonResourceNames.removeValue(forKey: handle)
                            candidate.buttonImageNames.removeValue(forKey: handle)
                            action = "button_empty_path_release_candidate"
                            break
                        }
                        if path.isEmpty, candidate.messages[handle] != nil {
                            // Clearing an empty message background is a local candidate rule.
                            // FUN_0067dd6c loads three child images and is not evidence for
                            // the serialized message background loader; that relationship
                            // remains not_tested.
                            candidate.messages[handle]?.background = nil
                            candidate.messages[handle]?.backgroundName = nil
                            candidate.messages[handle]?.backgroundBoundImages.removeAll()
                            candidate.messages[handle]?.backgroundBoundImageNames.removeAll()
                            candidate.messages[handle]?.backgroundMemberCount = 0
                            candidate.messages[handle]?.backgroundSelectedMember = nil
                            candidate.messages[handle]?.backgroundMotionStartTick = nil
                            candidate.messages[handle]?.backgroundHasExtendedContainerMetadata = false
                            candidate.messages[handle]?.backgroundLayerAuxiliaryFlags = Array(repeating: 1, count: 256)
                            candidate.messages[handle]?.backgroundSavedLayerTimeSnapshot = nil
                            candidate.messages[handle]?.backgroundMotionElapsedBeforeSpeedChange = 0
                            candidate.messages[handle]?.backgroundRestoredMotionThreshold = nil
                            candidate.messages[handle]?.backgroundRestoredMotionRemainder = 0
                            candidate.messages[handle]?.backgroundExtendedDefaultsPrepared = false
                            action = "message_empty_background_release_candidate"
                            break
                        }
                        if path.isEmpty, var image = candidate.images[handle] {
                            // The nil filename branch at 0x5ad775 releases the image payload.
                            image.resource = nil
                            image.resourceName = nil
                            image.isTheoraResource = false
                            image.standaloneVideoDuration = nil
                            image.resourceLoadLocation = nil
                            image.boundImages.removeAll()
                            image.boundImageNames.removeAll()
                            image.hasExtendedContainerMetadata = false
                            image.extendedDefaultsPrepared = false
                            image.extendedScalarValues.removeAll()
                            image.width = nil
                            image.height = nil
                            image.selectedMember = nil
                            image.motionStartTick = nil
                            image.savedLayerTimeSnapshot = nil
                            image.layerAuxiliaryFlags = Array(repeating: 1, count: 256)
                            image.motionElapsedBeforeSpeedChange = 0
                            image.restoredMotionThreshold = nil
                            image.restoredMotionRemainder = 0
                            image.layerClockRemainder = 0
                            image.memberCount = 0
                            candidate.images[handle] = image
                            action = "image_empty_path_release_candidate"
                            break
                        }
                        let capturePrefix = "$$$gamethreadimagez,"
                        let foldedPath = asciiLower(path)
                        if foldedPath.hasPrefix(capturePrefix), foldedPath.hasSuffix(".bmp"),
                           let priority = Int32(foldedPath.dropFirst(capturePrefix.count).dropLast(4)) {
                            // imoscripter_base.s maps %%%capture_ operands into this host namespace.
                            guard candidate.linkedPrimaryPlayMode != nil, candidate.images[handle] != nil else {
                                throw ResourceError.rejected("game_thread_image_capture_required: \(priority)")
                            }
                            let scene: ScreenCaptureRequest.Scene = isLinkedLogTask && pendingMemoryCheckpointRestore == .temporary &&
                                savedExecutionCandidate != nil ? .restoredCheckpoint : .suspendedPrimary
                            screenCaptureRequest = ScreenCaptureRequest(priority: priority, scene: scene,
                                                                        location: record.location, handle: handle)
                            phase = .waitingForScreenCapture
                            action = "game_thread_image_capture_request_candidate"
                            break
                        }
                        let logical = try candidateRepository!.catalog.resourcePath(path,currentSourceFile: record.location.sourceFile)
                        let (reference, data) = try candidateRepository!.readResource(logical)
                        resourceLocation = ScriptLocation(sourceFile: reference.sourceFile,sourceSHA256: reference.sourceSHA256,
                            byteOffset: 0,byteLength: data.count,rangeSHA256: data.sha256Hex,lineNumber: 1)
                        guard let imageLoader else { throw ResourceError.rejected("image_object_decoder_required") }
                        let (width, height, memberCount) = try imageLoader(data)
                        let motionOnly = width == 0 && height == 0 && memberCount == 0 &&
                            candidate.images[handle] != nil && imageMotionNames?(resourceLocation!)?.isEmpty == false
                        guard motionOnly || ((1...8192).contains(width) && (1...8192).contains(height)) else {
                            throw ResourceError.rejected("image_object_dimensions")
                        }
                        if allowImageFileLogCandidate {
                            imageFileLogOutcome = try candidate.recordImageFileLogCandidate(logical)
                            if imageFileLogOutcome == .noMatch, firstImageFileLogNoMatchSnapshot == nil {
                                imageFileLogSnapshot = candidate.fileLogPatternSnapshot()
                            }
                        }
                        if candidate.buttons.contains(handle) {
                            candidate.buttonResources[handle] = resourceLocation
                            candidate.buttonResourceNames[handle] = path
                            candidate.buttonResourceMemberCounts[handle] = memberCount
                            if data.starts(with: Data("abmp12".utf8)) {
                                candidate.buttonHasExtendedContainerMetadata.insert(handle)
                            } else {
                                candidate.buttonHasExtendedContainerMetadata.remove(handle)
                            }
                            let motionCount = imageMotionNames?(resourceLocation!)?.count ?? 0
                            if memberCount > 0 || motionCount > 0 {
                                let rowFlags = imageLayerFlags?(resourceLocation!, 0)
                                candidate.selectNativeButtonMotion(handle, index: 0,
                                    at: candidate.visualTicks, rowFlags: rowFlags)
                            } else {
                                candidate.buttonSelectedMembers.removeValue(forKey: handle)
                                candidate.buttonMotionStartTicks.removeValue(forKey: handle)
                                candidate.buttonSavedLayerTimeSnapshots.removeValue(forKey: handle)
                                candidate.buttonLayerAuxiliaryFlags[handle] = Array(repeating: 1, count: 256)
                            }
                            action = "button_resource_load_candidate"
                        } else if candidate.messages[handle] != nil {
                            // This local candidate binds the resolved catalog resource.
                            // The fixed-EXE relationship between its message image reload
                            // path and the inspected command dispatcher remains not_tested.
                            candidate.messages[handle]?.background = resourceLocation
                            candidate.messages[handle]?.backgroundName = path
                            candidate.messages[handle]?.backgroundBoundImages.removeAll()
                            candidate.messages[handle]?.backgroundBoundImageNames.removeAll()
                            candidate.messages[handle]?.backgroundMemberCount = memberCount
                            candidate.messages[handle]?.backgroundSelectedMember = nil
                            candidate.messages[handle]?.backgroundMotionStartTick = nil
                            candidate.messages[handle]?.backgroundHasExtendedContainerMetadata = data.starts(with: Data("abmp12".utf8))
                            candidate.messages[handle]?.backgroundLayerAuxiliaryFlags = Array(repeating: 1, count: 256)
                            candidate.messages[handle]?.backgroundSavedLayerTimeSnapshot = nil
                            candidate.messages[handle]?.backgroundMotionElapsedBeforeSpeedChange = 0
                            candidate.messages[handle]?.backgroundRestoredMotionThreshold = nil
                            candidate.messages[handle]?.backgroundRestoredMotionRemainder = 0
                            candidate.messages[handle]?.backgroundExtendedDefaultsPrepared = false
                            action = "message_background_load_candidate"
                        } else {
                            var image = candidate.images[handle]!
                            image.extendedDefaultsPrepared = false
                            image.extendedScalarValues.removeAll()
                            image.resource = resourceLocation
                            image.resourceName = path
                            let theoraDimensions = data.starts(with: Data("OggS".utf8))
                                ? try? ScriptMovieHeader.theoraDimensions(data) : nil
                            if let theoraDimensions {
                                guard theoraDimensions.0 == width, theoraDimensions.1 == height else {
                                    throw ResourceError.rejected("theora_image_header_dimensions_mismatch")
                                }
                            }
                            image.isTheoraResource = theoraDimensions != nil
                            image.standaloneVideoDuration = theoraDimensions != nil && path.lowercased().hasSuffix(".ogv")
                                ? try? ScriptMovieHeader.standaloneTheoraDuration(data) : nil
                            image.resourceLoadLocation = record.location
                            image.boundImages.removeAll()
                            image.boundImageNames.removeAll()
                            // A decoded standalone image has no ABMP extended data table.
                            image.hasExtendedContainerMetadata = data.starts(with: Data("abmp12".utf8))
                            image.width = motionOnly ? nil : width
                            image.height = motionOnly ? nil : height
                            image.memberCount = memberCount
                            if image.hasExtendedContainerMetadata {
                                image.layerAuxiliaryFlags = Array(repeating: 1, count: 256)
                                image.savedLayerTimeSnapshot = .init(times: Array(repeating: 0, count: 256),
                                    auxiliary: Array(repeating: 0, count: 256), visualTick: candidate.visualTicks)
                            }
                            // The successful image loader calls 0x57e96c, which
                            // initializes the selected motion through 0x57e840(..., 0, 0).
                            let standaloneVideoAction = theoraDimensions != nil && memberCount == 1
                            let motionCount = imageMotionNames?(resourceLocation!)?.count ?? 0
                            if memberCount > 0 || motionCount > 0 || standaloneVideoAction {
                                image.selectNativeMotion(0, at: candidate.visualTicks,
                                    rowFlags: imageLayerFlags?(resourceLocation!, 0))
                            } else {
                                image.selectedMember = nil
                                image.motionStartTick = nil
                                if !image.hasExtendedContainerMetadata {
                                    image.savedLayerTimeSnapshot = nil
                                    image.layerAuxiliaryFlags = Array(repeating: 1, count: 256)
                                }
                                image.motionElapsedBeforeSpeedChange = 0
                                image.restoredMotionThreshold = nil
                                image.restoredMotionRemainder = 0
                                image.layerClockRemainder = 0
                            }
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
                    if candidate.selectsPrimaryScriptSource, let restored = savedExecutionCandidate, isLinkedLogTask {
                        // 0x6b157f queries the selected instance; 0x6b15a9 sets the caller's result.
                        candidate.clearResultBindings()
                        try candidate.resultInteger(restored.storage.lookupCategory(name))
                        action = "linked_log_restored_variable_category"
                    } else {
                        try candidate.resultInteger(candidate.lookupCategory(name))
                        action = "variable_exists_category_candidate"
                    }
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
                            guard case .name(let name) = try calculationExpression(String(raw.dropLast(2))) else {
                                throw ResourceError.rejected("calculate_update_requires_named_target")
                            }
                            try candidate.updateInteger(name,delta: raw.hasSuffix("++") ? 1 : -1)
                            evaluated = .integer(1)
                            continue
                        }
                        let expression = try calculationExpression(raw)
                        if command == "if", case .binary("=",_,_) = expression { throw ResourceError.rejected("assignment_condition_outside_profile") }
                        // Carry an already verified sound reference through a
                        // direct alias copy; never evaluate an index twice.
                        let directName: String?
                        let directIndexed: String?
                        if case .binary("=", _, .indexed(let name, _)) = expression {
                            directName = nil; directIndexed = asciiLower(name)
                        } else if case .binary("=", _, .name(let name)) = expression {
                            directName = asciiLower(name); directIndexed = nil
                        } else { directName = nil; directIndexed = nil }
                        var observedSound: (index: Int32, handle: UInt64)?
                        // Capturing a copy permits a single atomic command commit; not original-engine error behavior.
                        evaluated = try expression.evaluate(read: { name in
                            let value = try candidate.read(name)
                            if asciiLower(name) == directName, case .object(let handle) = value,
                               let index = candidate.recordedSoundAliasIndex(source: name, index: 0, handle: handle) {
                                observedSound = (index, handle)
                            }
                            return value
                        }, write: { name, value in
                            try candidate.write(name, value)
                            if let observedSound, value == .object(observedSound.handle) {
                                try candidate.recordSoundAliasReference(target: name, index: 0,
                                    soundIndex: observedSound.index, handle: observedSound.handle)
                            }
                        }, readIndexed: { name, index in
                            let value = try candidate.readIndexed(name, index)
                            if asciiLower(name) == directIndexed, case .object(let handle) = value {
                                if directIndexed == "snd" { observedSound = (index, handle) }
                                else if let soundIndex = candidate.recordedSoundAliasIndex(source: name, index: index, handle: handle) {
                                    observedSound = (soundIndex, handle)
                                }
                            }
                            return value
                        }, writeIndexed: { name, index, value in
                            try candidate.writeIndexed(name, index, value)
                            if let observedSound, value == .object(observedSound.handle) {
                                try candidate.recordSoundAliasReference(target: name, index: index,
                                    soundIndex: observedSound.index, handle: observedSound.handle)
                            }
                        })
                    }
                    result = evaluated; action = "calculate"
                    if command == "if" {
                        guard let value = evaluated.integer, let block = program.blocks[pc], block.family == "if" else { throw ResourceError.rejected("if_type_or_structure_outside_profile") }
                        guard block.conditionalShapeSupported else {
                            throw ResourceError.rejected("if_marker_shape_outside_profile")
                        }
                        if value == 1 {
                            candidate.frames[candidate.frames.count-1].controls.append(pc)
                            candidate.frames[candidate.frames.count-1].ifConditions[pc] = value
                            action = "if_exact_one_true"
                        }
                        else {
                            let destination = block.conditionalElse ?? block.end
                            next = destination+1; skip = try skipped((pc+1)..<next); action = "if_not_exact_one"
                            if block.conditionalElse != nil {
                                candidate.frames[candidate.frames.count-1].controls.append(pc)
                                candidate.frames[candidate.frames.count-1].ifConditions[pc] = value
                            }
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
                    let removedIfs = candidate.frames[frame].controls.dropFirst(index + 1)
                    for item in removedIfs { candidate.frames[frame].ifConditions.removeValue(forKey: item) }
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
                    candidate.frames[candidate.frames.count-1].controls.removeLast()
                    candidate.frames[candidate.frames.count-1].ifConditions.removeValue(forKey: start)
                    next = block.end+1
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
                        candidate.frames[candidate.frames.count-1].controls.removeLast()
                        candidate.frames[candidate.frames.count-1].ifConditions.removeValue(forKey: start)
                        action = program.blocks[start]?.family == "case" ? "end_case_candidate" : "end_if"
                    }
                case "r":
                    try arity(0)
                    guard candidate.frames.last!.tableScope == [ScriptStorage.systemHandle],
                          candidateRepository != nil else {
                        throw ResourceError.rejected("system_restart_requires_repository")
                    }
                    // Deferred opcode 8 reaches 0x6d505c and defaults to
                    // startup.s / @@reset before issuing a module transfer.
                    nextProgram = try candidateRepository!.load("startup.s")
                    next = try nextProgram.label("@@reset")
                    guard nextProgram.ancestors[next].isEmpty else {
                        throw ResourceError.rejected("restart_target_inside_control_block")
                    }
                    candidate.frames = [ScriptFrame(returnIndex: nil, entryLabel: "@@reset")]
                    // 0x6d50be calls 0x5a0ff4, which resets both audio banks.
                    candidate.soundChannels.removeAll()
                    candidate.directSoundChannels.removeAll()
                    candidate.timers.removeAll()
                    logJumpCheckpoints.removeAll()
                    memoryCheckpoints.removeAll()
                    candidate.serializedMemoryCheckpoints.removeAll()
                    action = "system_restart_candidate"
                case "thrd":
                    if record.fields.count == 1, try field(0) == "0",
                       candidate.linkedPrimaryPlayMode != nil {
                        // 0x6b0ff6 posts the mode-zero request to the host.
                        systemTaskExitRequested = true
                        phase = .finished
                        action = "system_task_exit_request_candidate"
                        break
                    }
                    try arity(2)
                    let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                        write: { _,_ in throw ResourceError.rejected("mutating_system_task_mode") },
                        readIndexed: { try candidate.readIndexed($0,$1) })
                    let label = try field(1)
                    let titleQuit = allowTitleQuit && asciiLower(label) == "@@!quit" &&
                        Self.isTitleQuitRequest(record.location)
                    let log = asciiLower(label) == "@@!log" && candidate.linkedPrimaryPlayMode == nil
                    guard value.integer == 1, titleQuit || log || ["@@!load", "@@!quickload"].contains(asciiLower(label)) else {
                        throw ResourceError.rejected("system_task_request_outside_profile")
                    }
                    // 0x6b1002 queues mode 1. The host dispatches the label to SysStartUp.s.
                    systemTaskResumeState = (phase, clickWaitRemaining, clickWaitInitial)
                    systemTaskRequest = SystemTaskRequest(entryLabel: label, source: record.location)
                    phase = .waitingForSystemTask
                    action = "system_load_task_request_candidate"
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
                    candidate.frames[0].ifConditions.removeAll()
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
                            let value = try ScriptExpression.parse(raw).evaluate(read: { name in
                                if asciiLower(name) == "selffilename",
                                   let source = candidateRepository?.catalog.reference(forPhysical: program.document.source.relativePath) {
                                    return .string(source.logicalPath)
                                }
                                return try candidate.read(name)
                            },
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
                                case .indexed where candidate.messages[handle] != nil || candidate.tables[handle] != nil:
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
                            let frame = candidate.frames.count - 1
                            let destinationScopes = program.ancestors[destination]
                            guard candidate.frames[frame].controls.starts(with: destinationScopes) else {
                                throw ResourceError.rejected("jump_crosses_control_scope")
                            }
                            for exited in candidate.frames[frame].controls.dropFirst(destinationScopes.count) {
                                candidate.frames[frame].forPlans.removeValue(forKey: exited)
                                candidate.frames[frame].ifConditions.removeValue(forKey: exited)
                            }
                            candidate.frames[frame].controls = destinationScopes
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
                    if let suspended = timerReturn, suspended.depth == candidate.frames.count {
                        phase = suspended.phase
                        clickWaitRemaining = suspended.clickWait
                        clickWaitInitial = suspended.clickInitial
                        timerReturn = nil
                    }
                    if stopCallbackFrameDepth == candidate.frames.count {
                        stopCallbackFrameDepth = nil
                        pendingButton = nil
                        pendingClick = false
                        pendingLoadEscape = false
                        pendingDialogueLogNavigation = nil
                        pendingDialogueLogWheel = nil
                        syntheticBarCallbackActive = false
                        callbackElapsedTicks = nil
                        pointerPosition = nil
                        if stopCallback != nil { phase = .waitingForEvent }
                    }
                    if let saved = candidate.frames.last?.savedReturnScalars {
                        try candidate.applySavedResultScalars(saved)
                    }
                    if allowLabelProgressCandidate, candidate.frames.last?.completedLineReturnCandidate == true, destination > 0 {
                        labelProgressReturnedLine = (returnProgram, destination - 1)
                    }
                    candidate.frames.removeLast(); next = destination
                default: throw ResourceError.rejected("unsupported_command")
                }
            default: throw ResourceError.rejected("unsupported_record_\(record.kind.rawValue)")
            }
            let nextRecords = nextProgram.document.records
            if target == nil, (next != oldPC+1 || Data(nextProgram.document.source.relativePath.utf8) != Data(program.document.source.relativePath.utf8)), next < nextRecords.count { target = nextRecords[next].location }
            var labelProgressOutcome: String?
            var progressSource: (program: ScriptProgram, index: Int, returned: Bool)?
            if allowLabelProgressCandidate, phase == .ready {
                if next == oldPC + 1, next < records.count, candidate.frames.count == storage.frames.count,
                   action != "local_jump", action != "module_jump_candidate",
                   nextProgram.document.source.relativePath == program.document.source.relativePath,
                   nextProgram.document.source.sha256 == program.document.source.sha256 {
                    progressSource = (program, oldPC, false)
                } else if let returned = labelProgressReturnedLine, next == returned.index + 1,
                          next < returned.program.document.records.count,
                          candidate.frames.count + 1 == storage.frames.count,
                          nextProgram.document.source.relativePath == returned.program.document.source.relativePath,
                          nextProgram.document.source.sha256 == returned.program.document.source.sha256 {
                    progressSource = (returned.program, returned.index, true)
                }
            }
            if let progress = progressSource {
                let trackedProgram = progress.program
                let trackedRecords = trackedProgram.document.records
                let trackedRecord = trackedRecords[progress.index]
                let following = trackedRecords[next]
                if ![ScriptRecordKind.bom, .include, .label].contains(trackedRecord.kind),
                   (trackedRecord.kind != .empty || trackedRecord.lineCount == 1),
                   following.location.sourceFile == trackedRecord.location.sourceFile,
                   following.location.sourceSHA256 == trackedRecord.location.sourceSHA256,
                   following.location.lineNumber > trackedRecord.location.lineNumber {
                    // The reader callback is known, but local record-to-reader
                    // correspondence is only a candidate. Prefix calls must
                    // return before treating their caller's line as complete.
                    if let anchorIndex = trackedProgram.labelProgressAnchors[progress.index],
                       let label = trackedRecords[anchorIndex].identifier, !label.isEmpty {
                        let anchorLocation = trackedRecords[anchorIndex].location
                        let relative = label.hasPrefix("!") ? nil :
                            trackedProgram.candidateLabelRelativeLine(anchor: anchorIndex, position: progress.index)
                        if label.hasPrefix("!") {
                            labelProgressOutcome = "internalLabel"
                        } else if relative == nil {
                            labelProgressOutcome = "includeOrForeignSpan"
                        } else if trackedProgram.labels[Data(asciiLower(label).utf8)] != [anchorIndex] {
                            labelProgressOutcome = "ambiguousLabel"
                        } else if let ref = candidateRepository?.catalog.reference(forPhysical: anchorLocation.sourceFile),
                                  ref.sourceSHA256 == anchorLocation.sourceSHA256,
                                  let resolved = try? candidateRepository?.catalog.resolve(ref.logicalPath),
                                  resolved.sourceFile == ref.sourceFile, resolved.sourceSHA256 == ref.sourceSHA256,
                                  let relative, let position = Int32(exactly: relative + 1),
                                  position > 0 {
                            let name = asciiLower(ref.logicalPath.replacingOccurrences(of: "/", with: "\\") + "@@" + label)
                            let key = Data(name.utf8)
                            if candidate.lineLogLockTag == nil {
                                labelProgressOutcome = "lockUnknown"
                            } else if candidate.lineLogLockTag != 0 {
                                labelProgressOutcome = "locked"
                            } else if key.count > 8192 || name.utf16.count > 4096 ||
                                        (candidate.lineLogValues.count >= 4096 && candidate.lineLogValues[key] == nil) {
                                labelProgressOutcome = "limit"
                            } else if (candidate.lineLogValues[key] ?? -1) >= position {
                                labelProgressOutcome = trackedProgram.labelHistorySimpleSpans[progress.index]
                                    ? "unchanged" : "includeUnchanged"
                            } else {
                                candidate.lineLogValues[key] = position
                                labelProgressOutcome = trackedProgram.labelHistorySimpleSpans[progress.index]
                                    ? "advanced" : "includeAdvanced"
                            }
                        } else {
                            labelProgressOutcome = "unresolvedContext"
                        }
                    } else {
                        labelProgressOutcome = "noLabel"
                    }
                    if let labelProgressOutcome {
                        labelProgressCandidateOutcomes[labelProgressOutcome, default: 0] += 1
                        if progress.returned { labelProgressReturnOutcomes[labelProgressOutcome, default: 0] += 1 }
                        if ["advanced", "includeAdvanced", "includeOrForeignSpan", "lockUnknown", "unresolvedContext"].contains(labelProgressOutcome),
                           labelProgressFirstContexts[labelProgressOutcome] == nil {
                            let anchor = trackedProgram.labelProgressAnchors[progress.index].map { trackedRecords[$0].location }
                            labelProgressFirstContexts[labelProgressOutcome] = .init(position: trackedRecord.location, anchor: anchor,
                                programSource: trackedProgram.document.source.location(0..<0, line: 1), callDepth: storage.frames.count)
                        }
                    }
                }
            }
            if let pendingSaveWrite {
                if saveWriteHandler == nil, allowPrimarySave,
                   let request = makePrimarySaveRequest(record: record, next: next, name: pendingSaveWrite.name,
                                                        metadata: pendingSaveWrite.metadata, candidate: candidate) {
                    primarySaveRequest = request
                    phase = .waitingForPrimarySave
                    action = asciiLower(request.name) == "exceptionbackup.svd"
                        ? "exception_backup_requested" : "primary_autosave_requested"
                } else {
                    do {
                        guard let saveWriteHandler else {
                            throw ResourceError.rejected("save_write_context_unavailable")
                        }
                        candidate.clearResultBindings()
                        try candidate.resultInteger(1)
                        let publication = try saveWriteHandler(pendingSaveWrite.name, pendingSaveWrite.metadata, candidate,
                                                               systemDataSaveTarget?.sha256)
                        action = recordSlotPublication(publication, into: &candidate)
                    } catch {
                        lastSaveWriteIssue = String(describing: error)
                        candidate.clearResultBindings()
                        try candidate.resultInteger(0)
                        action = "save_slot_write_failed"
                    }
                }
            }
            if let pendingSaveDeletion {
                let name = asciiLower(pendingSaveDeletion)
                let key = Data(name.utf8)
                let selection = pendingSlotDeletion
                let startupCleanup = cleanShutdownInProgress &&
                    Self.isStartupCleanupSite(record.location, line: 37) && name == "exceptionbackup.svd"
                pendingSlotDeletion = nil
                do {
                    let confirmedMenuSlot = selection.map { $0.confirmed && $0.name == name } ?? false
                    guard (startupCleanup || confirmedMenuSlot), name.hasSuffix(".svd"),
                          let directory = saveDirectory, saveHeaderTemplate != nil else {
                        throw ResourceError.rejected("save_delete_slot_not_confirmed_or_unavailable")
                    }
                    if startupCleanup, let issue = lastSaveWriteIssue {
                        throw ResourceError.rejected(issue)
                    }
                    let deletion: (removed: Bool, syncError: Int32?) = try SaveTransaction.withRecoveredDirectory(directory) { _ in
                        let entries = try directory.entries()
                        let resolved = try Self.resolveSaveSlotName(pendingSaveDeletion, entries: entries)
                        if startupCleanup, saveSources[key] == nil {
                            guard !entries.contains(where: { $0.name == resolved }) else {
                                throw ResourceError.rejected("startup_backup_not_verified_for_cleanup")
                            }
                            return (false, nil)
                        }
                        guard try candidate.containsSessionSave(pendingSaveDeletion), let source = saveSources[key],
                              startupCleanup || source.sha256 == selection?.sha256 else {
                            throw ResourceError.rejected("save_delete_slot_not_confirmed_or_unavailable")
                        }
                        guard resolved == source.name else { throw ResourceError.rejected("save_delete_destination_changed") }
                        let syncError = try directory.removeMatchingFile(source.name, sha256: source.sha256,
                                                                         limit: SaveEnvelope.maxFileBytes)
                        return (true, syncError)
                    }
                    candidate.forgetSessionSaveSlot(key)
                    saveSources.removeValue(forKey: key)
                    lastSaveWriteIssue = deletion.syncError.map { "save_committed_directory_sync_unconfirmed_errno_\($0)" }
                    if !deletion.removed {
                        try candidate.resultInteger(0)
                        action = "startup_backup_cleanup_absent"
                    } else if deletion.syncError != nil {
                        action = "save_slot_delete_durability_unconfirmed"
                    } else {
                        action = startupCleanup ? "startup_backup_cleanup_removed" : "save_slot_delete_candidate"
                    }
                } catch {
                    lastSaveWriteIssue = String(describing: error)
                    candidate.clearResultBindings()
                    try candidate.resultInteger(0)
                    action = "save_slot_delete_failed"
                }
            }
            storage = candidate; repository = candidateRepository; pc = next; program = nextProgram; pendingModuleCandidates = []
            callDepthProbeMinimum = min(callDepthProbeMinimum ?? storage.frames.count, storage.frames.count)
            let activeStreamsAfter = Set(storage.soundChannels.compactMap { handle, channel -> Int32? in
                guard channel.playing else { return nil }
                return ScriptStorage.streamChannelIndex(handle)
            })
            if activeStreamsBefore != activeStreamsAfter || swappedStreamHandles != nil {
                if streamChannelTransitions.count < 256 {
                    streamChannelTransitions.append(.init(step: executedSteps + 1, location: record.location,
                        action: action, before: activeStreamsBefore.sorted(), after: activeStreamsAfter.sorted(),
                        swappedHandles: swappedStreamHandles))
                } else {
                    streamChannelTransitionsOmitted += 1
                }
            }
            if let labelHistoryReadOutcome {
                labelHistoryReadOutcomes[String(labelHistoryReadOutcome), default: 0] += 1
            }
            if let unreadLabelProbe {
                if researchUnreadLabelQueries.count < 16 {
                    researchUnreadLabelQueries.append(.init(step: executedSteps + 1, location: record.location, probe: unreadLabelProbe))
                } else { researchUnreadLabelQueriesTruncated = true }
            }
            if let imageFileLogOutcome {
                imageFileLogCandidateAttempts += 1
                imageFileLogCandidateOutcomes[imageFileLogOutcome.rawValue, default: 0] += 1
                if imageFileLogOutcome == .matched { imageFileLogCandidateMatches += 1 }
            }
            if let audioFileLogOutcome {
                audioFileLogCandidateAttempts += 1
                audioFileLogCandidateOutcomes[audioFileLogOutcome.rawValue, default: 0] += 1
            }
            if let imageFileLogSnapshot { firstImageFileLogNoMatchSnapshot = imageFileLogSnapshot }
            if let result { lastResult = result }
            let item = trace(.inferred,action,target: target,skipped: skip,resultType: result?.typeName,resource: resourceLocation)
            recordTrace(item); return item
        } catch {
            if let failure = error as? ScriptTableFailure { resourceLocation = failure.location }
            let failureReason = String(describing: error)
            if var continuation = macExceptionBackupContinuation {
                continuation.saveIssue = "exception-save-script-error: \(failureReason)"
                macExceptionBackupContinuation = continuation
                stopReason = "mac_exception_backup_failed: \(continuation.saveIssue!)"
            } else {
                stopReason = failureReason
            }
            phase = .stopped
            if scriptStepFailure == nil, macExceptionBackupContinuation == nil {
                let source = program.document.source
                scriptStepFailure = ScriptStepFailure(location: record.location,
                    programSourceFile: source.relativePath, programSourceSHA256: source.sha256,
                    programCounter: oldPC, reason: stopReason ?? "script_step_failed")
            }
            if stopReason == "ambiguous_module_variants", let variants = candidateRepository?.pendingVariants, !variants.isEmpty {
                pendingModuleCandidates = variants
            }
            let item = trace(.unsupported,"stop",reason: stopReason,resource: resourceLocation)
            recordTrace(item); return item
        }
    }
    private mutating func recordTrace(_ item: ScriptTrace) {
        executedSteps += 1
        if let source = coverageSourceFile, item.status == .inferred,
           item.location.sourceFile == source, item.recordType == .command || item.recordType == .label {
            if var entry = sourceCoverage[item.location] {
                entry.lastStep = item.sequence
                entry.executions += 1
                sourceCoverage[item.location] = entry
            } else if sourceCoverage.count < 4096 {
                sourceCoverage[item.location] = ScriptSourceCoverageEntry(location: item.location,
                    recordType: item.recordType, firstStep: item.sequence, lastStep: item.sequence, executions: 1)
            } else {
                sourceCoverageTruncated = true
            }
        }
        if captureSourceVisits, item.status == .inferred, previousVisitSource != item.location.sourceFile {
            let name = item.location.sourceFile
            previousVisitSource = name
            if var visit = sourceVisits[name] {
                visit.lastStep = item.sequence
                visit.lastLocation = item.location
                visit.entries += 1
                sourceVisits[name] = visit
            } else if sourceVisits.count < 512 {
                sourceVisits[name] = ScriptSourceVisit(firstStep: item.sequence, firstLocation: item.location,
                                                      lastStep: item.sequence, lastLocation: item.location, entries: 1)
            } else {
                sourceVisitsTruncated = true
            }
        }
        traces.append(item)
        if !retainFullTrace, traces.count == 2048 {
            traces.removeFirst(1024)
        }
    }

}
