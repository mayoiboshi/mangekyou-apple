import AVKit
import AVFoundation
import AppKit
import CoreText
import Combine
import SwiftUI
import MangekyouCore
import MangekyouMedia

private struct PlayerVideoView: NSViewRepresentable {
    let player: AVPlayer
    let traceCutin: Bool

    final class Coordinator {
        var readiness: NSKeyValueObservation?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resize
        view.player = player
        if traceCutin {
            context.coordinator.readiness = view.observe(\.isReadyForDisplay, options: [.initial, .new]) { _, change in
                guard change.newValue == true else { return }
                FileHandle.standardError.write(Data("player_cutin_first_frame_ready=1\n".utf8))
            }
        }
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

private final class PlayerAudioCompletion: NSObject, AVAudioPlayerDelegate {
    let finish: @MainActor @Sendable (ObjectIdentifier, String?) -> Void

    init(finish: @escaping @MainActor @Sendable (ObjectIdentifier, String?) -> Void) {
        self.finish = finish
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        complete(player, error: flag ? nil : "音频未能播放完毕")
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        complete(player, error: error?.localizedDescription ?? "音频解码失败")
    }

    private func complete(_ player: AVAudioPlayer, error: String?) {
        let identity = ObjectIdentifier(player)
        Task { @MainActor [finish] in finish(identity, error) }
    }
}

private struct PlayerViewport {
    static let width: CGFloat = 1280
    static let height: CGFloat = 720
    let scale: CGFloat
    let origin: CGPoint

    init(_ size: CGSize) {
        let scale = min(size.width / Self.width, size.height / Self.height)
        self.scale = scale
        origin = CGPoint(x: (size.width - Self.width * scale) / 2,
                         y: (size.height - Self.height * scale) / 2)
    }

    func displayRect(_ rect: CGRect) -> CGRect {
        CGRect(x: origin.x + rect.minX * scale, y: origin.y + rect.minY * scale,
               width: rect.width * scale, height: rect.height * scale)
    }

    var canvasBounds: CGRect {
        displayRect(CGRect(x: 0, y: 0, width: Self.width, height: Self.height))
    }

    func canvasPoint(_ point: CGPoint) -> CGPoint? {
        guard scale > 0 else { return nil }
        let x = (point.x - origin.x) / scale
        let y = (point.y - origin.y) / scale
        guard (0..<Self.width).contains(x), (0..<Self.height).contains(y) else { return nil }
        return CGPoint(x: x, y: y)
    }
}

private struct PlayerCanvasClip: Shape {
    func path(in rect: CGRect) -> Path {
        Path(PlayerViewport(rect.size).canvasBounds.offsetBy(dx: rect.minX, dy: rect.minY))
    }
}

private struct DialogueFrameTexture: Sendable {
    let image: CGImage
    let bounds: CGRect
    let alpha: UInt8
    var usesBoundSource = false
}

private struct PlayerLayer: Sendable, Identifiable {
    static let savedCaptureID = UInt64.max
    let id: UInt64
    var image: CGImage
    let hoverImage: CGImage?
    var x: Int32
    var y: Int32
    var priority: Int32
    var opacity: UInt8
    var scaleXPercent: Int32
    var scaleYPercent: Int32
    var motionOffset: CGPoint = .zero
    let alignmentXPercent: Int32
    let alignmentYPercent: Int32
    var textureFilter: Int32?
    let usesVolumeButtonOffsets: Bool
    let isWindowControl: Bool
    var isDialogBlack = false
    var isWhiteFlash = false
    var dialogueFrameTextures: [DialogueFrameTexture]? = nil

    var bounds: CGRect {
        if let textures = dialogueFrameTextures { return textures.first?.bounds ?? .zero }
        return bounds(for: image)
    }

    func containsInteractivePoint(_ point: CGPoint) -> Bool {
        opacity > 0 && bounds.contains(point)
    }


    func bounds(for raster: CGImage, textureOffset: CGFloat = 0) -> CGRect {
        let width = CGFloat(raster.width) * abs(CGFloat(scaleXPercent)) / 100
        let height = CGFloat(raster.height) * abs(CGFloat(scaleYPercent)) / 100
        return CGRect(x: CGFloat(x) + motionOffset.x + textureOffset - (width * CGFloat(alignmentXPercent) / 100).rounded(),
                      y: CGFloat(y) + motionOffset.y + textureOffset - (height * CGFloat(alignmentYPercent) / 100).rounded(),
                      width: width, height: height)
    }
}

private struct PlayerCutinSource: Sendable {
    static let sha256 = "06e44e46d8ba357eb49f61bfca45c320aa0f281f3ec3656e1717f648edc13050"
    let resource: ScriptLocation
    let range: (offset: Int, length: Int, sha256: String)
}

private struct PlayerCutin: Sendable {
    let id: UInt64
    let priority: Int32
    let bounds: CGRect
    let opacity: UInt8
}

private struct PlayerState: Sendable {
    let playbackIdentity: UUID
    let cutinSource: PlayerCutinSource?
    var cutin: PlayerCutin?
    let status: (phase: ScriptMachinePhase, steps: Int, stopReason: String?, currentLocation: ScriptLocation?)
    var isTerminal: Bool { status.phase == .stopped || status.phase == .finished }
    let buttonSounds: [UInt64: [Int32: ScriptLocation]]
    let choiceButtons: [UInt64: Int32]
    let visibleChoiceButtons: [UInt64: Int32]
    var choices: [Int32] { choiceButtons.values.sorted() }
    let choiceText: [Int32: String]
    let choiceTextSizes: [UInt64: CGSize]
    let choiceTextStyles: [UInt64: ScriptMachine.ChoiceTextStyle]
    let waitingForChoice: Bool
    let windowViewButton: UInt64?
    let windowLoadButton: UInt64?
    let dialogueWindowHidden: Bool
    let isSystemLoadFrame: Bool
    let loadConfirmationButtons: [UInt64: Bool]
    let isWaitingForLoadConfirmation: Bool
    let visibleSaveThumbnails: Int
    let loadMenuButtons: Set<UInt64>
    var acceptsLoadEscape: Bool { isWaitingForLoadConfirmation || !loadMenuButtons.isEmpty }
    let loadCancelButton: UInt64?
    let loadPageIndices: [UInt64: Int32]
    let checkedLoadPageButtons: Set<UInt64>
    let titleButtons: [UInt64: Int32]
    let titleButtonLabels: [UInt64: String]
    let titleStartButton: UInt64?
    let waitingForClick: Bool
    var canStartFromTitle: Bool { titleStartButton != nil }
    var fullTextAlphas: [UInt64: UInt8]
    let messageLayers: [ScriptMachine.MessageTextLayer]
    var messages: [String] { messageLayers.map(\.text) }
    var layers: [PlayerLayer]
    var pendingOpacityImages: Set<UInt64>
    var unavailableLayers: [String]
    let unavailableLayerFailures: [UInt64: String]
    var unavailableLayerCount: Int { unavailableLayerFailures.count }
    var unimplementedAnimationCount: Int
    let maxMotionTicks: Int32
    let movie: PlayerMovie?
    let movieRequest: ScriptMachine.MoviePlaybackRequest?
    let systemTaskRequest: ScriptMachine.SystemTaskRequest?
    let soundChannel: UInt64?
    let soundSource: ScriptLocation?
    let soundPreservesPosition: Bool
    let soundRepeatCount: Int32
    let soundInitialVolume: Int32?
    let activeSoundChannels: Set<UInt64>
    let immediateSoundVolumes: [UInt64: Int32]
    let soundVolumeChanges: [UInt64: ScriptMachine.SoundControlChange]
    let immediateSoundPans: [UInt64: Int32]
    let soundPanChanges: [UInt64: ScriptMachine.SoundControlChange]
    let soundSeeks: [UInt64: Int32]
    let audioCacheHits: Int
    let audioConversions: Int
}

private struct PlaybackCache<Key: Hashable, Value> {
    private struct Entry {
        let value: Value
        let cost: Int
        var lastUse: UInt64
    }

    let byteLimit: Int
    let entryLimit: Int
    private var entries: [Key: Entry] = [:]
    private var bytes = 0
    private var clock: UInt64 = 0

    mutating func value(for key: Key) -> Value? {
        guard var entry = entries[key] else { return nil }
        clock += 1
        entry.lastUse = clock
        entries[key] = entry
        return entry.value
    }

    mutating func insert(_ value: Value, for key: Key, cost: Int) {
        guard cost <= byteLimit else { return }
        if let previous = entries.removeValue(forKey: key) { bytes -= previous.cost }
        while cost > byteLimit - bytes || entries.count >= entryLimit {
            guard let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse }) else { break }
            bytes -= oldest.value.cost
            entries.removeValue(forKey: oldest.key)
        }
        clock += 1
        entries[key] = Entry(value: value, cost: cost, lastUse: clock)
        bytes += cost
    }
}

