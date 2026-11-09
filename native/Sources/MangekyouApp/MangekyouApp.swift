import AppKit
import SwiftUI
import MangekyouCore
import MangekyouMedia

@MainActor final class LibraryModel: ObservableObject {
    @Published var directory: SafeDirectory?
    @Published var inventory: Inventory?
    @Published var busy = false
    @Published var error: String?
    @Published var selected: String?
    @Published var search = ""
    @Published var image: NSImage?
    @Published var imageNotes: [String] = []
    @Published var previewError: String?
    @Published var scriptSummary: ScriptLexicalSummary?
    @Published var scriptRun: ScriptMachineSummary?
    @Published var scriptBusy = false
    @Published var moduleChoices: [ScriptModuleReference] = []
    private var preferredModuleSources: [Data: String] = [:]
    private var previewGeneration = UUID()
    private var executionGeneration = UUID()
    private var scriptDocument: ScriptDocument?
    private var imageDecodeTask: Task<ResourceImage, Error>?
    private var scriptDecodeTask: Task<ScriptPreview,Error>?
    private var scriptExecutionTask: Task<ScriptExecution,Error>?
    private struct ScriptPreview: Sendable {
        let document: ScriptDocument
        let summary: ScriptLexicalSummary
    }
    private struct ScriptExecution: Sendable {
        let summary: ScriptMachineSummary
        let choices: [ScriptModuleReference]
    }
    var displayedFiles: [ResourceEntry] {
        (inventory?.files ?? []).filter { search.isEmpty || $0.relativePath.localizedCaseInsensitiveContains(search) }
    }
    var selectedEntry: ResourceEntry? { inventory?.files.first { $0.id == selected } }

    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择合法持有的游戏目录或已提取的资源目录"
        panel.prompt = "导入目录"; panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }

    func load(_ url: URL) {
        guard !busy else { return }
        busy = true; error = nil; selected = nil
        preview()
        preferredModuleSources = [:]; moduleChoices = []
        Task {
            do {
                let source = try SafeDirectory(url)
                let result = try await Task.detached(priority: .userInitiated) { try InventoryScanner().scan(source) }.value
                directory = source; inventory = result
            } catch { self.error = String(describing: error) }
            busy = false
        }
    }

    func preview() {
        image = nil; imageNotes = []; previewError = nil
        imageDecodeTask?.cancel()
        imageDecodeTask = nil
        scriptDecodeTask?.cancel(); scriptExecutionTask?.cancel()
        previewGeneration = UUID(); executionGeneration = UUID()
        let generation = previewGeneration
        moduleChoices = []
        scriptSummary = nil; scriptDocument = nil; scriptRun = nil; scriptBusy = false
        guard let directory, let entry = selectedEntry else { return }
        if entry.relativePath.lowercased().hasSuffix(".s") {
            scriptBusy = true
            let worker = Task.detached(priority: .userInitiated) {
                let document = try ScriptDocument(data: directory.read(entry.relativePath),relativePath: entry.relativePath)
                return ScriptPreview(document: document,summary: ScriptLexicalSummary(document))
            }
            scriptDecodeTask = worker
            Task {
                do {
                    let result = try await worker.value
                    guard previewGeneration == generation, selected == entry.id, self.directory?.root == directory.root else { return }
                    scriptDocument = result.document; scriptSummary = result.summary; scriptBusy = false
                } catch {
                    guard previewGeneration == generation, selected == entry.id, self.directory?.root == directory.root else { return }
                    previewError = String(describing: error); scriptBusy = false
                }
            }
            return
        }
        guard ["PNG", "DPNG", "JPEG"].contains(entry.format) else { return }
        let worker = Task.detached(priority: .userInitiated) {
            let data = try directory.read(entry.relativePath)
            try Task.checkCancellation()
            return try ResourceImage.decode(data)
        }
        imageDecodeTask = worker
        Task {
            let result = await worker.result
            guard previewGeneration == generation, selected == entry.id,
                  self.directory?.root == directory.root else { return }
            imageDecodeTask = nil
            switch result {
            case .success(let decoded):
                image = NSImage(cgImage: decoded.image, size: NSSize(width: decoded.image.width, height: decoded.image.height))
                imageNotes = decoded.notes
            case .failure(let error):
                previewError = String(describing: error)
            }
        }
    }

    func inspectScriptExecution(preferredSource: String? = nil) {
        guard let document = scriptDocument, let directory, let inventory, !scriptBusy else { return }
        if let preferredSource {
            guard let choice = moduleChoices.first(where: { $0.sourceFile == preferredSource }),
                  let key = try? ScriptModuleCatalog.key(choice.logicalPath) else { return }
            preferredModuleSources[key] = preferredSource
        }
        let preferences = Array(preferredModuleSources.values)
        let selection = selected
        scriptBusy = true; scriptRun = nil; previewError = nil; moduleChoices = []
        executionGeneration = UUID(); let generation = executionGeneration
        let worker = Task.detached(priority: .userInitiated) {
            var catalog = try ScriptModuleCatalog.researchCopies(directory: directory,inventory: inventory)
            for source in preferences { try catalog.select(sourceFile: source) }
            let repository = try ScriptRepository(directory: directory,catalog: catalog)
            var machine = try ScriptMachine(program: ScriptProgram(document),allowExperimental: true,repository: repository)
            try machine.run()
            return ScriptExecution(summary: machine.summary,
                choices: machine.stopReason == "ambiguous_module_variants" ? machine.pendingModuleCandidates : [])
        }
        scriptExecutionTask = worker
        Task {
            do {
                let result = try await worker.value
                guard executionGeneration == generation, selected == selection, self.directory?.root == directory.root else { return }
                scriptRun = result.summary; moduleChoices = result.choices; scriptBusy = false
            } catch {
                guard executionGeneration == generation, selected == selection, self.directory?.root == directory.root else { return }
                previewError = String(describing: error); scriptBusy = false
            }
        }
    }
}

