import Foundation
import CoreGraphics
import ImageIO
import MangekyouCore
import MangekyouMedia
import CryptoKit

struct ImageCheck: Encodable {
    let relativePath: String
    let sourceSHA256: String?
    let status: EvidenceStatus
    let width: Int?
    let height: Int?
    let notes: [String]
    let issue: String?
    let originalRendererEquivalence: EvidenceStatus = .notTested
}
struct InspectReport: Encodable {
    let inventory: Inventory
    let imageChecks: [ImageCheck]
    let imageDecodeStatus: EvidenceStatus
}

struct SaveStateCheck: Encodable {
    let decodedLength: Int
    let threadVersion: Int32
    let routineCount: Int32
    let readerCursor: SaveReaderCursor
    let routineTextAndIntegerStatus: EvidenceStatus
    let decodedResultIntegerSnapshotCount: Int
    var resolvedLabel: ScriptLocation?
    var resolvedSourcePosition: ScriptLocation?
    var sourcePositionIssue: String?
    var resolvedCommand: ScriptLocation?
    var resolvedResumeRecord: ScriptLocation?
    var resolvedResumeRecordKind: ScriptRecordKind?
    var resolvedCommandControlDepth: Int?
    var commandBoundaryStatus: EvidenceStatus = .notTested
    var stateSeedInference: EvidenceStatus?
    var slotHeaderVerification: EvidenceStatus?
    var statePrefix: SaveStatePrefix?
    var displayState: SaveStatePrefix.DisplayState?
    var engineState: SaveEngineState?
    var engineStateIssue: String?
    var calValArrays: SaveVariableArrays.Summary?
    let restoreStatus: EvidenceStatus = .notTested

    init(_ data: Data) throws {
        guard data.count >= 16, data.starts(with: "thread\0\0".utf8) else {
            throw ResourceError.rejected("thread_prefix_missing")
        }
        decodedLength = data.count
        (threadVersion, routineCount) = data.withUnsafeBytes { bytes in
            (Int32(littleEndian: bytes.loadUnaligned(fromByteOffset: 8, as: Int32.self)),
             Int32(littleEndian: bytes.loadUnaligned(fromByteOffset: 12, as: Int32.self)))
        }
        guard threadVersion == 10, (0...1024).contains(routineCount) else {
            throw ResourceError.rejected("unsupported_thread_header")
        }
        readerCursor = try SaveReaderCursor(state: data, routineCount: routineCount)
        decodedResultIntegerSnapshotCount = try readerCursor.validateRoutinePayloads(in: data)
        routineTextAndIntegerStatus = readerCursor.routines.isEmpty ? .notTested : .verified
    }
}

struct SaveThumbnailCheck: Encodable {
    let present: Bool
    let width: Int?
    let height: Int?
}

struct TwoTextureCheck: Encodable {
    let status: EvidenceStatus = .verified
    let width: Int
    let height: Int
    let changedPixels: Int
    let canvasSHA256: String
    let originalRendererEquivalence: EvidenceStatus = .notTested
}