private actor PlayerSession {
    enum Input: Sendable {
        case soundStarted
        case movieFinished(Int32)
        case start
        case titlePointer(x: Int32, y: Int32)
        case click
        case timerTick
        case canvasClick(x: Int32, y: Int32, titleButton: Int32?)
        case loadMenuButton(UInt64, x: Int32, y: Int32)
        case loadConfirmation(Bool)
        case loadMenuEscape
        case choice(Int32)
        case windowViewButton(UInt64)
        case windowLoadButton(UInt64)
    }
    private var machine: ScriptMachine
    private var tracedComposedSaveThumbnail = false
    private var playbackIdentity = UUID()
    private var systemLoadTask: ScriptMachine?
    private let saveDirectory: SafeDirectory?
    private var restoredDisplay: CGImage?
    private var systemCapture: (source: ScriptLocation, image: CGImage)?
    private let assets: SafeDirectory
    private let recipe: ScriptImageRecipe
    private let cutinSource: PlayerCutinSource?
    private let ffmpeg: URL
    private let accelerated: Bool
    private let skipAudioForChoiceProbe: Bool
    let replayChoices: [Int32]
    // The session starts candidates muted and transfers each player once.
    // Only the receiver accesses the player after removal from this queue.
    struct PreparedSaveAudio: @unchecked Sendable {
        let channel: UInt64
        let source: ScriptLocation
        let player: AVAudioPlayer
    }

    private var preparedSaveAudio: [PreparedSaveAudio] = []

    func takePreparedSaveAudio(channel: UInt64, source: ScriptLocation, identity: UUID) -> PreparedSaveAudio? {
        guard playbackIdentity == identity, let first = preparedSaveAudio.first,
              first.channel == channel, first.source == source else { return nil }
        return preparedSaveAudio.removeFirst()
    }

    let saveImportIssues: [String]
    private struct RasterKey: Hashable {
        let source: ScriptLocation
        let selectedMember: Int32?
        let choiceHover: Bool?
    }
    private struct Raster {
        let image: CGImage
        let isInterfaceBackgroundPreview: Bool
    }
    private struct SceneVideo: Sendable {
        let movie: PlayerMovie
        let asset: AVURLAsset
        let frames: Int64
        var lastIndex: Int64? = nil
        var lastImage: CGImage? = nil
    }
    private var sceneVideos: [ScriptLocation: SceneVideo] = [:]
    private var sceneVideoOrder: [ScriptLocation] = []
    private var activeSceneVideos: [UInt64: ScriptLocation] = [:]
    private var sceneVideoCycles: [UInt64: Int64] = [:]
    private var sceneVideoFailures: [ScriptLocation: String] = [:]

    deinit {
        for video in sceneVideos.values { video.movie.remove() }
    }

    private var rasterCache = PlaybackCache<RasterKey, Result<Raster, Error>>(byteLimit: 64 * 1024 * 1024, entryLimit: 1024)
    private var audioCacheHits = 0
    private var audioConversions = 0
    private static let maximumCachedAudioBytes = 8 * 1024 * 1024
    private var audioCache = PlaybackCache<ScriptLocation, Data>(byteLimit: 32 * 1024 * 1024, entryLimit: 256)
    private var buttonAudioCache = PlaybackCache<ScriptLocation, Data>(byteLimit: 2 * 1024 * 1024, entryLimit: 32)

    private struct ReplaySelection: Decodable {
        struct Configuration: Decodable {
            let source_file: String
            let sha256: String
        }

        struct Attempt: Decodable { let attempt: Int }

        let attempts: [Attempt]
        let story_choices: [Int32]
        let corpus_report_sha256: String
        struct Selection: Decodable { let source_file: String; let sha256: String }

        let selected_sources: [Selection]
        let configuration_source: Configuration?
        let image_resources: [ScriptModuleReference]?
        let audio_resources: [ScriptModuleReference]?
        let wave_resources: [ScriptModuleReference]?
    }

    init(assets: SafeDirectory, replayDirectory: URL, gameDirectory: URL, ffmpeg: URL, saveURL: URL?, accelerated: Bool, skipAudioForChoiceProbe: Bool, allowSaveAdoption: Bool) throws {
        self.assets = assets
        saveDirectory = try saveURL.map { try SafeDirectory($0) }
        self.ffmpeg = ffmpeg
        self.accelerated = accelerated
        self.skipAudioForChoiceProbe = skipAudioForChoiceProbe
        let replay = try SafeDirectory(replayDirectory)
        let decoder = JSONDecoder()
        func readReplay(_ name: String, limit: Int) throws -> Data {
            try Task.checkCancellation()
            do { return try replay.read(name, limit: limit) }
            catch let error as ResourceError {
                throw ResourceError.rejected("player_replay_file_read_failed: \(name) · \(error)")
            }
        }
        func decodeReplay<T: Decodable>(_ type: T.Type, data: Data, name: String) throws -> T {
            do { return try decoder.decode(type, from: data) }
            catch is DecodingError {
                throw ResourceError.rejected("player_replay_file_invalid: \(name)")
            }
        }
        let catalogData = try readReplay("combined-catalog.json", limit: 32 * 1024 * 1024)
        let selection = try decodeReplay(ReplaySelection.self,
            data: readReplay("summary.json", limit: 32 * 1024 * 1024), name: "summary.json")
        guard selection.story_choices.count <= 64,
              selection.story_choices.allSatisfy({ (0..<6).contains($0) }) else {
            throw ResourceError.rejected("player_replay_choice_limit")
        }
        replayChoices = selection.story_choices
        guard catalogData.sha256Hex == selection.corpus_report_sha256 else {
            throw ResourceError.rejected("player_catalog_identity_mismatch")
        }
        try Task.checkCancellation()
        let file = try decodeReplay(ScriptCatalogFile.self, data: catalogData, name: "combined-catalog.json")
        let receipts: [Data: ScriptModuleReference]
        if let images = selection.image_resources, let audio = selection.audio_resources,
           let waves = selection.wave_resources {
            receipts = try Self.resourceReceipts(images + audio + waves)
        } else {
            guard let attempt = selection.attempts.last?.attempt, (0...128).contains(attempt) else {
                throw ResourceError.rejected("player_replay_attempt_missing")
            }
            try Task.checkCancellation()
            let log = try readReplay(String(format: "attempt-%02d-stderr.log", attempt), limit: 32 * 1024 * 1024)
            receipts = try Self.resourceReceipts(Self.legacyReceiptEntries(log, decoder: decoder))
        }
        let configurationPath = "GameData/System/config.txt"
        guard let reference = selection.configuration_source, reference.source_file == configurationPath else {
            throw ResourceError.rejected("player_configuration_reference_required")
        }
        let game = try SafeDirectory(gameDirectory)
        try Task.checkCancellation()
        let configurationData = try game.read(configurationPath, limit: 1024 * 1024)
        guard configurationData.sha256Hex == reference.sha256 else {
            throw ResourceError.rejected("player_configuration_identity_mismatch")
        }
        let configuration = try ScriptTable(data: configurationData, relativePath: configurationPath)
        try Task.checkCancellation()
        var catalog = try ScriptModuleCatalog(entries: file.items, indexedResourceNames: file.indexedResourceNames)
        for entry in selection.selected_sources {
            try Task.checkCancellation()
            guard catalog.reference(forPhysical: entry.source_file)?.sourceSHA256 == entry.sha256 else {
                throw ResourceError.rejected("player_selection_identity_mismatch")
            }
            try catalog.select(sourceFile: entry.source_file)
        }
        try Task.checkCancellation()
        let imageRecipe = try decodeReplay(ScriptImageRecipe.self,
            data: readReplay("image-recipe.json", limit: 1024 * 1024), name: "image-recipe.json")
        recipe = imageRecipe
        cutinSource = file.items.first { $0.sourceSHA256 == PlayerCutinSource.sha256 }.flatMap { reference in
            let resource = reference.wholeFileLocation(byteLength: 22_228_430)
            return (try? imageRecipe.member(resource, "万華鏡.ogv")).map {
                PlayerCutinSource(resource: resource, range: $0)
            }
        }
        let repository = try ScriptRepository(directory: assets, catalog: catalog) { logical in
            guard let entry = receipts[try ScriptModuleCatalog.key(logical)] else {
                throw ResourceError.rejected("player_resource_copy_not_in_replay: \(logical)")
            }
            return entry
        }
        let path = "data0.pack/startup.s"
        try Task.checkCancellation()
        let document = try ScriptDocument(data: assets.read(path), relativePath: path)
        try Task.checkCancellation()
        machine = try ScriptMachine(program: ScriptProgram(document), allowExperimental: true,
            maximumSteps: ScriptMachine.maximumSupportedSteps, repository: repository, configuration: configuration,
            imageLoader: recipe.dimensions, imageMemberLookup: recipe.member,
            imageExtendedValues: recipe.extendedValues, imageMotionNames: recipe.motionNames,
            retainFullTrace: false)
        machine.savedMotionUpdateThreshold = recipe.motionUpdateThreshold
        machine.inspectSaveRestoreBoundary = allowSaveAdoption
        machine.retainExperimentalSaveCandidate = allowSaveAdoption
        if let directory = saveDirectory {
            let inspected: [SaveSlotInventory.Entry]
            do {
                inspected = try SaveSlotInventory.scan(directory, includeMetadata: true) { payload in
                    _ = try ResourceImage.decode(payload)
                }
            } catch let error as ResourceError {
                saveImportIssues = ["无法读取存档目录 · \(error)"]
                return
            }
            var issues = inspected.filter { $0.status != .verified }.map {
                "\($0.name) · \(PlayerWindow.playbackMessage($0.issue ?? $0.status.rawValue))"
            }
            var entries = inspected.filter { entry in
                guard entry.status == .verified else { return false }
                guard let slot = entry.envelope?.slot else {
                    issues.append("\(entry.name) · 系统数据，无法作为剧情存档读取")
                    return false
                }
                guard slot.savedLocalTime != nil else {
                    issues.append("\(entry.name) · 存档日期无效，无法在原版读档菜单显示")
                    return false
                }
                if let issue = entry.issue {
                    issues.append("\(entry.name) · 使用占位缩略图 · \(issue)")
                }
                return true
            }
            var headerTemplate: Data?
            if entries.contains(where: { $0.envelope?.slot?.transformed == true }) {
                try Task.checkCancellation()
                do {
                    headerTemplate = try SaveEnvelope.slotHeaderTemplate(from: game, executable: "美少女万華鏡４.exe")
                } catch let error as ResourceError {
                    entries.removeAll { entry in
                        guard entry.envelope?.slot?.transformed == true else { return false }
                        issues.append("\(entry.name) · 无法取得原版存档校验模板 · \(error)")
                        return true
                    }
                }
            }
            if entries.isEmpty && issues.isEmpty {
                issues.append("所选目录没有找到剧情存档。请选择包含 .svd 槽位的目录。")
            }
            saveImportIssues = issues
            try machine.setReadOnlySaveSlots(entries, directory: directory, headerTemplate: headerTemplate,
                                             verifyUntransformedHeaders: false)
        } else {
            saveImportIssues = []
        }
    }

    private static func legacyReceiptEntries(_ log: Data, decoder: JSONDecoder) throws -> [ScriptModuleReference] {
        let prefix = Data("supplied_resource=".utf8)
        var entries: [ScriptModuleReference] = []
        for line in log.split(separator: 10) where line.starts(with: prefix) {
            try Task.checkCancellation()
            guard line.count <= 16 * 1024, entries.count < 50_000 else {
                throw ResourceError.rejected("player_resource_receipt_size_or_count")
            }
            entries.append(try decoder.decode(ScriptModuleReference.self, from: Data(line.dropFirst(prefix.count))))
        }
        return entries
    }

    private static func resourceReceipts(_ entries: [ScriptModuleReference]) throws -> [Data: ScriptModuleReference] {
        guard entries.count <= 50_000 else { throw ResourceError.rejected("player_resource_receipt_count") }
        let media = Set(["png", "jpg", "jpeg", "bmp", "ogg", "ogv", "wav", "b"])
        var receipts: [Data: ScriptModuleReference] = [:]
        for entry in entries {
            try Task.checkCancellation()
            _ = try SafeDirectory.components(entry.sourceFile)
            guard media.contains((entry.sourceFile as NSString).pathExtension.lowercased()),
                  entry.sourceSHA256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else {
                throw ResourceError.rejected("player_resource_receipt_invalid")
            }
            let key = try ScriptModuleCatalog.key(entry.logicalPath)
            guard receipts[key] == nil || receipts[key] == entry else {
                throw ResourceError.rejected("player_resource_receipt_conflict")
            }
            receipts[key] = entry
        }
        return receipts
    }

    func run(input: Input? = nil, presentTimedFrame: @MainActor @Sendable (PlayerState) -> Void) async throws -> PlayerState {
        switch input {
        case .loadMenuButton, .loadMenuEscape, .loadConfirmation:
            guard var task = systemLoadTask else {
                throw ResourceError.rejected("system_load_task_required")
            }
            if case .loadMenuButton(let handle, let x, let y) = input {
                try task.dispatchLoadMenuButton(handle, x: x, y: y)
            } else if case .loadConfirmation(let accept) = input {
                guard try task.dispatchLoadConfirmation(accept: accept) else {
                    throw ResourceError.rejected("load_confirmation_not_waiting")
                }
            } else {
                try task.dispatchLoadMenuEscape()
            }
            let initial = try advanceSystemLoadTask(task)
            let status = try await runSystemLoadWaits(initial, presentTimedFrame: presentTimedFrame)
            if machine.retainExperimentalSaveCandidate,
               case .loadConfirmation(true) = input,
               let task = systemLoadTask, task.stopReason == "save_restore_execution_state_unsupported" {
                let assets = assets, decoder = ffmpeg
                var restored = machine
                let audio = try restored.adoptExperimentalSaveCandidate(from: task) {
                    try PlayerMovie.savedDirectBufferBytes($0, assets: assets, ffmpeg: decoder)
                }
                guard audio.gaps.isEmpty else {
                    throw ResourceError.rejected("saved_audio_restore_incomplete")
                }
                // Validate queued playback before releasing the previous session.
                var preflight = restored
                var prepared: [PreparedSaveAudio] = []
                while let source = preflight.soundPlaybackRequest, let channel = preflight.soundPlaybackChannel {
                    try Task.checkCancellation()
                    let player = try AVAudioPlayer(data: convertedAudio(source))
                    try PlayerMovie.validateDuration(player.duration)
                    if let position = preflight.takePendingPlaybackSeek() {
                        let seconds = Double(position) / 1000
                        guard seconds < player.duration else {
                            throw ResourceError.rejected("saved_stream_seek_at_or_past_end")
                        }
                        player.currentTime = seconds
                    }
                    player.numberOfLoops = Int(preflight.soundPlaybackRepeatCount)
                    player.volume = 0
                    guard player.prepareToPlay() else {
                        throw ResourceError.rejected("saved_audio_prepare_failed")
                    }
                    prepared.append(.init(channel: channel, source: source, player: player))
                    try preflight.acknowledgeSoundPlayback()
                }
                try validateRestoredLayers(restored)
                let capturedDisplay = try task.savedCapturedDisplay.map { try ResourceImage.decode($0).image }
                try Task.checkCancellation()
                for candidate in prepared {
                    guard candidate.player.play() else {
                        for item in prepared { item.player.stop() }
                        throw ResourceError.rejected("player_audio_start_failed")
                    }
                }
                preparedSaveAudio = prepared
                machine = restored
                restoredDisplay = capturedDisplay
                playbackIdentity = UUID()
                activeSceneVideos.removeAll()
                systemLoadTask = nil
                systemCapture = nil
                FileHandle.standardError.write(Data("player_experimental_save_adopted=1 staged_streams=\(audio.stagedStreams) scheduled_streams=\(audio.scheduledStreams) scheduled_direct=\(audio.scheduledDirectSounds) audio_gaps=\(audio.gaps.count)\n".utf8))
                break
            }
            if let task = systemLoadTask, task.systemTaskExitRequested {
                try machine.finishSystemLoadTask(task)
                systemLoadTask = nil
                systemCapture = nil
                break
            }
            guard let frame = systemLoadFrame() else {
                throw ResourceError.rejected(status.reason ?? "system_task_bootstrap_waiting")
            }
            return frame
        case .soundStarted: try machine.acknowledgeSoundPlayback()
        case .movieFinished(let duration):
            try machine.acknowledgeMoviePlayback(durationTicks: duration)
            try machine.advancePlacementClock(ticks: duration)
        case .start:
            try machine.dispatchStopCallback(pointer: (1100, 360), buttonIndex: 0)
        case .titlePointer(let x, let y):
            try machine.dispatchStopCallback(pointer: (x, y))
        case .click:
            if machine.isDialogueWindowHidden {
                machine.restoreDialogueWindow()
                break
            }
            if machine.isWaitingForStoryChoice { break }
            if skipAudioForChoiceProbe {
                // Model a short dwell before the automatic click so the probe can observe idle motion.
                for _ in 0..<20 {
                    guard hasActiveBoundMotion else { break }
                    try Task.checkCancellation()
                    machine.advanceVisualClock(ticks: 16)
                    await presentTimedFrame(playbackSnapshot())
                }
            }
            if machine.phase == .waiting { try machine.completeIndefiniteClickWait() }
            else { try machine.dispatchStopCallback(click: true) }
        case .canvasClick(let x, let y, let titleButton):
            if machine.isDialogueWindowHidden {
                machine.restoreDialogueWindow()
                break
            }
            if machine.isWaitingForStoryChoice { break }
            if machine.phase == .waiting {
                try machine.completeIndefiniteClickWait()
            } else {
                try machine.dispatchStopCallback(pointer: (x, y),
                                                 buttonIndex: titleButton, click: true)
            }
        case .choice(let index): try machine.dispatchStoryChoice(index)
        case .windowViewButton(let handle): try machine.dispatchWindowViewButton(handle)
        case .windowLoadButton(let handle): try machine.dispatchWindowLoadButton(handle)
        case .timerTick, nil: break
        }
        var sampledPreviousWait = false
        while true {
            try Task.checkCancellation()
            if try machine.dispatchDueTimer() { continue }
            if machine.phase == .ready {
                try machine.run(stepQuota: 10_000)
                if !skipAudioForChoiceProbe { await Task.yield() }
                continue
            }
            if machine.phase == .waiting, let remaining = machine.clickWaitRemaining, remaining >= 0 {
                let sample = samplesAcceleratedVisualWait
                if !accelerated || sample || sampledPreviousWait { await presentTimedFrame(playbackSnapshot()) }
                sampledPreviousWait = sample
                let ticks = try await waitTicks(remaining, sampleAccelerated: sample)
                try machine.advanceClickWait(ticks: ticks)
                try machine.advancePlacementClock(ticks: ticks)
                continue
            }
            if machine.phase == .waitingForEvent, let request = machine.timedStopRequest, request.duration >= 0 {
                let committedCenterText = try machine.commitTimedCenterText()
                let sample = samplesAcceleratedVisualWait
                if committedCenterText || !accelerated || sample || sampledPreviousWait {
                    await presentTimedFrame(playbackSnapshot())
                }
                sampledPreviousWait = sample
                let ticks = try await waitTicks(request.duration, sampleAccelerated: sample)
                try machine.advanceTimedStop(ticks: ticks)
                try machine.advancePlacementClock(ticks: ticks)
                continue
            }
            if !machine.isWaitingForStoryChoice, try machine.commitHeadlessMessageOutput() {
                if !accelerated, machine.hasVisibleMessageSurface {
                    await presentTimedFrame(playbackSnapshot())
                    try Task.checkCancellation()
                }
                try machine.dispatchStopCallback()
                continue
            }
            if machine.movieStopRemaining == 0 {
                try machine.dispatchStopCallback()
                continue
            }
            // Title pointer callbacks schedule a slide and return directly to stop.
            if case .titlePointer = input, machine.phase == .waitingForEvent,
               let endpoint = machine.ticksUntilPlacementEndpoint {
                if !accelerated { await presentTimedFrame(playbackSnapshot()) }
                let ticks = try await waitTicks(accelerated ? endpoint : min(endpoint, 16))
                try machine.advancePlacementClock(ticks: ticks)
                continue
            }
            if skipAudioForChoiceProbe, machine.soundPlaybackRequest != nil {
                try machine.acknowledgeSoundPlayback()
                continue
            }
            let movie: PlayerMovie?
            if let request = machine.moviePlaybackRequest {
                movie = try await PlayerMovie.prepare(request, assets: assets, ffmpeg: ffmpeg)
            } else {
                movie = nil
            }
            if Task.isCancelled {
                movie?.remove()
                throw CancellationError()
            }
            return await playbackSnapshot(movie: movie)
        }
    }

    func convertedAudio(_ source: ScriptLocation) throws -> Data {
        if let cached = audioCache.value(for: source) {
            audioCacheHits += 1
            return cached
        }
        let prepared = try PlayerMovie.prepareAudio(source, assets: assets, ffmpeg: ffmpeg)
        defer { prepared.remove() }
        let data = try Data(contentsOf: prepared.url)
        try Task.checkCancellation()
        audioConversions += 1
        // Long ALAC tracks still play, but must not displace most short clips.
        if data.count <= Self.maximumCachedAudioBytes {
            audioCache.insert(data, for: source, cost: data.count)
        }
        return data
    }

    private static let dialogBlackDigest = "19e2101c218c9be4f0b459d8b58ff5acb38a0151a66c2bced8de3304bdc6f6f6"

    private static let blackPixel = solidPixel(gray: 0)
    private static let whitePixel = solidPixel(gray: 1)

    private static func solidPixel(gray: CGFloat) -> CGImage? {
        guard let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return context.makeImage()
    }

    private func playbackSnapshot(movie: PlayerMovie? = nil) async -> PlayerState {
        let layers = movie == nil ? machine.staticImageLayers.filter {
            $0.isTheoraResource && $0.selectedMember == 0 && $0.motionElapsedTicks != nil &&
                !$0.unappliedTransform && $0.boundRasterPreview == nil
        } : []
        let admittedLayers = layers.prefix(2)
        let nextSceneVideos = Dictionary(uniqueKeysWithValues: admittedLayers.map { ($0.id, $0.resource) })
        sceneVideoCycles = sceneVideoCycles.filter { id, _ in
            nextSceneVideos[id] != nil && nextSceneVideos[id] == activeSceneVideos[id]
        }
        activeSceneVideos = nextSceneVideos
        let activeSources = Set(activeSceneVideos.values)
        sceneVideoFailures = sceneVideoFailures.filter { activeSources.contains($0.key) }
        for key in sceneVideoOrder where !activeSources.contains(key) {
            sceneVideos[key]?.lastImage = nil
            sceneVideos[key]?.lastIndex = nil
        }
        while sceneVideoOrder.count + activeSources.subtracting(sceneVideoOrder).count > 4,
              let evicted = sceneVideoOrder.firstIndex(where: { !activeSources.contains($0) }) {
            let key = sceneVideoOrder.remove(at: evicted)
            sceneVideos.removeValue(forKey: key)?.movie.remove()
        }
        var frames: [UInt64: CGImage] = [:]
        var issues: [UInt64: String] = [:]
        for layer in layers.dropFirst(admittedLayers.count) {
            issues[layer.id] = "scene_video_layer_budget_exceeded"
        }
        for layer in admittedLayers {
            if let issue = sceneVideoFailures[layer.resource] {
                issues[layer.id] = issue
                continue
            }
            do {
                frames[layer.id] = try await sceneFrame(layer)
            } catch {
                let issue = String(describing: error)
                issues[layer.id] = issue
                if !Task.isCancelled, !(error is CancellationError) { sceneVideoFailures[layer.resource] = issue }
            }
        }
        return snapshot(movie: movie, sceneFrames: frames, sceneIssues: issues)
    }

    private func sceneFrame(_ layer: ScriptMachine.StaticImageLayer) async throws -> CGImage {
        let source = layer.resource
        if sceneVideos[source] == nil {
            let movie = try PlayerMovie.prepareSceneVideo(source, assets: assets, ffmpeg: ffmpeg)
            do {
                let asset = AVURLAsset(url: movie.url)
                guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                    throw ResourceError.rejected("scene_video_track_missing")
                }
                let cadence = try await track.load(.minFrameDuration)
                let duration = try await asset.load(.duration).seconds
                guard CMTimeCompare(cadence, CMTime(value: 1, timescale: 30)) == 0,
                      duration.isFinite, (1...PlayerMovie.maximumSceneDuration).contains(duration) else {
                    throw ResourceError.rejected("scene_video_timing_outside_profile")
                }
                try Task.checkCancellation()
                sceneVideos[source] = SceneVideo(movie: movie, asset: asset, frames: Int64((duration * 30).rounded()))
                FileHandle.standardError.write(Data("player_scene_video_prepared=\(source.sourceSHA256)\n".utf8))
            } catch {
                movie.remove()
                throw error
            }
        }
        sceneVideoOrder.removeAll { $0 == source }
        sceneVideoOrder.append(source)
        guard var video = sceneVideos[source], let ticks = layer.motionElapsedTicks, ticks >= 0 else {
            throw ResourceError.rejected("scene_video_clock_missing")
        }
        // Default zero-based loop for the audited 30 fps scene profile.
        let frame = Int64(ticks) * 30 / 1000
        let index = frame % video.frames
        let cycle = frame / video.frames
        let image: CGImage
        if video.lastIndex == index, let cached = video.lastImage {
            image = cached
        } else {
            let requested = CMTime(value: index, timescale: 30)
            let generator = AVAssetImageGenerator(asset: video.asset)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let (decoded, actual) = try await generator.image(at: requested)
            try Task.checkCancellation()
            guard CMTimeCompare(requested, actual) == 0 else {
                throw ResourceError.rejected("scene_video_frame_time_mismatch")
            }
            image = decoded
            video.lastIndex = index
            video.lastImage = image
            sceneVideos[source] = video
        }
        if let previous = sceneVideoCycles.updateValue(cycle, forKey: layer.id) {
            if previous < cycle {
                FileHandle.standardError.write(Data("player_scene_video_wrap=\(source.sourceSHA256) ticks=\(ticks) frame=\(index) layer=\(layer.id)\n".utf8))
            }
        } else {
            FileHandle.standardError.write(Data("player_scene_video_first_frame=\(source.sourceSHA256) ticks=\(ticks) frame=\(index) layer=\(layer.id)\n".utf8))
        }
        return image
    }

    private static let dialogueFrameDigest = "4cc07581ee78126b0bbbafb7dfd9dbbcdb78d025ec687f0d910e22f79fea9b5b"

    private func dialogueFrameTextures(_ layer: ScriptMachine.StaticImageLayer) throws -> [DialogueFrameTexture]? {
        guard layer.resource.sourceSHA256 == Self.dialogueFrameDigest,
              !layer.unappliedTransform,
              layer.alignmentXPercent == 0, layer.alignmentYPercent == 0,
              layer.scaleXPercent == 100, layer.scaleYPercent == 100,
              let member = layer.selectedMember, let ticks = layer.motionElapsedTicks,
              let keys = recipe.motionKeys(layer.resource, selectedMember: member, time: ticks),
              let entries = recipe.scopedTextureKeys(keys),
              entries.allSatisfy({ $0.states.isEmpty }) else { return nil }
        let host = CGAffineTransform(translationX: CGFloat(layer.x), y: CGFloat(layer.y))
        let ordered = entries.enumerated().sorted {
            ($0.element.texture.transform_fields?["0xa8"] ?? 0, $0.offset) <
                ($1.element.texture.transform_fields?["0xa8"] ?? 0, $1.offset)
        }
        var result: [DialogueFrameTexture] = []
        for entry in ordered.map(\.element) {
            let key = entry.texture
            guard let modes = recipe.composedRasterModes(texture: key, states: []),
                  modes.blend == 1, modes.sampling == 0,
                  let alpha = recipe.composedOpacity(texture: key, states: []),
                  let slot = key.texture_numbers?.first,
                  let texture = recipe.embeddedTexture(layer.resource, slot: slot),
                  texture.hasZeroAnchorOffset else { return nil }
            let source = layer.boundTextureLocations[slot] ?? texture.location
            let image = try staticRaster(source, selectedMember: nil).image
            guard let bounds = recipe.fullTextureRectangle(key, size: CGSize(width: image.width, height: image.height),
                                                           host: host) else { return nil }
            let pixelBounds = CGRect(x: bounds.minX.rounded(), y: bounds.minY.rounded(),
                                     width: bounds.width.rounded(), height: bounds.height.rounded())
            result.append(.init(image: image, bounds: pixelBounds, alpha: alpha,
                                usesBoundSource: layer.boundTextureLocations[slot] != nil))
        }
        return result
    }

    private func validateRestoredLayers(_ restored: ScriptMachine) throws {
        try Task.checkCancellation()
        let visible = restored.staticImageLayers.filter { $0.opacity > 0 }
        guard !visible.isEmpty else { return }
        // Snapshot consumes pending sound changes. Render a disposable copy
        // so the adopted machine can still deliver them to the playback host.
        var previous = restored
        let previousDisplay = restoredDisplay
        swap(&machine, &previous)
        restoredDisplay = nil
        defer {
            swap(&machine, &previous)
            restoredDisplay = previousDisplay
        }
        let frame = snapshot()
        for layer in visible {
            if let detail = frame.unavailableLayerFailures[layer.id] {
                throw ResourceError.rejected("saved_initial_layer_unavailable: \(detail)")
            }
        }
    }

    private func loadThumbnailBounds(_ layer: ScriptMachine.StaticImageLayer) -> CGRect {
        CGRect(x: Int(layer.x) - 8, y: Int(layer.y) - 8, width: 176, height: 106)
    }

    private func composedLoadThumbnail(_ layer: ScriptMachine.StaticImageLayer,
                                       backdrop: [PlayerLayer]? = nil) throws -> CGImage {
        guard layer.opacity == 255, layer.scaleXPercent == 100, layer.scaleYPercent == 100,
              layer.alignmentXPercent == 0, layer.alignmentYPercent == 0, !layer.unappliedTransform,
              let action = layer.selectedMember, let ticks = layer.motionElapsedTicks,
              let keys = recipe.motionKeys(layer.resource, selectedMember: action, time: ticks) else {
            throw ResourceError.rejected("thumbnail_composition_layer_profile")
        }
        let draws = keys.filter { $0.type != 0 }
        guard draws.map(\.type) == [4, 11] else {
            throw ResourceError.rejected("thumbnail_composition_draw_order_or_binding")
        }
        let usedSlots = Set(draws.flatMap { $0.texture_numbers ?? [] })
        let bindings = try layer.boundTextureLocations.filter { usedSlots.contains($0.key) }
            .mapValues { (try rasterPayload($0), $0) }
        let container = try rasterPayload(layer.resource)
        let patch = loadThumbnailBounds(layer)
        let width = Int(patch.width), height = Int(patch.height)
        let origin = SIMD2(8, 8)
        let pixel = backdrop == nil ? SIMD4<UInt8>.zero : SIMD4<UInt8>(0, 0, 0, 255)
        var canvas = Array(repeating: Array(repeating: pixel, count: width), count: height)
        for lower in backdrop ?? [] where lower.opacity > 0 && lower.bounds.intersects(patch) {
            guard lower.dialogueFrameTextures == nil, lower.hoverImage == nil, !lower.usesVolumeButtonOffsets else {
                throw ResourceError.rejected("thumbnail_composition_dynamic_backdrop")
            }
            let bounds = lower.bounds.offsetBy(dx: -patch.minX, dy: -patch.minY)
            try ResourceImage(image: lower.image, format: "display", notes: []).drawRasterPreview(
                bounds: bounds, opacity: lower.opacity, flipX: lower.scaleXPercent < 0,
                flipY: lower.scaleYPercent < 0, interpolation: lower.textureFilter == 1 ? .none : .low, canvas: &canvas)
        }
        let background = canvas
        guard try recipe.drawFullTexturePreview(draws[0], container: container,
            boundTextures: bindings.mapValues { $0.0 }, origin: origin, canvas: &canvas) else {
            throw ResourceError.rejected("thumbnail_composition_base_uncovered")
        }
        let base = canvas
        guard try recipe.drawFullTwoTextureKey(draws[1], container: container,
            boundTextures: bindings, origin: origin, canvas: &canvas) else {
            throw ResourceError.rejected("thumbnail_composition_pair_uncovered")
        }
        if backdrop == nil {
            for y in 0..<height {
                for x in 0..<width where canvas[y][x] != base[y][x] && base[y][x].w != 255 {
                    throw ResourceError.rejected("thumbnail_composition_requires_backdrop")
                }
            }
        } else {
            for y in 0..<height {
                for x in 0..<width {
                    // The lower layers are also drawn by the window. Replace
                    // only pixels changed by the thumbnail on that opaque target.
                    let pixel = canvas[y][x]
                    let prior = background[y][x]
                    canvas[y][x] = (pixel.x, pixel.y, pixel.z) == (prior.x, prior.y, prior.z)
                        ? .zero : SIMD4(pixel.x, pixel.y, pixel.z, 255)
                }
            }
        }
        let bytes = Data(canvas.flatMap { row in row.flatMap { [$0.x, $0.y, $0.z, $0.w] } })
        guard let provider = CGDataProvider(data: bytes as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)],
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw ResourceError.rejected("thumbnail_composition_image")
        }
        return image
    }

    private func snapshot(movie: PlayerMovie? = nil, isSystemLoadFrame: Bool = false,
                          sceneFrames: [UInt64: CGImage] = [:], sceneIssues: [UInt64: String] = [:]) -> PlayerState {
        let choiceButtons = machine.storyChoiceButtons
        let visibleChoiceButtons = machine.visibleStoryChoiceButtons
        let loadMenuButtons = machine.loadMenuButtons
        let confirmationButtons = machine.loadConfirmationButtons
        let layers = machine.staticImageLayers
        let messages = machine.messageTextLayers
        let windowAnimation = windowControlState
        var unavailableLayers: [String] = []
        var unavailableLayerFailures: [UInt64: String] = [:]
        var unimplementedAnimationCount = 0
        var cutin: PlayerCutin?
        var visibleSaveThumbnails = 0
        let fullTextAlphas = sampledFullTextAlphas(layers)
        var rendered: [PlayerLayer] = []
        func resolveLayer(_ layer: ScriptMachine.StaticImageLayer) -> PlayerLayer? {
            if portraitExitIsFinished(layer) { return nil }
            if recipe.isNonDrawingMotion(layer.resource, selectedMember: layer.selectedMember) {
                return nil
            }
            if let alpha = dialogBlackOpacity(layer),
               let pixel = Self.blackPixel {
                // Bounded preview of the audited 1280×720 untextured dialog layer.
                return PlayerLayer(id: layer.id, image: pixel, hoverImage: nil, x: layer.x, y: layer.y,
                    priority: layer.priority, opacity: alpha, scaleXPercent: 128000, scaleYPercent: 72000,
                    alignmentXPercent: 0, alignmentYPercent: 0, textureFilter: nil,
                    usesVolumeButtonOffsets: false, isWindowControl: false, isDialogBlack: true)
            }
            // The dialogue cursor's explicit None action also occurs before a click wait.
            if layer.resource.sourceFile.lowercased().hasSuffix("/avg/window/click.b"),
               let index = layer.selectedMember, let names = recipe.motionNames(layer.resource),
               names.indices.contains(Int(index)), names[Int(index)] == "None" {
                return nil
            }
            func layerIssue(_ source: ScriptLocation, _ reason: String) -> String {
                let member: String
                if source == layer.resource, let index = layer.selectedMember {
                    let names = recipe.motionNames(source) ?? []
                    let name = names.indices.contains(Int(index)) ? " \(names[Int(index)])" : ""
                    let types = recipe.motionKeyTypes(source, selectedMember: index)?.map(String.init).joined(separator: ", ")
                    let details = types.map { " · 关键帧类型 \($0)" } ?? ""
                    let firstKeys = recipe.motionKeys(source, selectedMember: index, time: 0)
                    let firstTypes = firstKeys?.map { String($0.type) }.joined(separator: ", ")
                    let firstFrame = firstTypes.map { " · 起始绘制顺序 \($0)" } ?? ""
                    let textures = firstKeys.flatMap { recipe.scopedTextureKeys($0) }?.compactMap { entry -> String? in
                        let key = entry.texture
                        guard let number = key.texture_numbers?.first else { return nil }
                        let rect = key.source_areas?.first
                        let area = rect?.count == 4 && rect?.allSatisfy({ $0 == 0 }) == true ? "（整图）" : ""
                        let texture = recipe.embeddedTexture(source, slot: number)
                        let embedded = texture.map { texture in
                            let anchor = texture.hasZeroAnchorOffset ? " · 附加锚点偏移为零" : ""
                            return " [内嵌 \(texture.name)\(anchor)]"
                        } ?? ""
                        var scope = entry.states.isEmpty ? "" : " [绘制状态层数 \(entry.states.count)]"
                        if !entry.states.isEmpty, let state = recipe.axisAlignedState(entry.states) {
                            scope += " [平移 \(state.x), \(state.y) · 缩放 \(state.scaleX), \(state.scaleY)]"
                        }
                        if let local = recipe.axisAlignedState([key]) {
                            scope += " [纹理平移 \(local.x), \(local.y) · 缩放 \(local.scaleX), \(local.scaleY)]"
                        }
                        if let anchor = key.literalAnchorRatio {
                            scope += " [纹理锚点比例 \(anchor.x), \(anchor.y)]"
                        }
                        if texture?.hasZeroAnchorOffset == true, let size = texture?.size,
                           !layer.unappliedTransform, layer.alignmentXPercent == 0, layer.alignmentYPercent == 0,
                           layer.scaleXPercent > 0, layer.scaleYPercent > 0,
                           let rect = recipe.fullTextureRectangle(key, size: size,
                               host: CGAffineTransform(translationX: CGFloat(layer.x), y: CGFloat(layer.y))
                                   .scaledBy(x: CGFloat(layer.scaleXPercent) / 100,
                                             y: CGFloat(layer.scaleYPercent) / 100)),
                           let frame = recipe.applyingAxisAlignedState(entry.states, to: rect,
                               target: CGSize(width: PlayerViewport.width, height: PlayerViewport.height)) {
                            scope += " [起始矩形试算 \(frame.minX), \(frame.minY), \(frame.width), \(frame.height)]"
                        }
                        if let opacity = recipe.composedOpacity(texture: key, states: entry.states) {
                            scope += " [起始透明度 \(opacity)/255]"
                        }
                        if let modes = recipe.composedRasterModes(texture: key, states: entry.states) {
                            scope += " [后端混合 \(modes.blend) · 采样 \(modes.sampling)]"
                        }
                        return "\(number)\(area)\(embedded)\(scope)"
                    }.joined(separator: ", ") ?? ""
                    let textureDetails = textures.isEmpty ? "" : " · 首路纹理 \(textures)"
                    let sampled = layer.motionElapsedTicks.flatMap {
                        recipe.motionKeys(source, selectedMember: index, time: $0)
                    }
                    let sampledFrame = sampled.flatMap { keys in
                        layer.motionElapsedTicks.map { time in
                            " · 宿主时钟 \(time) · 试采样类型 " + keys.map { String($0.type) }.joined(separator: ", ")
                        }
                    } ?? ""
                    member = " · 动作 \(index)\(name)\(details)\(firstFrame)\(textureDetails)\(sampledFrame)"
                } else {
                    member = ""
                }
                let channel = layer.drawChannel.map { " · ABMP 音频通道 \($0)" } ?? ""
                return "图层 \(layer.id) · \(source.sourceFile) · offset \(source.byteOffset), length \(source.byteLength), SHA-256 \(source.sourceSHA256)\(member)\(channel) · \(reason)"
            }
            if let windowAnimation, recipe.windowTextureIsOffCanvas(layer, offsetY: windowAnimation.y, canvasHeight: Int(PlayerViewport.height)) {
                unavailableLayers.append(layerIssue(layer.resource, "窗口纹理位于画布外，跨图层合成仅应用于已核对的控件"))
                return nil
            }
            if let frame = sceneFrames[layer.id] {
                return PlayerLayer(id: layer.id, image: frame, hoverImage: nil, x: layer.x, y: layer.y,
                    priority: layer.priority, opacity: layer.opacity, scaleXPercent: layer.scaleXPercent,
                    scaleYPercent: layer.scaleYPercent, alignmentXPercent: layer.alignmentXPercent,
                    alignmentYPercent: layer.alignmentYPercent, textureFilter: layer.textureFilter,
                    usesVolumeButtonOffsets: false, isWindowControl: false)
            }
            if let reason = sceneIssues[layer.id] {
                let detail = layerIssue(layer.resource, reason)
                unavailableLayerFailures[layer.id] = detail
                unavailableLayers.append(detail)
                unimplementedAnimationCount += 1
                return nil
            }
            if let videoLayer = cutinLayer(layer) {
                cutin = videoLayer
                return nil
            }
            let unboundFlash = layer.resource.sourceSHA256 ==
                Self.whiteFlashDigest &&
                layer.selectedMember == 0 && layer.boundRasterPreview == nil
            if let flash = sampleWhiteFlash(layer), let pixel = Self.whitePixel {
                if flash.hasUnboundTexture {
                    unavailableLayers.append(layerIssue(layer.resource, "已绘制白光，槽 0 纹理指令尚未核对"))
                    unimplementedAnimationCount += 1
                }
                return PlayerLayer(id: layer.id, image: pixel, hoverImage: nil, x: layer.x, y: layer.y,
                    priority: layer.priority, opacity: flash.alpha,
                    scaleXPercent: Int32(flash.size.x * 100), scaleYPercent: Int32(flash.size.y * 100),
                    alignmentXPercent: 50, alignmentYPercent: 50, textureFilter: nil,
                    usesVolumeButtonOffsets: false, isWindowControl: false, isWhiteFlash: true)
            }
            if unboundFlash, let time = layer.motionElapsedTicks,
               recipe.motionKeys(layer.resource, selectedMember: 0, time: time) == nil {
                unavailableLayers.append(layerIssue(layer.resource, "当前时钟 \(time) 缺少动作采样，原版时间控制尚未复现"))
                unimplementedAnimationCount += 1
                return nil
            }
            if layer.resource.sourceSHA256 == "97bb05fa8aaaff094f9ef12978d6fca0c7af6bd3081a01bbedd7ae5c02902a68",
               let action = layer.selectedMember, (0...4).contains(action),
               let bounds = messages.first(where: { $0.id == layer.id })?.canvasBounds {
                // The texture slot is replaced by the live text surface.
                unavailableLayers.append(layerIssue(layer.resource, "实时文字区域 \(bounds)，双纹理过渡尚未实现"))
                return nil
            }
            if layer.resource.sourceSHA256 == Self.fullTextDigest,
               let action = layer.selectedMember, (0...1).contains(action),
               let bounds = messages.first(where: { $0.id == layer.id })?.canvasBounds {
                // Slot 0 has no raster. Type 4 draws slot 1, the live text surface.
                if fullTextAlphas[layer.id] == nil {
                    unavailableLayers.append(layerIssue(layer.resource, "全屏文字区域 \(bounds)，消息动作无法采样"))
                }
                return nil
            }
            do {
                if isSystemLoadFrame, layer.resource.sourceFile.lowercased().hasSuffix("/saveload/thumimage.b") {
                    do {
                        let patch = loadThumbnailBounds(layer)
                        guard let x = Int32(exactly: Int(patch.minX)),
                              let y = Int32(exactly: Int(patch.minY)) else {
                            throw ResourceError.rejected("thumbnail_composition_position_out_of_range")
                        }
                        let image: CGImage
                        let usedBackdrop: Bool
                        do {
                            image = try composedLoadThumbnail(layer)
                            usedBackdrop = false
                        } catch ResourceError.rejected("thumbnail_composition_requires_backdrop") {
                            guard !messages.contains(where: {
                                guard $0.isVisible, ($0.priority ?? Int32.max) <= layer.priority,
                                      let bounds = $0.canvasBounds else { return false }
                                return patch.intersects(CGRect(x: Int(bounds[0]), y: Int(bounds[1]),
                                    width: Int(bounds[2]) - Int(bounds[0]), height: Int(bounds[3]) - Int(bounds[1])))
                            }) else { throw ResourceError.rejected("thumbnail_composition_text_backdrop") }
                            image = try composedLoadThumbnail(layer, backdrop: rendered)
                            usedBackdrop = true
                        }
                        if layer.boundRasterPreview?.sourceFile.hasPrefix("save-slot/") == true {
                            visibleSaveThumbnails += 1
                            if !tracedComposedSaveThumbnail {
                                tracedComposedSaveThumbnail = true
                                FileHandle.standardError.write(Data(
                                    "player_composed_save_thumbnail=1 backdrop=\(usedBackdrop)\n".utf8))
                            }
                        }
                        return PlayerLayer(id: layer.id, image: image, hoverImage: nil, x: x, y: y,
                            priority: layer.priority, opacity: 255, scaleXPercent: 100, scaleYPercent: 100,
                            alignmentXPercent: 0, alignmentYPercent: 0, usesVolumeButtonOffsets: false, isWindowControl: false)
                    } catch {
                        unavailableLayers.append(layerIssue(layer.resource, String(describing: error)))
                    }
                }
                if let textures = try dialogueFrameTextures(layer) {
                    guard let image = textures.first?.image ?? Self.whitePixel else { return nil }
                    return PlayerLayer(id: layer.id, image: image, hoverImage: nil, x: layer.x, y: layer.y,
                        priority: layer.priority, opacity: layer.opacity, scaleXPercent: 100, scaleYPercent: 100,
                        alignmentXPercent: 0, alignmentYPercent: 0, textureFilter: nil,
                        usesVolumeButtonOffsets: false, isWindowControl: false, dialogueFrameTextures: textures)
                }
                if let member = layer.selectedMember, let time = layer.motionElapsedTicks,
                   recipe.hasNoActiveDrawKey(layer.resource, selectedMember: member, time: time) {
                    return nil
                }
                let isChoiceRaster = layer.resource.sourceFile.lowercased().hasSuffix("/select/selectbutton.b")
                let raster: Raster
                var usesBoundRaster = false
                var boundMotion: (offset: CGPoint, sampling: Int32?)?
                do {
                    raster = try staticRaster(layer.resource, selectedMember: layer.selectedMember,
                                              choiceHover: isChoiceRaster ? false : nil)
                } catch ResourceError.rejected(let reason) where [
                    "abmp_raster_requires_motion", "abmp_raster_requires_composition", "abmp_raster_recipe_missing"
                ].contains(reason) && !isChoiceRaster {
                    guard let preview = layer.boundRasterPreview else { throw ResourceError.rejected(reason) }
                    do {
                        raster = try staticRaster(preview, selectedMember: nil)
                        usesBoundRaster = true
                    } catch {
                        let detail = layerIssue(preview, "绑定图片无法绘制 · \(error)")
                        unavailableLayerFailures[layer.id] = detail
                        unavailableLayers.append(detail)
                        return nil
                    }
                    boundMotion = boundMotionSample(layer)
                    if boundMotion?.sampling == nil {
                        if ["abmp_raster_requires_motion", "abmp_raster_requires_composition", "theora_image_layer_playback_unsupported"].contains(reason) {
                            unimplementedAnimationCount += 1
                        }
                        let detail = boundMotion == nil
                            ? "已绘制脚本绑定图片，当前动作未应用"
                            : "已绘制脚本绑定图片并应用位移，完整动作尚未核对"
                        unavailableLayers.append(layerIssue(layer.resource, "\(detail) · \(reason)"))
                    }
                }
                if let filter = layer.textureFilter, ![0, 1, 2].contains(filter) {
                    unavailableLayers.append(layerIssue(layer.resource, "纹理采样设置 \(filter) 尚未映射，使用默认采样"))
                }
                if layer.unappliedTransform {
                    unavailableLayers.append(layerIssue(layer.resource, "图层含尚未应用的深度、第三轴缩放或旋转"))
                }
                var dialogFrameOpacity: UInt8?
                if raster.isInterfaceBackgroundPreview,
                   layer.resource.sourceSHA256 == "7c0cb9495c6a551403d42832ee067caa42d31677cfcbbb4ef0f4e3489ab70c55",
                   let action = layer.selectedMember, let time = layer.motionElapsedTicks,
                   let keys = recipe.samplePartialMotion(layer.resource, selectedMember: action, time: time) {
                    if keys.allSatisfy({ $0.type == 0 }) { return nil }
                    if let frame = keys.first(where: { $0.type == 4 && $0.texture_numbers?.first == 1 }),
                       let modes = recipe.composedRasterModes(texture: frame, states: []),
                       modes.blend == 1, modes.sampling == 0 {
                        dialogFrameOpacity = recipe.composedOpacity(texture: frame, states: [])
                    }
                }
                if raster.isInterfaceBackgroundPreview {
                    var detail = "仅显示静态底图，复合演出尚未实现"
                    if layer.resource.sourceFile.lowercased().hasSuffix("/script/dialog/message.b") {
                        let action = layer.selectedMember.map(String.init) ?? "无"
                        let ticks = layer.motionElapsedTicks.map(String.init) ?? "无"
                        detail = dialogFrameOpacity == nil
                            ? "弹窗静态边框，动作 \(action)，动作时钟 \(ticks)"
                            : "已采样边框透明度，文字表面合成尚未核对"
                    }
                    unavailableLayers.append(layerIssue(layer.resource,
                        "\(detail) · 位置 (\(layer.x), \(layer.y)) · 锚点 (\(layer.alignmentXPercent), \(layer.alignmentYPercent))"))
                }
                var hoverImage: CGImage?
                if isChoiceRaster && choiceButtons[layer.id] != nil {
                    do { hoverImage = try staticRaster(layer.resource, selectedMember: nil, choiceHover: true).image }
                    catch { unavailableLayers.append(layerIssue(layer.resource, "悬停图层 · \(error)")) }
                } else if let hover = layer.hoverResource {
                    do { hoverImage = try staticRaster(hover, selectedMember: nil).image }
                    catch { unavailableLayers.append(layerIssue(hover, "悬停图层 · \(error)")) }
                } else if let hoverMember = loadButtonHoverMember(layer, menuButtons: loadMenuButtons,
                                                               confirmationButtons: confirmationButtons) {
                    do {
                        if let member = try recipe.member(layer.resource, hoverMember) {
                            let source = ScriptLocation(sourceFile: layer.resource.sourceFile,
                                sourceSHA256: layer.resource.sourceSHA256, byteOffset: member.offset,
                                byteLength: member.length, rangeSHA256: member.sha256, lineNumber: 1)
                            hoverImage = try staticRaster(source, selectedMember: nil).image
                        }
                    } catch {
                        unavailableLayers.append(layerIssue(layer.resource, "悬停图层 · \(error)"))
                    }
                }
                let auditedDialogueFrame = [
                    "4cc07581ee78126b0bbbafb7dfd9dbbcdb78d025ec687f0d910e22f79fea9b5b",
                    "7fe70fef6d1b9d8ef72b855ad89c21c3db087b5c511a134863bfbb9e762924c7"
                ].contains(layer.resource.sourceSHA256)
                var alignmentX = layer.alignmentXPercent
                var alignmentY = layer.alignmentYPercent
                if raster.isInterfaceBackgroundPreview, !layer.hasExplicitAlignment,
                   layer.resource.sourceFile.lowercased().hasSuffix("/script/dialog/message.b") {
                    // Center the audited static frame on the script's dialog position.
                    alignmentX = 50
                    alignmentY = 50
                }
                if usesBoundRaster && !layer.hasExplicitAlignment && layer.resource.sourceSHA256 ==
                    Self.portraitMotionDigest {
                    // Audited motion_basicset type-4 keys use the center-bottom anchor.
                    alignmentX = 50
                    alignmentY = 100
                }
                let volumeButton = layer.resource.byteOffset > 0 && layer.resource.sourceSHA256 ==
                    "63215beb5843f6cf52577c8202e350e80baaa8fc6b808255e093e125084383fa"
                let systemButton = layer.resource.byteOffset > 0 && layer.resource.sourceSHA256 ==
                    "fbdc9326ec004de7c81fe0e38724ab16ec1564349a01543444d8773bddd35e7a"
                if systemButton || volumeButton {
                    // The slot-0 and slot-1 texture keys both anchor at their center.
                    alignmentX = 50
                    alignmentY = 50
                }
                if raster.isInterfaceBackgroundPreview && auditedDialogueFrame {
                    // Older receipts omit keyframes. The audited frame's anchor is (0%, 100%).
                    var anchor = (x: 0.0, y: 1.0)
                    if let index = layer.selectedMember,
                       let keys = recipe.motionKeys(layer.resource, selectedMember: index, time: 0),
                       let key = keys.first(where: { $0.type == 4 && $0.texture_numbers?.first == 0 }),
                       let ratio = key.literalAnchorRatio {
                        anchor = ratio
                    }
                    if alignmentX == 0 { alignmentX = Int32((anchor.x * 100).rounded()) }
                    if alignmentY == 0 { alignmentY = Int32((anchor.y * 100).rounded()) }
                }
                var motionOffset = boundMotion?.offset ?? .zero
                var opacity = dialogFrameOpacity.map { UInt8((Int(layer.opacity) * Int($0) + 127) / 255) } ?? layer.opacity
                if (systemButton || volumeButton), layer.priority == 1550, let windowAnimation {
                    motionOffset.y += windowAnimation.y
                    opacity = UInt8(Int(opacity) * Int(windowAnimation.alpha) / 255)
                }
                let renderedLayer = PlayerLayer(id: layer.id, image: raster.image, hoverImage: hoverImage, x: layer.x, y: layer.y, priority: layer.priority, opacity: opacity,
                                   scaleXPercent: layer.scaleXPercent, scaleYPercent: layer.scaleYPercent,
                                   motionOffset: motionOffset,
                                   alignmentXPercent: alignmentX, alignmentYPercent: alignmentY,
                                   textureFilter: layer.textureFilter ?? boundMotion?.sampling, usesVolumeButtonOffsets: volumeButton,
                                   isWindowControl: systemButton || volumeButton)
                if isSystemLoadFrame, usesBoundRaster, opacity > 0,
                   layer.boundRasterPreview?.sourceFile.hasPrefix("save-slot/") == true,
                   renderedLayer.bounds.intersects(CGRect(x: 0, y: 0, width: PlayerViewport.width, height: PlayerViewport.height)) {
                    visibleSaveThumbnails += 1
                }
                return renderedLayer
            } catch {
                if case ResourceError.rejected(let reason) = error,
                   ["abmp_raster_requires_motion", "abmp_raster_requires_composition", "theora_image_layer_playback_unsupported"].contains(reason) {
                    unimplementedAnimationCount += 1
                }
                var reason = String(describing: error)
                if layer.resource.sourceSHA256 == PlayerCutinSource.sha256 {
                    reason += " · 演出视频状态 时间 \(layer.motionElapsedTicks ?? -1) 透明度 \(layer.opacity) 缩放 \(layer.scaleXPercent),\(layer.scaleYPercent) 锚点 \(layer.alignmentXPercent),\(layer.alignmentYPercent) 其他变换 \(layer.unappliedTransform)"
                }
                if reason == "theora_image_layer_playback_unsupported",
                   let load = machine.imageLoadLocation(layer.id) {
                    reason += " · 载入 \(load.sourceFile):\(load.lineNumber) · 动作时钟 \(layer.motionElapsedTicks ?? -1)"
                }
                if unboundFlash {
                    let location = machine.imageLoadLocation(layer.id).map { "\($0.sourceFile):\($0.lineNumber)" } ?? "未记录"
                    reason += " · 闪光载入 \(location) · 动作时钟 \(layer.motionElapsedTicks ?? -1) · 槽 0 已绑定 \(layer.boundRasterPreview != nil)"
                }
                if layer.resource.sourceSHA256 == "97bb05fa8aaaff094f9ef12978d6fca0c7af6bd3081a01bbedd7ae5c02902a68" {
                    let text = messages.first { $0.id == layer.id }
                    reason += " · 居中文字已提交 \(text != nil) · 文字绘制区域可用 \(text?.canvasBounds != nil)"
                    if let surface = machine.messageSurfaceStatus(layer.id) {
                        reason += " · 文字表面队列 \(surface.pending) 已提交操作 \(surface.committed) 已设置范围 \(surface.hasBounds)"
                    }
                }
                let detail = layerIssue(layer.resource, reason)
                unavailableLayerFailures[layer.id] = detail
                unavailableLayers.append(detail)
                return nil
            }
        }
        for layer in layers {
            if let resolved = resolveLayer(layer) { rendered.append(resolved) }
        }
        if !isSystemLoadFrame, machine.executedSteps > 0, !machine.savedCaptureIsBound {
            restoredDisplay = nil
        }
        if !isSystemLoadFrame, movie == nil, let image = restoredDisplay {
            let canvas = CGRect(x: 0, y: 0, width: PlayerViewport.width, height: PlayerViewport.height)
            let initialFrame = machine.executedSteps == 0 &&
                !rendered.contains { $0.opacity > 0 && $0.bounds.intersects(canvas) } &&
                !messages.contains { $0.isVisible && $0.canvasBounds != nil }
            let fade = machine.savedCaptureFade
            if initialFrame || fade != nil {
                let layer = PlayerLayer(id: PlayerLayer.savedCaptureID, image: image, hoverImage: nil, x: 0, y: 0,
                    priority: fade?.priority ?? Int32.min, opacity: fade?.opacity ?? 255,
                    scaleXPercent: 100, scaleYPercent: 100, alignmentXPercent: 0, alignmentYPercent: 0,
                    usesVolumeButtonOffsets: false, isWindowControl: false)
                let insertion = rendered.firstIndex { $0.priority > layer.priority } ?? rendered.endIndex
                rendered.insert(layer, at: insertion)
            }
        }
        let titleButtons = machine.titleButtons
        let titleButtonLabels = titleButtons.keys.reduce(into: [UInt64: String]()) { labels, handle in
            switch machine.titleButtonTarget(handle) {
            case "@@!start": labels[handle] = "开始游戏"
            case "@@!load": labels[handle] = "读取存档"
            case "@@!extra": labels[handle] = "相册"
            case "@@!config": labels[handle] = "设置"
            case "@@!quit": labels[handle] = "退出"
            case "@@!albummode": labels[handle] = "CG 鉴赏"
            case "@@!memorymode": labels[handle] = "回想"
            case "@@!soundmode": labels[handle] = "音乐鉴赏"
            case "@@!back": labels[handle] = "返回"
            default: break
            }
        }
        var buttonSounds: [UInt64: [Int32: ScriptLocation]] = [:]
        let hoverableLayers = rendered.filter { $0.hoverImage != nil }.map(\.id)
        for handle in Set(choiceButtons.keys).union(titleButtons.keys).union(loadMenuButtons).union(machine.loadConfirmationButtons.keys).union(hoverableLayers) {
            let sounds = [Int32(0), 1].reduce(into: [Int32: ScriptLocation]()) { sounds, slot in
                sounds[slot] = machine.buttonSound(handle, slot: slot)
            }
            if !sounds.isEmpty { buttonSounds[handle] = sounds }
        }
        let choiceText = Dictionary(uniqueKeysWithValues: visibleChoiceButtons.values.compactMap { index in
            machine.storyChoiceText(index).map { (index, $0) }
        })
        let choiceTextSizes = visibleChoiceButtons.keys.reduce(into: [UInt64: CGSize]()) { sizes, handle in
            if let size = machine.storyChoiceTextSize(handle) {
                sizes[handle] = CGSize(width: CGFloat(size.width), height: CGFloat(size.height))
            }
        }
        return PlayerState(playbackIdentity: playbackIdentity, cutinSource: cutinSource, cutin: cutin, status: machine.playbackStatus, buttonSounds: buttonSounds, choiceButtons: choiceButtons, visibleChoiceButtons: visibleChoiceButtons, choiceText: choiceText, choiceTextSizes: choiceTextSizes,
                           choiceTextStyles: visibleChoiceButtons.keys.reduce(into: [:]) { $0[$1] = machine.storyChoiceTextStyle($1) },
                           waitingForChoice: machine.isWaitingForStoryChoice, windowViewButton: machine.windowViewButton,
                           windowLoadButton: machine.windowLoadButton,
                           dialogueWindowHidden: machine.isDialogueWindowHidden,
                           isSystemLoadFrame: isSystemLoadFrame,
                           loadConfirmationButtons: isSystemLoadFrame ? machine.loadConfirmationButtons : [:],
                           isWaitingForLoadConfirmation: isSystemLoadFrame && machine.isWaitingForLoadConfirmation, visibleSaveThumbnails: visibleSaveThumbnails, loadMenuButtons: loadMenuButtons,
                           loadCancelButton: loadMenuButtons.sorted().first(where: machine.isLoadMenuCancelButton),
                           loadPageIndices: loadMenuButtons.reduce(into: [:]) { $0[$1] = machine.loadPageIndex($1) },
                           checkedLoadPageButtons: Set(loadMenuButtons.filter(machine.isLoadPageChecked)),
                           titleButtons: titleButtons, titleButtonLabels: titleButtonLabels, titleStartButton: machine.titleStartButton,
                           waitingForClick: machine.phase == .waiting && machine.clickWaitRemaining == -1,
                           fullTextAlphas: fullTextAlphas, messageLayers: messages, layers: rendered,
                           pendingOpacityImages: machine.pendingOpacityImages,
                           unavailableLayers: unavailableLayers, unavailableLayerFailures: unavailableLayerFailures,
                           unimplementedAnimationCount: unimplementedAnimationCount,
                           maxMotionTicks: layers.compactMap(\.motionElapsedTicks).max() ?? 0, movie: movie, movieRequest: machine.moviePlaybackRequest,
                           systemTaskRequest: machine.systemTaskRequest,
                           soundChannel: machine.soundPlaybackChannel,
                           soundSource: machine.soundPlaybackRequest,
                           soundPreservesPosition: machine.soundPlaybackPreservesPosition,
                           soundRepeatCount: machine.soundPlaybackRepeatCount, soundInitialVolume: machine.soundPlaybackInitialVolume, activeSoundChannels: machine.activeSoundChannels,
                           immediateSoundVolumes: machine.immediateSoundVolumes,
                           soundVolumeChanges: machine.takeSoundVolumeChanges(),
                           immediateSoundPans: machine.immediateSoundPans,
                           soundPanChanges: machine.takeSoundPanChanges(),
                           soundSeeks: machine.takeActiveSoundSeeks(),
                           audioCacheHits: audioCacheHits, audioConversions: audioConversions)
    }

    private static let portraitMotionDigest = "5b0f2bc31cc6b14311642df53590c1efd3edec3b6a032e13b90424ce70e99b03"

    private static let portraitStationaryTicks: [Int32: Int32] = [0: 0, 1: 300, 2: 700, 3: 1100, 7: 500, 11: 1500, 13: 300, 14: 700]

    private func portraitExitIsFinished(_ layer: ScriptMachine.StaticImageLayer) -> Bool {
        guard layer.resource.sourceSHA256 == Self.portraitMotionDigest,
              layer.selectedMember == 26, let ticks = layer.motionElapsedTicks,
              let keys = recipe.motionKeys(layer.resource, selectedMember: 26, time: ticks) else { return false }
        return keys.count == 2 && keys.allSatisfy { $0.type == 0 }
    }

    private func auditedPortraitSample(_ layer: ScriptMachine.StaticImageLayer) -> (offset: CGPoint, sampling: Int32)? {
        guard layer.resource.sourceSHA256 == Self.portraitMotionDigest,
              let action = layer.selectedMember,
              !layer.unappliedTransform,
              !layer.hasExplicitAlignment || (layer.alignmentXPercent == 50 && layer.alignmentYPercent == 100),
              let time = layer.motionElapsedTicks else { return nil }
        let sampleTime: Int32
        if action == 26 {
            sampleTime = time
        } else if action == 4 || action == 16 {
            // The second track loops back to its first key at tick 500.
            sampleTime = time % 500
        } else if let stationaryTick = Self.portraitStationaryTicks[action] {
            sampleTime = min(time, stationaryTick)
        } else {
            return nil
        }
        guard let keys = recipe.motionKeys(layer.resource, selectedMember: action, time: sampleTime),
              keys.count == 2, keys[0].type == 0 else { return nil }
        let key = keys[1]
        guard key.type == 4, key.texture_numbers?.first == 0, key.source_areas?.first == [0, 0, 0, 0],
              key.literalAnchorRatio.map({ $0.x == 0.5 && $0.y == 1 }) == true,
              recipe.composedOpacity(texture: key, states: []) == 255,
              let modes = recipe.composedRasterModes(texture: key, states: []), modes.blend == 1,
              modes.sampling == 0 || modes.sampling == 2,
              let position = recipe.axisAlignedState([key]), position.scaleX == 1, position.scaleY == 1 else { return nil }
        let offset = CGPoint(x: position.x * Double(layer.scaleXPercent) / 100,
                             y: position.y * Double(layer.scaleYPercent) / 100)
        return (offset, Int32(modes.sampling))
    }

    private func boundMotionSample(_ layer: ScriptMachine.StaticImageLayer) -> (offset: CGPoint, sampling: Int32?)? {
        if layer.boundRasterPreview != nil, let sample = auditedPortraitSample(layer) {
            return (sample.offset, sample.sampling)
        }
        guard layer.boundRasterPreview != nil, layer.resource.sourceSHA256 ==
            Self.portraitMotionDigest,
              let member = layer.selectedMember, (1...4).contains(member),
              let time = layer.motionElapsedTicks else { return nil }
        // In the default control state the repeating texture layer jumps from 500 to 0.
        let sampleTime = member == 4 ? time % 500 : time
        guard let keys = recipe.motionKeys(layer.resource, selectedMember: member, time: sampleTime),
              let key = keys.first(where: { $0.type == 4 && $0.texture_numbers?.first == 0 }),
              let position = recipe.axisAlignedState([key]) else { return nil }
        return (CGPoint(x: position.x * Double(layer.scaleXPercent) / 100,
                        y: position.y * Double(layer.scaleYPercent) / 100), nil)
    }

    private var windowControlState: (y: CGFloat, alpha: UInt8)? {
        machine.dialogueWindowMotion.map {
            ScriptImageRecipe.sampleDialogueWindow(closing: $0.closing, ticks: $0.ticks)
        }
    }

    private var hasActiveBoundMotion: Bool {
        if let motion = machine.dialogueWindowMotion, motion.advancing,
           motion.closing || motion.ticks < 250 { return true }
        let layers = machine.staticImageLayers
        let otherEndpoints: [Int32: Int32] = [4: .max, 16: .max, 26: 400]
        return layers.contains { layer in
            if layer.resource.sourceSHA256 == Self.dialogueFrameDigest {
                // Enable repeats the same two draw keys. Disable reaches a
                // non-drawing key at 250 ticks and stays there.
                return layer.motionIsAdvancing && layer.selectedMember == 1 &&
                    (layer.motionElapsedTicks ?? .max) < 250
            }
            // The audited enable action loops one opaque draw key. Only the
            // disable action needs idle samples to reach its non-drawing key.
            if layer.motionIsAdvancing, layer.selectedMember == 1,
               sampleFullText(layer)?.drawing == true { return true }
            if layer.motionIsAdvancing, sampleWhiteFlash(layer) != nil || activeSceneVideos[layer.id] == layer.resource && sceneVideos[layer.resource] != nil && sceneVideoFailures[layer.resource] == nil { return true }
            if layer.motionIsAdvancing, let time = textEffectTime(layer), time < 1000 { return true }
            guard layer.motionIsAdvancing, let member = layer.selectedMember,
                  let endpoint = Self.portraitStationaryTicks[member] ?? otherEndpoints[member],
                  let time = layer.motionElapsedTicks, time < endpoint else { return false }
            return boundMotionSample(layer) != nil
        }
    }

    private func textEffectTime(_ layer: ScriptMachine.StaticImageLayer) -> Int32? {
        guard layer.selectedMember == 0, layer.resource.sourceSHA256 ==
            "cd20f60e0984abd828a5f8c8567335a385339372dd99c2731def35ac4b4e972b" else { return nil }
        return layer.motionElapsedTicks
    }

    private static let fullTextDigest = "4b8c83118bbeee2e040b2c7ffab4d4704d134a373faa28e936b930207020a5c8"

    private func sampledFullTextAlphas(_ layers: [ScriptMachine.StaticImageLayer]) -> [UInt64: UInt8] {
        Dictionary(uniqueKeysWithValues: layers.compactMap { layer in
            sampleFullText(layer).map { (layer.id, $0.alpha) }
        })
    }

    private func sampleFullText(_ layer: ScriptMachine.StaticImageLayer) -> (alpha: UInt8, drawing: Bool)? {
        guard layer.resource.sourceSHA256 == Self.fullTextDigest,
              let action = layer.selectedMember, (0...1).contains(action),
              let ticks = layer.motionElapsedTicks,
              let keys = recipe.motionKeys(layer.resource, selectedMember: action, time: ticks),
              keys.count == 2, keys[0].type == 0 else { return nil }
        let key = keys[1]
        if key.type == 0 { return (0, false) }
        guard key.type == 4, key.texture_numbers?.first == 1,
              let alpha = recipe.composedOpacity(texture: key, states: []) else { return nil }
        return (UInt8(Int(alpha) * Int(layer.opacity) / 255), true)
    }

    private static let whiteFlashDigest = "dea47b18a5dac17a733523ca0a8c00167bf24217b168bf5330e8f11097f0d354"

    private static let regularFlashDigest = "fec9d49e9c5fe248bb6ec76d6c60b87f93c87ed70533a9c829c6e8621d811370"

    private static let layeredFlashDigest = "1ac81465631f953bcd762639ea41a940a5c9ae1bc42ce438fdf776a88f4ab497"

    private func sampleWhiteFlash(_ layer: ScriptMachine.StaticImageLayer) -> (size: SIMD2<Int>, alpha: UInt8, hasUnboundTexture: Bool)? {
        guard [Self.whiteFlashDigest, Self.regularFlashDigest, Self.layeredFlashDigest].contains(layer.resource.sourceSHA256),
              layer.selectedMember == 0, layer.boundRasterPreview == nil, !layer.unappliedTransform,
              layer.scaleXPercent == 100, layer.scaleYPercent == 100, layer.opacity == 255,
              layer.alignmentXPercent == 50, layer.alignmentYPercent == 50,
              let time = layer.motionElapsedTicks,
              let keys = recipe.motionKeys(layer.resource, selectedMember: 0, time: time) else { return nil }
        let draws = keys.filter { $0.type != 0 }
        guard let key = draws.last, let flash = recipe.whiteFlashPreview(key, container: layer.resource) else { return nil }
        if draws.count == 1 { return (flash.size, flash.alpha, false) }
        guard draws.count == 2, draws[0].type == 4, draws[0].texture_numbers?.first == 0 else { return nil }
        return (flash.size, flash.alpha, true)
    }

    private func dialogBlackOpacity(_ layer: ScriptMachine.StaticImageLayer) -> UInt8? {
        guard layer.resource.sourceSHA256 == Self.dialogBlackDigest,
              let member = layer.selectedMember, let time = layer.motionElapsedTicks,
              let keys = recipe.motionKeys(layer.resource, selectedMember: member, time: time),
              keys.count == 1, let key = keys.first, key.type == 1,
              let opacity = recipe.composedOpacity(texture: key, states: []) else { return nil }
        return UInt8((Int(opacity) * Int(layer.opacity) + 127) / 255)
    }

    private func cutinLayer(_ layer: ScriptMachine.StaticImageLayer) -> PlayerCutin? {
        guard layer.resource.sourceSHA256 == PlayerCutinSource.sha256,
              layer.selectedMember == 0, !layer.unappliedTransform,
              layer.scaleXPercent == 100, layer.scaleYPercent == 100,
              (try? recipe.member(layer.resource, "万華鏡.ogv")) != nil else { return nil }
        let x = Double(layer.x) - (1280 * Double(layer.alignmentXPercent) / 100).rounded()
        let y = Double(layer.y) - (720 * Double(layer.alignmentYPercent) / 100).rounded()
        return PlayerCutin(id: layer.id, priority: layer.priority,
                           bounds: CGRect(x: x, y: y, width: 1280, height: 720), opacity: layer.opacity)
    }

    func advanceIdleVisuals(ticks: Int32, cutinID: UInt64?) async -> (sceneFrames: [UInt64: CGImage], sceneIssues: [String], dialogueFrames: [UInt64: [DialogueFrameTexture]], layers: [UInt64: ScriptMachine.StaticImageLayer], motions: [UInt64: (offset: CGPoint, sampling: Int32?)], dialogBlackAlphas: [UInt64: UInt8], fullTextAlphas: [UInt64: UInt8], whiteFlashes: [UInt64: UInt8], windowAnimation: (y: CGFloat, alpha: UInt8)?, pendingOpacity: Set<UInt64>, expiredTextEffects: Set<UInt64>, cutin: PlayerCutin?, savedCaptureOpacity: UInt8?, timerDue: Bool)? {
        // The load screen is rendered by a separate machine with its own layer IDs.
        guard !Task.isCancelled, !accelerated, systemLoadTask == nil, machine.moviePlaybackRequest == nil,
              machine.phase == .waitingForEvent || (machine.phase == .waiting && machine.clickWaitRemaining == -1),
              ticks > 0 else { return nil }
        guard hasActiveBoundMotion || machine.ticksUntilOpacityEndpoint != nil ||
                machine.ticksUntilPlacementEndpoint != nil || machine.ticksUntilTimer != nil ||
                machine.savedCaptureFade != nil else { return nil }
        machine.advanceTimerClock(ticks: ticks)
        machine.advanceVisualClock(ticks: ticks)
        let layers = machine.staticImageLayers.filter { !portraitExitIsFinished($0) }
        let motions = layers.compactMap { layer in boundMotionSample(layer).map { (layer.id, $0) } }
        let dialogBlackAlphas = layers.compactMap { layer in dialogBlackOpacity(layer).map { (layer.id, $0) } }
        var sceneFrames: [UInt64: CGImage] = [:]
        var sceneIssues: [String] = []
        for layer in layers where layer.motionIsAdvancing && activeSceneVideos[layer.id] == layer.resource &&
            sceneVideos[layer.resource] != nil &&
            sceneVideoFailures[layer.resource] == nil {
            do {
                sceneFrames[layer.id] = try await sceneFrame(layer)
            } catch is CancellationError {
                return nil
            } catch {
                guard !Task.isCancelled else { return nil }
                let reason = String(describing: error)
                sceneVideoFailures[layer.resource] = reason
                sceneIssues.append("动态 CG 停在最后可用帧 · \(layer.resource.sourceFile) · \(reason)")
                FileHandle.standardError.write(Data("player_idle_scene_error=\(reason)\n".utf8))
            }
        }
        var dialogueFrames: [UInt64: [DialogueFrameTexture]] = [:]
        for layer in layers where layer.resource.sourceSHA256 == Self.dialogueFrameDigest {
            do {
                dialogueFrames[layer.id] = try dialogueFrameTextures(layer)
            } catch {
                sceneIssues.append("对白边框无法采样 · \(layer.resource.sourceFile) · \(error)")
            }
        }
        return (sceneFrames, sceneIssues, dialogueFrames, Dictionary(uniqueKeysWithValues: layers.map { ($0.id, $0) }),
                Dictionary(uniqueKeysWithValues: motions), Dictionary(uniqueKeysWithValues: dialogBlackAlphas), sampledFullTextAlphas(layers), Dictionary(uniqueKeysWithValues: layers.compactMap { layer in
                    sampleWhiteFlash(layer).map { (layer.id, $0.alpha) }
                }), windowControlState, machine.pendingOpacityImages,
                Set(layers.filter { (textEffectTime($0) ?? 0) >= 1000 }.map(\.id)),
                cutinID.flatMap { id in layers.first { $0.id == id }.flatMap(cutinLayer) },
                machine.savedCaptureFade?.opacity, machine.ticksUntilTimer == 0)
    }

    func reachChoiceTimerDeadline() throws -> Int32 {
        guard machine.isWaitingForStoryChoice, let ticks = machine.ticksUntilTimer, (0...1000).contains(ticks) else {
            throw ResourceError.rejected("player_choice_timer_deadline_unavailable")
        }
        machine.advanceTimerClock(ticks: ticks)
        return ticks
    }

    func dialogueHistory() -> [ScriptMachine.DialogueHistoryLine] {
        machine.recentDialogueHistory
    }

    struct SystemLoadStatus: Sendable {
        let steps: Int
        let reason: String?
        let location: ScriptLocation?
        let capturePriority: Int32?
        let waitTicks: Int32?
    }

    func runSystemLoadWaits(_ initial: SystemLoadStatus,
                            presentTimedFrame: @MainActor @Sendable (PlayerState) -> Void) async throws -> SystemLoadStatus {
        var status = initial
        let clock = ContinuousClock()
        var deadline = clock.now
        while let remaining = status.waitTicks, remaining >= 0 {
            try Task.checkCancellation()
            var ticks = remaining
            if !accelerated, ticks > 0 {
                if let task = systemLoadTask, task.staticImageLayers.contains(where: {
                    $0.resource.sourceSHA256 == Self.dialogBlackDigest && $0.motionIsAdvancing
                }) {
                    ticks = min(16, remaining)
                }
                deadline = deadline.advanced(by: .milliseconds(Int64(ticks)))
                if let frame = systemLoadFrame() { await presentTimedFrame(frame) }
                try await clock.sleep(until: deadline)
            }
            status = try advanceSystemLoadWait(ticks: ticks)
            if ticks == remaining { deadline = clock.now }
        }
        return status
    }

    private func advanceSystemLoadWait(ticks: Int32) throws -> SystemLoadStatus {
        try Task.checkCancellation()
        guard var task = systemLoadTask else {
            throw ResourceError.rejected("system_load_task_required")
        }
        try task.advanceClickWait(ticks: ticks)
        try task.advancePlacementClock(ticks: ticks)
        return try advanceSystemLoadTask(task)
    }

    func startSystemLoadTask() throws -> SystemLoadStatus {
        guard systemLoadTask == nil else { throw ResourceError.rejected("system_load_task_already_started") }
        return try advanceSystemLoadTask(machine.startSystemLoadTask())
    }

    func supplySystemCapture(_ data: Data) throws -> SystemLoadStatus {
        guard var task = systemLoadTask, systemCapture == nil, (1...8 * 1024 * 1024).contains(data.count) else {
            throw ResourceError.rejected("invalid_game_thread_image_capture")
        }
        let image = try ResourceImage.decode(data).image
        let source = ScriptModuleReference(logicalPath: "system-capture.png", sourceFile: "system-capture.png",
                                           sourceSHA256: data.sha256Hex).wholeFileLocation(byteLength: data.count)
        try task.supplyScreenCapture(source, width: image.width, height: image.height)
        systemCapture = (source, image)
        return try advanceSystemLoadTask(task)
    }

    private func advanceSystemLoadTask(_ initial: ScriptMachine) throws
        -> SystemLoadStatus {
        var task = initial
        try machine.runSystemLoadTask(&task)
        systemLoadTask = task
        let status = task.playbackStatus
        let wait = status.phase == .waiting ? task.clickWaitRemaining : nil
        return SystemLoadStatus(steps: status.steps, reason: status.stopReason, location: status.currentLocation,
                                capturePriority: task.screenCaptureRequest?.priority, waitTicks: wait)
    }

    func probeSaveThumbnailReplacement(slot name: String, jpeg: Data) throws -> Data {
        guard let saveDirectory, try SafeDirectory.components(name).count == 1 else {
            throw ResourceError.rejected("save_thumbnail_directory_unavailable")
        }
        let original = try saveDirectory.read(name, limit: SaveEnvelope.maxFileBytes)
        let rewritten = try SaveEnvelope.replacingSlotThumbnail(in: original, with: jpeg)
        guard let old = try SaveEnvelope(original).slot, let new = try SaveEnvelope(rewritten).slot,
              original.dropFirst(old.state.offset - 4).elementsEqual(rewritten.dropFirst(new.state.offset - 4)) else {
            throw ResourceError.rejected("save_thumbnail_replacement_changed_state")
        }
        return rewritten
    }

    func recoverFailedSaveLoad() -> Bool {
        guard machine.abortSystemLoad() else { return false }
        systemLoadTask = nil
        systemCapture = nil
        return true
    }

    func loadSlotButton(named name: String) throws -> UInt64? {
        try systemLoadTask?.loadSlotButton(named: name)
    }

    func systemLoadFrame() -> PlayerState? {
        guard var task = systemLoadTask,
              task.phase == .waitingForEvent || task.phase == .waiting else { return nil }
        // Render through the same layer resolver, with the task's object IDs and clock.
        // No suspension is possible while the primary machine is swapped out.
        swap(&machine, &task)
        defer {
            swap(&machine, &task)
            systemLoadTask = task
        }
        return snapshot(isSystemLoadFrame: true)
    }

    func soundCompleted(channel: UInt64, playbackStartStep: Int, identity: UUID) {
        guard identity == playbackIdentity else { return }
        machine.acknowledgeSoundCompletion(channel: channel, playbackStartStep: playbackStartStep)
    }

    func buttonAudio(_ source: ScriptLocation) throws -> Data {
        try Task.checkCancellation()
        if let cached = buttonAudioCache.value(for: source) { return cached }
        let data = try assets.read(source.sourceFile, limit: 1024 * 1024)
        guard source.byteOffset == 0, source.byteLength == data.count,
              data.sha256Hex == source.sourceSHA256, source.sourceSHA256 == source.rangeSHA256 else {
            throw ResourceError.rejected("player_button_audio_identity")
        }
        buttonAudioCache.insert(data, for: source, cost: data.count)
        return data
    }

    private func rasterPayload(_ source: ScriptLocation) throws -> Data {
        let data: Data
        let savePrefix = "save-slot/"
        if let embedded = machine.savedTextureBytes(source) {
            data = embedded
        } else if source.sourceFile.hasPrefix(savePrefix) {
            guard let saveDirectory else {
                throw ResourceError.rejected("save_thumbnail_directory_unavailable")
            }
            data = try saveDirectory.read(String(source.sourceFile.dropFirst(savePrefix.count)),
                                          limit: SaveEnvelope.maxFileBytes)
        } else {
            data = try assets.read(source.sourceFile)
        }
        guard data.sha256Hex == source.sourceSHA256,
              source.byteOffset >= 0, source.byteLength > 0, source.byteOffset <= data.count,
              source.byteLength <= data.count - source.byteOffset else {
            throw ResourceError.rejected("player_image_source_identity_or_range")
        }
        let payload = data.subdata(in: source.byteOffset..<(source.byteOffset + source.byteLength))
        guard payload.sha256Hex == source.rangeSHA256 else {
            throw ResourceError.rejected("player_image_range_identity")
        }
        return payload
    }

    private func loadButtonHoverMember(_ layer: ScriptMachine.StaticImageLayer, menuButtons: Set<UInt64>,
                                       confirmationButtons: [UInt64: Bool]) -> String? {
        switch layer.resource.sourceFile.lowercased().split(separator: "/").suffix(3).joined(separator: "/") {
        case "script/saveload/button_l.b" where menuButtons.contains(layer.id):
            return "戻る_on.png"
        case "script/dialog/button_yes.b" where confirmationButtons[layer.id] == true:
            return "確認_はい_on.png"
        case "script/dialog/button_no.b" where confirmationButtons[layer.id] == false:
            return "確認_いいえ_on.png"
        default:
            return nil
        }
    }

    private func staticRaster(_ source: ScriptLocation, selectedMember: Int32?, choiceHover: Bool? = nil) throws -> Raster {
        if let capture = systemCapture, source == capture.source {
            return Raster(image: capture.image, isInterfaceBackgroundPreview: false)
        }
        let key = RasterKey(source: source, selectedMember: selectedMember, choiceHover: choiceHover)
        if let cached = rasterCache.value(for: key) { return try cached.get() }
        let payload = try rasterPayload(source)
        // Memoize unsupported recipes only after verifying the resource bytes.
        // Read, identity and decoder failures remain retryable.
        let result = Result {
            try decodeRaster(payload, sourceFile: source.sourceFile, selectedMember: selectedMember, choiceHover: choiceHover)
        }
        let cost: Int
        switch result {
        case .success(let raster): cost = raster.image.bytesPerRow * raster.image.height
        case .failure(ResourceError.rejected(let reason)) where reason.hasPrefix("abmp_raster_")
            || reason == "choice_button_raster_recipe_missing" || reason == "theora_image_layer_playback_unsupported":
            cost = 0
        case .failure(let error):
            throw error
        }
        rasterCache.insert(result, for: key, cost: cost)
        return try result.get()
    }

    private func decodeRaster(_ payload: Data, sourceFile: String, selectedMember: Int32?, choiceHover: Bool?) throws -> Raster {
        if let choiceHover {
            let bytes = try recipe.choiceButtonPayload(payload, hovered: choiceHover)
            return Raster(image: try ResourceImage.decode(bytes).image, isInterfaceBackgroundPreview: false)
        }
        if payload.starts(with: Data("OggS".utf8)) {
            _ = try ScriptMovieHeader.theoraDimensions(payload)
            throw ResourceError.rejected("theora_image_layer_playback_unsupported")
        }
        let preview = try recipe.interfaceBackgroundPreview(payload, sourceFile: sourceFile)
        let bytes = try preview ?? recipe.staticRasterPayload(payload, sourceFile: sourceFile, selectedMember: selectedMember)
        return Raster(image: try ResourceImage.decode(bytes).image, isInterfaceBackgroundPreview: preview != nil)
    }

    private var samplesAcceleratedVisualWait: Bool {
        if skipAudioForChoiceProbe && hasActiveBoundMotion { return true }
        guard accelerated else { return false }
        if machine.executedSteps == 0,
           restoredDisplay != nil || machine.staticImageLayers.contains(where: { $0.opacity > 0 }) { return true }
        if restoredDisplay != nil, machine.savedCaptureFade != nil { return true }
        let pendingOpacity = cutinSource == nil ? [] : machine.pendingOpacityImages
        guard !pendingOpacity.isEmpty || machine.hasAdvancingImage(sourceSHA256: Self.whiteFlashDigest) ||
            machine.hasAdvancingImage(sourceSHA256: Self.regularFlashDigest) ||
            machine.hasAdvancingImage(sourceSHA256: Self.layeredFlashDigest) else { return false }
        return machine.staticImageLayers.contains { layer in
            (layer.motionIsAdvancing && sampleWhiteFlash(layer) != nil) ||
                (cutinSource != nil && pendingOpacity.contains(layer.id) &&
                 layer.resource.sourceSHA256 == PlayerCutinSource.sha256)
        }
    }

    private func waitTicks(_ remaining: Int32, sampleAccelerated: Bool = false) async throws -> Int32 {
        let ticks = min(remaining, machine.ticksUntilTimer ?? remaining)
        guard !accelerated else { return sampleAccelerated ? min(16, ticks) : ticks }
        // Publish the known destination even when the enclosing script wait is longer.
        let opacityTicks = machine.ticksUntilOpacityEndpoint.map { min(16, $0) } ?? ticks
        let placementEndpoint = machine.ticksUntilPlacementEndpoint ?? ticks
        let placementTicks = machine.hasSampledPlacementTransition ? min(16, placementEndpoint) : placementEndpoint
        let motionTicks = hasActiveBoundMotion ? 16 : ticks
        let savedFadeTicks = machine.savedCaptureFade == nil ? ticks : 16
        let frameTicks = min(ticks, placementTicks, opacityTicks, motionTicks, savedFadeTicks)
        try await Task.sleep(for: .milliseconds(Int64(frameTicks)))
        return frameTicks
    }
}