@main struct MangekyouApplication: App {
    @StateObject private var model = LibraryModel()
    @Environment(\.openWindow) private var openWindow
    private let launch: PlayerLaunch?

    init() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        launch = PlayerLaunch(arguments: arguments)
        if launch == nil, arguments.contains(where: { $0.hasPrefix("--") }) {
            let usage = """
            试玩启动参数无效。请提供绝对路径，并确认 ffmpeg 可执行。
            用法: Mangekyou --assets-dir PATH --replay-dir PATH --game-dir PATH [--ffmpeg PATH] [--save-dir PATH]

            """
            FileHandle.standardError.write(Data(usage.utf8))
            exit(64)
        }
    }

    var body: some Scene {
        WindowGroup(launch == nil ? "Mangekyou" : "万華鏡试玩") {
            Group {
                if let launch {
                    PlayerWindow(library: model, launch: launch)
                } else {
                    LibraryView(model: model)
                        .frame(minWidth: 960, minHeight: 640)
                }
            }
            .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1180, height: 790)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("导入游戏目录…") { model.chooseDirectory() }.keyboardShortcut("o")
                Button("打开试玩窗口") { openWindow(id: "player") }
            }
        }
        Window("万華鏡试玩", id: "player") {
            PlayerWindow(library: model)
                .preferredColorScheme(.dark)
        }
    }
}

