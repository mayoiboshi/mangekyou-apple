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
    let blocks: [Int: ScriptControlBlock]
    let startsByEnd: [Int: Int]
    let startsByMarker: [Int: Int]
    let ancestors: [[Int]]
    let traceCommands: [Data: (safe: String?, sha256: String)]

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
        self.traceCommands = traceCommands
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

public enum ScriptMachinePhase: String, Encodable, Sendable {
    case ready, waiting, waitingForEvent, waitingForMedia, waitingForSystemTask, waitingForScreenCapture, finished, stopped
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
    package private(set) var executedSteps = 0
    public private(set) var traces: [ScriptTrace] = []
    public private(set) var lastResult: ScriptValue?
    public private(set) var stopReason: String?
    public private(set) var pc: Int
    private var storage = ScriptStorage()
    private var saveDirectory: SafeDirectory?
    private var inferSaveStateSeed = false
    private var saveHeaderTemplate: Data?
    private var saveSources: [Data: (name: String, sha256: String, verifyHeader: Bool)] = [:]
    package enum SavedDisplayPreview: Sendable {
        case externalImage(Data, SaveStatePrefix.DisplaySummary.Reload.Transform)
        case rectangle(SaveStatePrefix.DisplaySummary.ProceduralRect)
        case capturedSurface(Data)
    }

