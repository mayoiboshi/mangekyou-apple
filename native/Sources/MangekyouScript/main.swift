import Foundation
import AVFoundation
import CoreGraphics
import MangekyouCore
import MangekyouMedia

struct HeadlessReplayBudget: Encodable {
    struct ResearchObservedStreamAtPlay: Encodable {
        let channel: Int32
        let playbackStartStep: Int?
        let source: ScriptLocation?
        let positionMilliseconds: Int32
    }
    struct ResearchStreamStatusSample: Encodable {
        let step: Int
        let location: ScriptLocation
        let stream: ScriptMachine.ResearchStreamScopeObservation
    }
    struct ResearchAutoTimedWait: Encodable {
        let initialDuration: Int32?
        let initialAlternateDuration: Int32?
        var elapsedTicks: [Int32] = []
        var effectiveTicks: [Int32] = []
        var callbackCount = 0
        var completed = false
        var callbackPlayObserved = false
        var freshZeroLocation: ScriptLocation?
        var freshZeroStep: Int?
        var freshZeroContinuationStartStep: Int?
        var zeroClockConsumed = false
        var mediaHandoffAttempted = false
        var mediaHandoffCompleted = false
        var mediaHandoffCount = 0
        var soundSwapAttempted = false
        var soundSwapCompleted = false
        var endStep: Int?
        var endLocation: ScriptLocation?
        var issue: String?
    }
    struct ResearchAutoFollowthrough: Encodable {
        let textWaitStartStep: Int
        var autoWaitStartStep: Int?
        var elapsedTicks: [Int32] = []
        var playObserved = false
        var continuationStartStep: Int?
        var mediaHandoffAttempted = false
        var mediaHandoffCompleted = false
        var mediaHandoffCount = 0
        var soundSwapCount = 0
        var soundStatusQueryCount = 0
        var observedAudioCompletionsBefore: Int?
        var observedAudioCompletionsAtPlay: Int?
        var streamStatusSamples: [ResearchStreamStatusSample] = []
        var audioCompletionEvents: [LiveAudioObserver.CompletionEvent] = []
        var observedStreamsAtPlay: [ResearchObservedStreamAtPlay] = []
        var endStep: Int?
        var endLocation: ScriptLocation?
        var issue: String?
    }
    struct ResearchControlCompletion: Encodable {
        let channel: Int32
        let kind: String
    }
    struct ResearchStreamReassertHandoff: Encodable {
        let channel: Int32
        let repeats: Int32
        let positionBefore: Int32
        let positionAfter: Int32
    }
    struct ResearchStreamControlHandoff: Encodable {
        let channel: Int32
        let kind: String
        let target: Int32
        let duration: Int32
        let delay: Int32
    }
    struct ResearchPlayModeChange: Encodable {
        let step: Int
        let before: Int32
        let after: Int32
        let location: ScriptLocation
    }
    struct ResearchDrawAudioFrame: Encodable {
        let ticks: Int32
        let pendingSkipTicks: Int32
        let effectiveTicks: Int32
        let zeroClock: Bool
        let visualTicksBefore: Int64
        let visualTicksAfter: Int64
        let positionsBefore: [Int32: Int32]
        let positionsAfter: [Int32: Int32]
    }
    struct DirectSound: Encodable {
        let channelCount: Int32
        let lockMilliseconds: Int32
        let clock = "dispatch_uptime_milliseconds_candidate"
        let playback: String
        let observedStarts: Int?
        let observedCompletions: Int?
        let completionEvents: [LiveAudioObserver.CompletionEvent]?
        let completionEventsTruncated: Bool?
        let originalEquivalence: EvidenceStatus = .notTested
    }
    struct LiveAudio: Encodable {
        let status: EvidenceStatus
        let positions: [Int32: Int32]?
        let positionsBeforeDelay: [Int32: Int32]?
        let observationDelayMilliseconds: Int32
        let maximumSeconds: Int
        let maximumStarts: Int
        let issue: String?
        var completedControlCount: Int = 0
        var pendingControlCount: Int = 0
        var rejectedControlCount: Int = 0
        var completedPlaybackCount: Int = 0
        var playbackStartCount: Int = 0
        var finiteRepeatStarts: Int = 0
        var finiteRepeatReassertions: Int = 0
        var reusedStreamDecodeCount: Int = 0
        var deferredSupersededSyncs: Int = 0
        var streamSwapHandoffs: Int = 0
        var streamSwapCancelledControls: Int = 0
        var positionObservationRecoveries: Int = 0
        var completionIdentityIssue: String? = nil
        var completionIdentityChannel: Int32? = nil
        var observedStreamIndices: [Int32]? = nil
        var machineActiveAudioOnFailure: [ScriptMachine.ResearchActiveAudioSnapshot]? = nil
        var recentLifecycleOnFailure: [LiveAudioObserver.LifecycleEvent]? = nil
        var categoryGains: [Int32: Int32]? = nil
        var playerVolumes: [Int32: Float]? = nil
        var positionsAtWriteRequest: [Int32: Int32]? = nil
        var saveAudioPreflightStatus: EvidenceStatus? = nil
        var saveAudioPreflightIssue: String? = nil
        let clock: String
        var volumeFilterStarts: Int = 0
        var filterChainStarts: Int = 0
        var filterChainClears: Int = 0
        var timeScaleStarts: Int = 0
        var timeScalePositionClock: String? = nil
        var timeScaleSourceDurationMilliseconds: Int32? = nil
        var timeScaleOutputDurationMilliseconds: Int32? = nil
        var unfilteredCandidateStarts: Int = 0
        var volumeFilterUpdates: Int = 0
        var recentFilterUpdates: [LiveAudioObserver.FilterUpdateEvent] = []
        var lastVolumeFilterAudioSHA256: String? = nil
        var candidateSampleRate: Int? = nil
        let positionConversion = "float32_seconds_nearest_even_candidate"
        let scriptTimingEquivalence: EvidenceStatus = .notTested
    }
    var hostIterations = 0
    var remainingMessageClicks: Int
    var remainingTicks: Int32?
    var timedStopRemaining: Int32? = nil
    var timedStopAlternateRemaining: Int32? = nil
    var researchCenterTextStopReached: Bool? = nil
    var researchRubyStopReached: Bool? = nil
    var researchTimedStopFrameTicks: Int32? = nil
    var researchTimedStopFrames: Int? = nil
    var researchTimedStopRealtimeElapsed: [Int32]? = nil
    var researchRealtimeOrdinaryWaitElapsed: [Int32]? = nil
    var researchRealtimeDrawElapsed: [Int32]? = nil
    var researchLastHandledDrawStep: Int? = nil
    var researchTimedStopRealtimeIssue: String? = nil
    var researchTimedStopCompletionRecoveries: Int? = nil
    var researchTimedStopSamplingRecoveries: Int? = nil
    var researchTimedRealtimeMaxFrames: Int? = nil
    var researchTimedStopFreshZeroStart: Int? = nil
    var researchTimedStopFreshZeroStep: Int? = nil
    var researchTimedStopAudioHandoffBridges: Int? = nil
    var researchTimedStopZeroCallbackCompleted: Bool? = nil
    var researchAudioCompletionStopCycles: Int? = nil
    var researchAudioCompletionStopScope: String? = nil
    var researchZeroFollowthroughSteps: Int? = nil
    var researchDrawAudioPositionsBefore: [Int32: Int32]? = nil
    var researchDrawAudioPositionsAfter: [Int32: Int32]? = nil
    var researchDrawAudioFrameScope: String? = nil
    var researchDrawAudioControlIssue: String? = nil
    var researchDrawAudioFollowthroughSteps: Int? = nil
    var researchFollowthroughMaximumSteps: Int? = nil
    var researchFollowthroughMaximumSeconds: Int? = nil
    var researchDrawEventScoped: Bool? = nil
    var researchDrawEventStoryChoice: Bool? = nil
    var researchDrawEventTimed: Bool? = nil
    var researchPlacementConflict: ResearchPlacementConflict? = nil
    var researchDrawWaitRemaining: Int32? = nil
    var researchDrawWaitNextTimer: Int32? = nil
    var researchDrawWaitZeroTimerFrame: Bool? = nil
    var researchDrawWaitTimerFrames: Int? = nil
    var researchDrawWaitTimerDispatched: Bool? = nil
    var researchDrawWaitTimerDispatchCount: Int? = nil
    var researchDrawWaitCompleted: Bool? = nil
    var researchDrawStoryChoiceDispatched: Bool? = nil
    var researchChoiceWaitZeroFrame: Bool? = nil
    var researchChoiceWaitFrames: Int? = nil
    var researchChoiceWaitTimerDispatchCount: Int? = nil
    var researchChoicePostWaitZeroFrame: Bool? = nil
    var researchChoicePostWaitFrames: Int? = nil
    var researchChoicePostWaitCompleted: Bool? = nil
    var researchChoicePostWaitCompletedCount: Int? = nil
    var researchChoicePostDrawFrames: Int? = nil
    var researchLaterWaitZeroFrame: Bool? = nil
    var researchLaterWaitFrames: Int? = nil
    var researchLaterWaitTimerCount: Int? = nil
    var researchLaterWaitCompleted: Bool? = nil
    var researchLaterChoiceDispatched: Bool? = nil
    var researchLaterChoiceWaitZeroFrame: Bool? = nil
    var researchLaterChoiceWaitFrames: Int? = nil
    var researchLaterChoiceWaitTimerCount: Int? = nil
    var researchLaterChoiceWaitCompleted: Bool? = nil
    var researchLaterPostWaitZeroFrames: Int? = nil
    var researchLaterPostWaitFrames: Int? = nil
    var researchLaterPostWaitCompletedCount: Int? = nil
    var researchThirdWaitZeroFrame: Bool? = nil
    var researchThirdWaitFrames: Int? = nil
    var researchThirdWaitTimerCount: Int? = nil
    var researchThirdWaitCompleted: Bool? = nil
    var researchThirdChoiceDispatched: Bool? = nil
    var researchThirdChoiceWaitFrames: Int? = nil
    var researchThirdChoiceWaitTimers: Int? = nil
    var researchThirdChoiceWaitCompleted: Bool? = nil
    var researchThirdPostWaitFrames: Int? = nil
    var researchThirdPostWaitCompleted: Int? = nil
    var researchFourthWaitZeroFrame: Bool? = nil
    var researchFourthWaitFrames: Int? = nil
    var researchFourthWaitTimerCount: Int? = nil
    var researchFourthWaitCompleted: Bool? = nil
    var researchFourthChoiceDispatched: Bool? = nil
    var researchFourthChoiceWaitFrames: Int? = nil
    var researchFourthChoiceWaitTimers: Int? = nil
    var researchFourthChoiceWaitCompleted: Bool? = nil
    var researchFourthPostWaitFrames: Int? = nil
    var researchFourthPostWaitCompleted: Int? = nil
    var researchDrawEventPlayMode: Int32? = nil
    var researchFollowthroughInitialPlayMode: Int32? = nil
    var researchFollowthroughPlayModeChanges: [ResearchPlayModeChange]? = nil
    var researchFollowthroughPlayModeChangesTruncated: Bool? = nil
    var researchDrawEventPendingMessages: Int? = nil
    var researchDrawEventCallbackDispatched: Bool? = nil
    var researchDrawAudioFrames: [ResearchDrawAudioFrame]? = nil
    var researchSkipAudioFrameHandled: Bool? = nil
    var researchSkipAudioFramesHandled: Int? = nil
    var researchStreamResetHandoffs: [Int32]? = nil
    var researchStreamResetControlsCancelled: Int? = nil
    var researchStreamResetCompletionRecoveries: Int? = nil
    var researchStreamPlaybackHandoffs: [Int32]? = nil
    var researchStreamPlaybackHandoffIssue: String? = nil
    var researchPlaybackConcurrentControlCompletions: Int? = nil
    var researchPlaybackConcurrentStreamCompletions: Int? = nil
    var researchPlaybackPositionRecoveries: Int? = nil
    var researchPlaybackPositionRecoveryAttempts: Int? = nil
    var researchPlaybackPositionIssue: String? = nil
    var researchStreamReassertHandoffs: [ResearchStreamReassertHandoff]? = nil
    var researchStreamNaturalCompletions: [Int32]? = nil
    var researchStreamCompletionIssue: String? = nil
    var researchStreamCompletionWaits: Int? = nil
    var researchFrameAudioCompletions: Int? = nil
    var researchFrameStartAudioCompletions: Int? = nil
    var researchFrameStartCombinedControlCompletions: Int? = nil
    var researchStreamControlHandoffs: [ResearchStreamControlHandoff]? = nil
    var researchStreamControlHandoffIssue: String? = nil
    var researchStreamControlIssueBefore: String? = nil
    var researchStreamControlIssueAfter: String? = nil
    var researchStreamControlClassification: String? = nil
    var researchStreamOtherChannelControlCompletions: Int? = nil
    var researchStreamRecoveryControlCompletions: Int? = nil
    var researchStreamReassertControlCompletions: Int? = nil
    var researchStreamControlCompletions: [ResearchControlCompletion]? = nil
    var researchSkipPendingScriptSteps: Int? = nil
    var researchZeroPendingScriptSteps: Int? = nil
    var researchTimedStopFrameScope: String? = nil
    var consumedStoryChoices: Int
    var remainingStoryChoices: Int
    var routeTitleReady: Bool? = nil
    var routeAwaitingChoice: Bool? = nil
    var liveAudio: LiveAudio? = nil
    var startedFromTitle: Bool? = nil
    var titleMenuActions: [String]? = nil
    var routeTitleReachedBeforeMenu: Bool? = nil
    var directSound: DirectSound? = nil
    var explicitButtonArray: String? = nil
    var explicitButtonIndex: Int32? = nil
    var subsequentButtonEvents: [String]? = nil
    var consumedSubsequentButtonEvents: Int? = nil
    var syntheticBarEvent: String? = nil
    var syntheticBarEventConsumed: Bool? = nil
    var researchBarBeforeSubsequentButtons: Bool? = nil
    var researchBarEventSite: ScriptLocation? = nil
    var syntheticBarAxis: String? = nil
    var syntheticBarAxisValue: Int32? = nil
    var syntheticBarAxisScope: String? = nil
    var syntheticBarPoint: [Int32]? = nil
    var syntheticBarPointHit: Bool? = nil
    var syntheticBarPointScope: String? = nil
    var syntheticBarResourceQuad: [Float]? = nil
    var syntheticBarResourcePoint: [Int32]? = nil
    var syntheticBarPointerInput: Bool? = nil
    var syntheticBarCallbackPointer: Bool? = nil
    var syntheticBarPointerInputScope: String? = nil
    var messagePrimaryWriteProbe: ScriptMachine.ResearchMessagePrimaryProbe? = nil
    var messagePrimaryWriteProbeIssue: String? = nil
    var imagePlacementWriteProbe: ScriptMachine.ResearchImagePlacementProbe? = nil
    var imagePlacementWriteProbeIssue: String? = nil
    var researchBarObjectUpdates: Int32? = nil
    var researchBarVisualTicks: Int32? = nil
    var unrenderedBars: [ScriptMachine.UnrenderedBarSnapshot]? = nil
    struct BarProgressSample: Encodable {
        let handle: UInt64
        let easing: String
        let trackEnableMotion: Int32?
        let progressEnableMotion: Int32?
        let status: EvidenceStatus
        let scope = "isolated_progress_texture_fixed_background_not_full_slider"
        let originalPixelEquivalence: EvidenceStatus = .notTested
        let animationTime: Float?
        let sourceArea: [Float]?
        let covered: Bool?
        let changedPixels: Int?
        let canvasSHA256: String?
        let issue: String?
        var compositeStatus: EvidenceStatus? = nil
        var compositeScope: String? = nil
        var trackActionCandidatesCompared: Int? = nil
        var trackChangedPixels: Int? = nil
        var trackCanvasSHA256: String? = nil
        var progressOverlayChangedPixels: Int? = nil
        var compositeChangedPixels: Int? = nil
        var compositeCanvasSHA256: String? = nil
        var compositeIssue: String? = nil
    }
    var barProgressSamples: [BarProgressSample]? = nil
    var barProgressSamplesTruncated: Bool? = nil
    struct UnrenderedButtonText: Encodable {
        let positiveLineAdvanceDirectiveCount: Int
        let layout: EvidenceStatus = .unsupported
    }
    var unrenderedButtonText: UnrenderedButtonText? = nil
    var soundDurationSource: String? = nil
    var videoImageDimensions: EvidenceStatus? = nil
    var videoImageDimensionsScope: String? = nil
    var labelHistoryReadStatus: EvidenceStatus? = nil
    var labelHistoryImported: Bool? = nil
    var labelHistoryReadOutcomes: [String: Int]? = nil
    var researchUnreadLabelQueries: [ResearchUnreadLabelQuery]? = nil
    var researchUnreadLabelQueriesTruncated: Bool? = nil
    var labelProgressTracking: EvidenceStatus? = nil
    var skipFrameCandidate: EvidenceStatus? = nil
    var skipFrameCandidateScope: String? = nil
    var skipFrameCandidateSamples: Int? = nil
    var skipTimeCandidate: EvidenceStatus? = nil
    var skipTimeCandidateScope: String? = nil
    var skipTimeConsumed: Int64? = nil
    var skipTimePending: Int32? = nil
    var skipTimePendingPhase: String? = nil
    var skipTimePendingMediaKind: String? = nil
    var skipTimePendingMediaSource: ScriptLocation? = nil
    var skipTimeMediaHandoffs: Int? = nil
    var researchWindowSkipDispatched: Bool? = nil
    var researchWindowAutoDispatched: Bool? = nil
    var researchWindowAutoAvailabilitySamples: [String: Int]? = nil
    var researchWindowAutoModeBefore: Int32? = nil
    var researchWindowAutoModeAfter: Int32? = nil
    var researchAutoFrameTicks: Int32? = nil
    var researchAutoFrames: Int? = nil
    var researchAutoFrameIssue: String? = nil
    var researchAutoFrameInitialSteps: Int? = nil
    var researchAutoFrameScope: String? = nil
    var researchAutoFramePlayObserved: Bool? = nil
    var researchAutoFrameAudioBefore: [Int32: Int32]? = nil
    var researchAutoFrameAudioAfter: [Int32: Int32]? = nil
    var researchAutoFrameElapsedTicks: [Int32]? = nil
    var researchAutoAudioPositionRetries: Int? = nil
    var researchAutoAudioCompletionWaits: Int? = nil
    var researchAutoAdditionalLines: [ResearchAutoFollowthrough]? = nil
    var researchAutoTimedWait: ResearchAutoTimedWait? = nil
    var researchAutoTimedWaits: [ResearchAutoTimedWait]? = nil
    var researchAutoAfterTimedLines: [ResearchAutoFollowthrough]? = nil
    var researchAutoAfterTimedMaxSeconds: Int? = nil
    var researchAutoAfterLinesTimedWaits: [ResearchAutoTimedWait]? = nil
    var researchWindowSkipAvailabilitySamples: [String: Int]? = nil
    var researchReturnedTitleObserved: Bool? = nil
    var researchReturnedTitleStartDispatched: Bool? = nil
    var researchReturnedTitleStartSteps: Int? = nil
    var researchReturnedTitleStartPhase: String? = nil
    var researchReturnedTitlePostWaitFrames: Int? = nil
    var researchReturnedTitlePostWaitCompleted: Int? = nil
    var researchReturnedTitleAfterWaitPhase: String? = nil
    var researchRestartSelectionWaitZeroFrame: Bool? = nil
    var researchRestartSelectionWaitFrames: Int? = nil
    var researchRestartSelectionWaitTimers: Int? = nil
    var researchRestartSelectionWaitCompleted: Bool? = nil
    var researchDrawBoundaryReached: Bool? = nil
    var researchDrawBoundaryCount: Int32? = nil
    var researchDrawFramesAdvanced: Int? = nil
    var researchDrawFrameTicks: Int32? = nil
    var researchDrawZeroClockFrames: Int? = nil
    var researchWaitZeroClockFrames: Int? = nil
    var researchZeroClockActiveAudio: [ScriptMachine.ResearchActiveAudioSnapshot]? = nil
    var researchZeroLiveAudioFrames: Int? = nil
    var researchZeroWaitFollowthroughSteps: Int? = nil
    var researchZeroEventCallbackSteps: Int? = nil
    var researchZeroEventContinuationSteps: Int? = nil
    var researchZeroEventStreamResets: [Int32]? = nil
    var researchZeroEventVolumeHandoffs: Int? = nil
    var researchZeroEventCallbackCompleted: Bool? = nil
    var researchZeroEventWaitLocation: ScriptLocation? = nil
    var researchZeroEventCallbackLocation: ScriptLocation? = nil
    var researchSubsequentButtonSites: [ScriptLocation]? = nil
    var researchZeroLiveAudioPositions: [Int32: Int32]? = nil
    var researchZeroLiveAudioScope: String? = nil
    var labelProgressTrackingScope: String? = nil
    var labelProgressCandidateOutcomes: [String: Int]? = nil
    var labelProgressReturnOutcomes: [String: Int]? = nil
    var labelProgressFirstContexts: [String: ScriptMachine.LabelProgressContext]? = nil
    var imageFileLogTracking: EvidenceStatus? = nil
    var imageFileLogTrackingScope: String? = nil
    var imageFileLogCandidateAttempts: Int? = nil
    var imageFileLogCandidateMatches: Int? = nil
    var imageFileLogCandidateOutcomes: [String: Int]? = nil
    var firstImageFileLogNoMatchSnapshot: FileLogPatternSnapshot? = nil
    var audioFileLogTracking: EvidenceStatus? = nil
    var audioFileLogTrackingScope: String? = nil
    var audioFileLogCandidateAttempts: Int? = nil
    var audioFileLogCandidateOutcomes: [String: Int]? = nil
}

struct HeadlessLoadTask: Encodable {
    struct TextSurface: Encodable {
        let id: UInt64
        let runCount: Int
        let hasNonWhitespaceText: Bool
        let canvasBounds: [Int64]?
        let priority: Int32?
        let status: EvidenceStatus = .notTested
    }

    struct Layer: Encodable {
        let resource: ScriptLocation
        let boundFirst: ScriptLocation?
        let x: Int32
        let y: Int32
        let priority: Int32
        let action: Int32?
        let time: Int32?
    }

    let machine: ScriptMachineSummary
    let captureRequired: Bool
    let exitRequested: Bool
    var experimentalAdoption: ScriptMachineSummary? = nil
    var experimentalAdoptionIssue: String? = nil
    var experimentalAdoptionRecoveryIssue: String? = nil
    var experimentalAdoptionStagedStreams: Int? = nil
    var experimentalAdoptionRestoredStreamNames: Int? = nil
    var experimentalAdoptionUnrestoredSavedStreamNames: Int? = nil
    var experimentalAdoptionRestoredStreamFilters: Int? = nil
    var experimentalAdoptionUnrestoredSavedStreamFilters: Int? = nil
    var experimentalAdoptionScheduledStreams: Int? = nil
    var experimentalAdoptionScheduledDirectSounds: Int? = nil
    var experimentalAdoptionAudioGaps: [ScriptMachine.ExperimentalSaveAudio.Gap]? = nil
    let saveResumeBoundary: ScriptMachine.SaveResumeBoundary?
    struct SoundBufferCheck: Encodable {
        let recordOffset: Int
        let decodedBytes: Int?
        let passesMinimum: Bool?
        let status: EvidenceStatus
        let issue: String?
    }
    var stagedSoundPlayback: [ScriptMachine.SaveResumeBoundary.SoundResumeRequest]? = nil
    struct StreamSeekCheck: Encodable {
        let recordOffset: Int
        let milliseconds: Int32
        let decodedBytes: Int?
        let status: EvidenceStatus
        let issue: String?
    }
    var streamSeekChecks: [StreamSeekCheck]? = nil
    var soundBufferChecks: [SoundBufferCheck]? = nil
    let checkedPages: [Int32]
    var verifiedPageSelections: [Int32] = []
    var visibleDialogueAfterRestart: Int?
    var clickedSaveSlot: Bool?
    var answeredSaveConfirmation: Bool?
    var resumedTitleAfterUnsupportedSave: Bool?
    let suppliedCaptureSHA256: String?
    let layers: [Layer]
    let visibleTextSurfaces: [TextSurface]
    let savedDisplayDraw: ScriptMachine.SavedDisplayDraw?
    var thumbnailPass: LoadThumbnailPass?
    var thumbnailIssue: String?

    init(_ task: ScriptMachine, suppliedCaptureSHA256: String?) {
        self.suppliedCaptureSHA256 = suppliedCaptureSHA256
        machine = task.summary
        captureRequired = task.screenCaptureRequest != nil
        exitRequested = task.systemTaskExitRequested
        saveResumeBoundary = task.saveResumeBoundary
        savedDisplayDraw = task.savedDisplayDrawReceipt
        checkedPages = task.loadMenuButtons.filter(task.isLoadPageChecked).compactMap(task.loadPageIndex).sorted()
        layers = task.staticImageLayers.map {
            Layer(resource: $0.resource, boundFirst: $0.boundRasterPreview,
                  x: $0.x, y: $0.y, priority: $0.priority, action: $0.selectedMember, time: $0.motionElapsedTicks)
        }
        visibleTextSurfaces = task.messageTextLayers.filter(\.isVisible).map {
            TextSurface(id: $0.id, runCount: $0.runs.count,
                        hasNonWhitespaceText: $0.runs.contains { run in
                            run.text.contains { !$0.isWhitespace } ||
                                (run.ruby?.text.contains { !$0.isWhitespace } ?? false)
                        }, canvasBounds: $0.canvasBounds, priority: $0.priority)
        }
    }
}

struct ScriptRunReport: Encodable {
    let status: EvidenceStatus
    let scope = "Native source/field decoding and optional explicit experimental execution with pinned modules; no game playback"
    let lexical: ScriptLexicalSummary?
    let machine: ScriptMachineSummary?
    let issue: String?
    let sourceFile: String
    let sourceSHA256: String?
    let moduleCandidates: [ScriptModuleReference]?
    let replayBudget: HeadlessReplayBudget?
    let loadTask: HeadlessLoadTask?
    var saveResumeBoundary: ScriptMachine.SaveResumeBoundary? = nil
    var scenePreview: LoadThumbnailPass? = nil
    var scenePreviewIssue: String? = nil
    var pendingMovieVolume: Int32? = nil
}
struct ScriptBatchReport: Encodable {
    let schemaVersion = 1
    let status: EvidenceStatus
    let mode: String
    let reports: [ScriptRunReport]
    let originalFilesWritten = false
    let externalUploads = false
    let fullGameCompatibility: EvidenceStatus = .notTested
}
struct Manifest: Decodable { let items: [Item] }
struct Item: Decodable { let source_file: String; let sha256: String }

struct HeadlessResourceReceipts: Decodable {
    let corpus_report_sha256: String
    let image_resources: [ScriptModuleReference]
    let audio_resources: [ScriptModuleReference]
    let wave_resources: [ScriptModuleReference]

    func indexed(catalogData: Data) throws -> [Data: ScriptModuleReference] {
        let entries = image_resources + audio_resources + wave_resources
        guard entries.count <= 50_000, catalogData.sha256Hex == corpus_report_sha256 else {
            throw ResourceError.rejected("resource_receipt_catalog_identity_or_count")
        }
        var result: [Data: ScriptModuleReference] = [:]
        for entry in entries {
            _ = try SafeDirectory.components(entry.sourceFile)
            let key = try ScriptModuleCatalog.key(entry.logicalPath)
            guard ["png", "jpg", "jpeg", "bmp", "ogg", "ogv", "wav", "b"]
                    .contains((entry.sourceFile as NSString).pathExtension.lowercased()),
                  entry.sourceSHA256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
                  result[key] == nil || result[key] == entry else {
                throw ResourceError.rejected("invalid_or_conflicting_resource_receipt")
            }
            result[key] = entry
        }
        return result
    }
}

@main struct ScriptInspector {
    static func main() {
        do {
            let directArgs = Array(CommandLine.arguments.dropFirst())
            if directArgs.first == "--probe-muted-timescale" {
                guard directArgs.count == 9, directArgs[1] == "--assets-dir", directArgs[3] == "--audio",
                      directArgs[5] == "--movie-tools", directArgs[7] == "--pitch",
                      let pitch = Int32(directArgs[8]) else {
                    throw ResourceError.rejected("invalid_muted_timescale_probe_arguments")
                }
                let directory = try SafeDirectory(URL(fileURLWithPath: directArgs[2], isDirectory: true))
                let bytes = try directory.read(directArgs[4], limit: 16 * 1024 * 1024)
                let location = ScriptModuleReference(logicalPath: directArgs[4], sourceFile: directArgs[4],
                    sourceSHA256: bytes.sha256Hex).wholeFileLocation(byteLength: bytes.count)
                let host = HeadlessMovieHost(tools: URL(fileURLWithPath: directArgs[6], isDirectory: true), assets: directory)
                let converted = try host.audioForTimeScale(location, pitch: pitch)
                let player = try AVAudioPlayer(data: converted.data)
                player.volume = 0
                guard player.prepareToPlay(), player.play() else { throw ResourceError.rejected("muted_timescale_probe_start_failed") }
                let before = player.currentTime
                Thread.sleep(forTimeInterval: 0.1)
                let after = player.currentTime
                player.stop()
                let report: [String: Any] = ["status": "inferred", "sourceSHA256": bytes.sha256Hex,
                    "outputSHA256": converted.data.sha256Hex, "pitch": pitch, "sampleRate": 44100,
                    "sourceDurationMilliseconds": converted.durationMilliseconds, "outputDuration": player.duration,
                    "inputFrames": converted.inputFrames, "outputFrames": (converted.data.count - 44) / 4,
                    "blocks": converted.blocks, "shortReadBlocks": converted.shortReadBlocks,
                    "playerVolume": player.volume, "positionBefore": before, "positionAfter": after,
                    "originalSchedulerEquivalence": "not_tested", "originalFilterEquivalence": "not_tested",
                    "audibleQuality": "not_tested", "gameScriptIntegration": "not_tested"]
                print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
                return
            }
            if directArgs.first == "--probe-muted-filter-chain" {
                guard directArgs.count == 9, directArgs[1] == "--assets-dir", directArgs[3] == "--audio",
                      directArgs[5] == "--movie-tools", directArgs[7] == "--filter" else {
                    throw ResourceError.rejected("invalid_muted_filter_chain_probe_arguments")
                }
                let directory = try SafeDirectory(URL(fileURLWithPath: directArgs[2], isDirectory: true))
                let bytes = try directory.read(directArgs[4], limit: 16 * 1024 * 1024)
                let location = ScriptModuleReference(logicalPath: directArgs[4], sourceFile: directArgs[4],
                    sourceSHA256: bytes.sha256Hex).wholeFileLocation(byteLength: bytes.count)
                let chain = try StreamFilterChainCandidate(researchFilterText: directArgs[8])
                let host = HeadlessMovieHost(tools: URL(fileURLWithPath: directArgs[6], isDirectory: true), assets: directory)
                let converted = try host.audioForLiveObserver(location, chainFilter: chain, candidateSampleRate: 44100)
                let player = try AVAudioPlayer(data: converted.data)
                player.volume = 0
                guard player.prepareToPlay(), player.play() else { throw ResourceError.rejected("muted_filter_chain_probe_start_failed") }
                let before = player.currentTime
                Thread.sleep(forTimeInterval: 0.1)
                let after = player.currentTime
                player.stop()
                let report: [String: Any] = ["status": "inferred", "sourceSHA256": bytes.sha256Hex,
                    "outputSHA256": converted.data.sha256Hex, "stageCount": chain.stageCount,
                    "sampleRate": 44100, "durationMilliseconds": converted.durationMilliseconds,
                    "playerVolume": player.volume, "positionBefore": before, "positionAfter": after,
                    "originalFilterEquivalence": "not_tested", "originalTimingEquivalence": "not_tested",
                    "audibleQuality": "not_tested", "gameScriptIntegration": "not_tested"]
                print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
                return
            }
            let args = Array(CommandLine.arguments.dropFirst())
            var dispatchStop = false
            var inspectLoadTask = false
            var loadTaskEscape = false
            var startAfterLoadEscape = false
            var startFromTitle = false
            var titleMenuTarget: String?
            var requireRouteReturn = false
            var loadTaskPages: [Int32] = []
            var openTitleLoad = false
            var loadThumbnailBackground: String?
            var scenePreviewBackground: String?
            var scenePreviewCanvas: SIMD2<Int>?
            var scenePreviewTicks: Int32?
            var scenePreviewCutinTicks: Int32?
            var scenePreviewVideoFrames = false
            var scenePreviewFrozenVideoFirstFrame = false
            var researchSceneVideoSampleTicks: Int32?
            var researchSceneOutputMask = false
            var scenePreviewSavedLayerTimes = false
            var scenePreviewSavedLayerDelta: Int32?
            var researchStopAtCenterText = false
            var researchStopAtRuby = false
            var exportScenePreviewPNG = false
            var requireCompleteScenePreview = false
            var stopAfterStoryChoices = false
            var recoverUnsupportedSave = false
            var adoptSaveCandidate = false
            var startAfterSaveRecovery = false
            var loadTaskCapturePath: String?
            var saveDirectoryPath: String?
            var researchSystemFile: String?
            var researchSystemExecutable: String?
            var researchSystemOutput: String?
            var researchConfigInput: String?
            var researchConfigOutput: String?
            var researchSettingsInput: String?
            var researchSettingsOutput: String?
            var inspectLabelHistory = false
            var researchLabelReadStatus = false
            var researchLabelProgress = false
            var researchVideoImageDimensions = false
            var researchSkipFrame = false
            var researchSkipTime = false
            var researchSkipMediaHandoff = false
            var researchZeroLiveAudio = false
            var researchZeroWaitFollowthrough = false
            var researchZeroEventCallback = false
            var researchZeroCallbackFollowthrough = false
            var researchZeroAudioDrawFrame = false
            var researchFollowthroughMaximumSteps: Int?
            var researchFollowthroughMaximumSeconds: Int?
            var researchSkipAudioFrame = false
            var researchWindowSkip = false
            var researchWindowAuto = false
            var researchAutoRealtime = false
            var researchAutoFollowTimedWait = false
            var researchAutoAfterLinesTimedWait = false
            var researchTitleStartAfterReturn = false
            var researchImageFileLog = false
            var researchAudioFileLog = false
            var researchSlotDonor: String?
            var researchMessageTemplatePath: String?
            var researchImageTemplatePath: String?
            var saveSceneThumbnail = false
            var researchStreamPositions: [Int32: Int32] = [:]
            var observeLiveAudio = false
            var researchAudibleVolumeFilter = false
            var researchMutedVolumeOutput = false
            var researchMutedFilterChain = false
            var researchMutedTimeScale = false
            var researchAudioRate: Int?
            var inspectUnrenderedBars = false
            var researchBarScenePreview = false
            var researchBarSceneControl = false
            var directSoundCount: Int32?
            var researchObserveDirectSound = false
            var directSoundLock: Int32?
            var liveAudioObservationDelay: Int32 = 0
            var liveAudioMaximumSeconds: Int?
            var liveAudioMaximumStarts: Int?
            var researchDisplaySurfaces: [Int: String] = [:]
            var inferSaveStateSeed = false
            var saveHeaderTemplateFromStdin = false
            var saveHeaderExecutable: String?
            var loadTaskSlot: String?
            var loadTaskConfirmation: Bool?
            var savedAutoWaitClicks = 0
            var savedDialogueClicks = 0
            var clickAfterSavedMovie = false
            var savedReplayStepLimit: Int?
            var loadTaskTicks: Int32?
            var messageClicks = 0
            var buttonIndex: Int32?
            var buttonArray: String?
            var subsequentButtons: [(array: String, index: Int32)] = []
            var researchBarBeforeSubsequentButtons = false
            var syntheticBarEvent: (name: String, value: Int32)?
            var syntheticBarAxis: (name: String, position: Int32, rounding: BarPointerGeometry.Rounding)?
            var syntheticBarPoint: [Int32]?
            var syntheticBarResourceY: Int32?
            var syntheticBarPointerRequest: (name: String, rounding: BarPointerGeometry.Rounding)?
            var syntheticBarPointerInput = false
            var researchBarObjectUpdates: Int32?
            var researchBarVisualTicks: Int32?
            var storyChoices: [Int32] = []
            var pointer: (x: Int32, y: Int32)?
            var compactSavedReplay = false
            var compactTrace = false
            var captureSourceVisits = false
            var coverageSourceFile: String?
            var resourceReceiptsPath: String?
            var resourceProviderPath: String?, resourceCachePath: String?
            var maximumSteps: Int?
            var entryArguments: [ScriptValue] = []
            var clickTicks: Int32?
            var researchDrawFrames: Int?
            var researchDrawFrameTicks: Int32?
            var researchTimedStopFrameTicks: Int32?
            var researchTimedRealtimeMaxFrames: Int?
            var researchStopCallbackTicks: Int32?
            var researchAudioCompletionStopCycles: Int?
            var researchAutoFrameTicks: Int32?
            var researchAutoAdditionalLines: Int?
            var researchAutoTimedWaitCount: Int?
            var researchAutoAfterTimedLines: Int?
            var researchAutoAfterTimedMaxSeconds: Int?
            var movieToolsPath: String?, imageRecipePath: String?, game: String?, assets: String?, source: String?, manifest: String?, entry: String?, catalogPath: String?, selections: [String] = [], execute = false, i = 0
            while i < args.count {
                if args[i] == "--research-bar-before-subsequent-buttons" { researchBarBeforeSubsequentButtons = true; i += 1; continue }
                if args[i] == "--inspect-unrendered-bars" { inspectUnrenderedBars = true; i += 1; continue }
                if args[i] == "--research-bar-scene-preview" { researchBarScenePreview = true; i += 1; continue }
                if args[i] == "--research-bar-scene-control" { researchBarSceneControl = true; i += 1; continue }
                if args[i] == "--inspect-label-history" { inspectLabelHistory = true; i += 1; continue }
                if args[i] == "--research-label-read-status" { researchLabelReadStatus = true; i += 1; continue }
                if args[i] == "--research-label-progress" { researchLabelProgress = true; i += 1; continue }
                if args[i] == "--research-video-image-dimensions" { researchVideoImageDimensions = true; i += 1; continue }
                if args[i] == "--research-skip-frame" { researchSkipFrame = true; i += 1; continue }
                if args[i] == "--research-skip-time" { researchSkipTime = true; i += 1; continue }
                if args[i] == "--research-skip-media-handoff" { researchSkipMediaHandoff = true; i += 1; continue }
                if args[i] == "--research-zero-live-audio" { researchZeroLiveAudio = true; i += 1; continue }
                if args[i] == "--research-zero-wait-followthrough" { researchZeroWaitFollowthrough = true; i += 1; continue }
                if args[i] == "--research-zero-event-callback" { researchZeroEventCallback = true; i += 1; continue }
                if args[i] == "--research-observe-direct-sound" { researchObserveDirectSound = true; i += 1; continue }
                if args[i] == "--research-zero-callback-followthrough" { researchZeroCallbackFollowthrough = true; i += 1; continue }
                if args[i] == "--research-zero-audio-draw-frame" { researchZeroAudioDrawFrame = true; i += 1; continue }
                if args[i] == "--research-skip-audio-frame" { researchSkipAudioFrame = true; i += 1; continue }
                if args[i] == "--research-window-skip" { researchWindowSkip = true; i += 1; continue }
                if args[i] == "--research-window-auto" { researchWindowAuto = true; i += 1; continue }
                if args[i] == "--research-auto-realtime" { researchAutoRealtime = true; i += 1; continue }
                if args[i] == "--research-auto-follow-timed-wait" { researchAutoFollowTimedWait = true; i += 1; continue }
                if args[i] == "--research-auto-after-lines-timed-wait" { researchAutoAfterLinesTimedWait = true; i += 1; continue }
                if args[i] == "--research-title-start-after-return" { researchTitleStartAfterReturn = true; i += 1; continue }
                if args[i] == "--research-image-file-log" { researchImageFileLog = true; i += 1; continue }
                if args[i] == "--research-audio-file-log" { researchAudioFileLog = true; i += 1; continue }
                if args[i] == "--open-title-load" { openTitleLoad = true; i += 1; continue }
                if args[i] == "--observe-live-audio" { observeLiveAudio = true; i += 1; continue }
                if args[i] == "--research-audible-volume-filter" { researchAudibleVolumeFilter = true; i += 1; continue }
                if args[i] == "--research-muted-volume-output" { researchMutedVolumeOutput = true; i += 1; continue }
                if args[i] == "--research-muted-filter-chain" { researchMutedFilterChain = true; i += 1; continue }
                if args[i] == "--research-muted-timescale" { researchMutedTimeScale = true; i += 1; continue }
                if args[i] == "--inspect-load-task" { inspectLoadTask = true; i += 1; continue }
                if args[i] == "--load-task-escape" { loadTaskEscape = true; i += 1; continue }
                if args[i] == "--infer-save-state-seed" { inferSaveStateSeed = true; i += 1; continue }
                if args[i] == "--save-header-template-stdin" { saveHeaderTemplateFromStdin = true; i += 1; continue }
                if args[i] == "--start-after-load-escape" { startAfterLoadEscape = true; i += 1; continue }
                if args[i] == "--start-from-title" { startFromTitle = true; i += 1; continue }
                if args[i] == "--require-route-return" { requireRouteReturn = true; i += 1; continue }
                if args[i] == "--save-scene-thumbnail" { saveSceneThumbnail = true; i += 1; continue }
                if args[i] == "--scene-preview-png" { exportScenePreviewPNG = true; i += 1; continue }
                if args[i] == "--scene-preview-video-frames" { scenePreviewVideoFrames = true; i += 1; continue }
                if args[i] == "--scene-preview-frozen-video-first-frame" { scenePreviewFrozenVideoFirstFrame = true; i += 1; continue }
                if args[i] == "--research-scene-output-mask" { researchSceneOutputMask = true; i += 1; continue }
                if args[i] == "--scene-preview-saved-layer-times" { scenePreviewSavedLayerTimes = true; i += 1; continue }
                if args[i] == "--research-stop-at-center-text" { researchStopAtCenterText = true; i += 1; continue }
                if args[i] == "--research-stop-at-ruby" { researchStopAtRuby = true; i += 1; continue }
                if args[i] == "--require-complete-scene-preview" { requireCompleteScenePreview = true; i += 1; continue }
                if args[i] == "--stop-after-story-choices" { stopAfterStoryChoices = true; i += 1; continue }
                if args[i] == "--start-after-save-recovery" { startAfterSaveRecovery = true; i += 1; continue }
                if args[i] == "--adopt-experimental-save-candidate" { adoptSaveCandidate = true; i += 1; continue }
                if args[i] == "--recover-unsupported-save" { recoverUnsupportedSave = true; i += 1; continue }
                if args[i] == "--dispatch-stop-callback" { dispatchStop = true; i += 1; continue }
                if args[i] == "--click-saved-auto-wait" {
                    guard savedAutoWaitClicks < 64 else { throw ResourceError.rejected("saved_auto_wait_click_limit") }
                    savedAutoWaitClicks += 1
                    i += 1
                    continue
                }
                if args[i] == "--click-saved-dialogue" {
                    guard savedDialogueClicks < 16 else { throw ResourceError.rejected("saved_dialogue_click_limit") }
                    savedDialogueClicks += 1
                    i += 1
                    continue
                }
                if args[i] == "--click-after-saved-movie" { clickAfterSavedMovie = true; i += 1; continue }
                if args[i] == "--message-click" { messageClicks = max(messageClicks, 1); i += 1; continue }
                if args[i] == "--compact-saved-replay" { compactSavedReplay = true; i += 1; continue }
                if args[i] == "--compact-trace" { compactTrace = true; i += 1; continue }
                if args[i] == "--source-visits" { captureSourceVisits = true; i += 1; continue }
                if args[i] == "--experimental-run" { execute = true; i += 1; continue }
                guard i+1 < args.count else { throw ResourceError.rejected("missing_cli_option_value") }
                switch args[i] {
                case "--research-bar-object-updates":
                    guard researchBarObjectUpdates == nil, let count = Int32(args[i+1]), (0...4).contains(count) else {
                        throw ResourceError.rejected("invalid_research_bar_object_updates")
                    }
                    researchBarObjectUpdates = count
                case "--research-bar-visual-ticks":
                    guard researchBarVisualTicks == nil, let ticks = Int32(args[i+1]), (0...5000).contains(ticks) else {
                        throw ResourceError.rejected("invalid_research_bar_visual_ticks")
                    }
                    researchBarVisualTicks = ticks
                case "--subsequent-bar":
                    let parts = args[i+1].split(separator: ":", omittingEmptySubsequences: false)
                    guard syntheticBarAxis == nil, syntheticBarEvent == nil, parts.count == 2, !parts[0].isEmpty,
                          parts[0].utf8.count <= 64,
                          parts[0].utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }),
                          let value = Int32(parts[1]), value >= 0 else {
                        throw ResourceError.rejected("invalid_synthetic_bar_event")
                    }
                    syntheticBarEvent = (String(parts[0]), value)
                case "--scene-preview-saved-layer-delta":
                    guard scenePreviewSavedLayerDelta == nil, let delta = Int32(args[i+1]),
                          (1...100_000).contains(delta) else {
                        throw ResourceError.rejected("invalid_saved_layer_delta")
                    }
                    scenePreviewSavedLayerDelta = delta
                case "--subsequent-bar-axis":
                    let parts = args[i+1].split(separator: ":", omittingEmptySubsequences: false)
                    guard syntheticBarAxis == nil, syntheticBarEvent == nil, parts.count == 3,
                          !parts[0].isEmpty, parts[0].utf8.count <= 64,
                          parts[0].utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }),
                          let position = Int32(parts[1]),
                          let rounding = BarPointerGeometry.Rounding(rawValue: String(parts[2])) else {
                        throw ResourceError.rejected("invalid_synthetic_bar_axis")
                    }
                    syntheticBarAxis = (String(parts[0]), position, rounding)
                case "--subsequent-bar-point":
                    let parts = args[i+1].split(separator: ":", omittingEmptySubsequences: false)
                    guard syntheticBarAxis == nil, syntheticBarEvent == nil, parts.count == 12,
                          !parts[0].isEmpty, parts[0].utf8.count <= 64,
                          parts[0].utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }),
                          let rounding = BarPointerGeometry.Rounding(rawValue: String(parts[11])) else {
                        throw ResourceError.rejected("invalid_synthetic_bar_point")
                    }
                    let coordinates = parts[1...10].compactMap { Int32($0) }
                    guard coordinates.count == 10, coordinates.allSatisfy({ (-32768...32767).contains($0) }) else {
                        throw ResourceError.rejected("invalid_synthetic_bar_point_coordinates")
                    }
                    syntheticBarPoint = coordinates
                    syntheticBarAxis = (String(parts[0]), coordinates[0], rounding)
                case "--subsequent-bar-resource-point":
                    let parts = args[i+1].split(separator: ":", omittingEmptySubsequences: false)
                    guard syntheticBarAxis == nil, syntheticBarEvent == nil, parts.count == 4,
                          !parts[0].isEmpty, parts[0].utf8.count <= 64,
                          parts[0].utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }),
                          let x = Int32(parts[1]), let y = Int32(parts[2]),
                          (-32768...32767).contains(x), (-32768...32767).contains(y),
                          let rounding = BarPointerGeometry.Rounding(rawValue: String(parts[3])) else {
                        throw ResourceError.rejected("invalid_synthetic_bar_resource_point")
                    }
                    syntheticBarResourceY = y
                    syntheticBarAxis = (String(parts[0]), x, rounding)
                case "--subsequent-bar-pointer":
                    let parts = args[i+1].split(separator: ":", omittingEmptySubsequences: false)
                    guard syntheticBarPointerRequest == nil, syntheticBarAxis == nil, syntheticBarEvent == nil,
                          parts.count == 2, !parts[0].isEmpty, parts[0].utf8.count <= 64,
                          parts[0].utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }),
                          let rounding = BarPointerGeometry.Rounding(rawValue: String(parts[1])) else {
                        throw ResourceError.rejected("invalid_synthetic_bar_pointer")
                    }
                    syntheticBarPointerRequest = (String(parts[0]), rounding)
                case "--subsequent-button":
                    let parts = args[i+1].split(separator: ":", omittingEmptySubsequences: false)
                    guard subsequentButtons.count < 16, parts.count == 2,
                          !parts[0].isEmpty, parts[0].utf8.count <= 64,
                          parts[0].utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }),
                          let index = Int32(parts[1]), index >= 0 else {
                        throw ResourceError.rejected("invalid_subsequent_button")
                    }
                    subsequentButtons.append((String(parts[0]), index))
                case "--button-array":
                    let name = args[i+1]
                    guard buttonArray == nil, !name.isEmpty, name.utf8.count <= 64,
                          name.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }) else {
                        throw ResourceError.rejected("invalid_button_array")
                    }
                    buttonArray = name
                case "--direct-sound-count":
                    guard directSoundCount == nil, let value = Int32(args[i+1]), (1...16).contains(value) else {
                        throw ResourceError.rejected("invalid_direct_sound_count")
                    }
                    directSoundCount = value
                case "--direct-sound-lock-ms":
                    guard directSoundLock == nil, let value = Int32(args[i+1]), (0...60_000).contains(value) else {
                        throw ResourceError.rejected("invalid_direct_sound_lock")
                    }
                    directSoundLock = value
                case "--source-coverage":
                    guard coverageSourceFile == nil, !args[i+1].isEmpty, args[i+1].utf8.count <= 4096 else {
                        throw ResourceError.rejected("invalid_source_coverage")
                    }
                    coverageSourceFile = args[i+1]
                case "--resource-cache":
                    guard resourceCachePath == nil, args[i+1].hasPrefix("/") else {
                        throw ResourceError.rejected("invalid_resource_cache_path")
                    }
                    resourceCachePath = args[i+1]
                case "--resource-receipts":
                    guard resourceReceiptsPath == nil else { throw ResourceError.rejected("duplicate_resource_receipts") }
                    resourceReceiptsPath = args[i+1]
                case "--resource-provider":
                    guard resourceProviderPath == nil, args[i+1].hasPrefix("/") else {
                        throw ResourceError.rejected("invalid_resource_provider_path")
                    }
                    resourceProviderPath = args[i+1]
                case "--headless-movie-tools":
                    guard movieToolsPath == nil, args[i+1].hasPrefix("/") else {
                        throw ResourceError.rejected("invalid_movie_tools_directory")
                    }
                    movieToolsPath = args[i+1]
                case "--story-choice":
                    guard storyChoices.count < 64, let index = Int32(args[i+1]), (0..<6).contains(index) else {
                        throw ResourceError.rejected("invalid_story_choice")
                    }
                    storyChoices.append(index)
                case "--title-menu-target":
                    guard titleMenuTarget == nil, ["album", "memory", "sound"].contains(args[i+1]) else {
                        throw ResourceError.rejected("invalid_title_menu_target")
                    }
                    titleMenuTarget = args[i+1]
                case "--button-index":
                    guard buttonIndex == nil, let index = Int32(args[i+1]), index >= 0 else {
                        throw ResourceError.rejected("invalid_button_index")
                    }
                    buttonIndex = index
                case "--pointer":
                    let fields = args[i+1].split(separator: ",",omittingEmptySubsequences: false)
                    guard pointer == nil, fields.count == 2,
                          let x = Int32(fields[0]), let y = Int32(fields[1]) else {
                        throw ResourceError.rejected("invalid_pointer_sample")
                    }
                    pointer = (x,y)
                case "--entry-int":
                    guard entryArguments.count < 16, let value = Int32(args[i+1]) else {
                        throw ResourceError.rejected("invalid_entry_argument")
                    }
                    entryArguments.append(.integer(value))
                case "--entry-string":
                    guard entryArguments.count < 16, args[i+1].utf8.count <= 8192 else {
                        throw ResourceError.rejected("invalid_entry_argument")
                    }
                    entryArguments.append(.string(args[i+1]))
                case "--maximum-steps":
                    guard maximumSteps == nil, let value = Int(args[i+1]), (1...ScriptMachine.maximumSupportedSteps).contains(value) else {
                        throw ResourceError.rejected("invalid_step_budget")
                    }
                    maximumSteps = value
                case "--research-followthrough-max-steps":
                    guard researchFollowthroughMaximumSteps == nil, let value = Int(args[i+1]), (1...64_000_000).contains(value) else {
                        throw ResourceError.rejected("invalid_research_followthrough_max_steps")
                    }
                    researchFollowthroughMaximumSteps = value
                case "--research-followthrough-max-seconds":
                    guard researchFollowthroughMaximumSeconds == nil, let value = Int(args[i+1]), (1...1200).contains(value) else {
                        throw ResourceError.rejected("invalid_research_followthrough_max_seconds")
                    }
                    researchFollowthroughMaximumSeconds = value
                case "--research-draw-frames":
                    guard researchDrawFrames == nil, let value = Int(args[i+1]), (1...16384).contains(value) else {
                        throw ResourceError.rejected("invalid_research_draw_frame_count")
                    }
                    researchDrawFrames = value
                case "--research-draw-frame-ticks":
                    guard researchDrawFrameTicks == nil, let value = Int32(args[i+1]), (1...1000).contains(value) else {
                        throw ResourceError.rejected("invalid_research_draw_frame_ticks")
                    }
                    researchDrawFrameTicks = value
                case "--research-timed-stop-frame-ticks":
                    guard researchTimedStopFrameTicks == nil, let value = Int32(args[i+1]), (1...1000).contains(value) else {
                        throw ResourceError.rejected("invalid_research_timed_stop_frame_ticks")
                    }
                    researchTimedStopFrameTicks = value
                case "--research-timed-realtime-max-frames":
                    guard researchTimedRealtimeMaxFrames == nil, let value = Int(args[i+1]), (1...1024).contains(value) else {
                        throw ResourceError.rejected("invalid_research_timed_realtime_max_frames")
                    }
                    researchTimedRealtimeMaxFrames = value
                case "--research-stop-callback-ticks":
                    guard researchStopCallbackTicks == nil, let value = Int32(args[i+1]), (0...1000).contains(value) else {
                        throw ResourceError.rejected("invalid_research_stop_callback_ticks")
                    }
                    researchStopCallbackTicks = value
                case "--research-audio-completion-stop-cycles":
                    guard researchAudioCompletionStopCycles == nil, let value = Int(args[i+1]), (1...16).contains(value) else {
                        throw ResourceError.rejected("invalid_research_audio_completion_stop_cycles")
                    }
                    researchAudioCompletionStopCycles = value
                case "--research-auto-frame-ticks":
                    guard researchAutoFrameTicks == nil, let value = Int32(args[i+1]), (1...1000).contains(value) else {
                        throw ResourceError.rejected("invalid_research_auto_frame_ticks")
                    }
                    researchAutoFrameTicks = value
                case "--research-auto-additional-lines":
                    guard researchAutoAdditionalLines == nil, let value = Int(args[i+1]), (1...2).contains(value) else {
                        throw ResourceError.rejected("invalid_research_auto_additional_lines")
                    }
                    researchAutoAdditionalLines = value
                case "--research-auto-timed-waits":
                    guard researchAutoTimedWaitCount == nil, let value = Int(args[i+1]), (1...3).contains(value) else {
                        throw ResourceError.rejected("invalid_research_auto_timed_waits")
                    }
                    researchAutoTimedWaitCount = value
                case "--research-auto-after-timed-lines":
                    guard researchAutoAfterTimedLines == nil, let value = Int(args[i+1]), (1...64).contains(value) else {
                        throw ResourceError.rejected("invalid_research_auto_after_timed_lines")
                    }
                    researchAutoAfterTimedLines = value
                case "--research-auto-after-timed-max-seconds":
                    guard researchAutoAfterTimedMaxSeconds == nil, let value = Int(args[i+1]), (1...120).contains(value) else {
                        throw ResourceError.rejected("invalid_research_auto_after_timed_max_seconds")
                    }
                    researchAutoAfterTimedMaxSeconds = value
                case "--message-clicks":
                    guard let count = Int(args[i+1]), (1...24000).contains(count) else {
                        throw ResourceError.rejected("invalid_message_click_count")
                    }
                    messageClicks = count
                case "--click-ticks":
                    guard clickTicks == nil, let value = Int32(args[i+1]), (0...3_000_000).contains(value) else {
                        throw ResourceError.rejected("invalid_click_tick_budget")
                    }
                    clickTicks = value
                case "--load-thumbnail-background":
                    guard loadThumbnailBackground == nil else { throw ResourceError.rejected("duplicate_thumbnail_background") }
                    loadThumbnailBackground = args[i+1]
                case "--scene-preview-background":
                    guard scenePreviewBackground == nil else { throw ResourceError.rejected("duplicate_scene_preview_background") }
                    scenePreviewBackground = args[i+1]
                case "--scene-preview-canvas":
                    let dimensions = args[i+1].split(separator: "x", omittingEmptySubsequences: false)
                    guard scenePreviewCanvas == nil, dimensions.count == 2,
                          let width = Int(dimensions[0]), let height = Int(dimensions[1]),
                          (1...4096).contains(width), (1...4096).contains(height), width * height <= 4_194_304 else {
                        throw ResourceError.rejected("invalid_scene_preview_canvas")
                    }
                    scenePreviewCanvas = SIMD2(width, height)
                case "--scene-preview-ticks":
                    guard scenePreviewTicks == nil, let ticks = Int32(args[i+1]), (0...3_000_000).contains(ticks) else {
                        throw ResourceError.rejected("invalid_scene_preview_ticks")
                    }
                    scenePreviewTicks = ticks
                case "--research-scene-video-ticks":
                    guard researchSceneVideoSampleTicks == nil, let ticks = Int32(args[i+1]), (0...10_000).contains(ticks) else {
                        throw ResourceError.rejected("invalid_research_scene_video_ticks")
                    }
                    researchSceneVideoSampleTicks = ticks
                case "--scene-preview-cutin-ticks":
                    guard scenePreviewCutinTicks == nil, let ticks = Int32(args[i+1]), (0..<30_000).contains(ticks) else {
                        throw ResourceError.rejected("invalid_scene_preview_cutin_ticks")
                    }
                    scenePreviewCutinTicks = ticks
                case "--load-task-ticks":
                    guard loadTaskTicks == nil, let ticks = Int32(args[i+1]), (0...3_000_000).contains(ticks) else {
                        throw ResourceError.rejected("invalid_load_task_tick_budget")
                    }
                    loadTaskTicks = ticks
                case "--load-task-page":
                    guard loadTaskPages.count < 32, let page = Int32(args[i+1]), page >= 0 else {
                        throw ResourceError.rejected("invalid_load_task_page")
                    }
                    loadTaskPages.append(page)
                case "--load-task-capture":
                    guard loadTaskCapturePath == nil else { throw ResourceError.rejected("duplicate_load_task_capture") }
                    loadTaskCapturePath = args[i+1]
                case "--save-display-surface":
                    let fields = args[i+1].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    guard fields.count == 2,
                          let index = Int(fields[0]), (0...1).contains(index), fields[1].hasPrefix("/"),
                          researchDisplaySurfaces[index] == nil else {
                        throw ResourceError.rejected("invalid_or_duplicate_save_display_surface")
                    }
                    researchDisplaySurfaces[index] = String(fields[1])
                case "--save-stream-position":
                    let fields = args[i+1].split(separator: "=", omittingEmptySubsequences: false)
                    guard fields.count == 2, let channel = Int32(fields[0]), channel >= 0,
                          let milliseconds = Int32(fields[1]), milliseconds >= 0,
                          researchStreamPositions[channel] == nil else {
                        throw ResourceError.rejected("invalid_or_duplicate_save_stream_position")
                    }
                    researchStreamPositions[channel] = milliseconds
                case "--live-audio-observe-ms":
                    guard let milliseconds = Int32(args[i+1]), (1...5000).contains(milliseconds),
                          liveAudioObservationDelay == 0 else {
                        throw ResourceError.rejected("invalid_live_audio_observation_delay")
                    }
                    liveAudioObservationDelay = milliseconds
                case "--live-audio-max-seconds":
                    guard liveAudioMaximumSeconds == nil, let seconds = Int(args[i+1]), (1...3600).contains(seconds) else {
                        throw ResourceError.rejected("invalid_live_audio_max_seconds")
                    }
                    liveAudioMaximumSeconds = seconds
                case "--live-audio-max-starts":
                    guard liveAudioMaximumStarts == nil, let count = Int(args[i+1]), (1...8192).contains(count) else {
                        throw ResourceError.rejected("invalid_live_audio_max_starts")
                    }
                    liveAudioMaximumStarts = count
                case "--research-audio-rate":
                    guard researchAudioRate == nil, let rate = Int(args[i+1]), [22050, 44100].contains(rate) else {
                        throw ResourceError.rejected("invalid_research_audio_rate")
                    }
                    researchAudioRate = rate
                case "--export-timed-wait-slot":
                    guard researchSlotDonor == nil, try SafeDirectory.components(args[i+1]).count == 1 else {
                        throw ResourceError.rejected("invalid_research_slot_donor")
                    }
                    researchSlotDonor = args[i+1]
                case "--research-message-template":
                    guard researchMessageTemplatePath == nil, !args[i+1].isEmpty else {
                        throw ResourceError.rejected("invalid_research_message_template")
                    }
                    researchMessageTemplatePath = args[i+1]
                case "--research-image-template":
                    guard researchImageTemplatePath == nil, !args[i+1].isEmpty else {
                        throw ResourceError.rejected("invalid_research_image_template")
                    }
                    researchImageTemplatePath = args[i+1]
                case "--save-dir":
                    guard saveDirectoryPath == nil else { throw ResourceError.rejected("duplicate_save_directory") }
                    saveDirectoryPath = args[i+1]
                case "--research-system-file":
                    guard researchSystemFile == nil, try SafeDirectory.components(args[i+1]).count == 1 else {
                        throw ResourceError.rejected("invalid_research_system_file")
                    }
                    researchSystemFile = args[i+1]
                case "--research-system-exe":
                    guard researchSystemExecutable == nil else { throw ResourceError.rejected("duplicate_research_system_exe") }
                    researchSystemExecutable = args[i+1]
                case "--research-system-output":
                    guard researchSystemOutput == nil, try SafeDirectory.components(args[i+1]).count <= 16 else {
                        throw ResourceError.rejected("invalid_research_system_output")
                    }
                    researchSystemOutput = args[i+1]
                case "--research-config-input":
                    guard researchConfigInput == nil, try SafeDirectory.components(args[i+1]).count <= 16 else {
                        throw ResourceError.rejected("invalid_research_config_input")
                    }
                    researchConfigInput = args[i+1]
                case "--research-config-output":
                    guard researchConfigOutput == nil, try SafeDirectory.components(args[i+1]).count <= 16 else {
                        throw ResourceError.rejected("invalid_research_config_output")
                    }
                    researchConfigOutput = args[i+1]
                case "--research-settings-input":
                    guard researchSettingsInput == nil, try SafeDirectory.components(args[i+1]).count <= 16 else {
                        throw ResourceError.rejected("invalid_research_settings_input")
                    }
                    researchSettingsInput = args[i+1]
                case "--research-settings-output":
                    guard researchSettingsOutput == nil, try SafeDirectory.components(args[i+1]).count <= 16 else {
                        throw ResourceError.rejected("invalid_research_settings_output")
                    }
                    researchSettingsOutput = args[i+1]
                case "--save-header-exe":
                    guard saveHeaderExecutable == nil else { throw ResourceError.rejected("duplicate_save_header_exe") }
                    saveHeaderExecutable = args[i+1]
                case "--load-task-slot":
                    guard loadTaskSlot == nil else { throw ResourceError.rejected("duplicate_load_task_slot") }
                    loadTaskSlot = args[i+1]
                case "--saved-replay-step-limit":
                    guard savedReplayStepLimit == nil, let limit = Int(args[i+1]), (1...ScriptMachine.maximumCompactSavedReplaySteps).contains(limit) else {
                        throw ResourceError.rejected("invalid_saved_replay_step_limit")
                    }
                    savedReplayStepLimit = limit
                case "--load-task-confirm":
                    guard loadTaskConfirmation == nil, ["yes", "no"].contains(args[i+1]) else {
                        throw ResourceError.rejected("invalid_load_task_confirmation")
                    }
                    loadTaskConfirmation = args[i+1] == "yes"
                case "--image-recipe": guard imageRecipePath == nil else { throw ResourceError.rejected("duplicate_image_recipe") }; imageRecipePath = args[i+1]
                case "--game-dir": guard game == nil else { throw ResourceError.rejected("duplicate_game_option") }; game = args[i+1]
                case "--assets-dir": guard assets == nil else { throw ResourceError.rejected("duplicate_assets_option") }; assets = args[i+1]
                case "--script": guard source == nil else { throw ResourceError.rejected("duplicate_script_option") }; source = args[i+1]
                case "--manifest": guard manifest == nil else { throw ResourceError.rejected("duplicate_manifest_option") }; manifest = args[i+1]
                case "--entry-label": guard entry == nil else { throw ResourceError.rejected("duplicate_entry_option") }; entry = args[i+1]
                case "--catalog": guard catalogPath == nil else { throw ResourceError.rejected("duplicate_catalog_option") }; catalogPath = args[i+1]
                case "--select-source": selections.append(args[i+1]); guard selections.count <= 512 else { throw ResourceError.rejected("module_selection_limit") }
                default: throw ResourceError.rejected("unknown_cli_option")
                }
                i += 2
            }
            if let request = syntheticBarPointerRequest {
                guard let pointer, (-32768...32767).contains(pointer.x), (-32768...32767).contains(pointer.y) else {
                    throw ResourceError.rejected("synthetic_bar_pointer_requires_bounded_pointer_sample")
                }
                syntheticBarAxis = (request.name, pointer.x, request.rounding)
                syntheticBarResourceY = pointer.y
                syntheticBarPointerInput = true
            }
            guard (pointer == nil && buttonIndex == nil) || (execute && dispatchStop) else { throw ResourceError.rejected("pointer_requires_stop_dispatch") }
            let restoredSoundInspection = titleMenuTarget == "sound" && researchSystemFile != nil &&
                saveDirectoryPath != nil && researchSystemOutput == nil
            guard !researchBarSceneControl || researchBarScenePreview else {
                throw ResourceError.rejected("bar_scene_control_requires_preview")
            }
            guard !researchBarScenePreview || (inspectUnrenderedBars && scenePreviewBackground != nil &&
                !researchSceneOutputMask && !saveSceneThumbnail && !exportScenePreviewPNG && !requireCompleteScenePreview &&
                !inspectLoadTask && !adoptSaveCandidate && researchSlotDonor == nil && researchSystemOutput == nil) else {
                throw ResourceError.rejected("bar_scene_preview_requires_read_only_research")
            }
            guard !inspectUnrenderedBars || (execute && (scenePreviewBackground == nil || researchBarScenePreview) && loadThumbnailBackground == nil &&
                researchSlotDonor == nil && (saveDirectoryPath == nil || restoredSoundInspection) && !openTitleLoad && !inspectLoadTask &&
                !adoptSaveCandidate && !saveSceneThumbnail &&
                (pointer == nil || syntheticBarPointerInput || (researchZeroEventCallback && researchObserveDirectSound && buttonIndex != nil)) &&
                !startFromTitle && (titleMenuTarget == nil || restoredSoundInspection) && !requireRouteReturn &&
                storyChoices.isEmpty && messageClicks == 0) else {
                throw ResourceError.rejected("unrendered_bar_inspection_requires_headless_scope")
            }
            guard buttonArray == nil || buttonIndex != nil else { throw ResourceError.rejected("button_array_requires_index") }
            guard subsequentButtons.isEmpty || (execute && dispatchStop && (buttonIndex != nil || titleMenuTarget != nil)) else {
                throw ResourceError.rejected("subsequent_button_requires_initial_button")
            }
            guard (syntheticBarEvent == nil && syntheticBarAxis == nil) || (inspectUnrenderedBars && observeLiveAudio && dispatchStop &&
                (buttonIndex != nil || (restoredSoundInspection && !subsequentButtons.isEmpty))) else {
                throw ResourceError.rejected("synthetic_bar_event_requires_live_research_mode")
            }
            guard !researchBarBeforeSubsequentButtons || (researchZeroEventCallback && !subsequentButtons.isEmpty &&
                (syntheticBarEvent != nil || syntheticBarAxis != nil)) else {
                throw ResourceError.rejected("bar_before_buttons_requires_event_research")
            }
            guard researchBarObjectUpdates == nil || syntheticBarEvent != nil || syntheticBarAxis != nil else {
                throw ResourceError.rejected("research_bar_updates_require_synthetic_event")
            }
            guard researchBarVisualTicks == nil || syntheticBarEvent != nil || syntheticBarAxis != nil else {
                throw ResourceError.rejected("research_bar_visual_ticks_require_synthetic_event")
            }
            guard (directSoundCount == nil && directSoundLock == nil) ||
                (directSoundCount != nil && directSoundLock != nil && execute && movieToolsPath != nil &&
                 (!observeLiveAudio || researchObserveDirectSound)) else {
                throw ResourceError.rejected("direct_sound_requires_headless_decoder_and_configuration")
            }
            guard let assets, (source == nil) != (manifest == nil), !execute || source != nil, entry == nil || execute else {
                throw ResourceError.rejected("Usage: mangekyou-script --assets-dir PATH (--script RELATIVE | --manifest JSON) [--experimental-run [--entry-label @@LABEL] [--catalog JSON [--select-source RELATIVE]...]]")
            }
            guard catalogPath == nil || execute, selections.isEmpty || catalogPath != nil else { throw ResourceError.rejected("module_catalog_requires_explicit_execution") }
            guard resourceReceiptsPath == nil || (catalogPath != nil && resourceProviderPath == nil) else {
                throw ResourceError.rejected("resource_receipts_require_catalog_and_no_provider")
            }
            guard resourceProviderPath == nil || catalogPath != nil else { throw ResourceError.rejected("resource_provider_requires_catalog") }
            guard resourceCachePath == nil || resourceProviderPath != nil else {
                throw ResourceError.rejected("resource_cache_requires_provider")
            }
            let resourceCache: [String: ScriptModuleReference] = try resourceCachePath.map { path in
                let url = URL(fileURLWithPath: path)
                let directory = try SafeDirectory(url.deletingLastPathComponent())
                let entries = try JSONDecoder().decode([String: ScriptModuleReference].self,
                    from: directory.read(url.lastPathComponent, limit: 8*1024*1024))
                guard entries.count <= 20_000 else { throw ResourceError.rejected("resource_cache_entry_limit") }
                return entries
            } ?? [:]
            let directory = try SafeDirectory(URL(fileURLWithPath: assets,isDirectory: true))
            guard clickTicks == nil || execute else { throw ResourceError.rejected("click_ticks_require_execution") }
            guard game == nil || execute else { throw ResourceError.rejected("game_configuration_requires_execution") }
            guard !openTitleLoad || inspectLoadTask else { throw ResourceError.rejected("title_load_requires_task_inspection") }
            guard !loadTaskEscape || inspectLoadTask else { throw ResourceError.rejected("escape_requires_load_task") }
            guard !startAfterLoadEscape || (openTitleLoad && loadTaskEscape) else {
                throw ResourceError.rejected("start_requires_title_load_escape")
            }
            guard !requireRouteReturn || ((startAfterLoadEscape || startFromTitle) && !storyChoices.isEmpty) else {
                throw ResourceError.rejected("route_return_requires_restart_and_choices")
            }
            guard loadTaskPages.isEmpty || inspectLoadTask else {
                throw ResourceError.rejected("page_requires_load_task")
            }
            guard (loadTaskCapturePath == nil && loadTaskTicks == nil && loadThumbnailBackground == nil) || inspectLoadTask else { throw ResourceError.rejected("capture_requires_load_task") }
            guard !inspectLoadTask || execute else { throw ResourceError.rejected("load_task_requires_execution") }
            guard scenePreviewBackground == nil || execute else {
                throw ResourceError.rejected("scene_preview_requires_execution")
            }
            guard scenePreviewTicks == nil || scenePreviewBackground != nil else {
                throw ResourceError.rejected("scene_preview_ticks_requires_background")
            }
            guard scenePreviewCutinTicks == nil || (scenePreviewBackground != nil && movieToolsPath != nil && !saveSceneThumbnail) else {
                throw ResourceError.rejected("cutin_frame_requires_scene_preview_and_decoder")
            }
            guard !scenePreviewVideoFrames || (scenePreviewBackground != nil && movieToolsPath != nil && !saveSceneThumbnail) else {
                throw ResourceError.rejected("scene_video_frames_require_preview_and_decoder")
            }
            guard !scenePreviewFrozenVideoFirstFrame || (scenePreviewVideoFrames && scenePreviewTicks == 0 &&
                !inspectLoadTask && !saveSceneThumbnail) else {
                throw ResourceError.rejected("frozen_video_first_frame_requires_zero_tick_preview")
            }
            guard researchSceneVideoSampleTicks == nil || (scenePreviewVideoFrames && scenePreviewTicks == 0 &&
                !scenePreviewFrozenVideoFirstFrame && !inspectLoadTask && !adoptSaveCandidate &&
                !saveSceneThumbnail && researchSlotDonor == nil && researchSystemOutput == nil && !openTitleLoad) else {
                throw ResourceError.rejected("explicit_video_sample_requires_fresh_zero_tick_preview")
            }
            guard !researchSceneOutputMask || (scenePreviewBackground != nil && !inspectLoadTask &&
                !adoptSaveCandidate && !saveSceneThumbnail && !inspectUnrenderedBars &&
                researchSlotDonor == nil && researchSystemOutput == nil && !openTitleLoad) else {
                throw ResourceError.rejected("scene_output_mask_requires_fresh_read_only_preview")
            }
            guard scenePreviewSavedLayerDelta == nil || scenePreviewSavedLayerTimes else {
                throw ResourceError.rejected("saved_layer_delta_requires_saved_layer_times")
            }
            guard !scenePreviewSavedLayerTimes || (inspectLoadTask && loadTaskSlot != nil && loadTaskConfirmation == true &&
                  scenePreviewBackground != nil && scenePreviewTicks == 0 && !adoptSaveCandidate &&
                  !saveSceneThumbnail && !exportScenePreviewPNG) else {
                throw ResourceError.rejected("saved_layer_times_require_frozen_isolated_load_preview")
            }
            guard scenePreviewCanvas == nil || scenePreviewBackground != nil else {
                throw ResourceError.rejected("scene_preview_canvas_requires_background")
            }
            guard !researchStopAtCenterText || (execute && source != nil && scenePreviewBackground != nil &&
                  researchSlotDonor == nil && researchSystemOutput == nil && !adoptSaveCandidate &&
                  !inspectLoadTask && !inspectUnrenderedBars) else {
                throw ResourceError.rejected("research_center_text_requires_read_only_scene_replay")
            }
            guard !researchStopAtRuby || (execute && source != nil && scenePreviewBackground != nil && dispatchStop &&
                  researchSlotDonor == nil && researchSystemOutput == nil && !adoptSaveCandidate &&
                  !inspectLoadTask && !inspectUnrenderedBars && !saveSceneThumbnail) else {
                throw ResourceError.rejected("research_ruby_requires_read_only_scene_replay")
            }
            guard !requireCompleteScenePreview || scenePreviewBackground != nil || loadThumbnailBackground != nil else {
                throw ResourceError.rejected("complete_scene_preview_requires_background")
            }
            guard !stopAfterStoryChoices || (execute && !storyChoices.isEmpty && !requireRouteReturn) else {
                throw ResourceError.rejected("stop_after_story_choices_requires_partial_choice_replay")
            }
            guard saveDirectoryPath == nil || execute else { throw ResourceError.rejected("save_directory_requires_execution") }
            guard !inferSaveStateSeed || saveDirectoryPath != nil else {
                throw ResourceError.rejected("save_seed_inference_requires_save_directory")
            }
            guard (!saveHeaderTemplateFromStdin && saveHeaderExecutable == nil)
                    || (loadTaskConfirmation == true && !inferSaveStateSeed &&
                        !(saveHeaderTemplateFromStdin && saveHeaderExecutable != nil)) else {
                throw ResourceError.rejected("save_header_template_requires_confirmed_slot")
            }
            guard loadTaskSlot == nil || (inspectLoadTask && saveDirectoryPath != nil && !loadTaskEscape) else {
                throw ResourceError.rejected("slot_click_requires_load_task_and_save_directory")
            }
            guard loadTaskConfirmation == nil || loadTaskSlot != nil else {
                throw ResourceError.rejected("confirmation_requires_load_task_slot")
            }
            guard compactSavedReplay || (savedReplayStepLimit ?? 0) <= ScriptMachine.maximumFullSavedReplaySteps else {
                throw ResourceError.rejected("extended_saved_replay_requires_compact_trace")
            }
            guard savedReplayStepLimit == nil || loadTaskConfirmation == true else {
                throw ResourceError.rejected("saved_replay_step_limit_requires_confirmed_slot")
            }
            guard (savedDialogueClicks == 0 && savedAutoWaitClicks == 0) || (loadTaskConfirmation == true && scenePreviewBackground != nil) else {
                throw ResourceError.rejected("saved_dialogue_click_requires_confirmed_slot_and_scene_preview")
            }
            guard !clickAfterSavedMovie || (loadTaskConfirmation == true && movieToolsPath != nil) else {
                throw ResourceError.rejected("saved_movie_click_requires_confirmed_slot_and_movie_host")
            }
            guard !startAfterSaveRecovery || recoverUnsupportedSave || adoptSaveCandidate else {
                throw ResourceError.rejected("start_after_save_recovery_requires_recovery")
            }
            guard !recoverUnsupportedSave || (openTitleLoad && loadTaskConfirmation == true) else {
                throw ResourceError.rejected("recover_unsupported_save_requires_title_load_confirmation")
            }
            guard !adoptSaveCandidate || (inspectLoadTask && openTitleLoad && loadTaskConfirmation == true && !recoverUnsupportedSave) else {
                throw ResourceError.rejected("adopt_save_requires_confirmed_title_load")
            }
            let saveDirectory = try saveDirectoryPath.map {
                try SafeDirectory(URL(fileURLWithPath: $0, isDirectory: true))
            }
            guard researchSettingsInput == nil || (researchSystemFile == nil && researchConfigInput == nil),
                  researchSettingsOutput == nil || (researchSystemOutput == nil && researchConfigOutput == nil &&
                    researchSlotDonor == nil && !inspectLoadTask && !adoptSaveCandidate && !exportScenePreviewPNG),
                  (researchSettingsInput == nil && researchSettingsOutput == nil) ||
                    (execute && game != nil && source != nil && researchSystemExecutable != nil &&
                     researchSlotDonor == nil && !inspectLoadTask && !adoptSaveCandidate && !exportScenePreviewPNG) else {
                throw ResourceError.rejected("research_settings_bundle_conflicting_options")
            }
            let settingsBundleInput: ResearchSettingsBundle?
            if let path = researchSettingsInput {
                let privateURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                    .appendingPathComponent("private", isDirectory: true)
                settingsBundleInput = try ResearchSettingsBundle.decode(SafeDirectory(privateURL).read(path, limit: 12 * 1024 * 1024))
            } else { settingsBundleInput = nil }
            let researchSystemData: SaveSystemData?
            if let bundle = settingsBundleInput {
                guard let game, let executable = researchSystemExecutable else {
                    throw ResourceError.rejected("research_settings_bundle_requires_game_exe")
                }
                let gameDirectory = try SafeDirectory(URL(fileURLWithPath: game, isDirectory: true))
                let template = try SaveSystemData.headerTemplate(from: gameDirectory, executable: executable)
                researchSystemData = try SaveSystemData(data: bundle.systemData, headerTemplate: template)
            } else if let name = researchSystemFile {
                guard execute, let saveDirectory, let game, let executable = researchSystemExecutable else {
                    throw ResourceError.rejected("research_system_file_requires_execution_save_directory_and_game_exe")
                }
                let gameDirectory = try SafeDirectory(URL(fileURLWithPath: game, isDirectory: true))
                let template = try SaveSystemData.headerTemplate(from: gameDirectory, executable: executable)
                researchSystemData = try SaveSystemData(data: saveDirectory.read(name, limit: SaveEnvelope.maxFileBytes),
                                                        headerTemplate: template)
            } else {
                guard researchSystemExecutable == nil else { throw ResourceError.rejected("research_system_exe_requires_system_file") }
                researchSystemData = nil
            }
            guard !inspectLabelHistory || (execute && source != nil) else {
                throw ResourceError.rejected("label_history_probe_requires_single_script_execution")
            }
            guard !researchLabelReadStatus || (execute && source != nil && catalogPath != nil &&
                  (researchSystemData != nil || (researchSystemOutput == nil && researchSlotDonor == nil))) else {
                throw ResourceError.rejected("label_read_candidate_requires_catalog_and_read_only_fresh_session")
            }
            guard !researchLabelProgress || (execute && source != nil && catalogPath != nil &&
                  (researchSystemData != nil || (researchSystemOutput == nil && researchSlotDonor == nil))) else {
                throw ResourceError.rejected("label_progress_candidate_requires_catalog_and_read_only_fresh_session")
            }
            guard !researchVideoImageDimensions || (execute && source != nil && researchSystemOutput == nil &&
                  researchSlotDonor == nil && scenePreviewBackground == nil && loadThumbnailBackground == nil) else {
                throw ResourceError.rejected("video_image_dimensions_requires_read_only_single_script")
            }
            guard !researchSkipFrame || (execute && source != nil && researchSystemOutput == nil && researchSlotDonor == nil) else {
                throw ResourceError.rejected("skip_frame_candidate_requires_read_only_single_replay")
            }
            guard !researchSkipTime || researchSkipFrame else {
                throw ResourceError.rejected("skip_time_candidate_requires_skip_frame_candidate")
            }
            guard !researchTitleStartAfterReturn || (requireRouteReturn && researchWindowSkip && researchZeroAudioDrawFrame && titleMenuTarget == nil) else {
                throw ResourceError.rejected("research_title_start_requires_route_return_and_observed_skip")
            }
            guard !researchSkipMediaHandoff || (researchSkipTime && movieToolsPath != nil && !observeLiveAudio) else {
                throw ResourceError.rejected("skip_media_handoff_requires_headless_skip_research")
            }
            guard (researchDrawFrames == nil && researchDrawFrameTicks == nil) ||
                (researchDrawFrames != nil && researchDrawFrameTicks != nil && researchSkipTime) else {
                throw ResourceError.rejected("draw_frame_research_requires_count_ticks_and_skip_research")
            }
            guard !researchZeroLiveAudio || (researchSkipTime && observeLiveAudio && researchDrawFrameTicks != nil) else {
                throw ResourceError.rejected("zero_live_audio_requires_observer_and_explicit_frame_ticks")
            }
            guard researchTimedStopFrameTicks == nil || (execute && source != nil && clickTicks != nil &&
                researchSystemOutput == nil && researchSlotDonor == nil &&
                (!researchSkipTime || (researchZeroLiveAudio && (researchWindowSkip || researchZeroEventCallback) &&
                    researchTimedStopFrameTicks == researchDrawFrameTicks))) else {
                throw ResourceError.rejected("timed_stop_frame_requires_read_only_budgeted_replay")
            }
            guard researchStopCallbackTicks == nil || (execute && source != nil && dispatchStop &&
                researchTimedStopFrameTicks == nil && researchSystemOutput == nil && researchSlotDonor == nil && researchConfigOutput == nil &&
                !researchSkipTime) else {
                throw ResourceError.rejected("stop_callback_ticks_require_read_only_explicit_dispatch")
            }
            guard researchAudioCompletionStopCycles == nil || (researchStopCallbackTicks != nil && observeLiveAudio &&
                messageClicks == 0 && pointer == nil && buttonIndex == nil && storyChoices.isEmpty) else {
                throw ResourceError.rejected("audio_completion_stop_cycles_require_explicit_observed_replay")
            }
            guard !researchZeroWaitFollowthrough || (researchZeroLiveAudio && clickTicks != nil) else {
                throw ResourceError.rejected("zero_wait_followthrough_requires_observed_wait")
            }
            guard !researchZeroEventCallback || (researchZeroWaitFollowthrough && dispatchStop && pointer != nil) else {
                throw ResourceError.rejected("zero_event_callback_requires_observed_pointer_cycle")
            }
            guard !researchObserveDirectSound || (researchZeroEventCallback && observeLiveAudio &&
                directSoundCount != nil && directSoundLock != nil && !researchAudibleVolumeFilter && !researchMutedFilterChain) else {
                throw ResourceError.rejected("direct_sound_observation_requires_muted_event_research")
            }
            guard researchTimedRealtimeMaxFrames == nil || (researchZeroEventCallback && researchTimedStopFrameTicks != nil) else {
                throw ResourceError.rejected("timed_realtime_max_frames_requires_event_research")
            }
            guard !researchZeroCallbackFollowthrough || (researchZeroLiveAudio && researchWindowSkip && researchTimedStopFrameTicks != nil) else {
                throw ResourceError.rejected("zero_callback_followthrough_requires_matched_zero_frame_research")
            }
            guard !researchZeroAudioDrawFrame || (researchZeroCallbackFollowthrough && researchDrawFrames != nil) else {
                throw ResourceError.rejected("zero_audio_draw_frame_requires_followthrough_and_frame_budget")
            }
            guard (researchFollowthroughMaximumSteps == nil && researchFollowthroughMaximumSeconds == nil) || researchZeroAudioDrawFrame else {
                throw ResourceError.rejected("research_followthrough_budget_requires_draw_audio")
            }
            guard !researchSkipAudioFrame || researchZeroAudioDrawFrame else {
                throw ResourceError.rejected("skip_audio_frame_requires_draw_audio_research")
            }
            guard !researchWindowSkip || (researchSkipFrame && startFromTitle && dispatchStop && buttonIndex == nil) else {
                throw ResourceError.rejected("window_skip_candidate_requires_title_replay")
            }
            guard !researchWindowAuto || (execute && source != nil && startFromTitle && dispatchStop &&
                buttonIndex == nil && !researchWindowSkip && !researchSkipTime && researchSystemOutput == nil &&
                researchSlotDonor == nil && researchConfigOutput == nil) else {
                throw ResourceError.rejected("window_auto_requires_read_only_title_replay")
            }
            guard researchAutoFrameTicks == nil || (researchWindowAuto && researchAudioCompletionStopCycles == nil &&
                researchStopCallbackTicks == nil) else {
                throw ResourceError.rejected("auto_frame_ticks_require_read_only_auto_replay")
            }
            guard !researchAutoRealtime || (observeLiveAudio && researchAutoFrameTicks != nil && researchAutoFrameTicks! <= 500) else {
                throw ResourceError.rejected("auto_realtime_requires_observed_audio_and_bounded_interval")
            }
            guard researchAutoAdditionalLines == nil || (researchAutoRealtime && storyChoices.isEmpty && titleMenuTarget == nil) else {
                throw ResourceError.rejected("auto_additional_lines_require_realtime_without_choices")
            }
            guard !researchAutoFollowTimedWait || (researchAutoAdditionalLines != nil && researchAutoRealtime && clickTicks != nil) else {
                throw ResourceError.rejected("auto_timed_wait_requires_budgeted_realtime_followthrough")
            }
            guard researchAutoTimedWaitCount == nil || researchAutoFollowTimedWait else {
                throw ResourceError.rejected("auto_timed_wait_count_requires_followthrough")
            }
            guard researchAutoAfterTimedLines == nil || (researchAutoFollowTimedWait && researchAutoTimedWaitCount != nil) else {
                throw ResourceError.rejected("auto_after_timed_lines_require_timed_waits")
            }
            guard researchAutoAfterTimedMaxSeconds == nil || researchAutoAfterTimedLines != nil else {
                throw ResourceError.rejected("auto_after_timed_max_seconds_requires_followthrough")
            }
            guard !researchAutoAfterLinesTimedWait || researchAutoAfterTimedLines != nil else {
                throw ResourceError.rejected("auto_after_lines_timed_wait_requires_followthrough")
            }
            guard !researchImageFileLog || (execute && researchSystemData != nil && source != nil && catalogPath != nil) else {
                throw ResourceError.rejected("image_file_log_candidate_requires_system_data_and_catalog")
            }
            guard !researchAudioFileLog || (execute && researchSystemData != nil && source != nil && catalogPath != nil) else {
                throw ResourceError.rejected("audio_file_log_candidate_requires_system_data_and_catalog")
            }
            var saveHeaderTemplate: Data?
            if let executable = saveHeaderExecutable {
                guard let game else { throw ResourceError.rejected("save_header_exe_requires_game_directory") }
                let gameDirectory = try SafeDirectory(URL(fileURLWithPath: game, isDirectory: true))
                saveHeaderTemplate = try SaveEnvelope.slotHeaderTemplate(from: gameDirectory, executable: executable)
            } else if saveHeaderTemplateFromStdin {
                var template = Data()
                while template.count < 41,
                      let chunk = try FileHandle.standardInput.read(upToCount: 41 - template.count),
                      !chunk.isEmpty {
                    template.append(chunk)
                }
                guard template.count == 40 else { throw ResourceError.rejected("save_header_verification_bounds") }
                saveHeaderTemplate = template
            }
            let saveSlots = try saveDirectory.map { directory in
                try SaveSlotInventory.scan(directory, includeMetadata: true) { payload in
                    _ = try ResourceImage.decode(payload)
                }
            }
            guard saveSlots?.contains(where: { $0.status == .unsupported }) != true else {
                throw ResourceError.rejected("save_directory_contains_unsupported_entries")
            }
            for slot in saveSlots ?? [] {
                if let issue = slot.issue {
                    FileHandle.standardError.write(Data("save_thumbnail_issue=\(issue)\n".utf8))
                }
            }
            guard imageRecipePath == nil || execute else { throw ResourceError.rejected("image_recipe_requires_execution") }
            let imageRecipe = try imageRecipePath.map { path in
                let url = URL(fileURLWithPath: path)
                let directory = try SafeDirectory(url.deletingLastPathComponent())
                return try JSONDecoder().decode(ScriptImageRecipe.self,from: directory.read(url.lastPathComponent, limit: 1024 * 1024))
            } ?? ScriptImageRecipe()
            guard movieToolsPath == nil || execute else { throw ResourceError.rejected("movie_tools_require_execution") }
            var movieHost = movieToolsPath.map {
                HeadlessMovieHost(tools: URL(fileURLWithPath: $0,isDirectory: true), assets: directory)
            }
            let configuration = try game.map { root in
                let directory = try SafeDirectory(URL(fileURLWithPath: root,isDirectory: true))
                let path = "GameData/System/config.txt"
                return try ScriptTable(data: directory.read(path,limit: 1024*1024),relativePath: path)
            }
            var repository: ScriptRepository?
            if let catalogPath {
                let url = URL(fileURLWithPath: catalogPath)
                let container = try SafeDirectory(url.deletingLastPathComponent())
                let catalogData = try container.read(url.lastPathComponent, limit: 32 * 1024 * 1024)
                let file = try JSONDecoder().decode(ScriptCatalogFile.self, from: catalogData)
                var catalog = try ScriptModuleCatalog(entries: file.items,indexedResourceNames: file.indexedResourceNames)
                for selection in selections { try catalog.select(sourceFile: selection) }
                let supply: (@Sendable (String) throws -> ScriptModuleReference)?
                if let path = resourceReceiptsPath {
                    let url = URL(fileURLWithPath: path)
                    let receiptDirectory = try SafeDirectory(url.deletingLastPathComponent())
                    let file = try JSONDecoder().decode(HeadlessResourceReceipts.self,
                        from: receiptDirectory.read(url.lastPathComponent, limit: 32 * 1024 * 1024))
                    let receipts = try file.indexed(catalogData: catalogData)
                    supply = { logical in
                        guard let receipt = receipts[try ScriptModuleCatalog.key(logical)] else {
                            let path = String(reflecting: logical)
                            FileHandle.standardError.write(Data("missing_replay_resource=\(path)\n".utf8))
                            throw ResourceError.rejected("resource_copy_not_in_replay")
                        }
                        return receipt
                    }
                } else if let resourceProviderPath {
                    let provider = LocalResourceProvider(executable: URL(fileURLWithPath: resourceProviderPath), cache: resourceCache)
                    supply = { try provider.load($0) }
                } else {
                    supply = nil
                }
                repository = try ScriptRepository(directory: directory,catalog: catalog,supplyResource: supply)
            }
            var items: [Item] = []
            if let source { items = [Item(source_file: source,sha256: "")] }
            else if let manifest {
                let url = URL(fileURLWithPath: manifest)
                let container = try SafeDirectory(url.deletingLastPathComponent())
                items = try JSONDecoder().decode(Manifest.self,from: container.read(url.lastPathComponent,limit: 32*1024*1024)).items
            }
            guard (1...2000).contains(items.count) else { throw ResourceError.rejected("script_file_count_limit") }
            var reports: [ScriptRunReport] = [], seen = Set<String>(), total = 0
            let clock = ContinuousClock(); let deadline = clock.now.advanced(by: .seconds(120))
            guard !exportScenePreviewPNG || (scenePreviewBackground != nil && source != nil && items.count == 1) else {
                throw ResourceError.rejected("scene_preview_png_requires_single_script_and_background")
            }
            guard (researchStreamPositions.isEmpty && researchDisplaySurfaces.isEmpty) || researchSlotDonor != nil else {
                throw ResourceError.rejected("save_state_options_require_slot_export")
            }
            guard entryArguments.isEmpty || (execute && entry != nil && source != nil && items.count == 1) else {
                throw ResourceError.rejected("entry_arguments_require_single_experimental_entry")
            }
            guard !observeLiveAudio || (execute && source != nil && items.count == 1 && movieToolsPath != nil &&
                  researchStreamPositions.isEmpty && !adoptSaveCandidate) else {
                throw ResourceError.rejected("live_audio_observer_requires_single_script_and_decoder")
            }
            guard !researchAudibleVolumeFilter || (observeLiveAudio && researchSlotDonor == nil &&
                  !researchSkipFrame && !researchWindowSkip) else {
                throw ResourceError.rejected("audible_volume_candidate_requires_live_observer_and_no_export")
            }
            guard !researchMutedVolumeOutput || researchAudibleVolumeFilter else {
                throw ResourceError.rejected("muted_volume_output_requires_volume_candidate")
            }
            guard !researchMutedFilterChain || (researchMutedVolumeOutput && researchAudioRate == 44100) else {
                throw ResourceError.rejected("muted_filter_chain_requires_muted_volume_candidate_and_44100")
            }
            guard !researchMutedTimeScale || (researchMutedFilterChain && !researchSkipTime && !researchSkipAudioFrame &&
                  !inspectUnrenderedBars && !researchZeroLiveAudio) else {
                throw ResourceError.rejected("muted_timescale_requires_filtered_observer_without_skip")
            }
            guard researchAudioRate == nil || researchAudibleVolumeFilter else {
                throw ResourceError.rejected("research_audio_rate_requires_volume_candidate")
            }
            guard !startFromTitle || (execute && source != nil && items.count == 1 && !openTitleLoad &&
                  !inspectLoadTask && !startAfterLoadEscape) else {
                throw ResourceError.rejected("start_from_title_requires_single_direct_replay")
            }
            guard titleMenuTarget == nil || (execute && source != nil && items.count == 1 && dispatchStop &&
                  !startFromTitle && buttonIndex == nil && researchSlotDonor == nil &&
                  (requireRouteReturn || (!inspectLoadTask && (pointer == nil || syntheticBarPointerInput) &&
                      (storyChoices.isEmpty || titleMenuTarget == "memory")))) else {
                throw ResourceError.rejected("title_menu_target_requires_single_direct_replay")
            }
            guard liveAudioObservationDelay == 0 || observeLiveAudio else {
                throw ResourceError.rejected("live_audio_observation_delay_requires_observer")
            }
            guard liveAudioMaximumSeconds == nil || observeLiveAudio else {
                throw ResourceError.rejected("live_audio_max_seconds_requires_observer")
            }
            guard liveAudioMaximumStarts == nil || observeLiveAudio else {
                throw ResourceError.rejected("live_audio_max_starts_requires_observer")
            }
            guard researchSlotDonor == nil || (execute && source != nil && items.count == 1 &&
                  saveDirectory != nil && repository != nil && !exportScenePreviewPNG && !inspectLoadTask && !requireRouteReturn) else {
                throw ResourceError.rejected("research_slot_export_requires_single_script_catalog_and_save_directory")
            }
            guard researchMessageTemplatePath == nil || researchSlotDonor != nil else {
                throw ResourceError.rejected("research_message_template_requires_slot_export")
            }
            guard researchImageTemplatePath == nil || researchSlotDonor != nil else {
                throw ResourceError.rejected("research_image_template_requires_slot_export")
            }
            guard !saveSceneThumbnail || (researchSlotDonor != nil && scenePreviewBackground != nil && scenePreviewTicks == nil) else {
                throw ResourceError.rejected("save_scene_thumbnail_requires_slot_export_and_current_scene_background")
            }
            var researchOutputDirectory: SafeDirectory?
            var researchOutputName: String?
            var researchConfigOutputDirectory: SafeDirectory?
            var researchConfigOutputName: String?
            var researchConfigInputData: Data? = settingsBundleInput?.configurationOverlay
            var researchSettingsOutputDirectory: SafeDirectory?
            var researchSettingsOutputName: String?
            if researchConfigInput != nil || researchConfigOutput != nil {
                guard execute, game != nil, source != nil, items.count == 1,
                      (researchSystemOutput == nil || researchConfigOutput == nil),
                      researchSlotDonor == nil, !exportScenePreviewPNG,
                      !inspectLoadTask, !adoptSaveCandidate else {
                    throw ResourceError.rejected("research_config_overlay_requires_single_session")
                }
                let privateURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                    .appendingPathComponent("private", isDirectory: true)
                if let path = researchConfigInput {
                    researchConfigInputData = try SafeDirectory(privateURL).read(path, limit: 64 * 1024)
                }
                if let path = researchConfigOutput {
                    let parts = try SafeDirectory.components(path)
                    var outputURL = privateURL
                    for part in parts.dropLast() { outputURL.appendPathComponent(part, isDirectory: true) }
                    outputURL = outputURL.standardizedFileURL
                    let outputComponents = outputURL.pathComponents.map { $0.lowercased() }
                    for input in [assets, game, saveDirectoryPath].compactMap({ $0 }) {
                        let components = URL(fileURLWithPath: input, isDirectory: true).standardizedFileURL.pathComponents.map { $0.lowercased() }
                        guard !outputComponents.starts(with: components) else {
                            throw ResourceError.rejected("research_output_inside_input_directory")
                        }
                    }
                    researchConfigOutputDirectory = try SafeDirectory(outputURL)
                    researchConfigOutputName = parts.last
                }
            }
            if let path = researchSystemOutput {
                guard researchSystemData != nil, source != nil, items.count == 1,
                      researchSlotDonor == nil, !exportScenePreviewPNG,
                      (!inspectLoadTask || (requireRouteReturn && titleMenuTarget == nil)) else {
                    throw ResourceError.rejected("research_system_output_requires_single_session")
                }
                let parts = try SafeDirectory.components(path)
                var outputURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                    .appendingPathComponent("private", isDirectory: true)
                for part in parts.dropLast() { outputURL.appendPathComponent(part, isDirectory: true) }
                outputURL = outputURL.standardizedFileURL
                researchOutputName = parts.last
                let outputComponents = outputURL.pathComponents.map { $0.lowercased() }
                for input in [assets, game, saveDirectoryPath].compactMap({ $0 }) {
                    let components = URL(fileURLWithPath: input, isDirectory: true).standardizedFileURL.pathComponents.map { $0.lowercased() }
                    guard !outputComponents.starts(with: components) else {
                        throw ResourceError.rejected("research_output_inside_input_directory")
                    }
                }
                researchOutputDirectory = try SafeDirectory(outputURL)
            }
            if let path = researchSettingsOutput {
                guard researchSystemData != nil else { throw ResourceError.rejected("research_settings_bundle_requires_system_data") }
                let parts = try SafeDirectory.components(path)
                var outputURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                    .appendingPathComponent("private", isDirectory: true)
                for part in parts.dropLast() { outputURL.appendPathComponent(part, isDirectory: true) }
                outputURL = outputURL.standardizedFileURL
                let outputComponents = outputURL.pathComponents.map { $0.lowercased() }
                for input in [assets, game, saveDirectoryPath].compactMap({ $0 }) {
                    let components = URL(fileURLWithPath: input, isDirectory: true).standardizedFileURL.pathComponents.map { $0.lowercased() }
                    guard !outputComponents.starts(with: components) else {
                        throw ResourceError.rejected("research_output_inside_input_directory")
                    }
                }
                researchSettingsOutputDirectory = try SafeDirectory(outputURL)
                researchSettingsOutputName = parts.last
            }
            var researchSlot: Data?
            var researchSystemOutputData: Data?
            var researchConfigOutputData: Data?
            var researchSettingsOutputData: Data?
            var scenePNG: Data?
            for item in items {
                var sha: String?
                do {
                    guard seen.insert(item.source_file).inserted else { throw ResourceError.rejected("duplicate_source_in_manifest") }
                    guard clock.now < deadline else { throw ResourceError.rejected("script_batch_time_limit") }
                    let data = try directory.read(item.source_file); sha = data.sha256Hex; total += data.count
                    guard total <= 128*1024*1024 else { throw ResourceError.rejected("script_batch_byte_limit") }
                    if !item.sha256.isEmpty, sha != item.sha256 { throw ResourceError.rejected("script_manifest_identity") }
                    let document = try ScriptDocument(data: data,relativePath: item.source_file)
                    let lexical = ScriptLexicalSummary(document)
                    var result: ScriptMachineSummary?
                    var candidates: [ScriptModuleReference]?
                    var replayBudget: HeadlessReplayBudget?
                    var loadTask: HeadlessLoadTask?
                    var routeIssue: String?
                    var saveResumeBoundary: ScriptMachine.SaveResumeBoundary?
                    var scenePreview: LoadThumbnailPass?
                    var scenePreviewIssue: String?
                    var pendingMovieVolume: Int32?
                    var researchSlotIssue: String?
                    var liveAudioObservationIssue: String?
                    var researchHostIssue: String?
                    if execute {
                        let liveAudioObserver = observeLiveAudio ? LiveAudioObserver(maximumSeconds: liveAudioMaximumSeconds ?? 120,
                            maximumStarts: liveAudioMaximumStarts ?? 512, allowVolumeFilter: researchAudibleVolumeFilter,
                            forceMuteOutput: researchMutedVolumeOutput, candidateSampleRate: researchAudioRate ?? 22050,
                            allowFilterChain: researchMutedFilterChain, allowTimeScale: researchMutedTimeScale) : nil
                        var machine = try ScriptMachine(program: ScriptProgram(document),allowExperimental: true,entryLabel: entry,entryArguments: entryArguments,maximumSteps: maximumSteps ?? 10_000,repository: repository,configuration: configuration, imageLoader: imageRecipe.dimensions,
                            imageMemberLookup: imageRecipe.member, imageExtendedValues: imageRecipe.extendedValues,
                            imageMotionNames: imageRecipe.motionNames, retainFullTrace: !compactTrace)
                        if let researchConfigInputData { try machine.applyResearchConfigurationOverlay(researchConfigInputData) }
                        if let researchSystemData {
                            let count = try machine.stageSystemDataScalars(researchSystemData)
                            FileHandle.standardError.write(Data("research_system_scalars=inferred count=\(count) file_log_entries=\(researchSystemData.summary.fileLogEntries) label_log_entries=\(researchSystemData.summary.labelLogEntries) automatic_read_tracking=unsupported\n".utf8))
                        }
                        machine.inspectUnrenderedBars = inspectUnrenderedBars
                        machine.allowLabelHistoryCandidate = researchLabelReadStatus
                        machine.allowResearchVideoImageDimensions = researchVideoImageDimensions
                        machine.allowImageFileLogCandidate = researchImageFileLog
                        machine.allowLabelProgressCandidate = researchLabelProgress
                        machine.allowResearchSkipFrameCandidate = researchSkipFrame
                        machine.allowResearchSkipTimeCandidate = researchSkipTime
                        if researchSkipFrame {
                            FileHandle.standardError.write(Data("research_skip_frame=inferred context_flag_assumed_clear other_writers_unmodelled original_equivalence=not_tested\n".utf8))
                        }
                        machine.allowAudioFileLogCandidate = researchAudioFileLog
                        machine.allowLiveSoundPositionQuery = observeLiveAudio
                        machine.allowLiveSoundSwapHandoff = observeLiveAudio
                        machine.allowLiveSoundFilterHandoff = researchAudibleVolumeFilter
                        machine.allowLiveSoundFilterChainHandoff = researchMutedFilterChain
                        if let directSoundCount, let directSoundLock {
                            try machine.configureHeadlessDirectSound(channelCount: directSoundCount, lockMilliseconds: directSoundLock)
                        }
                        if let saveSlots {
                            try machine.setReadOnlySaveSlots(saveSlots, directory: saveDirectory,
                                                             inferStateSeed: inferSaveStateSeed,
                                                             headerTemplate: saveHeaderTemplate)
                        }
                        machine.savedMotionUpdateThreshold = imageRecipe.motionUpdateThreshold
                        machine.retainExperimentalSaveCandidate = adoptSaveCandidate
                        machine.captureSourceVisits = captureSourceVisits
                        machine.coverageSourceFile = coverageSourceFile
                        try machine.run(stepQuota: maximumSteps ?? 10_000)
                        var budget = clickTicks
                        var pendingDispatch = dispatchStop
                        var subsequentButtonCursor = 0
                        var syntheticBarEventConsumed = false
                        var researchBarEventSite: ScriptLocation?
                        var syntheticBarAxisValue: Int32?
                        var syntheticBarResourceQuad: [Float]?
                        var pendingScopedDispatch = dispatchStop
                        var pendingMessageClicks = messageClicks
                        var researchCenterTextStopReached = false
                        var researchRubyStopReached = false
                        var hostIterations = 0
                        var choiceCursor = 0
                        var openedTitleLoad = false
                        var startedFromTitle = false
                        var researchWindowSkipDispatched = false
                        var researchWindowAutoDispatched = false
                        var researchWindowAutoAvailabilitySamples: [String: Int] = [:]
                        var researchWindowAutoModeBefore: Int32?
                        var researchWindowAutoModeAfter: Int32?
                        var stopAfterAutoTimedMediaHandoff = false
                        var autoTimedMediaHandoffCompleted = false
                        var autoTimedMediaContinuationStart: Int?
                        var stopAfterAutoTimedSoundSwap = false
                        var autoTimedSoundSwapCompleted = false
                        var autoTimedSoundSwapContinuationStart: Int?
                        var researchWindowSkipAvailabilitySamples: [String: Int] = [:]
                        var researchReturnedTitleObserved = false
                        var researchReturnedTitleStartDispatched = false
                        var researchReturnedTitleStartSteps = 0
                        var researchReturnedTitleStartPhase: String?
                        var researchReturnedTitlePostWaitFrames = 0
                        var researchReturnedTitlePostWaitCompleted = 0
                        var researchReturnedTitleAfterWaitPhase: String?
                        var researchRestartSelectionWaitZeroFrame = false
                        var researchRestartSelectionWaitFrames = 0
                        var researchRestartSelectionWaitTimers = 0
                        var researchRestartSelectionWaitCompleted = false
                        var researchSkipMediaHandoffs = 0
                        var researchZeroLiveAudioFrames = 0
                        var researchZeroWaitFollowthroughSteps = 0
                        var researchZeroEventCallbackSteps = 0
                        var researchZeroEventContinuationSteps = 0
                        var researchZeroEventStreamResets: [Int32] = []
                        var researchZeroEventVolumeHandoffs = 0
                        var researchZeroEventCallbackCompleted = false
                        var researchZeroEventWaitLocation: ScriptLocation?
                        var researchZeroEventCallbackLocation: ScriptLocation?
                        var researchSubsequentButtonSites: [ScriptLocation] = []
                        var researchZeroLiveAudioPositions: [Int32: Int32]?
                        var researchDrawFramesAdvanced = 0
                        var researchTimedStopFrames = 0
                        var researchTimedStopRealtimeElapsed: [Int32] = []
                        var researchRealtimeOrdinaryWaitElapsed: [Int32] = []
                        var researchRealtimeDrawElapsed: [Int32] = []
                        var researchLastHandledDrawStep: Int?
                        var researchTimedStopRealtimeIssue: String?
                        var researchTimedStopCompletionRecoveries = 0
                        var researchTimedStopSamplingRecoveries = 0
                        var researchTimedStopFreshZeroStart: Int?
                        var researchTimedStopFreshZeroStep: Int?
                        var researchTimedStopZeroCallbackCompleted: Bool?
                        var researchZeroFollowthroughSteps = 0
                        var researchDrawAudioPositionsBefore: [Int32: Int32]?
                        var researchDrawAudioPositionsAfter: [Int32: Int32]?
                        var researchDrawAudioControlIssue: String?
                        var researchDrawAudioFollowthroughSteps = 0
                        var researchDrawEventCallbackDispatched = false
                        var researchDrawWaitZeroTimerFrame = false
                        var researchDrawWaitTimerFrames = 0
                        var researchDrawWaitTimerDispatched = false
                        var researchDrawWaitTimerDispatchCount = 0
                        var researchDrawWaitCompleted = false
                        var researchDrawStoryChoiceDispatched = false
                        var researchChoiceWaitZeroFrame = false
                        var researchChoiceWaitFrames = 0
                        var researchChoiceWaitTimerDispatchCount = 0
                        var researchChoicePostWaitZeroFrame = false
                        var researchChoicePostWaitFrames = 0
                        var researchChoicePostWaitCompleted = false
                        var researchChoicePostWaitCompletedCount = 0
                        var researchChoicePostDrawFrames = 0
                        var researchLaterWaitZeroFrame = false
                        var researchLaterWaitFrames = 0
                        var researchLaterWaitTimerCount = 0
                        var researchLaterWaitCompleted = false
                        var researchLaterChoiceDispatched = false
                        var researchLaterChoiceWaitZeroFrame = false
                        var researchLaterChoiceWaitFrames = 0
                        var researchLaterChoiceWaitTimerCount = 0
                        var researchLaterChoiceWaitCompleted = false
                        var researchLaterPostWaitZeroFrames = 0
                        var researchLaterPostWaitFrames = 0
                        var researchLaterPostWaitCompletedCount = 0
                        var researchThirdWaitZeroFrame = false
                        var researchThirdWaitFrames = 0
                        var researchThirdWaitTimerCount = 0
                        var researchThirdWaitCompleted = false
                        var researchThirdChoiceDispatched = false
                        var researchThirdChoiceWaitFrames = 0
                        var researchThirdChoiceWaitTimers = 0
                        var researchThirdChoiceWaitCompleted = false
                        var researchThirdPostWaitFrames = 0
                        var researchThirdPostWaitCompleted = 0
                        var researchFourthWaitZeroFrame = false
                        var researchFourthWaitFrames = 0
                        var researchFourthWaitTimerCount = 0
                        var researchFourthWaitCompleted = false
                        var researchFourthChoiceDispatched = false
                        var researchFourthChoiceWaitFrames = 0
                        var researchFourthChoiceWaitTimers = 0
                        var researchFourthChoiceWaitCompleted = false
                        var researchFourthPostWaitFrames = 0
                        var researchFourthPostWaitCompleted = 0
                        var researchFollowthroughInitialPlayMode: Int32?
                        var researchFollowthroughPlayModeChanges: [HeadlessReplayBudget.ResearchPlayModeChange] = []
                        var researchFollowthroughPlayModeChangesTruncated = false
                        var researchDrawAudioFrames: [HeadlessReplayBudget.ResearchDrawAudioFrame] = []
                        var researchSkipAudioFrameHandled = false
                        var researchSkipAudioFramesHandled = 0
                        var researchStreamResetHandoffs: [Int32] = []
                        var researchStreamResetControlsCancelled = 0
                        var researchStreamResetCompletionRecoveries = 0
                        var researchStreamPlaybackHandoffs: [Int32] = []
                        var researchStreamPlaybackHandoffIssue: String?
                        var researchPlaybackConcurrentControlCompletions = 0
                        var researchPlaybackConcurrentStreamCompletions = 0
                        var researchPlaybackPositionRecoveries = 0
                        var researchPlaybackPositionRecoveryAttempts = 0
                        var researchPlaybackPositionIssue: String?
                        var reusedStreamDecodeCount = 0
                        var researchStreamReassertHandoffs: [HeadlessReplayBudget.ResearchStreamReassertHandoff] = []
                        var researchStreamNaturalCompletions: [Int32] = []
                        var researchStreamCompletionIssue: String?
                        var researchStreamCompletionWaits = 0
                        var researchFrameAudioCompletions = 0
                        var researchFrameStartAudioCompletions = 0
                        var researchFrameStartCombinedControlCompletions = 0
                        var researchStreamControlHandoffs: [HeadlessReplayBudget.ResearchStreamControlHandoff] = []
                        var researchStreamControlHandoffIssue: String?
                        var researchStreamControlIssueBefore: String?
                        var researchStreamControlIssueAfter: String?
                        var researchStreamControlClassification: String?
                        var researchStreamOtherChannelControlCompletions = 0
                        var researchStreamRecoveryControlCompletions = 0
                        var researchStreamReassertControlCompletions = 0
                        var researchStreamControlCompletions: [HeadlessReplayBudget.ResearchControlCompletion] = []
                        var researchSkipPendingScriptSteps = 0
                        var researchZeroPendingScriptSteps = 0
                        var titleMenuActions: [String] = []
                        var titleMenuIssue: String?
                        var routeStartedForMenu = false
                        var routeTitleReachedBeforeMenu = false
                        var lastRouteProgressSteps = 0
                        func checkedResearchZeroAudioPositions() throws -> [Int32: Int32]? {
                            let active = machine.activeSoundChannels
                            guard researchZeroLiveAudio, !active.isEmpty else { return nil }
                            guard researchZeroLiveAudioFrames == 0 ||
                                (researchZeroEventCallback && !pendingDispatch &&
                                 researchZeroLiveAudioFrames < (researchTimedRealtimeMaxFrames ?? 64)) else {
                                throw ResourceError.rejected("zero_clock_live_audio_frame_budget_exhausted")
                            }
                            guard let observer = liveAudioObserver, observer.rejectedControlCount == 0 else {
                                throw ResourceError.rejected("zero_clock_live_audio_unavailable")
                            }
                            let snapshots = machine.activeStreamPlaybackSnapshots
                            guard snapshots.count == active.count else {
                                throw ResourceError.rejected("zero_clock_live_audio_nonstream_unsupported")
                            }
                            do { return try observer.positions(for: snapshots) }
                            catch { throw ResourceError.rejected("zero_clock_live_audio_identity_unavailable") }
                        }
                        func checkedRealtimeStreamPositions(_ observer: LiveAudioObserver) throws -> [Int32: Int32] {
                            let active = machine.activeSoundChannels
                            let snapshots = machine.activeStreamPlaybackSnapshots
                            guard snapshots.count == active.count, observer.rejectedControlCount == 0 else {
                                throw ResourceError.rejected("timed_stop_frame_live_audio_identity_unsupported")
                            }
                            do { return try observer.positions(for: snapshots) }
                            catch {
                                let encoder = JSONEncoder()
                                encoder.outputFormatting = [.sortedKeys]
                                var prior: [UInt64: Data] = [:]
                                let gains = try machine.soundCategoryGains(only: active)
                                for channel in active {
                                    prior[channel] = try encoder.encode(machine.researchActiveAudioSnapshots(
                                        excluding: active.subtracting([channel])))
                                }
                                let completions = observer.completedPlaybackCount
                                let events = observer.completedPlaybackEvents.count
                                let controls = observer.completedControlCount
                                _ = try observer.awaitStoppedCompletion(for: snapshots)
                                try observer.synchronizeControls(machine: &machine)
                                let remaining = machine.activeSoundChannels
                                let removed = active.subtracting(remaining)
                                let newEvents = Array(observer.completedPlaybackEvents.dropFirst(events))
                                guard !removed.isEmpty, remaining.isSubset(of: active),
                                      observer.completedPlaybackCount - completions == removed.count,
                                      newEvents.count == removed.count, observer.completedControlCount == controls,
                                      observer.rejectedControlCount == 0 else {
                                    throw ResourceError.rejected("timed_stop_frame_completion_unconfirmed")
                                }
                                let newGains = try machine.soundCategoryGains(only: remaining)
                                for channel in remaining {
                                    let current = try encoder.encode(machine.researchActiveAudioSnapshots(
                                        excluding: remaining.subtracting([channel])))
                                    guard current == prior[channel], newGains[channel] == gains[channel] else {
                                        throw ResourceError.rejected("timed_stop_frame_other_audio_changed")
                                    }
                                }
                                for channel in removed {
                                    guard let index = ScriptMachine.streamSaveChannelIndex(channel),
                                          let original = snapshots[channel], let step = original.step,
                                          newEvents.contains(where: { $0.channel == index && $0.playbackStartStep == step && $0.source == original.source }) else {
                                        throw ResourceError.rejected("timed_stop_frame_completion_identity_mismatch")
                                    }
                                }
                                researchTimedStopSamplingRecoveries += removed.count
                                return try observer.positions(for: machine.activeStreamPlaybackSnapshots)
                            }
                        }
                        var hostContinuationStart: Int?
                        var hostContinuationVisualTicks: Int64?
                        var researchTimedStopAudioHandoffBridges = 0
                        func setHostContinuationStart(preservingAudioHandoff: Bool = false) {
                            let trace = machine.traces
                            let zero = trace.last(where: { $0.action == "engine_field_98_write_candidate" })
                            let suffix = zero.map { z in trace.filter { $0.sequence >= z.sequence } } ?? []
                            let audioRequest = trace.last?.action == "sound_filter_request_candidate" ||
                                trace.last?.action == "sound_playback_request_candidate"
                            let snapshots = machine.activeStreamPlaybackSnapshots
                            let preserve = preservingAudioHandoff && researchZeroEventCallback &&
                                hostContinuationVisualTicks == machine.researchVisualTicks &&
                                hostContinuationStart != nil && zero != nil &&
                                zero!.sequence > hostContinuationStart! && researchTimedStopFreshZeroStep != zero!.sequence &&
                                trace.last?.sequence == machine.playbackStatus.steps && audioRequest &&
                                !suffix.isEmpty && zip(suffix, suffix.dropFirst()).allSatisfy { $1.sequence == $0.sequence + 1 } &&
                                !suffix.contains { $0.action == "draw_request_candidate" } &&
                                !machine.researchHasActiveTimers && machine.pendingResearchSkipTime == 0 &&
                                snapshots.count == machine.activeSoundChannels.count &&
                                liveAudioObserver?.rejectedControlCount == 0 &&
                                (try? liveAudioObserver?.positions(for: snapshots)) != nil
                            if preserve { researchTimedStopAudioHandoffBridges += 1 }
                            else { hostContinuationStart = machine.playbackStatus.steps }
                            hostContinuationVisualTicks = machine.researchVisualTicks
                        }
                        func runHost() throws {
                            while hostIterations < 50_000 {
                                hostIterations += 1
                                var resumedSoundPlayback = false
                                if let request = machine.soundFilterRequest {
                                    guard let observer = liveAudioObserver, let host = movieHost,
                                          ScriptMachine.streamSaveChannelIndex(request.channel) != nil,
                                          !machine.researchHasPendingSoundChanges(channel: request.channel) else {
                                        researchHostIssue = "live_audio_volume_update_control_unsupported"
                                        break
                                    }
                                    do {
                                        try observer.updateVolumeFilter(request, decoder: host)
                                        try machine.acknowledgeSoundFilter(request)
                                    } catch ResourceError.rejected(let issue) {
                                        researchHostIssue = issue
                                        break
                                    } catch {
                                        researchHostIssue = "live_audio_volume_update_failed"
                                        break
                                    }
                                    if machine.phase == .ready { setHostContinuationStart(preservingAudioHandoff: true); try machine.run(stepQuota: maximumSteps ?? 10_000) }
                                    continue
                                }
                                if researchWindowSkip, startedFromTitle, !researchWindowSkipDispatched,
                                   machine.phase == .waitingForEvent {
                                    let reason = machine.researchWindowSkipUnavailableReason ?? "available"
                                    researchWindowSkipAvailabilitySamples[reason, default: 0] += 1
                                }
                                if researchWindowAuto, startedFromTitle, !researchWindowAutoDispatched,
                                   machine.phase == .waitingForEvent {
                                    let reason = machine.researchWindowAutoUnavailableReason ?? "available"
                                    researchWindowAutoAvailabilitySamples[reason, default: 0] += 1
                                }
                                if let request = machine.soundSwapRequest {
                                    guard !researchSkipTime || machine.pendingResearchSkipTime == 0 else {
                                        researchHostIssue = "skip_time_pending_waitingForSoundSwap_unsupported"
                                        break
                                    }
                                    guard let liveAudioObserver else {
                                        researchHostIssue = "live_audio_swap_observer_unavailable"
                                        break
                                    }
                                    do {
                                        try liveAudioObserver.exchangeStreams(request, snapshots: machine.activeStreamPlaybackSnapshots)
                                        try machine.acknowledgeSoundSwap(request)
                                    } catch ResourceError.rejected(let issue) {
                                        researchHostIssue = issue
                                        break
                                    }
                                    if stopAfterAutoTimedSoundSwap {
                                        autoTimedSoundSwapCompleted = true
                                        if machine.phase == .ready {
                                            autoTimedSoundSwapContinuationStart = machine.playbackStatus.steps
                                            setHostContinuationStart(); try machine.run(stepQuota: maximumSteps ?? 10_000)
                                        }
                                        break
                                    }
                                    if machine.phase == .ready { setHostContinuationStart(); try machine.run(stepQuota: maximumSteps ?? 10_000) }
                                    continue
                                }
                                if machine.phase == .waitingForFrame {
                                    guard let maximum = researchDrawFrames, let ticks = researchDrawFrameTicks,
                                          researchDrawFramesAdvanced < maximum else {
                                        researchHostIssue = "draw_frame_scheduler_unsupported"
                                        break
                                    }
                                    do {
                                        if researchZeroEventCallback {
                                            guard let observer = liveAudioObserver, let available = budget, available >= ticks,
                                                  researchTimedStopRealtimeElapsed.count + researchRealtimeOrdinaryWaitElapsed.count + researchRealtimeDrawElapsed.count < (researchTimedRealtimeMaxFrames ?? 64),
                                                  let draw = machine.traces.last(where: { $0.action == "draw_request_candidate" }) else {
                                                throw ResourceError.rejected("draw_frame_realtime_budget_or_source_unsupported")
                                            }
                                            try observer.synchronizeControls(machine: &machine)
                                            let snapshots = machine.activeStreamPlaybackSnapshots
                                            let direct = machine.activeDirectPlaybackSnapshots
                                            guard snapshots.count + direct.count == machine.activeSoundChannels.count,
                                                  (direct.isEmpty || researchObserveDirectSound),
                                                  observer.directPlaybackIdentitiesMatch(direct), observer.rejectedControlCount == 0,
                                                  (try? observer.positions(for: snapshots)) != nil else {
                                                throw ResourceError.rejected("draw_frame_realtime_audio_identity_unsupported")
                                            }
                                            let previous = DispatchTime.now().uptimeNanoseconds
                                            Thread.sleep(forTimeInterval: Double(ticks) / 1000)
                                            let now = DispatchTime.now().uptimeNanoseconds
                                            let measured = (now - previous) / 1_000_000
                                            guard (1...1000).contains(measured), measured <= UInt64(available) else {
                                                throw ResourceError.rejected("draw_frame_realtime_outside_budget")
                                            }
                                            let elapsed = ScriptFrameClock.elapsedMilliseconds(
                                                current: UInt32(truncatingIfNeeded: now / 1_000_000),
                                                previous: UInt32(truncatingIfNeeded: previous / 1_000_000))
                                            guard elapsed <= available else { throw ResourceError.rejected("draw_frame_realtime_outside_budget") }
                                            try observer.synchronizeControls(machine: &machine)
                                            guard observer.rejectedControlCount == 0,
                                                  observer.directPlaybackIdentitiesMatch(machine.activeDirectPlaybackSnapshots),
                                                  (try? observer.positions(for: machine.activeStreamPlaybackSnapshots)) != nil else {
                                                throw ResourceError.rejected("draw_frame_realtime_audio_identity_unsupported")
                                            }
                                            try machine.advanceResearchDrawFrame(ticks: elapsed, allowObservedStreams: true,
                                                consumePendingSkipTime: true, allowObservedDirectSounds: researchObserveDirectSound)
                                            budget = available - elapsed
                                            researchRealtimeDrawElapsed.append(elapsed)
                                            researchLastHandledDrawStep = draw.sequence
                                        } else {
                                            try machine.advanceResearchDrawFrame(ticks: ticks)
                                        }
                                    } catch ResourceError.rejected(let issue) where issue.hasPrefix("draw_frame_") {
                                        researchHostIssue = issue
                                        break
                                    }
                                    researchDrawFramesAdvanced += 1
                                    if machine.phase == .ready { setHostContinuationStart(); try machine.run(stepQuota: maximumSteps ?? 10_000) }
                                    continue
                                }
                                if researchZeroWaitFollowthrough && machine.phase == .waitingForEvent &&
                                   machine.timedStopRequest == nil && machine.pendingResearchSkipTime > 0 &&
                                   machine.researchZeroWaitClockPending, let observer = liveAudioObserver,
                                   let ticks = researchDrawFrameTicks, let available = budget, available >= ticks {
                                    do {
                                        try observer.synchronizeControls(machine: &machine)
                                        guard let positions = try checkedResearchZeroAudioPositions() else {
                                            throw ResourceError.rejected("zero_clock_live_audio_unavailable")
                                        }
                                        let elapsed = try machine.consumeResearchWaitZeroClock(hostTicks: ticks,
                                            allowObservedStreams: true, allowUntimedEventFrame: true)
                                        try machine.advancePlacementClock(ticks: elapsed)
                                        budget = available - ticks
                                        researchZeroLiveAudioFrames += 1
                                        researchZeroLiveAudioPositions = positions
                                        if researchZeroEventCallback && pendingDispatch {
                                            var active = machine.activeSoundChannels
                                            var beforeAudio = machine.researchActiveAudioSnapshots
                                            var beforeGains = try machine.soundCategoryGains(only: active)
                                            let audioEncoder = JSONEncoder()
                                            audioEncoder.outputFormatting = [.sortedKeys]
                                            var perChannelAudio: [UInt64: Data] = [:]
                                            for channel in active {
                                                perChannelAudio[channel] = try audioEncoder.encode(machine.researchActiveAudioSnapshots(
                                                    excluding: active.subtracting([channel])))
                                            }
                                            researchZeroEventWaitLocation = machine.playbackStatus.currentLocation
                                            researchZeroEventCallbackLocation = machine.researchStopCallbackLocation
                                            machine.researchStopAtDrawBoundary = true
                                            try machine.dispatchStopCallback(pointer: pointer, buttonIndex: buttonIndex,
                                                buttonArray: buttonArray ?? "Button", elapsedTicks: 0)
                                            pendingDispatch = false
                                            pendingScopedDispatch = false
                                            while machine.phase == .ready && machine.researchStopCallbackRunning && researchZeroEventCallbackSteps < 512 {
                                                guard !machine.researchHasActiveTimers, machine.pendingResearchSkipTime == 0,
                                                      active == machine.activeSoundChannels,
                                                      beforeAudio == machine.researchActiveAudioSnapshots,
                                                      try machine.soundCategoryGains(only: active) == beforeGains,
                                                      observer.rejectedControlCount == 0,
                                                      (try? observer.positions(for: machine.activeStreamPlaybackSnapshots)) != nil else {
                                                    researchHostIssue = "zero_event_callback_state_changed"
                                                    break
                                                }
                                                _ = machine.step()
                                                researchZeroEventCallbackSteps += 1
                                            }
                                            if researchHostIssue == nil {
                                                if active != machine.activeSoundChannels || beforeAudio != machine.researchActiveAudioSnapshots ||
                                                    (try? machine.soundCategoryGains(only: active)) != beforeGains ||
                                                    machine.researchHasActiveTimers || machine.pendingResearchSkipTime != 0 ||
                                                    observer.rejectedControlCount != 0 ||
                                                    (try? observer.positions(for: machine.activeStreamPlaybackSnapshots)) == nil {
                                                    researchHostIssue = "zero_event_callback_state_changed"
                                                } else if machine.researchStopCallbackRunning {
                                                    researchHostIssue = "zero_event_callback_incomplete"
                                                } else {
                                                    researchZeroEventCallbackCompleted = true
                                                }
                                            }
                                            while researchHostIssue == nil && researchZeroEventCallbackCompleted &&
                                                  machine.phase == .ready && researchZeroEventContinuationSteps < 10_000 {
                                                guard !machine.researchHasActiveTimers, (0...60_000).contains(machine.pendingResearchSkipTime),
                                                      active == machine.activeSoundChannels,
                                                      beforeAudio == machine.researchActiveAudioSnapshots,
                                                      try machine.soundCategoryGains(only: active) == beforeGains,
                                                      observer.rejectedControlCount == 0,
                                                      observer.directPlaybackIdentitiesMatch(machine.activeDirectPlaybackSnapshots),
                                                      (try? observer.positions(for: machine.activeStreamPlaybackSnapshots)) != nil else {
                                                    researchHostIssue = "zero_event_continuation_state_changed"
                                                    break
                                                }
                                                let trace = machine.step()
                                                researchZeroEventContinuationSteps += 1
                                                let afterActive = machine.activeSoundChannels
                                                if researchObserveDirectSound, trace?.action == "direct_sound_playback_request_candidate",
                                                   machine.phase == .waitingForMedia, let channel = machine.soundPlaybackChannel,
                                                   let source = machine.soundPlaybackRequest, let host = movieHost {
                                                    let added = afterActive.subtracting(active)
                                                    let direct = machine.activeDirectPlaybackSnapshots[channel]
                                                    guard added == Set([channel]), active.isSubset(of: afterActive),
                                                          direct?.source == source, let step = direct?.step,
                                                          ScriptMachine.directSoundChannelIndex(channel) != nil,
                                                          try machine.soundCategoryGains(only: active) == beforeGains,
                                                          observer.rejectedControlCount == 0,
                                                          (try? observer.positions(for: machine.activeStreamPlaybackSnapshots)) != nil else {
                                                        researchHostIssue = "zero_event_direct_sound_identity_unsupported"
                                                        break
                                                    }
                                                    for existing in active {
                                                        let snapshot = try audioEncoder.encode(machine.researchActiveAudioSnapshots(
                                                            excluding: afterActive.subtracting([existing])))
                                                        guard snapshot == perChannelAudio[existing] else {
                                                            throw ResourceError.rejected("zero_event_direct_sound_other_stream_changed")
                                                        }
                                                    }
                                                    let duration = try observer.startDirect(channel: channel, source: source,
                                                                                           playbackStep: step, decoder: host)
                                                    try machine.acknowledgeSoundPlayback(durationMilliseconds: duration)
                                                    guard observer.directPlaybackIdentitiesMatch(machine.activeDirectPlaybackSnapshots) else {
                                                        researchHostIssue = "zero_event_direct_sound_identity_unsupported"
                                                        break
                                                    }
                                                    active = machine.activeSoundChannels
                                                    beforeAudio = machine.researchActiveAudioSnapshots
                                                    beforeGains = try machine.soundCategoryGains(only: active)
                                                    perChannelAudio[channel] = try audioEncoder.encode(machine.researchActiveAudioSnapshots(
                                                        excluding: active.subtracting([channel])))
                                                    continue
                                                }
                                                if researchObserveDirectSound, trace?.action == "sound_playback_request_candidate",
                                                   machine.phase == .waitingForMedia, machine.soundPlaybackIsStream,
                                                   !machine.soundPlaybackPreservesPosition, !machine.researchSoundPlaybackHasPendingSeek,
                                                   let channel = machine.soundPlaybackChannel, let source = machine.soundPlaybackRequest,
                                                   let host = movieHost {
                                                    let added = afterActive.subtracting(active)
                                                    let snapshot = machine.activeStreamPlaybackSnapshots[channel]
                                                    guard added == Set([channel]), active.isSubset(of: afterActive),
                                                          snapshot?.source == source, let step = snapshot?.step,
                                                          (-1...1024).contains(machine.soundPlaybackRepeatCount),
                                                          try machine.soundCategoryGains(only: active) == beforeGains,
                                                          observer.rejectedControlCount == 0,
                                                          observer.directPlaybackIdentitiesMatch(machine.activeDirectPlaybackSnapshots) else {
                                                        researchHostIssue = "zero_event_stream_handoff_identity_unsupported"
                                                        break
                                                    }
                                                    for existing in active {
                                                        let current = try audioEncoder.encode(machine.researchActiveAudioSnapshots(
                                                            excluding: afterActive.subtracting([existing])))
                                                        guard current == perChannelAudio[existing] else {
                                                            throw ResourceError.rejected("zero_event_stream_handoff_other_audio_changed")
                                                        }
                                                    }
                                                    guard let duration = try observer.start(channel: channel, source: source,
                                                        playbackStep: step, repeats: machine.soundPlaybackRepeatCount,
                                                        preservePosition: false, seek: nil, decoder: host) else {
                                                        throw ResourceError.rejected("zero_event_stream_handoff_start_failed")
                                                    }
                                                    try machine.acknowledgeSoundPlayback(durationMilliseconds: duration)
                                                    active = machine.activeSoundChannels
                                                    beforeAudio = machine.researchActiveAudioSnapshots
                                                    beforeGains = try machine.soundCategoryGains(only: active)
                                                    perChannelAudio[channel] = try audioEncoder.encode(machine.researchActiveAudioSnapshots(
                                                        excluding: active.subtracting([channel])))
                                                    continue
                                                }
                                                if researchObserveDirectSound, trace?.action == "sound_v_candidate", afterActive == active {
                                                    var changed: [UInt64] = []
                                                    for channel in active {
                                                        let snapshot = try audioEncoder.encode(machine.researchActiveAudioSnapshots(
                                                            excluding: active.subtracting([channel])))
                                                        if snapshot != perChannelAudio[channel] { changed.append(channel) }
                                                    }
                                                    if changed.isEmpty { continue }
                                                    guard changed.count == 1, let channel = changed.first,
                                                          ScriptMachine.streamSaveChannelIndex(channel) != nil,
                                                          machine.researchPendingSoundControl(channel: channel, pan: false) != nil,
                                                          try machine.soundCategoryGains(only: active) == beforeGains,
                                                          researchZeroEventVolumeHandoffs < 32 else {
                                                        researchHostIssue = "zero_event_volume_handoff_unsupported"
                                                        break
                                                    }
                                                    let directCompletionsBefore = observer.directCompletions
                                                    try observer.synchronizeControls(machine: &machine)
                                                    let refreshedActive = machine.activeSoundChannels
                                                    let removed = active.subtracting(refreshedActive)
                                                    guard refreshedActive.isSubset(of: active),
                                                          observer.rejectedControlCount == 0,
                                                          observer.directCompletions - directCompletionsBefore == removed.count,
                                                          removed.allSatisfy({ ScriptMachine.directSoundChannelIndex($0) != nil }),
                                                          observer.directPlaybackIdentitiesMatch(machine.activeDirectPlaybackSnapshots),
                                                          (try? observer.positions(for: machine.activeStreamPlaybackSnapshots)) != nil else {
                                                        researchHostIssue = "zero_event_volume_handoff_identity_unsupported"
                                                        break
                                                    }
                                                    let gains = try machine.soundCategoryGains(only: refreshedActive)
                                                    guard gains == beforeGains.filter({ refreshedActive.contains($0.key) }) else {
                                                        researchHostIssue = "zero_event_volume_handoff_gain_unsupported"
                                                        break
                                                    }
                                                    for existing in refreshedActive where existing != channel {
                                                        let snapshot = try audioEncoder.encode(machine.researchActiveAudioSnapshots(
                                                            excluding: refreshedActive.subtracting([existing])))
                                                        guard snapshot == perChannelAudio[existing] else {
                                                            throw ResourceError.rejected("zero_event_volume_handoff_other_stream_changed")
                                                        }
                                                    }
                                                    for removedChannel in removed { perChannelAudio.removeValue(forKey: removedChannel) }
                                                    active = refreshedActive
                                                    beforeAudio = machine.researchActiveAudioSnapshots
                                                    beforeGains = gains
                                                    perChannelAudio[channel] = try audioEncoder.encode(machine.researchActiveAudioSnapshots(
                                                        excluding: active.subtracting([channel])))
                                                    researchZeroEventVolumeHandoffs += 1
                                                    continue
                                                }
                                                if trace?.action == "sound_channel_reset_candidate", afterActive != active {
                                                    let removed = active.subtracting(afterActive)
                                                    guard removed.count == 1, afterActive.isSubset(of: active),
                                                          let channel = removed.first,
                                                          let index = ScriptMachine.streamSaveChannelIndex(channel),
                                                          researchZeroEventStreamResets.count < 32,
                                                          try machine.soundCategoryGains(only: afterActive) == beforeGains.filter({ afterActive.contains($0.key) }) else {
                                                        researchHostIssue = "zero_event_continuation_reset_identity_unsupported"
                                                        break
                                                    }
                                                    for remaining in afterActive {
                                                        let snapshot = try audioEncoder.encode(machine.researchActiveAudioSnapshots(
                                                            excluding: afterActive.subtracting([remaining])))
                                                        guard snapshot == perChannelAudio[remaining] else {
                                                            throw ResourceError.rejected("zero_event_continuation_reset_identity_unsupported")
                                                        }
                                                    }
                                                    observer.retainActiveChannels(afterActive)
                                                    perChannelAudio.removeValue(forKey: channel)
                                                    guard observer.rejectedControlCount == 0,
                                                          (try? observer.positions(for: machine.activeStreamPlaybackSnapshots)) != nil else {
                                                        researchHostIssue = "zero_event_continuation_reset_observer_unsupported"
                                                        break
                                                    }
                                                    researchZeroEventStreamResets.append(index)
                                                    active = afterActive
                                                    beforeAudio = machine.researchActiveAudioSnapshots
                                                    beforeGains = try machine.soundCategoryGains(only: active)
                                                }
                                            }
                                            if researchHostIssue == nil && researchZeroEventContinuationSteps > 0 {
                                                if machine.phase == .stopped {
                                                    researchHostIssue = machine.stopReason ?? "zero_event_continuation_stopped_unsupported"
                                                } else if active != machine.activeSoundChannels || beforeAudio != machine.researchActiveAudioSnapshots ||
                                                    (try? machine.soundCategoryGains(only: active)) != beforeGains ||
                                                    machine.researchHasActiveTimers ||
                                                    (machine.pendingResearchSkipTime != 0 && machine.phase != .waitingForFrame && machine.phase != .waitingForEvent) ||
                                                    observer.rejectedControlCount != 0 ||
                                                    !observer.directPlaybackIdentitiesMatch(machine.activeDirectPlaybackSnapshots) ||
                                                    (try? observer.positions(for: machine.activeStreamPlaybackSnapshots)) == nil {
                                                    researchHostIssue = "zero_event_continuation_state_changed"
                                                } else if machine.phase == .ready {
                                                    researchHostIssue = "zero_event_continuation_step_limit"
                                                } else if machine.phase != .waitingForEvent && machine.phase != .finished &&
                                                          machine.phase != .waitingForFrame &&
                                                          !(machine.phase == .waiting && active.isEmpty) {
                                                    researchHostIssue = "zero_event_continuation_\(machine.phase.rawValue)_unsupported"
                                                }
                                            }
                                        } else if !researchZeroEventCallback {
                                            researchHostIssue = "zero_event_callback_not_dispatched"
                                        }
                                    } catch ResourceError.rejected(let issue) {
                                        researchHostIssue = issue
                                    }
                                    if researchHostIssue == nil && researchZeroEventCallbackCompleted &&
                                       researchZeroEventContinuationSteps > 0 &&
                                       (machine.phase == .waitingForFrame ||
                                        (machine.phase == .waiting && machine.activeSoundChannels.isEmpty) ||
                                        (machine.phase == .waitingForEvent && !pendingDispatch &&
                                         subsequentButtonCursor < subsequentButtons.count && !machine.isResearchMessageTextWait &&
                                         researchZeroEventWaitLocation != nil && researchZeroEventCallbackLocation != nil &&
                                         machine.playbackStatus.currentLocation == researchZeroEventWaitLocation &&
                                         machine.researchStopCallbackLocation == researchZeroEventCallbackLocation)) {
                                        continue
                                    }
                                    break
                                }
                                let allowsPendingStreamHandoff = (researchSkipMediaHandoff || researchObserveDirectSound) &&
                                    machine.phase == .waitingForMedia && machine.soundPlaybackRequest != nil &&
                                    machine.soundPlaybackIsStream && movieHost != nil
                                if researchSkipTime && machine.pendingResearchSkipTime > 0 && machine.phase != .waiting &&
                                    !allowsPendingStreamHandoff {
                                    // Preserve the machine and pending request in the report.
                                    researchHostIssue = "skip_time_pending_\(machine.phase.rawValue)_unsupported"
                                    break
                                }
                                liveAudioObserver?.retainActiveChannels(machine.activeSoundChannels)
                                var deferredStreams: Set<UInt64> = []
                                if machine.phase == .waitingForMedia, machine.soundPlaybackIsStream,
                                   !machine.soundPlaybackPreservesPosition, let observer = liveAudioObserver,
                                   let request = machine.soundPlaybackRequest, let channel = machine.soundPlaybackChannel,
                                   let snapshot = machine.activeStreamPlaybackSnapshots[channel], snapshot.source == request,
                                   let playbackStep = snapshot.step,
                                   observer.hasSupersededStream(channel: channel, source: request, playbackStep: playbackStep) {
                                    deferredStreams.insert(channel)
                                }
                                do {
                                    try liveAudioObserver?.synchronizeControls(machine: &machine, excluding: deferredStreams)
                                } catch ResourceError.rejected(let issue) {
                                    researchHostIssue = issue
                                    break
                                }
                                if titleMenuTarget != nil && requireRouteReturn && routeStartedForMenu &&
                                    choiceCursor == storyChoices.count && machine.canStartFromTitle {
                                    routeTitleReachedBeforeMenu = true
                                }
                                if requireRouteReturn, machine.executedSteps - lastRouteProgressSteps >= 1_000_000 {
                                    lastRouteProgressSteps = machine.executedSteps
                                    let receipt = "route_steps=\(lastRouteProgressSteps) choices=\(choiceCursor) phase=\(machine.phase.rawValue)\n"
                                    FileHandle.standardError.write(Data(receipt.utf8))
                                }
                                if let request = machine.soundSeekRequest {
                                    guard let liveAudioObserver else { throw ResourceError.rejected("sound_seek_observation_unavailable") }
                                    try liveAudioObserver.seek(request, snapshots: machine.activeStreamPlaybackSnapshots)
                                    try machine.acknowledgeSoundSeek(request)
                                } else if let request = machine.soundPositionRequest {
                                    guard let liveAudioObserver,
                                          liveAudioObserver.allowsSourcePositionQuery(channel: request.channel),
                                          let index = ScriptMachine.streamSaveChannelIndex(request.channel),
                                          let position = try liveAudioObserver.positions(for: [request.channel:
                                              (source: request.source, step: request.playbackStep)])[index] else {
                                        throw ResourceError.rejected("sound_position_observation_unavailable")
                                    }
                                    try machine.acknowledgeSoundPosition(position, for: request)
                                } else if try machine.dispatchDueTimer() {
                                    // The callback runs before further host input or time advancement.
                                } else if let request = machine.moviePlaybackRequest, let movieHost {
                                    try machine.acknowledgeMoviePlayback(durationTicks: movieHost.decode(request))
                                } else if let request = machine.soundPlaybackRequest, movieHost != nil {
                                    let seek = (adoptSaveCandidate || observeLiveAudio) ? machine.takePendingPlaybackSeek() : nil
                                    let reuseLiveDecode = liveAudioObserver != nil && machine.soundPlaybackIsStream &&
                                        !machine.soundPlaybackPreservesPosition && seek == nil &&
                                        machine.soundPlaybackChannel.flatMap(ScriptMachine.streamSaveChannelIndex) != nil
                                    let observedDirectRequest = researchObserveDirectSound && !machine.soundPlaybackIsStream &&
                                        machine.soundPlaybackChannel.flatMap(ScriptMachine.directSoundChannelIndex) != nil
                                    if !reuseLiveDecode && !observedDirectRequest { try movieHost!.decodeSound(request, seekMilliseconds: seek) }
                                    var soundDuration: Int32?
                                    if let liveAudioObserver, let channel = machine.soundPlaybackChannel {
                                        do {
                                            if observedDirectRequest {
                                                guard seek == nil, let snapshot = machine.activeDirectPlaybackSnapshots[channel],
                                                      snapshot.source == request, let step = snapshot.step else {
                                                    throw ResourceError.rejected("live_direct_audio_request_identity_mismatch")
                                                }
                                                soundDuration = try liveAudioObserver.startDirect(channel: channel, source: request,
                                                    playbackStep: step, decoder: movieHost!)
                                            } else {
                                                soundDuration = try liveAudioObserver.start(channel: channel, source: request,
                                                    playbackStep: machine.activeStreamPlaybackSnapshots[channel]?.step,
                                                    repeats: machine.soundPlaybackRepeatCount,
                                                    preservePosition: machine.soundPlaybackPreservesPosition,
                                                    seek: seek, volumeFilter: researchAudibleVolumeFilter
                                                        ? machine.researchActiveStreamVolumeFilters[channel] : nil,
                                                    filterChainText: researchMutedFilterChain
                                                        ? machine.researchActiveStreamFilterChains[channel] : nil,
                                                    decoder: movieHost!)
                                                if reuseLiveDecode && soundDuration != nil { reusedStreamDecodeCount += 1 }
                                            }
                                        } catch ResourceError.rejected(let issue) {
                                            researchHostIssue = issue
                                            break
                                        }
                                    }
                                    if soundDuration == nil && (inspectUnrenderedBars || observeLiveAudio) && machine.soundPlaybackIsStream {
                                        soundDuration = try movieHost!.probeSoundDuration(request)
                                    }
                                    if let seek {
                                        FileHandle.standardError.write(Data("experimental_saved_stream_playback seek_ms=\(seek)\n".utf8))
                                    }
                                    let wasObservedStream = machine.soundPlaybackIsStream && liveAudioObserver != nil
                                    try machine.acknowledgeSoundPlayback(durationMilliseconds: soundDuration)
                                    resumedSoundPlayback = wasObservedStream
                                    if stopAfterAutoTimedMediaHandoff {
                                        autoTimedMediaHandoffCompleted = true
                                        if machine.phase == .ready {
                                            autoTimedMediaContinuationStart = machine.playbackStatus.steps
                                            setHostContinuationStart(); try machine.run(stepQuota: maximumSteps ?? 10_000)
                                        }
                                        break
                                    }
                                    if allowsPendingStreamHandoff && machine.pendingResearchSkipTime > 0 {
                                        researchSkipMediaHandoffs += 1
                                    }
                                    if machine.phase != .ready { continue }
                                } else if machine.phase == .waiting, let remaining = machine.clickWaitRemaining,
                                          remaining >= 0, let available = budget {
                                    let zeroLiveFramesBefore = researchZeroLiveAudioFrames
                                    let pendingSkipBeforeZero = machine.pendingResearchSkipTime
                                    var delta = min(available, remaining, machine.ticksUntilTimer ?? remaining)
                                    var waitTicks = delta
                                    if researchSkipTime && machine.researchZeroWaitClockPending && delta > 0 {
                                        guard let quantum = researchDrawFrameTicks else {
                                            researchHostIssue = "zero_clock_requires_explicit_frame_ticks"
                                            break
                                        }
                                        delta = min(delta, quantum)
                                        do {
                                            let positions = try checkedResearchZeroAudioPositions()
                                            waitTicks = try machine.consumeResearchWaitZeroClock(hostTicks: delta,
                                                allowObservedStreams: positions != nil)
                                            if let positions {
                                                researchZeroLiveAudioFrames += 1
                                                researchZeroLiveAudioPositions = positions
                                            }
                                        } catch ResourceError.rejected(let issue) where issue.hasPrefix("zero_clock_") {
                                            researchHostIssue = issue
                                            break
                                        }
                                    }
                                    let consumedObservedSkipFrame = researchZeroLiveAudioFrames > zeroLiveFramesBefore &&
                                        pendingSkipBeforeZero > 0 && waitTicks == pendingSkipBeforeZero
                                    if researchZeroLiveAudioFrames > 0 && waitTicks > 0 && !machine.activeSoundChannels.isEmpty &&
                                       !consumedObservedSkipFrame {
                                        guard researchZeroEventCallback, let quantum = researchTimedStopFrameTicks,
                                              let observer = liveAudioObserver, pendingSkipBeforeZero == 0,
                                              researchTimedStopRealtimeElapsed.count + researchRealtimeOrdinaryWaitElapsed.count + researchRealtimeDrawElapsed.count < (researchTimedRealtimeMaxFrames ?? 64),
                                              let anchor = researchLastHandledDrawStep ?? researchTimedStopFreshZeroStep,
                                              let last = machine.traces.last, last.sequence == machine.playbackStatus.steps else {
                                            researchHostIssue = "zero_live_audio_positive_frame_unsupported"
                                            break
                                        }
                                        let suffix = machine.traces.filter { $0.sequence >= anchor }
                                        guard suffix.first?.sequence == anchor, zip(suffix, suffix.dropFirst()).allSatisfy({ $1.sequence == $0.sequence + 1 }),
                                              !suffix.contains(where: { $0.action == "draw_request_candidate" && $0.sequence != researchLastHandledDrawStep }) else {
                                            researchHostIssue = "realtime_ordinary_wait_clock_history_unsupported"
                                            break
                                        }
                                        do {
                                            try machine.validateResearchChoiceWaitClock()
                                            try observer.synchronizeControls(machine: &machine)
                                            let snapshots = machine.activeStreamPlaybackSnapshots
                                            guard snapshots.count == machine.activeSoundChannels.count, observer.rejectedControlCount == 0,
                                                  (try? observer.positions(for: snapshots)) != nil else {
                                                throw ResourceError.rejected("realtime_ordinary_wait_audio_identity_unsupported")
                                            }
                                            let previous = DispatchTime.now().uptimeNanoseconds
                                            Thread.sleep(forTimeInterval: Double(min(quantum, remaining)) / 1000)
                                            let now = DispatchTime.now().uptimeNanoseconds
                                            let measured = (now - previous) / 1_000_000
                                            guard (1...1000).contains(measured), measured <= UInt64(available) else {
                                                throw ResourceError.rejected("realtime_ordinary_wait_outside_budget")
                                            }
                                            delta = ScriptFrameClock.elapsedMilliseconds(
                                                current: UInt32(truncatingIfNeeded: now / 1_000_000),
                                                previous: UInt32(truncatingIfNeeded: previous / 1_000_000))
                                            guard delta <= available else { throw ResourceError.rejected("realtime_ordinary_wait_outside_budget") }
                                            try observer.synchronizeControls(machine: &machine)
                                            guard observer.rejectedControlCount == 0,
                                                  (try? observer.positions(for: machine.activeStreamPlaybackSnapshots)) != nil else {
                                                throw ResourceError.rejected("realtime_ordinary_wait_audio_identity_unsupported")
                                            }
                                            waitTicks = delta
                                            researchRealtimeOrdinaryWaitElapsed.append(delta)
                                        } catch ResourceError.rejected(let issue) {
                                            researchHostIssue = issue
                                            break
                                        }
                                    }
                                    let effectiveDelta: Int32
                                    do {
                                        effectiveDelta = try machine.consumeResearchSkipTime(hostTicks: waitTicks)
                                    } catch ResourceError.rejected(let issue) where researchSkipTime && issue.hasPrefix("skip_time_") {
                                        researchHostIssue = issue
                                        break
                                    }
                                    try machine.advanceClickWait(ticks: effectiveDelta)
                                    try machine.advancePlacementClock(ticks: effectiveDelta)
                                    budget = available-delta
                                    if researchZeroLiveAudioFrames > zeroLiveFramesBefore {
                                        guard researchZeroWaitFollowthrough, consumedObservedSkipFrame,
                                              machine.phase == .ready, let observer = liveAudioObserver else {
                                            researchHostIssue = "zero_live_audio_followup_unsupported"
                                            break
                                        }
                                        let active = machine.activeSoundChannels
                                        let originalAudio = machine.researchActiveAudioSnapshots
                                        let originalGains = try machine.soundCategoryGains(only: active)
                                        while machine.phase == .ready && researchZeroWaitFollowthroughSteps < 512 {
                                            guard !machine.researchHasActiveTimers, machine.pendingResearchSkipTime == 0,
                                                  active == machine.activeSoundChannels,
                                                  originalAudio == machine.researchActiveAudioSnapshots,
                                                  try machine.soundCategoryGains(only: active) == originalGains,
                                                  observer.rejectedControlCount == 0,
                                                  (try? observer.positions(for: machine.activeStreamPlaybackSnapshots)) != nil else {
                                                researchHostIssue = "zero_wait_followthrough_state_changed"
                                                break
                                            }
                                            _ = machine.step()
                                            researchZeroWaitFollowthroughSteps += 1
                                        }
                                        if researchHostIssue == nil {
                                            if active != machine.activeSoundChannels || originalAudio != machine.researchActiveAudioSnapshots ||
                                                (try? machine.soundCategoryGains(only: active)) != originalGains ||
                                                machine.researchHasActiveTimers || machine.pendingResearchSkipTime != 0 ||
                                                observer.rejectedControlCount != 0 ||
                                                (try? observer.positions(for: machine.activeStreamPlaybackSnapshots)) == nil {
                                                researchHostIssue = "zero_wait_followthrough_state_changed"
                                            } else if machine.phase == .ready {
                                                researchHostIssue = "zero_wait_followthrough_step_limit"
                                            } else if machine.phase != .waitingForEvent && machine.phase != .finished {
                                                researchHostIssue = "zero_wait_followthrough_\(machine.phase.rawValue)_unsupported"
                                            }
                                        }
                                        break
                                    }
                                    if machine.phase != .ready && delta > 0 { continue }
                                } else if machine.phase == .waitingForEvent, let request = machine.timedStopRequest,
                                          (request.duration >= 0 || (researchTimedStopFrameTicks != nil &&
                                            (!researchSkipTime || researchWindowSkipDispatched || researchZeroEventCallback))),
                                          let available = budget, available > 0 {
                                    if researchStopAtCenterText, try machine.commitTimedCenterText() {
                                        researchCenterTextStopReached = true
                                        break
                                    }
                                    if let quantum = researchTimedStopFrameTicks, !researchSkipTime || researchWindowSkipDispatched || researchZeroEventCallback {
                                        guard available >= quantum else { break }
                                        let realtimeEventFrame = researchZeroEventCallback && !researchWindowSkip
                                        let recentTrace = machine.traces
                                        let lastZero = recentTrace.last(where: { $0.action == "engine_field_98_write_candidate" })
                                        let freshTimedZero: Bool = {
                                            guard realtimeEventFrame, let start = hostContinuationStart, let zero = lastZero,
                                                  researchTimedStopFreshZeroStep != zero.sequence, zero.sequence > start, let last = recentTrace.last,
                                                  last.sequence == machine.playbackStatus.steps else { return false }
                                            let suffix = recentTrace.filter { $0.sequence >= zero.sequence }
                                            return !suffix.isEmpty && zip(suffix, suffix.dropFirst()).allSatisfy { $1.sequence == $0.sequence + 1 } &&
                                                !suffix.contains { $0.action == "draw_request_candidate" }
                                        }()
                                        let zeroPending = researchSkipTime && (machine.researchZeroWaitClockPending || freshTimedZero)
                                        var positions: [Int32: Int32]?
                                        var delta = quantum
                                        do {
                                            if zeroPending && !realtimeEventFrame {
                                                positions = try checkedResearchZeroAudioPositions()
                                            } else if realtimeEventFrame {
                                                guard researchTimedStopRealtimeElapsed.count + researchRealtimeOrdinaryWaitElapsed.count + researchRealtimeDrawElapsed.count < (researchTimedRealtimeMaxFrames ?? 64) else {
                                                    throw ResourceError.rejected("timed_stop_frame_realtime_frame_limit")
                                                }
                                                guard let observer = liveAudioObserver else {
                                                    throw ResourceError.rejected("timed_stop_frame_live_audio_unavailable")
                                                }
                                                try observer.synchronizeControls(machine: &machine)
                                                positions = try checkedRealtimeStreamPositions(observer)
                                                let previous = DispatchTime.now().uptimeNanoseconds
                                                Thread.sleep(forTimeInterval: Double(quantum) / 1000)
                                                let now = DispatchTime.now().uptimeNanoseconds
                                                let measured = (now - previous) / 1_000_000
                                                guard (1...1000).contains(measured), measured <= UInt64(available) else {
                                                    throw ResourceError.rejected("timed_stop_frame_realtime_outside_budget")
                                                }
                                                delta = ScriptFrameClock.elapsedMilliseconds(
                                                    current: UInt32(truncatingIfNeeded: now / 1_000_000),
                                                    previous: UInt32(truncatingIfNeeded: previous / 1_000_000))
                                                guard delta <= available else { throw ResourceError.rejected("timed_stop_frame_realtime_outside_budget") }
                                                try observer.synchronizeControls(machine: &machine)
                                                positions = try checkedRealtimeStreamPositions(observer)
                                            }
                                            try machine.validateResearchTimedStopFrame(allowZeroClock: zeroPending,
                                                allowObservedStreams: positions != nil, allowRealtimeObservedStreams: realtimeEventFrame,
                                                allowFreshTimedWait: freshTimedZero)
                                        }
                                        catch ResourceError.rejected(let issue) where issue.hasPrefix("timed_stop_frame_") || issue.hasPrefix("zero_clock_") {
                                            researchHostIssue = issue
                                            break
                                        }
                                        let elapsed = zeroPending ? try machine.consumeResearchWaitZeroClock(hostTicks: delta,
                                            allowObservedStreams: positions != nil, allowFreshTimedWait: freshTimedZero) : delta
                                        if freshTimedZero {
                                            researchTimedStopFreshZeroStart = hostContinuationStart
                                            researchTimedStopFreshZeroStep = lastZero?.sequence
                                        }
                                        if let positions, zeroPending {
                                            researchZeroLiveAudioFrames += 1
                                            researchZeroLiveAudioPositions = positions
                                        }
                                        try machine.advanceTimedStop(ticks: elapsed)
                                        try machine.advancePlacementClock(ticks: elapsed)
                                        budget = available - delta
                                        researchTimedStopFrames += 1
                                        if realtimeEventFrame { researchTimedStopRealtimeElapsed.append(elapsed) }
                                        let audioEncoder = JSONEncoder()
                                        audioEncoder.outputFormatting = .sortedKeys
                                        let audioBeforeCallback = positions == nil ? nil : machine.researchActiveAudioSnapshots
                                        let gainsBeforeCallback = positions == nil ? nil : try machine.soundCategoryGains(only: machine.activeSoundChannels)
                                        let activeBeforeCallback = machine.activeSoundChannels
                                        let snapshotsBeforeCallback = machine.activeStreamPlaybackSnapshots
                                        let completedBeforeCallback = liveAudioObserver?.completedPlaybackCount ?? 0
                                        let eventsBeforeCallback = liveAudioObserver?.completedPlaybackEvents.count ?? 0
                                        let controlsBeforeCallback = liveAudioObserver?.completedControlCount ?? 0
                                        var audioByChannel: [UInt64: Data] = [:]
                                        if realtimeEventFrame {
                                            for channel in activeBeforeCallback {
                                                audioByChannel[channel] = try audioEncoder.encode(machine.researchActiveAudioSnapshots(
                                                    excluding: activeBeforeCallback.subtracting([channel])))
                                            }
                                        }
                                        if machine.phase == .waitingForEvent {
                                            try machine.dispatchStopCallback(pointer: pointer,
                                                buttonIndex: pendingDispatch ? buttonIndex : nil,
                                                buttonArray: buttonArray ?? "Button", elapsedTicks: elapsed)
                                            pendingDispatch = false
                                        }
                                        if positions != nil {
                                            var callbackSteps = 0
                                            while machine.phase == .ready && machine.researchStopCallbackRunning && callbackSteps < 512 {
                                                _ = machine.step()
                                                callbackSteps += 1
                                            }
                                            researchTimedStopZeroCallbackCompleted = !machine.researchStopCallbackRunning
                                            if realtimeEventFrame {
                                                guard let observer = liveAudioObserver else {
                                                    researchTimedStopRealtimeIssue = "observer_missing"
                                                    researchHostIssue = "realtime_event_callback_state_changed"
                                                    break
                                                }
                                                if machine.researchStopCallbackRunning { researchTimedStopRealtimeIssue = "callback_running" }
                                                else if machine.researchHasActiveTimers { researchTimedStopRealtimeIssue = "timer_active" }
                                                else if machine.pendingResearchSkipTime != 0 { researchTimedStopRealtimeIssue = "skip_pending" }
                                                else if audioBeforeCallback != machine.researchActiveAudioSnapshots { researchTimedStopRealtimeIssue = "audio_state_changed" }
                                                else if gainsBeforeCallback != (try? machine.soundCategoryGains(only: machine.activeSoundChannels)) { researchTimedStopRealtimeIssue = "audio_gain_changed" }
                                                else if observer.rejectedControlCount != 0 { researchTimedStopRealtimeIssue = "audio_control_rejected" }
                                                else if (try? observer.positions(for: machine.activeStreamPlaybackSnapshots)) == nil {
                                                    do {
                                                        _ = try observer.awaitStoppedCompletion(for: snapshotsBeforeCallback)
                                                        try observer.synchronizeControls(machine: &machine)
                                                        let remaining = machine.activeSoundChannels
                                                        let removed = activeBeforeCallback.subtracting(remaining)
                                                        let events = Array(observer.completedPlaybackEvents.dropFirst(eventsBeforeCallback))
                                                        guard !removed.isEmpty, remaining.isSubset(of: activeBeforeCallback),
                                                              observer.completedPlaybackCount - completedBeforeCallback == removed.count,
                                                              events.count == removed.count,
                                                              observer.completedControlCount == controlsBeforeCallback,
                                                              observer.rejectedControlCount == 0 else {
                                                            throw ResourceError.rejected("realtime_completion_not_confirmed")
                                                        }
                                                        let gains = try machine.soundCategoryGains(only: remaining)
                                                        for channel in remaining {
                                                            let snapshot = try audioEncoder.encode(machine.researchActiveAudioSnapshots(
                                                                excluding: remaining.subtracting([channel])))
                                                            guard snapshot == audioByChannel[channel], gains[channel] == gainsBeforeCallback?[channel] else {
                                                                throw ResourceError.rejected("realtime_completion_other_stream_changed")
                                                            }
                                                        }
                                                        for channel in removed {
                                                            guard let index = ScriptMachine.streamSaveChannelIndex(channel),
                                                                  let prior = snapshotsBeforeCallback[channel], let step = prior.step,
                                                                  events.contains(where: { $0.channel == index && $0.playbackStartStep == step && $0.source == prior.source }) else {
                                                                throw ResourceError.rejected("realtime_completion_identity_mismatch")
                                                            }
                                                        }
                                                        guard (try? observer.positions(for: machine.activeStreamPlaybackSnapshots)) != nil else {
                                                            throw ResourceError.rejected("realtime_completion_remaining_position_unavailable")
                                                        }
                                                        researchTimedStopCompletionRecoveries += removed.count
                                                    } catch {
                                                        researchTimedStopRealtimeIssue = "audio_position_recovery_failed"
                                                    }
                                                }
                                                if researchTimedStopRealtimeIssue != nil {
                                                    researchHostIssue = "realtime_event_callback_state_changed"
                                                    break
                                                }
                                                if machine.phase == .waitingForEvent && machine.timedStopRequest != nil { continue }
                                                if machine.phase == .ready {
                                                    setHostContinuationStart()
                                                    try machine.run(stepQuota: maximumSteps ?? 10_000)
                                                    continue
                                                }
                                                researchHostIssue = "realtime_event_callback_\(machine.phase.rawValue)_unsupported"
                                                break
                                            }
                                            researchHostIssue = machine.phase == .stopped ? (machine.stopReason ?? "zero_live_audio_callback_stopped") :
                                                (machine.researchStopCallbackRunning && machine.phase == .ready
                                                    ? "zero_live_audio_callback_step_limit" : (realtimeEventFrame
                                                        ? "realtime_event_callback_followup_unsupported" : "zero_live_audio_followup_unsupported"))
                                            if researchZeroCallbackFollowthrough, researchTimedStopZeroCallbackCompleted == true,
                                               machine.phase == .ready, let observer = liveAudioObserver {
                                                var initialAudio = machine.researchActiveAudioSnapshots
                                                var initialGains = try machine.soundCategoryGains(only: machine.activeSoundChannels)
                                                var perChannelAudio: [UInt64: Data] = [:]
                                                for channel in machine.activeSoundChannels {
                                                    perChannelAudio[channel] = try audioEncoder.encode(machine.researchActiveAudioSnapshots(
                                                        excluding: machine.activeSoundChannels.subtracting([channel])))
                                                }
                                                var issue: String? = initialAudio == audioBeforeCallback && initialGains == gainsBeforeCallback
                                                    ? nil : "zero_followthrough_audio_change_unsupported"
                                                researchFollowthroughInitialPlayMode = machine.researchMessageWaitPlayMode
                                                let segmentDeadline = ContinuousClock.now.advanced(by: .seconds(researchFollowthroughMaximumSeconds ?? 120))
                                                let maximumDrawFollowthroughSteps = researchFollowthroughMaximumSteps ?? 6_000_000
                                                func normalizedAudioControl(_ data: Data, pan: Bool) throws -> Data {
                                                    guard var items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], items.count == 1 else {
                                                        throw ResourceError.rejected("stream_control_snapshot_invalid")
                                                    }
                                                    let keys = pan ? ["panTarget", "panDuration", "panDelay", "panChangePending", "panAcknowledgementPending"] :
                                                        ["volumeTarget", "volumeDuration", "volumeDelay", "volumeChangePending", "volumeAcknowledgementPending"]
                                                    for key in keys { items[0].removeValue(forKey: key) }
                                                    return try JSONSerialization.data(withJSONObject: items, options: [.sortedKeys])
                                                }
                                                func normalizedAudioLoop(_ data: Data) throws -> Data {
                                                    guard var items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], items.count == 1 else {
                                                        throw ResourceError.rejected("stream_playback_snapshot_invalid")
                                                    }
                                                    items[0].removeValue(forKey: "loopRequest")
                                                    return try JSONSerialization.data(withJSONObject: items, options: [.sortedKeys])
                                                }
                                                struct ControlState: Decodable {
                                                    let volumeTarget: Int32?
                                                    let volumeDuration: Int32?
                                                    let volumeDelay: Int32?
                                                    let volumeChangePending: Bool
                                                    let volumeAcknowledgementPending: Bool
                                                    let panTarget: Int32?
                                                    let panDuration: Int32?
                                                    let panDelay: Int32?
                                                    let panChangePending: Bool
                                                    let panAcknowledgementPending: Bool
                                                }
                                                func checkedControlCompletions(channels: Set<UInt64>, expectedCount: Int) throws -> ([HeadlessReplayBudget.ResearchControlCompletion], [UInt64: Data]) {
                                                    var accepted: [HeadlessReplayBudget.ResearchControlCompletion] = []
                                                    var updatedChannels: [UInt64: Data] = [:]
                                                    for channel in channels {
                                                        guard let previous = perChannelAudio[channel],
                                                              let index = ScriptMachine.streamSaveChannelIndex(channel) else {
                                                            throw ResourceError.rejected("control_completion_snapshot_unavailable")
                                                        }
                                                        let updated = try audioEncoder.encode(machine.researchActiveAudioSnapshots(
                                                            excluding: machine.activeSoundChannels.subtracting([channel])))
                                                        updatedChannels[channel] = updated
                                                        if previous == updated { continue }
                                                        let normalizedBefore = try normalizedAudioControl(normalizedAudioControl(previous, pan: false), pan: true)
                                                        let normalizedAfter = try normalizedAudioControl(normalizedAudioControl(updated, pan: false), pan: true)
                                                        guard normalizedBefore == normalizedAfter,
                                                              let prior = try JSONDecoder().decode([ControlState].self, from: previous).first,
                                                              let current = try JSONDecoder().decode([ControlState].self, from: updated).first else {
                                                            throw ResourceError.rejected("control_completion_other_state_changed")
                                                        }
                                                        if prior.volumeDuration != current.volumeDuration || prior.volumeDelay != current.volumeDelay ||
                                                            prior.volumeAcknowledgementPending != current.volumeAcknowledgementPending || prior.volumeChangePending != current.volumeChangePending {
                                                            guard prior.volumeTarget == current.volumeTarget, prior.volumeAcknowledgementPending,
                                                                  !prior.volumeChangePending, !current.volumeAcknowledgementPending,
                                                                  !current.volumeChangePending, current.volumeDuration == 0, current.volumeDelay == 0 else {
                                                                throw ResourceError.rejected("volume_completion_transition_unmatched")
                                                            }
                                                            accepted.append(.init(channel: index, kind: "volume"))
                                                        } else if prior.volumeTarget != current.volumeTarget {
                                                            throw ResourceError.rejected("volume_completion_target_changed")
                                                        }
                                                        if prior.panDuration != current.panDuration || prior.panDelay != current.panDelay ||
                                                            prior.panAcknowledgementPending != current.panAcknowledgementPending || prior.panChangePending != current.panChangePending {
                                                            guard prior.panTarget == current.panTarget, prior.panAcknowledgementPending,
                                                                  !prior.panChangePending, !current.panAcknowledgementPending,
                                                                  !current.panChangePending, current.panDuration == 0, current.panDelay == 0 else {
                                                                throw ResourceError.rejected("pan_completion_transition_unmatched")
                                                            }
                                                            accepted.append(.init(channel: index, kind: "pan"))
                                                        } else if prior.panTarget != current.panTarget {
                                                            throw ResourceError.rejected("pan_completion_target_changed")
                                                        }
                                                    }
                                                    guard accepted.count == expectedCount,
                                                          researchStreamControlCompletions.count + accepted.count <= 4096 else {
                                                        throw ResourceError.rejected("control_completion_count_mismatch")
                                                    }
                                                    return (accepted, updatedChannels)
                                                }
                                                func acceptObservedCompletions(active: Set<UInt64>, completedBefore: Int) throws {
                                                    let remaining = machine.activeSoundChannels
                                                    let removed = active.subtracting(remaining)
                                                    guard !removed.isEmpty, remaining.isSubset(of: active),
                                                          observer.completedPlaybackCount - completedBefore == removed.count,
                                                          observer.rejectedControlCount == 0,
                                                          researchStreamNaturalCompletions.count + removed.count <= 2048 else {
                                                        throw ResourceError.rejected("completion_not_confirmed_or_other_state_changed")
                                                    }
                                                    let remainingGains = try machine.soundCategoryGains(only: remaining)
                                                    for channel in remaining {
                                                        let current = try audioEncoder.encode(machine.researchActiveAudioSnapshots(
                                                            excluding: remaining.subtracting([channel])))
                                                        guard current == perChannelAudio[channel], remainingGains[channel] == initialGains[channel] else {
                                                            throw ResourceError.rejected("completion_other_audio_changed")
                                                        }
                                                    }
                                                    for channel in removed.sorted() {
                                                        guard let index = ScriptMachine.streamSaveChannelIndex(channel) else {
                                                            throw ResourceError.rejected("completion_channel_invalid")
                                                        }
                                                        researchStreamNaturalCompletions.append(index)
                                                        perChannelAudio.removeValue(forKey: channel)
                                                    }
                                                    initialAudio = machine.researchActiveAudioSnapshots
                                                    initialGains = remainingGains
                                                    _ = try observer.positions(for: machine.activeStreamPlaybackSnapshots)
                                                }
                                                func recoverObservedCompletions(active: Set<UInt64>, snapshots: [UInt64: (source: ScriptLocation?, step: Int?)]) throws {
                                                    let completedBefore = observer.completedPlaybackCount
                                                    let controlsBefore = observer.completedControlCount
                                                    if try observer.awaitStoppedCompletion(for: snapshots) { researchStreamCompletionWaits += 1 }
                                                    try observer.synchronizeControls(machine: &machine)
                                                    let remaining = machine.activeSoundChannels
                                                    guard remaining.isSubset(of: active), observer.rejectedControlCount == 0 else {
                                                        throw ResourceError.rejected("completion_recovery_identity_mismatch")
                                                    }
                                                    let (accepted, updatedChannels) = try checkedControlCompletions(
                                                        channels: remaining, expectedCount: observer.completedControlCount - controlsBefore)
                                                    for (channel, snapshot) in updatedChannels { perChannelAudio[channel] = snapshot }
                                                    try acceptObservedCompletions(active: active, completedBefore: completedBefore)
                                                    researchStreamControlCompletions.append(contentsOf: accepted)
                                                    researchStreamRecoveryControlCompletions += accepted.count
                                                }
                                                func advanceObservedSegment(prefix: String, limit: Int) throws -> (Int, String?) {
                                                    var steps = 0
                                                    while machine.phase == .ready && steps < limit {
                                                        guard ContinuousClock.now < segmentDeadline else { return (steps, "\(prefix)_time_limit") }
                                                        let active = machine.activeSoundChannels
                                                        let snapshots = machine.activeStreamPlaybackSnapshots
                                                        guard snapshots.count == active.count,
                                                              observer.rejectedControlCount == 0 else {
                                                            return (steps, "\(prefix)_audio_identity_unsupported")
                                                        }
                                                        if (try? observer.positions(for: snapshots)) == nil {
                                                            do { try recoverObservedCompletions(active: active, snapshots: snapshots) }
                                                            catch {
                                                                researchStreamCompletionIssue = String(describing: error)
                                                                return (steps, "\(prefix)_audio_completion_unsupported")
                                                            }
                                                            continue
                                                        }
                                                        if machine.researchZeroWaitClockPending { researchZeroPendingScriptSteps += 1 }
                                                        if machine.pendingResearchSkipTime > 0 { researchSkipPendingScriptSteps += 1 }
                                                        let modeBefore = machine.researchMessageWaitPlayMode
                                                        let trace = machine.step()
                                                        steps += 1
                                                        let modeAfter = machine.researchMessageWaitPlayMode
                                                        if modeBefore != modeAfter, let trace {
                                                            if researchFollowthroughPlayModeChanges.count < 64 {
                                                                researchFollowthroughPlayModeChanges.append(.init(step: trace.sequence,
                                                                    before: modeBefore, after: modeAfter, location: trace.location))
                                                            } else { researchFollowthroughPlayModeChangesTruncated = true }
                                                        }
                                                        let afterActive = machine.activeSoundChannels
                                                        let afterAudio = machine.researchActiveAudioSnapshots
                                                        let afterGains = try machine.soundCategoryGains(only: afterActive)
                                                        if afterAudio != initialAudio || afterGains != initialGains ||
                                                            (trace?.action == "sound_playback_request_candidate" &&
                                                             machine.phase == .waitingForMedia && machine.soundPlaybackPreservesPosition) {
                                                            guard !machine.researchZeroWaitClockPending else {
                                                                return (steps, "\(prefix)_pending_zero_audio_change_unsupported")
                                                            }
                                                            guard machine.pendingResearchSkipTime == 0 else {
                                                                return (steps, "\(prefix)_pending_skip_audio_change_unsupported")
                                                            }
                                                            let removed = active.subtracting(afterActive)
                                                            let added = afterActive.subtracting(active)
                                                            if trace?.action == "sound_playback_request_candidate", machine.phase == .waitingForMedia,
                                                               machine.soundPlaybackIsStream, machine.soundPlaybackPreservesPosition,
                                                               !machine.researchSoundPlaybackHasPendingSeek, removed.isEmpty, added.isEmpty,
                                                               researchStreamReassertHandoffs.count < 2048,
                                                               let channel = machine.soundPlaybackChannel, active.contains(channel),
                                                               let index = ScriptMachine.streamSaveChannelIndex(channel),
                                                               let request = machine.soundPlaybackRequest, let host = movieHost,
                                                               let previous = snapshots[channel], previous.source == request, previous.step != nil,
                                                               machine.activeStreamPlaybackSnapshots[channel]?.source == request,
                                                               machine.activeStreamPlaybackSnapshots[channel]?.step == previous.step,
                                                               [-1, 0].contains(machine.soundPlaybackRepeatCount), afterGains == initialGains {
                                                                let current = try audioEncoder.encode(machine.researchActiveAudioSnapshots(
                                                                    excluding: active.subtracting([channel])))
                                                                if let prior = perChannelAudio[channel],
                                                                   try normalizedAudioLoop(prior) == normalizedAudioLoop(current) {
                                                                    for existing in active where existing != channel {
                                                                        let unchanged = try audioEncoder.encode(machine.researchActiveAudioSnapshots(
                                                                            excluding: active.subtracting([existing])))
                                                                        guard unchanged == perChannelAudio[existing] else {
                                                                            return (steps, "\(prefix)_audio_change_unsupported")
                                                                        }
                                                                    }
                                                                    do {
                                                                        guard let before = try observer.positions(for: [channel: previous])[index] else {
                                                                            throw ResourceError.rejected("stream_reassert_position_unavailable")
                                                                        }
                                                                        let repeats = machine.soundPlaybackRepeatCount
                                                                        let controlsBefore = observer.completedControlCount
                                                                        try observer.start(channel: channel, source: request, playbackStep: previous.step,
                                                                            repeats: repeats, preservePosition: true, seek: nil, decoder: host)
                                                                        try machine.acknowledgeSoundPlayback()
                                                                        perChannelAudio[channel] = current
                                                                        try observer.synchronizeControls(machine: &machine)
                                                                        guard machine.phase == .ready, observer.rejectedControlCount == 0,
                                                                              machine.activeSoundChannels == active,
                                                                              let after = try observer.positions(for: [channel: previous])[index],
                                                                              (try? observer.positions(for: machine.activeStreamPlaybackSnapshots)) != nil,
                                                                              try machine.soundCategoryGains(only: active) == initialGains else {
                                                                            throw ResourceError.rejected("stream_reassert_identity_mismatch")
                                                                        }
                                                                        let (accepted, updatedChannels) = try checkedControlCompletions(
                                                                            channels: active, expectedCount: observer.completedControlCount - controlsBefore)
                                                                        for (existing, updated) in updatedChannels { perChannelAudio[existing] = updated }
                                                                        researchStreamControlCompletions.append(contentsOf: accepted)
                                                                        researchStreamReassertControlCompletions += accepted.count
                                                                        initialAudio = machine.researchActiveAudioSnapshots
                                                                        researchStreamReassertHandoffs.append(.init(channel: index, repeats: repeats,
                                                                            positionBefore: before, positionAfter: after))
                                                                        continue
                                                                    } catch {
                                                                        researchStreamPlaybackHandoffIssue = String(describing: error)
                                                                        return (steps, "\(prefix)_stream_reassert_handoff_unsupported")
                                                                    }
                                                                }
                                                            }
                                                            let isVolume = trace?.action == "sound_v_candidate"
                                                            let isPan = trace?.action == "sound_pan_candidate"
                                                            if (isVolume || isPan), removed.isEmpty, added.isEmpty,
                                                               afterGains == initialGains, researchStreamControlHandoffs.count < 8192 {
                                                                var changed: [(UInt64, Data)] = []
                                                                for channel in active {
                                                                    let current = try audioEncoder.encode(machine.researchActiveAudioSnapshots(
                                                                        excluding: afterActive.subtracting([channel])))
                                                                    if current != perChannelAudio[channel] { changed.append((channel, current)) }
                                                                }
                                                                if changed.count == 1, let (channel, current) = changed.first,
                                                                   let previous = perChannelAudio[channel],
                                                                   let index = ScriptMachine.streamSaveChannelIndex(channel),
                                                                   let control = machine.researchPendingSoundControl(channel: channel, pan: isPan),
                                                                   try normalizedAudioControl(previous, pan: isPan) == normalizedAudioControl(current, pan: isPan) {
                                                                    do {
                                                                        let completedBefore = observer.completedControlCount
                                                                        try observer.synchronizeControls(machine: &machine)
                                                                        guard machine.phase == .ready, observer.rejectedControlCount == 0,
                                                                              machine.activeSoundChannels == active,
                                                                              (try? observer.positions(for: machine.activeStreamPlaybackSnapshots)) != nil else {
                                                                            throw ResourceError.rejected("stream_control_handoff_identity_mismatch")
                                                                        }
                                                                        let updatedGains = try machine.soundCategoryGains(only: active)
                                                                        guard updatedGains == initialGains else { throw ResourceError.rejected("stream_control_handoff_gain_changed") }
                                                                        var concurrentCompletions: [HeadlessReplayBudget.ResearchControlCompletion] = []
                                                                        for existing in active {
                                                                            let updated = try audioEncoder.encode(machine.researchActiveAudioSnapshots(
                                                                                excluding: active.subtracting([existing])))
                                                                            if existing == channel {
                                                                                if try normalizedAudioControl(previous, pan: isPan) != normalizedAudioControl(updated, pan: isPan) {
                                                                                    let prior = try JSONDecoder().decode([ControlState].self, from: previous).first
                                                                                    let result = try JSONDecoder().decode([ControlState].self, from: updated).first
                                                                                    let normalizedBefore = try normalizedAudioControl(normalizedAudioControl(previous, pan: false), pan: true)
                                                                                    let normalizedAfter = try normalizedAudioControl(normalizedAudioControl(updated, pan: false), pan: true)
                                                                                    guard normalizedBefore == normalizedAfter, let prior, let result else {
                                                                                        researchStreamControlIssueBefore = String(data: previous, encoding: .utf8)
                                                                                        researchStreamControlIssueAfter = String(data: updated, encoding: .utf8)
                                                                                        throw ResourceError.rejected("stream_control_handoff_other_state_changed")
                                                                                    }
                                                                                    if isPan {
                                                                                        guard prior.volumeTarget == result.volumeTarget, prior.volumeAcknowledgementPending,
                                                                                              !prior.volumeChangePending, !result.volumeAcknowledgementPending,
                                                                                              !result.volumeChangePending, result.volumeDuration == 0, result.volumeDelay == 0 else {
                                                                                            throw ResourceError.rejected("stream_control_concurrent_volume_unmatched")
                                                                                        }
                                                                                        concurrentCompletions.append(.init(channel: index, kind: "volume"))
                                                                                    } else {
                                                                                        guard prior.panTarget == result.panTarget, prior.panAcknowledgementPending,
                                                                                              !prior.panChangePending, !result.panAcknowledgementPending,
                                                                                              !result.panChangePending, result.panDuration == 0, result.panDelay == 0 else {
                                                                                            throw ResourceError.rejected("stream_control_concurrent_pan_unmatched")
                                                                                        }
                                                                                        concurrentCompletions.append(.init(channel: index, kind: "pan"))
                                                                                    }
                                                                                }
                                                                                guard machine.researchPendingSoundControl(channel: channel, pan: isPan) == nil else {
                                                                                    researchStreamControlIssueBefore = String(data: previous, encoding: .utf8)
                                                                                    researchStreamControlIssueAfter = String(data: updated, encoding: .utf8)
                                                                                    throw ResourceError.rejected("stream_control_handoff_pending_unaccepted")
                                                                                }
                                                                                perChannelAudio[existing] = updated
                                                                            }
                                                                        }
                                                                        let immediate = control.duration == 0 && control.delay == 0 ? 1 : 0
                                                                        let otherCount = observer.completedControlCount - completedBefore - immediate - concurrentCompletions.count
                                                                        guard otherCount >= 0 else {
                                                                            throw ResourceError.rejected("stream_control_completion_count_mismatch")
                                                                        }
                                                                        let (otherCompletions, otherChannels) = try checkedControlCompletions(
                                                                            channels: active.subtracting([channel]), expectedCount: otherCount)
                                                                        guard researchStreamControlCompletions.count + concurrentCompletions.count + otherCompletions.count <= 4096 else {
                                                                            throw ResourceError.rejected("stream_control_completion_count_mismatch")
                                                                        }
                                                                        for (existing, updated) in otherChannels { perChannelAudio[existing] = updated }
                                                                        researchStreamControlCompletions.append(contentsOf: concurrentCompletions)
                                                                        researchStreamControlCompletions.append(contentsOf: otherCompletions)
                                                                        researchStreamOtherChannelControlCompletions += otherCompletions.count
                                                                        initialAudio = machine.researchActiveAudioSnapshots
                                                                        initialGains = updatedGains
                                                                        researchStreamControlHandoffs.append(.init(channel: index, kind: isPan ? "pan" : "volume",
                                                                            target: control.target, duration: control.duration, delay: control.delay))
                                                                        continue
                                                                    } catch {
                                                                        researchStreamControlHandoffIssue = String(describing: error)
                                                                        return (steps, "\(prefix)_stream_control_handoff_unsupported")
                                                                    }
                                                                }
                                                            }
                                                            if isVolume || isPan {
                                                                var changedChannels = 0
                                                                var pendingChannels = 0
                                                                var normalizedMatches = 0
                                                                for candidate in active.intersection(afterActive).sorted() {
                                                                    let observed = try audioEncoder.encode(machine.researchActiveAudioSnapshots(
                                                                        excluding: afterActive.subtracting([candidate])))
                                                                    guard let previous = perChannelAudio[candidate], observed != previous else { continue }
                                                                    changedChannels += 1
                                                                    if machine.researchPendingSoundControl(channel: candidate, pan: isPan) != nil { pendingChannels += 1 }
                                                                    if try normalizedAudioControl(previous, pan: isPan) == normalizedAudioControl(observed, pan: isPan) { normalizedMatches += 1 }
                                                                    if researchStreamControlIssueBefore == nil {
                                                                        researchStreamControlIssueBefore = String(data: previous, encoding: .utf8)
                                                                        researchStreamControlIssueAfter = String(data: observed, encoding: .utf8)
                                                                    }
                                                                }
                                                                researchStreamControlClassification = "changed=\(changedChannels),pending=\(pendingChannels),normalized=\(normalizedMatches),added=\(added.count),removed=\(removed.count),gainsMatch=\(afterGains == initialGains),handoffs=\(researchStreamControlHandoffs.count)"
                                                            }
                                                            if trace?.action == "sound_playback_request_candidate", machine.phase == .waitingForMedia,
                                                               machine.soundPlaybackIsStream, !machine.soundPlaybackPreservesPosition,
                                                               !machine.researchSoundPlaybackHasPendingSeek,
                                                               removed.isEmpty, added.count == 1, researchStreamPlaybackHandoffs.count < 2048,
                                                               let channel = added.first, channel == machine.soundPlaybackChannel,
                                                               let index = ScriptMachine.streamSaveChannelIndex(channel),
                                                               let request = machine.soundPlaybackRequest, let host = movieHost,
                                                               machine.activeStreamPlaybackSnapshots[channel]?.source == request,
                                                               machine.activeStreamPlaybackSnapshots[channel]?.step != nil,
                                                               (-1...1024).contains(machine.soundPlaybackRepeatCount) {
                                                                for existing in active {
                                                                    let current = try audioEncoder.encode(machine.researchActiveAudioSnapshots(
                                                                        excluding: afterActive.subtracting([existing])))
                                                                    guard current == perChannelAudio[existing], afterGains[existing] == initialGains[existing] else {
                                                                        return (steps, "\(prefix)_audio_change_unsupported")
                                                                    }
                                                                }
                                                                do {
                                                                    guard let duration = try observer.start(channel: channel, source: request,
                                                                        playbackStep: machine.activeStreamPlaybackSnapshots[channel]?.step,
                                                                        repeats: machine.soundPlaybackRepeatCount, preservePosition: false,
                                                                        seek: nil, decoder: host) else {
                                                                        throw ResourceError.rejected("stream_playback_duration_unavailable")
                                                                    }
                                                                    reusedStreamDecodeCount += 1
                                                                    try machine.acknowledgeSoundPlayback(durationMilliseconds: duration)
                                                                    let completedBefore = observer.completedControlCount
                                                                    let playbacksBefore = observer.completedPlaybackCount
                                                                    let newChannelControlsBefore = (observer.completedControlsByChannel[channel] ?? 0)
                                                                    try observer.synchronizeControls(machine: &machine)
                                                                    var positionsAvailable = (try? observer.positions(for: machine.activeStreamPlaybackSnapshots)) != nil
                                                                    let needsPositionRecovery = !positionsAvailable
                                                                    var recoveryAttempts = 0
                                                                    while !positionsAvailable, recoveryAttempts < 4 {
                                                                        recoveryAttempts += 1
                                                                        researchPlaybackPositionRecoveryAttempts += 1
                                                                        if try observer.awaitStoppedCompletion(for: machine.activeStreamPlaybackSnapshots) {
                                                                            researchStreamCompletionWaits += 1
                                                                        }
                                                                        try observer.synchronizeControls(machine: &machine)
                                                                        positionsAvailable = (try? observer.positions(for: machine.activeStreamPlaybackSnapshots)) != nil
                                                                    }
                                                                    guard machine.phase == .ready else {
                                                                        throw ResourceError.rejected("stream_playback_handoff_phase_changed")
                                                                    }
                                                                    guard observer.rejectedControlCount == 0 else {
                                                                        throw ResourceError.rejected("stream_playback_handoff_control_rejected")
                                                                    }
                                                                    let remaining = machine.activeSoundChannels
                                                                    let removedAtHandoff = afterActive.subtracting(remaining)
                                                                    guard remaining.isSubset(of: afterActive), remaining.contains(channel),
                                                                          removedAtHandoff.isSubset(of: active),
                                                                          observer.completedPlaybackCount - playbacksBefore == removedAtHandoff.count,
                                                                          researchStreamNaturalCompletions.count + removedAtHandoff.count <= 2048 else {
                                                                        throw ResourceError.rejected("stream_playback_handoff_active_channels_changed")
                                                                    }
                                                                    do { _ = try observer.positions(for: machine.activeStreamPlaybackSnapshots) }
                                                                    catch {
                                                                        researchPlaybackPositionIssue = observer.positionFailure(for: machine.activeStreamPlaybackSnapshots)
                                                                        throw ResourceError.rejected("stream_playback_handoff_positions_unavailable")
                                                                    }
                                                                    let updatedGains = try machine.soundCategoryGains(only: remaining)
                                                                    let surviving = active.subtracting(removedAtHandoff)
                                                                    for existing in surviving {
                                                                        guard updatedGains[existing] == initialGains[existing] else {
                                                                            throw ResourceError.rejected("stream_playback_handoff_other_channel_changed")
                                                                        }
                                                                    }
                                                                    let newChannelControls = (observer.completedControlsByChannel[channel] ?? 0) - newChannelControlsBefore
                                                                    let otherChannelControls = observer.completedControlCount - completedBefore - newChannelControls
                                                                    guard newChannelControls >= 0, otherChannelControls >= 0 else {
                                                                        throw ResourceError.rejected("stream_playback_control_count_invalid")
                                                                    }
                                                                    let (completedControls, updatedChannels) = try checkedControlCompletions(
                                                                        channels: surviving, expectedCount: otherChannelControls)
                                                                    for removed in removedAtHandoff.sorted() {
                                                                        guard let removedIndex = ScriptMachine.streamSaveChannelIndex(removed) else {
                                                                            throw ResourceError.rejected("stream_playback_completion_channel_invalid")
                                                                        }
                                                                        researchStreamNaturalCompletions.append(removedIndex)
                                                                        perChannelAudio.removeValue(forKey: removed)
                                                                    }
                                                                    for (existing, snapshot) in updatedChannels { perChannelAudio[existing] = snapshot }
                                                                    researchStreamControlCompletions.append(contentsOf: completedControls)
                                                                    researchPlaybackConcurrentControlCompletions += completedControls.count
                                                                    researchPlaybackConcurrentStreamCompletions += removedAtHandoff.count
                                                                    perChannelAudio[channel] = try audioEncoder.encode(machine.researchActiveAudioSnapshots(
                                                                        excluding: remaining.subtracting([channel])))
                                                                    initialAudio = machine.researchActiveAudioSnapshots
                                                                    initialGains = updatedGains
                                                                    if needsPositionRecovery { researchPlaybackPositionRecoveries += 1 }
                                                                    researchStreamPlaybackHandoffs.append(index)
                                                                    continue
                                                                } catch {
                                                                    researchStreamPlaybackHandoffIssue = String(describing: error)
                                                                    return (steps, "\(prefix)_stream_playback_handoff_unsupported")
                                                                }
                                                            }
                                                            guard trace?.action == "sound_channel_reset_candidate", removed.count == 1,
                                                                  added.isEmpty,
                                                                  researchStreamResetHandoffs.count < 2048,
                                                                  let removedChannel = removed.first,
                                                                  let removedIndex = ScriptMachine.streamSaveChannelIndex(removedChannel) else {
                                                                return (steps, "\(prefix)_audio_change_unsupported")
                                                            }
                                                            for channel in afterActive {
                                                                let current = try audioEncoder.encode(machine.researchActiveAudioSnapshots(
                                                                    excluding: afterActive.subtracting([channel])))
                                                                guard current == perChannelAudio[channel], afterGains[channel] == initialGains[channel] else {
                                                                    return (steps, "\(prefix)_audio_change_unsupported")
                                                                }
                                                            }
                                                            let pendingBefore = observer.pendingControlCount
                                                            observer.retainActiveChannels(afterActive)
                                                            guard observer.rejectedControlCount == 0 else {
                                                                return (steps, "\(prefix)_audio_identity_unsupported")
                                                            }
                                                            researchStreamResetControlsCancelled += max(0, pendingBefore - observer.pendingControlCount)
                                                            researchStreamResetHandoffs.append(removedIndex)
                                                            perChannelAudio.removeValue(forKey: removedChannel)
                                                            initialAudio = afterAudio
                                                            initialGains = afterGains
                                                            let remainingSnapshots = machine.activeStreamPlaybackSnapshots
                                                            if (try? observer.positions(for: remainingSnapshots)) == nil {
                                                                do {
                                                                    try recoverObservedCompletions(active: afterActive, snapshots: remainingSnapshots)
                                                                    researchStreamResetCompletionRecoveries += 1
                                                                } catch {
                                                                    researchStreamCompletionIssue = String(describing: error)
                                                                    return (steps, "\(prefix)_audio_identity_unsupported")
                                                                }
                                                            }
                                                        }
                                                    }
                                                    return (steps, machine.phase == .ready ? "\(prefix)_step_limit" : nil)
                                                }
                                                if issue == nil {
                                                    (researchZeroFollowthroughSteps, issue) = try advanceObservedSegment(prefix: "zero_followthrough", limit: 512)
                                                }
                                                func continueObservedDrawFrames() throws {
                                                    while researchZeroAudioDrawFrame, issue == nil, machine.phase == .waitingForFrame {
                                                        let pendingSkip = machine.pendingResearchSkipTime
                                                        guard pendingSkip == 0 || researchSkipAudioFrame else {
                                                            issue = "zero_draw_audio_pending_skip_frame_unsupported"
                                                            break
                                                        }
                                                        guard researchDrawAudioFollowthroughSteps < maximumDrawFollowthroughSteps else {
                                                            issue = "zero_draw_audio_step_limit"
                                                            break
                                                        }
                                                        guard ContinuousClock.now < segmentDeadline else {
                                                            issue = "zero_draw_audio_time_limit"
                                                            break
                                                        }
                                                        guard let frameTicks = researchDrawFrameTicks, let frameMaximum = researchDrawFrames,
                                                              let remainingBudget = budget, remainingBudget >= frameTicks,
                                                              researchDrawFramesAdvanced < frameMaximum else {
                                                            issue = "zero_draw_audio_frame_budget_unsupported"
                                                            break
                                                        }
                                                        do {
                                                            let activeBefore = machine.activeSoundChannels
                                                            let completedBefore = observer.completedControlCount
                                                            let playbacksBefore = observer.completedPlaybackCount
                                                            try observer.synchronizeControls(machine: &machine)
                                                            if machine.activeSoundChannels != activeBefore {
                                                                let remaining = machine.activeSoundChannels
                                                                guard remaining.isSubset(of: activeBefore), observer.rejectedControlCount == 0 else {
                                                                    throw ResourceError.rejected("frame_completion_identity_mismatch")
                                                                }
                                                                let (accepted, updatedChannels) = try checkedControlCompletions(
                                                                    channels: remaining, expectedCount: observer.completedControlCount - completedBefore)
                                                                for (channel, snapshot) in updatedChannels { perChannelAudio[channel] = snapshot }
                                                                try acceptObservedCompletions(active: activeBefore, completedBefore: playbacksBefore)
                                                                researchStreamControlCompletions.append(contentsOf: accepted)
                                                                researchFrameStartCombinedControlCompletions += accepted.count
                                                                researchFrameStartAudioCompletions += observer.completedPlaybackCount - playbacksBefore
                                                            }
                                                            let afterAudio = machine.researchActiveAudioSnapshots
                                                            let afterGains = try machine.soundCategoryGains(only: machine.activeSoundChannels)
                                                            if afterAudio != initialAudio || afterGains != initialGains {
                                                                guard machine.activeSoundChannels == activeBefore, afterGains == initialGains,
                                                                      observer.rejectedControlCount == 0,
                                                                      (try? observer.positions(for: machine.activeStreamPlaybackSnapshots)) != nil else {
                                                                    issue = "zero_draw_audio_control_transition_unsupported"
                                                                    break
                                                                }
                                                                let (accepted, updatedChannels) = try checkedControlCompletions(
                                                                    channels: activeBefore, expectedCount: observer.completedControlCount - completedBefore)
                                                                guard !accepted.isEmpty else {
                                                                    throw ResourceError.rejected("control_completion_count_mismatch")
                                                                }
                                                                researchStreamControlCompletions.append(contentsOf: accepted)
                                                                perChannelAudio = updatedChannels
                                                                initialAudio = afterAudio
                                                                initialGains = afterGains
                                                            }
                                                        } catch {
                                                            researchDrawAudioControlIssue = String(describing: error)
                                                            issue = "zero_draw_audio_control_observation_unsupported"
                                                            break
                                                        }
                                                        if let ticks = researchDrawFrameTicks, let maximum = researchDrawFrames,
                                                           let available = budget, available >= ticks, researchDrawFramesAdvanced < maximum {
                                                            let active = machine.activeSoundChannels
                                                            let snapshots = machine.activeStreamPlaybackSnapshots
                                                            if active.count != snapshots.count || observer.rejectedControlCount != 0 {
                                                                issue = "zero_draw_audio_identity_unsupported"
                                                            } else {
                                                                do {
                                                                    let before = try observer.positions(for: snapshots)
                                                                    if researchDrawAudioPositionsBefore == nil { researchDrawAudioPositionsBefore = before }
                                                                    let visualBefore = machine.researchVisualTicks
                                                                    let zeroClock = machine.researchZeroWaitClockPending
                                                                    try machine.advanceResearchDrawFrame(ticks: ticks, allowObservedStreams: true,
                                                                        consumePendingSkipTime: pendingSkip > 0)
                                                                    if pendingSkip > 0 {
                                                                        researchSkipAudioFrameHandled = true
                                                                        researchSkipAudioFramesHandled += 1
                                                                    }
                                                                    budget = available - ticks
                                                                    researchDrawFramesAdvanced += 1
                                                                    let after: [Int32: Int32]
                                                                    do {
                                                                        after = try observer.positions(for: machine.activeStreamPlaybackSnapshots)
                                                                    } catch {
                                                                        guard machine.activeSoundChannels == active,
                                                                              machine.researchActiveAudioSnapshots == initialAudio,
                                                                              try machine.soundCategoryGains(only: active) == initialGains else {
                                                                            throw ResourceError.rejected("frame_completion_other_state_changed")
                                                                        }
                                                                        let completedBefore = observer.completedPlaybackCount
                                                                        do { try recoverObservedCompletions(active: active, snapshots: snapshots) }
                                                                        catch {
                                                                            researchStreamCompletionIssue = String(describing: error)
                                                                            throw error
                                                                        }
                                                                        researchFrameAudioCompletions += observer.completedPlaybackCount - completedBefore
                                                                        after = try observer.positions(for: machine.activeStreamPlaybackSnapshots)
                                                                    }
                                                                    researchDrawAudioPositionsAfter = after
                                                                    researchDrawAudioFrames.append(.init(ticks: ticks, pendingSkipTicks: pendingSkip,
                                                                        effectiveTicks: zeroClock ? 0 : ticks + pendingSkip, zeroClock: zeroClock,
                                                                        visualTicksBefore: visualBefore,
                                                                        visualTicksAfter: machine.researchVisualTicks, positionsBefore: before, positionsAfter: after))
                                                                    if try machine.researchActiveAudioSnapshots != initialAudio ||
                                                                        machine.soundCategoryGains(only: machine.activeSoundChannels) != initialGains {
                                                                        issue = "zero_draw_audio_change_unsupported"
                                                                    } else {
                                                                        let (steps, nextIssue) = try advanceObservedSegment(prefix: "zero_draw_audio", limit: maximumDrawFollowthroughSteps - researchDrawAudioFollowthroughSteps)
                                                                        researchDrawAudioFollowthroughSteps += steps
                                                                        issue = nextIssue
                                                                    }
                                                                } catch ResourceError.rejected(let failure) {
                                                                    issue = failure.hasPrefix("draw_frame_") ? failure : "zero_draw_audio_identity_unsupported"
                                                                }
                                                            }
                                                        } else {
                                                            issue = "zero_draw_audio_frame_budget_unsupported"
                                                        }
                                                    }
                                                }
                                                func continueLaterUntimedWaits(_ frameTicks: Int32) throws {
                                                    let startFrames = researchLaterPostWaitFrames
                                                    let startCompleted = researchLaterPostWaitCompletedCount
                                                while issue == nil, machine.phase == .waiting,
                                                      !machine.researchHasActiveTimers,
                                                      researchLaterPostWaitCompletedCount - startCompleted < 4,
                                                      researchLaterPostWaitFrames - startFrames < 16384 {
                                                    let postActive = machine.activeSoundChannels
                                                    let postSnapshots = machine.activeStreamPlaybackSnapshots
                                                    guard postActive.count == postSnapshots.count,
                                                          let initialWait = machine.clickWaitRemaining, initialWait > 0,
                                                          machine.pendingResearchSkipTime == 0,
                                                          observer.rejectedControlCount == 0,
                                                          machine.researchActiveAudioSnapshots == initialAudio,
                                                          try machine.soundCategoryGains(only: postActive) == initialGains,
                                                          (try? observer.positions(for: postSnapshots)) != nil else {
                                                        throw ResourceError.rejected("research_later_post_wait_initial_unsupported")
                                                    }
                                                    if machine.researchZeroWaitClockPending {
                                                        guard let available = budget, available >= frameTicks else {
                                                            throw ResourceError.rejected("research_later_post_wait_zero_budget")
                                                        }
                                                        let elapsed = try machine.consumeResearchWaitZeroClock(hostTicks: frameTicks, allowObservedStreams: true)
                                                        guard elapsed == 0 else { throw ResourceError.rejected("research_later_post_wait_zero_nonzero") }
                                                        try machine.advanceClickWait(ticks: 0)
                                                        try machine.advancePlacementClock(ticks: 0)
                                                        budget = available - frameTicks
                                                        guard machine.clickWaitRemaining == initialWait, !machine.researchHasActiveTimers else {
                                                            throw ResourceError.rejected("research_later_post_wait_zero_changed")
                                                        }
                                                        researchLaterPostWaitZeroFrames += 1
                                                    }
                                                    while issue == nil, machine.phase == .waiting, researchLaterPostWaitFrames - startFrames < 16384 {
                                                        try machine.validateResearchChoiceWaitClock()
                                                        guard ContinuousClock.now < segmentDeadline,
                                                              researchDrawAudioFollowthroughSteps < maximumDrawFollowthroughSteps,
                                                              let remaining = machine.clickWaitRemaining, remaining >= frameTicks,
                                                              let available = budget, available >= frameTicks,
                                                              !machine.researchHasActiveTimers,
                                                              machine.activeSoundChannels == postActive,
                                                              machine.researchActiveAudioSnapshots == initialAudio,
                                                              try machine.soundCategoryGains(only: postActive) == initialGains,
                                                              observer.rejectedControlCount == 0,
                                                              (try? observer.positions(for: postSnapshots)) != nil else {
                                                            issue = "research_later_post_wait_frame_outside_profile"
                                                            break
                                                        }
                                                        try machine.advanceClickWait(ticks: frameTicks)
                                                        try machine.advancePlacementClock(ticks: frameTicks)
                                                        budget = available - frameTicks
                                                        researchLaterPostWaitFrames += 1
                                                        if machine.phase == .ready {
                                                            researchLaterPostWaitCompletedCount += 1
                                                            let (postSteps, postIssue) = try advanceObservedSegment(prefix: "zero_draw_audio_later_post_wait", limit: maximumDrawFollowthroughSteps - researchDrawAudioFollowthroughSteps)
                                                            researchDrawAudioFollowthroughSteps += postSteps
                                                            issue = postIssue
                                                            if issue == nil, machine.phase == .waitingForFrame {
                                                                let beforeFrames = researchDrawFramesAdvanced
                                                                try continueObservedDrawFrames()
                                                                researchChoicePostDrawFrames += researchDrawFramesAdvanced - beforeFrames
                                                            }
                                                            break
                                                        }
                                                    }
                                                }
                                                }
                                                func continueSelectionTimedWait(_ frameTicks: Int32) throws -> (completed: Bool, frames: Int, timers: Int, zero: Bool) {
                                                    var waitCompleted = false
                                                    var waitFrames = 0
                                                    var waitTimers = 0
                                                    var waitZero = false
                                                if issue == nil, machine.phase == .waiting, machine.researchHasActiveTimers {
                                                    let thirdActive = machine.activeSoundChannels
                                                    let thirdSnapshots = machine.activeStreamPlaybackSnapshots
                                                    guard thirdActive.count == thirdSnapshots.count,
                                                          let initialWait = machine.clickWaitRemaining, initialWait > 0,
                                                          let initialTimer = machine.ticksUntilTimer, initialTimer > 0,
                                                          machine.pendingResearchSkipTime == 0,
                                                          observer.rejectedControlCount == 0,
                                                          machine.researchActiveAudioSnapshots == initialAudio,
                                                          try machine.soundCategoryGains(only: thirdActive) == initialGains,
                                                          (try? observer.positions(for: thirdSnapshots)) != nil else {
                                                        throw ResourceError.rejected("research_third_wait_initial_unsupported")
                                                    }
                                                    if machine.researchZeroWaitClockPending {
                                                        guard let available = budget, available >= frameTicks else {
                                                            throw ResourceError.rejected("research_third_wait_zero_budget")
                                                        }
                                                        let elapsed = try machine.consumeResearchWaitZeroClock(hostTicks: frameTicks, allowObservedStreams: true, allowObservedTimers: true)
                                                        guard elapsed == 0 else { throw ResourceError.rejected("research_third_wait_zero_nonzero") }
                                                        try machine.advanceClickWait(ticks: 0)
                                                        try machine.advancePlacementClock(ticks: 0)
                                                        budget = available - frameTicks
                                                        guard machine.clickWaitRemaining == initialWait, machine.ticksUntilTimer == initialTimer else {
                                                            throw ResourceError.rejected("research_third_wait_zero_changed")
                                                        }
                                                        waitZero = true
                                                    }
                                                    while waitFrames < 512, issue == nil {
                                                        try machine.validateResearchChoiceWaitClock()
                                                        guard ContinuousClock.now < segmentDeadline,
                                                              researchDrawAudioFollowthroughSteps < maximumDrawFollowthroughSteps,
                                                              let remaining = machine.clickWaitRemaining, remaining >= frameTicks,
                                                              let nextTimer = machine.ticksUntilTimer, nextTimer >= frameTicks,
                                                              let available = budget, available >= frameTicks,
                                                              machine.activeSoundChannels == thirdActive,
                                                              machine.researchActiveAudioSnapshots == initialAudio,
                                                              try machine.soundCategoryGains(only: thirdActive) == initialGains,
                                                              observer.rejectedControlCount == 0,
                                                              (try? observer.positions(for: thirdSnapshots)) != nil else {
                                                            issue = "research_third_wait_frame_outside_profile"
                                                            break
                                                        }
                                                        if nextTimer == remaining {
                                                            issue = "research_third_wait_simultaneous_deadline_unsupported"
                                                            break
                                                        }
                                                        try machine.advanceClickWait(ticks: frameTicks)
                                                        try machine.advancePlacementClock(ticks: frameTicks)
                                                        budget = available - frameTicks
                                                        waitFrames += 1
                                                        if machine.ticksUntilTimer == 0 {
                                                            guard try machine.dispatchDueTimer() else { throw ResourceError.rejected("research_third_wait_timer_dispatch_failed") }
                                                            waitTimers += 1
                                                            let (timerSteps, timerIssue) = try advanceObservedSegment(prefix: "zero_draw_audio_third_wait_timer", limit: min(512, maximumDrawFollowthroughSteps - researchDrawAudioFollowthroughSteps))
                                                            researchDrawAudioFollowthroughSteps += timerSteps
                                                            issue = timerIssue
                                                            if issue == nil, machine.phase != .waiting { issue = "research_third_wait_timer_return_unsupported" }
                                                            if issue == nil, waitTimers >= 16 { issue = "research_third_wait_timer_budget_unsupported" }
                                                        } else if machine.phase == .ready {
                                                            waitCompleted = true
                                                            let (finishSteps, finishIssue) = try advanceObservedSegment(prefix: "zero_draw_audio_third_wait", limit: min(512, maximumDrawFollowthroughSteps - researchDrawAudioFollowthroughSteps))
                                                            researchDrawAudioFollowthroughSteps += finishSteps
                                                            issue = finishIssue
                                                            break
                                                        }
                                                    }
                                                    if issue == nil, !waitCompleted { issue = "research_third_wait_frame_budget_unsupported" }
                                                }
                                                    return (waitCompleted, waitFrames, waitTimers, waitZero)
                                                }
                                                try continueObservedDrawFrames()
                                                if researchZeroAudioDrawFrame, researchSkipAudioFrame, issue == nil,
                                                   machine.phase == .waiting,
                                                   researchDrawAudioFollowthroughSteps < maximumDrawFollowthroughSteps,
                                                   ContinuousClock.now < segmentDeadline {
                                                    do {
                                                        if machine.researchZeroWaitClockPending {
                                                            guard let quantum = researchDrawFrameTicks, let available = budget, available >= quantum,
                                                                  let remaining = machine.clickWaitRemaining, remaining > 0,
                                                                  let timer = machine.ticksUntilTimer, timer > 0,
                                                                  machine.pendingResearchSkipTime == 0 else {
                                                                throw ResourceError.rejected("research_zero_timer_wait_outside_profile")
                                                            }
                                                            let active = machine.activeSoundChannels
                                                            let snapshots = machine.activeStreamPlaybackSnapshots
                                                            guard active.count == snapshots.count, observer.rejectedControlCount == 0,
                                                                  machine.researchActiveAudioSnapshots == initialAudio,
                                                                  try machine.soundCategoryGains(only: active) == initialGains,
                                                                  (try? observer.positions(for: snapshots)) != nil else {
                                                                throw ResourceError.rejected("research_zero_timer_identity_unsupported")
                                                            }
                                                            let elapsed = try machine.consumeResearchWaitZeroClock(hostTicks: quantum,
                                                                allowObservedStreams: true, allowObservedTimers: true)
                                                            guard elapsed == 0 else { throw ResourceError.rejected("research_zero_timer_elapsed_nonzero") }
                                                            try machine.advanceClickWait(ticks: elapsed)
                                                            try machine.advancePlacementClock(ticks: elapsed)
                                                            budget = available - quantum
                                                            guard machine.clickWaitRemaining == remaining, machine.ticksUntilTimer == timer,
                                                                  machine.activeSoundChannels == active,
                                                                  machine.researchActiveAudioSnapshots == initialAudio,
                                                                  try machine.soundCategoryGains(only: active) == initialGains,
                                                                  (try? observer.positions(for: snapshots)) != nil else {
                                                                throw ResourceError.rejected("research_zero_timer_state_changed")
                                                            }
                                                            researchDrawWaitZeroTimerFrame = true
                                                            while researchDrawWaitTimerFrames < 256, issue == nil {
                                                                guard ContinuousClock.now < segmentDeadline,
                                                                      let remaining = machine.clickWaitRemaining, remaining > 0,
                                                                      let nextTimer = machine.ticksUntilTimer, nextTimer > 0,
                                                                      nextTimer != remaining, nextTimer >= quantum, remaining >= quantum,
                                                                      let available = budget, available >= quantum,
                                                                      machine.pendingResearchSkipTime == 0,
                                                                      !machine.researchZeroWaitClockPending,
                                                                      machine.activeSoundChannels == active,
                                                                      machine.researchActiveAudioSnapshots == initialAudio,
                                                                      try machine.soundCategoryGains(only: active) == initialGains,
                                                                      observer.rejectedControlCount == 0,
                                                                      (try? observer.positions(for: snapshots)) != nil else {
                                                                    issue = "research_timer_frame_outside_profile"
                                                                    break
                                                                }
                                                                try machine.advanceClickWait(ticks: quantum)
                                                                try machine.advancePlacementClock(ticks: quantum)
                                                                budget = available - quantum
                                                                researchDrawWaitTimerFrames += 1
                                                                if machine.ticksUntilTimer == 0 {
                                                                    guard try machine.dispatchDueTimer() else {
                                                                        throw ResourceError.rejected("research_timer_due_dispatch_failed")
                                                                    }
                                                                    researchDrawWaitTimerDispatched = true
                                                                    researchDrawWaitTimerDispatchCount += 1
                                                                    let (steps, nextIssue) = try advanceObservedSegment(prefix: "zero_draw_audio_timer", limit: min(512, maximumDrawFollowthroughSteps - researchDrawAudioFollowthroughSteps))
                                                                    researchDrawAudioFollowthroughSteps += steps
                                                                    issue = nextIssue
                                                                    if issue == nil, machine.phase != .waiting {
                                                                        issue = "research_timer_callback_wait_not_restored"
                                                                    }
                                                                    if researchDrawWaitTimerDispatchCount >= 4, issue == nil {
                                                                        issue = "research_timer_callback_budget_unsupported"
                                                                    }
                                                                } else if machine.phase == .ready {
                                                                    researchDrawWaitCompleted = true
                                                                    let (steps, nextIssue) = try advanceObservedSegment(prefix: "zero_draw_audio_wait_complete", limit: min(512, maximumDrawFollowthroughSteps - researchDrawAudioFollowthroughSteps))
                                                                    researchDrawAudioFollowthroughSteps += steps
                                                                    issue = nextIssue
                                                                    if issue == nil, machine.isWaitingForStoryChoice,
                                                                       choiceCursor < storyChoices.count,
                                                                       machine.pendingResearchSkipTime == 0,
                                                                       (machine.ticksUntilTimer ?? 1) > 0,
                                                                       researchDrawAudioFollowthroughSteps < maximumDrawFollowthroughSteps,
                                                                       ContinuousClock.now < segmentDeadline {
                                                                        let active = machine.activeSoundChannels
                                                                        let choiceSnapshots = machine.activeStreamPlaybackSnapshots
                                                                        guard active.count == choiceSnapshots.count, observer.rejectedControlCount == 0,
                                                                              machine.researchActiveAudioSnapshots == initialAudio,
                                                                              try machine.soundCategoryGains(only: active) == initialGains,
                                                                              (try? observer.positions(for: choiceSnapshots)) != nil else {
                                                                            throw ResourceError.rejected("research_story_choice_identity_unsupported")
                                                                        }
                                                                        let choice = storyChoices[choiceCursor]
                                                                        try machine.dispatchStoryChoice(choice)
                                                                        let receipt = "story_choice=\(choiceCursor) index=\(choice)\n"
                                                                        FileHandle.standardError.write(Data(receipt.utf8))
                                                                        choiceCursor += 1
                                                                        researchDrawStoryChoiceDispatched = true
                                                                        let (choiceSteps, choiceIssue) = try advanceObservedSegment(prefix: "zero_draw_audio_story_choice", limit: min(512, maximumDrawFollowthroughSteps - researchDrawAudioFollowthroughSteps))
                                                                        researchDrawAudioFollowthroughSteps += choiceSteps
                                                                        issue = choiceIssue
                                                                        if issue == nil, machine.phase == .waiting {
                                                                            guard let initialWait = machine.clickWaitRemaining, initialWait > 0,
                                                                                  let initialTimer = machine.ticksUntilTimer, initialTimer > 0,
                                                                                  let frameTicks = researchDrawFrameTicks, let available = budget,
                                                                                  available >= frameTicks, machine.pendingResearchSkipTime == 0,
                                                                                  machine.activeSoundChannels == active,
                                                                                  machine.researchActiveAudioSnapshots == initialAudio,
                                                                                  try machine.soundCategoryGains(only: active) == initialGains,
                                                                                  (try? observer.positions(for: choiceSnapshots)) != nil else {
                                                                                throw ResourceError.rejected("research_choice_wait_initial_state_unsupported")
                                                                            }
                                                                            if machine.researchZeroWaitClockPending {
                                                                                let elapsed = try machine.consumeResearchWaitZeroClock(hostTicks: frameTicks,
                                                                                    allowObservedStreams: true, allowObservedTimers: true)
                                                                                guard elapsed == 0 else { throw ResourceError.rejected("research_choice_wait_zero_nonzero") }
                                                                                try machine.advanceClickWait(ticks: elapsed)
                                                                                try machine.advancePlacementClock(ticks: elapsed)
                                                                                budget = available - frameTicks
                                                                                guard machine.clickWaitRemaining == initialWait, machine.ticksUntilTimer == initialTimer else {
                                                                                    throw ResourceError.rejected("research_choice_wait_zero_changed")
                                                                                }
                                                                                researchChoiceWaitZeroFrame = true
                                                                            }
                                                                            while researchChoiceWaitFrames < 512, issue == nil {
                                                                                try machine.validateResearchChoiceWaitClock()
                                                                                guard ContinuousClock.now < segmentDeadline,
                                                                                      let remaining = machine.clickWaitRemaining, remaining > 0,
                                                                                      let nextTimer = machine.ticksUntilTimer, nextTimer > 0,
                                                                                      let available = budget, available >= frameTicks,
                                                                                      nextTimer >= frameTicks, remaining >= frameTicks,
                                                                                      machine.activeSoundChannels == active,
                                                                                      machine.researchActiveAudioSnapshots == initialAudio,
                                                                                      try machine.soundCategoryGains(only: active) == initialGains,
                                                                                      observer.rejectedControlCount == 0,
                                                                                      (try? observer.positions(for: choiceSnapshots)) != nil else {
                                                                                    issue = "research_choice_wait_frame_outside_profile"
                                                                                    break
                                                                                }
                                                                                if nextTimer == remaining {
                                                                                    issue = "research_choice_wait_simultaneous_deadline_unsupported"
                                                                                    break
                                                                                }
                                                                                try machine.advanceClickWait(ticks: frameTicks)
                                                                                try machine.advancePlacementClock(ticks: frameTicks)
                                                                                budget = available - frameTicks
                                                                                researchChoiceWaitFrames += 1
                                                                                if machine.ticksUntilTimer == 0 {
                                                                                    guard try machine.dispatchDueTimer() else {
                                                                                        throw ResourceError.rejected("research_choice_wait_timer_dispatch_failed")
                                                                                    }
                                                                                    researchChoiceWaitTimerDispatchCount += 1
                                                                                    let (timerSteps, timerIssue) = try advanceObservedSegment(prefix: "zero_draw_audio_choice_timer", limit: min(512, maximumDrawFollowthroughSteps - researchDrawAudioFollowthroughSteps))
                                                                                    researchDrawAudioFollowthroughSteps += timerSteps
                                                                                    issue = timerIssue
                                                                                    if issue == nil, machine.phase != .waiting { issue = "research_choice_wait_timer_return_unsupported" }
                                                                                    if issue == nil, researchChoiceWaitTimerDispatchCount >= 16 { issue = "research_choice_wait_timer_budget_unsupported" }
                                                                                } else if machine.phase == .ready {
                                                                                    let (finishSteps, finishIssue) = try advanceObservedSegment(prefix: "zero_draw_audio_choice_wait", limit: min(512, maximumDrawFollowthroughSteps - researchDrawAudioFollowthroughSteps))
                                                                                    researchDrawAudioFollowthroughSteps += finishSteps
                                                                                    issue = finishIssue
                                                                                    if issue == nil, machine.phase == .waiting,
                                                                                       !machine.researchHasActiveTimers,
                                                                                       let postRemaining = machine.clickWaitRemaining, postRemaining > 0,
                                                                                       machine.pendingResearchSkipTime == 0 {
                                                                                        if machine.researchZeroWaitClockPending {
                                                                                            guard machine.activeSoundChannels == active,
                                                                                                  machine.researchActiveAudioSnapshots == initialAudio,
                                                                                                  try machine.soundCategoryGains(only: active) == initialGains,
                                                                                                  observer.rejectedControlCount == 0,
                                                                                                  (try? observer.positions(for: choiceSnapshots)) != nil else {
                                                                                                throw ResourceError.rejected("research_post_choice_zero_identity")
                                                                                            }
                                                                                            guard let available = budget, available >= frameTicks else {
                                                                                                throw ResourceError.rejected("research_post_choice_zero_budget")
                                                                                            }
                                                                                            let zeroTicks = try machine.consumeResearchWaitZeroClock(hostTicks: frameTicks, allowObservedStreams: true)
                                                                                            guard zeroTicks == 0 else { throw ResourceError.rejected("research_post_choice_zero_nonzero") }
                                                                                            try machine.advanceClickWait(ticks: 0)
                                                                                            try machine.advancePlacementClock(ticks: 0)
                                                                                            budget = available - frameTicks
                                                                                            guard machine.clickWaitRemaining == postRemaining, !machine.researchHasActiveTimers else {
                                                                                                throw ResourceError.rejected("research_post_choice_zero_state_changed")
                                                                                            }
                                                                                            researchChoicePostWaitZeroFrame = true
                                                                                        }
                                                                                        while researchChoicePostWaitFrames < 1024, issue == nil {
                                                                                            try machine.validateResearchChoiceWaitClock()
                                                                                            guard ContinuousClock.now < segmentDeadline,
                                                                                                  let remaining = machine.clickWaitRemaining, remaining >= frameTicks,
                                                                                                  let available = budget, available >= frameTicks,
                                                                                                  !machine.researchHasActiveTimers,
                                                                                                  machine.activeSoundChannels == active,
                                                                                                  machine.researchActiveAudioSnapshots == initialAudio,
                                                                                                  try machine.soundCategoryGains(only: active) == initialGains,
                                                                                                  observer.rejectedControlCount == 0,
                                                                                                  (try? observer.positions(for: choiceSnapshots)) != nil else {
                                                                                                issue = "research_post_choice_wait_outside_profile"
                                                                                                break
                                                                                            }
                                                                                            try machine.advanceClickWait(ticks: frameTicks)
                                                                                            try machine.advancePlacementClock(ticks: frameTicks)
                                                                                            budget = available - frameTicks
                                                                                            researchChoicePostWaitFrames += 1
                                                                                            if machine.phase == .ready {
                                                                                                researchChoicePostWaitCompleted = true
                                                                                                researchChoicePostWaitCompletedCount += 1
                                                                                                let (postSteps, postIssue) = try advanceObservedSegment(prefix: "zero_draw_audio_post_choice_wait", limit: min(4096, maximumDrawFollowthroughSteps - researchDrawAudioFollowthroughSteps))
                                                                                                researchDrawAudioFollowthroughSteps += postSteps
                                                                                                issue = postIssue
                                                                                                if issue == nil, machine.phase == .waitingForFrame {
                                                                                                    let beforeFrames = researchDrawFramesAdvanced
                                                                                                    try continueObservedDrawFrames()
                                                                                                    researchChoicePostDrawFrames += researchDrawFramesAdvanced - beforeFrames
                                                                                                }
                                                                                                if issue == nil, machine.phase == .waiting, machine.researchHasActiveTimers {
                                                                                                    let laterActive = machine.activeSoundChannels
                                                                                                    let laterSnapshots = machine.activeStreamPlaybackSnapshots
                                                                                                    guard laterActive.count == laterSnapshots.count,
                                                                                                          let initialWait = machine.clickWaitRemaining, initialWait > 0,
                                                                                                          let initialTimer = machine.ticksUntilTimer, initialTimer > 0,
                                                                                                          machine.pendingResearchSkipTime == 0,
                                                                                                          observer.rejectedControlCount == 0,
                                                                                                          machine.researchActiveAudioSnapshots == initialAudio,
                                                                                                          try machine.soundCategoryGains(only: laterActive) == initialGains,
                                                                                                          (try? observer.positions(for: laterSnapshots)) != nil else {
                                                                                                        throw ResourceError.rejected("research_later_wait_initial_state_unsupported")
                                                                                                    }
                                                                                                    if machine.researchZeroWaitClockPending {
                                                                                                        guard let available = budget, available >= frameTicks else {
                                                                                                            throw ResourceError.rejected("research_later_wait_zero_budget")
                                                                                                        }
                                                                                                        let elapsed = try machine.consumeResearchWaitZeroClock(hostTicks: frameTicks, allowObservedStreams: true, allowObservedTimers: true)
                                                                                                        guard elapsed == 0 else { throw ResourceError.rejected("research_later_wait_zero_nonzero") }
                                                                                                        try machine.advanceClickWait(ticks: 0)
                                                                                                        try machine.advancePlacementClock(ticks: 0)
                                                                                                        budget = available - frameTicks
                                                                                                        guard machine.clickWaitRemaining == initialWait, machine.ticksUntilTimer == initialTimer else {
                                                                                                            throw ResourceError.rejected("research_later_wait_zero_changed")
                                                                                                        }
                                                                                                        researchLaterWaitZeroFrame = true
                                                                                                    }
                                                                                                    while researchLaterWaitFrames < 512, issue == nil {
                                                                                                        try machine.validateResearchChoiceWaitClock()
                                                                                                        guard ContinuousClock.now < segmentDeadline,
                                                                                                              researchDrawAudioFollowthroughSteps < maximumDrawFollowthroughSteps,
                                                                                                              let remaining = machine.clickWaitRemaining, remaining >= frameTicks,
                                                                                                              let nextTimer = machine.ticksUntilTimer, nextTimer >= frameTicks,
                                                                                                              let available = budget, available >= frameTicks,
                                                                                                              machine.activeSoundChannels == laterActive,
                                                                                                              machine.researchActiveAudioSnapshots == initialAudio,
                                                                                                              try machine.soundCategoryGains(only: laterActive) == initialGains,
                                                                                                              observer.rejectedControlCount == 0,
                                                                                                              (try? observer.positions(for: laterSnapshots)) != nil else {
                                                                                                            issue = "research_later_wait_frame_outside_profile"
                                                                                                            break
                                                                                                        }
                                                                                                        if nextTimer == remaining {
                                                                                                            issue = "research_later_wait_simultaneous_deadline_unsupported"
                                                                                                            break
                                                                                                        }
                                                                                                        try machine.advanceClickWait(ticks: frameTicks)
                                                                                                        try machine.advancePlacementClock(ticks: frameTicks)
                                                                                                        budget = available - frameTicks
                                                                                                        researchLaterWaitFrames += 1
                                                                                                        if machine.ticksUntilTimer == 0 {
                                                                                                            guard try machine.dispatchDueTimer() else {
                                                                                                                throw ResourceError.rejected("research_later_wait_timer_dispatch_failed")
                                                                                                            }
                                                                                                            researchLaterWaitTimerCount += 1
                                                                                                            let (timerSteps, timerIssue) = try advanceObservedSegment(prefix: "zero_draw_audio_later_timer", limit: min(512, maximumDrawFollowthroughSteps - researchDrawAudioFollowthroughSteps))
                                                                                                            researchDrawAudioFollowthroughSteps += timerSteps
                                                                                                            issue = timerIssue
                                                                                                            if issue == nil, machine.phase != .waiting { issue = "research_later_wait_timer_return_unsupported" }
                                                                                                            if issue == nil, researchLaterWaitTimerCount >= 16 { issue = "research_later_wait_timer_budget_unsupported" }
                                                                                                        } else if machine.phase == .ready {
                                                                                                            researchLaterWaitCompleted = true
                                                                                                            let (finishSteps, finishIssue) = try advanceObservedSegment(prefix: "zero_draw_audio_later_wait", limit: min(512, maximumDrawFollowthroughSteps - researchDrawAudioFollowthroughSteps))
                                                                                                            researchDrawAudioFollowthroughSteps += finishSteps
                                                                                                            issue = finishIssue
                                                                                                            if issue == nil, machine.isWaitingForStoryChoice,
                                                                                                               choiceCursor < storyChoices.count,
                                                                                                               machine.pendingResearchSkipTime == 0,
                                                                                                               (machine.ticksUntilTimer ?? 1) > 0,
                                                                                                               researchDrawAudioFollowthroughSteps < maximumDrawFollowthroughSteps,
                                                                                                               ContinuousClock.now < segmentDeadline {
                                                                                                                let choiceActive = machine.activeSoundChannels
                                                                                                                let choiceSnapshots = machine.activeStreamPlaybackSnapshots
                                                                                                                guard choiceActive.count == choiceSnapshots.count,
                                                                                                                      observer.rejectedControlCount == 0,
                                                                                                                      machine.researchActiveAudioSnapshots == initialAudio,
                                                                                                                      try machine.soundCategoryGains(only: choiceActive) == initialGains,
                                                                                                                      (try? observer.positions(for: choiceSnapshots)) != nil else {
                                                                                                                    throw ResourceError.rejected("research_later_choice_identity_unsupported")
                                                                                                                }
                                                                                                                let choice = storyChoices[choiceCursor]
                                                                                                                try machine.dispatchStoryChoice(choice)
                                                                                                                FileHandle.standardError.write(Data("story_choice=\(choiceCursor) index=\(choice)\n".utf8))
                                                                                                                choiceCursor += 1
                                                                                                                researchLaterChoiceDispatched = true
                                                                                                                let (choiceSteps, choiceIssue) = try advanceObservedSegment(prefix: "zero_draw_audio_later_choice", limit: min(512, maximumDrawFollowthroughSteps - researchDrawAudioFollowthroughSteps))
                                                                                                                researchDrawAudioFollowthroughSteps += choiceSteps
                                                                                                                issue = choiceIssue
                                                                                                                if issue == nil, machine.phase == .waiting, machine.researchHasActiveTimers {
                                                                                                                    let waitActive = machine.activeSoundChannels
                                                                                                                    let waitSnapshots = machine.activeStreamPlaybackSnapshots
                                                                                                                    guard waitActive.count == waitSnapshots.count,
                                                                                                                          let initialWait = machine.clickWaitRemaining, initialWait > 0,
                                                                                                                          let initialTimer = machine.ticksUntilTimer, initialTimer > 0,
                                                                                                                          machine.pendingResearchSkipTime == 0,
                                                                                                                          observer.rejectedControlCount == 0,
                                                                                                                          machine.researchActiveAudioSnapshots == initialAudio,
                                                                                                                          try machine.soundCategoryGains(only: waitActive) == initialGains,
                                                                                                                          (try? observer.positions(for: waitSnapshots)) != nil else {
                                                                                                                        throw ResourceError.rejected("research_later_choice_wait_initial_unsupported")
                                                                                                                    }
                                                                                                                    if machine.researchZeroWaitClockPending {
                                                                                                                        guard let available = budget, available >= frameTicks else {
                                                                                                                            throw ResourceError.rejected("research_later_choice_wait_zero_budget")
                                                                                                                        }
                                                                                                                        let elapsed = try machine.consumeResearchWaitZeroClock(hostTicks: frameTicks, allowObservedStreams: true, allowObservedTimers: true)
                                                                                                                        guard elapsed == 0 else { throw ResourceError.rejected("research_later_choice_wait_zero_nonzero") }
                                                                                                                        try machine.advanceClickWait(ticks: 0)
                                                                                                                        try machine.advancePlacementClock(ticks: 0)
                                                                                                                        budget = available - frameTicks
                                                                                                                        guard machine.clickWaitRemaining == initialWait, machine.ticksUntilTimer == initialTimer else {
                                                                                                                            throw ResourceError.rejected("research_later_choice_wait_zero_changed")
                                                                                                                        }
                                                                                                                        researchLaterChoiceWaitZeroFrame = true
                                                                                                                    }
                                                                                                                    while researchLaterChoiceWaitFrames < 1024, issue == nil {
                                                                                                                        try machine.validateResearchChoiceWaitClock()
                                                                                                                        guard ContinuousClock.now < segmentDeadline,
                                                                                                                              researchDrawAudioFollowthroughSteps < maximumDrawFollowthroughSteps,
                                                                                                                              let remaining = machine.clickWaitRemaining, remaining >= frameTicks,
                                                                                                                              let nextTimer = machine.ticksUntilTimer, nextTimer >= frameTicks,
                                                                                                                              let available = budget, available >= frameTicks,
                                                                                                                              machine.activeSoundChannels == waitActive,
                                                                                                                              machine.researchActiveAudioSnapshots == initialAudio,
                                                                                                                              try machine.soundCategoryGains(only: waitActive) == initialGains,
                                                                                                                              observer.rejectedControlCount == 0,
                                                                                                                              (try? observer.positions(for: waitSnapshots)) != nil else {
                                                                                                                            issue = "research_later_choice_wait_frame_outside_profile"
                                                                                                                            break
                                                                                                                        }
                                                                                                                        if nextTimer == remaining {
                                                                                                                            issue = "research_later_choice_wait_simultaneous_deadline_unsupported"
                                                                                                                            break
                                                                                                                        }
                                                                                                                        try machine.advanceClickWait(ticks: frameTicks)
                                                                                                                        try machine.advancePlacementClock(ticks: frameTicks)
                                                                                                                        budget = available - frameTicks
                                                                                                                        researchLaterChoiceWaitFrames += 1
                                                                                                                        if machine.ticksUntilTimer == 0 {
                                                                                                                            guard try machine.dispatchDueTimer() else {
                                                                                                                                throw ResourceError.rejected("research_later_choice_wait_timer_dispatch_failed")
                                                                                                                            }
                                                                                                                            researchLaterChoiceWaitTimerCount += 1
                                                                                                                            let (timerSteps, timerIssue) = try advanceObservedSegment(prefix: "zero_draw_audio_later_choice_timer", limit: min(512, maximumDrawFollowthroughSteps - researchDrawAudioFollowthroughSteps))
                                                                                                                            researchDrawAudioFollowthroughSteps += timerSteps
                                                                                                                            issue = timerIssue
                                                                                                                            if issue == nil, machine.phase != .waiting { issue = "research_later_choice_wait_timer_return_unsupported" }
                                                                                                                            if issue == nil, researchLaterChoiceWaitTimerCount >= 16 { issue = "research_later_choice_wait_timer_budget_unsupported" }
                                                                                                                        } else if machine.phase == .ready {
                                                                                                                            researchLaterChoiceWaitCompleted = true
                                                                                                                            let (finishSteps, finishIssue) = try advanceObservedSegment(prefix: "zero_draw_audio_later_choice_wait", limit: min(4096, maximumDrawFollowthroughSteps - researchDrawAudioFollowthroughSteps))
                                                                                                                            researchDrawAudioFollowthroughSteps += finishSteps
                                                                                                                            issue = finishIssue
                                                                                                                            break
                                                                                                                        }
                                                                                                                    }
                                                                                                                    if issue == nil, !researchLaterChoiceWaitCompleted { issue = "research_later_choice_wait_frame_budget_unsupported" }
                                                                                                                }
                                                                                                                try continueLaterUntimedWaits(frameTicks)
                                                                                                                if issue == nil, machine.phase == .waitingForFrame {
                                                                                                                    let beforeFrames = researchDrawFramesAdvanced
                                                                                                                    try continueObservedDrawFrames()
                                                                                                                    researchChoicePostDrawFrames += researchDrawFramesAdvanced - beforeFrames
                                                                                                                }
                                                                                                                let thirdWait = try continueSelectionTimedWait(frameTicks)
                                                                                                                researchThirdWaitCompleted = thirdWait.completed
                                                                                                                researchThirdWaitFrames = thirdWait.frames
                                                                                                                researchThirdWaitTimerCount = thirdWait.timers
                                                                                                                researchThirdWaitZeroFrame = thirdWait.zero
                                                                                                                func dispatchAndFollowChoice() throws -> (dispatched: Bool, frames: Int, timers: Int, completed: Bool) {
                                                                                                                    var choiceDispatched = false
                                                                                                                    var choiceWaitFrames = 0
                                                                                                                    var choiceWaitTimers = 0
                                                                                                                    var choiceWaitCompleted = false
                                                                                                                if issue == nil,
                                                                                                                   machine.isWaitingForStoryChoice, choiceCursor < storyChoices.count,
                                                                                                                   machine.pendingResearchSkipTime == 0,
                                                                                                                   (machine.ticksUntilTimer ?? 1) > 0,
                                                                                                                   researchDrawAudioFollowthroughSteps < maximumDrawFollowthroughSteps,
                                                                                                                   ContinuousClock.now < segmentDeadline {
                                                                                                                    let choiceActive = machine.activeSoundChannels
                                                                                                                    let choiceSnapshots = machine.activeStreamPlaybackSnapshots
                                                                                                                    guard choiceActive.count == choiceSnapshots.count,
                                                                                                                          observer.rejectedControlCount == 0,
                                                                                                                          machine.researchActiveAudioSnapshots == initialAudio,
                                                                                                                          try machine.soundCategoryGains(only: choiceActive) == initialGains,
                                                                                                                          (try? observer.positions(for: choiceSnapshots)) != nil else {
                                                                                                                        throw ResourceError.rejected("research_third_choice_identity_unsupported")
                                                                                                                    }
                                                                                                                    let choice = storyChoices[choiceCursor]
                                                                                                                    try machine.dispatchStoryChoice(choice)
                                                                                                                    FileHandle.standardError.write(Data("story_choice=\(choiceCursor) index=\(choice)\n".utf8))
                                                                                                                    choiceCursor += 1
                                                                                                                    choiceDispatched = true
                                                                                                                    let (choiceSteps, choiceIssue) = try advanceObservedSegment(prefix: "zero_draw_audio_third_choice", limit: min(512, maximumDrawFollowthroughSteps - researchDrawAudioFollowthroughSteps))
                                                                                                                    researchDrawAudioFollowthroughSteps += choiceSteps
                                                                                                                    issue = choiceIssue
                                                                                                                    if issue == nil, machine.phase == .waiting, machine.researchHasActiveTimers {
                                                                                                                        let waitActive = machine.activeSoundChannels
                                                                                                                        let waitSnapshots = machine.activeStreamPlaybackSnapshots
                                                                                                                        guard waitActive.count == waitSnapshots.count,
                                                                                                                              let initialWait = machine.clickWaitRemaining, initialWait > 0,
                                                                                                                              let initialTimer = machine.ticksUntilTimer, initialTimer > 0,
                                                                                                                              machine.pendingResearchSkipTime == 0,
                                                                                                                              observer.rejectedControlCount == 0,
                                                                                                                              machine.researchActiveAudioSnapshots == initialAudio,
                                                                                                                              try machine.soundCategoryGains(only: waitActive) == initialGains,
                                                                                                                              (try? observer.positions(for: waitSnapshots)) != nil else {
                                                                                                                            throw ResourceError.rejected("research_third_choice_wait_initial_unsupported")
                                                                                                                        }
                                                                                                                        if machine.researchZeroWaitClockPending {
                                                                                                                            guard let available = budget, available >= frameTicks else { throw ResourceError.rejected("research_third_choice_wait_zero_budget") }
                                                                                                                            let elapsed = try machine.consumeResearchWaitZeroClock(hostTicks: frameTicks, allowObservedStreams: true, allowObservedTimers: true)
                                                                                                                            guard elapsed == 0 else { throw ResourceError.rejected("research_third_choice_wait_zero_nonzero") }
                                                                                                                            try machine.advanceClickWait(ticks: 0)
                                                                                                                            try machine.advancePlacementClock(ticks: 0)
                                                                                                                            budget = available - frameTicks
                                                                                                                            guard machine.clickWaitRemaining == initialWait, machine.ticksUntilTimer == initialTimer else { throw ResourceError.rejected("research_third_choice_wait_zero_changed") }
                                                                                                                        }
                                                                                                                        while choiceWaitFrames < 1024, issue == nil {
                                                                                                                            try machine.validateResearchChoiceWaitClock()
                                                                                                                            guard ContinuousClock.now < segmentDeadline,
                                                                                                                                  researchDrawAudioFollowthroughSteps < maximumDrawFollowthroughSteps,
                                                                                                                                  let remaining = machine.clickWaitRemaining, remaining >= frameTicks,
                                                                                                                                  let nextTimer = machine.ticksUntilTimer, nextTimer >= frameTicks,
                                                                                                                                  let available = budget, available >= frameTicks,
                                                                                                                                  machine.activeSoundChannels == waitActive,
                                                                                                                                  machine.researchActiveAudioSnapshots == initialAudio,
                                                                                                                                  try machine.soundCategoryGains(only: waitActive) == initialGains,
                                                                                                                                  observer.rejectedControlCount == 0,
                                                                                                                                  (try? observer.positions(for: waitSnapshots)) != nil else {
                                                                                                                                issue = "research_third_choice_wait_frame_outside_profile"
                                                                                                                                break
                                                                                                                            }
                                                                                                                            if nextTimer == remaining { issue = "research_third_choice_wait_simultaneous_deadline_unsupported"; break }
                                                                                                                            try machine.advanceClickWait(ticks: frameTicks)
                                                                                                                            try machine.advancePlacementClock(ticks: frameTicks)
                                                                                                                            budget = available - frameTicks
                                                                                                                            choiceWaitFrames += 1
                                                                                                                            if machine.ticksUntilTimer == 0 {
                                                                                                                                guard try machine.dispatchDueTimer() else { throw ResourceError.rejected("research_third_choice_wait_timer_dispatch_failed") }
                                                                                                                                choiceWaitTimers += 1
                                                                                                                                let (timerSteps, timerIssue) = try advanceObservedSegment(prefix: "zero_draw_audio_third_choice_timer", limit: min(512, maximumDrawFollowthroughSteps - researchDrawAudioFollowthroughSteps))
                                                                                                                                researchDrawAudioFollowthroughSteps += timerSteps
                                                                                                                                issue = timerIssue
                                                                                                                                if issue == nil, machine.phase != .waiting { issue = "research_third_choice_wait_timer_return_unsupported" }
                                                                                                                                if issue == nil, choiceWaitTimers >= 16 { issue = "research_third_choice_wait_timer_budget_unsupported" }
                                                                                                                            } else if machine.phase == .ready {
                                                                                                                                choiceWaitCompleted = true
                                                                                                                                let (finishSteps, finishIssue) = try advanceObservedSegment(prefix: "zero_draw_audio_third_choice_wait", limit: min(4096, maximumDrawFollowthroughSteps - researchDrawAudioFollowthroughSteps))
                                                                                                                                researchDrawAudioFollowthroughSteps += finishSteps
                                                                                                                                issue = finishIssue
                                                                                                                                break
                                                                                                                            }
                                                                                                                        }
                                                                                                                        if issue == nil, !choiceWaitCompleted { issue = "research_third_choice_wait_frame_budget_unsupported" }
                                                                                                                    }
                                                                                                                }
                                                                                                                    return (choiceDispatched, choiceWaitFrames, choiceWaitTimers, choiceWaitCompleted)
                                                                                                                }
                                                                                                                if researchThirdWaitCompleted {
                                                                                                                    let thirdChoice = try dispatchAndFollowChoice()
                                                                                                                    researchThirdChoiceDispatched = thirdChoice.dispatched
                                                                                                                    researchThirdChoiceWaitFrames = thirdChoice.frames
                                                                                                                    researchThirdChoiceWaitTimers = thirdChoice.timers
                                                                                                                    researchThirdChoiceWaitCompleted = thirdChoice.completed
                                                                                                                    if issue == nil, researchThirdChoiceWaitCompleted {
                                                                                                                        let beforeFrames = researchLaterPostWaitFrames
                                                                                                                        let beforeCompleted = researchLaterPostWaitCompletedCount
                                                                                                                        try continueLaterUntimedWaits(frameTicks)
                                                                                                                        researchThirdPostWaitFrames = researchLaterPostWaitFrames - beforeFrames
                                                                                                                        researchThirdPostWaitCompleted = researchLaterPostWaitCompletedCount - beforeCompleted
                                                                                                                        let fourthWait = try continueSelectionTimedWait(frameTicks)
                                                                                                                        researchFourthWaitCompleted = fourthWait.completed
                                                                                                                        researchFourthWaitFrames = fourthWait.frames
                                                                                                                        researchFourthWaitTimerCount = fourthWait.timers
                                                                                                                        researchFourthWaitZeroFrame = fourthWait.zero
                                                                                                                        if fourthWait.completed {
                                                                                                                            let fourthChoice = try dispatchAndFollowChoice()
                                                                                                                            researchFourthChoiceDispatched = fourthChoice.dispatched
                                                                                                                            researchFourthChoiceWaitFrames = fourthChoice.frames
                                                                                                                            researchFourthChoiceWaitTimers = fourthChoice.timers
                                                                                                                            researchFourthChoiceWaitCompleted = fourthChoice.completed
                                                                                                                            if issue == nil, fourthChoice.completed {
                                                                                                                                let beforeFrames = researchLaterPostWaitFrames
                                                                                                                                let beforeCompleted = researchLaterPostWaitCompletedCount
                                                                                                                                try continueLaterUntimedWaits(frameTicks)
                                                                                                                                researchFourthPostWaitFrames = researchLaterPostWaitFrames - beforeFrames
                                                                                                                                researchFourthPostWaitCompleted = researchLaterPostWaitCompletedCount - beforeCompleted
                                                                                                                            }
                                                                                                                        }
                                                                                                                    }
                                                                                                                }
                                                                                                            }
                                                                                                            if issue == nil, researchTitleStartAfterReturn,
                                                                                                               researchWindowSkipDispatched, startedFromTitle,
                                                                                                               choiceCursor == storyChoices.count,
                                                                                                               machine.phase == .waitingForEvent, machine.canStartFromTitle,
                                                                                                               !machine.isWaitingForStoryChoice,
                                                                                                               machine.pendingResearchSkipTime == 0,
                                                                                                               !machine.researchZeroWaitClockPending,
                                                                                                               !machine.researchHasActiveTimers,
                                                                                                               researchDrawAudioFollowthroughSteps < maximumDrawFollowthroughSteps,
                                                                                                               ContinuousClock.now < segmentDeadline {
                                                                                                                let active = machine.activeSoundChannels
                                                                                                                let snapshots = machine.activeStreamPlaybackSnapshots
                                                                                                                guard active.count == snapshots.count,
                                                                                                                      observer.rejectedControlCount == 0,
                                                                                                                      machine.researchActiveAudioSnapshots == initialAudio,
                                                                                                                      try machine.soundCategoryGains(only: active) == initialGains,
                                                                                                                      (try? observer.positions(for: snapshots)) != nil,
                                                                                                                      let handle = machine.titleStartButton,
                                                                                                                      let index = machine.titleButtons[handle],
                                                                                                                      let layer = machine.staticImageLayers.first(where: { $0.id == handle }) else {
                                                                                                                    throw ResourceError.rejected("research_returned_title_start_identity_unsupported")
                                                                                                                }
                                                                                                                researchReturnedTitleObserved = true
                                                                                                                try machine.dispatchStopCallback(pointer: (layer.x, layer.y), buttonIndex: index, click: true)
                                                                                                                researchReturnedTitleStartDispatched = true
                                                                                                                let (steps, startIssue) = try advanceObservedSegment(prefix: "research_returned_title_start", limit: min(4096, maximumDrawFollowthroughSteps - researchDrawAudioFollowthroughSteps))
                                                                                                                researchReturnedTitleStartSteps = steps
                                                                                                                researchDrawAudioFollowthroughSteps += steps
                                                                                                                researchReturnedTitleStartPhase = machine.phase.rawValue
                                                                                                                issue = startIssue
                                                                                                                if issue == nil, machine.phase == .waiting, !machine.researchHasActiveTimers {
                                                                                                                    guard let frameTicks = researchDrawFrameTicks else { throw ResourceError.rejected("research_returned_title_frame_ticks_missing") }
                                                                                                                    let beforeFrames = researchLaterPostWaitFrames
                                                                                                                    let beforeCompleted = researchLaterPostWaitCompletedCount
                                                                                                                    try continueLaterUntimedWaits(frameTicks)
                                                                                                                    researchReturnedTitlePostWaitFrames = researchLaterPostWaitFrames - beforeFrames
                                                                                                                    researchReturnedTitlePostWaitCompleted = researchLaterPostWaitCompletedCount - beforeCompleted
                                                                                                                    researchReturnedTitleAfterWaitPhase = machine.phase.rawValue
                                                                                                                    let resumedWait = try continueSelectionTimedWait(frameTicks)
                                                                                                                    researchRestartSelectionWaitCompleted = resumedWait.completed
                                                                                                                    researchRestartSelectionWaitFrames = resumedWait.frames
                                                                                                                    researchRestartSelectionWaitTimers = resumedWait.timers
                                                                                                                    researchRestartSelectionWaitZeroFrame = resumedWait.zero
                                                                                                                }
                                                                                                            }
                                                                                                            if issue == nil { issue = "research_later_wait_followup_stopped" }
                                                                                                            break
                                                                                                        }
                                                                                                    }
                                                                                                    if issue == nil { issue = "research_later_wait_frame_budget_unsupported" }
                                                                                                }
                                                                                                if issue == nil, machine.phase == .waiting,
                                                                                                   !machine.researchHasActiveTimers,
                                                                                                   !machine.researchZeroWaitClockPending,
                                                                                                   researchChoicePostWaitCompletedCount < 4 {
                                                                                                    continue
                                                                                                }
                                                                                                if issue == nil { issue = "research_post_choice_wait_followup_unsupported" }
                                                                                                break
                                                                                            }
                                                                                        }
                                                                                        if issue == nil { issue = "research_post_choice_wait_frame_budget_unsupported" }
                                                                                    }
                                                                                    if issue == nil { issue = "research_choice_wait_followup_unsupported" }
                                                                                }
                                                                            }
                                                                            if issue == nil { issue = "research_choice_wait_frame_budget_unsupported" }
                                                                        }
                                                                        if issue == nil { issue = "research_story_choice_followup_unsupported" }
                                                                    }
                                                                    if issue == nil { issue = "research_wait_complete_followup_unsupported" }
                                                                    break
                                                                }
                                                            }
                                                            if issue == nil { issue = "research_timer_frame_budget_unsupported" }
                                                        }
                                                    } catch ResourceError.rejected(let failure) {
                                                        issue = failure
                                                    }
                                                }
                                                if researchZeroAudioDrawFrame, issue == nil,
                                                   machine.isResearchMessageTextWait,
                                                   machine.pendingResearchSkipTime == 0,
                                                   !machine.researchZeroWaitClockPending,
                                                   machine.ticksUntilTimer == nil,
                                                   researchDrawAudioFollowthroughSteps < maximumDrawFollowthroughSteps,
                                                   ContinuousClock.now < segmentDeadline {
                                                    let active = machine.activeSoundChannels
                                                    let snapshots = machine.activeStreamPlaybackSnapshots
                                                    if active.count == snapshots.count, observer.rejectedControlCount == 0,
                                                       machine.researchActiveAudioSnapshots == initialAudio,
                                                       try machine.soundCategoryGains(only: active) == initialGains,
                                                       (try? observer.positions(for: snapshots)) != nil {
                                                        try machine.dispatchStopCallback()
                                                        researchDrawEventCallbackDispatched = true
                                                        let (steps, nextIssue) = try advanceObservedSegment(prefix: "zero_draw_audio_event", limit: min(512, maximumDrawFollowthroughSteps - researchDrawAudioFollowthroughSteps))
                                                        researchDrawAudioFollowthroughSteps += steps
                                                        issue = nextIssue
                                                    } else {
                                                        issue = "zero_draw_audio_event_identity_unsupported"
                                                    }
                                                }
                                                if researchZeroAudioDrawFrame, issue == nil {
                                                    issue = "zero_draw_audio_\(machine.phase.rawValue)_unsupported"
                                                }
                                                researchHostIssue = machine.phase == .stopped ? (machine.stopReason ?? "zero_followthrough_stopped") :
                                                    (issue ?? (machine.phase == .ready
                                                        ? (researchZeroFollowthroughSteps >= 512 ? "zero_followthrough_step_limit" : "zero_followthrough_pending_clock_unsupported")
                                                        : "zero_followthrough_\(machine.phase.rawValue)_unsupported"))
                                            }
                                            break
                                        }
                                        if machine.phase == .ready { setHostContinuationStart(); try machine.run(stepQuota: maximumSteps ?? 10_000) }
                                        continue
                                    }
                                    let zeroLiveFramesBefore = researchZeroLiveAudioFrames
                                    var delta = min(available, request.duration, machine.ticksUntilTimer ?? request.duration)
                                    var waitTicks = delta
                                    if researchSkipTime && machine.researchZeroWaitClockPending && delta > 0 {
                                        guard let quantum = researchDrawFrameTicks else {
                                            researchHostIssue = "zero_clock_requires_explicit_frame_ticks"
                                            break
                                        }
                                        delta = min(delta, quantum)
                                        do {
                                            let positions = try checkedResearchZeroAudioPositions()
                                            waitTicks = try machine.consumeResearchWaitZeroClock(hostTicks: delta,
                                                allowObservedStreams: positions != nil)
                                            if let positions {
                                                researchZeroLiveAudioFrames += 1
                                                researchZeroLiveAudioPositions = positions
                                            }
                                        } catch ResourceError.rejected(let issue) where issue.hasPrefix("zero_clock_") {
                                            researchHostIssue = issue
                                            break
                                        }
                                    }
                                    if researchZeroLiveAudioFrames > 0 && waitTicks > 0 && !machine.activeSoundChannels.isEmpty {
                                        researchHostIssue = "zero_live_audio_positive_frame_unsupported"
                                        break
                                    }
                                    try machine.advanceTimedStop(ticks: waitTicks)
                                    try machine.advancePlacementClock(ticks: waitTicks)
                                    budget = available - delta
                                    if researchZeroLiveAudioFrames > zeroLiveFramesBefore {
                                        researchHostIssue = "zero_live_audio_followup_unsupported"
                                        break
                                    }
                                    if machine.phase != .ready && delta > 0 { continue }
                                } else if let remaining = machine.movieStopRemaining {
                                    if remaining > 0 {
                                        guard let available = budget, available > 0 else { break }
                                        let delta = min(available, remaining, machine.ticksUntilTimer ?? remaining)
                                        try machine.advancePlacementClock(ticks: delta)
                                        budget = available - delta
                                        continue
                                    }
                                    try machine.dispatchStopCallback(pointer: pointer)
                                } else if machine.isWaitingForStoryChoice {
                                    // A direct gallery replay may supply choices only
                                    // after both memory-menu actions completed.
                                    guard titleMenuTarget == nil || requireRouteReturn ||
                                        (titleMenuTarget == "memory" && titleMenuActions.count == 2) else { break }
                                    if requireRouteReturn {
                                        let available = machine.availableStoryChoices.map(String.init).joined(separator: ",")
                                        let receipt = "story_choice_available=\(choiceCursor) indices=\(available)\n"
                                        FileHandle.standardError.write(Data(receipt.utf8))
                                    }
                                    guard choiceCursor < storyChoices.count else { break }
                                    let choice = storyChoices[choiceCursor]
                                    try machine.dispatchStoryChoice(choice)
                                    let receipt = "story_choice=\(choiceCursor) index=\(choice)\n"
                                    FileHandle.standardError.write(Data(receipt.utf8))
                                    choiceCursor += 1
                                } else if let target = titleMenuTarget, titleMenuActions.count < 2,
                                          (!requireRouteReturn || routeTitleReachedBeforeMenu),
                                          !machine.titleButtons.isEmpty {
                                    let requested = titleMenuActions.isEmpty ? "@@!extra" : "@@!\(target)mode"
                                    let matches = machine.titleButtons.filter { machine.titleButtonTarget($0.key) == requested }
                                    guard matches.count == 1, let button = matches.first,
                                          let layer = machine.staticImageLayers.first(where: { $0.id == button.key }) else {
                                        titleMenuIssue = "title_menu_target_unavailable: \(requested)"
                                        break
                                    }
                                    try machine.dispatchStopCallback(pointer: (layer.x, layer.y), buttonIndex: button.value, click: true)
                                    titleMenuActions.append(requested)
                                    pendingDispatch = false
                                    pendingScopedDispatch = false
                                } else if startFromTitle, !startedFromTitle, machine.canStartFromTitle {
                                    guard let handle = machine.titleStartButton, let index = machine.titleButtons[handle],
                                          let layer = machine.staticImageLayers.first(where: { $0.id == handle }) else {
                                        throw ResourceError.rejected("title_start_button_unavailable")
                                    }
                                    try machine.dispatchStopCallback(pointer: (layer.x, layer.y), buttonIndex: index, click: true)
                                    startedFromTitle = true
                                    routeStartedForMenu = requireRouteReturn
                                } else if openTitleLoad, !openedTitleLoad, machine.canStartFromTitle {
                                    let matches = machine.titleButtons.filter { machine.titleButtonTarget($0.key) == "@@!load" }
                                    guard matches.count == 1, let button = matches.first else {
                                        throw ResourceError.rejected("title_load_button_not_unique")
                                    }
                                    try machine.dispatchStopCallback(pointer: pointer, buttonIndex: button.value, click: true)
                                    openedTitleLoad = true
                                } else if researchWindowAuto, startedFromTitle, !researchWindowAutoDispatched,
                                          let handle = machine.researchWindowAutoButton {
                                    researchWindowAutoModeBefore = machine.researchMessageWaitPlayMode
                                    try machine.dispatchResearchWindowAutoButton(handle)
                                    researchWindowAutoDispatched = true
                                    setHostContinuationStart(); try machine.run(stepQuota: maximumSteps ?? 10_000)
                                    researchWindowAutoModeAfter = machine.researchMessageWaitPlayMode
                                    continue
                                } else if researchWindowSkip, startedFromTitle, !researchWindowSkipDispatched,
                                          let handle = machine.researchWindowSkipButton {
                                    try machine.dispatchResearchWindowSkipButton(handle)
                                    researchWindowSkipDispatched = true
                                    if researchSkipTime { machine.researchStopAtDrawBoundary = true }
                                } else if machine.phase == .waitingForEvent, pendingDispatch {
                                    guard researchStopCallbackTicks == nil || machine.timedStopRequest == nil else {
                                        throw ResourceError.rejected("research_stop_callback_ticks_require_untimed_stop")
                                    }
                                    if researchZeroEventCallback && researchZeroEventWaitLocation == nil {
                                        researchZeroEventWaitLocation = machine.playbackStatus.currentLocation
                                        researchZeroEventCallbackLocation = machine.researchStopCallbackLocation
                                    }
                                    try machine.dispatchStopCallback(pointer: pointer,buttonIndex: buttonIndex,buttonArray: buttonArray ?? "Button", elapsedTicks: researchStopCallbackTicks ?? 0)
                                    pendingDispatch = false
                                } else if machine.phase == .waitingForEvent, subsequentButtonCursor < subsequentButtons.count,
                                          (!researchBarBeforeSubsequentButtons || syntheticBarEventConsumed),
                                          (!researchZeroEventCallback || (!machine.isResearchMessageTextWait &&
                                            researchZeroEventWaitLocation != nil && researchZeroEventCallbackLocation != nil &&
                                            machine.playbackStatus.currentLocation == researchZeroEventWaitLocation &&
                                            machine.researchStopCallbackLocation == researchZeroEventCallbackLocation)),
                                          titleMenuTarget == nil || titleMenuActions.count == 2 {
                                    let next = subsequentButtons[subsequentButtonCursor]
                                    let site = machine.playbackStatus.currentLocation
                                    try machine.dispatchStopCallback(pointer: pointer, buttonIndex: next.index, buttonArray: next.array)
                                    if researchZeroEventCallback, let site { researchSubsequentButtonSites.append(site) }
                                    subsequentButtonCursor += 1
                                } else if machine.phase == .waitingForEvent, let event = syntheticBarEvent, !syntheticBarEventConsumed {
                                    if researchBarBeforeSubsequentButtons {
                                        guard researchZeroEventWaitLocation != nil && researchZeroEventCallbackLocation != nil &&
                                            machine.playbackStatus.currentLocation == researchZeroEventWaitLocation &&
                                            machine.researchStopCallbackLocation == researchZeroEventCallbackLocation else {
                                            throw ResourceError.rejected("bar_event_wait_site_mismatch")
                                        }
                                        researchBarEventSite = machine.playbackStatus.currentLocation
                                    }
                                    try machine.dispatchSyntheticBarChange(name: event.name, value: event.value,
                                        objectUpdates: researchBarObjectUpdates ?? 0)
                                    syntheticBarEventConsumed = true
                                } else if machine.phase == .waitingForEvent, let event = syntheticBarAxis, !syntheticBarEventConsumed {
                                    if researchBarBeforeSubsequentButtons {
                                        guard researchZeroEventWaitLocation != nil && researchZeroEventCallbackLocation != nil &&
                                            machine.playbackStatus.currentLocation == researchZeroEventWaitLocation &&
                                            machine.researchStopCallbackLocation == researchZeroEventCallbackLocation else {
                                            throw ResourceError.rejected("bar_event_wait_site_mismatch")
                                        }
                                        researchBarEventSite = machine.playbackStatus.currentLocation
                                    }
                                    if let point = syntheticBarPoint {
                                        let x = [point[2], point[4], point[6], point[8]].map(Float.init)
                                        let y = [point[3], point[5], point[7], point[9]].map(Float.init)
                                        guard BarHitGeometry.contains(x: Float(point[0]), y: Float(point[1]),
                                                                      vertexX: x, vertexY: y) == true else {
                                            throw ResourceError.rejected("synthetic_bar_point_outside_candidate")
                                        }
                                    }
                                    let bar = try machine.unrenderedBarSnapshot(named: event.name)
                                    guard bar.resources[0] == nil, let track = bar.resources[1], track.byteOffset == 0,
                                          track.byteLength <= 4 * 1024 * 1024, track.sourceSHA256 == track.rangeSHA256,
                                          bar.placement.count == 3 else {
                                        throw ResourceError.rejected("synthetic_bar_axis_track_unavailable")
                                    }
                                    let data = try directory.read(track.sourceFile, limit: 4 * 1024 * 1024)
                                    guard data.count == track.byteLength, data.sha256Hex == track.sourceSHA256,
                                          let canvas = imageRecipe.motionCanvasInputs(track),
                                          let geometry = BarPointerGeometry(knobLength: 0, trackLength: canvas.width, maximum: bar.maximum),
                                          let value = geometry.value(pointer: event.position, origin: bar.placement[0], rounding: event.rounding) else {
                                        throw ResourceError.rejected("synthetic_bar_axis_geometry_unavailable")
                                    }
                                    if let pointY = syntheticBarResourceY {
                                        guard !bar.locked, bar.placementSet, imageRecipe.motionNames(track) ==
                                                ["*Enable", "*OffMouse", "*OnMouse", "*OnMouseDown", "*OnLock"] else {
                                            throw ResourceError.rejected("synthetic_bar_resource_region_profile_unsupported")
                                        }
                                        var agreed: (x: [Float], y: [Float])?
                                        for index in 0..<4 {
                                            guard let keys = imageRecipe.motionKeys(track, selectedMember: Int32(index), time: 0),
                                                  keys.count(where: { $0.type == 6 }) == 1,
                                                  let key = keys.first(where: { $0.type == 6 }),
                                                  let region = imageRecipe.identityHostType6RegionCandidate(key,
                                                    origin: SIMD2(bar.placement[0], bar.placement[1])) else {
                                                throw ResourceError.rejected("synthetic_bar_resource_region_unavailable")
                                            }
                                            if let agreed, agreed.x != region.x || agreed.y != region.y {
                                                throw ResourceError.rejected("synthetic_bar_resource_regions_differ")
                                            }
                                            agreed = region
                                        }
                                        guard let region = agreed,
                                              BarHitGeometry.contains(x: Float(event.position), y: Float(pointY),
                                                vertexX: region.x, vertexY: region.y) == true else {
                                            throw ResourceError.rejected("synthetic_bar_resource_point_outside_candidate")
                                        }
                                        syntheticBarResourceQuad = zip(region.x, region.y).flatMap { [$0.0, $0.1] }
                                    }
                                    try machine.dispatchSyntheticBarChange(name: event.name, value: value,
                                        pointer: syntheticBarPointerInput ? pointer : nil,
                                        objectUpdates: researchBarObjectUpdates ?? 0)
                                    syntheticBarAxisValue = value
                                    syntheticBarEventConsumed = true
                                } else if machine.hasScopedStop, pendingScopedDispatch {
                                    try machine.dispatchStopCallback(pointer: pointer)
                                    pendingScopedDispatch = false
                                } else if dispatchStop, try machine.commitHeadlessMessageOutput() {
                                    if researchStopAtRuby, machine.messageTextLayers.contains(where: { layer in
                                        layer.isVisible && layer.runs.contains(where: { $0.ruby != nil })
                                    }) {
                                        researchRubyStopReached = true
                                        break
                                    }
                                    try machine.dispatchStopCallback(pointer: pointer)
                                } else if machine.hasScopedStop, pendingMessageClicks > 0,
                                          titleMenuTarget == nil || requireRouteReturn || titleMenuActions.count == 2 {
                                    if stopAfterStoryChoices && choiceCursor == storyChoices.count { break }
                                    try machine.dispatchStopCallback(pointer: pointer, click: true)
                                    pendingMessageClicks -= 1
                                } else { break }
                                guard machine.phase == .ready else { break }
                                setHostContinuationStart(preservingAudioHandoff: resumedSoundPlayback); try machine.run(stepQuota: maximumSteps ?? 10_000)
                            }
                        }
                        try runHost()
                        var autoFrameCount: Int?
                        var autoFrameIssue: String?
                        var autoFrameInitialSteps: Int?
                        var autoFramePlayObserved: Bool?
                        var autoFrameAudioBefore: [Int32: Int32]?
                        var autoFrameAudioAfter: [Int32: Int32]?
                        var autoFrameElapsedTicks: [Int32] = []
                        var autoAudioPositionRetries = 0
                        var autoAudioCompletionWaits = 0
                        func checkAutoFrameHost() throws -> String? {
                            if machine.researchHasActiveTimers { return "active_timer_not_advanced" }
                            let active = machine.activeSoundChannels
                            guard !active.isEmpty else { return nil }
                            guard let observer = liveAudioObserver else { return "active_sound_not_observed" }
                            try observer.synchronizeControls(machine: &machine)
                            let remaining = machine.activeSoundChannels
                            let snapshots = machine.activeStreamPlaybackSnapshots
                            guard snapshots.count == remaining.count, observer.rejectedControlCount == 0 else {
                                return "active_sound_identity_or_control_unsupported"
                            }
                            let positions: [Int32: Int32]
                            do {
                                positions = try observer.positions(for: snapshots)
                            } catch ResourceError.rejected(let issue) where issue == "live_audio_playback_identity_or_state_mismatch" {
                                autoAudioPositionRetries += 1
                                if try observer.awaitStoppedCompletion(for: snapshots) {
                                    autoAudioCompletionWaits += 1
                                }
                                try observer.synchronizeControls(machine: &machine)
                                let refreshed = machine.activeStreamPlaybackSnapshots
                                guard refreshed.count == machine.activeSoundChannels.count,
                                      observer.rejectedControlCount == 0 else {
                                    return "active_sound_identity_or_control_unsupported"
                                }
                                positions = try observer.positions(for: refreshed)
                            }
                            if autoFrameAudioBefore == nil { autoFrameAudioBefore = positions }
                            autoFrameAudioAfter = positions
                            return nil
                        }
                        if let ticks = researchAutoFrameTicks {
                            autoFrameCount = 0
                            autoFrameInitialSteps = machine.playbackStatus.steps
                            autoFramePlayObserved = false
                            if !researchWindowAutoDispatched || machine.researchMessageWaitPlayMode != 2 {
                                autoFrameIssue = "auto_mode_not_enabled"
                            } else if !machine.isResearchMessageAutoWait {
                                autoFrameIssue = "auto_wait_not_reached"
                            } else if let issue = try checkAutoFrameHost() {
                                autoFrameIssue = issue
                            } else {
                                var previousFrameTime = DispatchTime.now().uptimeNanoseconds
                                for _ in 0..<16 {
                                    guard machine.isResearchMessageAutoWait else {
                                        autoFrameIssue = "auto_wait_or_host_state_changed"
                                        break
                                    }
                                    var elapsedTicks = ticks
                                    if researchAutoRealtime {
                                        Thread.sleep(forTimeInterval: Double(ticks) / 1000)
                                        let now = DispatchTime.now().uptimeNanoseconds
                                        let elapsed = (now - previousFrameTime) / 1_000_000
                                        guard (1...1000).contains(elapsed) else {
                                            autoFrameIssue = "auto_realtime_elapsed_outside_profile"
                                            break
                                        }
                                        elapsedTicks = ScriptFrameClock.elapsedMilliseconds(
                                            current: UInt32(truncatingIfNeeded: now / 1_000_000),
                                            previous: UInt32(truncatingIfNeeded: previousFrameTime / 1_000_000))
                                        previousFrameTime = now
                                    }
                                    if let issue = try checkAutoFrameHost() {
                                        autoFrameIssue = issue
                                        break
                                    }
                                    try machine.dispatchStopCallback(elapsedTicks: elapsedTicks)
                                    autoFrameElapsedTicks.append(elapsedTicks)
                                    autoFrameCount! += 1
                                    var callbackSteps = 0
                                    while machine.phase == .ready && machine.researchStopCallbackRunning && callbackSteps < 10_000 {
                                        if machine.step()?.action == "stop_callback_play_candidate" {
                                            autoFramePlayObserved = true
                                        }
                                        callbackSteps += 1
                                    }
                                    guard !machine.researchStopCallbackRunning else {
                                        autoFrameIssue = "auto_callback_not_completed"
                                        break
                                    }
                                    if autoFramePlayObserved == true {
                                        if machine.phase == .ready { try machine.run(stepQuota: maximumSteps ?? 10_000) }
                                        break
                                    }
                                }
                                if autoFrameCount == 16 && autoFramePlayObserved == false && autoFrameIssue == nil {
                                    autoFrameIssue = "auto_frame_limit_reached"
                                }
                            }
                        }
                        func sampleAdditionalAutoLine(ticks: Int32) throws -> HeadlessReplayBudget.ResearchAutoFollowthrough {
                                var line = HeadlessReplayBudget.ResearchAutoFollowthrough(textWaitStartStep: machine.playbackStatus.steps)
                                guard autoFramePlayObserved == true, machine.isResearchMessageTextWait,
                                      pendingMessageClicks == 0, machine.researchMessageWaitPlayMode == 2 else {
                                    line.issue = machine.timedStopRequest != nil
                                        ? "timed_stop_wait_requires_explicit_followthrough"
                                        : "text_wait_or_unconsumed_input_outside_profile"
                                    return line
                                }
                                try runHost()
                                guard researchHostIssue == nil, machine.isResearchMessageAutoWait,
                                      machine.researchMessageWaitPlayMode == 2 else {
                                    line.issue = researchHostIssue ?? "next_auto_wait_not_reached"
                                    line.endStep = machine.playbackStatus.steps
                                    line.endLocation = machine.playbackStatus.currentLocation
                                    return line
                                }
                                line.autoWaitStartStep = machine.playbackStatus.steps
                                line.observedAudioCompletionsBefore = liveAudioObserver?.completedPlaybackCount
                                let completionStart = liveAudioObserver?.completedPlaybackEvents.count ?? 0
                                var previousFrameTime = DispatchTime.now().uptimeNanoseconds
                                let lineDeadline = ContinuousClock.now.advanced(by: .seconds(15))
                                for _ in 0..<64 {
                                    if ContinuousClock.now >= lineDeadline { line.issue = "auto_line_time_limit"; break }
                                    guard machine.isResearchMessageAutoWait else {
                                        line.issue = "auto_wait_or_host_state_changed"
                                        break
                                    }
                                    Thread.sleep(forTimeInterval: Double(ticks) / 1000)
                                    let now = DispatchTime.now().uptimeNanoseconds
                                    let elapsed = (now - previousFrameTime) / 1_000_000
                                    guard (1...1000).contains(elapsed) else {
                                        line.issue = "auto_realtime_elapsed_outside_profile"
                                        break
                                    }
                                    let guestTicks = ScriptFrameClock.elapsedMilliseconds(
                                        current: UInt32(truncatingIfNeeded: now / 1_000_000),
                                        previous: UInt32(truncatingIfNeeded: previousFrameTime / 1_000_000))
                                    previousFrameTime = now
                                    if let issue = try checkAutoFrameHost() { line.issue = issue; break }
                                    try machine.dispatchStopCallback(elapsedTicks: guestTicks)
                                    line.elapsedTicks.append(guestTicks)
                                    var callbackSteps = 0
                                    while machine.phase == .ready && machine.researchStopCallbackRunning && callbackSteps < 10_000 {
                                        let stream = machine.researchStreamScopeObservation
                                        let trace = machine.step()
                                        if trace?.action == "sound_play_status_query_candidate" {
                                            line.soundStatusQueryCount += 1
                                            if let stream, let trace, line.streamStatusSamples.count < 64 {
                                                line.streamStatusSamples.append(.init(step: trace.sequence, location: trace.location, stream: stream))
                                            }
                                        }
                                        if trace?.action == "stop_callback_play_candidate" {
                                            line.playObserved = true
                                            line.observedAudioCompletionsAtPlay = liveAudioObserver?.completedPlaybackCount
                                            if let observer = liveAudioObserver {
                                                line.audioCompletionEvents = Array(observer.completedPlaybackEvents.dropFirst(completionStart))
                                                let snapshots = machine.activeStreamPlaybackSnapshots
                                                if let positions = try? observer.positions(for: snapshots) {
                                                    line.observedStreamsAtPlay = snapshots.compactMap { handle, snapshot in
                                                        guard let index = ScriptMachine.streamSaveChannelIndex(handle),
                                                              let position = positions[index] else { return nil }
                                                        return .init(channel: index, playbackStartStep: snapshot.step,
                                                                     source: snapshot.source, positionMilliseconds: position)
                                                    }.sorted { $0.channel < $1.channel }
                                                }
                                            }
                                        }
                                        callbackSteps += 1
                                    }
                                    guard !machine.researchStopCallbackRunning else {
                                        line.issue = "auto_callback_not_completed"
                                        break
                                    }
                                    if line.playObserved {
                                        if machine.phase == .ready {
                                            line.continuationStartStep = machine.playbackStatus.steps
                                            try machine.run(stepQuota: maximumSteps ?? 10_000)
                                        }
                                        break
                                    }
                                }
                                if line.elapsedTicks.count == 64 && !line.playObserved && line.issue == nil {
                                    line.issue = "auto_frame_limit_reached"
                                }
                                if line.playObserved {
                                    for _ in 0..<4 {
                                        if machine.phase == .waitingForMedia && machine.soundPlaybackRequest != nil {
                                            line.mediaHandoffAttempted = true
                                            autoTimedMediaHandoffCompleted = false
                                            autoTimedMediaContinuationStart = nil
                                            stopAfterAutoTimedMediaHandoff = true
                                            try runHost()
                                            stopAfterAutoTimedMediaHandoff = false
                                            line.mediaHandoffCompleted = autoTimedMediaHandoffCompleted
                                            guard autoTimedMediaHandoffCompleted else {
                                                line.issue = researchHostIssue ?? "auto_media_handoff_not_completed"
                                                break
                                            }
                                            line.mediaHandoffCount += 1
                                            line.continuationStartStep = autoTimedMediaContinuationStart
                                        } else if machine.phase == .waitingForSoundSwap && machine.soundSwapRequest != nil {
                                            autoTimedSoundSwapCompleted = false
                                            autoTimedSoundSwapContinuationStart = nil
                                            stopAfterAutoTimedSoundSwap = true
                                            try runHost()
                                            stopAfterAutoTimedSoundSwap = false
                                            guard autoTimedSoundSwapCompleted else {
                                                line.issue = researchHostIssue ?? "auto_sound_swap_not_completed"
                                                break
                                            }
                                            line.soundSwapCount += 1
                                            line.continuationStartStep = autoTimedSoundSwapContinuationStart
                                        } else { break }
                                    }
                                    if line.issue == nil && ((machine.phase == .waitingForMedia && machine.soundPlaybackRequest != nil) ||
                                        (machine.phase == .waitingForSoundSwap && machine.soundSwapRequest != nil)) {
                                        line.issue = "auto_audio_handoff_limit_reached"
                                    }
                                }
                                line.endStep = machine.playbackStatus.steps
                                line.endLocation = machine.playbackStatus.currentLocation
                                return line
                        }
                        var autoAdditionalLines: [HeadlessReplayBudget.ResearchAutoFollowthrough] = []
                        if let count = researchAutoAdditionalLines, let ticks = researchAutoFrameTicks {
                            for _ in 0..<count {
                                let line = try sampleAdditionalAutoLine(ticks: ticks)
                                autoAdditionalLines.append(line)
                                if !line.playObserved || line.issue != nil { break }
                            }
                        }
                        func sampleAutoTimedWait(ticks: Int32, continuationStart: inout Int?,
                                                 precedingPlayObserved: Bool) throws -> HeadlessReplayBudget.ResearchAutoTimedWait {
                            autoTimedMediaHandoffCompleted = false
                            autoTimedMediaContinuationStart = nil
                            autoTimedSoundSwapCompleted = false
                            autoTimedSoundSwapContinuationStart = nil
                            var sample = HeadlessReplayBudget.ResearchAutoTimedWait(
                                initialDuration: machine.timedStopRequest?.duration,
                                initialAlternateDuration: machine.timedStopRequest?.alternateDuration)
                            if !precedingPlayObserved || !machine.isResearchMessageClickTimedWait ||
                                (machine.timedStopRequest?.duration ?? -1) <= 0 || pendingMessageClicks != 0 {
                                sample.issue = "finite_click_timed_wait_not_reached"
                            } else {
                                var previousFrameTime = DispatchTime.now().uptimeNanoseconds
                                for _ in 0..<16 {
                                    guard machine.isResearchMessageClickTimedWait else {
                                        sample.issue = "timed_wait_or_host_state_changed"
                                        break
                                    }
                                    Thread.sleep(forTimeInterval: Double(ticks) / 1000)
                                    let now = DispatchTime.now().uptimeNanoseconds
                                    let elapsed = (now - previousFrameTime) / 1_000_000
                                    guard (1...1000).contains(elapsed), let available = budget, available >= Int32(elapsed) else {
                                        sample.issue = "timed_wait_elapsed_or_budget_outside_profile"
                                        break
                                    }
                                    let guestTicks = ScriptFrameClock.elapsedMilliseconds(
                                        current: UInt32(truncatingIfNeeded: now / 1_000_000),
                                        previous: UInt32(truncatingIfNeeded: previousFrameTime / 1_000_000))
                                    previousFrameTime = now
                                    if let issue = try checkAutoFrameHost() { sample.issue = issue; break }
                                    var effectiveTicks = guestTicks
                                    do {
                                        try machine.validateResearchTimedStopFrame(allowObservedStreams: liveAudioObserver != nil,
                                            allowRealtimeObservedStreams: liveAudioObserver != nil)
                                    } catch ResourceError.rejected(let issue) {
                                        guard issue == "timed_stop_frame_clock_reset_pending", sample.elapsedTicks.isEmpty,
                                              let start = continuationStart,
                                              let zero = machine.traces.last(where: { $0.action == "engine_field_98_write_candidate" }),
                                              zero.sequence > start,
                                              !machine.traces.contains(where: { $0.sequence > zero.sequence && $0.action == "draw_request_candidate" }) else {
                                            sample.issue = issue
                                            break
                                        }
                                        effectiveTicks = try machine.consumeResearchWaitZeroClock(hostTicks: effectiveTicks,
                                            allowObservedStreams: liveAudioObserver != nil, allowFreshTimedWait: true)
                                        guard effectiveTicks == 0 else {
                                            sample.issue = "fresh_zero_clock_not_consumed"
                                            break
                                        }
                                        sample.zeroClockConsumed = true
                                        sample.freshZeroStep = zero.sequence
                                        sample.freshZeroContinuationStartStep = start
                                        sample.freshZeroLocation = zero.location
                                        try machine.validateResearchTimedStopFrame(allowObservedStreams: liveAudioObserver != nil,
                                            allowRealtimeObservedStreams: liveAudioObserver != nil)
                                    }
                                    let delta = Int32(elapsed)
                                    try machine.advanceTimedStop(ticks: effectiveTicks)
                                    try machine.advancePlacementClock(ticks: effectiveTicks)
                                    budget = available - delta
                                    sample.elapsedTicks.append(guestTicks)
                                    sample.effectiveTicks.append(effectiveTicks)
                                    if machine.phase == .waitingForEvent {
                                        try machine.dispatchStopCallback(elapsedTicks: effectiveTicks)
                                        sample.callbackCount += 1
                                        var callbackSteps = 0
                                        while machine.phase == .ready && machine.researchStopCallbackRunning && callbackSteps < 10_000 {
                                            if machine.step()?.action == "stop_callback_play_candidate" { sample.callbackPlayObserved = true }
                                            callbackSteps += 1
                                        }
                                        if machine.researchStopCallbackRunning { sample.issue = "timed_callback_not_completed"; break }
                                    }
                                    if machine.phase == .ready && machine.timedStopRequest == nil {
                                        sample.completed = true
                                        continuationStart = machine.playbackStatus.steps
                                        try machine.run(stepQuota: maximumSteps ?? 10_000)
                                        break
                                    }
                                }
                                if sample.elapsedTicks.count == 16 && !sample.completed && sample.issue == nil {
                                    sample.issue = "timed_wait_frame_limit_reached"
                                }
                            }
                            func handlePendingMedia() throws {
                                while sample.completed && sample.issue == nil && machine.phase == .waitingForMedia &&
                                      machine.soundPlaybackRequest != nil && sample.mediaHandoffCount < 3 {
                                    sample.mediaHandoffAttempted = true
                                    autoTimedMediaHandoffCompleted = false
                                    autoTimedMediaContinuationStart = nil
                                    stopAfterAutoTimedMediaHandoff = true
                                    try runHost()
                                    stopAfterAutoTimedMediaHandoff = false
                                    sample.mediaHandoffCompleted = autoTimedMediaHandoffCompleted
                                    if autoTimedMediaHandoffCompleted {
                                        sample.mediaHandoffCount += 1
                                        continuationStart = autoTimedMediaContinuationStart
                                    } else { sample.issue = researchHostIssue ?? "auto_media_handoff_not_completed" }
                                }
                                if sample.mediaHandoffCount == 3 && machine.phase == .waitingForMedia &&
                                    machine.soundPlaybackRequest != nil && sample.issue == nil {
                                    sample.issue = "auto_media_handoff_limit_reached"
                                }
                            }
                            try handlePendingMedia()
                            if sample.completed && machine.phase == .waitingForSoundSwap && machine.soundSwapRequest != nil {
                                sample.soundSwapAttempted = true
                                stopAfterAutoTimedSoundSwap = true
                                try runHost()
                                stopAfterAutoTimedSoundSwap = false
                                sample.soundSwapCompleted = autoTimedSoundSwapCompleted
                                if autoTimedSoundSwapCompleted { continuationStart = autoTimedSoundSwapContinuationStart }
                                if !autoTimedSoundSwapCompleted { sample.issue = researchHostIssue ?? "auto_sound_swap_not_completed" }
                            }
                            try handlePendingMedia()
                            sample.endStep = machine.playbackStatus.steps
                            sample.endLocation = machine.playbackStatus.currentLocation
                            return sample
                        }
                        var autoTimedWait: HeadlessReplayBudget.ResearchAutoTimedWait?
                        var autoTimedWaits: [HeadlessReplayBudget.ResearchAutoTimedWait] = []
                        if researchAutoFollowTimedWait, let ticks = researchAutoFrameTicks {
                          var continuationStart = autoAdditionalLines.last?.continuationStartStep
                          for _ in 0..<(researchAutoTimedWaitCount ?? 1) {
                            let sample = try sampleAutoTimedWait(ticks: ticks, continuationStart: &continuationStart,
                                precedingPlayObserved: autoAdditionalLines.last?.playObserved == true)
                            autoTimedWaits.append(sample)
                            if !sample.completed || sample.issue != nil || !machine.isResearchMessageClickTimedWait { break }
                          }
                          autoTimedWait = autoTimedWaits.first
                        }
                        var autoAfterTimedLines: [HeadlessReplayBudget.ResearchAutoFollowthrough] = []
                        var autoAfterLinesTimedWaits: [HeadlessReplayBudget.ResearchAutoTimedWait] = []
                        if let count = researchAutoAfterTimedLines, let ticks = researchAutoFrameTicks,
                           autoTimedWaits.count == researchAutoTimedWaitCount,
                           autoTimedWaits.allSatisfy({ $0.completed && $0.issue == nil }) {
                            let followthroughDeadline = ContinuousClock.now.advanced(by: .seconds(researchAutoAfterTimedMaxSeconds ?? 20))
                            for _ in 0..<count {
                                if ContinuousClock.now >= followthroughDeadline {
                                    var line = HeadlessReplayBudget.ResearchAutoFollowthrough(textWaitStartStep: machine.playbackStatus.steps)
                                    line.issue = "auto_after_timed_time_limit"
                                    autoAfterTimedLines.append(line)
                                    break
                                }
                                let line = try sampleAdditionalAutoLine(ticks: ticks)
                                autoAfterTimedLines.append(line)
                                if !line.playObserved || line.issue != nil { break }
                                var continuationStart = line.continuationStartStep
                                while researchAutoAfterLinesTimedWait && machine.isResearchMessageClickTimedWait &&
                                      autoAfterLinesTimedWaits.count < 32 && ContinuousClock.now < followthroughDeadline {
                                    let wait = try sampleAutoTimedWait(ticks: ticks, continuationStart: &continuationStart,
                                        precedingPlayObserved: line.playObserved)
                                    autoAfterLinesTimedWaits.append(wait)
                                    if !wait.completed || wait.issue != nil { break }
                                }
                                if !machine.isResearchMessageTextWait { break }
                            }
                        }
                        var audioCompletionCyclesDispatched: Int?
                        if let cycles = researchAudioCompletionStopCycles {
                            guard let observer = liveAudioObserver, machine.phase == .waitingForEvent,
                                  machine.timedStopRequest == nil, observer.starts == 1,
                                  machine.activeStreamPlaybackSnapshots.count == 1 else {
                                throw ResourceError.rejected("audio_completion_stop_requires_one_active_stream_and_wait")
                            }
                            let deadline = ContinuousClock.now + .seconds(min(liveAudioMaximumSeconds ?? 10, 10))
                            while observer.completedPlaybackCount == 0 && ContinuousClock.now < deadline {
                                _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
                                try observer.synchronizeControls(machine: &machine)
                            }
                            guard observer.completedPlaybackCount == 1, observer.rejectedControlCount == 0,
                                  machine.activeStreamPlaybackSnapshots.isEmpty else {
                                throw ResourceError.rejected("audio_completion_stop_playback_not_completed")
                            }
                            var dispatched = 0
                            for _ in 0..<cycles {
                                guard machine.phase == .waitingForEvent, machine.timedStopRequest == nil else { break }
                                try machine.dispatchStopCallback(elapsedTicks: 0)
                                dispatched += 1
                                try machine.run(stepQuota: maximumSteps ?? 10_000)
                            }
                            audioCompletionCyclesDispatched = dispatched
                        }
                        if openTitleLoad || loadTaskEscape || !loadTaskPages.isEmpty || loadTaskSlot != nil {
                            guard machine.systemTaskRequest != nil else {
                                throw ResourceError.rejected("requested_load_task_not_reached")
                            }
                        }
                        if inspectLoadTask, machine.systemTaskRequest != nil {
                            var task = try machine.startSystemLoadTask()
                            task.savedAutoWaitClicks = savedAutoWaitClicks
                            task.savedDialogueClicks = savedDialogueClicks
                            task.clickAfterSavedMovie = clickAfterSavedMovie
                            task.compactSavedReplay = compactSavedReplay
                            task.savedReplayStepLimit = savedReplayStepLimit ?? 512
                            if let host = movieHost {
                                task.savedMovieDecodeHandler = { try host.decode($0) }
                                task.savedSoundDecodeHandler = { request, seek in
                                    var audioHost = host
                                    try audioHost.decodeSound(request, seekMilliseconds: seek)
                                }
                            }
                            task.savedDisplayDrawHandler = { preview in
                                let image: CGImage
                                switch preview {
                                case .externalImage(let bytes, let transform):
                                    image = try ResourceImage.decode(bytes).savedDisplayPreview(
                                        transform: transform, width: 1280, height: 720)
                                case .capturedSurface(let bytes):
                                    image = try ResourceImage.decode(bytes).image
                                case .rectangle(let rect):
                                    image = try ResourceImage.savedDisplayRectPreview(rect, width: 1280, height: 720)
                                }
                                guard let pixels = image.dataProvider?.data else {
                                    throw ResourceError.rejected("saved_display_preview_pixels_unavailable")
                                }
                                return .init(status: .inferred, width: image.width, height: image.height,
                                             pixelSHA256: (pixels as Data).sha256Hex)
                            }
                            task.savedEventSampleTicks = scenePreviewTicks
                            task.savedFrozenLayerPreview = scenePreviewSavedLayerTimes
                            if let background = scenePreviewBackground {
                                let strictPreview = requireCompleteScenePreview
                                let sceneCanvas = scenePreviewCanvas
                                let videoHost = scenePreviewVideoFrames ? movieHost : nil
                                let savedLayerTimes = scenePreviewSavedLayerTimes
                                let savedLayerDelta = scenePreviewSavedLayerDelta
                                task.savedSceneDrawHandler = { probe, pass in
                                    let priority: Int32?
                                    let isCapture: Bool
                                    let isFrozenLayerScene: Bool
                                    let overlapProgress: (elapsed: UInt32, duration: UInt32)?
                                    switch pass {
                                    case .scene: (priority, isCapture, isFrozenLayerScene, overlapProgress) = (nil, false, false, nil)
                                    case .frozenLayerScene: (priority, isCapture, isFrozenLayerScene, overlapProgress) = (nil, false, true, nil)
                                    case .capture(let cutoff): (priority, isCapture, isFrozenLayerScene, overlapProgress) = (cutoff, true, false, nil)
                                    case .overlapSample(let cutoff, let elapsed, let duration): (priority, isCapture, isFrozenLayerScene, overlapProgress) = (cutoff, false, false, (elapsed, duration))
                                    }
                                    var surface: Data?
                                    let scene = try LoadThumbnailPass(task: probe, assets: directory,
                                        recipe: imageRecipe, backgroundPath: background, suppliedCapture: nil,
                                        saveDirectory: saveDirectory, atDrawRequest: true, capturePriority: priority,
                                        overlapProgress: overlapProgress, canvasSize: sceneCanvas,
                                        sceneVideoFrame: videoHost.map { host in { source, ticks in try host.standaloneSceneFrame(source, ticks: ticks) } },
                                        useSavedLayerTimesCandidate: savedLayerTimes && isFrozenLayerScene,
                                        savedLayerAdvanceDelta: isFrozenLayerScene ? savedLayerDelta : nil,
                                        exportPNG: isCapture ? { surface = $0 } : nil)
                                    let incomplete = isFrozenLayerScene || !scene.omittedLayers.isEmpty || !scene.textPreviewIssues.isEmpty ||
                                        !scene.sceneVideoCandidateTicks.isEmpty || scene.savedLayerTimeCandidateCount > 0 ||
                                        (strictPreview && (scene.interfaceBackgroundPreviewCount > 0 || scene.fractionalScalePreviewCount > 0 || scene.embeddedAlignmentCandidateCount > 0 || scene.dynamicMessageSurfaceCount > 0 || scene.sampling2CandidateCount > 0 || scene.inactiveMessageSurfaceCount > 0 || scene.dualTextureCandidateCount > 0))
                                    var receipt = ScriptMachine.SavedDisplayDraw(status: incomplete ? .unsupported : .inferred,
                                                 pixelSHA256: scene.canvasSHA256,
                                                 issue: isFrozenLayerScene && scene.savedLayerTimeCandidateCount == 0
                                                    ? "saved_layer_time_snapshot_unavailable" : (incomplete ? "saved_scene_preview_incomplete" : nil),
                                                 omittedLayers: scene.omittedLayers.map {
                                                     .init(resource: $0.resource, reason: $0.reason)
                                                 }, textIssues: scene.textPreviewIssues)
                                    receipt.coverage = .init(rasterLayers: scene.staticRasterCount,
                                        motionLayers: scene.compositedMotionLayers.count,
                                        staticInterfaceFallbacks: scene.interfaceBackgroundPreviewCount,
                                        nonDrawingLayers: scene.nonDrawingLayerCount,
                                        nonDrawingReasons: scene.nonDrawingReasons,
                                        textLayers: scene.textPreviewCount,
                                        textLayersWithoutCoverage: scene.textPreviewWithoutCoverageCount)
                                    receipt.interfaceBackgroundPreviews = scene.interfaceBackgroundPreviews
                                    if !scene.sceneVideoCandidateTicks.isEmpty { receipt.sceneVideoCandidateTicks = scene.sceneVideoCandidateTicks }
                                    if scene.savedLayerTimeCandidateCount > 0 {
                                        receipt.savedLayerTimeCandidateCount = scene.savedLayerTimeCandidateCount
                                        receipt.savedLayerTimeSamples = scene.savedLayerTimeSamples
                                    }
                                    receipt.clippedRasters = scene.clippedRasters
                                    receipt.uncoveredMotions = scene.uncoveredMotions
                                    receipt.transitionMidpointSHA256 = scene.transitionMidpointSHA256
                                    return (receipt, incomplete ? nil : surface)
                                }
                            }
                            try machine.runSystemLoadTask(&task)
                            var suppliedCapture: Data?
                            if let path = loadTaskCapturePath, task.screenCaptureRequest != nil {
                                let url = URL(fileURLWithPath: path)
                                let captureDirectory = try SafeDirectory(url.deletingLastPathComponent())
                                let bytes = try captureDirectory.read(url.lastPathComponent, limit: 8 * 1024 * 1024)
                                let image = try ResourceImage.decode(bytes).image
                                let reference = ScriptModuleReference(logicalPath: "system-capture.png",
                                    sourceFile: "system-capture.png", sourceSHA256: bytes.sha256Hex)
                                try task.supplyScreenCapture(reference.wholeFileLocation(byteLength: bytes.count),
                                    width: image.width, height: image.height)
                                suppliedCapture = bytes
                                try machine.runSystemLoadTask(&task)
                            }
                            var taskTicks = loadTaskTicks ?? 0
                            var escaped = false
                            var verifiedPages: [Int32] = []
                            var pendingPage: Int32?
                            var clickedSlot = false
                            var answeredConfirmation = false
                            for _ in 0..<1024 {
                                if let page = pendingPage, !task.loadMenuButtons.isEmpty {
                                    let checked = task.loadMenuButtons.filter(task.isLoadPageChecked)
                                        .compactMap(task.loadPageIndex)
                                    guard checked == [page] else {
                                        throw ResourceError.rejected("load_task_page_did_not_change")
                                    }
                                    verifiedPages.append(page)
                                    pendingPage = nil
                                }
                                if verifiedPages.count < loadTaskPages.count, pendingPage == nil,
                                   !task.loadMenuButtons.isEmpty {
                                    let page = loadTaskPages[verifiedPages.count]
                                    let buttons = task.loadMenuButtons.filter { task.loadPageIndex($0) == page }
                                    guard buttons.count == 1, let handle = buttons.first,
                                          let layer = task.staticImageLayers.first(where: { $0.id == handle }) else {
                                        throw ResourceError.rejected("load_task_page_button_unavailable")
                                    }
                                    try task.dispatchLoadMenuButton(handle, x: layer.x, y: layer.y)
                                    pendingPage = page
                                    try machine.runSystemLoadTask(&task)
                                    continue
                                }
                                if loadTaskEscape, !escaped, task.phase == .waitingForEvent, !task.loadMenuButtons.isEmpty {
                                    try task.dispatchLoadMenuEscape()
                                    escaped = true
                                    try machine.runSystemLoadTask(&task)
                                    continue
                                }
                                if let slot = loadTaskSlot, !clickedSlot, !task.loadMenuButtons.isEmpty {
                                    guard let handle = try task.loadSlotButton(named: slot),
                                          let layer = task.staticImageLayers.first(where: { $0.id == handle }) else {
                                        throw ResourceError.rejected("load_slot_button_unavailable")
                                    }
                                    try task.dispatchLoadMenuButton(handle, x: layer.x, y: layer.y)
                                    clickedSlot = true
                                    try machine.runSystemLoadTask(&task)
                                    continue
                                }
                                if clickedSlot, !answeredConfirmation, let accept = loadTaskConfirmation,
                                   try task.dispatchLoadConfirmation(accept: accept) {
                                    answeredConfirmation = true
                                    try machine.runSystemLoadTask(&task)
                                    continue
                                }
                                guard task.phase == .waiting, let wait = task.clickWaitRemaining,
                                      wait >= 0 else { break }
                                let delta = min(wait, taskTicks)
                                guard delta > 0 || wait == 0 else { break }
                                try task.advanceClickWait(ticks: delta)
                                try task.advancePlacementClock(ticks: delta)
                                taskTicks -= delta
                                guard task.phase == .ready else { break }
                                try machine.runSystemLoadTask(&task)
                            }
                            guard verifiedPages == loadTaskPages else {
                                throw ResourceError.rejected("load_task_page_did_not_change")
                            }
                            guard loadTaskSlot == nil || clickedSlot else {
                                let status = task.playbackStatus
                                let cause = status.stopReason ?? status.phase.rawValue
                                throw ResourceError.rejected("load_slot_button_not_reached: \(cause)")
                            }
                            guard loadTaskConfirmation == nil || answeredConfirmation else {
                                throw ResourceError.rejected("load_confirmation_not_reached")
                            }
                            var visibleDialogueAfterRestart: Int?
                            if loadTaskEscape {
                                guard escaped, task.systemTaskExitRequested else {
                                    throw ResourceError.rejected("load_task_escape_did_not_exit")
                                }
                                try machine.finishSystemLoadTask(task)
                                if openTitleLoad {
                                    for _ in 0..<1024 {
                                        if machine.phase == .ready {
                                            try machine.run(stepQuota: 10_000)
                                        }
                                        guard machine.phase == .waiting, let wait = machine.clickWaitRemaining,
                                              wait >= 0, wait <= taskTicks else { break }
                                        try machine.advanceClickWait(ticks: wait)
                                        try machine.advancePlacementClock(ticks: wait)
                                        taskTicks -= wait
                                    }
                                    guard machine.phase == .waitingForEvent, machine.canStartFromTitle else {
                                        throw ResourceError.rejected("load_task_title_did_not_resume")
                                    }

                                }
                            }
                            var report = HeadlessLoadTask(task, suppliedCaptureSHA256: suppliedCapture?.sha256Hex)
                            if adoptSaveCandidate {
                                let directBufferBytes: ((ScriptLocation) throws -> Int)? = movieHost.map { host in
                                    { try host.savedSoundPCMBytes($0) }
                                }
                                let suspendedMachine = machine
                                let suspendedHost = movieHost
                                let suspendedInputs = (budget, pendingDispatch, pendingScopedDispatch,
                                                       pendingMessageClicks, hostIterations, choiceCursor,
                                                       openedTitleLoad, lastRouteProgressSteps)
                                func restoreSuspendedInputs() {
                                    budget = suspendedInputs.0
                                    pendingDispatch = suspendedInputs.1
                                    pendingScopedDispatch = suspendedInputs.2
                                    pendingMessageClicks = suspendedInputs.3
                                    hostIterations = suspendedInputs.4
                                    choiceCursor = suspendedInputs.5
                                    openedTitleLoad = suspendedInputs.6
                                    lastRouteProgressSteps = suspendedInputs.7
                                    movieHost = suspendedHost
                                }
                                do {
                                    let audio = try machine.adoptExperimentalSaveCandidate(from: task, directBufferBytes: directBufferBytes)
                                    report.experimentalAdoptionStagedStreams = audio.stagedStreams
                                    report.experimentalAdoptionRestoredStreamNames = audio.restoredStreamNames
                                    report.experimentalAdoptionUnrestoredSavedStreamNames = audio.unrestoredSavedStreamNames
                                    report.experimentalAdoptionRestoredStreamFilters = audio.restoredStreamFilters
                                    report.experimentalAdoptionUnrestoredSavedStreamFilters = audio.unrestoredSavedStreamFilters
                                    report.experimentalAdoptionScheduledStreams = audio.scheduledStreams
                                    report.experimentalAdoptionScheduledDirectSounds = audio.scheduledDirectSounds
                                    report.experimentalAdoptionAudioGaps = audio.gaps
                                    guard audio.gaps.isEmpty else {
                                        throw ResourceError.rejected("saved_audio_restore_incomplete")
                                    }
                                    guard movieHost != nil || (audio.scheduledStreams == 0 && audio.scheduledDirectSounds == 0) else {
                                        throw ResourceError.rejected("saved_audio_host_unavailable")
                                    }
                                    try machine.run(stepQuota: maximumSteps ?? 10_000)
                                    try runHost()
                                    guard machine.phase != .stopped else {
                                        throw ResourceError.rejected("save_adopted_execution_stopped:\(machine.stopReason ?? "unknown")")
                                    }
                                    report.experimentalAdoption = machine.summary
                                } catch {
                                    machine = suspendedMachine
                                    restoreSuspendedInputs()
                                    report.experimentalAdoptionIssue = String(describing: error)
                                    do {
                                        try machine.discardFailedSaveLoadTask(task)
                                        try machine.run(stepQuota: 10_000)
                                        try runHost()
                                        guard machine.phase == .waitingForEvent, machine.canStartFromTitle else {
                                            throw ResourceError.rejected("save_recovery_title_did_not_resume:\(machine.phase.rawValue):\(machine.stopReason ?? "none")")
                                        }
                                        report.resumedTitleAfterUnsupportedSave = true
                                    } catch {
                                        machine = suspendedMachine
                                        restoreSuspendedInputs()
                                        report.experimentalAdoptionRecoveryIssue = String(describing: error)
                                    }
                                }
                            }
                            if recoverUnsupportedSave {
                                try machine.discardFailedSaveLoadTask(task)
                                try machine.run(stepQuota: 10_000)
                                try runHost()
                                guard machine.phase == .waitingForEvent, machine.canStartFromTitle else {
                                    throw ResourceError.rejected("save_recovery_title_did_not_resume:\(machine.phase.rawValue):\(machine.stopReason ?? "none")")
                                }
                                report.resumedTitleAfterUnsupportedSave = true
                            }
                            if startAfterLoadEscape || (startAfterSaveRecovery && report.resumedTitleAfterUnsupportedSave == true) {
                                guard let handle = machine.titleStartButton, let index = machine.titleButtons[handle],
                                      let layer = machine.staticImageLayers.first(where: { $0.id == handle }) else {
                                    throw ResourceError.rejected("title_start_button_unavailable")
                                }
                                try machine.dispatchStopCallback(pointer: (layer.x, layer.y), buttonIndex: index, click: true)
                                routeStartedForMenu = requireRouteReturn
                                try machine.run(stepQuota: 10_000)
                                guard !machine.canStartFromTitle, machine.phase == .waiting ||
                                        machine.phase == .waitingForEvent || machine.moviePlaybackRequest != nil else {
                                    throw ResourceError.rejected("title_start_after_load_escape_failed")
                                }
                                try runHost()
                                visibleDialogueAfterRestart = machine.messageTextLayers.count {
                                    $0.isVisible && $0.canvasBounds != nil &&
                                        $0.runs.contains { $0.text.contains { !$0.isWhitespace } }
                                }
                            }
                            if let requests = task.saveResumeBoundary?.stagedSoundRequests, !requests.isEmpty {
                                let results: [HeadlessLoadTask.SoundBufferCheck] = requests.enumerated().map { index, check in
                                    guard movieHost != nil, index < 4 else {
                                        return .init(recordOffset: check.recordOffset, decodedBytes: nil, passesMinimum: nil,
                                                     status: .notTested, issue: "saved_sound_decoder_unavailable_or_limit")
                                    }
                                    do {
                                        if let minimumBytes = check.minimumDecodedBytes {
                                            let bytes = try movieHost!.savedSoundPCMBytes(check.source)
                                            return .init(recordOffset: check.recordOffset, decodedBytes: bytes,
                                                         passesMinimum: bytes >= minimumBytes, status: .inferred, issue: nil)
                                        }
                                        try movieHost!.decodeSound(check.source)
                                        return .init(recordOffset: check.recordOffset, decodedBytes: nil,
                                                     passesMinimum: nil, status: .verified, issue: nil)
                                    } catch {
                                        return .init(recordOffset: check.recordOffset, decodedBytes: nil, passesMinimum: nil,
                                                     status: .unsupported, issue: String(describing: error))
                                    }
                                }
                                report.soundBufferChecks = results
                                let passed = Set(results.filter {
                                    $0.status == .verified || $0.passesMinimum == true
                                }.map(\.recordOffset))
                                report.stagedSoundPlayback = requests.filter { passed.contains($0.recordOffset) }
                            }
                            if let seeks = task.saveResumeBoundary?.stagedStreamSeeks, !seeks.isEmpty {
                                report.streamSeekChecks = seeks.enumerated().map { index, seek in
                                    guard let host = movieHost, index < 4 else {
                                        return .init(recordOffset: seek.recordOffset, milliseconds: seek.milliseconds,
                                                     decodedBytes: nil, status: .notTested, issue: "saved_stream_decoder_unavailable_or_limit")
                                    }
                                    do {
                                        let bytes = try host.savedSoundPCMBytes(seek.source, seekMilliseconds: seek.milliseconds)
                                        return .init(recordOffset: seek.recordOffset, milliseconds: seek.milliseconds,
                                                     decodedBytes: bytes, status: bytes > 0 ? seek.status : .unsupported,
                                                     issue: bytes > 0 ? seek.issue : "saved_stream_seek_no_samples")
                                    } catch {
                                        return .init(recordOffset: seek.recordOffset, milliseconds: seek.milliseconds,
                                                     decodedBytes: nil, status: .unsupported, issue: String(describing: error))
                                    }
                                }
                            }
                            report.verifiedPageSelections = verifiedPages
                            if loadTaskSlot != nil { report.clickedSaveSlot = clickedSlot }
                            if answeredConfirmation { report.answeredSaveConfirmation = loadTaskConfirmation }
                            report.visibleDialogueAfterRestart = visibleDialogueAfterRestart
                            if let background = loadThumbnailBackground, !task.systemTaskExitRequested {
                                do {
                                    let preview = try LoadThumbnailPass(task: task, assets: directory,
                                        recipe: imageRecipe, backgroundPath: background, suppliedCapture: suppliedCapture,
                                        saveDirectory: saveDirectory)
                                    report.thumbnailPass = preview
                                    if requireCompleteScenePreview,
                                       preview.isIncomplete {
                                        report.thumbnailIssue = "load_thumbnail_preview_incomplete"
                                    }
                                } catch {
                                    report.thumbnailIssue = String(describing: error)
                                }
                            } else if requireCompleteScenePreview, loadThumbnailBackground != nil {
                                report.thumbnailIssue = "complete_load_thumbnail_preview_requires_open_menu"
                            }
                            loadTask = report
                        }
                        var observedPositions: [Int32: Int32]?
                        var positionsBeforeDelay: [Int32: Int32]?
                        var observedAudioIssue: String?
                        var positionObservationRecoveries = 0
                        if let liveAudioObserver {
                            do {
                                func sampleObservedPositions() throws -> [Int32: Int32] {
                                    do { return try liveAudioObserver.positions(for: machine.activeStreamPlaybackSnapshots) }
                                    catch {
                                        _ = try liveAudioObserver.awaitStoppedCompletion(for: machine.activeStreamPlaybackSnapshots)
                                        try liveAudioObserver.synchronizeControls(machine: &machine)
                                        let positions = try liveAudioObserver.positions(for: machine.activeStreamPlaybackSnapshots)
                                        positionObservationRecoveries += 1
                                        return positions
                                    }
                                }
                                try liveAudioObserver.synchronizeControls(machine: &machine)
                                if liveAudioObservationDelay > 0 {
                                    positionsBeforeDelay = try sampleObservedPositions()
                                    Thread.sleep(forTimeInterval: Double(liveAudioObservationDelay) / 1000)
                                    try liveAudioObserver.synchronizeControls(machine: &machine)
                                }
                                observedPositions = try sampleObservedPositions()
                                if liveAudioObserver.rejectedControlCount > 0 {
                                    throw ResourceError.rejected("live_audio_control_unacknowledged")
                                }
                            }
                            catch { observedAudioIssue = String(describing: error) }
                            liveAudioObservationIssue = observedAudioIssue
                        }
                        if let ticks = researchBarVisualTicks {
                            guard syntheticBarEventConsumed, machine.phase == .waitingForEvent else {
                                throw ResourceError.rejected("research_bar_visual_ticks_require_consumed_event")
                            }
                            // Explicit local sampling time; this does not model native host scheduling.
                            machine.advanceVisualClock(ticks: ticks)
                        }
                        replayBudget = HeadlessReplayBudget(hostIterations: hostIterations,
                            remainingMessageClicks: pendingMessageClicks, remainingTicks: budget,
                            consumedStoryChoices: choiceCursor, remainingStoryChoices: storyChoices.count - choiceCursor,
                            routeTitleReady: requireRouteReturn ? (machine.phase == .waitingForEvent && machine.canStartFromTitle) : nil,
                            routeAwaitingChoice: requireRouteReturn ? machine.isWaitingForStoryChoice : nil,
                            liveAudio: observeLiveAudio ? .init(status: observedAudioIssue == nil ? .inferred : .unsupported,
                                positions: observedPositions, positionsBeforeDelay: positionsBeforeDelay,
                                observationDelayMilliseconds: liveAudioObservationDelay,
                                maximumSeconds: liveAudioMaximumSeconds ?? 120,
                                maximumStarts: liveAudioMaximumStarts ?? 512, issue: observedAudioIssue,
                                completedControlCount: liveAudioObserver?.completedControlCount ?? 0,
                                pendingControlCount: liveAudioObserver?.pendingControlCount ?? 0,
                                rejectedControlCount: liveAudioObserver?.rejectedControlCount ?? 0,
                                completedPlaybackCount: liveAudioObserver?.completedPlaybackCount ?? 0,
                                playbackStartCount: liveAudioObserver?.starts ?? 0,
                                finiteRepeatStarts: liveAudioObserver?.finiteRepeatStarts ?? 0,
                                finiteRepeatReassertions: liveAudioObserver?.finiteRepeatReassertions ?? 0,
                                reusedStreamDecodeCount: reusedStreamDecodeCount,
                                deferredSupersededSyncs: liveAudioObserver?.deferredSupersededSyncs ?? 0,
                                streamSwapHandoffs: liveAudioObserver?.streamSwapHandoffs ?? 0,
                                streamSwapCancelledControls: liveAudioObserver?.streamSwapCancelledControls ?? 0,
                                positionObservationRecoveries: positionObservationRecoveries,
                                completionIdentityIssue: liveAudioObserver?.completionIdentityIssue,
                                completionIdentityChannel: liveAudioObserver?.completionIdentityChannel,
                                observedStreamIndices: observedAudioIssue == nil ? nil : liveAudioObserver?.observedStreamIndices,
                                machineActiveAudioOnFailure: observedAudioIssue == nil ? nil : machine.researchActiveAudioSnapshots,
                                recentLifecycleOnFailure: observedAudioIssue == nil ? nil : liveAudioObserver?.recentLifecycle,
                                categoryGains: liveAudioObserver?.observedCategoryGains,
                                playerVolumes: liveAudioObserver?.observedPlayerVolumes,
                                clock: researchMutedVolumeOutput ? "muted_volume_candidate_av_audio_player" :
                                    (researchAudibleVolumeFilter ? "audible_volume_candidate_av_audio_player" : "silent_pcm_realtime_av_audio_player"),
                                volumeFilterStarts: liveAudioObserver?.volumeFilterStarts ?? 0,
                                filterChainStarts: liveAudioObserver?.filterChainStarts ?? 0,
                                filterChainClears: liveAudioObserver?.filterChainClears ?? 0,
                                timeScaleStarts: liveAudioObserver?.timeScaleStarts ?? 0,
                                timeScalePositionClock: (liveAudioObserver?.timeScaleStarts ?? 0) > 0 ? "output_player_timeline_candidate" : nil,
                                timeScaleSourceDurationMilliseconds: liveAudioObserver?.lastTimeScaleSourceDurationMilliseconds,
                                timeScaleOutputDurationMilliseconds: liveAudioObserver?.lastTimeScaleOutputDurationMilliseconds,
                                unfilteredCandidateStarts: liveAudioObserver?.unfilteredCandidateStarts ?? 0,
                                volumeFilterUpdates: liveAudioObserver?.volumeFilterUpdates ?? 0,
                                recentFilterUpdates: liveAudioObserver?.recentFilterUpdates ?? [],
                                lastVolumeFilterAudioSHA256: liveAudioObserver?.lastVolumeFilterAudioSHA256,
                                candidateSampleRate: researchAudibleVolumeFilter ? (researchAudioRate ?? 22050) : nil) : nil,
                            startedFromTitle: startFromTitle ? startedFromTitle : nil,
                            titleMenuActions: titleMenuTarget == nil ? nil : titleMenuActions,
                            routeTitleReachedBeforeMenu: titleMenuTarget != nil && requireRouteReturn ? routeTitleReachedBeforeMenu : nil,
                            directSound: directSoundCount.flatMap { count in directSoundLock.map {
                                .init(channelCount: count, lockMilliseconds: $0,
                                      playback: researchObserveDirectSound ? "muted_realtime_candidate" : "decode_only_not_audible",
                                      observedStarts: researchObserveDirectSound ? liveAudioObserver?.directStarts : nil,
                                      observedCompletions: researchObserveDirectSound ? liveAudioObserver?.directCompletions : nil,
                                      completionEvents: researchObserveDirectSound ? liveAudioObserver?.directCompletionEvents : nil,
                                      completionEventsTruncated: researchObserveDirectSound ? liveAudioObserver?.directCompletionEventsTruncated : nil)
                            } }, explicitButtonArray: buttonIndex == nil ? nil : (buttonArray ?? "Button"),
                            explicitButtonIndex: buttonIndex,
                            subsequentButtonEvents: subsequentButtons.isEmpty ? nil : subsequentButtons.map { "\($0.array):\($0.index)" },
                            consumedSubsequentButtonEvents: subsequentButtons.isEmpty ? nil : subsequentButtonCursor,
                            syntheticBarEvent: syntheticBarEvent.map { "\($0.name):\($0.value)" },
                            syntheticBarEventConsumed: syntheticBarEvent == nil && syntheticBarAxis == nil ? nil : syntheticBarEventConsumed,
                            researchBarBeforeSubsequentButtons: researchBarBeforeSubsequentButtons ? true : nil,
                            researchBarEventSite: researchBarEventSite,
                            syntheticBarAxis: syntheticBarAxis.map { "\($0.name):\($0.position):\($0.rounding.rawValue)" },
                            syntheticBarAxisValue: syntheticBarAxisValue,
                            syntheticBarAxisScope: syntheticBarAxis == nil ? nil : (syntheticBarPointerInput
                                ? "caller_pointer_sample_resource_quad_identity_host_transform_candidate"
                                : (syntheticBarResourceY != nil
                                ? "resource_time_zero_quad_identity_host_no_projection_or_visibility_candidate"
                                : (syntheticBarPoint == nil ? "explicit_axis_zero_width_knob_no_hit_test_rounding_candidate"
                                   : "explicit_axis_zero_width_knob_caller_quad_rounding_candidate"))),
                            syntheticBarPoint: syntheticBarPoint,
                            syntheticBarPointHit: syntheticBarPoint != nil && syntheticBarEventConsumed ? true : nil,
                            syntheticBarPointScope: syntheticBarPoint == nil ? nil : "caller_supplied_quad_candidate_not_native_hit_geometry",
                            syntheticBarResourceQuad: syntheticBarResourceQuad,
                            syntheticBarResourcePoint: syntheticBarResourceY.flatMap { y in syntheticBarAxis.map { [$0.position, y] } },
                            syntheticBarPointerInput: syntheticBarPointerInput ? true : nil,
                            syntheticBarCallbackPointer: syntheticBarPointerInput ? true : nil,
                            syntheticBarPointerInputScope: syntheticBarPointerInput
                                ? "caller_pointer_sample_attached_to_stop_callback_after_resource_type6_region_candidate_identity_host_transform_and_original_pointer_mapping_not_tested" : nil,
                            researchBarObjectUpdates: researchBarObjectUpdates,
                            researchBarVisualTicks: researchBarVisualTicks,
                            unrenderedBars: inspectUnrenderedBars ? machine.unrenderedBarSnapshots : nil,
                            unrenderedButtonText: inspectUnrenderedBars ?
                                .init(positiveLineAdvanceDirectiveCount: machine.unrenderedButtonLineAdvanceCount) : nil,
                            soundDurationSource: (inspectUnrenderedBars || observeLiveAudio) ? "ffprobe_float32_nearest_even_milliseconds_candidate" : nil)
                        if inspectUnrenderedBars {
                            // Sample only the current local state. Both easing modes are
                            // reported because the original runtime selection is unknown.
                            let bars = machine.unrenderedBarSnapshots
                            var samples: [HeadlessReplayBudget.BarProgressSample] = []
                            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                            for bar in bars.prefix(16) {
                                for easing in [BarMotionSampling.Easing.power, .quartic] {
                                    var time: Float?, area: [Float]?
                                    do {
                                        guard ContinuousClock.now < deadline, bar.resources.count == 3,
                                              let resource = bar.resources[2],
                                              let progressEnableMotion = bar.progressEnableMotion,
                                              resource.byteOffset == 0, resource.byteLength <= 4 * 1024 * 1024,
                                              resource.sourceSHA256 == resource.rangeSHA256 else {
                                            throw ResourceError.rejected("bar_progress_resource_or_budget_unavailable")
                                        }
                                        let data = try directory.read(resource.sourceFile, limit: 4 * 1024 * 1024)
                                        guard data.count == resource.byteLength, data.sha256Hex == resource.sourceSHA256,
                                              let duration = imageRecipe.motionDurationInputs(resource),
                                              imageRecipe.motionNames(resource)?.indices.contains(Int(progressEnableMotion)) == true,
                                              imageRecipe.motionNames(resource)?[Int(progressEnableMotion)] == "*Enable",
                                              let sampled = BarMotionSampling.animationTime(start: bar.transitionStart,
                                                target: bar.value, maximum: bar.maximum, duration: bar.transitionDuration,
                                                remaining: bar.transitionRemaining, animationDuration: duration.duration,
                                                easing: easing),
                                              let keys = imageRecipe.motionKeysAtFractionalTime(resource, selectedMember: progressEnableMotion, time: sampled) else {
                                            throw ResourceError.rejected("bar_progress_timeline_or_identity_unavailable")
                                        }
                                        time = sampled
                                        let draws = keys.filter { $0.type != 0 }
                                        guard draws.count <= 1, draws.allSatisfy({ $0.type == 4 }) else {
                                            throw ResourceError.rejected("bar_progress_key_shape_unsupported")
                                        }
                                        let background = SIMD4<UInt8>(20, 40, 60, 255)
                                        var canvas = Array(repeating: Array(repeating: background, count: 512), count: 128)
                                        var covered = false
                                        if let key = draws.first {
                                            area = key.sampledFirstSourceArea
                                            covered = try imageRecipe.drawFullTexturePreview(key, container: data,
                                                origin: .zero, canvas: &canvas)
                                        }
                                        var pixels = Data(), changed = 0
                                        for row in canvas {
                                            changed += row.count { $0 != background }
                                            row.withUnsafeBytes { pixels.append(contentsOf: $0) }
                                        }
                                        var result = HeadlessReplayBudget.BarProgressSample(handle: bar.handle,
                                            easing: easing.rawValue, trackEnableMotion: bar.trackEnableMotion,
                                            progressEnableMotion: bar.progressEnableMotion, status: .inferred,
                                            animationTime: time, sourceArea: area, covered: covered, changedPixels: changed,
                                            canvasSHA256: pixels.sha256Hex, issue: nil)
                                        do {
                                            // Time-zero consensus is only a visual candidate;
                                            // neither pointer state nor actual action time is known.
                                            guard ContinuousClock.now < deadline, bar.resources[0] == nil,
                                                  let track = bar.resources[1], track.byteOffset == 0,
                                                  let trackEnableMotion = bar.trackEnableMotion,
                                                  track.byteLength <= 4 * 1024 * 1024,
                                                  track.sourceSHA256 == track.rangeSHA256 else {
                                                throw ResourceError.rejected("bar_track_resource_or_budget_unavailable")
                                            }
                                            let trackData = try directory.read(track.sourceFile, limit: 4 * 1024 * 1024)
                                            guard trackData.count == track.byteLength, trackData.sha256Hex == track.sourceSHA256,
                                                  let trackNames = imageRecipe.motionNames(track),
                                              trackNames.indices.contains(Int(trackEnableMotion)),
                                              trackNames[Int(trackEnableMotion)] == "*Enable", (1...16).contains(trackNames.count),
                                                  imageRecipe.motionDurationInputs(track)?.duration == 0,
                                              let trackKeys = imageRecipe.motionKeys(track, selectedMember: trackEnableMotion, time: 0),
                                                  trackKeys.allSatisfy({ [0, 4, 6].contains($0.type) }),
                                                  trackKeys.count(where: { $0.type == 4 }) == 1,
                                                  let trackKey = trackKeys.first(where: { $0.type == 4 }) else {
                                                throw ResourceError.rejected("bar_track_initial_frame_unavailable")
                                            }
                                            var composite = Array(repeating: Array(repeating: background, count: 512), count: 128)
                                            _ = try imageRecipe.drawFullTexturePreview(trackKey, container: trackData,
                                                origin: SIMD2(16, 16), canvas: &composite)
                                            let needsConsensus = bar.locked || bar.lockStateChanged
                                            if needsConsensus {
                                                for index in 1..<trackNames.count {
                                                    guard ContinuousClock.now < deadline,
                                                          let keys = imageRecipe.motionKeys(track, selectedMember: Int32(index), time: 0),
                                                          keys.allSatisfy({ [0, 4, 6].contains($0.type) }),
                                                          keys.count(where: { $0.type == 4 }) == 1,
                                                          let key = keys.first(where: { $0.type == 4 }) else {
                                                        throw ResourceError.rejected("bar_track_action_consensus_unavailable")
                                                    }
                                                    var candidate = Array(repeating: Array(repeating: background, count: 512), count: 128)
                                                    _ = try imageRecipe.drawFullTexturePreview(key, container: trackData,
                                                        origin: SIMD2(16, 16), canvas: &candidate)
                                                    guard candidate == composite else {
                                                        throw ResourceError.rejected("bar_track_action_frames_differ")
                                                    }
                                                }
                                            }
                                            var trackPixels = Data(), trackChanged = 0
                                            for row in composite {
                                                trackChanged += row.count { $0 != background }
                                                row.withUnsafeBytes { trackPixels.append(contentsOf: $0) }
                                            }
                                            let trackCanvas = composite
                                            if let key = draws.first {
                                                _ = try imageRecipe.drawFullTexturePreview(key, container: data,
                                                    origin: SIMD2(16, 16), canvas: &composite)
                                            }
                                            var compositePixels = Data(), compositeChanged = 0
                                            for row in composite {
                                                compositeChanged += row.count { $0 != background }
                                                row.withUnsafeBytes { compositePixels.append(contentsOf: $0) }
                                            }
                                            result.compositeStatus = .inferred
                                            result.compositeScope = needsConsensus
                                                ? "track_listed_actions_time_zero_pixel_consensus_plus_progress_fixed_background_actual_action_time_and_input_unsupported"
                                                : "track_initial_enable_frame_assumed_plus_progress_fixed_background_input_unsupported"
                                            result.trackActionCandidatesCompared = needsConsensus ? trackNames.count : nil
                                            result.trackChangedPixels = trackChanged
                                            result.trackCanvasSHA256 = trackPixels.sha256Hex
                                            result.progressOverlayChangedPixels = zip(trackCanvas, composite).reduce(0) { count, rows in
                                                count + zip(rows.0, rows.1).count { pair in pair.0 != pair.1 }
                                            }
                                            result.compositeChangedPixels = compositeChanged
                                            result.compositeCanvasSHA256 = compositePixels.sha256Hex
                                        } catch {
                                            result.compositeStatus = .unsupported
                                            result.compositeIssue = String(describing: error)
                                        }
                                        samples.append(result)
                                    } catch {
                                        var failed = HeadlessReplayBudget.BarProgressSample(handle: bar.handle,
                                            easing: easing.rawValue, trackEnableMotion: bar.trackEnableMotion,
                                            progressEnableMotion: bar.progressEnableMotion, status: .unsupported,
                                            animationTime: time, sourceArea: area, covered: nil, changedPixels: nil,
                                            canvasSHA256: nil, issue: String(describing: error))
                                        failed.compositeStatus = .notTested
                                        failed.compositeIssue = "bar_progress_prerequisite_unavailable"
                                        samples.append(failed)
                                    }
                                }
                            }
                            replayBudget?.barProgressSamples = samples
                            replayBudget?.barProgressSamplesTruncated = bars.count > 16
                        }
                        replayBudget?.timedStopRemaining = machine.timedStopRequest?.duration
                        if let audioCompletionCyclesDispatched {
                            replayBudget?.researchAudioCompletionStopCycles = audioCompletionCyclesDispatched
                            replayBudget?.researchAudioCompletionStopScope = "explicit_zero_tick_callbacks_after_observed_stream_completion_native_scheduling_not_tested"
                        }
                        if researchStopAtCenterText { replayBudget?.researchCenterTextStopReached = researchCenterTextStopReached }
                        if researchStopAtRuby { replayBudget?.researchRubyStopReached = researchRubyStopReached }
                        replayBudget?.timedStopAlternateRemaining = machine.timedStopRequest?.alternateDuration
                        if let researchTimedStopFrameTicks {
                            replayBudget?.researchTimedStopFrameTicks = researchTimedStopFrameTicks
                            replayBudget?.researchTimedStopFrames = researchTimedStopFrames
                            if researchZeroEventCallback {
                                replayBudget?.researchTimedStopRealtimeElapsed = researchTimedStopRealtimeElapsed
                                replayBudget?.researchRealtimeOrdinaryWaitElapsed = researchRealtimeOrdinaryWaitElapsed
                                replayBudget?.researchRealtimeDrawElapsed = researchRealtimeDrawElapsed
                                replayBudget?.researchLastHandledDrawStep = researchLastHandledDrawStep
                                replayBudget?.researchTimedStopRealtimeIssue = researchTimedStopRealtimeIssue
                                replayBudget?.researchTimedStopCompletionRecoveries = researchTimedStopCompletionRecoveries
                                replayBudget?.researchTimedStopSamplingRecoveries = researchTimedStopSamplingRecoveries
                                replayBudget?.researchTimedRealtimeMaxFrames = researchTimedRealtimeMaxFrames ?? 64
                            }
                            replayBudget?.researchTimedStopFreshZeroStart = researchTimedStopFreshZeroStart
                            replayBudget?.researchTimedStopFreshZeroStep = researchTimedStopFreshZeroStep
                            if researchZeroEventCallback { replayBudget?.researchTimedStopAudioHandoffBridges = researchTimedStopAudioHandoffBridges }
                            replayBudget?.researchTimedStopZeroCallbackCompleted = researchTimedStopZeroCallbackCompleted
                            if researchZeroCallbackFollowthrough { replayBudget?.researchZeroFollowthroughSteps = researchZeroFollowthroughSteps }
                            if researchZeroCallbackFollowthrough {
                                replayBudget?.researchStreamResetHandoffs = researchStreamResetHandoffs
                                replayBudget?.researchStreamResetControlsCancelled = researchStreamResetControlsCancelled
                                replayBudget?.researchStreamResetCompletionRecoveries = researchStreamResetCompletionRecoveries
                                replayBudget?.researchStreamPlaybackHandoffs = researchStreamPlaybackHandoffs
                                replayBudget?.researchStreamPlaybackHandoffIssue = researchStreamPlaybackHandoffIssue
                                replayBudget?.researchPlaybackConcurrentControlCompletions = researchPlaybackConcurrentControlCompletions
                                replayBudget?.researchPlaybackConcurrentStreamCompletions = researchPlaybackConcurrentStreamCompletions
                                replayBudget?.researchPlaybackPositionRecoveries = researchPlaybackPositionRecoveries
                                replayBudget?.researchPlaybackPositionRecoveryAttempts = researchPlaybackPositionRecoveryAttempts
                                replayBudget?.researchPlaybackPositionIssue = researchPlaybackPositionIssue
                                replayBudget?.researchStreamReassertHandoffs = researchStreamReassertHandoffs
                                replayBudget?.researchStreamNaturalCompletions = researchStreamNaturalCompletions
                                replayBudget?.researchStreamCompletionIssue = researchStreamCompletionIssue
                                replayBudget?.researchStreamCompletionWaits = researchStreamCompletionWaits
                                replayBudget?.researchFrameAudioCompletions = researchFrameAudioCompletions
                                replayBudget?.researchFrameStartAudioCompletions = researchFrameStartAudioCompletions
                                replayBudget?.researchFrameStartCombinedControlCompletions = researchFrameStartCombinedControlCompletions
                                replayBudget?.researchStreamControlHandoffs = researchStreamControlHandoffs
                                replayBudget?.researchStreamControlHandoffIssue = researchStreamControlHandoffIssue
                                replayBudget?.researchStreamControlIssueBefore = researchStreamControlIssueBefore
                                replayBudget?.researchStreamControlIssueAfter = researchStreamControlIssueAfter
                                replayBudget?.researchStreamControlClassification = researchStreamControlClassification
                                replayBudget?.researchStreamOtherChannelControlCompletions = researchStreamOtherChannelControlCompletions
                                replayBudget?.researchStreamRecoveryControlCompletions = researchStreamRecoveryControlCompletions
                                replayBudget?.researchStreamReassertControlCompletions = researchStreamReassertControlCompletions
                                replayBudget?.researchStreamControlCompletions = researchStreamControlCompletions
                                replayBudget?.researchSkipPendingScriptSteps = researchSkipPendingScriptSteps
                                replayBudget?.researchZeroPendingScriptSteps = researchZeroPendingScriptSteps
                            }
                            if researchZeroAudioDrawFrame {
                                replayBudget?.researchDrawAudioPositionsBefore = researchDrawAudioPositionsBefore
                                replayBudget?.researchDrawAudioPositionsAfter = researchDrawAudioPositionsAfter
                                replayBudget?.researchDrawAudioFollowthroughSteps = researchDrawAudioFollowthroughSteps
                                replayBudget?.researchFollowthroughMaximumSteps = researchFollowthroughMaximumSteps ?? 6_000_000
                                replayBudget?.researchFollowthroughMaximumSeconds = researchFollowthroughMaximumSeconds ?? 120
                                if machine.phase == .waiting {
                                    replayBudget?.researchDrawWaitRemaining = machine.clickWaitRemaining
                                    replayBudget?.researchDrawWaitNextTimer = machine.ticksUntilTimer
                                }
                                replayBudget?.researchDrawEventCallbackDispatched = researchDrawEventCallbackDispatched
                                replayBudget?.researchDrawWaitZeroTimerFrame = researchDrawWaitZeroTimerFrame
                                replayBudget?.researchDrawWaitTimerFrames = researchDrawWaitTimerFrames
                                replayBudget?.researchDrawWaitTimerDispatched = researchDrawWaitTimerDispatched
                                replayBudget?.researchDrawWaitTimerDispatchCount = researchDrawWaitTimerDispatchCount
                                replayBudget?.researchDrawWaitCompleted = researchDrawWaitCompleted
                                replayBudget?.researchDrawStoryChoiceDispatched = researchDrawStoryChoiceDispatched
                                replayBudget?.researchChoiceWaitZeroFrame = researchChoiceWaitZeroFrame
                                replayBudget?.researchChoiceWaitFrames = researchChoiceWaitFrames
                                replayBudget?.researchChoiceWaitTimerDispatchCount = researchChoiceWaitTimerDispatchCount
                                replayBudget?.researchChoicePostWaitZeroFrame = researchChoicePostWaitZeroFrame
                                replayBudget?.researchChoicePostWaitFrames = researchChoicePostWaitFrames
                                replayBudget?.researchChoicePostWaitCompleted = researchChoicePostWaitCompleted
                                replayBudget?.researchChoicePostWaitCompletedCount = researchChoicePostWaitCompletedCount
                                replayBudget?.researchChoicePostDrawFrames = researchChoicePostDrawFrames
                                replayBudget?.researchLaterWaitZeroFrame = researchLaterWaitZeroFrame
                                replayBudget?.researchLaterWaitFrames = researchLaterWaitFrames
                                replayBudget?.researchLaterWaitTimerCount = researchLaterWaitTimerCount
                                replayBudget?.researchLaterWaitCompleted = researchLaterWaitCompleted
                                replayBudget?.researchLaterChoiceDispatched = researchLaterChoiceDispatched
                                replayBudget?.researchLaterChoiceWaitZeroFrame = researchLaterChoiceWaitZeroFrame
                                replayBudget?.researchLaterChoiceWaitFrames = researchLaterChoiceWaitFrames
                                replayBudget?.researchLaterChoiceWaitTimerCount = researchLaterChoiceWaitTimerCount
                                replayBudget?.researchLaterChoiceWaitCompleted = researchLaterChoiceWaitCompleted
                                replayBudget?.researchLaterPostWaitZeroFrames = researchLaterPostWaitZeroFrames
                                replayBudget?.researchLaterPostWaitFrames = researchLaterPostWaitFrames
                                replayBudget?.researchLaterPostWaitCompletedCount = researchLaterPostWaitCompletedCount
                                replayBudget?.researchThirdWaitZeroFrame = researchThirdWaitZeroFrame
                                replayBudget?.researchThirdWaitFrames = researchThirdWaitFrames
                                replayBudget?.researchThirdWaitTimerCount = researchThirdWaitTimerCount
                                replayBudget?.researchThirdWaitCompleted = researchThirdWaitCompleted
                                replayBudget?.researchThirdChoiceDispatched = researchThirdChoiceDispatched
                                replayBudget?.researchThirdChoiceWaitFrames = researchThirdChoiceWaitFrames
                                replayBudget?.researchThirdChoiceWaitTimers = researchThirdChoiceWaitTimers
                                replayBudget?.researchThirdChoiceWaitCompleted = researchThirdChoiceWaitCompleted
                                replayBudget?.researchThirdPostWaitFrames = researchThirdPostWaitFrames
                                replayBudget?.researchThirdPostWaitCompleted = researchThirdPostWaitCompleted
                                replayBudget?.researchFourthWaitZeroFrame = researchFourthWaitZeroFrame
                                replayBudget?.researchFourthWaitFrames = researchFourthWaitFrames
                                replayBudget?.researchFourthWaitTimerCount = researchFourthWaitTimerCount
                                replayBudget?.researchFourthWaitCompleted = researchFourthWaitCompleted
                                replayBudget?.researchFourthChoiceDispatched = researchFourthChoiceDispatched
                                replayBudget?.researchFourthChoiceWaitFrames = researchFourthChoiceWaitFrames
                                replayBudget?.researchFourthChoiceWaitTimers = researchFourthChoiceWaitTimers
                                replayBudget?.researchFourthChoiceWaitCompleted = researchFourthChoiceWaitCompleted
                                replayBudget?.researchFourthPostWaitFrames = researchFourthPostWaitFrames
                                replayBudget?.researchFourthPostWaitCompleted = researchFourthPostWaitCompleted
                                replayBudget?.researchFollowthroughInitialPlayMode = researchFollowthroughInitialPlayMode
                                replayBudget?.researchFollowthroughPlayModeChanges = researchFollowthroughPlayModeChanges
                                replayBudget?.researchFollowthroughPlayModeChangesTruncated = researchFollowthroughPlayModeChangesTruncated
                                if machine.phase == .waitingForEvent {
                                    replayBudget?.researchDrawEventScoped = machine.hasScopedStop
                                    replayBudget?.researchDrawEventStoryChoice = machine.isWaitingForStoryChoice
                                    replayBudget?.researchDrawEventTimed = machine.timedStopRequest != nil
                                    replayBudget?.researchDrawEventPlayMode = machine.researchMessageWaitPlayMode
                                    replayBudget?.researchDrawEventPendingMessages = machine.researchMessageWaitPendingCount
                                }
                                replayBudget?.researchDrawAudioFrames = researchDrawAudioFrames
                                replayBudget?.researchDrawAudioControlIssue = researchDrawAudioControlIssue
                                if researchSkipAudioFrame {
                                    replayBudget?.researchSkipAudioFrameHandled = researchSkipAudioFrameHandled
                                    replayBudget?.researchSkipAudioFramesHandled = researchSkipAudioFramesHandled
                                }
                                replayBudget?.researchDrawAudioFrameScope = "bounded_explicit_positive_virtual_frames_and_script_matched_muted_streams_wall_clock_not_synchronized_original_equivalence_not_tested"
                            }
                            replayBudget?.researchTimedStopFrameScope = "explicit_virtual_frame_callback_no_active_timer_or_movie_one_matched_stream_zero_frame_only_original_scheduling_not_tested"
                        }
                        if researchLabelReadStatus {
                            replayBudget?.labelHistoryReadStatus = .inferred
                            replayBudget?.labelHistoryImported = machine.labelHistoryStorageShape["importedHistory"] == 1
                            replayBudget?.labelHistoryReadOutcomes = machine.labelHistoryReadOutcomes
                            if researchSkipFrame {
                                replayBudget?.researchUnreadLabelQueries = machine.researchUnreadLabelQueries
                                replayBudget?.researchUnreadLabelQueriesTruncated = machine.researchUnreadLabelQueriesTruncated
                            }
                        }
                        if researchVideoImageDimensions {
                            replayBudget?.videoImageDimensions = .inferred
                            replayBudget?.videoImageDimensionsScope = "standalone_theora_header_dimensions_original_surface_equivalence_not_tested"
                        }
                        if researchLabelProgress {
                            replayBudget?.labelProgressTracking = .inferred
                            replayBudget?.labelProgressTrackingScope = "primary_machine_completed_lines_unique_label_same_source_or_one_label_free_include_original_path_and_reader_equivalence_not_tested"
                            replayBudget?.labelProgressCandidateOutcomes = machine.labelProgressCandidateOutcomes
                            replayBudget?.labelProgressReturnOutcomes = machine.labelProgressReturnOutcomes
                            replayBudget?.labelProgressFirstContexts = machine.labelProgressFirstContexts
                        }
                        if researchSkipFrame {
                            replayBudget?.skipFrameCandidate = .inferred
                            replayBudget?.skipFrameCandidateScope = "positive_host_clock_samples_only_context_flag_assumed_clear_other_flag_writers_unmodelled"
                            replayBudget?.skipFrameCandidateSamples = machine.researchSkipFrameSamples
                            replayBudget?.researchPlacementConflict = machine.researchPlacementConflict
                        }
                        if researchSkipTime {
                            replayBudget?.skipTimeCandidate = .inferred
                            replayBudget?.skipTimeCandidateScope = "finite_wait_candidate_zero_frame_observed_streams_only_no_timer_or_movie_other_scheduler_effects_not_tested"
                            replayBudget?.skipTimeConsumed = machine.researchSkipTimeConsumed
                            replayBudget?.skipTimePending = machine.pendingResearchSkipTime
                            if researchZeroLiveAudio {
                                replayBudget?.researchZeroLiveAudioFrames = researchZeroLiveAudioFrames
                                if researchZeroWaitFollowthrough { replayBudget?.researchZeroWaitFollowthroughSteps = researchZeroWaitFollowthroughSteps }
                                if researchZeroEventCallback {
                                    replayBudget?.researchZeroEventCallbackSteps = researchZeroEventCallbackSteps
                                    replayBudget?.researchZeroEventContinuationSteps = researchZeroEventContinuationSteps
                                    replayBudget?.researchZeroEventStreamResets = researchZeroEventStreamResets
                                    replayBudget?.researchZeroEventVolumeHandoffs = researchZeroEventVolumeHandoffs
                                    replayBudget?.researchZeroEventCallbackCompleted = researchZeroEventCallbackCompleted
                                    replayBudget?.researchZeroEventWaitLocation = researchZeroEventWaitLocation
                                    replayBudget?.researchZeroEventCallbackLocation = researchZeroEventCallbackLocation
                                    replayBudget?.researchSubsequentButtonSites = researchSubsequentButtonSites
                                }
                                replayBudget?.researchZeroLiveAudioPositions = researchZeroLiveAudioPositions
                                replayBudget?.researchZeroLiveAudioScope = "muted_realtime_matching_streams_zero_base_elapsed_pending_skip_may_apply_native_equivalence_not_tested"
                            }
                            if (researchHostIssue?.hasPrefix("zero_event_callback_") ?? false) ||
                                (researchHostIssue?.hasPrefix("zero_event_continuation_") ?? false) ||
                                (researchHostIssue?.hasPrefix("zero_wait_followthrough_") ?? false) ||
                                researchHostIssue == "zero_clock_active_audio_unsupported" ||
                                researchHostIssue == "draw_frame_active_audio_unsupported" ||
                                researchHostIssue == "zero_live_audio_positive_frame_unsupported" ||
                                researchHostIssue == "zero_live_audio_followup_unsupported" ||
                                (researchHostIssue?.hasPrefix("zero_followthrough_") ?? false) ||
                                (researchHostIssue?.hasPrefix("zero_draw_audio_") ?? false) ||
                                (researchHostIssue?.hasPrefix("skip_audio_frame_") ?? false) {
                                replayBudget?.researchZeroClockActiveAudio = machine.researchActiveAudioSnapshots
                            }
                            if researchDrawFrames != nil {
                                replayBudget?.researchDrawFramesAdvanced = researchDrawFramesAdvanced
                                replayBudget?.researchDrawFrameTicks = researchDrawFrameTicks
                                replayBudget?.researchDrawZeroClockFrames = machine.researchDrawZeroClockFrames
                                replayBudget?.researchWaitZeroClockFrames = machine.researchWaitZeroClockFrames
                            }
                            replayBudget?.researchDrawBoundaryReached = machine.phase == .waitingForFrame
                            if machine.phase == .waitingForFrame {
                                replayBudget?.researchDrawBoundaryCount = machine.researchPendingDrawCount
                            }
                            if researchSkipMediaHandoff { replayBudget?.skipTimeMediaHandoffs = researchSkipMediaHandoffs }
                            if researchHostIssue != nil {
                                replayBudget?.skipTimePendingPhase = machine.phase.rawValue
                                if let request = machine.moviePlaybackRequest {
                                    replayBudget?.skipTimePendingMediaKind = "movie"
                                    replayBudget?.skipTimePendingMediaSource = request.resource
                                } else if let request = machine.soundPlaybackRequest {
                                    replayBudget?.skipTimePendingMediaKind = machine.soundPlaybackIsStream ? "stream_audio" : "direct_audio"
                                    replayBudget?.skipTimePendingMediaSource = request
                                }
                            }
                        }
                        if researchWindowSkip {
                            replayBudget?.researchWindowSkipDispatched = researchWindowSkipDispatched
                            replayBudget?.researchWindowSkipAvailabilitySamples = researchWindowSkipAvailabilitySamples
                                replayBudget?.researchReturnedTitleObserved = researchReturnedTitleObserved
                                replayBudget?.researchReturnedTitleStartDispatched = researchReturnedTitleStartDispatched
                                replayBudget?.researchReturnedTitleStartSteps = researchReturnedTitleStartSteps
                                replayBudget?.researchReturnedTitleStartPhase = researchReturnedTitleStartPhase
                                replayBudget?.researchReturnedTitlePostWaitFrames = researchReturnedTitlePostWaitFrames
                                replayBudget?.researchReturnedTitlePostWaitCompleted = researchReturnedTitlePostWaitCompleted
                                replayBudget?.researchReturnedTitleAfterWaitPhase = researchReturnedTitleAfterWaitPhase
                                replayBudget?.researchRestartSelectionWaitZeroFrame = researchRestartSelectionWaitZeroFrame
                                replayBudget?.researchRestartSelectionWaitFrames = researchRestartSelectionWaitFrames
                                replayBudget?.researchRestartSelectionWaitTimers = researchRestartSelectionWaitTimers
                                replayBudget?.researchRestartSelectionWaitCompleted = researchRestartSelectionWaitCompleted
                        }
                        if researchWindowAuto {
                            replayBudget?.researchWindowAutoDispatched = researchWindowAutoDispatched
                            replayBudget?.researchWindowAutoAvailabilitySamples = researchWindowAutoAvailabilitySamples
                            replayBudget?.researchWindowAutoModeBefore = researchWindowAutoModeBefore
                            replayBudget?.researchWindowAutoModeAfter = researchWindowAutoModeAfter
                        }
                        if let researchAutoFrameTicks {
                            replayBudget?.researchAutoFrameTicks = researchAutoFrameTicks
                            replayBudget?.researchAutoFrames = autoFrameCount
                            replayBudget?.researchAutoFrameIssue = autoFrameIssue
                            replayBudget?.researchAutoFrameInitialSteps = autoFrameInitialSteps
                            replayBudget?.researchAutoFramePlayObserved = autoFramePlayObserved
                            replayBudget?.researchAutoFrameAudioBefore = autoFrameAudioBefore
                            replayBudget?.researchAutoFrameAudioAfter = autoFrameAudioAfter
                            replayBudget?.researchAutoFrameElapsedTicks = autoFrameElapsedTicks
                            replayBudget?.researchAutoAudioPositionRetries = autoAudioPositionRetries
                            replayBudget?.researchAutoAudioCompletionWaits = autoAudioCompletionWaits
                            replayBudget?.researchAutoFrameScope = researchAutoRealtime
                                ? "monotonic_ms_native_host_delta_candidate_observed_audio_extra_clock_native_scheduling_not_tested"
                                : "explicit_bounded_callback_ticks_observed_audio_clock_not_synchronized_no_timer_native_scheduling_not_tested"
                        }
                        if researchAutoAdditionalLines != nil { replayBudget?.researchAutoAdditionalLines = autoAdditionalLines }
                        if researchAutoFollowTimedWait { replayBudget?.researchAutoTimedWait = autoTimedWait }
                        if researchAutoTimedWaitCount != nil { replayBudget?.researchAutoTimedWaits = autoTimedWaits }
                        if researchAutoAfterTimedLines != nil {
                            replayBudget?.researchAutoAfterTimedLines = autoAfterTimedLines
                            replayBudget?.researchAutoAfterTimedMaxSeconds = researchAutoAfterTimedMaxSeconds ?? 20
                        }
                        if researchAutoAfterLinesTimedWait { replayBudget?.researchAutoAfterLinesTimedWaits = autoAfterLinesTimedWaits }
                        if researchImageFileLog {
                            replayBudget?.imageFileLogTracking = .inferred
                            replayBudget?.imageFileLogTrackingScope = "primary_machine_image_loads_only_original_resolved_path_not_tested"
                            replayBudget?.imageFileLogCandidateAttempts = machine.imageFileLogCandidateAttempts
                            replayBudget?.imageFileLogCandidateMatches = machine.imageFileLogCandidateMatches
                            replayBudget?.imageFileLogCandidateOutcomes = machine.imageFileLogCandidateOutcomes
                            replayBudget?.firstImageFileLogNoMatchSnapshot = machine.firstImageFileLogNoMatchSnapshot
                        }
                        if researchAudioFileLog {
                            replayBudget?.audioFileLogTracking = .inferred
                            replayBudget?.audioFileLogTrackingScope = "primary_machine_validated_wave_and_vorbis_loads_only_original_resolved_path_not_tested"
                            replayBudget?.audioFileLogCandidateAttempts = machine.audioFileLogCandidateAttempts
                            replayBudget?.audioFileLogCandidateOutcomes = machine.audioFileLogCandidateOutcomes
                        }
                        result = machine.summary
                        pendingMovieVolume = machine.moviePlaybackRequest?.volume
                        saveResumeBoundary = machine.saveResumeBoundary
                        var saveThumbnail: Data?
                        if scenePreviewBackground != nil, machine.phase == .waitingForSystemTask {
                            // Only the isolated continuation can supply a scene while the parent is suspended.
                            if exportScenePreviewPNG {
                                scenePreviewIssue = "saved_scene_png_export_unavailable"
                            } else if let draw = loadTask?.saveResumeBoundary?.replaySceneDraw {
                                if draw.status == .unsupported {
                                    scenePreviewIssue = draw.issue ?? "saved_scene_preview_incomplete"
                                }
                            } else if loadTask?.machine.status != .unsupported {
                                scenePreviewIssue = "saved_scene_preview_unavailable"
                            }
                        } else if let background = scenePreviewBackground {
                            do {
                                var previewMachine = machine
                                previewMachine.advanceVisualClock(ticks: scenePreviewTicks ?? 0)
                                let preview = try LoadThumbnailPass(task: previewMachine, assets: directory,
                                    recipe: imageRecipe, backgroundPath: background, suppliedCapture: nil,
                                    saveDirectory: saveDirectory,
                                    choicePointer: pointer.map { CGPoint(x: Int($0.x), y: Int($0.y)) },
                                    canvasSize: scenePreviewCanvas,
                                    cutinFrameTicks: scenePreviewCutinTicks,
                                    cutinFrame: scenePreviewCutinTicks.flatMap { ticks in movieHost.map { host in
                                        { source, range in try host.cutinFrame(source, range: range, ticks: ticks) }
                                    } },
                                    sceneVideoFrame: scenePreviewVideoFrames ? movieHost.map { host in
                                        { source, ticks in try host.standaloneSceneFrame(source, ticks: ticks) }
                                    } : nil,
                                    frozenVideoFirstFrame: scenePreviewFrozenVideoFirstFrame,
                                    unclockedVideoSampleTicks: researchSceneVideoSampleTicks,
                                    filterOutputMaskCandidate: researchSceneOutputMask,
                                    researchBarPreview: researchBarScenePreview,
                                    omitResearchBarComponents: researchBarSceneControl,
                                    exportPNG: exportScenePreviewPNG ? { scenePNG = $0 } : nil,
                                    exportJPEG: saveSceneThumbnail ? { saveThumbnail = $0 } : nil)
                                scenePreview = preview
                                if requireCompleteScenePreview,
                                   preview.isIncomplete {
                                    scenePreviewIssue = "scene_preview_incomplete"
                                }
                            } catch {
                                scenePreviewIssue = String(describing: error)
                            }
                        }
                        if let donorName = researchSlotDonor, let saveDirectory {
                            do {
                                let donor = try saveDirectory.read(donorName, limit: SaveEnvelope.maxFileBytes)
                                guard let slot = try SaveEnvelope(donor).slot else {
                                    throw ResourceError.rejected("research_slot_donor_required")
                                }
                                let template = try SaveEnvelope.decodeSlotState(donor, inferSeed: inferSaveStateSeed)
                                if let path = researchMessageTemplatePath {
                                    do {
                                        let url = URL(fileURLWithPath: path)
                                        let templateDirectory = try SafeDirectory(url.deletingLastPathComponent())
                                        let bytes = try templateDirectory.read(url.lastPathComponent, limit: SaveEnvelope.maxFileBytes)
                                        let state = try SaveEnvelope.decodeSlotState(bytes, inferSeed: true)
                                        replayBudget?.messagePrimaryWriteProbe = try machine.probeMessagePrimaryWrites(templateState: state)
                                    } catch {
                                        replayBudget?.messagePrimaryWriteProbeIssue = String(describing: error)
                                    }
                                }
                                if let path = researchImageTemplatePath {
                                    do {
                                        let url = URL(fileURLWithPath: path)
                                        let templateDirectory = try SafeDirectory(url.deletingLastPathComponent())
                                        let bytes = try templateDirectory.read(url.lastPathComponent, limit: SaveEnvelope.maxFileBytes)
                                        let state = try SaveEnvelope.decodeSlotState(bytes, inferSeed: true)
                                        replayBudget?.imagePlacementWriteProbe = try machine.probeImagePlacementWrites(templateState: state)
                                    } catch {
                                        replayBudget?.imagePlacementWriteProbeIssue = String(describing: error)
                                    }
                                }
                                if saveSceneThumbnail {
                                    guard saveThumbnail != nil, scenePreview?.isIncomplete == false else {
                                        throw ResourceError.rejected(scenePreviewIssue ?? "save_scene_thumbnail_incomplete")
                                    }
                                }
                                let thumbnail = saveThumbnail ?? Data(donor.dropFirst(slot.thumbnail.offset).prefix(slot.thumbnail.length))
                                let now = Date()
                                let localSeconds = now.timeIntervalSince1970 + Double(TimeZone.current.secondsFromGMT(for: now))
                                let displaySurfaces = try researchDisplaySurfaces.mapValues { path in
                                    let url = URL(fileURLWithPath: path)
                                    let directory = try SafeDirectory(url.deletingLastPathComponent())
                                    let payload = try directory.read(url.lastPathComponent, limit: SaveEnvelope.maxFileBytes)
                                    _ = try ResourceImage.decode(payload)
                                    return payload
                                }
                                if observeLiveAudio, observedPositions == nil || observedAudioIssue != nil {
                                    throw ResourceError.rejected(observedAudioIssue ?? "live_audio_positions_unavailable")
                                }
                                var positionsForWrite = researchStreamPositions
                                if let liveAudioObserver {
                                    try liveAudioObserver.synchronizeControls(machine: &machine)
                                    positionsForWrite = try liveAudioObserver.positions(for: machine.activeStreamPlaybackSnapshots)
                                    replayBudget?.liveAudio?.positionsAtWriteRequest = positionsForWrite
                                    replayBudget?.liveAudio?.completedControlCount = liveAudioObserver.completedControlCount
                                    replayBudget?.liveAudio?.pendingControlCount = liveAudioObserver.pendingControlCount
                                    replayBudget?.liveAudio?.rejectedControlCount = liveAudioObserver.rejectedControlCount
                                    replayBudget?.liveAudio?.completedPlaybackCount = liveAudioObserver.completedPlaybackCount
                                    if liveAudioObserver.rejectedControlCount > 0 {
                                        throw ResourceError.rejected("live_audio_control_unacknowledged")
                                    }
                                    // Diagnose audio independently of global-object
                                    // preflight; never use this copy as a slot.
                                    do {
                                        _ = try machine.encodeTimedWaitStreams(template: template, positions: positionsForWrite)
                                        replayBudget?.liveAudio?.saveAudioPreflightStatus = .inferred
                                    } catch {
                                        replayBudget?.liveAudio?.saveAudioPreflightStatus = .unsupported
                                        replayBudget?.liveAudio?.saveAudioPreflightIssue = String(describing: error)
                                    }
                                }
                                researchSlot = try machine.encodeTimedWaitResearchSlot(template: template,
                                    positions: positionsForWrite,
                                    displaySurfaces: displaySurfaces,
                                    metadata: SaveEnvelope.readSlotMetadata(donor), thumbnail: thumbnail,
                                    savedDays: localSeconds / 86_400 + 25_569)
                            } catch {
                                researchSlotIssue = String(describing: error)
                            }
                        }
                        if researchConfigOutput != nil {
                            researchConfigOutputData = try machine.encodeResearchConfigurationOverlay()
                        }
                        if researchSystemOutput != nil, let researchSystemData {
                            do {
                                researchSystemOutputData = try machine.encodeResearchSystemData(researchSystemData)
                            } catch {
                                researchSlotIssue = String(describing: error)
                            }
                        }
                        if researchSettingsOutput != nil, let researchSystemData {
                            do {
                                let system = try machine.encodeResearchSystemData(researchSystemData)
                                let overlay = try machine.encodeResearchConfigurationOverlay()
                                researchSettingsOutputData = try ResearchSettingsBundle(systemData: system, configurationOverlay: overlay).encode()
                            } catch {
                                researchSlotIssue = String(describing: error)
                            }
                        }
                        if requireRouteReturn {
                            if choiceCursor != storyChoices.count {
                                routeIssue = "route_choices_not_consumed"
                            } else if machine.isWaitingForStoryChoice {
                                routeIssue = "route_additional_choice_required"
                            } else if titleMenuTarget != nil ? !routeTitleReachedBeforeMenu :
                                        (machine.phase != .waitingForEvent || !machine.canStartFromTitle) {
                                routeIssue = "route_did_not_return_to_title"
                            }
                        }
                        if titleMenuTarget == "memory", !requireRouteReturn, choiceCursor != storyChoices.count {
                            routeIssue = "memory_story_choices_not_consumed"
                        }
                        if startFromTitle && !startedFromTitle { routeIssue = "title_start_not_reached" }
                        if titleMenuTarget != nil && titleMenuActions.count != 2 {
                            routeIssue = titleMenuIssue ?? (machine.phase == .stopped ? machine.stopReason : nil) ??
                                "title_menu_target_not_reached"
                        }
                        if inspectLabelHistory, ["label_read_status_unsupported", "label_read_status_context_unsupported"]
                            .contains(machine.stopReason ?? "") {
                            let probe = try JSONEncoder().encode(machine.labelHistoryProbe)
                            FileHandle.standardError.write(Data("label_history_probe=".utf8) + probe + Data([10]))
                            let shape = try JSONEncoder().encode(machine.labelHistoryStorageShape)
                            FileHandle.standardError.write(Data("label_history_storage_shape=".utf8) + shape + Data([10]))
                        }
                        if machine.stopReason == "ambiguous_module_variants" { candidates = machine.pendingModuleCandidates }
                    }
                    guard try directory.read(item.source_file).sha256Hex == sha else { throw ResourceError.rejected("script_source_changed") }
                    let adoptedFromRestoreBoundary = loadTask?.experimentalAdoption != nil &&
                        loadTask?.machine.stopReason == "save_restore_execution_state_unsupported"
                    let loadFailure = loadTask?.machine.status == .unsupported && !adoptedFromRestoreBoundary
                    let issue = researchHostIssue ?? researchSlotIssue ?? loadTask?.experimentalAdoptionIssue ?? routeIssue ?? liveAudioObservationIssue ?? scenePreviewIssue ?? loadTask?.thumbnailIssue ??
                        (loadFailure ? loadTask?.machine.stopReason : nil) ??
                        (result?.status == .unsupported ? result?.stopReason : nil)
                    reports.append(ScriptRunReport(
                        status: issue != nil || loadFailure ? .unsupported : (result?.status ?? .inferred),
                        lexical: lexical, machine: result, issue: issue,sourceFile: item.source_file,sourceSHA256: sha,moduleCandidates: candidates,
                        replayBudget: replayBudget,loadTask: loadTask,saveResumeBoundary: saveResumeBoundary,
                        scenePreview: scenePreview, scenePreviewIssue: scenePreviewIssue,
                        pendingMovieVolume: pendingMovieVolume))
                } catch {
                    reports.append(ScriptRunReport(status: .unsupported,lexical: nil,machine: nil,
                        issue: String(describing: error),sourceFile: item.source_file,sourceSHA256: sha,moduleCandidates: nil,replayBudget: nil,loadTask: nil))
                }
            }
            let report = ScriptBatchReport(status: reports.contains { $0.status == .unsupported } ? .unsupported : .inferred,
                mode: execute ? (repository == nil ? "experimental_single_file" : "experimental_pinned_modules") : "lexical_metadata_only",reports: reports)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
            let json = try encoder.encode(report) + Data([10])
            if researchConfigOutput != nil {
                guard report.status != .unsupported, let data = researchConfigOutputData,
                      let directory = researchConfigOutputDirectory, let name = researchConfigOutputName else {
                    FileHandle.standardError.write(json)
                    exit(2)
                }
                try directory.writeNew(name, data: data, limit: 64 * 1024)
                FileHandle.standardError.write(Data("research_config_overlay=inferred native_format=unsupported\n".utf8))
            }
            if researchSystemOutput != nil {
                guard report.status != .unsupported, let data = researchSystemOutputData,
                      let directory = researchOutputDirectory, let name = researchOutputName else {
                    FileHandle.standardError.write(json)
                    exit(2)
                }
                try directory.writeNew(name, data: data)
                FileHandle.standardError.write(Data("research_system_output=inferred automatic_read_tracking=unsupported\n".utf8))
            }
            if researchSettingsOutput != nil {
                guard report.status != .unsupported, let data = researchSettingsOutputData,
                      let directory = researchSettingsOutputDirectory, let name = researchSettingsOutputName else {
                    FileHandle.standardError.write(json)
                    exit(2)
                }
                try directory.writeNewAtomically(name, data: data, limit: 12 * 1024 * 1024)
                FileHandle.standardError.write(Data("research_settings_bundle=inferred native_format=unsupported\n".utf8))
            }
            if researchSlotDonor != nil {
                FileHandle.standardError.write(json)
                if report.status != .unsupported, let researchSlot {
                    try FileHandle.standardOutput.write(contentsOf: researchSlot)
                } else {
                    exit(2)
                }
            } else if exportScenePreviewPNG {
                FileHandle.standardError.write(json)
                if let scenePNG { FileHandle.standardOutput.write(scenePNG) }
            } else {
                FileHandle.standardOutput.write(json)
            }
            if report.status == .unsupported { exit(2) }
        } catch {
            FileHandle.standardError.write(Data("Mangekyou script: \(error)\n".utf8)); exit(2)
        }
    }
}