struct PlayerLaunch: Sendable {
    static let homebrewDecoder = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")

    static func isDecoder(_ url: URL) -> Bool {
        url.lastPathComponent == "ffmpeg" &&
            (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true &&
            FileManager.default.isExecutableFile(atPath: url.path)
    }

    let assets: URL
    let replay: URL
    let game: URL
    let ffmpeg: URL
    let saveURL: URL?
    let startAtTitle: Bool
    let advanceToDialogue: Bool
    let checkWindowView: Bool
    let checkDialogueLoad: Bool
    let checkDialogueLoadStartupFailure: Bool
    let checkCutinLoad: Bool
    let advanceToOpacity: Bool
    let checkAudioResume: Bool
    let advanceToChoice: Bool
    let checkChoiceCount: Int
    let checkChoiceTimer: Bool
    let openLoadMenu: Bool
    let checkLoadPage: Bool
    let checkLoadCancel: Bool
    let checkLoadEscape: Bool
    let checkLoadConfirmationSlot: String?
    let checkExperimentalSaveAdoption: Bool
    let checkDialogueSaveAdoption: Bool
    let expectedLoadRecoveryCause: String?
    var checkLoadRecovery: Bool { expectedLoadRecoveryCause != nil }
    let replayRoute: Bool
    let realtimeRoute: Bool

    init?(arguments: [String]) {
        let rejectDialogueSave = arguments.last?.hasPrefix("--check-dialogue-save-rejection=") == true
        checkDialogueSaveAdoption = rejectDialogueSave ||
            arguments.last?.hasPrefix("--check-dialogue-save-adoption=") == true
        checkExperimentalSaveAdoption = checkDialogueSaveAdoption ||
            arguments.last?.hasPrefix("--check-experimental-save-adoption=") == true
        checkWindowView = arguments.last == "--check-window-view"
        checkDialogueLoadStartupFailure = arguments.last == "--check-dialogue-load-startup-failure"
        checkCutinLoad = arguments.last == "--check-cutin-load"
        checkDialogueLoad = checkDialogueSaveAdoption || checkCutinLoad || checkDialogueLoadStartupFailure || arguments.last == "--check-dialogue-load" ||
            arguments.last?.hasPrefix("--check-dialogue-load-recovery=") == true
        advanceToDialogue = checkDialogueLoad || checkWindowView || arguments.last == "--advance-to-dialogue"
        advanceToOpacity = arguments.last == "--advance-to-opacity"
        checkAudioResume = arguments.last == "--check-audio-resume"
        switch arguments.last {
        case "--check-first-choice", "--check-choice-timer": checkChoiceCount = 1
        case "--check-second-choice": checkChoiceCount = 2
        case let option? where option.hasPrefix("--check-choices="):
            guard let count = Int(option.dropFirst("--check-choices=".count)),
                  (1...64).contains(count) else { return nil }
            checkChoiceCount = count
        default:
            checkChoiceCount = 0
        }
        checkChoiceTimer = arguments.last == "--check-choice-timer"
        advanceToChoice = checkChoiceTimer || checkChoiceCount > 0 || arguments.last == "--advance-to-choice"
        checkLoadPage = arguments.last == "--check-load-page"
        checkLoadEscape = arguments.last == "--check-load-escape"
        checkLoadCancel = checkLoadEscape || arguments.last == "--check-load-cancel"
        let confirmationPrefix: String
        if rejectDialogueSave {
            confirmationPrefix = "--check-dialogue-save-rejection="
            expectedLoadRecoveryCause = "saved_stream_seek_at_or_past_end"
        } else if checkExperimentalSaveAdoption {
            confirmationPrefix = checkDialogueSaveAdoption ? "--check-dialogue-save-adoption=" : "--check-experimental-save-adoption="
            expectedLoadRecoveryCause = nil
        } else if arguments.last?.hasPrefix("--check-load-version-mismatch=") == true {
            confirmationPrefix = "--check-load-version-mismatch="
            expectedLoadRecoveryCause = "save_reader_line_buffer_differs"
        } else if arguments.last?.hasPrefix("--check-load-recovery=") == true {
            confirmationPrefix = "--check-load-recovery="
            expectedLoadRecoveryCause = "save_restore_execution_state_unsupported"
        } else {
            confirmationPrefix = checkDialogueLoad ? "--check-dialogue-load-recovery=" : "--check-load-confirmation="
            expectedLoadRecoveryCause = nil
        }
        if let option = arguments.last, option.hasPrefix(confirmationPrefix) {
            let slot = String(option.dropFirst(confirmationPrefix.count))
            guard (try? SafeDirectory.components(slot))?.count == 1 else { return nil }
            checkLoadConfirmationSlot = slot
        } else {
            checkLoadConfirmationSlot = nil
        }
        openLoadMenu = checkLoadCancel || checkLoadPage || (!checkDialogueLoad && checkLoadConfirmationSlot != nil) ||
            arguments.last == "--open-load-menu"
        realtimeRoute = arguments.last == "--replay-route-realtime"
        replayRoute = realtimeRoute || arguments.last == "--replay-route"
        startAtTitle = replayRoute || advanceToChoice || advanceToDialogue || advanceToOpacity ||
            checkAudioResume || arguments.last == "--start-at-title"
        let arguments = startAtTitle || openLoadMenu ? Array(arguments.dropLast()) : arguments
        guard (6...10).contains(arguments.count), arguments.count.isMultiple(of: 2) else { return nil }
        let supportedPaths = Set(["--assets-dir", "--replay-dir", "--game-dir", "--ffmpeg", "--save-dir"])
        var paths: [String: URL] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            guard supportedPaths.contains(arguments[index]), arguments[index + 1].hasPrefix("/"),
                  paths[arguments[index]] == nil else { return nil }
            paths[arguments[index]] = URL(fileURLWithPath: arguments[index + 1])
        }
        let ffmpeg = paths["--ffmpeg"] ?? Self.homebrewDecoder
        guard let assets = paths["--assets-dir"], let replay = paths["--replay-dir"],
              let game = paths["--game-dir"], Self.isDecoder(ffmpeg) else { return nil }
        self.assets = assets
        self.replay = replay
        self.game = game
        self.ffmpeg = ffmpeg
        saveURL = paths["--save-dir"]
    }
}