    package struct SavedDisplayDraw: Encodable, Sendable {
        package var interfaceBackgroundPreviews: [ScriptLocation]? = nil
        package let status: EvidenceStatus
        let width: Int?
        let height: Int?
        let pixelSHA256: String?
        package let issue: String?

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
        case capture(Int32)
        case overlapSample(Int32, elapsed: UInt32, duration: UInt32)
    }
    package var savedEventSampleTicks: Int32?
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
        var isolatedCallFrameIssue: String? = nil
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
        package var stagedStreamSeeks: [(recordOffset: Int, source: ScriptLocation, milliseconds: Int32, status: EvidenceStatus, issue: String?)] {
            (streamedSoundResources ?? []).compactMap { match in
                guard let source = match.stagedLocation, let milliseconds = match.requestedSeekMilliseconds,
                      let status = match.seekStatus else { return nil }
                return (match.recordOffset, source, milliseconds, status, match.seekIssue)
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
            var signature: String? = nil
            var issue: String? = nil
        }
        var nestedDisplayResourceCheck: NestedDisplayResourceCheck? = nil
        struct SavedButtonImageCheck: Encodable, Sendable {
            let objectDecodedOffset: Int
            let resource: NestedDisplayResourceCheck
        }
        var savedButtonImageChecks: [SavedButtonImageCheck]? = nil
        var savedImageResourceChecks: [SavedButtonImageCheck]? = nil
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
        var unstagedGlobalObjectArrayCount: Int? = nil
        var stagedGlobalButtonIdentityArrayCount: Int? = nil
        var globalButtonIdentityIssue: String? = nil
        var stagedGlobalImageIdentityArrayCount: Int? = nil
        var stagedGlobalInactiveTimerArrayCount: Int? = nil
        var globalTimerIdentityIssue: String? = nil
        var globalImageIdentityIssue: String? = nil
        var isolatedStorageIssue: String? = nil
        var firstAbsentGlobalBindingOffset: Int? = nil
        var globalTextObjectIssue: String? = nil
        var engineState: SaveEngineState? = nil
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
    private var logJumpCheckpoints: [LogJumpCheckpoint] = []

    private var callbackElapsedTicks: Int32?
    private var pendingClick = false
    private var pendingLoadEscape = false
    private var pendingButton: UInt64?
    private var pointerPosition: (x: Int32, y: Int32)?
    public private(set) var timedStopRequest: (duration: Int32, alternateDuration: Int32)?
    private var stopCallback: Int?
    private var stopCallbackFrameDepth: Int?
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
                if let savedMode = transition.savedMode { return savedMode == 1 }
                return canStartFromTitle || image.motion?.mode == 3
            }
            return storage.enabledButtons.contains(handle)
                && (canStartFromTitle || storage.buttonMotion[handle]?.mode == 3)
        }
    }

    package func hasAdvancingImage(sourceSHA256: String) -> Bool {
        storage.images.values.contains {
            $0.isDrawable && $0.resource?.sourceSHA256 == sourceSHA256 &&
                $0.motionStartTick != nil && ($0.playbackSpeed ?? 100) > 0
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

    /// Advance the headless visual clock to known endpoints.
    public mutating func advancePlacementClock(ticks: Int32) throws {
        guard ticks >= 0 else { throw ResourceError.rejected("negative_placement_ticks") }
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
        storage.visualTicks += min(Int64(ticks), Int64.max - storage.visualTicks)
        advanceOpacityClock(ticks: ticks)
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
        public var isTheoraResource = false
        package var boundTextureLocations: [Int32: ScriptLocation] = [:]
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

    public var staticImageLayers: [StaticImageLayer] {
        let sampleTitlePlacement = canStartFromTitle
        func hasUnappliedTransform(_ transform: ScriptStorage.ImageTransform?) -> Bool {
            guard let transform else { return false }
            return transform.depth != 0 || transform.scale[2] != 100 || transform.rotation.contains { $0 != 0 }
        }
        func position(_ handle: UInt64, _ placement: [Int32]) -> (Int32, Int32) {
            let settings = storage.images[handle]?.motion ?? storage.buttonMotion[handle]
            guard let motion = storage.placementTransitions[handle], motion.savedMode != 0,
                  sampleTitlePlacement || settings?.mode == 3 || motion.savedMode == 1 else {
                return (placement[0], placement[1])
            }
            // Script queries still see the committed placement. The original
            // position evaluator quantizes remaining time to 1/1024 (0x5ab3ee).
            let fraction = motion.quantizedProgress
            let progress: Double
            if let settings, settings.mode == 3 {
                // Mode 3 dispatches to 0x50ba30. The original executable
                // initializes the alternate-curve flag to zero.
                progress = 1 - pow(1 - fraction, 1 + 1.4 * Double(settings.strength) / 100)
            } else {
                progress = fraction
            }
            func axis(_ index: Int) -> Int32 {
                if motion.savedMode == 1 {
                    return motion.sampleSavedLinearAxis(from: placement[index], to: motion.destination[index])
                }
                let start = Double(placement[index])
                return Int32((start + (Double(motion.destination[index]) - start) * progress).rounded())
            }
            return (axis(0), axis(1))
        }
        let images: [StaticImageLayer] = storage.images.compactMap { handle, image in
            guard image.isDrawable, let resource = image.resource,
                  let placement = image.placement, placement.count >= 3 else { return nil }
            let (x, y) = position(handle, placement)
            var scale = image.transform?.scale ?? [100, 100, 100]
            var priority = placement[2]
            if let motion = storage.placementTransitions[handle], motion.savedMode == 1,
               let target = motion.destinationTransform?.scale {
                // 0x5ab599 samples priority with the same evaluator as position.
                priority = motion.sampleSavedLinearAxis(from: priority, to: motion.destination[2])
                for axis in 0..<2 {
                    scale[axis] = motion.sampleSavedLinearAxis(from: scale[axis], to: target[axis])
                }
            }
            return StaticImageLayer(id: handle, resource: resource, x: x, y: y,
                                    priority: priority, selectedMember: image.selectedMember,
                                    motionElapsedTicks: image.motionElapsedHundredths(at: storage.visualTicks).map { Int32($0 / 100) },
                                    motionIsAdvancing: image.motionStartTick != nil && (image.playbackSpeed ?? 100) > 0, opacity: image.presentedOpacity,
                                    scaleXPercent: scale[0],
                                    scaleYPercent: scale[1], hoverResource: nil,
                                    boundRasterPreview: image.boundImages[0],
                                    hasExplicitAlignment: image.alignment != nil, alignmentXPercent: image.alignment?.x ?? 0, alignmentYPercent: image.alignment?.y ?? 0, textureFilter: image.textureFilter,
                                    unappliedTransform: hasUnappliedTransform(image.transform), drawChannel: image.drawChannel,
                                    isTheoraResource: image.isTheoraResource, boundTextureLocations: image.boundImages)
        }
        let buttons: [StaticImageLayer] = storage.enabledButtons.compactMap { handle in
            let container = storage.buttonResources[handle]
            // The audited load-page *OnCheck action draws texture slot 1.
            let checkedPage = storage.buttonCheckVisual[handle, default: 0] != 0 &&
                container.map { asciiLower($0.sourceFile).hasSuffix("/script/saveload/button_page.b") } == true
            let textures = storage.buttonImages[handle]
            let checkedTexture = checkedPage ? textures?[1] : nil
            guard let resource = checkedTexture ?? textures?[0] ?? container,
                  let placement = storage.buttonPlacement[handle], placement.count >= 3 else { return nil }
            let (x, y) = position(handle, placement)
            let scale = storage.savedButtonPlacementScale[handle] ?? SIMD2(100, 100)
            return StaticImageLayer(id: handle, resource: resource, x: x, y: y,
                                    priority: placement[2], selectedMember: nil, motionElapsedTicks: nil,
                                    motionIsAdvancing: false, opacity: 255, scaleXPercent: scale.x, scaleYPercent: scale.y,
                                    hoverResource: !checkedPage && storage.buttonLocks[handle, default: 0] == 0 ? textures?[1] : nil,
                                    boundRasterPreview: nil, hasExplicitAlignment: false, alignmentXPercent: 0, alignmentYPercent: 0, textureFilter: nil, unappliedTransform: false, drawChannel: nil)
        }
        let backgrounds: [StaticImageLayer] = storage.messages.compactMap { handle, message in
            guard message.enabled, let resource = message.background,
                  let placement = message.placement, placement.count >= 3 else { return nil }
            return StaticImageLayer(id: handle, resource: resource, x: placement[0], y: placement[1],
                                    priority: placement[2], selectedMember: message.backgroundSelectedMember,
                                    motionElapsedTicks: message.backgroundMotionStartTick.map { Int32(clamping: storage.visualTicks - $0) },
                                    motionIsAdvancing: message.backgroundMotionStartTick != nil, opacity: 255,
                                    scaleXPercent: message.transform?.scale[0] ?? 100,
                                    scaleYPercent: message.transform?.scale[1] ?? 100, hoverResource: nil, boundRasterPreview: nil,
                                    hasExplicitAlignment: message.alignment != nil, alignmentXPercent: message.alignment?.0 ?? 0, alignmentYPercent: message.alignment?.1 ?? 0, textureFilter: nil,
                                    unappliedTransform: hasUnappliedTransform(message.transform), drawChannel: message.drawChannel)
        }
        return (images + buttons + backgrounds).sorted { ($0.priority, $0.id) < ($1.priority, $1.id) }
    }

    public struct MessageTextLayer: Sendable {
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
            public var horizontalAdvance: Int32? = nil
        }

        public let id: UInt64
        public let runs: [Run]
        public var text: String { runs.map(\.text).joined() }
        public let canvasBounds: [Int64]?
        public let surfaceMargins: [Int32]
        public let x: Int32
        public let y: Int32
        public let scaleXPercent: Int32
        public let scaleYPercent: Int32
        public let isVisible: Bool
        public let priority: Int32?
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
            var runs: [MessageTextLayer.Run] = []
            var width: Int32 = 24
            var height: Int32 = 24
            var colorARGB: UInt32 = 0xffff_ffff
            func fontName(_ slot: Int32) -> String? {
                let key = "Font[\(slot)].Name"
                if case .string(let override) = storage.fontOverrides[key] { return override }
                return try? storage.configuration?.value(for: key)
            }
            var currentFont = fontName(0)
            var rubyFont: String?
            var rubyWidth: Int32?
            var rubyHeight: Int32?
            var rubyColor: UInt32?
            for operation in message.committedOutput {
                switch operation {
                case .text(let text):
                    if !text.isEmpty { runs.append(.init(text: text, width: width, height: height, ruby: nil, colorARGB: colorARGB, fontName: currentFont)) }
                case .ruby(let base, let annotation):
                    if !base.isEmpty {
                        let ruby = MessageTextLayer.Ruby(text: annotation, fontName: rubyFont,
                                                        width: rubyWidth, height: rubyHeight, colorARGB: rubyColor)
                        runs.append(.init(text: base, width: width, height: height, ruby: ruby,
                                          colorARGB: colorARGB, fontName: currentFont))
                    }
                case .directive("n", _):
                    runs.append(.init(text: "\n", width: width, height: height, ruby: nil, colorARGB: colorARGB, fontName: currentFont))
                case .directive("i", let operands) where operands[0] > 0:
                    runs.append(.init(text: "", width: width, height: height, ruby: nil, colorARGB: colorARGB,
                                      fontName: currentFont, horizontalAdvance: operands[0]))
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
                case .directive:
                    break
                }
            }
            guard !runs.isEmpty else { return nil }
            var canvasBounds: [Int64]?
            if message.enabled, let placement = message.placement, placement.count >= 3,
               let bounds = message.textBounds, bounds.count == 4, bounds[2] > bounds[0], bounds[3] > bounds[1] {
                var origin = placement.prefix(2).map(Int64.init)
                if message.usesTimedCenterText, bounds[0] == 0, bounds[1] == 0 {
                    // The audited type-4 key anchors the live message surface at 50% on both axes.
                    origin[0] -= (Int64(bounds[2]) + 1) / 2
                    origin[1] -= (Int64(bounds[3]) + 1) / 2
                }
                canvasBounds = bounds.enumerated().map { index, endpoint in
                    Int64(endpoint) + origin[index % 2]
                }
            }
            return MessageTextLayer(id: handle, runs: runs, canvasBounds: canvasBounds,
                                    surfaceMargins: message.textMargins ?? [0, 0],
                                    x: message.placement?[0] ?? 0, y: message.placement?[1] ?? 0,
                                    scaleXPercent: message.transform?.scale[0] ?? 100,
                                    scaleYPercent: message.transform?.scale[1] ?? 100, isVisible: message.enabled,
                                    priority: canvasBounds == nil ? nil : message.placement?[2])
        }
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
                  storage.enabledButtons.contains(handle), storage.buttonLocks[handle, default: 0] == 0,
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
            storage.buttonLocks[$0, default: 0] == 0 &&
            ["@@!pagechange", "@@!cancel", "@@!data"].contains((storage.buttonUserStrings[$0]?[0]).map(asciiLower) ?? "")
        })
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

    package var loadConfirmationButtons: [UInt64: Bool] {
        guard isWaitingForLoadConfirmation else { return [:] }
        var buttons: [UInt64: Bool] = [:]
        for handle in storage.enabledButtons where storage.buttonLocks[handle, default: 0] == 0 {
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
        guard !loadMenuButtons.isEmpty else {
            throw ResourceError.rejected("load_menu_escape_outside_profile")
        }
        try dispatchStopCallback()
        pendingLoadEscape = true
    }

    public mutating func dispatchLoadMenuButton(_ handle: UInt64, x: Int32, y: Int32) throws {
        guard loadMenuButtons.contains(handle) else {
            throw ResourceError.rejected("load_menu_button_not_selectable")
        }
        try dispatchStopCallback(pointer: (x, y), click: true)
        pendingButton = handle
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
        visibleStoryChoiceButtons.filter { storage.buttonLocks[$0.key, default: 0] == 0 }
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
              storage.enabledButtons.contains(handle), storage.buttonLocks[handle, default: 0] == 0,
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
              storage.enabledButtons.contains(handle), storage.buttonLocks[handle, default: 0] == 0,
              let target = storage.buttonUserStrings[handle]?[1],
              asciiLower(target) == "@@!avg_onsysbutton_view" else { return nil }
        return handle
    }

    package var windowLoadButton: UInt64? {
        guard phase == .waitingForEvent, stopCallback != nil, stopCallbackFrameDepth == nil,
              timedStopRequest == nil, !isWaitingForStoryChoice, !isDialogueWindowHidden,
              case .object(let handle) = try? storage.readIndexed("SysButton", 5),
              storage.enabledButtons.contains(handle), storage.buttonLocks[handle, default: 0] == 0,
              storage.buttonUserStrings[handle]?[0].map(asciiLower) == "load",
              storage.buttonUserStrings[handle]?[1].map(asciiLower) == "@@!load" else { return nil }
        return handle
    }

    package mutating func dispatchWindowLoadButton(_ handle: UInt64) throws {
        guard windowLoadButton == handle, let source = playbackStatus.currentLocation else {
            throw ResourceError.rejected("window_load_button_not_selectable")
        }
        // Native host entry for the audited SysButton[5] registration.
        systemTaskRequest = SystemTaskRequest(entryLabel: "@@!Load", source: source)
        returnsToDialogueAfterLoad = true
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
    private var systemLoadTaskID: UUID?
    package var retainExperimentalSaveCandidate = false
    private struct SavedExecutionCandidate: Sendable {
        let program: ScriptProgram
        let index: Int
        let storage: ScriptStorage
        let repository: ScriptRepository?
        let wait: Int32?
        let clickInitial: Int32?
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
        soundPlaybackChannel = channel
        soundPlaybackRequest = storage.soundChannels[channel]?.resource
        phase = .waitingForMedia
    }

    package struct ExperimentalSaveAudio: Encodable, Sendable {
        package struct Gap: Encodable, Sendable {
            let recordOffset: Int
            let reason: String
            let status: EvidenceStatus = .unsupported
        }
        package var stagedStreams = 0
        package var scheduledStreams = 0
        package var scheduledDirectSounds = 0
        package var gaps: [Gap] = []
    }

    @discardableResult
    package mutating func adoptExperimentalSaveCandidate(
        from task: ScriptMachine, directBufferBytes: ((ScriptLocation) throws -> Int)? = nil
    ) throws -> ExperimentalSaveAudio {
        guard retainExperimentalSaveCandidate, phase == .waitingForSystemTask,
              let rollback = systemLoadRollback, rollback.id == task.systemLoadTaskID,
              task.phase == .stopped, task.stopReason == "save_restore_execution_state_unsupported",
              let staged = task.savedExecutionCandidate else {
            throw ResourceError.rejected("saved_execution_candidate_unavailable")
        }
        guard var restored = try Self.makeSavedExecutionMachine(
            program: staged.program, index: staged.index, storage: staged.storage,
            repository: staged.repository, wait: staged.wait, clickInitial: staged.clickInitial,
            maximumSteps: maximumSteps, maximumFrames: maximumFrames, retainFullTrace: retainFullTrace,
            imageLoader: imageLoader, imageMemberLookup: imageMemberLookup,
            imageExtendedValues: imageExtendedValues, imageMotionNames: imageMotionNames
        ) else { throw ResourceError.rejected("saved_execution_candidate_invalid") }
        var audio = ExperimentalSaveAudio()
        if let boundary = task.saveResumeBoundary, let prefix = boundary.statePrefix {
            let streamRecords = Dictionary(uniqueKeysWithValues: prefix.ssndReferences.map {
                ($0.record.decodedOffset, $0.streamChannel)
            })
            let seeks = Dictionary(uniqueKeysWithValues: boundary.stagedStreamSeeks.filter { seek in
                if seek.status == .verified { return true }
                // Accept the float representation produced by our integer-ms
                // writer. This does not establish the original x87 rounding mode.
                guard seek.status == .inferred, let record = streamRecords[seek.recordOffset],
                      let stream = record else { return false }
                return stream.matchesEncodedMilliseconds(seek.milliseconds)
            }.map { ($0.recordOffset, $0) })
            let directRequests = Dictionary(uniqueKeysWithValues: boundary.stagedSoundRequests.map { ($0.recordOffset, $0) })
            var directProbes = 0
            for record in prefix.dsndReferences where record.directReloadRequested == true {
                let offset = record.record.decodedOffset
                guard let request = directRequests[offset],
                      request.startOffset == 0, request.slotIndex < 64 else {
                    audio.gaps.append(.init(recordOffset: offset,
                                            reason: "saved_direct_channel_restore_unsupported"))
                    continue
                }
                if let minimum = request.minimumDecodedBytes {
                    guard let directBufferBytes, directProbes < 4 else {
                        audio.gaps.append(.init(recordOffset: offset, reason: "saved_direct_buffer_check_unavailable"))
                        continue
                    }
                    directProbes += 1
                    do {
                        // A short buffer intentionally does not start in mode 2.
                        guard try directBufferBytes(request.source) >= minimum else { continue }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        audio.gaps.append(.init(recordOffset: offset, reason: "saved_direct_buffer_check_failed"))
                        continue
                    }
                }
                // 0x5a100c dispatches direct buffers to a separate bank.
                // Keep their host playback IDs outside the indexed stream range.
                let handle = UInt64.max - 2048 - UInt64(request.slotIndex)
                restored.storage.soundChannels[handle] = .init(loopRequest: request.looping ? -1 : 0, volume: request.volumeInput,
                                                               resource: request.source)
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
                // 0x5a053e and 0x5a0560 set volume and pan before the play gate.
                restored.storage.soundChannels[handle] = .init(seekRequest: seek.milliseconds,
                    panRequest: (stream.resumePan, 0, 0), volume: stream.resumeVolume, resource: seek.source)
                audio.stagedStreams += 1
                if let repeats = stream.resumeRepeatCount {
                    if repeats >= -1 {
                        restored.storage.soundChannels[handle]?.loopRequest = repeats
                        // 0x5a0528–0x5a056a sets zero gain, requests a 2000 ms
                        // transition to the stored gain, and restores pan immediately.
                        restored.storage.soundChannels[handle]?.volumeDuration = 2000
                        restored.storage.soundChannels[handle]?.volumeChangePending = true
                        restored.savedAudioStarts.append(handle)
                        audio.scheduledStreams += 1
                    } else {
                        audio.gaps.append(.init(recordOffset: record.record.decodedOffset,
                                                reason: "saved_stream_repeat_counter_unresolved"))
                    }
                }
            }
        }
        if !restored.savedAudioStarts.isEmpty {
            restored.phaseAfterSavedAudioStarts = restored.phase
            restored.startNextSavedAudio()
        }
        restored.replayEffectSurface = task.savedCapturedDisplay
        restored.saveDirectory = saveDirectory
        restored.saveSources = saveSources
        restored.saveHeaderTemplate = saveHeaderTemplate
        restored.inferSaveStateSeed = inferSaveStateSeed
        restored.retainExperimentalSaveCandidate = retainExperimentalSaveCandidate
        restored.savedMotionUpdateThreshold = savedMotionUpdateThreshold
        self = restored
        return audio
    }

    private var failedSaveRestore = false
    private var returnsToDialogueAfterLoad = false
    private var systemLoadRollback: (id: UUID, bindings: [Data: ScriptBinding], mask: Int32, mode: Int32)?

    public mutating func finishSystemLoadTask(_ task: ScriptMachine) throws {
        guard phase == .waitingForSystemTask, task.systemTaskExitRequested,
              let rollback = systemLoadRollback, task.systemLoadTaskID == rollback.id else {
            throw ResourceError.rejected("system_task_exit_required")
        }
        systemLoadRollback = nil
        phase = returnsToDialogueAfterLoad ? .waitingForEvent : .ready
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
            storage.systemPlayMode = rollback.mode
        }
        systemLoadRollback = nil
        systemTaskRequest = nil
        phase = returnsToDialogueAfterLoad ? .waitingForEvent : .ready
        returnsToDialogueAfterLoad = false
        return true
    }

    public struct ScreenCaptureRequest: Sendable {
        public let priority: Int32
        fileprivate let handle: UInt64
        fileprivate let location: ScriptLocation
    }
    public private(set) var screenCaptureRequest: ScreenCaptureRequest?

    public mutating func supplyScreenCapture(_ source: ScriptLocation, width: Int, height: Int) throws {
        guard phase == .waitingForScreenCapture, let request = screenCaptureRequest,
              var image = storage.images[request.handle],
              width == 1280, height == 720, source.byteOffset == 0,
              (1...8 * 1024 * 1024).contains(source.byteLength) else {
            throw ResourceError.rejected("invalid_game_thread_image_capture")
        }
        image.resource = source
        image.isTheoraResource = false
        image.resourceLoadLocation = request.location
        image.width = width
        image.height = height
        image.memberCount = 1
        image.selectedMember = nil
        image.motionStartTick = nil
        image.restoredMotionThreshold = nil
        image.restoredMotionRemainder = 0
        image.boundImages.removeAll()
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
            retainFullTrace: retainFullTrace)
        task.storage.linkedPrimaryPlayMode = storage.systemPlayMode
        task.storage.linkedPrimaryInputMask = storage.systemInputMask
        task.storage.fileLogValues = storage.fileLogValues
        task.storage.lineLogValues = storage.lineLogValues
        task.storage.sessionSaveNames = storage.sessionSaveNames
        task.storage.sessionSaveMetadata = storage.sessionSaveMetadata
        task.storage.sessionSaveThumbnails = storage.sessionSaveThumbnails
        task.saveDirectory = saveDirectory
        task.inferSaveStateSeed = inferSaveStateSeed
        task.saveHeaderTemplate = saveHeaderTemplate
        task.inspectSaveRestoreBoundary = inspectSaveRestoreBoundary
        task.savedMotionUpdateThreshold = savedMotionUpdateThreshold
        task.saveSources = saveSources
        task.retainExperimentalSaveCandidate = retainExperimentalSaveCandidate
        let taskID = UUID()
        task.systemLoadTaskID = taskID
        systemLoadRollback = (taskID, storage.system, storage.systemInputMask, storage.systemPlayMode)
        systemTaskRequest = nil
        return task
    }

    public mutating func runSystemLoadTask(_ task: inout ScriptMachine) throws {
        guard phase == .waitingForSystemTask, task.storage.linkedPrimaryPlayMode != nil,
              let rollback = systemLoadRollback, task.systemLoadTaskID == rollback.id else {
            throw ResourceError.rejected("linked_system_task_required")
        }
        task.storage.linkedPrimaryPlayMode = storage.systemPlayMode
        task.storage.linkedPrimaryInputMask = storage.systemInputMask
        // The primary machine is suspended while the task uses the shared svar table.
        task.storage.system = storage.system
        defer {
            storage.system = task.storage.system
            if let mask = task.storage.linkedPrimaryInputMask { storage.systemInputMask = mask }
            if let mode = task.storage.linkedPrimaryPlayMode { storage.systemPlayMode = mode }
        }
        try task.run(stepQuota: 15_000)
    }

    public private(set) var soundPlaybackRequest: ScriptLocation?
    public private(set) var soundPlaybackChannel: UInt64?
    public private(set) var soundPlaybackPreservesPosition = false
    public var activeSoundChannels: Set<UInt64> {
        Set(storage.soundChannels.compactMap { $0.value.playing ? $0.key : nil })
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
    }

    public mutating func takeSoundVolumeChanges() -> [UInt64: SoundControlChange] {
        var changes: [UInt64: SoundControlChange] = [:]
        for channel in activeSoundChannels {
            guard var sound = storage.soundChannels[channel], sound.volumeChangePending,
                  let target = sound.volume else { continue }
            changes[channel] = SoundControlChange(target: target, duration: sound.volumeDuration ?? 0,
                                                delay: sound.volumeDelay ?? 0)
            sound.volumeChangePending = false
            storage.soundChannels[channel] = sound
        }
        return changes
    }

    public mutating func takeSoundPanChanges() -> [UInt64: SoundControlChange] {
        var changes: [UInt64: SoundControlChange] = [:]
        for channel in activeSoundChannels {
            guard var sound = storage.soundChannels[channel], sound.panChangePending,
                  let pan = sound.panRequest else { continue }
            changes[channel] = SoundControlChange(target: pan.position, duration: pan.duration, delay: pan.delay)
            sound.panChangePending = false
            storage.soundChannels[channel] = sound
        }
        return changes
    }

    public var immediateSoundPans: [UInt64: Int32] {
        storage.soundChannels.compactMapValues { channel in
            guard channel.playing else { return nil }
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

    package mutating func takePendingPlaybackSeek() -> Int32? {
        guard let channel = soundPlaybackChannel,
              let seek = storage.soundChannels[channel]?.seekRequest else { return nil }
        storage.soundChannels[channel]?.seekRequest = nil
        return seek
    }

    package var soundPlaybackInitialVolume: Int32? {
        guard phaseAfterSavedAudioStarts != nil, let channel = soundPlaybackChannel,
              storage.soundChannels[channel]?.volumeDuration == 2000 else { return nil }
        return 0
    }

    public var soundPlaybackRepeatCount: Int32 {
        // At EOF, 0x57594b stops at zero and 0x575966 decrements a positive count before restarting.
        soundPlaybackChannel.flatMap { storage.soundChannels[$0]?.loopRequest } ?? 0
    }

    public mutating func acknowledgeSoundPlayback() throws {
        guard phase == .waitingForMedia, soundPlaybackRequest != nil else {
            throw ResourceError.rejected("pending_sound_required")
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
        guard storage.soundChannels[channel]?.playbackStartStep == playbackStartStep else { return }
        storage.soundChannels[channel]?.playing = false
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

    struct SavedCalculationContinuation: Encodable, Sendable {
        var steps: [ScriptTrace]
        let nextLocation: ScriptLocation?
        let stopReason: String
        var waitRemaining: Int32? = nil
        var simulatedSavedWaitTicks: Int32? = nil
        var pendingDrawCount: Int32? = nil
        var previewDraw: SavedDisplayDraw? = nil
        var sceneDraw: SavedDisplayDraw? = nil
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
                                      storage: inout ScriptStorage) throws {
        guard program.ancestors.indices.contains(index) else {
            throw ResourceError.rejected("saved_active_control_stack_shape")
        }
        let starts = program.ancestors[index]
        guard !starts.isEmpty, starts.count == blocks.count, storage.frames.count == 1 else {
            throw ResourceError.rejected("saved_active_control_stack_shape")
        }
        var plans: [Int: ScriptForPlan] = [:]
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
        storage.frames[0].controls = starts
        storage.frames[0].forPlans = plans
    }

    static func stageSavedCall(callee: ScriptProgram, anchor: ScriptLocation,
                               caller: ScriptProgram, returnIndex: Int, catalog: ScriptModuleCatalog?,
                               locals: [Data: ScriptBinding] = [:], storage: inout ScriptStorage) throws {
        let records = caller.document.records
        guard !storage.frames.isEmpty, storage.frames.count < 64, records.indices.contains(returnIndex),
              caller.ancestors[returnIndex].isEmpty,
              let callIndex = (0..<returnIndex).reversed().first(where: {
                  ![.layout, .comment].contains(records[$0].kind)
              }),
              caller.ancestors[callIndex].isEmpty,
              records[callIndex].command.map(asciiLower) == "sub",
              (1...18).contains(records[callIndex].fields.count),
              records[callIndex].fields.allSatisfy({ $0.key == nil }) else {
            throw ResourceError.rejected("saved_call_site_not_matched")
        }
        let fields = records[callIndex].fields
        let label = fields[0].raw
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
        if fields.count == 1 || asciiLower(fields[1].raw) == "self" ||
            (fields.count > 2 && fields[1].raw.isEmpty) {
            guard caller.document.source.sha256 == source.sha256,
                  caller.document.source.relativePath.utf8.elementsEqual(source.relativePath.utf8) else {
                throw ResourceError.rejected("saved_local_call_source_not_matched")
            }
        } else {
            guard let catalog, case .string(let path) = try ScriptExpression.parse(fields[1].raw),
                  let reference = try? catalog.resolve(path),
                  reference.sourceSHA256 == source.sha256,
                  reference.sourceFile.utf8.elementsEqual(source.relativePath.utf8) else {
                throw ResourceError.rejected("saved_module_call_source_not_matched")
            }
        }
        let arguments = fields.dropFirst(2)
        var integers = Array(repeating: Int32(0), count: 16)
        var strings = Array(repeating: "", count: 16)
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
            for (slot, field) in arguments.enumerated() where !field.raw.isEmpty {
                let expression = try ScriptExpression.parse(field.raw)
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
                    strings[slot] = field.raw.hasPrefix("$") ? field.raw : String(integer)
                case .string(let string):
                    guard string.utf8.count <= 8192 else { throw ResourceError.rejected("call_string_parameter_limit") }
                    strings[slot] = string
                    integers[slot] = ScriptExpression.integerTextCache(string) ?? 0
                case .object:
                    throw ResourceError.rejected("saved_call_argument_not_literal")
                }
            }
        }
        storage.frames.append(ScriptFrame(returnIndex: callIndex + 1, returnProgram: caller,
                                          entryLabel: label, locals: locals, parameterCount: Int32(arguments.count),
                                          integerParameters: integers, stringParameters: strings))
    }

    private static func makeSavedExecutionMachine(
        program: ScriptProgram, index: Int, storage: ScriptStorage,
        repository: ScriptRepository?, wait: Int32?, clickInitial: Int32? = nil, maximumSteps: Int, maximumFrames: Int = 64, retainFullTrace: Bool,
        imageLoader: (@Sendable (Data) throws -> (Int, Int, Int))?,
        imageMemberLookup: (@Sendable (ScriptLocation, String) throws -> (offset: Int, length: Int, sha256: String)?)?,
        imageExtendedValues: (@Sendable (ScriptLocation) -> [Int: Int32]?)?,
        imageMotionNames: (@Sendable (ScriptLocation) -> [String]?)?
    ) throws -> ScriptMachine? {
        let records = program.document.records
        guard records.indices.contains(index), let frame = storage.frames.last,
              program.ancestors[index] == frame.controls,
              [.command, .lineTag].contains(records[index].kind) || wait != nil else { return nil }
        if let wait, wait < -1 { throw ResourceError.rejected("invalid_saved_wait") }
        try storage.validate()
        var machine = try ScriptMachine(program: program, allowExperimental: true, maximumSteps: maximumSteps,
                                        maximumFrames: maximumFrames, repository: repository, imageLoader: imageLoader,
                                        imageMemberLookup: imageMemberLookup, imageExtendedValues: imageExtendedValues,
                                        imageMotionNames: imageMotionNames, retainFullTrace: retainFullTrace)
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
        }
        return machine
    }

    static func probeSavedCalculations(program: ScriptProgram, index: Int,
                                       storage: ScriptStorage, repository: ScriptRepository? = nil,
                                       savedWait: Int32? = nil, drawPreview: (() throws -> SavedDisplayDraw)? = nil,
                                       drawScene: ((ScriptMachine, SavedScenePass) throws -> (SavedDisplayDraw, Data?))? = nil,
                                       eventSampleTicks: Int32? = nil,
                                       decodeMovie: ((MoviePlaybackRequest) throws -> Int32)? = nil,
                                       decodeSound: ((ScriptLocation, Int32?) throws -> Void)? = nil,
                                       clickAfterMovie: Bool = false, dialogueClicks: Int = 0, autoWaitClicks: Int = 0, limit: Int = 512, compact: Bool = false,
                                       imageLoader: (@Sendable (Data) throws -> (Int, Int, Int))? = nil,
                                       imageMemberLookup: (@Sendable (ScriptLocation, String) throws -> (offset: Int, length: Int, sha256: String)?)? = nil,
                                       imageExtendedValues: (@Sendable (ScriptLocation) -> [Int: Int32]?)? = nil,
                                       imageMotionNames: (@Sendable (ScriptLocation) -> [String]?)? = nil) throws -> SavedCalculationContinuation? {
        var autoWaitClicksRemaining = autoWaitClicks
        var dialogueClicksRemaining = dialogueClicks
        var clickPending = clickAfterMovie
        let maximumReplaySteps = compact ? maximumCompactSavedReplaySteps : maximumFullSavedReplaySteps
        guard (1...maximumReplaySteps).contains(limit) else { throw ResourceError.rejected("saved_replay_step_limit") }
        guard var probe = try makeSavedExecutionMachine(
            program: program, index: index, storage: storage, repository: repository,
            wait: savedWait, maximumSteps: limit, retainFullTrace: !compact,
            imageLoader: imageLoader, imageMemberLookup: imageMemberLookup,
            imageExtendedValues: imageExtendedValues, imageMotionNames: imageMotionNames
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
        var acknowledgedSceneDraws = 0
        var captureDraw: SavedDisplayDraw?
        var textDraw: SavedDisplayDraw?
        var decodedSounds = 0
        var decodedSoundRequestCount: Int? { decodeSound.map { _ in decodedSounds } }
        var movieDecoded = false
        while steps.count + droppedSteps < limit {
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
                let cameraScope = scope == [ScriptStorage.cameraHandle] && probe.storage.cameraInitialized
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
                    supported = record.fields.isEmpty && scope.count == 1 &&
                        scope.allSatisfy { probe.storage.buttons.contains($0) || probe.storage.images[$0] != nil || probe.storage.messages[$0] != nil }
                case "c" where probe.storage.frames.last?.tableScope == [ScriptStorage.effectHandle]:
                    // Mode 1 bypasses replacement even when the host flag is unknown.
                    guard (probe.storage.effectCapturePriority != nil && probe.storage.fadeInDuration == nil) ||
                          (drawScene != nil && record.fields.count == 1) else {
                        return .init(steps: steps, nextLocation: record.location,
                                     stopReason: "saved_effect_capture_requires_restored_state",
                                     simulatedSavedWaitTicks: simulatedSavedWaitTicks, previewDraw: previewDraw, sceneDraw: sceneDraw, captureDraw: captureDraw, textDraw: textDraw, omittedStepCount: droppedSteps == 0 ? nil : droppedSteps, consumedInput: consumedInput, decodedSoundRequestCount: decodedSoundRequestCount)
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
                case "cc", "ap", "as", "nsw", "kwl", "kwb", "kwe", "ns": supported = messageScope
                case "?c" where scope == [ScriptStorage.effectHandle]:
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
                case "?cv", "?cvv", "?cvm": supported = scope == [ScriptStorage.configHandle] && record.fields.count == 1
                case "?mcw": supported = scope == [ScriptStorage.configHandle] && record.fields.isEmpty
                case "?ap": supported = scope == [ScriptStorage.systemHandle] && record.fields.isEmpty
                case "lk" where scope == [ScriptStorage.systemKeyHandle] ||
                    scope == [ScriptStorage.fileLogHandle] || scope == [ScriptStorage.lineLogHandle]:
                    supported = record.fields.count == 1
                case "?lk", "?lkc", "lk", "lkc":
                    supported = scope == [ScriptStorage.systemHandle]
                case "i" where movieDecoded && scope == [ScriptStorage.effectHandle]:
                    supported = true
                case "stop":
                    supported = (movieDecoded && record.fields.count == 1 &&
                        record.fields.first?.raw == "@@!Avg_MovieOnStopEvent") ||
                        (sceneDraw?.status == .inferred && record.fields.count == 3 &&
                         record.fields.first?.raw == "@@!Imo_ClickWait") ||
                        (sceneDraw?.status == .inferred && record.fields.count == 1 &&
                         record.fields.first.map { ["@@!Imo_MesWaitTextOnStop", "@@!Imo_MesWaitAutoOnStop"].contains($0.raw) } == true)
                case "sc":
                    supported = movieDecoded && probe.stopCallbackFrameDepth != nil &&
                        scope == [ScriptStorage.inputHandle]
                case "play":
                    supported = movieDecoded && probe.stopCallbackFrameDepth != nil
                case "?p" where imageScope || buttonScope || messageScope:
                    supported = record.fields.isEmpty
                case "?p" where streamScope: supported = record.fields.isEmpty
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
                    supported = record.fields.count == 4
                case "a": supported = (listScope || scope == [ScriptStorage.fileLogHandle]) && record.fields.count == 1
                case "ad": supported = listScope && record.fields.count == 2
                case "?n": supported = tableScope
                case "bpos": supported = tableScope && record.fields.count == 1
                case "brep": supported = tableScope && record.fields.count == 1
                case "?c", "?s": supported = listScope || tableScope
                case "v": supported = movieScope || listScope || tableScope || imageScope || streamScope
                case "pan", "p2": supported = streamScope
                case "pri": supported = cameraScope
                case "p4", "alg2": supported = imageScope || messageScope
                case "ts": supported = messageScope || (buttonScope && scope.allSatisfy { probe.storage.buttonResources[$0] != nil })
                case "tmg": supported = messageScope
                case "?tmg", "?tp": supported = messageScope && record.fields.isEmpty
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
                                     simulatedSavedWaitTicks: simulatedSavedWaitTicks, previewDraw: previewDraw, sceneDraw: sceneDraw, captureDraw: captureDraw, textDraw: textDraw, omittedStepCount: droppedSteps == 0 ? nil : droppedSteps, consumedInput: consumedInput, decodedSoundRequestCount: decodedSoundRequestCount)
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
                return .init(steps: steps, nextLocation: record.location, stopReason: "next_record_outside_calculation_profile", simulatedSavedWaitTicks: simulatedSavedWaitTicks, previewDraw: previewDraw, sceneDraw: sceneDraw, captureDraw: captureDraw, textDraw: textDraw, omittedStepCount: droppedSteps == 0 ? nil : droppedSteps, consumedInput: consumedInput, decodedSoundRequestCount: decodedSoundRequestCount)
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
                                     sceneDraw: sceneDraw, captureDraw: captureDraw, textDraw: textDraw, omittedStepCount: droppedSteps == 0 ? nil : droppedSteps, consumedInput: consumedInput, decodedSoundRequestCount: decodedSoundRequestCount)
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
                                     simulatedSavedWaitTicks: simulatedSavedWaitTicks, previewDraw: previewDraw, sceneDraw: sceneDraw, captureDraw: captureDraw, textDraw: textDraw, omittedStepCount: droppedSteps == 0 ? nil : droppedSteps, consumedInput: consumedInput, decodedSoundRequestCount: decodedSoundRequestCount)
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
                                 sceneDraw: sceneDraw, captureDraw: captureDraw, textDraw: textDraw, omittedStepCount: droppedSteps == 0 ? nil : droppedSteps, consumedInput: consumedInput, decodedSoundRequestCount: decodedSoundRequestCount)
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
                                 previewDraw: previewDraw, sceneDraw: sceneDraw, captureDraw: captureDraw, textDraw: textDraw, omittedStepCount: droppedSteps == 0 ? nil : droppedSteps, consumedInput: consumedInput, decodedSoundRequestCount: decodedSoundRequestCount)
                }
            }
        }
        let finalRecords = probe.program.document.records
        let nextLocation = finalRecords.indices.contains(probe.pc) ? finalRecords[probe.pc].location : nil
        if probe.phase == .waitingForMedia, probe.soundPlaybackRequest != nil {
            return .init(steps: steps, nextLocation: nextLocation, stopReason: "saved_sound_requires_media_host",
                         simulatedSavedWaitTicks: simulatedSavedWaitTicks, previewDraw: previewDraw, sceneDraw: sceneDraw, captureDraw: captureDraw, textDraw: textDraw, omittedStepCount: droppedSteps == 0 ? nil : droppedSteps, consumedInput: consumedInput, decodedSoundRequestCount: decodedSoundRequestCount)
        }
        if probe.phase == .waitingForMedia, probe.moviePlaybackRequest != nil {
            return .init(steps: steps, nextLocation: nextLocation, stopReason: "saved_movie_requires_media_host",
                         simulatedSavedWaitTicks: simulatedSavedWaitTicks, previewDraw: previewDraw, sceneDraw: sceneDraw, captureDraw: captureDraw, textDraw: textDraw, omittedStepCount: droppedSteps == 0 ? nil : droppedSteps, consumedInput: consumedInput, decodedSoundRequestCount: decodedSoundRequestCount)
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
                         previewDraw: previewDraw, sceneDraw: sceneDraw, captureDraw: captureDraw, textDraw: textDraw, omittedStepCount: droppedSteps == 0 ? nil : droppedSteps, consumedInput: consumedInput, decodedSoundRequestCount: decodedSoundRequestCount,
                         eventWait: .init(kind: kind, callbackLocation: callbackLocation,
                                          remainingReplayClicks: remainingClicks),
                         eventFrame: eventFrame, advancedEventFrame: advancedEventFrame,
                         eventSampleTicks: eventSampleTicks)
        }
        if probe.phase == .waiting {
            return .init(steps: steps, nextLocation: nextLocation, stopReason: "waiting_for_input_or_timer",
                         waitRemaining: probe.clickWaitRemaining, simulatedSavedWaitTicks: simulatedSavedWaitTicks, previewDraw: previewDraw, sceneDraw: sceneDraw, captureDraw: captureDraw, textDraw: textDraw, omittedStepCount: droppedSteps == 0 ? nil : droppedSteps, consumedInput: consumedInput, decodedSoundRequestCount: decodedSoundRequestCount)
        }
        return .init(steps: steps, nextLocation: nextLocation,
                     stopReason: probe.stopReason ?? (steps.count + droppedSteps == limit ? "calculation_probe_step_limit" : "script_end"),
                     simulatedSavedWaitTicks: simulatedSavedWaitTicks, previewDraw: previewDraw, sceneDraw: sceneDraw, captureDraw: captureDraw, textDraw: textDraw, omittedStepCount: droppedSteps == 0 ? nil : droppedSteps, consumedInput: consumedInput, decodedSoundRequestCount: decodedSoundRequestCount)
    }

    public func value(named name: String) throws -> ScriptValue { try storage.read(name) }
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
    private var liveSaveWait: (remaining: Int32, initial: Int32, mode: UInt8, command: String)? {
        guard phase == .waiting, let remaining = clickWaitRemaining,
              timerReturn == nil, stopCallback == nil, pc > 0,
              program.document.records.indices.contains(pc - 1),
              let command = program.document.records[pc - 1].command.map(asciiLower) else { return nil }
        if command == "wait", remaining > 0 { return (remaining, 0, 3, command) }
        if command == "clk", let initial = clickWaitInitial,
           (remaining == -1 && initial == -1) || (remaining >= 0 && remaining <= initial) {
            return (remaining, initial, 4, command)
        }
        return nil
    }

    /// Serialize the thread of a timed wait with resolved call sites. Other engine state
    /// belongs to subsequent sections of the save stream.
    package func encodeTimedWaitThread(scriptPath requestedPath: String? = nil, readerOpaqueFields: Data, allowsIndexedLocals: Bool = false) throws -> Data {
        guard let wait = liveSaveWait else {
            throw ResourceError.rejected("save_thread_live_wait_outside_profile")
        }
        let label: String
        if let entryLabel = storage.frames.last?.entryLabel {
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
            guard frame.controls.isEmpty, frame.savedReturnScalars == nil,
                  frame.tableScope.isEmpty || frame.tableScope == [ScriptStorage.effectHandle] else {
                throw ResourceError.rejected(
                    "save_thread_live_frame_outside_profile: frame=\(index) controls=\(frame.controls.count) scope=\(frame.tableScope.count) return_scalars=\(frame.savedReturnScalars != nil)")
            }
        }
        guard storage.frames.allSatisfy({ frame in
            (allowsIndexedLocals || (frame.locals.isEmpty && (frame.parameterCount ?? 0) == 0)) &&
                frame.objectAliases.isEmpty && frame.objectParameterNames.isEmpty
        }) else {
            throw ResourceError.rejected("save_thread_live_bindings_outside_profile")
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
        let fields = try program.savedReaderFields(commandIndex: pc - 1, anchor: anchor, afterWaitCommand: wait.command)
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
        let routines = try storage.frames.enumerated().map { index, frame in
            let active = index == storage.frames.count - 1
            var blocks: [Data] = []
            if index > 0 {
                guard let caller = frame.returnProgram, let destination = frame.returnIndex,
                      destination > 0,
                      caller.document.records.indices.contains(destination),
                      let callerLabel = storage.frames[index - 1].entryLabel,
                      caller.document.records[destination - 1].command.map(asciiLower) == "sub" else {
                    throw ResourceError.rejected("save_thread_live_return_outside_profile")
                }
                let call = caller.document.records[destination - 1].location
                let callerAnchor = caller.document.records[try caller.label(callerLabel)].location
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
                let end = call.byteOffset + call.byteLength
                let position = source.location(end..<end, line: call.lineNumber)
                let fields = try SaveReaderCursor.sourceRecordFields(position: position, anchor: callerAnchor, source: source)
                blocks = [try SaveReaderCursor.ControlBlock.encode(rawState: 1,
                    rawValueAt38: fields.line, rawValueAt3C: fields.position,
                    strings: [path, String(callerLabel.dropFirst(2))] + Array(repeating: "", count: 8))]
            }
            var scope = Array(repeating: "", count: 16)
            if frame.tableScope == [ScriptStorage.effectHandle] { scope[0] = "eff" }
            return try SaveReaderCursor.Routine.encode(scope: scope,
                rawState: active ? wait.mode : 0, waitTime: active ? wait.remaining : 0,
                skipTime: active ? wait.initial : 0, channel: 0,
                jumpLabel: "", eventLabel: "", eventName: "", resultSnapshot: nil, controlBlocks: blocks)
        }
        return try SaveReaderCursor.encodeThread(routines: routines, reader: reader)
    }

    /// Encode the template's declared global bindings at the same suspension
    /// boundary used for the experimental thread writer.
    package func encodeTimedWaitGlobals(template: Data) throws -> Data {
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
        let newBindingKeys = missing.filter { SaveVariableArrays.generatedBindingType($0, in: storage) != nil }
        let missingObjects = missing.subtracting(newBindingKeys)
        guard missingObjects.isEmpty else {
            var counts: [String: Int] = [:]
            var visualElements: [String: Int] = [:]
            for key in missingObjects {
                let elements = storage.global[key]?.elements ?? []
                let kinds = Set(elements.map { value -> String in
                    guard case .object(let handle) = value else { return value.typeName }
                    if let image = storage.images[handle] {
                        visualElements[image.resource == nil ? "image_unbound" : "image_bound", default: 0] += 1
                        return "image"
                    }
                    if storage.buttons.contains(handle) {
                        visualElements[storage.buttonResources[handle] == nil ? "button_unbound" : "button_bound", default: 0] += 1
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
            }
            let detail = counts.merging(visualElements, uniquingKeysWith: +).sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            throw ResourceError.rejected("save_globals_template_missing_bindings: count=\(missingObjects.count) \(detail)")
        }
        return try SaveVariableArrays.encodeCalValValues(template: template, storage: storage, newBindingKeys: newBindingKeys)
    }

    package func encodeTimedWaitSystemFields(template: Data) throws -> Data {
        guard liveSaveWait != nil else {
            throw ResourceError.rejected("save_system_fields_live_wait_outside_profile")
        }
        return try SaveEngineState.replacingSystemFields(in: template, at: 0, names: storage.systemNameSlots,
                                                         lockMask: storage.systemLockMask, customLockMask: storage.systemCustomLockMask)
    }

    package static func streamSaveChannelIndex(_ playbackHandle: UInt64) -> Int32? {
        ScriptStorage.streamChannelIndex(playbackHandle)
    }

    package func encodeTimedWaitStreams(template: Data, positions: [Int32: Int32]) throws -> Data {
        guard liveSaveWait != nil, let catalog = repository?.catalog else {
            throw ResourceError.rejected("save_streams_live_wait_outside_profile")
        }
        let reader = try SaveReaderCursor(threadState: template)
        let prefix = try SaveStatePrefix(state: template, after: reader)
        return try prefix.replacingLiveStreams(in: template, storage: storage, catalog: catalog,
                                               positions: positions)
    }

    /// Build an experimental slot in memory from a validated timed-wait snapshot.
    package func encodeTimedWaitResearchSlot(template: Data, positions: [Int32: Int32],
                                             displaySurfaces: [Int: Data] = [:],
                                             metadata: [String], thumbnail: Data, savedDays: Double,
                                             seed: UInt32? = nil, headerVerification: Data? = nil) throws -> Data {
        let state = try assembleTimedWaitResearchState(template: template, positions: positions,
                                                      displaySurfaces: displaySurfaces)
        return try SaveEnvelope.encodeSlot(state: state, metadata: metadata, thumbnail: thumbnail,
                                           savedDays: savedDays, seed: seed, headerVerification: headerVerification)
    }

    /// Research-only assembly against a parsed donor. Host captures can
    /// replace embedded surfaces. Other image state remains template data.
    package func assembleTimedWaitResearchState(template: Data, positions: [Int32: Int32],
                                                displaySurfaces: [Int: Data] = [:]) throws -> Data {
        guard template.count <= SaveEnvelope.maxFileBytes else {
            throw ResourceError.rejected("save_research_template_size_limit")
        }
        let originalReader = try SaveReaderCursor(threadState: template)
        let originalPrefix = try SaveStatePrefix(state: template, after: originalReader)
        let audio = try encodeTimedWaitStreams(template: template, positions: positions)
        var updated = originalPrefix.bypassingDonorDirectReloads(in: audio)
        for (index, payload) in displaySurfaces.sorted(by: { $0.key < $1.key }) {
            updated = try originalPrefix.replacingDisplaySurface(in: updated, index: index, payload: payload)
        }
        let calVal = try originalPrefix.locateCalVal(in: updated)
        let globalEnd = try SaveVariableArrays.readCalVal(state: updated, at: calVal).nextDecodedOffset
        let indexed = try SaveVariableArrays.encodeIndexedLocals(in: updated, at: globalEnd, frames: storage.frames)
        func span(_ start: Int, _ end: Int) -> Data {
            Data(updated[(updated.startIndex + start)..<(updated.startIndex + end)])
        }
        let opaqueStart = originalReader.decodedOffset + 13
        let thread = try encodeTimedWaitThread(readerOpaqueFields: span(opaqueStart, opaqueStart + 64), allowsIndexedLocals: true)
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

    public var playbackStatus: (phase: ScriptMachinePhase, steps: Int, stopReason: String?, currentLocation: ScriptLocation?) {
        let records = program.document.records
        return (phase, executedSteps, stopReason, pc < records.count ? records[pc].location : nil)
    }

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
                    parameterCount: Int32(arguments.count), integerParameters: integers, stringParameters: strings))
                next = destination
                action = "line_tag_replacement_call_candidate"
            case .command:
                guard let raw, safeCommand != nil else { throw ResourceError.rejected("invalid_command_identifier") }
                let command = asciiLower(raw)
                if candidate.selectsPrimaryScriptSource {
                    // Only the system play-mode calls have been checked for cross-instance routing.
                    let selectsSystem = command == "scp" && record.fields.count == 1 &&
                        asciiLower(record.fields[0].raw) == "sys"
                    let usesSystem = (command == "p" || command == "?p") &&
                        candidate.frames.last?.tableScope == [ScriptStorage.systemHandle]
                    let selectsSaveData = command == "scp" && record.fields.count == 1 &&
                        asciiLower(record.fields[0].raw) == "dat"
                    let requestsSaveRestore = command == "l" &&
                        candidate.frames.last?.tableScope == [ScriptStorage.saveDataHandle]
                    guard command == "srct" || selectsSystem || usesSystem || selectsSaveData || requestsSaveRestore else {
                        throw ResourceError.rejected("script_source_target_outside_profile")
                    }
                }
                switch command {
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
                        guard case .object(let handle) = value, handle == ScriptStorage.configHandle || handle == ScriptStorage.saveDataHandle || handle == ScriptStorage.temporaryDataHandle || handle == ScriptStorage.memoryDataHandle || handle == ScriptStorage.systemKeyHandle || handle == ScriptStorage.fileLogHandle || handle == ScriptStorage.lineLogHandle || handle == ScriptStorage.dialogueLogHandle || handle == ScriptStorage.mathHandle || handle == ScriptStorage.miscHandle || handle == ScriptStorage.systemHandle || handle == ScriptStorage.effectHandle || ScriptStorage.isStreamHandle(handle) || handle == ScriptStorage.inputHandle || handle == ScriptStorage.replacementHandle || handle == ScriptStorage.cameraHandle || candidate.tables[handle] != nil || candidate.lists[handle] != nil || candidate.images[handle] != nil || candidate.movies[handle] != nil || candidate.timers[handle] != nil || candidate.buttons.contains(handle) || candidate.messages[handle] != nil
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
                        // 0x5acb64 clamps explicit alpha; 0x5acc5c copies the zero-duration endpoint.
                        if values[0] != -1, values[3] >= 0, var image = candidate.images[handle] {
                            let alpha = UInt8(clamping: values[0])
                            let origin = image.presentedOpacity
                            if values[3] == 0 || origin == alpha {
                                image.immediateOpacity = alpha
                                image.opacityEndpoint = nil
                            } else {
                                image.immediateOpacity = origin
                                image.opacityEndpoint = (alpha, values[3], values[3], loop)
                            }
                            candidate.images[handle] = image
                        }
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
                    guard scope.count == 1, let handle = scope.first, var message = candidate.messages[handle] ?? candidate.buttonText[handle] else {
                        throw ResourceError.rejected("message_clear_requires_message_scope")
                    }
                    // 0x6c8f64 calls 0x6787b0, which drains output and clears
                    // the message surface and transient text. The CLI only queues
                    // output without rendering glyphs.
                    message.pendingOutput.removeAll()
                    message.committedOutput.removeAll()
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
                    var remaining = text[...]
                    var output: [ScriptStorage.MessageObject.Output] = []
                    let arities = ["n": 0, "i": 1, "f": 1, "rf": 1, "s": 2, "c": 1, "rc": 1, "pi": 2, "rs": 2, "rpi": 2, "rp": 2]
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
                        guard output.count <= 128 - (candidate.buttonText[handle]?.pendingOutput.count ?? 0) else {
                            throw ResourceError.rejected("message_pending_output_limit")
                        }
                        candidate.buttonText[handle, default: .init()].pendingOutput.append(contentsOf: output)
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
                case "?in", "dc", "bg", "in", "out", "ps":
                    if (command == "in" || command == "?in"),
                       candidate.frames.last!.tableScope == [ScriptStorage.systemHandle] {
                        let usesPrimary = candidate.selectsPrimaryScriptSource && candidate.linkedPrimaryInputMask != nil
                        if command == "?in" {
                            try arity(0)
                            // 0x6b2d72 reads the selected instance's input mask.
                            let mask = usesPrimary ? candidate.linkedPrimaryInputMask! : candidate.systemInputMask
                            candidate.clearResultBindings()
                            try candidate.resultInteger(mask)
                            action = "system_input_mask_query_candidate"
                        } else {
                            // 0x6b2d2b resets the mask when the operand is absent.
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
                            if usesPrimary { candidate.linkedPrimaryInputMask = mask }
                            else { candidate.systemInputMask = mask }
                            action = "system_input_mask_write_candidate"
                        }
                        break
                    }
                    guard command != "?in" else { throw ResourceError.rejected("unsupported_command") }
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
                            image.playbackSpeed = min(3000, max(0, integer))
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
                    guard (mode == 0 || mode == 4), (0...60_000).contains(duration) else {
                        throw ResourceError.rejected("fade_in_mode_or_duration_outside_profile")
                    }
                    candidate.fadeInRule = nil
                    candidate.fadeInAnimation = nil
                    if record.fields.count >= 4 {
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
                                // The shipped sentence script uses the four-field fdi for animation.
                                candidate.fadeInAnimation = location
                            }
                        }
                        candidate.fadeInPriority = try integerOperand(3)
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
                case "s" where candidate.frames.last!.tableScope == [ScriptStorage.saveDataHandle]:
                    try arity(1)
                    throw ResourceError.rejected("save_write_execution_state_unsupported")
                case "s" where candidate.frames.last!.tableScope != [ScriptStorage.saveDataHandle],
                     "?g" where candidate.frames.last!.tableScope != [ScriptStorage.saveDataHandle]:
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
                            let key = Data(try callLabel().utf8)
                            // 0x6cc8c2 queries the named checkpoint and returns its presence.
                            candidate.clearResultBindings()
                            try candidate.resultInteger(memoryCheckpoints[key] == nil ? 0 : 1)
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
                            let key = Data(name.utf8)
                            guard !key.isEmpty, key.count <= 1024,
                                  memoryCheckpoints.count < 64 || memoryCheckpoints[key] != nil,
                                  let options = operands[0].integer,
                                  let mode = operands.count == 1 ? 2 : operands[1].integer else {
                                throw ResourceError.rejected("memory_checkpoint_operands_or_budget")
                            }
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
                            let name = Data(try callLabel().utf8)
                            let exists = logJumpCheckpoints.contains { Data($0.name.utf8) == name }
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
                        if logJumpLimit > 0 {
                            logJumpCheckpoints.removeAll { Data($0.name.utf8) == Data(name.utf8) }
                            if logJumpCheckpoints.count == logJumpLimit { logJumpCheckpoints.removeFirst() }
                            logJumpCheckpoints.append(.init(name: name, options: options, mode: mode,
                                storage: candidate, program: program, resumeIndex: pc+1))
                        }
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
                                speaker: values[0], text: values[1], voice: values[2], extra: values[3])
                            candidate.dialogueLogBytes = bytes
                        }
                        action = "dialogue_log_update_candidate"
                        break
                    }
                    if candidate.frames.last!.tableScope == [ScriptStorage.fileLogHandle] {
                        try arity(command == "s" ? 2 : 1)
                        let key = Data(try callLabel().utf8)
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
                    if command == "?skp", let skip = candidate.restoredSystemSkip {
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
                case "k2":
                    try arity(2)
                    guard candidate.frames.last!.tableScope == [ScriptStorage.inputHandle],
                          stopCallbackFrameDepth != nil, (pointerPosition != nil || pendingLoadEscape), !pendingClick,
                          try field(0) == "$10002", try field(1) == "$1001B" else {
                        throw ResourceError.rejected("input_key_range_outside_pointer_profile")
                    }
                    // 0x6ca240 dispatches k2 to 0x6ca068. The inclusive key scan
                    // clears results at 0x6ca12c and writes only matching keys.
                    candidate.clearResultBindings()
                    try candidate.resultInteger(pendingLoadEscape ? 0x1001b : 0)
                    action = pendingLoadEscape ? "input_load_escape_candidate" : "input_key_range_empty_pointer_cycle_candidate"
                    pendingLoadEscape = false
                case "gsc" where pendingLoadEscape:
                    try arity(0)
                    guard candidate.frames.last!.tableScope == [ScriptStorage.inputHandle], stopCallbackFrameDepth != nil else {
                        throw ResourceError.rejected("input_scope_required")
                    }
                    // This keyboard-only cycle carries no secondary click target.
                    try candidate.setButtonResults(handle: ScriptStorage.nullHandle, label: "")
                    action = "input_secondary_click_empty_keyboard_cycle_candidate"
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
                    // This profile supports the zero-anchor placement path only.
                    candidate.clearResultBindings()
                    try candidate.setConfigResultArray(placement.map(ScriptValue.integer),string: false)
                    action = candidate.buttons.contains(handle) ? "button_position_query_candidate" : "image_position_query_candidate"
                    if candidate.messages[handle] != nil { action = "message_position_query_candidate" }

                case "d":
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
                        memoryCheckpoints.removeValue(forKey: Data(try callLabel().utf8))
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
                                    image.selectedMember = index
                                    image.motionStartTick = candidate.visualTicks
                                    image.motionElapsedBeforeSpeedChange = 0
                                    image.restoredMotionRemainder = 0
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
                case "e":
                    try arity(0)
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
                            image.selectedMember = index
                            image.motionStartTick = candidate.visualTicks
                            image.motionElapsedBeforeSpeedChange = 0
                            image.restoredMotionRemainder = 0
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
                    candidate.soundChannels[stream,default: .init()].seekRequest = position
                    action = "sound_seek_request_candidate"
                case "ck":
                    try arity(1)
                    let scope = candidate.frames.last!.tableScope
                    guard scope.count == 1, let handle = scope.first, candidate.buttons.contains(handle) else {
                        throw ResourceError.rejected("button_ck_requires_button_scope")
                    }
                    let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                        write: { _,_ in throw ResourceError.rejected("mutating_button_ck") },
                        readIndexed: { try candidate.readIndexed($0,$1) })
                    guard let integer = value.integer else {
                        throw ResourceError.rejected("button_ck_requires_integer")
                    }
                    // 0x67c6f4 stores the low byte before invoking the button refresh.
                    candidate.buttonCheckVisual[handle] = UInt8(truncatingIfNeeded: integer)
                    action = "button_ck_state_candidate"
                case "mi", "?mi":
                    let scope = candidate.frames.last!.tableScope
                    guard scope.count == 1, let handle = scope.first, candidate.buttons.contains(handle) else {
                        throw ResourceError.rejected("button_mi_requires_button_scope")
                    }
                    if command == "?mi" {
                        try arity(0)
                        candidate.clearResultBindings()
                        try candidate.resultInteger(candidate.buttonMI.contains(handle) ? 1 : 0)
                    } else {
                        try arity(1)
                        let value = try ScriptExpression.parse(field(0)).evaluate(read: { try candidate.read($0) },
                            write: { _,_ in throw ResourceError.rejected("mutating_button_mi") },
                            readIndexed: { try candidate.readIndexed($0,$1) })
                        guard let integer = value.integer else {
                            throw ResourceError.rejected("button_mi_requires_integer")
                        }
                        // 0x6cc1e1–0x6cc1eb stores the result of an exact comparison with 1.
                        if integer == 1 { candidate.buttonMI.insert(handle) }
                        else { candidate.buttonMI.remove(handle) }
                    }
                    action = "button_mi_state_candidate"
                case "vtn", "v", "pan":
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
                            candidate.soundChannels[stream!]?.panChangePending = true
                        } else {
                            candidate.soundChannels[stream!]?.volume = integer
                            candidate.soundChannels[stream!]?.volumeDuration = timing[0]
                            candidate.soundChannels[stream!]?.volumeDelay = timing[1]
                            candidate.soundChannels[stream!]?.volumeChangePending = true
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
                        guard image.placement != nil, (candidate.placementTransitions[handle]?.elapsed ?? 0) == 0 else {
                            throw ResourceError.rejected("timed_placement_origin_unavailable")
                        }
                        candidate.placementTransitions[handle] = .init(destination: placement, duration: duration, destinationTransform: transform)
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
                    // 0x5745eb leaves the active repeat counter unchanged for -2.
                    soundPlaybackPreservesPosition = loop == -2
                    if !soundPlaybackPreservesPosition {
                        candidate.soundChannels[stream]?.loopRequest = max(-1,loop)
                    }
                    candidate.soundChannels[stream]?.playing = true
                    candidate.soundChannels[stream]?.playbackStartStep = executedSteps + 1
                    soundPlaybackChannel = stream
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
                        if candidate.selectsPrimaryScriptSource, candidate.linkedPrimaryPlayMode != nil {
                            candidate.linkedPrimaryPlayMode = mode
                        } else {
                            candidate.systemPlayMode = mode
                        }
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
                        soundPlaybackPreservesPosition = false
                        candidate.soundChannels[stream]?.playing = true
                        candidate.soundChannels[stream]?.playbackStartStep = executedSteps + 1
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
                        moviePlaybackRequest = MoviePlaybackRequest(resource: resource, placement: placement, size: size, volume: movie.volume, handle: handle)
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
                            message.backgroundSelectedMember = index
                            message.backgroundMotionStartTick = candidate.visualTicks
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
                            // 0x6c7b30 forces a restart when the second operand is zero.
                            // The original evaluator returns zero for a missing operand (0x69bb17).
                            let restart = operands.count == 1 || operands[1] == 0
                            if motionNames != nil || image.isTheoraResource,
                               restart || image.selectedMember != operands[0] {
                                image.motionStartTick = candidate.visualTicks
                                image.motionElapsedBeforeSpeedChange = 0
                                image.restoredMotionRemainder = 0
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
                        action = "memory_checkpoint_clear_candidate"
                        break
                    }
                    if command == "i", candidate.frames.last!.tableScope == [ScriptStorage.lineLogHandle] {
                        try arity(0)
                        candidate.lineLogValues.removeAll()
                        action = "line_log_clear_candidate"
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
                            candidate.fileLogValues.removeAll()
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
                case "g", "?g":
                    // The save dispatcher routes g and ?g to the same branch at 0x6b419c.
                    let scope = candidate.frames.last!.tableScope
                    if command == "g", scope.count == 1, let handle = scope.first,
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
                    guard try callLabel(1) == #".*?\[([^\]]*?)\].*$"#, try callLabel(2) == "$1" else {
                        throw ResourceError.rejected("regex_substitution_pattern_outside_profile")
                    }
                    let output: String
                    if let start = input.firstIndex(of: "["), let end = input[start...].firstIndex(of: "]") {
                        output = String(input[input.index(after: start)..<end])
                    } else {
                        output = input
                    }
                    candidate.clearResultBindings()
                    try candidate.resultString(output)
                    action = "bracket_capture_substitution_candidate"
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
                case "efn", "cfe":
                    try arity(command == "efn" ? 1 : 2)
                    guard candidate.frames.last!.tableScope == [ScriptStorage.miscHandle] else {
                        throw ResourceError.rejected("filename_operation_requires_misc_scope")
                    }
                    let path = try callLabel(0)
                    let result: String
                    if command == "efn" {
                        // 0x6c4821 calls the filename extraction helper.
                        result = String(path.split(whereSeparator: { $0 == "/" || $0 == "\\" || $0 == ":" }).last ?? "")
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
                case "l", "?v":
                    if command == "l", candidate.frames.last!.tableScope == [ScriptStorage.temporaryDataHandle] {
                        try arity(1)
                        let name = Data(try callLabel().utf8)
                        guard !logJumpCheckpoints.contains(where: { Data($0.name.utf8) == name }) else {
                            throw ResourceError.rejected("temporary_checkpoint_restore_unsupported")
                        }
                        // 0x6cc73e initializes the result to zero; only a successful restore sets it to one.
                        candidate.clearResultBindings()
                        try candidate.resultInteger(0)
                        action = "temporary_checkpoint_restore_not_found"
                        break
                    }
                    if command == "l", candidate.frames.last!.tableScope == [ScriptStorage.saveDataHandle] {
                        savedDisplayPreview = nil
                        // This path is terminal until execution-state restore is
                        // supported. Keep its provenance separate from stopReason.
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
                            let bytes = try directory.read(source.name, limit: SaveEnvelope.maxFileBytes)
                            guard bytes.sha256Hex == source.sha256 else {
                                throw ResourceError.rejected("save_restore_slot_changed")
                            }
                            let inferred = inferSaveStateSeed ? try SaveEnvelope(bytes).slot?.transformed == true : false
                            let template = source.verifyHeader ? saveHeaderTemplate : nil
                            let seed = try template.map { try SaveEnvelope.validatedSlotSeed(bytes, clearTemplate: $0) }
                            let state = try SaveEnvelope.decodeSlotState(bytes, seed: seed, inferSeed: inferred)
                            let cursor = try SaveReaderCursor(threadState: state)
                            guard inspectSaveRestoreBoundary else {
                                guard cursor.routines.count <= maximumFrames else {
                                    throw ResourceError.rejected("saved_return_frame_limit")
                                }
                                _ = try cursor.validateRoutinePayloads(in: state)
                                if var pinned = candidateRepository {
                                    _ = try cursor.resolveResumeInstruction(in: state, repository: &pinned)
                                    for routine in cursor.routines.dropFirst() {
                                        guard let block = routine.controlBlocks.first, block.rawState == 1 else {
                                            throw ResourceError.rejected("saved_return_block_unavailable")
                                        }
                                        let (_, instruction, _, _) = try SaveReaderCursor.routineReturnPosition(
                                            block, in: state, repository: &pinned)
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
                                                issue: "saved_return_frame_limit")
                                        }
                                        guard let block, block.rawState == 1 else {
                                            return .init(routineOffset: routine.decodedOffset, blockOffset: block?.decodedOffset,
                                                location: nil, instructionIndex: nil, status: .unsupported,
                                                issue: "saved_return_block_unavailable")
                                        }
                                        do {
                                            let (position, instruction, returnProgram, returnAnchor) = try SaveReaderCursor.routineReturnPosition(
                                                block, in: state, repository: &returnRepository)
                                            if let instruction {
                                                savedReturns.append((returnProgram, instruction, returnAnchor))
                                            }
                                            return .init(routineOffset: routine.decodedOffset, blockOffset: block.decodedOffset,
                                                location: position, instructionIndex: instruction, status: .inferred,
                                                issue: instruction == nil ? "saved_return_not_command_boundary" : nil)
                                        } catch {
                                            return .init(routineOffset: routine.decodedOffset, blockOffset: block.decodedOffset,
                                                location: nil, instructionIndex: nil, status: .unsupported,
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
                                let summary = try arrays.summary(in: state, at: offset) { slot, decodedOffset, group in
                                    if !rootReferences.isEmpty {
                                        for record in group.records {
                                            let key = Data(asciiLower(record.textFields[0]).utf8)
                                            if rootReferences.contains(key) { shadowed.insert(key) }
                                        }
                                    }
                                    do {
                                        let storage = try ScriptStorage.stageSavedGlobalScalars(group)
                                        let complete = storage.global.count == group.records.count
                                        if slot < frameLocalLimit, complete {
                                            frameLocals[slot] = storage.global
                                        }
                                        indexedGroups.append(.init(slot: slot, decodedOffset: decodedOffset,
                                                                   scalarCount: storage.global.count,
                                                                   status: complete ? .verified : .unsupported,
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
                                if !summary.buttonPayloads.isEmpty || !summary.imagePayloads.isEmpty {
                                    var remaining = 32 * 1024 * 1024
                                    func checkImage(offset: Int, source: SaveReaderCursor.Reference?) -> SaveResumeBoundary.SavedButtonImageCheck {
                                        var result: SaveResumeBoundary.NestedDisplayResourceCheck
                                        if let reference = source, var repository = candidateRepository {
                                            do {
                                                guard remaining > 0 else {
                                                    throw ResourceError.rejected("saved_button_image_read_budget")
                                                }
                                                let path = try reference.utf16Text(in: state)
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
                                                    let motionCount = imageMotionNames?(location)?.count
                                                    let motionOnly = width == 0 && height == 0 && memberCount == 0 &&
                                                        (motionCount ?? 0) > 0
                                                    if motionOnly || ((1...8192).contains(width) && (1...8192).contains(height)) {
                                                        savedVisualResources[offset] = .init(location: location, width: width,
                                                            height: height, memberCount: memberCount,
                                                            hasExtendedContainerMetadata: bytes.starts(with: Data("abmp12".utf8)),
                                                            motionCount: motionCount,
                                                            motionUpdateThreshold: savedMotionUpdateThreshold?(location))
                                                    } else {
                                                        result.issue = "saved_button_image_decoder_or_dimensions"
                                                    }
                                                } else {
                                                    result.issue = "saved_button_image_decoder_or_dimensions"
                                                }
                                            } catch {
                                                result = .init(status: .unsupported, issue: String(describing: error))
                                            }
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
                                        let checks = summary.imagePayloads.map { checkImage(offset: $0.decodedOffset, source: $0.imageSource) }
                                        saveResumeBoundary?.savedImageResourceChecks = checks
                                    }
                                    if !summary.buttonPayloads.isEmpty || !summary.imagePayloads.isEmpty {
                                        // The original reload pass calls 0x5ae808 for named slots 0–31.
                                        // Only the player's existing ordinary raster binding is staged here.
                                        let owners = summary.imagePayloads.map { ($0.decodedOffset, $0.textureSlots) } +
                                            summary.buttonPayloads.map { ($0.decodedOffset, $0.textureSlots.filter { (0...1).contains($0.index) }) }
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
                                    saveResumeBoundary?.stagedGlobalButtonIdentityArrayCount =
                                        try staged?.stageSavedGlobalButtonIdentities(arrays, resources: savedVisualResources.mapValues(\.location),
                                            textures: savedVisualResources.mapValues(\.boundTextures), sounds: savedButtonSounds,
                                            savedState: state, program: resumeInstruction?.program)
                                } catch {
                                    saveResumeBoundary?.globalButtonIdentityIssue = String(describing: error)
                                }
                                do {
                                    saveResumeBoundary?.stagedGlobalImageIdentityArrayCount =
                                        try staged?.stageSavedGlobalImageIdentities(arrays, resources: savedVisualResources)
                                } catch {
                                    saveResumeBoundary?.globalImageIdentityIssue = String(describing: error)
                                }
                                if saveResumeBoundary?.globalImageIdentityIssue == nil,
                                   let image = summary.imagePayloads.first(where: {
                                       $0.drawGate != 0 && savedVisualResources[$0.decodedOffset] == nil
                                   }) {
                                    saveResumeBoundary?.globalImageIdentityIssue =
                                        "saved_drawable_image_resource_unrestored:\(image.decodedOffset)"
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
                                let stagedObjectCount = (saveResumeBoundary?.stagedGlobalListCount ?? 0)
                                    + (saveResumeBoundary?.stagedGlobalTableCount ?? 0)
                                let unstagedObjects = summary.objectArrayCount - stagedObjectCount
                                    - (saveResumeBoundary?.stagedGlobalButtonIdentityArrayCount ?? 0)
                                    - (saveResumeBoundary?.stagedGlobalImageIdentityArrayCount ?? 0)
                                    - (saveResumeBoundary?.stagedGlobalInactiveTimerArrayCount ?? 0)
                                saveResumeBoundary?.unstagedGlobalObjectArrayCount = unstagedObjects
                                if summary.absentValueCount != 0 {
                                    saveResumeBoundary?.firstAbsentGlobalBindingOffset = arrays.records.first {
                                        if case .absent = $0.values { return true }
                                        return false
                                    }?.decodedOffset
                                }
                                let storageIssue: String?
                                if let issue = saveResumeBoundary?.globalScalarIssue ??
                                    saveResumeBoundary?.globalTextObjectIssue ??
                                    saveResumeBoundary?.globalButtonIdentityIssue ??
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
                                        if engine.status == .verified {
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
                                let activeRoutineCanResume = activeRoutine?.rawState == 0 || savedWait != nil
                                let restoredScopes = try? cursor.routines.map { routine -> [UInt64] in
                                    if routine.scope.allSatisfy({ $0.length == 0 }) { return [] }
                                    guard let first = routine.scope.first,
                                          routine.scope.dropFirst().allSatisfy({ $0.length == 0 }),
                                          asciiLower(try first.utf16Text(in: state)) == "eff" else {
                                        throw ResourceError.rejected("saved_routine_scope_outside_profile")
                                    }
                                    return [ScriptStorage.effectHandle]
                                }
                                if var staged, let target = resumeInstruction,
                                   (2...maximumFrames).contains(cursor.routines.count),
                                   savedReturns.count == cursor.routines.count - 1,
                                   !cursor.routines[0].hasResultSnapshot,
                                   activeRoutineCanResume, cursor.routines.dropLast().allSatisfy({ $0.rawState == 0 }),
                                   cursor.routines.allSatisfy({
                                       $0.nonEmptyResultObjectReferenceCount == 0 && ($0.resultButtonReference?.length ?? 0) == 0 }),
                                   let restoredScopes,
                                   cursor.routines[0].controlBlocks.isEmpty,
                                   cursor.routines.dropFirst().allSatisfy({ $0.controlBlocks.count == 1 }),
                                   storageIssue == nil, readerPrefixesSupported, readerRulesSupported,
                                   saveResumeBoundary?.globalTextObjectIssue == nil {
                                    do {
                                        staged.frames[0].locals = frameLocals[0] ?? [:]
                                        for (index, caller) in savedReturns.enumerated() {
                                            let callee = index + 1 < savedReturns.count ? savedReturns[index + 1] : target
                                            try Self.stageSavedCall(callee: callee.program, anchor: callee.anchor,
                                                caller: caller.program, returnIndex: caller.index,
                                                catalog: candidateRepository?.catalog, locals: frameLocals[index + 1] ?? [:],
                                                storage: &staged)
                                            let routine = cursor.routines[index + 1]
                                            staged.frames[index + 1].savedReturnScalars = try routine.savedResultScalars(in: state)
                                        }
                                        for (index, scope) in restoredScopes.enumerated() {
                                            staged.frames[index].tableScope = scope
                                        }
                                        try staged.validate()
                                        saveResumeBoundary?.isolatedReturnScalarFrameCount = staged.frames.count {
                                            $0.savedReturnScalars != nil
                                        }
                                        saveResumeBoundary?.isolatedCallFrameStatus = .inferred
                                        if retainExperimentalSaveCandidate {
                                            savedExecutionCandidate = .init(program: target.program, index: target.index,
                                                storage: staged, repository: candidateRepository, wait: savedWait,
                                                clickInitial: activeRoutine?.rawState == 4 ? activeRoutine?.skipTime : nil)
                                        }
                                        var continuation = try Self.probeSavedCalculations(
                                            program: target.program, index: target.index, storage: staged,
                                            repository: candidateRepository, savedWait: savedWait, drawPreview: drawPreview, drawScene: savedSceneDrawHandler, eventSampleTicks: savedEventSampleTicks,
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
                                   let scope = restoredScopes?.first,
                                   root.nonEmptyResultObjectReferenceCount == 0,
                                   (root.resultButtonReference?.length ?? 0) == 0,
                                   storageIssue == nil, readerPrefixesSupported, readerRulesSupported,
                                   saveResumeBoundary?.globalTextObjectIssue == nil,
                                   saveResumeBoundary?.rootResultScalarIssue == nil {
                                    staged.frames[0].locals = frameLocals[0] ?? [:]
                                    staged.frames[0].tableScope = scope
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
                                        if retainExperimentalSaveCandidate {
                                            savedExecutionCandidate = .init(program: target.program, index: target.index,
                                                storage: staged, repository: candidateRepository, wait: savedWait,
                                                clickInitial: activeRoutine?.rawState == 4 ? activeRoutine?.skipTime : nil)
                                        }
                                        var continuation = try Self.probeSavedCalculations(
                                            program: target.program, index: target.index, storage: staged,
                                            repository: candidateRepository, savedWait: savedWait, drawPreview: drawPreview, drawScene: savedSceneDrawHandler, eventSampleTicks: savedEventSampleTicks,
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
                        throw ResourceError.rejected("save_restore_execution_state_unsupported")
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
                        resourceLocation = location
                        // The original load dispatch at 0x6b50cc takes the
                        // channel index directly, without a script-side reset.
                        candidate.soundChannels[stream, default: .init()].resource = location
                        candidate.soundChannels[stream]?.seekRequest = nil
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
                            candidate.buttonImages.removeValue(forKey: handle)
                            action = "button_empty_path_release_candidate"
                            break
                        }
                        if path.isEmpty, candidate.messages[handle] != nil {
                            // 0x67dd6c forwards empty slots to the image release path at 0x5ad744.
                            candidate.messages[handle]?.background = nil
                            candidate.messages[handle]?.backgroundMemberCount = 0
                            candidate.messages[handle]?.backgroundSelectedMember = nil
                            candidate.messages[handle]?.backgroundMotionStartTick = nil
                            candidate.messages[handle]?.backgroundExtendedDefaultsPrepared = false
                            action = "message_empty_background_release_candidate"
                            break
                        }
                        if path.isEmpty, var image = candidate.images[handle] {
                            // The nil filename branch at 0x5ad775 releases the image payload.
                            image.resource = nil
                            image.isTheoraResource = false
                            image.resourceLoadLocation = nil
                            image.boundImages.removeAll()
                            image.hasExtendedContainerMetadata = false
                            image.extendedDefaultsPrepared = false
                            image.extendedScalarValues.removeAll()
                            image.width = nil
                            image.height = nil
                            image.selectedMember = nil
                            image.motionStartTick = nil
                            image.restoredMotionThreshold = nil
                            image.restoredMotionRemainder = 0
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
                            screenCaptureRequest = ScreenCaptureRequest(priority: priority, handle: handle, location: record.location)
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
                        if candidate.buttons.contains(handle) {
                            candidate.buttonResources[handle] = resourceLocation
                            action = "button_resource_load_candidate"
                        } else if candidate.messages[handle] != nil {
                            // 0x6cbc40 resolves the file and calls the message image loader.
                            candidate.messages[handle]?.background = resourceLocation
                            candidate.messages[handle]?.backgroundMemberCount = memberCount
                            candidate.messages[handle]?.backgroundSelectedMember = nil
                            candidate.messages[handle]?.backgroundMotionStartTick = nil
                            candidate.messages[handle]?.backgroundExtendedDefaultsPrepared = false
                            action = "message_background_load_candidate"
                        } else {
                            var image = candidate.images[handle]!
                            image.extendedDefaultsPrepared = false
                            image.extendedScalarValues.removeAll()
                            image.resource = resourceLocation
                            image.isTheoraResource = data.starts(with: Data("OggS".utf8)) &&
                                (try? ScriptMovieHeader.theoraDimensions(data)) != nil
                            image.resourceLoadLocation = record.location
                            image.boundImages.removeAll()
                            // A decoded standalone image has no ABMP extended data table.
                            image.hasExtendedContainerMetadata = data.starts(with: Data("abmp12".utf8))
                            image.width = motionOnly ? nil : width
                            image.height = motionOnly ? nil : height
                            image.memberCount = memberCount
                            image.selectedMember = nil
                            image.motionStartTick = nil
                            image.restoredMotionThreshold = nil
                            image.restoredMotionRemainder = 0
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
                            guard case .name(let name) = try calculationExpression(String(raw.dropLast(2))) else {
                                throw ResourceError.rejected("calculate_update_requires_named_target")
                            }
                            try candidate.updateInteger(name,delta: raw.hasSuffix("++") ? 1 : -1)
                            evaluated = .integer(1)
                            continue
                        }
                        let expression = try calculationExpression(raw)
                        if command == "if", case .binary("=",_,_) = expression { throw ResourceError.rejected("assignment_condition_outside_profile") }
                        // Capturing a copy permits a single atomic command commit; not original-engine error behavior.
                        evaluated = try expression.evaluate(read: { try candidate.read($0) },write: { try candidate.write($0,$1) },
                            readIndexed: { try candidate.readIndexed($0,$1) },writeIndexed: { try candidate.writeIndexed($0,$1,$2) })
                    }
                    result = evaluated; action = "calculate"
                    if command == "if" {
                        guard let value = evaluated.integer, let block = program.blocks[pc], block.family == "if" else { throw ResourceError.rejected("if_type_or_structure_outside_profile") }
                        guard block.conditionalShapeSupported else {
                            throw ResourceError.rejected("if_marker_shape_outside_profile")
                        }
                        if value == 1 { candidate.frames[candidate.frames.count-1].controls.append(pc); action = "if_exact_one_true" }
                        else {
                            let destination = block.conditionalElse ?? block.end
                            next = destination+1; skip = try skipped((pc+1)..<next); action = "if_not_exact_one"
                            if block.conditionalElse != nil { candidate.frames[candidate.frames.count-1].controls.append(pc) }
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
                    candidate.timers.removeAll()
                    logJumpCheckpoints.removeAll()
                    memoryCheckpoints.removeAll()
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
                    guard value.integer == 1, asciiLower(label) == "@@!load" else {
                        throw ResourceError.rejected("system_task_request_outside_profile")
                    }
                    // 0x6b1002 queues mode 1. The host dispatches the label to SysStartUp.s.
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
                        callbackElapsedTicks = nil
                        pointerPosition = nil
                        if stopCallback != nil { phase = .waitingForEvent }
                    }
                    if let saved = candidate.frames.last?.savedReturnScalars {
                        try candidate.applySavedResultScalars(saved)
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
