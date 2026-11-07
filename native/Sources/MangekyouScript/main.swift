import Foundation
import MangekyouCore

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

@main struct ScriptInspector {
    static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            var assets: String?, source: String?, manifest: String?, entry: String?, catalogPath: String?, selections: [String] = [], execute = false, i = 0
            while i < args.count {
                if args[i] == "--experimental-run" { execute = true; i += 1; continue }
                guard i+1 < args.count else { throw ResourceError.rejected("missing_cli_option_value") }
                switch args[i] {
                case "--assets-dir": guard assets == nil else { throw ResourceError.rejected("duplicate_assets_option") }; assets = args[i+1]
                case "--script": guard source == nil else { throw ResourceError.rejected("duplicate_script_option") }; source = args[i+1]
                case "--manifest": guard manifest == nil else { throw ResourceError.rejected("duplicate_manifest_option") }; manifest = args[i+1]
                case "--entry-label": guard entry == nil else { throw ResourceError.rejected("duplicate_entry_option") }; entry = args[i+1]
                case "--catalog": guard catalogPath == nil else { throw ResourceError.rejected("duplicate_catalog_option") }; catalogPath = args[i+1]
                case "--select-source": selections.append(args[i+1]); guard selections.count <= 32 else { throw ResourceError.rejected("module_selection_limit") }
                default: throw ResourceError.rejected("unknown_cli_option")
                }
                i += 2
            }
            guard let assets, (source == nil) != (manifest == nil), !execute || source != nil, entry == nil || execute else {
                throw ResourceError.rejected("Usage: mangekyou-script --assets-dir PATH (--script RELATIVE | --manifest JSON) [--experimental-run [--entry-label @@LABEL] [--catalog JSON [--select-source RELATIVE]...]]")
            }
            guard catalogPath == nil || execute, selections.isEmpty || catalogPath != nil else { throw ResourceError.rejected("module_catalog_requires_explicit_execution") }
            let directory = try SafeDirectory(URL(fileURLWithPath: assets,isDirectory: true))
            var repository: ScriptRepository?
            if let catalogPath {
                let url = URL(fileURLWithPath: catalogPath)
                let container = try SafeDirectory(url.deletingLastPathComponent())
                let file = try JSONDecoder().decode(ScriptCatalogFile.self,from: container.read(url.lastPathComponent,limit: 32*1024*1024))
                var catalog = try ScriptModuleCatalog(entries: file.items)
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
                        var machine = try ScriptMachine(program: ScriptProgram(document),allowExperimental: true,entryLabel: entry,repository: repository)
                        try machine.run(); result = machine.summary
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
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
            FileHandle.standardOutput.write(try encoder.encode(report)); print("")
            if report.status == .unsupported { exit(2) }
        } catch {
            FileHandle.standardError.write(Data("Mangekyou script: \(error)\n".utf8)); exit(2)
        }
    }
}