@main struct Inspect {
    static func main() {
        do {
            var args = Array(CommandLine.arguments.dropFirst())
            if args.first == "--inspect-two-texture" {
                guard args.count == 9, let action = Int32(args[6]), action >= 0,
                      let x = Int(args[7]), let y = Int(args[8]) else {
                    throw ResourceError.rejected("invalid_two_texture_inspection_arguments")
                }
                let assets = try SafeDirectory(URL(fileURLWithPath: args[1], isDirectory: true))
                let recipeURL = URL(fileURLWithPath: args[2])
                let recipes = try SafeDirectory(recipeURL.deletingLastPathComponent())
                let recipe = try JSONDecoder().decode(ScriptImageRecipe.self,
                    from: recipes.read(recipeURL.lastPathComponent, limit: 32 * 1024 * 1024))
                let container = try assets.read(args[3])
                let bound = try assets.read(args[5])
                func location(_ path: String, _ data: Data) -> ScriptLocation {
                    ScriptModuleReference(logicalPath: path, sourceFile: path, sourceSHA256: data.sha256Hex)
                        .wholeFileLocation(byteLength: data.count)
                }
                guard let keys = recipe.motionKeys(location(args[3], container), selectedMember: action, time: 0) else {
                    throw ResourceError.rejected("two_texture_timeline_unavailable")
                }
                let draws = keys.filter { $0.type == 11 }
                guard draws.count == 1 else { throw ResourceError.rejected("two_texture_key_count") }
                let background = try ResourceImage.decode(assets.read(args[4])).opaqueCanvas(over: CGColor(gray: 0, alpha: 1))
                var canvas = background
                try recipe.drawFullTwoTextureKey(draws[0], container: container,
                    boundFirst: (bound, location(args[5], bound)), origin: SIMD2(x, y), canvas: &canvas)
                var hash = SHA256()
                var changed = 0
                for (before, after) in zip(background, canvas) {
                    changed += zip(before, after).count { $0 != $1 }
                    after.withUnsafeBytes { hash.update(bufferPointer: $0) }
                }
                let report = TwoTextureCheck(width: canvas[0].count, height: canvas.count,
                    changedPixels: changed, canvasSHA256: hash.finalize().map { String(format: "%02x", $0) }.joined())
                FileHandle.standardOutput.write(try JSONEncoder().encode(report))
                print("")
                return
            }
            var seedFromStdin = false
            var inferSeed = false
            var headerTemplateFromStdin = false
            var headerExecutable: String?
            var headerGameDirectory: String?
            var calValOffset: Int?
            var locateCalVal = false
            var inspectEngine = false
            var inspectPrefix = false
            var inspectDisplay = false
            var selectedSources: [String] = []
            var previewDisplaySurface: Int?
            var previewDisplayReload: (width: Int, height: Int)?
            if args.first == "--inspect-save-state" {
                while args.count > 3, let option = args.last, option.hasPrefix("--") {
                    switch option {
                    case "--seed-stdin", "--infer-seed", "--header-template-stdin":
                        guard !seedFromStdin, !inferSeed, !headerTemplateFromStdin else {
                            throw ResourceError.rejected("conflicting_state_seed_options")
                        }
                        seedFromStdin = option == "--seed-stdin"
                        inferSeed = option == "--infer-seed"
                        headerTemplateFromStdin = option == "--header-template-stdin"
                    case "--engine-state":
                        guard !inspectEngine else { throw ResourceError.rejected("duplicate_engine_state_option") }
                        inspectEngine = true
                    case "--display-state":
                        guard !inspectDisplay else { throw ResourceError.rejected("duplicate_display_state_option") }
                        inspectDisplay = true
                    case "--state-prefix":
                        guard !inspectPrefix else { throw ResourceError.rejected("duplicate_state_prefix_option") }
                        inspectPrefix = true
                    default:
                        if option.hasPrefix("--header-exe=") {
                            guard headerExecutable == nil else { throw ResourceError.rejected("duplicate_save_header_exe") }
                            headerExecutable = String(option.dropFirst("--header-exe=".count))
                            args.removeLast()
                            continue
                        }
                        if option.hasPrefix("--header-game-dir=") {
                            guard headerGameDirectory == nil else { throw ResourceError.rejected("duplicate_save_header_game_directory") }
                            headerGameDirectory = String(option.dropFirst("--header-game-dir=".count))
                            args.removeLast()
                            continue
                        }
                        if option.hasPrefix("--display-surface-png=") {
                            guard previewDisplaySurface == nil,
                                  let index = Int(option.dropFirst("--display-surface-png=".count)),
                                  (0...1).contains(index) else {
                                throw ResourceError.rejected("invalid_display_surface_preview_option")
                            }
                            previewDisplaySurface = index
                            args.removeLast()
                            continue
                        }
                        if option.hasPrefix("--display-reload-png=") {
                            let size = option.dropFirst("--display-reload-png=".count).split(separator: "x")
                            guard previewDisplayReload == nil, size.count == 2,
                                  let width = Int(size[0]), let height = Int(size[1]),
                                  (1...4096).contains(width), (1...4096).contains(height) else {
                                throw ResourceError.rejected("invalid_display_reload_preview_size")
                            }
                            previewDisplayReload = (width, height)
                            args.removeLast()
                            continue
                        }
                        if option.hasPrefix("--select-source=") {
                            let source = String(option.dropFirst("--select-source=".count))
                            guard !source.isEmpty else { throw ResourceError.rejected("empty_selected_source") }
                            selectedSources.append(source)
                            args.removeLast()
                            continue
                        }
                        let prefix = "--calval-offset="
                        guard option.hasPrefix(prefix) else {
                            throw ResourceError.rejected("unknown_save_state_option")
                        }
                        guard !locateCalVal, calValOffset == nil else {
                            throw ResourceError.rejected("duplicate_calval_offset_option")
                        }
                        let value = option.dropFirst(prefix.count)
                        if value == "auto" {
                            locateCalVal = true
                        } else {
                            guard let offset = Int(value), offset >= 0 else {
                                throw ResourceError.rejected("invalid_calval_offset")
                            }
                            calValOffset = offset
                        }
                    }
                    args.removeLast()
                }
                guard (headerExecutable == nil) == (headerGameDirectory == nil),
                      headerExecutable == nil || (!seedFromStdin && !inferSeed && !headerTemplateFromStdin) else {
                    throw ResourceError.rejected("conflicting_save_header_source_options")
                }
            }
            if args.count == 2, args[0] == "--inspect-save-directory" {
                let directory = try SafeDirectory(URL(fileURLWithPath: args[1], isDirectory: true))
                let report = try SaveSlotInventory.scan(directory)
                FileHandle.standardOutput.write(try JSONEncoder().encode(report))
                print("")
                if report.contains(where: { $0.status == .unsupported }) { exit(2) }
                return
            }
            if (args.count == 3 && ["--inspect-save", "--inspect-save-state", "--inspect-save-thumbnail"].contains(args[0]))
                || (args.count == 6 && args[0] == "--inspect-save-state") {
                let directory = try SafeDirectory(URL(fileURLWithPath: args[1], isDirectory: true))
                let data = try directory.read(args[2], limit: SaveEnvelope.maxFileBytes)
                let encoder = JSONEncoder()
                let output: Data
                var failedSaveCheck = false
                if args[0] == "--inspect-save-state" {
                    var seed: UInt32?
                    if seedFromStdin {
                        var input = Data()
                        while input.count < 17,
                              let chunk = try FileHandle.standardInput.read(upToCount: 17 - input.count),
                              !chunk.isEmpty {
                            input.append(chunk)
                        }
                        guard input.count < 17 else { throw ResourceError.rejected("invalid_state_seed") }
                        let field = String(decoding: input, as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard (1...8).contains(field.utf8.count),
                              field.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                              let value = UInt32(field, radix: 16) else {
                            throw ResourceError.rejected("invalid_state_seed")
                        }
                        seed = value
                    }
                    if let executable = headerExecutable, let game = headerGameDirectory {
                        let original = try SafeDirectory(URL(fileURLWithPath: game, isDirectory: true))
                        let template = try SaveEnvelope.slotHeaderTemplate(from: original, executable: executable)
                        seed = try SaveEnvelope.validatedSlotSeed(data, clearTemplate: template)
                    } else if headerTemplateFromStdin {
                        var template = Data()
                        while template.count < 41,
                              let chunk = try FileHandle.standardInput.read(upToCount: 41 - template.count),
                              !chunk.isEmpty {
                            template.append(chunk)
                        }
                        seed = try SaveEnvelope.validatedSlotSeed(data, clearTemplate: template)
                    }
                    let state = try SaveEnvelope.decodeSlotState(data, seed: seed, inferSeed: inferSeed)
                    var check = try SaveStateCheck(state)
                    if !selectedSources.isEmpty && (args.count != 6 || previewDisplaySurface != nil) {
                        throw ResourceError.rejected("selected_sources_require_catalog_lookup")
                    }
                    if previewDisplaySurface != nil && previewDisplayReload != nil {
                        throw ResourceError.rejected("conflicting_display_preview_options")
                    }
                    func writePreview(_ image: CGImage) throws {
                        let png = NSMutableData()
                        guard let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil) else {
                            throw ResourceError.rejected("saved_display_preview_encoder_unavailable")
                        }
                        CGImageDestinationAddImage(destination, image, nil)
                        guard CGImageDestinationFinalize(destination) else {
                            throw ResourceError.rejected("saved_display_preview_encode_failed")
                        }
                        FileHandle.standardOutput.write(png as Data)
                    }
                    if let index = previewDisplaySurface {
                        let prefix = try SaveStatePrefix(state: state, after: check.readerCursor)
                        try writePreview(ResourceImage.decode(prefix.displaySurfaceBytes(in: state, index: index)).image)
                        return
                    }
                    var previewReload: SaveStatePrefix.DisplaySummary.Reload?
                    if let size = previewDisplayReload {
                        let prefix = try SaveStatePrefix(state: state, after: check.readerCursor)
                        let display = try prefix.inspectDisplay(in: state)
                        if let rect = display.proceduralRect {
                            try writePreview(ResourceImage.savedDisplayRectPreview(rect, width: size.width, height: size.height))
                            return
                        }
                        if let issue = display.proceduralRectIssue { throw ResourceError.rejected(issue) }
                        guard let reload = display.externalReload else {
                            throw ResourceError.rejected("saved_display_reload_unavailable")
                        }
                        guard args.count == 6 else { throw ResourceError.rejected("saved_display_reload_requires_catalog") }
                        previewReload = reload
                    }

                    if headerTemplateFromStdin || headerExecutable != nil { check.slotHeaderVerification = .verified }
                    if inspectPrefix || inspectDisplay || locateCalVal || (inspectEngine && calValOffset == nil) {
                        let prefix = try SaveStatePrefix(state: state, after: check.readerCursor)
                        check.statePrefix = prefix
                        if inspectDisplay {
                            check.displayState = try prefix.inspectDisplayState(in: state)
                        }
                        if locateCalVal || (inspectEngine && calValOffset == nil) {
                            calValOffset = try check.displayState?.calValOffset ?? prefix.locateCalVal(in: state)
                        }
                    }
                    if let calValOffset {
                        let arrays = try SaveVariableArrays.inspectCalVal(state: state, at: calValOffset)
                        check.calValArrays = arrays
                        failedSaveCheck = arrays.indexed.status == .unsupported
                        if inspectEngine && !failedSaveCheck {
                            do {
                                let engine = try SaveEngineState(state: state,
                                    at: arrays.indexed.nextDecodedOffset ?? arrays.nextDecodedOffset)
                                check.engineState = engine
                                if engine.status == .unsupported {
                                    check.engineStateIssue = "unparsed_save_state_tail"
                                    failedSaveCheck = true
                                }
                            } catch {
                                check.engineStateIssue = String(describing: error)
                                failedSaveCheck = true
                            }
                        }
                    }
                    if inferSeed, try SaveEnvelope(data).slot?.transformed == true {
                        check.stateSeedInference = .inferred
                    }
                    if args.count == 6 {
                        let assets = try SafeDirectory(URL(fileURLWithPath: args[3], isDirectory: true))
                        let catalogDirectory = try SafeDirectory(URL(fileURLWithPath: args[4], isDirectory: true))
                        let catalogFile = try JSONDecoder().decode(ScriptCatalogFile.self,
                            from: catalogDirectory.read(args[5], limit: 32 * 1024 * 1024))
                        var catalog = try ScriptModuleCatalog(entries: catalogFile.items)
                        for source in selectedSources.reversed() {
                            try catalog.select(sourceFile: source)
                        }
                        if let size = previewDisplayReload, let reload = previewReload {
                            let (_, bytes) = try reload.readImage(in: state, catalog: catalog, directory: assets)
                            let image = try ResourceImage.decode(bytes)
                            try writePreview(image.savedDisplayPreview(transform: reload.transform,
                                                                       width: size.width, height: size.height))
                            return
                        }
                        var repository = try ScriptRepository(directory: assets, catalog: catalog)
                        do {
                            let resolved = try check.readerCursor.resolveLabel(in: state, repository: &repository)
                            check.resolvedLabel = resolved.location
                            let position = try resolved.program.sourcePosition(for: check.readerCursor, anchor: resolved.location)
                            check.resolvedSourcePosition = position
                            if check.readerCursor.routines.last?.rawState == 3 {
                                let index = try resolved.program.savedResumeIndex(position, reader: check.readerCursor)
                                let record = resolved.program.document.records[index]
                                check.resolvedResumeRecord = record.location
                                check.resolvedResumeRecordKind = record.kind
                                check.commandBoundaryStatus = .inferred
                            } else {
                                let boundary = try resolved.program.saveCommandBoundary(position)
                                check.resolvedCommand = boundary.location
                                check.resolvedCommandControlDepth = boundary.controlDepth
                                check.commandBoundaryStatus = .verified
                            }
                        } catch {
                            check.commandBoundaryStatus = .unsupported
                            check.sourcePositionIssue = String(describing: error)
                            failedSaveCheck = true
                        }
                    }
                    output = try encoder.encode(check)
                } else if args[0] == "--inspect-save-thumbnail" {
                    let thumbnail = try ResourceImage.decodeSaveThumbnail(data)
                    output = try encoder.encode(SaveThumbnailCheck(present: thumbnail != nil,
                        width: thumbnail?.image.width, height: thumbnail?.image.height))
                } else {
                    output = try encoder.encode(SaveEnvelope(data))
                }
                FileHandle.standardOutput.write(output)
                print("")
                if failedSaveCheck { exit(2) }
                return
            }
            guard args.count >= 2, args.count <= 3, ["--game-dir", "--assets-dir"].contains(args[0]),
                  args.count == 2 || args[2] == "--verify-images" else {
                throw ResourceError.rejected("""
                    Usage: mangekyou-inspect (--game-dir|--assets-dir) PATH [--verify-images]
                           mangekyou-inspect --inspect-two-texture ASSETS RECIPE CONTAINER BACKGROUND FIRST ACTION X Y
                           mangekyou-inspect --inspect-save-directory DIRECTORY
                           mangekyou-inspect --inspect-save DIRECTORY SLOT
                           mangekyou-inspect --inspect-save-thumbnail DIRECTORY SLOT
                           mangekyou-inspect --inspect-save-state DIRECTORY SLOT [ASSETS CATALOG_DIRECTORY CATALOG] [--display-surface-png=0|1|--display-reload-png=WIDTHxHEIGHT] [--select-source=SOURCE ...] [--state-prefix] [--display-state] [--engine-state] [--calval-offset=BYTES|auto] [--seed-stdin|--infer-seed|--header-template-stdin]
                           --seed-stdin reads one hexadecimal value from a pipe closed at EOF.
                           --header-template-stdin reads exactly 40 template bytes from a pipe closed at EOF.
                           --header-game-dir=PATH --header-exe=RELATIVE_PATH uses a pinned local original executable.
                    """)
            }
            let directory = try SafeDirectory(URL(fileURLWithPath: args[1], isDirectory: true))
            let result = try InventoryScanner().scan(directory)
            var checks: [ImageCheck] = []
            if args.count == 3 {
                let images = result.files.filter { ["PNG", "DPNG", "JPEG"].contains($0.format) }
                guard images.count <= 128 else { throw ResourceError.rejected("image_sample_limit") }
                var total = 0
                let deadline = Date().addingTimeInterval(60)
                for entry in images {
                    do {
                        guard Date() < deadline else { throw ResourceError.rejected("image_time_limit") }
                        let data = try directory.read(entry.relativePath)
                        total += data.count
                        guard total <= 128 * 1024 * 1024 else { throw ResourceError.rejected("image_total_byte_limit") }
                        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                        let decoded = try ResourceImage.decode(data)
                        checks.append(ImageCheck(relativePath: entry.relativePath, sourceSHA256: sha,
                            status: .verified, width: decoded.image.width, height: decoded.image.height, notes: decoded.notes, issue: nil))
                    } catch {
                        checks.append(ImageCheck(relativePath: entry.relativePath, sourceSHA256: nil,
                            status: .unsupported, width: nil, height: nil, notes: [], issue: String(describing: error)))
                    }
                }
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let report = InspectReport(inventory: result, imageChecks: checks, imageDecodeStatus: args.count == 3 && !checks.isEmpty ?
                (checks.allSatisfy { $0.status == .verified } ? .verified : .unsupported) : .notTested)
            FileHandle.standardOutput.write(try encoder.encode(report)); print("")
            if !result.issues.isEmpty || checks.contains(where: { $0.status == .unsupported }) { exit(2) }
        } catch {
            let message = "Mangekyou: \(error)\n"
            FileHandle.standardError.write(Data(message.utf8)); exit(2)
        }
    }
}