struct PlayerWindow: View {
    @ObservedObject var library: LibraryModel
    var launch: PlayerLaunch? = nil
    @AppStorage("player.masterVolume") private var masterVolume: Double = 1
    @AppStorage("player.isMuted") private var isMuted = false
    private struct ReplayConfiguration {
        let assets: SafeDirectory
        let replay: URL
        let game: URL
        let ffmpeg: URL
        let resolvedDecoder: URL
        let saveURL: URL?
    }
    @State private var currentReplay: ReplayConfiguration?
    @State private var failedReplay: ReplayConfiguration?
    @State private var saveImportIssues: [String] = []
    @AppStorage("player.lastLaunchPaths") private var lastLaunchPaths: Data = Data()
    @State private var launched = false
    @State private var startedFromLaunch = false
    @State private var reportedRouteReturn = false
    @State private var startedDialogueLoadProbe = false
    @State private var titlePointerOnRight: Bool?
    @State private var launchClicks = 0
    @State private var observedOpacity = false
    @State private var loggedLayerIssues: Set<String> = []
    @State private var choiceCursor = 0
    @State private var session: PlayerSession?
    @State private var history: [ScriptMachine.DialogueHistoryLine] = []
    @State private var showingHistory = false
    @State private var work: Task<Void, Never>?
    @State private var idleVisuals: Task<Void, Never>?
    @State private var workID: UUID?
    @State private var runningIdleTimer = false
    @State private var choiceDuringTimer: (handle: UInt64, index: Int32)?
    @State private var state: PlayerState?
    @State private var issue: String?
    @State private var hoveredButton: UInt64?
    @State private var canvasPointer: CGPoint?
    @FocusState private var loadMenuFocused: Bool
    @State private var buttonAudioTask: Task<Void, Never>?
    @State private var buttonAudioPlayer: AVAudioPlayer?
    @State private var buttonAudioCompletion: PlayerAudioCompletion?
    @State private var video: AVPlayer?
    @State private var cutinVideo: AVPlayer?
    @State private var cutinPausedForLoad = false
    @State private var cutinObservedOpacity: UInt8?
    @State private var cutinMovie: PlayerMovie?
    @State private var cutinWork: Task<Void, Never>?
    @State private var cutinStatus: NSKeyValueObservation?
    @State private var cutinFailure: String?
    @State private var videoPaused = false
    @State private var pendingMovieCompletion: Int32?
    @State private var videoStatus: NSKeyValueObservation?
    @State private var displayedPlaybackIdentity: UUID?
    @State private var audio: [UInt64: AVAudioPlayer] = [:]
    @State private var audioSources: [UInt64: ScriptLocation] = [:]
    @State private var audioPlaybackSteps: [UInt64: Int] = [:]
    @State private var audioCompletions: [UInt64: PlayerAudioCompletion] = [:]
    @State private var audioGains: [UInt64: Float] = [:]
    private enum SoundControl: Hashable { case volume, pan }
    private struct SoundFade: Hashable {
        let channel: UInt64
        let control: SoundControl
    }
    @State private var soundFades: [SoundFade: Task<Void, Never>] = [:]

