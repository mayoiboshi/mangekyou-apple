import Foundation
import CoreGraphics
import MangekyouCore
import MangekyouMedia

struct HeadlessReplayBudget: Encodable {
    var hostIterations = 0
    var remainingMessageClicks: Int
    var remainingTicks: Int32?
    var consumedStoryChoices: Int
    var remainingStoryChoices: Int
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
            let args = Array(CommandLine.arguments.dropFirst())
            var dispatchStop = false
            var inspectLoadTask = false
            var loadTaskEscape = false
            var startAfterLoadEscape = false
            var requireRouteReturn = false
            var loadTaskPages: [Int32] = []
            var openTitleLoad = false
            var loadThumbnailBackground: String?
            var scenePreviewBackground: String?
            var scenePreviewTicks: Int32?
            var exportScenePreviewPNG = false
            var requireCompleteScenePreview = false
            var stopAfterStoryChoices = false
            var recoverUnsupportedSave = false
            var startAfterSaveRecovery = false
            var loadTaskCapturePath: String?
            var saveDirectoryPath: String?
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
            var storyChoices: [Int32] = []
            var pointer: (x: Int32, y: Int32)?
            var compactSavedReplay = false
            var compactTrace = false
            var resourceReceiptsPath: String?
            var resourceProviderPath: String?, resourceCachePath: String?
            var maximumSteps: Int?
            var clickTicks: Int32?
            var movieToolsPath: String?, imageRecipePath: String?, game: String?, assets: String?, source: String?, manifest: String?, entry: String?, catalogPath: String?, selections: [String] = [], execute = false, i = 0
            while i < args.count {
                if args[i] == "--open-title-load" { openTitleLoad = true; i += 1; continue }
                if args[i] == "--inspect-load-task" { inspectLoadTask = true; i += 1; continue }
                if args[i] == "--load-task-escape" { loadTaskEscape = true; i += 1; continue }
                if args[i] == "--infer-save-state-seed" { inferSaveStateSeed = true; i += 1; continue }
                if args[i] == "--save-header-template-stdin" { saveHeaderTemplateFromStdin = true; i += 1; continue }
                if args[i] == "--start-after-load-escape" { startAfterLoadEscape = true; i += 1; continue }
                if args[i] == "--require-route-return" { requireRouteReturn = true; i += 1; continue }
                if args[i] == "--scene-preview-png" { exportScenePreviewPNG = true; i += 1; continue }
                if args[i] == "--require-complete-scene-preview" { requireCompleteScenePreview = true; i += 1; continue }
                if args[i] == "--stop-after-story-choices" { stopAfterStoryChoices = true; i += 1; continue }
                if args[i] == "--start-after-save-recovery" { startAfterSaveRecovery = true; i += 1; continue }
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
                if args[i] == "--experimental-run" { execute = true; i += 1; continue }
                guard i+1 < args.count else { throw ResourceError.rejected("missing_cli_option_value") }
                switch args[i] {
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
                case "--maximum-steps":
                    guard maximumSteps == nil, let value = Int(args[i+1]), (1...ScriptMachine.maximumSupportedSteps).contains(value) else {
                        throw ResourceError.rejected("invalid_step_budget")
                    }
                    maximumSteps = value
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
                case "--scene-preview-ticks":
                    guard scenePreviewTicks == nil, let ticks = Int32(args[i+1]), (0...3_000_000).contains(ticks) else {
                        throw ResourceError.rejected("invalid_scene_preview_ticks")
                    }
                    scenePreviewTicks = ticks
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
                case "--save-dir":
                    guard saveDirectoryPath == nil else { throw ResourceError.rejected("duplicate_save_directory") }
                    saveDirectoryPath = args[i+1]
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
                case "--select-source": selections.append(args[i+1]); guard selections.count <= 128 else { throw ResourceError.rejected("module_selection_limit") }
                default: throw ResourceError.rejected("unknown_cli_option")
                }
                i += 2
            }
            guard (pointer == nil && buttonIndex == nil) || (execute && dispatchStop) else { throw ResourceError.rejected("pointer_requires_stop_dispatch") }
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
            guard !requireRouteReturn || (startAfterLoadEscape && !storyChoices.isEmpty) else {
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
            guard !startAfterSaveRecovery || recoverUnsupportedSave else {
                throw ResourceError.rejected("start_after_save_recovery_requires_recovery")
            }
            guard !recoverUnsupportedSave || (openTitleLoad && loadTaskConfirmation == true) else {
                throw ResourceError.rejected("recover_unsupported_save_requires_title_load_confirmation")
            }
            let saveDirectory = try saveDirectoryPath.map {
                try SafeDirectory(URL(fileURLWithPath: $0, isDirectory: true))
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
            let saveSlots = try saveDirectory.map { try SaveSlotInventory.scan($0, includeMetadata: true) }
            guard saveSlots?.contains(where: { $0.status == .unsupported }) != true else {
                throw ResourceError.rejected("save_directory_contains_unsupported_entries")
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
                    if execute {
                        var machine = try ScriptMachine(program: ScriptProgram(document),allowExperimental: true,entryLabel: entry,maximumSteps: maximumSteps ?? 10_000,repository: repository,configuration: configuration, imageLoader: imageRecipe.dimensions,
                            imageMemberLookup: imageRecipe.member, imageExtendedValues: imageRecipe.extendedValues,
                            imageMotionNames: imageRecipe.motionNames, retainFullTrace: !compactTrace)
                        if let saveSlots {
                            try machine.setReadOnlySaveSlots(saveSlots, directory: saveDirectory,
                                                             inferStateSeed: inferSaveStateSeed,
                                                             headerTemplate: saveHeaderTemplate)
                        }
                        try machine.run(stepQuota: maximumSteps ?? 10_000)
                        var budget = clickTicks
                        var pendingDispatch = dispatchStop
                        var pendingScopedDispatch = dispatchStop
                        var pendingMessageClicks = messageClicks
                        var hostIterations = 0
                        var choiceCursor = 0
                        var openedTitleLoad = false
                        var lastRouteProgressSteps = 0
                        func runHost() throws {
                            while hostIterations < 50_000 {
                                hostIterations += 1
                                if requireRouteReturn, machine.executedSteps - lastRouteProgressSteps >= 1_000_000 {
                                    lastRouteProgressSteps = machine.executedSteps
                                    let receipt = "route_steps=\(lastRouteProgressSteps) choices=\(choiceCursor) phase=\(machine.phase.rawValue)\n"
                                    FileHandle.standardError.write(Data(receipt.utf8))
                                }
                                if try machine.dispatchDueTimer() {
                                    // The callback runs before further host input or time advancement.
                                } else if let request = machine.moviePlaybackRequest, let movieHost {
                                    try machine.acknowledgeMoviePlayback(durationTicks: movieHost.decode(request))
                                } else if let request = machine.soundPlaybackRequest, movieHost != nil {
                                    try movieHost!.decodeSound(request)
                                    try machine.acknowledgeSoundPlayback()
                                } else if machine.phase == .waiting, let remaining = machine.clickWaitRemaining,
                                          remaining >= 0, let available = budget {
                                    let delta = min(available, remaining, machine.ticksUntilTimer ?? remaining)
                                    try machine.advanceClickWait(ticks: delta)
                                    try machine.advancePlacementClock(ticks: delta)
                                    budget = available-delta
                                    if machine.phase != .ready && delta > 0 { continue }
                                } else if machine.phase == .waitingForEvent, let request = machine.timedStopRequest,
                                          let available = budget, available > 0 {
                                    let delta = min(available, request.duration, machine.ticksUntilTimer ?? request.duration)
                                    try machine.advanceTimedStop(ticks: delta)
                                    try machine.advancePlacementClock(ticks: delta)
                                    budget = available - delta
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
                                    guard choiceCursor < storyChoices.count else { break }
                                    let choice = storyChoices[choiceCursor]
                                    try machine.dispatchStoryChoice(choice)
                                    let receipt = "story_choice=\(choiceCursor) index=\(choice)\n"
                                    FileHandle.standardError.write(Data(receipt.utf8))
                                    choiceCursor += 1
                                } else if openTitleLoad, !openedTitleLoad, machine.canStartFromTitle {
                                    let matches = machine.titleButtons.filter { machine.titleButtonTarget($0.key) == "@@!load" }
                                    guard matches.count == 1, let button = matches.first else {
                                        throw ResourceError.rejected("title_load_button_not_unique")
                                    }
                                    try machine.dispatchStopCallback(pointer: pointer, buttonIndex: button.value, click: true)
                                    openedTitleLoad = true
                                } else if machine.phase == .waitingForEvent, pendingDispatch {
                                    try machine.dispatchStopCallback(pointer: pointer,buttonIndex: buttonIndex)
                                    pendingDispatch = false
                                } else if machine.hasScopedStop, pendingScopedDispatch {
                                    try machine.dispatchStopCallback(pointer: pointer)
                                    pendingScopedDispatch = false
                                } else if dispatchStop, try machine.commitHeadlessMessageOutput() {
                                    try machine.dispatchStopCallback(pointer: pointer)
                                } else if machine.hasScopedStop, pendingMessageClicks > 0 {
                                    if stopAfterStoryChoices && choiceCursor == storyChoices.count { break }
                                    try machine.dispatchStopCallback(pointer: pointer, click: true)
                                    pendingMessageClicks -= 1
                                } else { break }
                                guard machine.phase == .ready else { break }
                                try machine.run(stepQuota: maximumSteps ?? 10_000)
                            }
                        }
                        try runHost()
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
                                task.savedSoundDecodeHandler = { request in
                                    var audioHost = host
                                    try audioHost.decodeSound(request)
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
                            if let background = scenePreviewBackground {
                                let strictPreview = requireCompleteScenePreview
                                task.savedSceneDrawHandler = { probe, pass in
                                    let priority: Int32?
                                    let isCapture: Bool
                                    let overlapProgress: (elapsed: UInt32, duration: UInt32)?
                                    switch pass {
                                    case .scene: (priority, isCapture, overlapProgress) = (nil, false, nil)
                                    case .capture(let cutoff): (priority, isCapture, overlapProgress) = (cutoff, true, nil)
                                    case .overlapSample(let cutoff, let elapsed, let duration): (priority, isCapture, overlapProgress) = (cutoff, false, (elapsed, duration))
                                    }
                                    var surface: Data?
                                    let scene = try LoadThumbnailPass(task: probe, assets: directory,
                                        recipe: imageRecipe, backgroundPath: background, suppliedCapture: nil,
                                        saveDirectory: saveDirectory, atDrawRequest: true, capturePriority: priority,
                                        overlapProgress: overlapProgress, exportPNG: isCapture ? { surface = $0 } : nil)
                                    let incomplete = !scene.omittedLayers.isEmpty || !scene.textPreviewIssues.isEmpty ||
                                        (strictPreview && scene.interfaceBackgroundPreviewCount > 0)
                                    var receipt = ScriptMachine.SavedDisplayDraw(status: incomplete ? .unsupported : .inferred,
                                                 pixelSHA256: scene.canvasSHA256,
                                                 issue: incomplete ? "saved_scene_preview_incomplete" : nil,
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
                                throw ResourceError.rejected("load_slot_button_not_reached")
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
                            if recoverUnsupportedSave {
                                try machine.discardFailedSaveLoadTask(task)
                                try machine.run(stepQuota: 10_000)
                                try runHost()
                                guard machine.phase == .waitingForEvent, machine.canStartFromTitle else {
                                    throw ResourceError.rejected("save_recovery_title_did_not_resume:\(machine.phase.rawValue):\(machine.stopReason ?? "none")")
                                }
                                report.resumedTitleAfterUnsupportedSave = true
                            }
                            if startAfterLoadEscape || startAfterSaveRecovery {
                                guard let handle = machine.titleStartButton, let index = machine.titleButtons[handle],
                                      let layer = machine.staticImageLayers.first(where: { $0.id == handle }) else {
                                    throw ResourceError.rejected("title_start_button_unavailable")
                                }
                                try machine.dispatchStopCallback(pointer: (layer.x, layer.y), buttonIndex: index, click: true)
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
                                                     decodedBytes: bytes, status: bytes > 0 ? .verified : .unsupported,
                                                     issue: bytes > 0 ? nil : "saved_stream_seek_no_samples")
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
                        replayBudget = HeadlessReplayBudget(hostIterations: hostIterations,
                            remainingMessageClicks: pendingMessageClicks, remainingTicks: budget,
                            consumedStoryChoices: choiceCursor, remainingStoryChoices: storyChoices.count - choiceCursor)
                        result = machine.summary
                        saveResumeBoundary = machine.saveResumeBoundary
                        if scenePreviewBackground != nil, !exportScenePreviewPNG,
                           machine.phase == .waitingForSystemTask,
                           let draw = loadTask?.saveResumeBoundary?.replaySceneDraw {
                            // The suspended parent owns no scene while the load task is active.
                            if draw.status == .unsupported {
                                scenePreviewIssue = draw.issue ?? "saved_scene_preview_incomplete"
                            }
                        } else if let background = scenePreviewBackground {
                            do {
                                var previewMachine = machine
                                previewMachine.advanceVisualClock(ticks: scenePreviewTicks ?? 0)
                                let preview = try LoadThumbnailPass(task: previewMachine, assets: directory,
                                    recipe: imageRecipe, backgroundPath: background, suppliedCapture: nil,
                                    saveDirectory: saveDirectory,
                                    choicePointer: pointer.map { CGPoint(x: Int($0.x), y: Int($0.y)) },
                                    exportPNG: exportScenePreviewPNG ? { scenePNG = $0 } : nil)
                                scenePreview = preview
                                if requireCompleteScenePreview,
                                   preview.isIncomplete {
                                    scenePreviewIssue = "scene_preview_incomplete"
                                }
                            } catch {
                                scenePreviewIssue = String(describing: error)
                            }
                        }
                        if requireRouteReturn {
                            if choiceCursor != storyChoices.count {
                                routeIssue = "route_choices_not_consumed"
                            } else if machine.isWaitingForStoryChoice {
                                routeIssue = "route_additional_choice_required"
                            } else if machine.phase != .waitingForEvent || !machine.canStartFromTitle {
                                routeIssue = "route_did_not_return_to_title"
                            }
                        }
                        if machine.stopReason == "ambiguous_module_variants" { candidates = machine.pendingModuleCandidates }
                    }
                    guard try directory.read(item.source_file).sha256Hex == sha else { throw ResourceError.rejected("script_source_changed") }
                    let loadFailure = loadTask?.machine.status == .unsupported
                    let issue = routeIssue ?? scenePreviewIssue ?? loadTask?.thumbnailIssue ??
                        (loadFailure ? loadTask?.machine.stopReason : nil)
                    reports.append(ScriptRunReport(
                        status: issue != nil || loadFailure ? .unsupported : (result?.status ?? .inferred),
                        lexical: lexical, machine: result, issue: issue,sourceFile: item.source_file,sourceSHA256: sha,moduleCandidates: candidates,
                        replayBudget: replayBudget,loadTask: loadTask,saveResumeBoundary: saveResumeBoundary,
                        scenePreview: scenePreview, scenePreviewIssue: scenePreviewIssue))
                } catch {
                    reports.append(ScriptRunReport(status: .unsupported,lexical: nil,machine: nil,
                        issue: String(describing: error),sourceFile: item.source_file,sourceSHA256: sha,moduleCandidates: nil,replayBudget: nil,loadTask: nil))
                }
            }
            let report = ScriptBatchReport(status: reports.contains { $0.status == .unsupported } ? .unsupported : .inferred,
                mode: execute ? (repository == nil ? "experimental_single_file" : "experimental_pinned_modules") : "lexical_metadata_only",reports: reports)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
            let json = try encoder.encode(report) + Data([10])
            if exportScenePreviewPNG {
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
