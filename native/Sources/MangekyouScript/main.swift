import Foundation
import MangekyouCore
import MangekyouMedia
import CryptoKit

struct ScriptRunReport: Encodable {
    let status: EvidenceStatus
    let scope = "Native source/field decoding and optional explicit experimental execution with pinned modules; no game playback"
    let lexical: ScriptLexicalSummary?
    let machine: ScriptMachineSummary?
    let issue: String?
    let sourceFile: String
    let sourceSHA256: String?
    let moduleCandidates: [ScriptModuleReference]?
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

struct ImageMemberRecipe: Decodable, Sendable {
    let name: String?
    let motion_name_candidates: [String]?
    let extended_scalar_values: [Int: Int32]?
    let container_sha256: String
    let offset: Int
    let length: Int
    let sha256: String

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func payload(_ data: Data) throws -> Data {
        guard Self.digest(data) == container_sha256, offset >= 0, length > 0,
              offset <= data.count, length <= data.count-offset else {
            throw ResourceError.rejected("abmp_image_member_range")
        }
        let member = data.subdata(in: offset..<offset+length)
        guard Self.digest(member) == sha256 else { throw ResourceError.rejected("abmp_image_member_identity") }
        return member
    }
}

@main struct ScriptInspector {
    static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            var dispatchStop = false
            var messageClicks = 0
            var buttonIndex: Int32?
            var pointer: (x: Int32, y: Int32)?
            var compactTrace = false
            var maximumSteps: Int?
            var clickTicks: Int32?
            var movieToolsPath: String?, imageRecipePath: String?, game: String?, assets: String?, source: String?, manifest: String?, entry: String?, catalogPath: String?, selections: [String] = [], execute = false, i = 0
            while i < args.count {
                if args[i] == "--dispatch-stop-callback" { dispatchStop = true; i += 1; continue }
                if args[i] == "--message-click" { messageClicks = max(messageClicks, 1); i += 1; continue }
                if args[i] == "--compact-trace" { compactTrace = true; i += 1; continue }
                if args[i] == "--experimental-run" { execute = true; i += 1; continue }
                guard i+1 < args.count else { throw ResourceError.rejected("missing_cli_option_value") }
                switch args[i] {
                case "--headless-movie-tools":
                    guard movieToolsPath == nil, args[i+1].hasPrefix("/") else {
                        throw ResourceError.rejected("invalid_movie_tools_directory")
                    }
                    movieToolsPath = args[i+1]
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
                    guard let count = Int(args[i+1]), (1...96).contains(count) else {
                        throw ResourceError.rejected("invalid_message_click_count")
                    }
                    messageClicks = count
                case "--click-ticks":
                    guard clickTicks == nil, let value = Int32(args[i+1]), (0...1_000_000).contains(value) else {
                        throw ResourceError.rejected("invalid_click_tick_budget")
                    }
                    clickTicks = value
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
            let directory = try SafeDirectory(URL(fileURLWithPath: assets,isDirectory: true))
            guard clickTicks == nil || execute else { throw ResourceError.rejected("click_ticks_require_execution") }
            guard game == nil || execute else { throw ResourceError.rejected("game_configuration_requires_execution") }
            guard imageRecipePath == nil || execute else { throw ResourceError.rejected("image_recipe_requires_execution") }
            let imageRecipe = try imageRecipePath.map { path in
                let url = URL(fileURLWithPath: path)
                let directory = try SafeDirectory(url.deletingLastPathComponent())
                return try JSONDecoder().decode([ImageMemberRecipe].self,from: directory.read(url.lastPathComponent,limit: 65536))
            }
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
                let file = try JSONDecoder().decode(ScriptCatalogFile.self,from: container.read(url.lastPathComponent,limit: 32*1024*1024))
                var catalog = try ScriptModuleCatalog(entries: file.items,indexedResourceNames: file.indexedResourceNames)
                for selection in selections { try catalog.select(sourceFile: selection) }
                repository = try ScriptRepository(directory: directory,catalog: catalog)
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
                    if execute {
                        var machine = try ScriptMachine(program: ScriptProgram(document),allowExperimental: true,entryLabel: entry,maximumSteps: maximumSteps ?? 10_000,repository: repository,configuration: configuration, imageLoader: { data in
                            if data.starts(with: Data("abmp12".utf8)) {
                                let digest = ImageMemberRecipe.digest(data)
                                let members = (imageRecipe ?? []).filter { $0.container_sha256 == digest }
                                guard (1...128).contains(members.count) else {
                                    throw ResourceError.rejected("abmp_image_recipe_required")
                                }
                                var width = 0, height = 0, pixels = 0
                                for member in members {
                                    let decoded = try ResourceImage.decode(member.payload(data))
                                    width = max(width,decoded.image.width)
                                    height = max(height,decoded.image.height)
                                    pixels += decoded.image.width * decoded.image.height
                                    guard pixels <= 64*1024*1024 else { throw ResourceError.rejected("abmp_image_pixel_budget") }
                                }
                                return (width,height,members.count)
                            }
                            let decoded = try ResourceImage.decode(data)
                            return (decoded.image.width, decoded.image.height, 1)
                        }, imageMemberLookup: { container, name in
                            let matches = (imageRecipe ?? []).filter {
                                $0.container_sha256 == container.sourceSHA256 && $0.name == name
                            }
                            guard !matches.isEmpty else { return nil }
                            guard matches.count == 1, let member = matches.first,
                                  member.offset >= 0, member.length > 0,
                                  member.offset <= container.byteLength,
                                  member.length <= container.byteLength - member.offset else {
                                throw ResourceError.rejected("ambiguous_or_invalid_image_member")
                            }
                            return (member.offset, member.length, member.sha256)
                        }, imageExtendedValues: { container in
                            (imageRecipe ?? []).first {
                                $0.container_sha256 == container.sourceSHA256 && $0.extended_scalar_values != nil
                            }?.extended_scalar_values
                        }, imageMotionNames: { container in
                            (imageRecipe ?? []).first {
                                $0.container_sha256 == container.sourceSHA256 && $0.motion_name_candidates != nil
                            }?.motion_name_candidates
                        }, retainFullTrace: !compactTrace)
                        try machine.run(stepQuota: maximumSteps ?? 10_000)
                        var budget = clickTicks
                        var pendingDispatch = dispatchStop
                        var pendingScopedDispatch = dispatchStop
                        var pendingMessageClicks = messageClicks
                        for _ in 0..<384 {
                            if let request = machine.moviePlaybackRequest, let movieHost {
                                try machine.acknowledgeMoviePlayback(durationTicks: movieHost.decode(request))
                            } else if let request = machine.soundPlaybackRequest, movieHost != nil {
                                try movieHost!.decodeSound(request)
                                try machine.acknowledgeSoundPlayback()
                            } else if machine.phase == .waiting, let remaining = machine.clickWaitRemaining,
                                      remaining >= 0, let available = budget {
                                let delta = min(available,remaining)
                                try machine.advanceClickWait(ticks: delta)
                                try machine.advancePlacementClock(ticks: delta)
                                budget = available-delta
                            } else if machine.phase == .waitingForEvent, let request = machine.timedStopRequest,
                                      let available = budget, available > 0 {
                                let delta = min(available, request.duration)
                                try machine.advanceTimedStop(ticks: delta)
                                try machine.advancePlacementClock(ticks: delta)
                                budget = available - delta
                            } else if machine.phase == .waitingForEvent, pendingDispatch {
                                try machine.dispatchStopCallback(pointer: pointer,buttonIndex: buttonIndex)
                                pendingDispatch = false
                            } else if machine.hasScopedStop, pendingScopedDispatch {
                                try machine.dispatchStopCallback(pointer: pointer)
                                pendingScopedDispatch = false
                            } else if dispatchStop, try machine.commitHeadlessMessageOutput() {
                                try machine.dispatchStopCallback(pointer: pointer)
                            } else if machine.hasScopedStop, pendingMessageClicks > 0 {
                                try machine.dispatchStopCallback(pointer: pointer, click: true)
                                pendingMessageClicks -= 1
                            } else { break }
                            guard machine.phase == .ready else { break }
                            try machine.run(stepQuota: maximumSteps ?? 10_000)
                        }
                        result = machine.summary
                        if machine.stopReason == "ambiguous_module_variants" { candidates = machine.pendingModuleCandidates }
                    }
                    guard try directory.read(item.source_file).sha256Hex == sha else { throw ResourceError.rejected("script_source_changed") }
                    reports.append(ScriptRunReport(status: result?.status ?? .inferred,lexical: lexical,machine: result,
                        issue: nil,sourceFile: item.source_file,sourceSHA256: sha,moduleCandidates: candidates))
                } catch {
                    reports.append(ScriptRunReport(status: .unsupported,lexical: nil,machine: nil,
                        issue: String(describing: error),sourceFile: item.source_file,sourceSHA256: sha,moduleCandidates: nil))
                }
            }
            let report = ScriptBatchReport(status: reports.contains { $0.status == .unsupported } ? .unsupported : .inferred,
                mode: execute ? (repository == nil ? "experimental_single_file" : "experimental_pinned_modules") : "lexical_metadata_only",reports: reports)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
            FileHandle.standardOutput.write(try encoder.encode(report)); print("")
            if report.status == .unsupported { exit(2) }
        } catch {
            FileHandle.standardError.write(Data("Mangekyou script: \(error)\n".utf8)); exit(2)
        }
    }
}