    var body: some View {
        VStack(spacing: 18) {
            Text("万華鏡").font(.largeTitle)
            Text("原生试玩 · 开发中").foregroundStyle(.secondary)
            if launch == nil, !lastLaunchPaths.isEmpty {
                Button("打开上次试玩配置", action: reopenLastReplay)
                    .disabled(work != nil)
            }
            Menu("载入本地回放配置") {
                Button("选择回放配置…") { chooseReplay() }
                Button("选择回放配置及只读存档…") { chooseReplay(includeSaves: true) }
            }
            .disabled(work != nil)
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("正在运行原版脚本…")
                    .font(.caption)
            }
            .frame(height: 20)
            .opacity(work == nil ? 0 : 1)
            .accessibilityHidden(work == nil)
            HStack {
                Button("对话记录", action: openHistory)
                    .disabled(work != nil || session == nil || video != nil)
                Button("停止试玩", action: stopSession)
                    .disabled(work == nil && session == nil)
                if let video {
                    Button(videoPaused ? "继续影片" : "暂停影片") {
                        if videoPaused { video.play() }
                        else { video.pause() }
                        videoPaused.toggle()
                    }
                    .keyboardShortcut(.space, modifiers: [])
                }
            }
            HStack {
                Toggle("静音", isOn: $isMuted)
                    .toggleStyle(.button)
                Slider(value: $masterVolume, in: 0...1) { Text("总音量") }
                    .frame(maxWidth: 240)
                Text(masterVolume.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit()
            }
            .font(.caption)
            if let state {
                let result = state.status
                LabeledContent("脚本步数", value: result.steps.formatted())
                LabeledContent("运行状态", value: result.phase.rawValue)
                if video != nil || cutinVideo != nil || !state.layers.isEmpty || state.messageLayers.contains(where: { $0.canvasBounds != nil }) {
                    // The movie placement profile treats the third operand as its layer priority.
                    let movieOrder: (Int32, UInt64)? = video != nil
                        ? state.movieRequest?.placement.last.map { ($0, 0) }
                        : (cutinVideo == nil ? nil : state.cutin.map { ($0.priority, $0.id) })
                    sceneCanvas(state) { priority, id in
                        movieOrder.map { (priority, id) < $0 } ?? true
                    }
                    .aspectRatio(PlayerViewport.width / PlayerViewport.height, contentMode: .fit)
                    .layoutPriority(1)
                    .background(.black)
                    .overlay(alignment: .topLeading) {
                        if let video, let request = state.movieRequest, request.size.0 > 0, request.size.1 > 0 {
                            canvasVideo(video, bounds: CGRect(
                                x: CGFloat(request.placement[0]), y: CGFloat(request.placement[1]),
                                width: CGFloat(request.size.0), height: CGFloat(request.size.1)))
                        } else if !state.isSystemLoadFrame, let cutinVideo, let cutin = state.cutin {
                            canvasVideo(cutinVideo, bounds: cutin.bounds, opacity: Double(cutin.opacity) / 255, traceCutin: launch != nil)
                        }
                    }
                    .overlay {
                        if let movieOrder {
                            sceneCanvas(state) { ($0, $1) >= movieOrder }
                                .allowsHitTesting(false)
                        }
                    }
                    .clipped()
                    .overlay {
                        if result.phase == .waitingForEvent || state.waitingForClick,
                           work == nil || (runningIdleTimer && state.waitingForChoice) {
                            GeometryReader { geometry in
                                Color.clear.contentShape(Rectangle())
                                    .onContinuousHover { phase in
                                        switch phase {
                                        case .active(let point):
                                            updatePointer(PlayerViewport(geometry.size).canvasPoint(point), state: state)
                                        case .ended:
                                            updatePointer(nil, state: state)
                                        }
                                    }
                                    .onDisappear {
                                        canvasPointer = nil
                                        hoveredButton = nil
                                    }
                                    .focusable(state.acceptsLoadEscape)
                                    .focused($loadMenuFocused)
                                    .onChange(of: state.acceptsLoadEscape, initial: true) { _, active in
                                        loadMenuFocused = active
                                    }
                                    .onKeyPress(.escape) {
                                        guard state.acceptsLoadEscape else { return .ignored }
                                        send(state.isWaitingForLoadConfirmation ? .loadConfirmation(false) : .loadMenuEscape)
                                        return .handled
                                    }
                                    .gesture(SpatialTapGesture().onEnded { event in
                                        guard let point = PlayerViewport(geometry.size).canvasPoint(event.location) else { return }
                                        if state.isWaitingForLoadConfirmation {
                                            if let button = state.layers.last(where: {
                                                state.loadConfirmationButtons[$0.id] != nil && $0.containsInteractivePoint(point)
                                            }), let accept = state.loadConfirmationButtons[button.id] {
                                                playButtonAudio(state.buttonSounds[button.id]?[1])
                                                send(.loadConfirmation(accept))
                                            }
                                            return
                                        }
                                        if state.isSystemLoadFrame {
                                            if let button = state.layers.last(where: {
                                                state.loadMenuButtons.contains($0.id) && $0.containsInteractivePoint(point)
                                            }) {
                                                playButtonAudio(state.buttonSounds[button.id]?[1])
                                                send(.loadMenuButton(button.id, x: Int32(point.x), y: Int32(point.y)))
                                            }
                                            return
                                        }
                                        if state.dialogueWindowHidden {
                                            send(.canvasClick(x: Int32(point.x), y: Int32(point.y), titleButton: nil))
                                            return
                                        }
                                        if state.waitingForChoice {
                                            if let button = state.layers.last(where: {
                                                state.choiceButtons[$0.id] != nil && $0.containsInteractivePoint(point)
                                            }), let choice = state.choiceButtons[button.id] {
                                                playButtonAudio(state.buttonSounds[button.id]?[1])
                                                send(.choice(choice))
                                            }
                                            return
                                        }
                                        // Window controls own their hit area even while their script callbacks are unavailable.
                                        if let control = state.layers.last(where: { $0.isWindowControl && $0.containsInteractivePoint(point) }) {
                                            if control.id == state.windowViewButton {
                                                playButtonAudio(state.buttonSounds[control.id]?[1])
                                                send(.windowViewButton(control.id))
                                            } else if control.id == state.windowLoadButton {
                                                playButtonAudio(state.buttonSounds[control.id]?[1])
                                                send(.windowLoadButton(control.id))
                                            }
                                            return
                                        }
                                        let button = state.layers.last {
                                            state.titleButtons[$0.id] != nil && $0.containsInteractivePoint(point)
                                        }
                                        let index = button.flatMap { state.titleButtons[$0.id] }
                                        guard state.titleButtons.isEmpty || index != nil else { return }
                                        if let button { playButtonAudio(state.buttonSounds[button.id]?[1]) }
                                        send(.canvasClick(x: Int32(point.x), y: Int32(point.y), titleButton: index))
                                    })
                            }
                        }
                    }
                }
                if !state.unavailableLayers.isEmpty {
                    DisclosureGroup(state.unavailableLayerCount == 0 ? "图层诊断" : "图层诊断 · \(state.unavailableLayerCount) 个图层未绘制") {
                        ScrollView {
                            Text(state.unavailableLayers.joined(separator: "\n"))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 100)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                let unpositioned = state.dialogueWindowHidden ? [] : state.messageLayers.filter { $0.isVisible && $0.canvasBounds == nil }.map(\.text)
                if !unpositioned.isEmpty {
                    ScrollView {
                        Text(unpositioned.joined(separator: "\n"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 220)
                }
                if state.isWaitingForLoadConfirmation {
                    HStack {
                        Button("读取此存档") { send(.loadConfirmation(true)) }
                        Button("取消读取") { send(.loadConfirmation(false)) }
                    }
                    .disabled(work != nil)
                }
                if state.isSystemLoadFrame {
                    HStack {
                        if let cancel = state.layers.first(where: { state.loadCancelButton == $0.id }) {
                            Button("返回标题") {
                                playButtonAudio(state.buttonSounds[cancel.id]?[1])
                                send(.loadMenuButton(cancel.id, x: Int32(cancel.bounds.midX), y: Int32(cancel.bounds.midY)))
                            }
                            .disabled(work != nil)
                        }
                        if !state.loadPageIndices.isEmpty {
                            let pages = state.loadPageIndices.sorted { ($0.value, $0.key) < ($1.value, $1.key) }
                            Menu("读档页码") {
                                ForEach(pages, id: \.key) { page in
                                    if let button = state.layers.first(where: { $0.id == page.key }) {
                                        let selected = state.checkedLoadPageButtons.contains(page.key)
                                        Button {
                                            playButtonAudio(state.buttonSounds[button.id]?[1])
                                            send(.loadMenuButton(button.id, x: Int32(button.bounds.midX), y: Int32(button.bounds.midY)))
                                        } label: {
                                            let name = "第 \(Int64(page.value) + 1) 页"
                                            if selected { Label(name, systemImage: "checkmark") }
                                            else { Text(name) }
                                        }
                                        .accessibilityAddTraits(selected ? .isSelected : [])
                                    }
                                }
                            }
                            .disabled(work != nil)
                        }
                    }
                } else if let start = state.titleStartButton {
                    Button("开始游戏") {
                        playButtonAudio(state.buttonSounds[start]?[1])
                        send(.start)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(work != nil)
                } else if !state.choices.isEmpty {
                    HStack {
                        ForEach(state.choices, id: \.self) { choice in
                            Button(state.choiceText[choice] ?? "选项 \(choice + 1)") {
                                if let handle = state.choiceButtons.first(where: { $0.value == choice })?.key {
                                    playButtonAudio(state.buttonSounds[handle]?[1])
                                }
                                send(.choice(choice))
                            }
                            .keyboardShortcut(KeyEquivalent(Character(String(choice + 1))), modifiers: [])
                        }
                    }.disabled(work != nil)
                } else if !state.waitingForChoice && state.titleButtons.isEmpty &&
                            (result.phase == .waitingForEvent || state.waitingForClick) {
                    Button(state.dialogueWindowHidden ? "恢复对话窗口" : "继续") { send(.click) }
                        .keyboardShortcut(.space, modifiers: [])
                        .disabled(work != nil)
                }
                if !state.titleButtonLabels.isEmpty {
                    let buttons = state.titleButtons.sorted { $0.value < $1.value }.map(\.key)
                    Menu("标题菜单") {
                        ForEach(buttons, id: \.self) { handle in
                            if let label = state.titleButtonLabels[handle], let index = state.titleButtons[handle] {
                                Button(label) {
                                    let bounds = state.layers.first { $0.id == handle }?.bounds
                                    let x = Int32(clamping: Int((bounds?.midX ?? 0).rounded()))
                                    let y = Int32(clamping: Int((bounds?.midY ?? 0).rounded()))
                                    playButtonAudio(state.buttonSounds[handle]?[1])
                                    send(.canvasClick(x: x, y: y, titleButton: index))
                                }
                            }
                        }
                    }
                    .disabled(work != nil)
                }
                if let reason = result.stopReason { Text(Self.playbackMessage(reason)).foregroundStyle(.orange) }
                if let location = result.currentLocation {
                    Text("\(location.sourceFile) · 第 \(location.lineNumber) 行")
                        .font(.caption).textSelection(.enabled)
                }
            }
            if !saveImportIssues.isEmpty {
                DisclosureGroup("存档导入提示") {
                    ScrollView {
                        Text(saveImportIssues.joined(separator: "\n"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 100)
                }
                .font(.caption)
                .foregroundStyle(.orange)
            }
            if let issue {
                Text(issue).foregroundStyle(.orange).textSelection(.enabled)
                if let failedReplay {
                    Button("重试本次配置") {
                        openReplay(assets: failedReplay.assets, replayURL: failedReplay.replay,
                                   gameURL: failedReplay.game, ffmpeg: failedReplay.ffmpeg, saveURL: failedReplay.saveURL)
                    }
                    .disabled(work != nil)
                }
            }
        }
        .padding(36)
        .frame(minWidth: 640, minHeight: 400)
        .task {
            guard let launch, !launched else { return }
            launched = true
            do {
                let assets = try SafeDirectory(launch.assets)
                openReplay(assets: assets, replayURL: launch.replay, gameURL: launch.game, ffmpeg: launch.ffmpeg, saveURL: launch.saveURL)
            } catch {
                issue = String(describing: error)
                FileHandle.standardError.write(Data("player_error=\(String(describing: error))\n".utf8))
            }
        }
        .sheet(isPresented: $showingHistory, onDismiss: { history = [] }) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("对话记录").font(.title2)
                    Spacer()
                    Button("关闭") { showingHistory = false }.keyboardShortcut(.cancelAction)
                }
                if history.isEmpty {
                    ContentUnavailableView("暂无对话记录", systemImage: "text.bubble")
                } else {
                    List(Array(history.reversed().enumerated()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: 4) {
                            if !entry.speaker.isEmpty {
                                Text(entry.speaker).font(.headline)
                            }
                            Text(entry.text).textSelection(.enabled)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .padding(20)
            .frame(minWidth: 480, minHeight: 380)
        }
        .onDisappear { stopSession() }
        .onChange(of: masterVolume) { _, _ in applyMasterVolume() }
        .onChange(of: isMuted) { _, _ in applyMasterVolume() }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime).receive(on: DispatchQueue.main)) { notification in
            guard let item = notification.object as? AVPlayerItem else { return }
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            if item === video?.currentItem {
                failVideo(error?.localizedDescription ?? "影片播放未能完成")
            } else if item === cutinVideo?.currentItem {
                failCutin(error?.localizedDescription ?? "演出视频播放未能完成")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime).receive(on: DispatchQueue.main)) { notification in
            guard let item = notification.object as? AVPlayerItem,
                  item === video?.currentItem, let movie = state?.movie else { return }
            let seconds = item.duration.seconds
            guard seconds.isFinite, seconds > 0, seconds <= PlayerMovie.maximumDuration else {
                failVideo("影片时长无法确认")
                return
            }
            clearVideo()
            movie.remove()
            let duration = max(1, Int32(seconds * 1000))
            if launch != nil, let source = state?.movieRequest?.resource {
                FileHandle.standardError.write(Data("player_movie_finished=\(source.sourceSHA256) duration_ms=\(duration)\n".utf8))
            }
            if work == nil {
                send(.movieFinished(duration))
            } else {
                pendingMovieCompletion = duration
            }
        }
    }

    private func updateHoveredButton(_ point: CGPoint?, state: PlayerState) {
        let hovered = (state.dialogueWindowHidden ? nil : point).flatMap { location in
            state.layers.last {
                (!state.isSystemLoadFrame || (state.isWaitingForLoadConfirmation
                    ? state.loadConfirmationButtons[$0.id] != nil : state.loadMenuButtons.contains($0.id))) &&
                    ($0.hoverImage != nil || state.buttonSounds[$0.id] != nil) && $0.containsInteractivePoint(location)
            }?.id
        }
        if hovered != hoveredButton {
            hoveredButton = hovered
            if let hovered { playButtonAudio(state.buttonSounds[hovered]?[0]) }
        }
    }

    private func updatePointer(_ point: CGPoint?, state: PlayerState) {
        canvasPointer = point
        updateHoveredButton(point, state: state)
        guard state.canStartFromTitle else { return }
        let x = Int32(point?.x ?? 0)
        let y = Int32(point?.y ?? 0)
        // Match the title script's two thresholds, retaining the current state between them.
        guard x > 980 || x < 930 else { return }
        let onRight = x > 980
        guard titlePointerOnRight != onRight, work == nil else { return }
        titlePointerOnRight = onRight
        send(.titlePointer(x: x, y: y))
    }

    private func playButtonAudio(_ source: ScriptLocation?) {
        guard let source, let session else { return }
        buttonAudioTask?.cancel()
        buttonAudioTask = Task {
            do {
                let bytes = try await session.buttonAudio(source)
                try Task.checkCancellation()
                let player = try AVAudioPlayer(data: bytes)
                player.volume = masterGain
                let completion = PlayerAudioCompletion { identity, error in
                    guard let current = buttonAudioPlayer, ObjectIdentifier(current) == identity else { return }
                    current.stop()
                    buttonAudioPlayer = nil
                    buttonAudioCompletion = nil
                    if let error { issue = "按钮音效 · \(error)" }
                }
                player.delegate = completion
                guard player.play() else { throw ResourceError.rejected("player_button_audio_start_failed") }
                buttonAudioPlayer?.stop()
                buttonAudioPlayer = player
                buttonAudioCompletion = completion
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.session === session else { return }
                issue = "按钮音效 · \(error)"
            }
        }
    }

    private func send(_ input: PlayerSession.Input) {
        guard let session, !showingHistory else { return }
        if work != nil {
            if runningIdleTimer, choiceDuringTimer == nil, case .choice(let index) = input,
               state?.waitingForChoice == true,
               let handle = state?.choiceButtons.first(where: { $0.value == index })?.key {
                choiceDuringTimer = (handle, index)
            }
            return
        }
        switch input {
        case .loadMenuButton, .loadMenuEscape, .loadConfirmation:
            guard state?.isSystemLoadFrame == true else { return }
        default:
            guard state?.isSystemLoadFrame != true else { return }
        }
        idleVisuals?.cancel()
        if case .timerTick = input {
            runningIdleTimer = true
        } else {
            issue = nil
        }
        let id = UUID()
        workID = id
        work = Task {
            defer { finishWork(id) }
            do {
                try await driveWithSaveRecovery(session, input: input)
            } catch is CancellationError {
                if workID == id { stopSession() }
            } catch {
                guard workID == id else { return }
                failPlayback(String(describing: error))
            }
        }
    }

    private func driveWithSaveRecovery(_ session: PlayerSession, input: PlayerSession.Input) async throws {
        do {
            try await drive(session, input: input)
        } catch {
            try Task.checkCancellation()
            guard await session.recoverFailedSaveLoad() else { throw error }
            if launch?.checkLoadRecovery == true || launch?.checkExperimentalSaveAdoption == true {
                FileHandle.standardError.write(Data("player_load_recovery_cause=\(error)\n".utf8))
            }
            try Task.checkCancellation()
            try await drive(session)
            try Task.checkCancellation()
            let reason = Self.playbackMessage(String(describing: error))
            if state?.isTerminal == false {
                issue = "读取存档失败，已返回游戏。\n\(reason)"
            } else if issue == nil {
                issue = reason
            }
        }
    }

    private func finishWork(_ id: UUID) {
        guard workID == id else { return }
        work = nil
        workID = nil
        runningIdleTimer = false
        let queuedChoice = choiceDuringTimer
        choiceDuringTimer = nil
        guard state?.isTerminal != true else { return }
        if let queuedChoice, !showingHistory, state?.waitingForChoice == true,
           state?.choiceButtons[queuedChoice.handle] == queuedChoice.index {
            send(.choice(queuedChoice.index))
            return
        }
        if let duration = pendingMovieCompletion {
            pendingMovieCompletion = nil
            send(.movieFinished(duration))
        } else if let session, video == nil {
            idleVisuals?.cancel()
            idleVisuals = Task {
                let clock = ContinuousClock()
                var lastTick = clock.now
                var loggedFrames = 0
                var loggedSceneFrames = 0
                var loggedMotionFrames = 0
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(16)) }
                    catch { return }
                    let elapsed = min(lastTick.duration(to: clock.now), .milliseconds(Int64(Int32.max)))
                    let parts = elapsed.components
                    let ticks = Int32(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
                    lastTick = lastTick.advanced(by: .milliseconds(Int64(ticks)))
                    guard let values = await session.advanceIdleVisuals(ticks: ticks, cutinID: state?.cutin?.id),
                          !Task.isCancelled, self.session === session, work == nil else { return }
                    guard var next = state else { return }
                    next.layers.removeAll { layer in
                        if layer.id == PlayerLayer.savedCaptureID { return values.savedCaptureOpacity == nil }
                        if values.layers[layer.id] == nil {
                            if launch != nil {
                                FileHandle.standardError.write(Data("player_idle_layer_removed=\(layer.id)\n".utf8))
                            }
                            return true
                        }
                        return values.expiredTextEffects.contains(layer.id) ||
                            (layer.isWhiteFlash && values.whiteFlashes[layer.id] == nil)
                    }
                    for index in next.layers.indices {
                        if next.layers[index].id == PlayerLayer.savedCaptureID,
                           let opacity = values.savedCaptureOpacity {
                            next.layers[index].opacity = opacity
                            continue
                        }
                        guard let layer = values.layers[next.layers[index].id] else { continue }
                        if let frame = values.sceneFrames[layer.id], next.layers[index].image !== frame {
                            next.layers[index].image = frame
                            if launch != nil, loggedSceneFrames < 16 {
                                FileHandle.standardError.write(Data("player_idle_scene_frame=\(layer.id) ticks=\(layer.motionElapsedTicks ?? 0)\n".utf8))
                                loggedSceneFrames += 1
                            }
                        }
                        let motion = values.motions[layer.id]
                        let offset = motion?.offset ?? .zero
                        let previousFilter = next.layers[index].textureFilter
                        next.layers[index].textureFilter = layer.textureFilter ?? motion?.sampling
                        if launch != nil, loggedMotionFrames < 96,
                           next.layers[index].motionOffset != offset || previousFilter != next.layers[index].textureFilter,
                           let ticks = layer.motionElapsedTicks, let action = layer.selectedMember {
                            FileHandle.standardError.write(Data("player_idle_bound_motion=\(layer.id) action=\(action) ticks=\(ticks) x=\(offset.x) y=\(offset.y) sampling=\(next.layers[index].textureFilter ?? -1)\n".utf8))
                            loggedMotionFrames += 1
                        }
                        next.layers[index].motionOffset = offset
                        if let previous = next.layers[index].dialogueFrameTextures {
                            let textures = values.dialogueFrames[layer.id] ?? []
                            next.layers[index].dialogueFrameTextures = textures
                            if launch != nil, previous.count != textures.count {
                                FileHandle.standardError.write(Data(
                                    "player_idle_dialogue_frame=\(layer.id) ticks=\(layer.motionElapsedTicks ?? 0) textures=\(textures.count)\n".utf8))
                            }
                        }
                        next.layers[index].opacity = values.whiteFlashes[layer.id] ?? layer.opacity
                        if layer.priority == 1550, let animation = values.windowAnimation,
                           next.layers[index].isWindowControl {
                            next.layers[index].motionOffset.y += animation.y
                            next.layers[index].opacity = UInt8(Int(layer.opacity) * Int(animation.alpha) / 255)
                        }
                        next.layers[index].x = layer.x
                        next.layers[index].y = layer.y
                        next.layers[index].priority = layer.priority
                        if next.layers[index].isDialogBlack {
                            // Keep the procedural geometry while its draw key is inactive.
                            next.layers[index].opacity = values.dialogBlackAlphas[layer.id] ?? 0
                        } else if !next.layers[index].isWhiteFlash {
                            next.layers[index].scaleXPercent = layer.scaleXPercent
                            next.layers[index].scaleYPercent = layer.scaleYPercent
                        }
                    }
                    next.layers.sort { ($0.priority, $0.id) < ($1.priority, $1.id) }
                    // The idle frame still carries the previous message surfaces.
                    // Keep a removed backing layer hidden until a full snapshot replaces them.
                    var fullTextAlphas = values.fullTextAlphas
                    for id in next.fullTextAlphas.keys where values.layers[id] == nil {
                        fullTextAlphas[id] = 0
                    }
                    next.fullTextAlphas = fullTextAlphas
                    next.pendingOpacityImages = values.pendingOpacity
                    for detail in values.sceneIssues where !next.unavailableLayers.contains(detail) {
                        next.unavailableLayers.append(detail)
                        next.unimplementedAnimationCount += 1
                    }
                    next.cutin = values.cutin
                    state = next
                    updateHoveredButton(canvasPointer, state: next)
                    updateCutin(next)
                    if values.timerDue, !showingHistory {
                        send(.timerTick)
                        return
                    }
                    if launch?.advanceToOpacity == true, loggedFrames < 256 {
                        let translucent = next.layers.filter { (1..<255).contains($0.opacity) }.count
                        let transparent = next.layers.filter { $0.opacity == 0 }.count
                        FileHandle.standardError.write(Data("player_idle_opacity_ticks=\(ticks) translucent_layers=\(translucent) transparent_layers=\(transparent)\n".utf8))
                        loggedFrames += 1
                    }
                }
            }
        }
    }

    private func clearVideo() {
        videoStatus?.invalidate()
        videoStatus = nil
        video?.pause()
        video?.replaceCurrentItem(with: nil)
        video = nil
        videoPaused = false
    }

    private func clearCutin() {
        cutinWork?.cancel()
        cutinWork = nil
        stopCutinVideo()
        cutinMovie?.remove()
        cutinMovie = nil
        cutinFailure = nil
    }

    private func stopCutinVideo() {
        cutinStatus?.invalidate()
        cutinStatus = nil
        if launch != nil, let player = cutinVideo {
            let position = player.currentTime().seconds
            if position.isFinite {
                FileHandle.standardError.write(Data("player_cutin_stop_seconds=\(position)\n".utf8))
            }
        }
        cutinVideo?.pause()
        cutinVideo?.replaceCurrentItem(with: nil)
        cutinVideo = nil
        cutinPausedForLoad = false
        cutinObservedOpacity = nil
    }

    private func failCutin(_ reason: String) {
        clearCutin()
        cutinFailure = "演出视频载入失败 · \(reason)"
        if state?.cutin != nil { issue = cutinFailure }
        if launch != nil { FileHandle.standardError.write(Data("player_cutin_error=\(reason)\n".utf8)) }
    }

    private func pauseCutinForLoad(_ player: AVPlayer) {
        guard player.timeControlStatus != .paused else { return }
        player.pause()
        cutinPausedForLoad = true
    }

    private func updateCutin(_ next: PlayerState) {
        if next.isSystemLoadFrame {
            if let cutinVideo { pauseCutinForLoad(cutinVideo) }
            return
        }
        if let cutinFailure {
            if next.cutin != nil { issue = cutinFailure }
            return
        }
        if next.cutin == nil || next.movie != nil {
            stopCutinVideo()
        } else if cutinVideo == nil, let movie = cutinMovie {
            let item = AVPlayerItem(url: movie.url)
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            cutinVideo = player
            let identity = ObjectIdentifier(item)
            cutinStatus = item.observe(\.status, options: [.initial, .new]) { item, _ in
                guard item.status == .failed else { return }
                let reason = item.error?.localizedDescription ?? "影片无法载入"
                Task { @MainActor in
                    guard let current = cutinVideo?.currentItem, ObjectIdentifier(current) == identity else { return }
                    failCutin(reason)
                }
            }
            player.play()
            if launch != nil { FileHandle.standardError.write(Data("player_cutin_started=1\n".utf8)) }
        }
        if cutinPausedForLoad {
            cutinVideo?.play()
            cutinPausedForLoad = false
        }
        if launch != nil, cutinVideo != nil, let opacity = next.cutin?.opacity,
           opacity != cutinObservedOpacity {
            cutinObservedOpacity = opacity
            FileHandle.standardError.write(Data("player_cutin_opacity=\(opacity)\n".utf8))
        }
        guard cutinWork == nil, cutinMovie == nil,
              let source = next.cutinSource, let replay = currentReplay else {
            return
        }
        cutinWork = Task {
            do {
                let conversion = Task.detached {
                    try await PlayerMovie.prepare(resource: source.resource, assets: replay.assets,
                        ffmpeg: replay.resolvedDecoder, embeddedRange: source.range)
                }
                let movie = try await withTaskCancellationHandler {
                    try await conversion.value
                } onCancel: {
                    conversion.cancel()
                }
                guard !Task.isCancelled, let latest = state else {
                    movie.remove()
                    return
                }
                cutinMovie = movie
                if launch != nil {
                    let visible = latest.cutin == nil ? 0 : 1
                    FileHandle.standardError.write(Data("player_cutin_prepared visible=\(visible)\n".utf8))
                }
                updateCutin(latest)
            } catch {
                guard !Task.isCancelled else { return }
                failCutin(String(describing: error))
            }
        }
    }

    private func failVideo(_ reason: String) {
        failPlayback(reason, diagnostic: "movie_playback_failed")
    }

    nonisolated private static let playbackErrorMessages: [String: String] = [
        "player_media_source_changed": "媒体文件和资源清单不一致，请检查导入的资源副本。",
        "player_media_converter_launch_failed": "无法启动 ffmpeg，请检查选择的程序是否可执行。",
        "player_media_conversion_failed": "音轨转码失败。",
        "player_video_conversion_failed": "影片的硬件和软件编码均失败。",
        "player_media_conversion_timeout": "媒体转码超时。",
        "player_media_output_missing": "转码程序没有生成媒体文件。",
        "player_media_output_empty": "转码程序生成了空文件。",
        "player_media_output_limit": "转码文件达到大小上限。",
        "player_media_duration_invalid": "无法确认媒体时长。",
        "player_media_duration_limit": "媒体时长超过 10 分钟上限。",
        "player_resource_copy_not_in_replay": "试玩配置缺少脚本请求的资源记录。",
        "game_thread_image_capture_required": "此画面需要从主游戏画布生成快照。",
        "player_replay_file_read_failed": "无法读取试玩配置文件，请检查所选回放目录。",
        "player_replay_file_invalid": "试玩配置文件格式无效，请重新生成回放配置。",
        "player_catalog_identity_mismatch": "资源目录清单与试玩摘要不匹配。",
        "save_envelope_size": "存档文件大小超出支持范围。",
        "save_envelope_magic": "文件头无法识别为受支持的存档格式。",
        "save_envelope_length": "存档记录的长度与文件内容不一致。",
        "save_envelope_checksum": "存档校验失败，文件可能不完整或已损坏。",
        "saved_audio_restore_incomplete": "当前播放器无法恢复存档中的全部音频状态。",
        "saved_audio_prepare_failed": "无法准备存档中的音频。",
        "saved_initial_layer_unavailable": "无法绘制存档恢复后的初始画面。",
        "save_restore_slot_changed": "存档文件在打开菜单后发生了变化，请重新打开读档菜单。",
        "save_reader_line_buffer_differs": "存档中的脚本行与当前资源版本不一致。",
        "saved_return_frame_limit": "存档中的调用层数超过当前播放器支持的范围。",
        "saved_return_block_unavailable": "存档缺少当前播放器可识别的脚本返回记录。",
        "saved_return_not_command_boundary": "存档中的返回位置无法对应到当前脚本的指令边界。",
        "save_command_boundary_missing": "存档中的剧情位置无法对应到当前脚本的指令边界。",
        "system_task_bootstrap_waiting": "读档脚本未生成可操作的菜单画面。",
        "save_restore_execution_state_unsupported": "已读取存档，但当前版本尚不能恢复其中的剧情执行状态。",
        "saved_stream_seek_at_or_past_end": "存档记录的音频播放位置已超出当前音频范围。",
        "save_header_template_exe_identity": "变换存档需要已核验的第四作原版 EXE 才能校验。",
        "save_header_verification_mismatch": "存档头与已核验的第四作格式不匹配。",
        "player_configuration_identity_mismatch": "原版配置文件与试玩摘要不匹配。"
    ]

    private func failPlayback(_ reason: String, diagnostic: String? = nil) {
        let retry = currentReplay
        stopSession()
        failedReplay = retry
        issue = Self.playbackMessage(reason)
        if launch != nil {
            FileHandle.standardError.write(Data("player_error=\(diagnostic ?? reason)\n".utf8))
        }
    }

    nonisolated fileprivate static func playbackMessage(_ reason: String) -> String {
        let code = reason.split(separator: ":", maxSplits: 1).first.map(String.init) ?? reason
        guard let explanation = playbackErrorMessages[code] else { return reason }
        return "\(explanation)\n\(reason)"
    }

    private var masterGain: Float { isMuted ? 0 : Float(min(1, max(0, masterVolume))) }

    private func applyMasterVolume() {
        let master = masterGain
        if let buttonAudioPlayer, buttonAudioPlayer.volume != master {
            buttonAudioPlayer.volume = master
        }
        if let video {
            let volume = normalizedVolume(state?.movieRequest?.volume ?? 256) * master
            if video.volume != volume { video.volume = volume }
        }
        for (channel, player) in audio {
            let volume = (audioGains[channel] ?? 1) * master
            if player.volume != volume { player.volume = volume }
        }
    }

    private func normalizedVolume(_ value: Int32) -> Float {
        Float(min(256, max(0, value))) / 256
    }

    private func normalizedPan(_ value: Int32) -> Float {
        // The native stream setter at 0x5a10be clamps to ±256.
        Float(min(256, max(-256, value))) / 256
    }

    private func openHistory() {
        guard let session, work == nil, video == nil, !showingHistory else { return }
        Task {
            let entries = await session.dialogueHistory()
            guard self.session === session, work == nil, video == nil, !showingHistory else { return }
            history = entries
            showingHistory = true
        }
    }

    private func stopSession() {
        idleVisuals?.cancel()
        idleVisuals = nil
        currentReplay = nil
        failedReplay = nil
        saveImportIssues = []
        showingHistory = false
        history = []
        workID = nil
        runningIdleTimer = false
        choiceDuringTimer = nil
        pendingMovieCompletion = nil
        work?.cancel()
        work = nil
        clearVideo()
        clearCutin()
        stopAudio()
        state?.movie?.remove()
        state = nil
        displayedPlaybackIdentity = nil
        session = nil
    }

    private func stopAudio() {
        buttonAudioTask?.cancel()
        buttonAudioTask = nil
        buttonAudioPlayer?.stop()
        buttonAudioPlayer = nil
        buttonAudioCompletion = nil
        hoveredButton = nil
        for player in audio.values { player.stop() }
        audio.removeAll()
        audioSources.removeAll()
        audioPlaybackSteps.removeAll()
        audioCompletions.removeAll()
        audioGains.removeAll()
        for task in soundFades.values { task.cancel() }
        soundFades.removeAll()
    }

    private func verifySaveAdoptionPlayback() throws {
        guard let restored = state, !restored.isSystemLoadFrame, !restored.canStartFromTitle,
              !restored.isTerminal, restored.status.steps > 0, issue == nil else {
            throw ResourceError.rejected("player_experimental_save_adoption_probe_failed")
        }
        let positions = try sampledStreamPositions(for: restored.activeSoundChannels)
        FileHandle.standardError.write(Data("player_save_stream_samples=\(positions.count)\n".utf8))
        FileHandle.standardError.write(Data("player_experimental_save_playback phase=\(restored.status.phase) steps=\(restored.status.steps) layers=\(restored.layers.count)\n".utf8))
    }

    private func sampledStreamPositions(for handles: Set<UInt64>) throws -> [Int32: Int32] {
        var positions: [Int32: Int32] = [:]
        for handle in handles {
            guard let channel = ScriptMachine.streamSaveChannelIndex(handle) else { continue }
            guard let player = audio[handle], audioSources[handle] != nil else {
                throw ResourceError.rejected("player_stream_sample_channel_unavailable")
            }
            positions[channel] = try sampledStreamPosition(player).milliseconds
        }
        return positions
    }

    private func sampledStreamPosition(_ player: AVAudioPlayer) throws -> (seconds: Double, milliseconds: Int32) {
        let position = player.currentTime
        guard player.isPlaying, position >= 0, position < player.duration,
              let milliseconds = Int32(exactly: (position * 1000).rounded(.down)) else {
            throw ResourceError.rejected("player_stream_sample_outside_profile")
        }
        return (position, milliseconds)
    }

    private func drive(_ session: PlayerSession, input: PlayerSession.Input? = nil) async throws {
        var pending = input
        var beforeDialogueLoad: PlayerState?
        var visibleCutinWaits = 0
        var readyCutinWaits = 0
        var selectableCutinWaits = 0
        var dialogueLoadLoopingAudio: [UInt64: AVAudioPlayer] = [:]
        var checkedAudioResume = false
        var reopeningLoadMenu = false
        var adoptedMovieClickStep: Int?
        while true {
            var next = try await session.run(input: pending, presentTimedFrame: presentTimedFrame)
            if Task.isCancelled {
                next.movie?.remove()
                throw CancellationError()
            }
            if next.isSystemLoadFrame {
                show(next)
                return
            }
            synchronizePlaybackIdentity(next)
            while let source = next.soundSource, let channel = next.soundChannel {
                let current = audio[channel]
                let reuse = next.soundPreservesPosition && current?.isPlaying == true &&
                    audioSources[channel] == source
                let prepared = await session.takePreparedSaveAudio(channel: channel, source: source,
                                                                   identity: next.playbackIdentity)
                if Task.isCancelled {
                    prepared?.player.stop()
                    throw CancellationError()
                }
                let player: AVAudioPlayer
                if let prepared {
                    player = prepared.player
                } else if reuse, let current {
                    player = current
                } else {
                    let sound = try await session.convertedAudio(source)
                    try Task.checkCancellation()
                    player = try AVAudioPlayer(data: sound)
                }
                applySoundState(next, excludingSeekFor: channel)
                let previousTime = player.currentTime
                let gain: Float
                if reuse {
                    gain = audioGains[channel] ?? 1
                } else {
                    try PlayerMovie.validateDuration(player.duration)
                    player.pan = normalizedPan(next.immediateSoundPans[channel] ?? 0)
                    player.numberOfLoops = Int(next.soundRepeatCount)
                    gain = normalizedVolume(next.soundInitialVolume ?? next.immediateSoundVolumes[channel] ?? 256)
                    player.volume = gain * masterGain
                }
                if prepared == nil, let position = next.soundSeeks[channel] { seek(player, to: position) }
                let playbackStartStep = next.status.steps
                let playbackIdentity = next.playbackIdentity
                let completion = PlayerAudioCompletion { identity, error in
                    guard let current = audio[channel], ObjectIdentifier(current) == identity,
                          audioPlaybackSteps[channel] == playbackStartStep else { return }
                    removeAudio(channel: channel)
                    if let error { issue = "音频播放 · \(error)" }
                    Task { await session.soundCompleted(channel: channel, playbackStartStep: playbackStartStep, identity: playbackIdentity) }
                }
                player.delegate = completion
                guard prepared != nil || reuse || player.play() else { throw ResourceError.rejected("player_audio_start_failed") }
                if launch?.checkExperimentalSaveAdoption == true, let position = next.soundSeeks[channel] {
                    guard let sampled = try? sampledStreamPosition(player),
                          let savedChannel = ScriptMachine.streamSaveChannelIndex(channel),
                          abs(Int64(sampled.milliseconds) - Int64(position)) <= 100 else {
                        if !reuse { player.stop() }
                        throw ResourceError.rejected("player_save_stream_position_probe_failed")
                    }
                    FileHandle.standardError.write(Data("player_save_stream_started seek_ms=\(position) actual_seconds=\(sampled.seconds) sampled_ms=\(sampled.milliseconds) save_channel=\(savedChannel) playing=true initial_gain=\(gain) target=\(next.soundVolumeChanges[channel]?.target ?? -1) fade_ms=\(next.soundVolumeChanges[channel]?.duration ?? 0) pan=\(player.pan)\n".utf8))
                }
                if launch?.checkExperimentalSaveAdoption == true, next.status.steps == 0,
                   next.soundSeeks[channel] == nil {
                    FileHandle.standardError.write(Data("player_save_direct_started loops=\(player.numberOfLoops) playing=\(player.isPlaying) gain=\(gain)\n".utf8))
                }
                if !reuse {
                    cancelSoundFades(channel: channel)
                    current?.stop()
                }
                audio[channel] = player
                audioSources[channel] = source
                audioPlaybackSteps[channel] = playbackStartStep
                audioCompletions[channel] = completion
                audioGains[channel] = gain
                if launch?.replayRoute == true, !reuse {
                    FileHandle.standardError.write(Data(
                        "player_route_audio_started channel=\(channel) sha256=\(source.rangeSHA256) loops=\(player.numberOfLoops) steps=\(playbackStartStep) preserve_requested=\(next.soundPreservesPosition)\n".utf8))
                }
                if let change = next.soundVolumeChanges[channel] { applySoundChange(change, channel: channel, control: .volume) }
                if let change = next.soundPanChanges[channel] { applySoundChange(change, channel: channel, control: .pan) }
                if launch?.checkAudioResume == true, reuse, previousTime > 0.02,
                   next.soundSeeks[channel] == nil, player.currentTime >= previousTime {
                    checkedAudioResume = true
                    FileHandle.standardError.write(Data("player_audio_resume_verified=1 steps=\(next.status.steps)\n".utf8))
                }
                if prepared != nil, !player.isPlaying {
                    // A short sound may finish while still muted, before its delegate is attached.
                    removeAudio(channel: channel)
                    await session.soundCompleted(channel: channel, playbackStartStep: playbackStartStep,
                                                 identity: playbackIdentity)
                }
                next = try await session.run(input: .soundStarted, presentTimedFrame: presentTimedFrame)
                if Task.isCancelled {
                    next.movie?.remove()
                    throw CancellationError()
                }
            }
            applySoundState(next)
            show(next)
            if let before = adoptedMovieClickStep {
                guard next.status.steps > before, !next.isTerminal else {
                    throw ResourceError.rejected("player_experimental_save_movie_click_failed")
                }
                FileHandle.standardError.write(Data("player_experimental_save_movie_click=1 before=\(before) after=\(next.status.steps) phase=\(next.status.phase) layers=\(next.layers.count)\n".utf8))
                return
            }
            if launch?.checkExperimentalSaveAdoption == true, startedFromLaunch,
               case .movieFinished = pending, !next.waitingForChoice,
               next.waitingForClick || next.status.phase == .waitingForEvent {
                adoptedMovieClickStep = next.status.steps
                pending = .click
                continue
            }
            if let task = next.systemTaskRequest {
                if launch != nil {
                    FileHandle.standardError.write(Data("player_system_task_requested=\(task.entryLabel) line=\(task.source.lineNumber)\n".utf8))
                }
                do {
                    var status = try await session.startSystemLoadTask()
                    if let priority = status.capturePriority {
                        try Task.checkCancellation()
                        let canvasBounds = CGRect(x: 0, y: 0, width: PlayerViewport.width, height: PlayerViewport.height)
                        guard next.movie == nil else {
                            throw ResourceError.rejected("game_thread_video_capture_unsupported")
                        }
                        var capturedState = next
                        if let cutin = next.cutin, cutin.priority <= priority, cutin.opacity > 0,
                           cutin.bounds.intersects(canvasBounds) {
                            guard let player = cutinVideo, let item = player.currentItem, item.status == .readyToPlay,
                                  player.currentTime().seconds.isFinite else {
                                throw ResourceError.rejected("game_thread_cutin_frame_unavailable")
                            }
                            pauseCutinForLoad(player)
                            let requested = player.currentTime()
                            let (frame, actual) = try await PlayerMovie.captureFrame(in: item.asset, at: requested)
                            guard cutinVideo === player, player.currentItem === item else {
                                throw ResourceError.rejected("game_thread_cutin_frame_source_changed")
                            }
                            guard frame.width == Int(cutin.bounds.width), frame.height == Int(cutin.bounds.height) else {
                                throw ResourceError.rejected("game_thread_cutin_frame_size_mismatch")
                            }
                            capturedState.layers.append(PlayerLayer(id: cutin.id, image: frame, hoverImage: nil,
                                x: Int32(cutin.bounds.minX), y: Int32(cutin.bounds.minY), priority: cutin.priority,
                                opacity: cutin.opacity, scaleXPercent: 100, scaleYPercent: 100,
                                alignmentXPercent: 0, alignmentYPercent: 0, textureFilter: nil,
                                usesVolumeButtonOffsets: false, isWindowControl: false))
                            capturedState.layers.sort { ($0.priority, $0.id) < ($1.priority, $1.id) }
                            if launch?.checkCutinLoad == true {
                                FileHandle.standardError.write(Data("player_cutin_capture_frame=\(actual.seconds) requested=\(requested.seconds)\n".utf8))
                            }
                        }
                        let data = try captureScenePNG(capturedState, through: priority)
                        if launch?.checkDialogueSaveAdoption == true, let slot = launch?.checkLoadConfirmationSlot {
                            let thumbnail = try encodeCaptureThumbnail(data, width: 160, height: 90)
                            let rewritten = try await session.probeSaveThumbnailReplacement(slot: slot, jpeg: thumbnail)
                            guard let decoded = try ResourceImage.decodeSaveThumbnail(rewritten)?.image else {
                                throw ResourceError.rejected("game_thread_thumbnail_encode_failed")
                            }
                            guard decoded.width == 160, decoded.height == 90 else {
                                throw ResourceError.rejected("game_thread_thumbnail_size_mismatch")
                            }
                            FileHandle.standardError.write(Data("player_capture_thumbnail=160x90 jpeg_bytes=\(thumbnail.count) state_preserved=true\n".utf8))
                        }
                        status = try await session.supplySystemCapture(data)
                        if launch != nil {
                            let frameTextures = capturedState.layers.lazy
                                .filter { $0.priority <= priority && $0.opacity > 0 }
                                .reduce(0) { $0 + ($1.dialogueFrameTextures?.count ?? 0) }
                            FileHandle.standardError.write(Data(
                                "player_system_capture_supplied=1 priority=\(priority) dialogue_frame_textures=\(frameTextures)\n".utf8))
                        }
                    }
                    status = try await session.runSystemLoadWaits(status, presentTimedFrame: presentTimedFrame)
                    try Task.checkCancellation()
                    let reason = status.reason ?? "system_task_bootstrap_waiting"
                    if let frame = await session.systemLoadFrame() {
                        try Task.checkCancellation()
                        show(frame)
                        issue = nil
                        if let before = beforeDialogueLoad {
                            guard launch?.checkDialogueLoadStartupFailure != true else {
                                throw ResourceError.rejected("player_dialogue_load_probe_expected_startup_failure")
                            }
                            let suspendedCutin = cutinVideo
                            let suspendedTime = suspendedCutin?.currentTime()
                            let restored: PlayerState
                            if let slot = launch?.checkLoadConfirmationSlot {
                                guard let handle = try await session.loadSlotButton(named: slot),
                                      let layer = frame.layers.first(where: { $0.id == handle }) else {
                                    throw ResourceError.rejected("load_confirmation_probe_slot_unavailable")
                                }
                                let dialog = try await session.run(input: .loadMenuButton(handle,
                                    x: Int32(layer.bounds.midX), y: Int32(layer.bounds.midY)), presentTimedFrame: presentTimedFrame)
                                show(dialog)
                                guard dialog.isWaitingForLoadConfirmation else {
                                    throw ResourceError.rejected("load_confirmation_probe_dialog_unavailable")
                                }
                                try await driveWithSaveRecovery(session, input: .loadConfirmation(true))
                                if launch?.checkDialogueSaveAdoption == true, launch?.expectedLoadRecoveryCause == nil {
                                    try verifySaveAdoptionPlayback()
                                    return
                                }
                                let expected = launch?.expectedLoadRecoveryCause ?? "save_restore_execution_state_unsupported"
                                guard let recovered = state,
                                      issue?.components(separatedBy: "\n").last == expected else {
                                    throw ResourceError.rejected("load_recovery_probe_unexpected_failure: \(issue?.components(separatedBy: "\n").last ?? "missing_cause")")
                                }
                                restored = recovered
                            } else {
                                restored = try await session.run(input: .loadMenuEscape, presentTimedFrame: presentTimedFrame)
                                show(restored)
                            }
                            guard frame.isSystemLoadFrame, !frame.loadMenuButtons.isEmpty,
                                  !restored.isSystemLoadFrame, restored.status.phase == .waitingForEvent,
                                  restored.playbackIdentity == before.playbackIdentity,
                                  restored.status.steps == before.status.steps, restored.messages == before.messages else {
                                throw ResourceError.rejected("player_dialogue_load_probe_failed")
                            }
                            if launch?.checkCutinLoad == true {
                                guard let suspendedCutin, let suspendedTime, cutinVideo === suspendedCutin,
                                      abs(CMTimeSubtract(suspendedCutin.currentTime(), suspendedTime).seconds) <= 0.1 else {
                                    throw ResourceError.rejected("player_cutin_load_probe_position_lost")
                                }
                            }
                            guard dialogueLoadLoopingAudio.allSatisfy({ audio[$0.key] === $0.value }) else {
                                throw ResourceError.rejected("player_dialogue_load_probe_audio_replaced")
                            }
                            let continued = try await session.run(input: .click, presentTimedFrame: presentTimedFrame)
                            show(continued)
                            guard continued.status.steps > restored.status.steps, !continued.isTerminal,
                                  !continued.isSystemLoadFrame else {
                                throw ResourceError.rejected("player_dialogue_load_probe_continuation_failed")
                            }
                            FileHandle.standardError.write(Data("player_dialogue_load_restored=1 steps=\(restored.status.steps) continued_steps=\(continued.status.steps) preserved_loops=\(dialogueLoadLoopingAudio.count)\n".utf8))
                            return
                        } else if reopeningLoadMenu {
                            guard frame.isSystemLoadFrame, !frame.loadMenuButtons.isEmpty else {
                                throw ResourceError.rejected("load_menu_reopen_buttons_unavailable")
                            }
                            FileHandle.standardError.write(Data("player_load_reopened steps=\(frame.status.steps) buttons=\(frame.loadMenuButtons.count)\n".utf8))
                        } else if let slot = launch?.checkLoadConfirmationSlot {
                            guard let handle = try await session.loadSlotButton(named: slot),
                                  let layer = frame.layers.first(where: { $0.id == handle }) else {
                                throw ResourceError.rejected("load_confirmation_probe_slot_unavailable")
                            }
                            let dialog = try await session.run(input: .loadMenuButton(handle,
                                x: Int32(layer.bounds.midX), y: Int32(layer.bounds.midY)), presentTimedFrame: presentTimedFrame)
                            try Task.checkCancellation()
                            show(dialog)
                            guard dialog.isWaitingForLoadConfirmation,
                                  Set(dialog.loadConfirmationButtons.values) == [true, false] else {
                                throw ResourceError.rejected("load_confirmation_probe_dialog_unavailable")
                            }
                            if launch?.checkExperimentalSaveAdoption == true {
                                for id in dialog.loadConfirmationButtons.keys {
                                    guard let button = dialog.layers.first(where: { $0.id == id }),
                                          button.hoverImage != nil else {
                                        throw ResourceError.rejected("load_confirmation_probe_hover_image_unavailable")
                                    }
                                    updateHoveredButton(CGPoint(x: button.bounds.midX, y: button.bounds.midY), state: dialog)
                                    guard hoveredButton == id else {
                                        throw ResourceError.rejected("load_confirmation_probe_hover_hit_failed")
                                    }
                                }
                                updateHoveredButton(nil, state: dialog)
                                try await driveWithSaveRecovery(session, input: .loadConfirmation(true))
                                try verifySaveAdoptionPlayback()
                                return
                            }
                            if let cause = launch?.expectedLoadRecoveryCause {
                                try await driveWithSaveRecovery(session, input: .loadConfirmation(true))
                                guard state?.canStartFromTitle == true, state?.isSystemLoadFrame == false else {
                                    throw ResourceError.rejected("load_recovery_probe_title_not_restored")
                                }
                                guard issue?.components(separatedBy: "\n").last == cause else {
                                    throw ResourceError.rejected("load_recovery_probe_unexpected_failure: \(issue?.components(separatedBy: "\n").last ?? "missing_cause")")
                                }
                                FileHandle.standardError.write(Data("player_load_recovery_verified=1 cause=\(cause)\n".utf8))
                                return
                            }
                            let result = try await session.run(input: .loadConfirmation(false), presentTimedFrame: presentTimedFrame)
                            try Task.checkCancellation()
                            show(result)
                            guard result.isSystemLoadFrame, !result.isWaitingForLoadConfirmation,
                                  let reopenedHandle = try await session.loadSlotButton(named: slot),
                                  result.loadMenuButtons.contains(reopenedHandle),
                                  let reopenedLayer = result.layers.first(where: { $0.id == reopenedHandle }) else {
                                throw ResourceError.rejected("load_confirmation_probe_list_not_restored")
                            }
                            let reopened = try await session.run(input: .loadMenuButton(reopenedHandle,
                                x: Int32(reopenedLayer.bounds.midX), y: Int32(reopenedLayer.bounds.midY)),
                                presentTimedFrame: presentTimedFrame)
                            guard reopened.isWaitingForLoadConfirmation else {
                                throw ResourceError.rejected("load_confirmation_probe_slot_not_reopened")
                            }
                            let returned = try await session.run(input: .loadConfirmation(false),
                                presentTimedFrame: presentTimedFrame)
                            try Task.checkCancellation()
                            guard returned.isSystemLoadFrame, !returned.isWaitingForLoadConfirmation else {
                                throw ResourceError.rejected("load_confirmation_probe_list_not_restored")
                            }
                            show(returned)
                            FileHandle.standardError.write(Data("player_load_confirmation_cancelled=1\n".utf8))
                        } else if let launch, launch.checkLoadPage || launch.checkLoadCancel {
                            guard let button = frame.layers.first(where: {
                                frame.loadMenuButtons.contains($0.id) &&
                                    (launch.checkLoadCancel ? frame.loadCancelButton == $0.id : frame.loadPageIndices[$0.id] == 1)
                            }) else {
                                throw ResourceError.rejected("load_menu_probe_button_unavailable")
                            }
                            if launch.checkLoadCancel, !launch.checkLoadEscape, button.hoverImage == nil {
                                throw ResourceError.rejected("load_menu_cancel_hover_raster_missing")
                            }
                            let point = CGPoint(x: button.bounds.midX, y: button.bounds.midY)
                            let input: PlayerSession.Input = launch.checkLoadEscape ? .loadMenuEscape :
                                .loadMenuButton(button.id, x: Int32(point.x), y: Int32(point.y))
                            let result = try await session.run(input: input, presentTimedFrame: presentTimedFrame)
                            try Task.checkCancellation()
                            if launch.checkLoadPage {
                                guard frame.checkedLoadPageButtons.count == 1,
                                      !frame.checkedLoadPageButtons.contains(button.id),
                                      result.checkedLoadPageButtons == [button.id],
                                      button.hoverImage != nil,
                                      let selected = result.layers.first(where: { $0.id == button.id }),
                                      selected.hoverImage == nil else {
                                    throw ResourceError.rejected("load_page_probe_checked_visual_missing")
                                }
                                FileHandle.standardError.write(Data("player_load_page_checked_visual=1\n".utf8))
                            }
                            show(result)
                            let probe = launch.checkLoadEscape ? "escape" : (launch.checkLoadCancel ? "cancel" : "page")
                            FileHandle.standardError.write(Data("player_load_\(probe)_probe title=\(result.canStartFromTitle) steps=\(result.status.steps) phase=\(result.status.phase)\n".utf8))
                            if launch.checkLoadCancel {
                                guard !result.isSystemLoadFrame, result.canStartFromTitle,
                                      let handle = result.titleButtonLabels.first(where: { $0.value == "读取存档" })?.key,
                                      let index = result.titleButtons[handle],
                                      let layer = result.layers.first(where: { $0.id == handle }) else {
                                    throw ResourceError.rejected("load_menu_reopen_title_unavailable")
                                }
                                reopeningLoadMenu = true
                                pending = .canvasClick(x: Int32(layer.bounds.midX), y: Int32(layer.bounds.midY), titleButton: index)
                                continue
                            }
                        }
                        if launch != nil {
                            FileHandle.standardError.write(Data("player_system_task_frame layers=\(frame.layers.count) messages=\(frame.messageLayers.count) save_thumbnails=\(frame.visibleSaveThumbnails)\n".utf8))
                        }
                    } else {
                        throw ResourceError.rejected(reason)
                    }
                    if launch != nil {
                        FileHandle.standardError.write(Data("player_system_task_bootstrap steps=\(status.steps) reason=\(reason) source=\(status.location?.sourceFile ?? "-") line=\(status.location?.lineNumber ?? 0) offset=\(status.location?.byteOffset ?? 0)\n".utf8))
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let recovered = await session.recoverFailedSaveLoad()
                    let reason = Self.playbackMessage(String(describing: error))
                    if recovered {
                        try Task.checkCancellation()
                        let restored = try await session.run(presentTimedFrame: presentTimedFrame)
                        applySoundState(restored)
                        show(restored)
                        issue = restored.isTerminal ? reason : "无法打开读档菜单，已返回游戏。\n\(reason)"
                        if launch != nil {
                            FileHandle.standardError.write(Data("player_load_startup_recovered phase=\(restored.status.phase) steps=\(restored.status.steps) cause=\(error)\n".utf8))
                        }
                        if launch?.checkDialogueLoadStartupFailure == true, let before = beforeDialogueLoad {
                            guard String(describing: error) == "module_not_in_catalog",
                                  restored.status.phase == .waitingForEvent,
                                  restored.status.steps == before.status.steps,
                                  restored.messages == before.messages,
                                  issue?.hasPrefix("无法打开读档菜单，已返回游戏。") == true,
                                  issue?.components(separatedBy: "\n").last == "module_not_in_catalog" else {
                                throw ResourceError.rejected("player_dialogue_load_startup_recovery_probe_failed")
                            }
                            let continued = try await session.run(input: .click, presentTimedFrame: presentTimedFrame)
                            show(continued)
                            guard continued.status.steps > restored.status.steps, !continued.isTerminal else {
                                throw ResourceError.rejected("player_dialogue_load_probe_continuation_failed")
                            }
                            FileHandle.standardError.write(Data("player_dialogue_load_startup_recovered=1 continued_steps=\(continued.status.steps)\n".utf8))
                        }
                    } else {
                        issue = reason
                    }
                    if launch?.checkLoadConfirmationSlot != nil {
                        FileHandle.standardError.write(Data("player_load_confirmation_probe_error=\(error)\n".utf8))
                    }
                    if let launch, launch.checkLoadPage || launch.checkLoadCancel {
                        let probe = launch.checkLoadEscape ? "escape" : (launch.checkLoadCancel ? "cancel" : "page")
                        FileHandle.standardError.write(Data("player_load_\(probe)_probe_error=\(error)\n".utf8))
                    }
                }
                return
            }
            if launch?.checkChoiceTimer == true, choiceCursor == 0, next.waitingForChoice, !next.choices.isEmpty {
                var updated = next
                var deadlines: [Int32] = []
                for _ in 0..<3 {
                    deadlines.append(try await session.reachChoiceTimerDeadline())
                    let previousSteps = updated.status.steps
                    updated = try await session.run(input: .timerTick, presentTimedFrame: presentTimedFrame)
                    show(updated)
                    guard updated.waitingForChoice, updated.choiceButtons == next.choiceButtons,
                          updated.status.steps > previousSteps else {
                        throw ResourceError.rejected("player_choice_timer_probe_failed")
                    }
                }
                guard let choice = session.replayChoices.first, updated.choices.contains(choice) else {
                    throw ResourceError.rejected("player_replay_choice_unavailable")
                }
                FileHandle.standardError.write(Data("player_choice_timer_verified=1 deadlines=\(deadlines) choices=\(updated.choices.count)\n".utf8))
                choiceCursor = 1
                pending = .choice(choice)
                continue
            }
            if checkedAudioResume { return }
            if let launch, case .choice(let selectedIndex) = pending, launch.replayRoute || launch.checkChoiceCount > 0 {
                guard next.status.phase != .stopped, launch.replayRoute || !next.waitingForChoice else {
                    throw ResourceError.rejected("player_choice_probe_failed")
                }
                let marker = choiceCursor == 1 ? "player_first_choice_resolved=1" : "player_choices_resolved=\(choiceCursor)"
                FileHandle.standardError.write(Data("\(marker) steps=\(next.status.steps) selected_index=\(selectedIndex)\n".utf8))
                if launch.checkChoiceCount > 0, choiceCursor >= launch.checkChoiceCount { return }
            }
            if launch?.replayRoute == true, startedFromLaunch, next.canStartFromTitle {
                guard !reportedRouteReturn else { return }
                reportedRouteReturn = true
                FileHandle.standardError.write(Data("player_route_returned_to_title choices=\(choiceCursor) steps=\(next.status.steps)\n".utf8))
                return
            }
            if launch?.checkCutinLoad == true, next.status.phase == .waitingForEvent,
               (next.cutin?.opacity ?? 0) > 0 {
                visibleCutinWaits += 1
                if cutinVideo?.currentItem?.status == .readyToPlay { readyCutinWaits += 1 }
                if let handle = next.windowLoadButton,
                   next.layers.contains(where: { $0.id == handle && $0.opacity > 0 }) {
                    selectableCutinWaits += 1
                }
            }
            if launch?.checkDialogueLoad == true, !startedDialogueLoadProbe, !next.messages.isEmpty,
               launch?.checkCutinLoad != true || ((next.cutin?.opacity ?? 0) > 0 && cutinVideo?.currentItem?.status == .readyToPlay),
               let handle = next.windowLoadButton,
               next.layers.contains(where: { $0.id == handle && $0.opacity > 0 }) {
                startedDialogueLoadProbe = true
                beforeDialogueLoad = next
                dialogueLoadLoopingAudio = audio.filter { $0.value.numberOfLoops < 0 && $0.value.isPlaying }
                pending = .windowLoadButton(handle)
                continue
            }
            if launch?.checkWindowView == true, !next.messages.isEmpty,
               let handle = next.windowViewButton,
               next.layers.contains(where: { $0.id == handle && $0.opacity > 0 }) {
                let hidden = try await session.run(input: .windowViewButton(handle), presentTimedFrame: presentTimedFrame)
                show(hidden)
                let restored = try await session.run(input: .click, presentTimedFrame: presentTimedFrame)
                show(restored)
                guard hidden.dialogueWindowHidden, !restored.dialogueWindowHidden,
                      restored.status.steps == hidden.status.steps,
                      restored.messages == next.messages else {
                    throw ResourceError.rejected("player_window_view_probe_failed")
                }
                FileHandle.standardError.write(Data("player_window_view_restored=1\n".utf8))
                return
            }
            if launch?.advanceToDialogue == true, launch?.checkCutinLoad != true, !next.messages.isEmpty {
                let count = await session.dialogueHistory().count
                try Task.checkCancellation()
                FileHandle.standardError.write(Data("player_dialogue_history_count=\(count)\n".utf8))
            }
            if let launch, (launch.startAtTitle || launch.openLoadMenu), next.canStartFromTitle,
               !startedFromLaunch, titlePointerOnRight != true {
                titlePointerOnRight = true
                pending = .titlePointer(x: 1100, y: 360)
            } else if launch?.openLoadMenu == true, next.canStartFromTitle, !startedFromLaunch {
                guard let handle = next.titleButtonLabels.first(where: { $0.value == "读取存档" })?.key,
                      let index = next.titleButtons[handle] else {
                    throw ResourceError.rejected("player_title_load_button_unavailable")
                }
                startedFromLaunch = true
                let bounds = next.layers.first { $0.id == handle }?.bounds
                pending = .canvasClick(x: Int32(clamping: Int((bounds?.midX ?? 0).rounded())),
                                       y: Int32(clamping: Int((bounds?.midY ?? 0).rounded())), titleButton: index)
                FileHandle.standardError.write(Data("player_title_load_dispatched=1\n".utf8))
            } else if launch?.startAtTitle == true, next.canStartFromTitle, !startedFromLaunch {
                startedFromLaunch = true
                pending = .start
            } else if !next.choices.isEmpty,
                      launch?.replayRoute == true || (launch?.checkChoiceCount ?? 0) > 0 ||
                      (launch?.advanceToOpacity == true && !observedOpacity) || launch?.checkAudioResume == true {
                guard choiceCursor < session.replayChoices.count else {
                    if launch?.replayRoute == true {
                        throw ResourceError.rejected("player_replay_choices_exhausted: \(choiceCursor) choices, step \(next.status.steps)")
                    }
                    return
                }
                let choice = session.replayChoices[choiceCursor]
                guard next.choices.contains(choice) else {
                    throw ResourceError.rejected("player_replay_choice_unavailable")
                }
                choiceCursor += 1
                pending = .choice(choice)
            } else if startedFromLaunch, next.status.phase == .waitingForEvent,
                      !next.canStartFromTitle, !next.waitingForChoice,
                      (launch?.replayRoute == true && launchClicks < 24000 ||
                       launch?.advanceToChoice == true && launchClicks < ((launch?.checkChoiceCount ?? 0) > 0 ? 24000 : 4000) ||
                       launch?.checkCutinLoad == true && !startedDialogueLoadProbe && launchClicks < 300 ||
                       launch?.advanceToDialogue == true && next.messages.isEmpty && launchClicks < 24 ||
                       launch?.checkAudioResume == true && launchClicks < 4000 ||
                       launch?.advanceToOpacity == true && !observedOpacity && launchClicks < 24000) {
                launchClicks += 1
                pending = .click
            } else if startedFromLaunch, launch?.checkCutinLoad == true, !startedDialogueLoadProbe, launchClicks >= 300 {
                throw ResourceError.rejected("player_cutin_load_probe_no_target: visible=\(visibleCutinWaits) ready=\(readyCutinWaits) selectable=\(selectableCutinWaits)")
            } else if startedFromLaunch, launch?.replayRoute == true, launchClicks >= 24000,
                      next.status.phase == .waitingForEvent, !next.waitingForChoice {
                throw ResourceError.rejected("player_replay_click_limit: \(launchClicks) clicks, step \(next.status.steps)")
            } else {
                return
            }
        }
    }

    nonisolated private func dialogueFont(_ name: String?, size: CGFloat) -> NSFont {
        if let name, !name.isEmpty {
            if let installed = NSFont(name: name, size: size) { return installed }
            let substitute: String?
            switch name.applyingTransform(.fullwidthToHalfwidth, reverse: false) {
            case "MS 明朝": substitute = "HiraMinProN-W3"
            case "MS ｺﾞｼｯｸ": substitute = "HiraKakuProN-W3"
            default: substitute = nil
            }
            if let substitute, let font = NSFont(name: substitute, size: size) { return font }
        }
        return NSFont.systemFont(ofSize: size)
    }

    nonisolated private func dialogueColor(_ argb: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((argb >> 16) & 255) / 255,
                green: CGFloat((argb >> 8) & 255) / 255,
                blue: CGFloat(argb & 255) / 255, alpha: CGFloat(argb >> 24) / 255)
    }

    nonisolated private func messageGeometry(_ layer: ScriptMachine.MessageTextLayer, background: PlayerLayer?,
                                 viewport: PlayerViewport) -> (frame: CGRect, transform: CGAffineTransform)? {
        let scaleX = CGFloat(background?.scaleXPercent ?? layer.scaleXPercent) / 100
        let scaleY = CGFloat(background?.scaleYPercent ?? layer.scaleYPercent) / 100
        guard let bounds = layer.canvasBounds, scaleX != 0, scaleY != 0 else { return nil }
        // Idle visual updates move the raster while message bounds retain their snapshot origin.
        let offsetX = background.map { $0.bounds.minX - CGFloat(layer.x) } ?? 0
        let offsetY = background.map { $0.bounds.minY - CGFloat(layer.y) } ?? 0
        let frame = viewport.displayRect(CGRect(x: CGFloat(bounds[0]) + offsetX, y: CGFloat(bounds[1]) + offsetY,
            width: CGFloat(bounds[2] - bounds[0]), height: CGFloat(bounds[3] - bounds[1])))
        guard !frame.isEmpty else { return nil }
        let anchor = CGRect(x: CGFloat(layer.x), y: CGFloat(layer.y), width: 0, height: 0)
        let backgroundFrame = viewport.displayRect(background?.bounds ?? anchor)
        let origin = CGPoint(x: scaleX < 0 ? backgroundFrame.maxX : backgroundFrame.minX,
                             y: scaleY < 0 ? backgroundFrame.maxY : backgroundFrame.minY)
        let transform = CGAffineTransform(translationX: origin.x, y: origin.y)
            .scaledBy(x: scaleX, y: scaleY)
            .translatedBy(x: -backgroundFrame.minX, y: -backgroundFrame.minY)
        return (frame, transform)
    }

    private func canvasVideo(_ player: AVPlayer, bounds: CGRect, opacity: Double = 1, traceCutin: Bool = false) -> some View {
        GeometryReader { geometry in
            let frame = PlayerViewport(geometry.size).displayRect(bounds)
            PlayerVideoView(player: player, traceCutin: traceCutin)
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
                .opacity(opacity)
        }
        .clipShape(PlayerCanvasClip())
        .allowsHitTesting(false)
    }

    private func encodeCaptureThumbnail(_ png: Data, width: Int, height: Int) throws -> Data {
        let capture = try ResourceImage.decode(png).image
        guard (1...512).contains(width), (1...512).contains(height),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ResourceError.rejected("game_thread_thumbnail_context_unavailable")
        }
        context.interpolationQuality = .high
        context.draw(capture, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage(),
              let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [:]) else {
            throw ResourceError.rejected("game_thread_thumbnail_encode_failed")
        }
        return jpeg
    }

    private func captureScenePNG(_ state: PlayerState, through priority: Int32) throws -> Data {
        let capture = ImageRenderer(content: sceneCanvas(state) { layerPriority, _ in
            layerPriority <= priority
        }
        .frame(width: PlayerViewport.width, height: PlayerViewport.height)
        .background(.black))
        guard let image = capture.cgImage,
              image.width == Int(PlayerViewport.width), image.height == Int(PlayerViewport.height),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ResourceError.rejected("game_thread_image_capture_render_failed")
        }
        return data
    }

    private func sceneCanvas(_ state: PlayerState, includes: @escaping (Int32, UInt64) -> Bool) -> some View {
        let hoveredButton = self.hoveredButton
        return Canvas { canvas, size in
            let viewport = PlayerViewport(size)
            var context = canvas
            context.clip(to: Path(viewport.canvasBounds))
            let dialogueLayers = state.dialogueWindowHidden ? [] : state.messageLayers
            let messages = dialogueLayers.compactMap { layer
                -> (priority: Int32, layer: ScriptMachine.MessageTextLayer)? in
                guard let priority = layer.priority, includes(priority, layer.id) else { return nil }
                return (priority, layer)
            }.sorted { ($0.priority, $0.layer.id) < ($1.priority, $1.layer.id) }
            let backgrounds = messages.isEmpty ? [:] : Dictionary(
                state.layers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
            )
            var nextMessage = 0
            func drawMessage(_ layer: ScriptMachine.MessageTextLayer) {
                let background = backgrounds[layer.id]
                // A message and its raster can share the same script image object.
                let opacity = state.fullTextAlphas[layer.id] ?? background?.opacity ?? 255
                guard opacity > 0, let geometry = messageGeometry(layer, background: background, viewport: viewport) else { return }
                let frame = geometry.frame
                let text = NSMutableAttributedString()
                for run in layer.runs {
                    if let advance = run.horizontalAdvance {
                        var callbacks = CTRunDelegateCallbacks(version: kCTRunDelegateVersion1,
                            dealloc: { $0.deallocate() }, getAscent: { _ in 0 }, getDescent: { _ in 0 },
                            getWidth: { $0.load(as: CGFloat.self) })
                        let width = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<CGFloat>.size,
                                                                     alignment: MemoryLayout<CGFloat>.alignment)
                        width.storeBytes(of: CGFloat(advance) * viewport.scale, as: CGFloat.self)
                        if let delegate = CTRunDelegateCreate(&callbacks, width) {
                            text.append(NSAttributedString(string: "\u{fffc}", attributes: [
                                NSAttributedString.Key(kCTRunDelegateAttributeName as String): delegate
                            ]))
                        } else {
                            width.deallocate()
                        }
                        continue
                    }
                    let fontSize = max(1, CGFloat(run.height) * viewport.scale)
                    let baseFont = dialogueFont(run.fontName, size: fontSize)
                    var matrix = CGAffineTransform(scaleX: CGFloat(run.width) / CGFloat(run.height), y: 1)
                    let font = CTFontCreateCopyWithAttributes(baseFont as CTFont, fontSize, &matrix, nil)
                    var attributes: [NSAttributedString.Key: Any] = [
                        .font: font, .foregroundColor: dialogueColor(run.colorARGB)
                    ]
                    if let reading = run.ruby, !reading.text.isEmpty {
                        let readingSize = reading.height.map { max(1, CGFloat($0) * viewport.scale) } ?? fontSize / 2
                        let readingBase = dialogueFont(reading.fontName ?? run.fontName, size: readingSize)
                        let ratio = reading.width.flatMap { width in reading.height.map { CGFloat(width) / CGFloat($0) } } ?? 1
                        var readingMatrix = CGAffineTransform(scaleX: ratio, y: 1)
                        let readingFont = CTFontCreateCopyWithAttributes(readingBase as CTFont, readingSize, &readingMatrix, nil)
                        let ruby = CTRubyAnnotationCreateWithAttributes(
                            .center, .auto, .before, reading.text as CFString,
                            [kCTFontAttributeName: readingFont,
                             kCTForegroundColorAttributeName: dialogueColor(reading.colorARGB ?? run.colorARGB).cgColor] as CFDictionary)
                        attributes[NSAttributedString.Key(kCTRubyAnnotationAttributeName as String)] = ruby
                    }
                    text.append(NSAttributedString(string: run.text, attributes: attributes))
                }
                let typesetter = CTFramesetterCreateWithAttributedString(text)
                let path = CGPath(rect: CGRect(origin: .zero, size: frame.size), transform: nil)
                let textFrame = CTFramesetterCreateFrame(typesetter, CFRange(), path, nil)
                context.withCGContext { graphics in
                    graphics.saveGState()
                    defer { graphics.restoreGState() }
                    graphics.concatenate(geometry.transform)
                    graphics.setAlpha(CGFloat(opacity) / 255)
                    graphics.clip(to: frame)
                    graphics.translateBy(x: frame.minX, y: frame.maxY)
                    graphics.scaleBy(x: 1, y: -1)
                    let marginX = CGFloat(layer.surfaceMargins[0]) * viewport.scale
                    let marginY = CGFloat(layer.surfaceMargins[1]) * viewport.scale
                    let surfaceSize = CGSize(width: max(4 * viewport.scale, frame.width) + 2 * marginX,
                                             height: max(4 * viewport.scale, frame.height) + 2 * marginY)
                    // The surface offset is cancelled when projecting the text area back to the canvas.
                    if surfaceSize.width > 0, surfaceSize.height > 0,
                       surfaceSize.width <= 4096, surfaceSize.height <= 4096,
                       let surface = CGLayer(graphics, size: surfaceSize, auxiliaryInfo: nil),
                       let surfaceContext = surface.context {
                        surfaceContext.translateBy(x: marginX, y: marginY)
                        surfaceContext.textMatrix = .identity
                        CTFrameDraw(textFrame, surfaceContext)
                        graphics.draw(surface, at: CGPoint(x: -marginX, y: -marginY))
                    } else {
                        graphics.textMatrix = .identity
                        CTFrameDraw(textFrame, graphics)
                    }
                }
            }
            let dialogueIDs = Set(state.messageLayers.map(\.id))
            for layer in state.layers where includes(layer.priority, layer.id) {
                if state.dialogueWindowHidden && (layer.isWindowControl || dialogueIDs.contains(layer.id)) { continue }
                // Draw the message just above its own background, before later peers.
                while nextMessage < messages.count,
                      (messages[nextMessage].priority, messages[nextMessage].layer.id) < (layer.priority, layer.id) {
                    drawMessage(messages[nextMessage].layer)
                    nextMessage += 1
                }
                if let textures = layer.dialogueFrameTextures {
                    for texture in textures {
                        var textureContext = context
                        let alpha = (Int(texture.alpha) * Int(layer.opacity) + 127) / 255
                        textureContext.opacity = Double(alpha) / 255
                        textureContext.draw(Image(decorative: texture.image, scale: 1).interpolation(.none),
                                            in: viewport.displayRect(texture.bounds))
                    }
                    continue
                }
                let isHovered = layer.id == hoveredButton && layer.hoverImage != nil
                let raster = isHovered ? (layer.hoverImage ?? layer.image) : layer.image
                // 0x54fe9c and 0x5345e0 select fractional sampling for filter 2.
                let rasterImage = Image(decorative: raster, scale: 1)
                let image: Image
                switch layer.textureFilter {
                case 1: image = rasterImage.interpolation(.none)
                case 2: image = rasterImage.interpolation(.low)
                default: image = rasterImage
                }
                // Button_s type-4 raster positions differ from the type-6 hit rectangle.
                let textureOffset: CGFloat = layer.usesVolumeButtonOffsets ? (isHovered ? 3 : 5) : 0
                let bounds = layer.bounds(for: raster, textureOffset: textureOffset)
                guard !bounds.isEmpty else { continue }
                var layerContext = context
                layerContext.opacity = Double(layer.opacity) / 255
                let frame = viewport.displayRect(bounds)
                if layer.scaleXPercent < 0 || layer.scaleYPercent < 0 {
                    // Keep the current 2D anchor while reflecting the raster within its frame.
                    layerContext.translateBy(x: frame.midX, y: frame.midY)
                    layerContext.scaleBy(x: layer.scaleXPercent < 0 ? -1 : 1,
                                         y: layer.scaleYPercent < 0 ? -1 : 1)
                    layerContext.translateBy(x: -frame.midX, y: -frame.midY)
                }
                layerContext.draw(image, in: frame)
                if let index = state.visibleChoiceButtons[layer.id], let label = state.choiceText[index] {
                    let size = state.choiceTextSizes[layer.id]
                    let width = min(frame.width, size.map { $0.width * viewport.scale } ?? frame.width)
                    let height = min(frame.height, size.map { $0.height * viewport.scale } ?? frame.height)
                    let textFrame = CGRect(x: frame.midX - width / 2, y: frame.midY - height / 2,
                                           width: width, height: height)
                    var labelContext = context
                    labelContext.opacity = layerContext.opacity
                    labelContext.clip(to: Path(textFrame))
                    let style = state.choiceTextStyles[layer.id]
                    let font = dialogueFont(style?.fontName, size: max(1, CGFloat(style?.height ?? 24) * viewport.scale))
                    let color = dialogueColor(style?.colorARGB ?? 0xffff_ffff)
                    labelContext.draw(Text(label).font(Font(font)).foregroundColor(Color(nsColor: color)), in: textFrame)
                }
            }
            for message in messages.dropFirst(nextMessage) { drawMessage(message.layer) }
        }
    }

    private func seek(_ player: AVAudioPlayer, to milliseconds: Int32) {
        // 0x5a14d8 divides the stream seek operand by 1000.
        player.currentTime = min(player.duration, Double(max(0, milliseconds)) / 1000)
        if launch?.checkAudioResume == true {
            FileHandle.standardError.write(Data(
                "player_audio_seek requested_ms=\(milliseconds) actual_seconds=\(player.currentTime)\n".utf8))
        }
    }

    private func applySoundSeeks(_ next: PlayerState, excluding replacement: UInt64? = nil) {
        for (channel, position) in next.soundSeeks where channel != replacement {
            if let player = audio[channel] { seek(player, to: position) }
        }
    }

    private func removeAudio(channel: UInt64) {
        if launch?.replayRoute == true, let source = audioSources[channel] {
            FileHandle.standardError.write(Data(
                "player_route_audio_removed channel=\(channel) sha256=\(source.rangeSHA256)\n".utf8))
        }
        audio.removeValue(forKey: channel)?.stop()
        audioSources.removeValue(forKey: channel)
        audioPlaybackSteps.removeValue(forKey: channel)
        audioCompletions.removeValue(forKey: channel)
        audioGains.removeValue(forKey: channel)
        cancelSoundFades(channel: channel)
    }

    private func applySoundState(_ next: PlayerState, excludingSeekFor replacement: UInt64? = nil) {
        if next.isTerminal {
            stopAudio()
            return
        }
        for channel in Set(audio.keys).subtracting(next.activeSoundChannels) {
            removeAudio(channel: channel)
        }
        for (channel, volume) in next.immediateSoundVolumes where audio[channel] != nil {
            audioGains[channel] = normalizedVolume(volume)
        }
        for (channel, pan) in next.immediateSoundPans {
            audio[channel]?.pan = normalizedPan(pan)
        }
        for (channel, change) in next.soundVolumeChanges where channel != replacement {
            applySoundChange(change, channel: channel, control: .volume)
        }
        for (channel, change) in next.soundPanChanges where channel != replacement {
            applySoundChange(change, channel: channel, control: .pan)
        }
        applySoundSeeks(next, excluding: replacement)
        applyMasterVolume()
    }

    private func cancelSoundFades(channel: UInt64) {
        soundFades.removeValue(forKey: SoundFade(channel: channel, control: .volume))?.cancel()
        soundFades.removeValue(forKey: SoundFade(channel: channel, control: .pan))?.cancel()
    }

    private func applySoundChange(_ change: ScriptMachine.SoundControlChange, channel: UInt64, control: SoundControl) {
        let key = SoundFade(channel: channel, control: control)
        soundFades.removeValue(forKey: key)?.cancel()
        guard let player = audio[channel] else { return }
        let target = control == .volume ? normalizedVolume(change.target) : normalizedPan(change.target)
        func apply(_ value: Float) {
            switch control {
            case .volume:
                audioGains[channel] = value
                player.volume = value * masterGain
            case .pan:
                player.pan = value
            }
        }
        guard change.delay > 0 || change.duration > 0 else {
            apply(target)
            return
        }
        soundFades[key] = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(Int64(change.delay)))
                let start = control == .volume ? (audioGains[channel] ?? 1) : player.pan
                let clock = ContinuousClock()
                let startTime = clock.now
                let duration = Duration.milliseconds(Int64(change.duration))
                while true {
                    try Task.checkCancellation()
                    let elapsed = startTime.duration(to: clock.now)
                    let fraction: Float = elapsed >= duration ? 1 : Float(elapsed / duration)
                    apply(start + (target - start) * fraction)
                    if fraction == 1 { break }
                    try await Task.sleep(for: .milliseconds(16))
                }
                soundFades.removeValue(forKey: key)
            } catch {
                return
            }
        }
    }

    private func synchronizePlaybackIdentity(_ next: PlayerState) {
        guard displayedPlaybackIdentity != next.playbackIdentity else { return }
        if displayedPlaybackIdentity != nil {
            let stoppedChannels = audio.count
            stopAudio()
            clearCutin()
            if launch?.checkExperimentalSaveAdoption == true {
                FileHandle.standardError.write(Data("player_save_previous_media_cleared channels=\(stoppedChannels)\n".utf8))
            }
        }
        displayedPlaybackIdentity = next.playbackIdentity
    }

    private func presentTimedFrame(_ next: PlayerState) {
        guard !Task.isCancelled else { return }
        if !next.isSystemLoadFrame {
            synchronizePlaybackIdentity(next)
            applySoundState(next)
        }
        show(next)
    }

    private func show(_ next: PlayerState) {
        state = next
        if next.isTerminal {
            idleVisuals?.cancel()
            idleVisuals = nil
            pendingMovieCompletion = nil
            clearVideo()
            clearCutin()
            next.movie?.remove()
            if launch != nil {
                FileHandle.standardError.write(Data("player_terminal_media_cleared=1\n".utf8))
            }
        } else {
            updateCutin(next)
        }
        if launch != nil {
            let canvas = CGRect(x: 0, y: 0, width: PlayerViewport.width, height: PlayerViewport.height)
            let positioned = next.messageLayers.filter { $0.canvasBounds != nil }.count
            let viewport = PlayerViewport(canvas.size)
            let messagesOnCanvas = next.messageLayers.filter { message in
                let background = next.layers.first { $0.id == message.id }
                guard let geometry = messageGeometry(message, background: background, viewport: viewport) else { return false }
                return geometry.frame.applying(geometry.transform).intersects(canvas)
            }.count
            let transparent = next.layers.filter { $0.opacity == 0 }.count
            let translucent = next.layers.filter { (1..<255).contains($0.opacity) }.count
            let animatedLayers = next.layers.filter {
                next.pendingOpacityImages.contains($0.id) && !$0.bounds.isEmpty && $0.bounds.intersects(canvas)
            }
            let animatedOnCanvas = animatedLayers.count
            if launch?.advanceToOpacity == true, !observedOpacity, !animatedLayers.isEmpty {
                observedOpacity = true
                let ids = animatedLayers.map { String($0.id) }.joined(separator: ",")
                FileHandle.standardError.write(Data("player_opacity_target_layers=\(ids) steps=\(next.status.steps)\n".utf8))
                if let issues = try? JSONEncoder().encode(next.unavailableLayers) {
                    FileHandle.standardError.write(Data("player_opacity_target_issues=".utf8) + issues + Data([10]))
                }
            }
            if next.layers.contains(where: { ($0.dialogueFrameTextures?.count ?? 0) > 1 }) {
                FileHandle.standardError.write(Data("player_dialogue_frame_composited=1 steps=\(next.status.steps)\n".utf8))
            }
            let onCanvas = next.layers.filter { $0.opacity > 0 && !$0.bounds.isEmpty && $0.bounds.intersects(canvas) }.count
            let maxMotionTicks = next.maxMotionTicks
            let displacedLayers = next.layers.filter { $0.motionOffset != .zero && $0.bounds.intersects(canvas) }.count
            if launch?.checkExperimentalSaveAdoption == true, next.status.steps == 0 {
                let bound = next.layers.flatMap { $0.dialogueFrameTextures ?? [] }.filter(\.usesBoundSource).count
                if bound > 0 {
                    FileHandle.standardError.write(Data("player_saved_frame_bound_textures=\(bound)\n".utf8))
                }
            }
            let milestone = "player_phase=\(next.status.phase.rawValue) steps=\(next.status.steps) motion_elapsed_max=\(maxMotionTicks) displaced_layers=\(displacedLayers) title=\(next.canStartFromTitle) movie=\(next.movie != nil) messages=\(next.messages.count) positioned_messages=\(positioned) message_bounds_on_canvas=\(messagesOnCanvas) layers=\(next.layers.count) missing_layers=\(next.unavailableLayerCount) unsupported_animation_layers=\(next.unimplementedAnimationCount) drawable_layers=\(onCanvas) transparent_layers=\(transparent) translucent_layers=\(translucent) opacity_pending=\(next.pendingOpacityImages.count) opacity_on_canvas=\(animatedOnCanvas) choices=\(next.choices.count) choice_labels=\(next.choiceText.count) audio_cache_hits=\(next.audioCacheHits) audio_conversions=\(next.audioConversions)\n"
            FileHandle.standardError.write(Data(milestone.utf8))
            if let flash = next.layers.first(where: { $0.isWhiteFlash && $0.bounds.intersects(canvas) }) {
                FileHandle.standardError.write(Data("player_white_flash_layer=\(flash.id) steps=\(next.status.steps)\n".utf8))
            }
            if !next.choiceButtons.isEmpty {
                let visible = next.layers.filter { next.choiceButtons[$0.id] != nil }.count
                FileHandle.standardError.write(Data("player_choice_canvas_layers=\(visible)\n".utf8))
            }
            let newLayerIssues = next.unavailableLayers.filter { detail in
                // Retain the first observed clock in the log, but deduplicate
                // later samples of the same key types and failure.
                let key = detail.replacingOccurrences(of: " · (?:宿主时钟|动作时钟) -?[0-9]+(?= ·|$)", with: "",
                                                      options: .regularExpression)
                return loggedLayerIssues.insert(key).inserted
            }
            if !newLayerIssues.isEmpty, let paths = try? JSONEncoder().encode(newLayerIssues.sorted()) {
                FileHandle.standardError.write(Data("player_missing_layers=".utf8) + paths + Data([10]))
            }
            if let reason = next.status.stopReason {
                let line = next.status.currentLocation?.lineNumber ?? 0
                FileHandle.standardError.write(Data("player_stop=\(reason) line=\(line)\n".utf8))
            }
        }
        if !next.isTerminal, let movie = next.movie {
            clearVideo()
            let item = AVPlayerItem(url: movie.url)
            let player = AVPlayer(playerItem: item)
            // The original PCM mixer scales the movie operand in units of 1/256.
            player.volume = normalizedVolume(next.movieRequest?.volume ?? 256) * masterGain
            video = player
            let identity = ObjectIdentifier(item)
            videoStatus = item.observe(\.status, options: [.initial, .new]) { item, _ in
                guard item.status == .failed else { return }
                let reason = item.error?.localizedDescription ?? "影片无法载入"
                Task { @MainActor in
                    guard let current = video?.currentItem, ObjectIdentifier(current) == identity else { return }
                    failVideo(reason)
                }
            }
            player.play()
            if launch != nil, let source = next.movieRequest?.resource {
                FileHandle.standardError.write(Data("player_movie_started=\(source.sourceSHA256) steps=\(next.status.steps)\n".utf8))
            }
        }
    }

    private var savedReplayLaunch: PlayerLaunch? {
        guard let arguments = try? JSONDecoder().decode([String].self, from: lastLaunchPaths) else { return nil }
        return PlayerLaunch(arguments: arguments)
    }

    private func reopenLastReplay() {
        guard work == nil else { return }
        guard let saved = savedReplayLaunch else {
            issue = "上次的试玩配置已失效，请重新选择目录。"
            return
        }
        do {
            let assets = try SafeDirectory(saved.assets)
            openReplay(assets: assets, replayURL: saved.replay, gameURL: saved.game, ffmpeg: saved.ffmpeg, saveURL: saved.saveURL)
        } catch {
            issue = String(describing: error)
        }
    }

    private func chooseReplay(includeSaves: Bool = false) {
        guard work == nil else { return }
        let saved = savedReplayLaunch
        let assetsPanel = NSOpenPanel()
        assetsPanel.title = "选择已准备的本地资源副本目录"
        assetsPanel.directoryURL = currentReplay?.assets.root ?? library.directory?.root ?? saved?.assets
        assetsPanel.canChooseDirectories = true
        assetsPanel.canChooseFiles = false
        assetsPanel.allowsMultipleSelection = false
        guard assetsPanel.runModal() == .OK, let assetsURL = assetsPanel.url else { return }
        let assets: SafeDirectory
        do {
            assets = try SafeDirectory(assetsURL)
        } catch {
            issue = String(describing: error)
            return
        }
        let panel = NSOpenPanel()
        panel.title = "选择包含资源清单和回放摘要的目录"
        panel.directoryURL = currentReplay?.replay ?? saved?.replay
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let gamePanel = NSOpenPanel()
        gamePanel.title = "选择对应的原版游戏目录"
        gamePanel.directoryURL = currentReplay?.game ?? saved?.game
        gamePanel.canChooseDirectories = true
        gamePanel.canChooseFiles = false
        gamePanel.allowsMultipleSelection = false
        guard gamePanel.runModal() == .OK, let gameURL = gamePanel.url else { return }
        guard let ffmpeg = chooseDecoder(preferred: currentReplay?.ffmpeg ?? saved?.ffmpeg) else { return }
        var saveURL: URL?
        if includeSaves {
            let savePanel = NSOpenPanel()
            savePanel.title = "选择只读存档目录"
            savePanel.directoryURL = currentReplay?.saveURL ?? saved?.saveURL
            savePanel.canChooseDirectories = true
            savePanel.canChooseFiles = false
            savePanel.allowsMultipleSelection = false
            guard savePanel.runModal() == .OK, let selected = savePanel.url else { return }
            saveURL = selected
        }
        openReplay(assets: assets, replayURL: url, gameURL: gameURL, ffmpeg: ffmpeg, saveURL: saveURL)
    }

    private func chooseDecoder(preferred: URL?) -> URL? {
        if let preferred, PlayerLaunch.isDecoder(preferred) { return preferred }
        let homebrew = PlayerLaunch.homebrewDecoder
        if PlayerLaunch.isDecoder(homebrew) { return homebrew }

        let panel = NSOpenPanel()
        panel.title = "选择本机 ffmpeg 可执行文件"
        panel.directoryURL = preferred?.deletingLastPathComponent()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard PlayerLaunch.isDecoder(url) else {
            issue = "请选择名为 ffmpeg 的本机可执行文件。"
            return nil
        }
        return url
    }

    private func openReplay(assets: SafeDirectory, replayURL: URL, gameURL: URL, ffmpeg: URL, saveURL: URL? = nil) {
        let decoder = ffmpeg.resolvingSymlinksInPath().standardizedFileURL
        let inputRoots = [assets.root, replayURL, gameURL] + (saveURL.map { [$0] } ?? [])
        guard PlayerLaunch.isDecoder(ffmpeg), !inputRoots.contains(where: { root in
            decoder.pathComponents.starts(with: root.resolvingSymlinksInPath().standardizedFileURL.pathComponents)
        }) else {
            issue = "请选择位于游戏、回放、资源副本和存档目录之外的 ffmpeg 可执行文件。"
            if launch != nil {
                FileHandle.standardError.write(Data("player_error=player_decoder_invalid_or_inside_input\n".utf8))
            }
            return
        }
        idleVisuals?.cancel()
        idleVisuals = nil
        let configuration = ReplayConfiguration(assets: assets, replay: replayURL, game: gameURL, ffmpeg: ffmpeg, resolvedDecoder: decoder, saveURL: saveURL)
        failedReplay = nil
        issue = nil
        let id = UUID()
        workID = id
        work = Task {
            defer { finishWork(id) }
            let skipAudioForChoiceProbe = launch?.advanceToChoice == true
            let accelerated = skipAudioForChoiceProbe || launch?.checkLoadRecovery == true || launch?.checkDialogueLoad == true ||
                launch?.checkExperimentalSaveAdoption == true ||
                (launch?.replayRoute == true && launch?.realtimeRoute != true)
            // These explicit fault probes exercise the legacy rollback boundary.
            let allowSaveAdoption = launch?.checkDialogueSaveAdoption == true || (launch?.checkLoadRecovery != true &&
                !(launch?.checkDialogueLoad == true && launch?.checkLoadConfirmationSlot != nil))
            var installed = false
            do {
                let opening = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    return try PlayerSession(assets: assets, replayDirectory: replayURL, gameDirectory: gameURL, ffmpeg: decoder, saveURL: saveURL, accelerated: accelerated,
                                             skipAudioForChoiceProbe: skipAudioForChoiceProbe,
                                             allowSaveAdoption: allowSaveAdoption)
                }
                let opened = try await withTaskCancellationHandler {
                    try await opening.value
                } onCancel: {
                    opening.cancel()
                }
                try Task.checkCancellation()
                if let count = launch?.checkChoiceCount, count > opened.replayChoices.count {
                    throw ResourceError.rejected("player_choice_probe_plan_too_short")
                }
                currentReplay = configuration
                installed = true
                pendingMovieCompletion = nil
                clearVideo()
                clearCutin()
                stopAudio()
                state?.movie?.remove()
                state = nil
                showingHistory = false
                history = []
                startedFromLaunch = false
                reportedRouteReturn = false
                startedDialogueLoadProbe = false
                titlePointerOnRight = nil
                launchClicks = 0
                observedOpacity = false
                loggedLayerIssues.removeAll()
                choiceCursor = 0
                session = opened
                saveImportIssues = opened.saveImportIssues
                if launch != nil, !saveImportIssues.isEmpty {
                    FileHandle.standardError.write(Data("player_save_import_issues=\(saveImportIssues.count)\n".utf8))
                }
                try await drive(opened)
                try Task.checkCancellation()
                if launch == nil, issue == nil, state?.status.phase != .stopped {
                    var arguments = [
                        "--assets-dir", assets.root.path, "--replay-dir", replayURL.path,
                        "--game-dir", gameURL.path, "--ffmpeg", ffmpeg.path
                    ]
                    if let saveURL { arguments += ["--save-dir", saveURL.path] }
                    if let saved = try? JSONEncoder().encode(arguments) { lastLaunchPaths = saved }
                }
            } catch is CancellationError {
                if workID == id { stopSession() }
            } catch {
                guard workID == id else { return }
                let reason = String(describing: error)
                if installed {
                    failPlayback(reason)
                } else {
                    failedReplay = configuration
                    issue = Self.playbackMessage(reason)
                    if launch != nil {
                        FileHandle.standardError.write(Data("player_error=\(reason)\n".utf8))
                    }
                }
            }
        }
    }
}