struct LibraryView: View {
    @ObservedObject var model: LibraryModel
    private let gold = Color(red: 0.79, green: 0.66, blue: 0.42)
    var body: some View {
        Group {
            if let inventory = model.inventory { library(inventory) }
            else { welcome }
        }
        .tint(gold)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { model.chooseDirectory() } label: { Label("导入目录", systemImage: "folder.badge.plus") }
                    .disabled(model.busy)
            }
        }
        .overlay {
            if model.busy { ProgressView("正在只读检查资源…").padding(28).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18)) }
        }
        .alert("目录未能导入", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("好", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .onChange(of: model.selected) { _, _ in model.preview() }
    }

    private var welcome: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.12, green: 0.07, blue: 0.11), .black], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 22) {
                Image(systemName: "circle.hexagongrid.fill").font(.system(size: 72, weight: .ultraLight)).foregroundStyle(gold)
                Text("万華鏡").font(.system(size: 50, weight: .light, design: .serif)).tracking(16)
                Text("MANGEKYOU").font(.system(size: 11, weight: .medium)).tracking(7).foregroundStyle(gold)
                Text("罪と罰の少女").font(.title3).foregroundStyle(.secondary).padding(.top, 8)
                Text("Apple Silicon 原生移植 · 开发中").font(.callout).foregroundStyle(.secondary)
                Button("导入游戏目录…") { model.chooseDirectory() }
                    .buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 14).disabled(model.busy)
                VStack(spacing: 6) {
                    Text("请使用自己合法持有的第四作资源。原始文件只读，数据留在本机。")
                    Text("支持目录、图片与实验性脚本检查；尚不能开始游戏。")
                }.font(.footnote).foregroundStyle(.secondary)
            }.padding(50)
        }
    }

    private func library(_ inventory: Inventory) -> some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.directory?.root.lastPathComponent ?? "资源库").font(.headline).lineLimit(2).padding(.horizontal, 12)
                HStack {
                    Label("\(inventory.files.count) 个文件", systemImage: "doc.on.doc")
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: inventory.totalBytes, countStyle: .file))
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
                List(selection: $model.selected) {
                    ForEach(model.displayedFiles) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.relativePath).font(.system(size: 12)).lineLimit(2)
                            Text(entry.format).font(.caption2).foregroundStyle(entry.status == .unsupported ? .orange : .secondary)
                        }.padding(.vertical, 3).tag(entry.id)
                    }
                }.searchable(text: $model.search, prompt: "查找资源")
            }.padding(.top, 12).navigationSplitViewColumnWidth(min: 260, ideal: 330, max: 480)
        } detail: {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("资源检查").font(.title2)
                        Text("\(inventory.archives.count) 个资源包已识别 · 游戏运行尚未开放").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label("只读", systemImage: "lock.shield").font(.caption).foregroundStyle(gold)
                }
                Divider()
                if let entry = model.selectedEntry {
                    Text(entry.relativePath).font(.headline).textSelection(.enabled)
                    HStack {
                        Text(entry.format)
                        Text("·")
                        Text(ByteCountFormatter.string(fromByteCount: entry.byteCount, countStyle: .file))
                    }.font(.caption).foregroundStyle(.secondary)
                    if let summary = model.scriptSummary {
                        scriptDetails(summary)
                    } else if model.scriptBusy {
                        ProgressView("正在读取脚本…")
                    } else if let pack = entry.pack {
                        Label("包尾信息已验证", systemImage: "checkmark.circle").foregroundStyle(gold)
                        Text("声明 \(pack.declaredEntries) 项资源。应用尚未读取目录索引，也未解包或验证包内内容。")
                            .font(.callout).foregroundStyle(.secondary)
                    } else if let image = model.image {
                        ZStack {
                            Color(white: 0.16)
                            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(12)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity).clipShape(RoundedRectangle(cornerRadius: 8))
                        Text("\(Int(image.size.width)) × \(Int(image.size.height))").font(.caption).foregroundStyle(.secondary)
                        ForEach(model.imageNotes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    } else {
                        ContentUnavailableView("尚无可用预览", systemImage: "doc.viewfinder",
                            description: Text(model.previewError ?? entry.issue ?? "此格式尚未接入原生预览；没有执行或跳过其中内容。"))
                    }
                } else {
                    ContentUnavailableView("选择一个资源", systemImage: "square.grid.2x2",
                        description: Text("可检查资源包与脚本，或预览已提取的 PNG、JPEG 与受限 DPNG。"))
                }
                if !inventory.issues.isEmpty {
                    DisclosureGroup("\(inventory.issues.count) 项未能完成的检查") {
                        ScrollView { Text(inventory.issues.joined(separator: "\n")).font(.caption).textSelection(.enabled) }.frame(maxHeight: 120)
                    }.foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
            }.padding(28)
        }
    }

    private func scriptDetails(_ summary: ScriptLexicalSummary) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("脚本字节位置已建立",systemImage: "doc.text.magnifyingglass").foregroundStyle(gold)
            Text("编码 \(summary.encoding) · \(summary.recordCount) 条记录 · \(summary.commandCounts.values.reduce(0,+)) 条候选命令")
                .font(.callout).foregroundStyle(.secondary)
            Text("实验性执行检查只处理已实现的子集，遇到未支持内容会停止。不播放剧情，也不保存进度。")
                .font(.callout).foregroundStyle(.secondary)
            Button("实验性执行检查") { model.inspectScriptExecution() }
                .buttonStyle(.bordered).disabled(model.scriptBusy)
            if model.scriptBusy { ProgressView("正在检查执行路径…") }
            if let run = model.scriptRun {
                Divider()
                Label(run.phase == .stopped ? "已停在尚未支持的位置" : run.phase == .finished ? "本次子集检查到达文件末尾" : "已用尽本次检查步数",
                    systemImage: run.phase == .stopped ? "pause.circle" : "checkmark.circle")
                Text("处理 \(run.steps) 条记录 · 调用深度 \(run.callDepth) · 已载入 \(run.moduleSnapshotCount) 个脚本 · \(run.tableObjectCount) 个表对象、\(run.tableEntryCount) 个配置项")
                Text("\(run.listObjectCount) 个列表对象 · \(run.listLineCount) 行列表文本")
                    .font(.caption).foregroundStyle(.secondary)
                if let last = run.trace.last, last.status == .unsupported {
                    Text(last.location.sourceFile).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("\(last.command ?? last.recordType.rawValue) · 第 \(last.location.lineNumber) 行 · 字节 \(last.location.byteOffset)")
                        .font(.system(.callout,design: .monospaced)).textSelection(.enabled)
                    Text(last.reason ?? "未支持").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if !model.moduleChoices.isEmpty {
                    Text("目标资源存在不同内容的版本。选择一个版本后会从头重新检查；不会推定原游戏采用哪一版。")
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach(model.moduleChoices,id: \.sourceFile) { choice in
                        Button {
                            model.inspectScriptExecution(preferredSource: choice.sourceFile)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(choice.sourceFile)
                                Text("SHA-256 " + choice.sourceSHA256.prefix(12)).font(.caption2).foregroundStyle(.secondary)
                            }
                        }.buttonStyle(.bordered).disabled(model.scriptBusy)
                    }
                }
                Text("这是当前模型的本地检查，尚未通过原引擎行为对照。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.previewError { Text(error).font(.caption).foregroundStyle(.orange) }
        }
    }
}
