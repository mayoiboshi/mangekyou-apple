import Foundation

public struct ScriptModuleReference: Codable, Sendable, Equatable {
    public let logicalPath: String
    public let sourceFile: String
    public let sourceSHA256: String
    enum CodingKeys: String, CodingKey {
        case logicalPath = "logical_path", sourceFile = "source_file", sourceSHA256 = "sha256"
    }
    public init(logicalPath: String, sourceFile: String, sourceSHA256: String) {
        self.logicalPath = logicalPath; self.sourceFile = sourceFile; self.sourceSHA256 = sourceSHA256
    }

    public func wholeFileLocation(byteLength: Int) -> ScriptLocation {
        ScriptLocation(sourceFile: sourceFile, sourceSHA256: sourceSHA256, byteOffset: 0,
                       byteLength: byteLength, rangeSHA256: sourceSHA256, lineNumber: 1)
    }
}

public struct ScriptCatalogFile: Codable, Sendable {
    public let items: [ScriptModuleReference]
    public var indexedResourceNames: [String]?
    public init(items: [ScriptModuleReference]) { self.items = items }
}

/// Host-supplied mapping. No PACK mount precedence is inferred from directory or filename order.
public struct ScriptModuleCatalog: Sendable {
    public let entries: [ScriptModuleReference]
    private var indexedResourceKeys: Set<Data>?
    private var groups: [Data: [ScriptModuleReference]] = [:]
    private var physical: [Data: ScriptModuleReference] = [:]
    private var selections: [Data: Data] = [:]

    public init(entries: [ScriptModuleReference], indexedResourceNames: [String]? = nil) throws {
        guard (1...2000).contains(entries.count) else { throw ResourceError.rejected("module_catalog_count_limit") }
        self.entries = entries
        if let indexedResourceNames {
            guard (1...50_000).contains(indexedResourceNames.count) else {
                throw ResourceError.rejected("resource_index_count_limit")
            }
            indexedResourceKeys = Set(try indexedResourceNames.map(Self.key))
        }
        for entry in entries {
            _ = try SafeDirectory.components(entry.sourceFile)
            guard entry.sourceFile.utf8.count <= 4096,
                  entry.sourceSHA256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil
            else { throw ResourceError.rejected("invalid_module_reference") }
            let key = try Self.key(entry.logicalPath), file = Data(entry.sourceFile.utf8)
            guard physical[file] == nil else { throw ResourceError.rejected("duplicate_physical_module_reference") }
            physical[file] = entry; groups[key,default: []].append(entry)
        }
    }

    /// Explicit research-copy layout adapter. The first dataN.pack DIRECTORY is a provenance
    /// component, not a mounted archive. This does not read archives or choose patch precedence.
    public static func researchCopies(directory: SafeDirectory, inventory: Inventory) throws -> Self {
        let files = inventory.files.filter { $0.relativePath.lowercased().hasSuffix(".s") || $0.relativePath.lowercased().hasSuffix(".txt") }
        guard (1...2000).contains(files.count) else { throw ResourceError.rejected("research_copy_catalog_count") }
        var entries: [ScriptModuleReference] = [], total = 0
        let clock = ContinuousClock(), started = ContinuousClock.now
        for file in files {
            guard !Task.isCancelled, clock.now - started < .seconds(15) else { throw ResourceError.rejected("research_copy_catalog_time_or_cancel_limit") }
            let data = try directory.read(file.relativePath); total += data.count
            guard total <= 128*1024*1024 else { throw ResourceError.rejected("research_copy_catalog_byte_limit") }
            let parts = try SafeDirectory.components(file.relativePath)
            let wrapped = parts.count > 1 && parts[0].range(of: #"^data([0-9]|[12][0-9]|3[01])\.pack$"#, options: .regularExpression) != nil
            let logical = (wrapped ? Array(parts.dropFirst()) : parts).joined(separator: "/")
            entries.append(ScriptModuleReference(logicalPath: logical,sourceFile: file.relativePath,sourceSHA256: data.sha256Hex))
        }
        return try Self(entries: entries)
    }

    public static func key(_ raw: String) throws -> Data {
        let logical = raw.replacingOccurrences(of: "\\",with: "/")
        guard logical.utf8.count <= 4096 else { throw ResourceError.rejected("module_path_limit") }
        _ = try SafeDirectory.components(logical)
        // Data keys avoid Swift String's implicit canonical Unicode equivalence.
        return Data(asciiLower(logical).utf8)
    }

    public func variants(for logical: String) throws -> [ScriptModuleReference] {
        (groups[try Self.key(logical)] ?? []).sorted { Data($0.sourceFile.utf8).lexicographicallyPrecedes(Data($1.sourceFile.utf8)) }
    }

    func resourceExists(_ raw: String, currentSourceFile: String) throws -> Bool {
        let logical = try resourcePath(raw,currentSourceFile: currentSourceFile)
        if !(try variants(for: logical)).isEmpty { return true }
        guard let indexedResourceKeys else { throw ResourceError.rejected("resource_existence_index_required") }
        return indexedResourceKeys.contains(try Self.key(logical))
    }

    func requireResourceCopyIfIndexed(_ logical: String) throws {
        let key = try Self.key(logical)
        if indexedResourceKeys?.contains(key) == true {
            FileHandle.standardError.write(Data("indexed_resource_key_sha256=\(key.sha256Hex)\n".utf8))
            throw ResourceError.rejected("indexed_resource_copy_required")
        }
    }

    func isIndexed(_ logical: String) throws -> Bool {
        indexedResourceKeys?.contains(try Self.key(logical)) == true
    }

    public func reference(forPhysical relative: String) -> ScriptModuleReference? { physical[Data(relative.utf8)] }

    /// Reviewed self-directory candidate, then the literal logical name. Configured
    /// native search prefixes and Windows filesystem expansion remain unsupported.
    public func resourcePath(_ raw: String, currentSourceFile: String) throws -> String {
        _ = try Self.key(raw)
        guard let source = reference(forPhysical: currentSourceFile) else { throw ResourceError.rejected("resource_current_module_not_in_catalog") }
        let parts = source.logicalPath.replacingOccurrences(of: "\\",with: "/").split(separator: "/")
        if parts.count > 1 {
            let relative = parts.dropLast().joined(separator: "/")+"/"+raw.replacingOccurrences(of: "\\",with: "/")
            let key = try Self.key(relative)
            if indexedResourceKeys?.contains(key) == true || groups[key] != nil { return relative }
        }
        return raw
    }

    func relativeResourcePath(_ raw: String, currentSourceFile: String) throws -> String {
        guard let source = reference(forPhysical: currentSourceFile) else {
            throw ResourceError.rejected("resource_current_module_not_in_catalog")
        }
        let path = raw.replacingOccurrences(of: "\\",with: "/")
        guard !path.hasPrefix("/"), !path.contains(":"), path.utf8.count <= 4096 else {
            throw ResourceError.rejected("invalid_relative_resource")
        }
        var parts = source.logicalPath.replacingOccurrences(of: "\\",with: "/").split(separator: "/").dropLast().map(String.init)
        for part in path.split(separator: "/",omittingEmptySubsequences: false) {
            if part == ".." {
                guard !parts.isEmpty else { throw ResourceError.rejected("resource_path_escapes_catalog") }
                parts.removeLast()
            } else {
                guard !part.isEmpty, part != "." else { throw ResourceError.rejected("invalid_relative_resource") }
                parts.append(String(part))
            }
        }
        let logical = parts.joined(separator: "/")
        _ = try Self.key(logical)
        return logical
    }

    public mutating func select(sourceFile: String) throws {
        guard let reference = reference(forPhysical: sourceFile) else { throw ResourceError.rejected("selected_module_not_in_catalog") }
        selections[try Self.key(reference.logicalPath)] = Data(reference.sourceFile.utf8)
    }

    public func resolve(_ logical: String) throws -> ScriptModuleReference {
        let variants = try variants(for: logical), key = try Self.key(logical)
        guard !variants.isEmpty else { throw ResourceError.rejected("module_not_in_catalog") }
        if let selected = selections[key], let found = variants.first(where: { Data($0.sourceFile.utf8) == selected }) { return found }
        guard Set(variants.map(\.sourceSHA256)).count == 1 else { throw ResourceError.rejected("ambiguous_module_variants") }
        // Byte-identical aliases only. This is deterministic provenance selection, not mount precedence.
        return variants[0]
    }
}

private struct ScriptIncludeState {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    var visits = 0
    var records = 0
    var seen = Set<Data>()
    var active = Set<Data>()
    var sources: [Data: ScriptSource] = [:]
}

public struct ScriptRepository: Sendable {
    public let directory: SafeDirectory
    public let catalog: ScriptModuleCatalog
    private var cache: [Data: ScriptProgram] = [:]
    private var cacheOrder: [Data] = []
    private var cachedInstructionCount = 0
    private var dataCache: [Data: Data] = [:]
    private var suppliedResources: [Data: ScriptModuleReference] = [:]
    private let supplyResource: (@Sendable (String) throws -> ScriptModuleReference)?
    public private(set) var snapshotBytes = 0
    public var loadedModuleCount: Int { cache.count }
    public var sourceSnapshotCount: Int { dataCache.count }
    public let maximumModules: Int
    public let maximumBytes: Int
    public private(set) var pendingVariants: [ScriptModuleReference] = []

    public init(directory: SafeDirectory, catalog: ScriptModuleCatalog, maximumModules: Int = 512,
                maximumBytes: Int = 128*1024*1024,
                supplyResource: (@Sendable (String) throws -> ScriptModuleReference)? = nil) throws {
        guard (1...512).contains(maximumModules), (1...128*1024*1024).contains(maximumBytes)
        else { throw ResourceError.rejected("module_repository_limits") }
        self.directory = directory; self.catalog = catalog; self.maximumModules = maximumModules; self.maximumBytes = maximumBytes
        self.supplyResource = supplyResource
    }

    mutating func attachRoot(_ program: ScriptProgram) throws -> ScriptProgram {
        let source = program.document.source
        guard let entry = catalog.reference(forPhysical: source.relativePath), entry.sourceSHA256 == source.sha256
        else { throw ResourceError.rejected("root_program_not_pinned_in_catalog") }
        if program.document.records.contains(where: { $0.kind == .include }) { return try load(entry.logicalPath) }
        try store(program); return program
    }

    private mutating func store(_ program: ScriptProgram) throws {
        let key = Data(program.document.source.relativePath.utf8)
        if cache[key] != nil { return }
        let instructionCount = program.document.records.count
        guard instructionCount <= 400_000
        else { throw ResourceError.rejected("module_instruction_cache_limit") }
        if dataCache[key] == nil {
            guard dataCache.count < maximumModules, program.document.source.data.count <= maximumBytes - snapshotBytes
            else { throw ResourceError.rejected("module_snapshot_budget") }
            snapshotBytes += program.document.source.data.count; dataCache[key] = program.document.source.data
        }
        // Active calls keep their program values in frames. Eviction only drops
        // reusable parsed entries and preserves the pinned source snapshots.
        while instructionCount > 400_000 - cachedInstructionCount {
            let evicted = cacheOrder.removeFirst()
            if let previous = cache.removeValue(forKey: evicted) {
                cachedInstructionCount -= previous.document.records.count
            }
        }
        cache[key] = program
        cacheOrder.append(key)
        cachedInstructionCount += instructionCount
    }

    static func vorbisLocation(_ reference: ScriptModuleReference, data: Data) throws -> ScriptLocation {
        try ScriptMovieHeader.validateVorbis(data)
        return ScriptLocation(sourceFile: reference.sourceFile, sourceSHA256: reference.sourceSHA256,
                              byteOffset: 0, byteLength: data.count, rangeSHA256: reference.sourceSHA256, lineNumber: 1)
    }

    private mutating func resolveResource(_ logical: String) throws -> ScriptModuleReference {
        pendingVariants = try catalog.variants(for: logical)
        let logicalKey = try ScriptModuleCatalog.key(logical)
        let entry: ScriptModuleReference
        if let supplied = suppliedResources[logicalKey] {
            entry = supplied
        } else if pendingVariants.isEmpty, try catalog.isIndexed(logical), let supplyResource {
            guard suppliedResources.count < 50_000 else { throw ResourceError.rejected("supplied_resource_count_limit") }
            entry = try supplyResource(logical)
            guard try ScriptModuleCatalog.key(entry.logicalPath) == logicalKey,
                  catalog.reference(forPhysical: entry.sourceFile).map({ $0 == entry }) ?? true else {
                throw ResourceError.rejected("supplied_resource_identity")
            }
        } else {
            if pendingVariants.isEmpty { try catalog.requireResourceCopyIfIndexed(logical) }
            entry = try catalog.resolve(logical)
        }
        return entry
    }

    public mutating func readResource(_ logical: String, byteLimit: Int = 32 * 1024 * 1024) throws -> (ScriptModuleReference, Data) {
        let entry = try resolveResource(logical)
        let logicalKey = try ScriptModuleCatalog.key(logical)
        let key = Data(entry.sourceFile.utf8)
        if let data = dataCache[key] {
            guard data.count <= byteLimit else { throw ResourceError.rejected("resource_read_byte_limit") }
            return (entry, data)
        }
        let foldedPath = asciiLower(entry.sourceFile)
        let data = try directory.read(entry.sourceFile, limit: min(byteLimit, foldedPath.hasSuffix(".b") ? 32*1024*1024 : 16*1024*1024))
        guard data.sha256Hex == entry.sourceSHA256 else { throw ResourceError.rejected("module_source_identity") }
        if pendingVariants.isEmpty { suppliedResources[logicalKey] = entry }
        let media = [".png", ".jpg", ".jpeg", ".ogg", ".ogv", ".wav", ".b"].contains {
            foldedPath.hasSuffix($0)
        }
        if media { return (entry,data) }
        guard dataCache.count < maximumModules else { throw ResourceError.rejected("module_snapshot_budget") }
        guard data.count <= maximumBytes - snapshotBytes else { throw ResourceError.rejected("module_snapshot_budget") }
        snapshotBytes += data.count; dataCache[key] = data
        return (entry,data)
    }

    mutating func movieLocation(_ logical: String) throws -> (location: ScriptLocation, size: (Int32, Int32)) {
        let reference = try resolveResource(logical)
        let movie = try directory.withFile(reference.sourceFile) { fd, size in
            let digest = try SafeDirectory.movieSHA256(fd: fd, size: size)
            guard digest == reference.sourceSHA256 else {
                throw ResourceError.rejected("movie_source_identity")
            }
            let header = try SafeDirectory.read(fd: fd, offset: 0, count: Int(min(size, 1024*1024)))
            let (width, height) = try ScriptMovieHeader.theoraDimensions(header)
            guard (1...8192).contains(width), (1...8192).contains(height) else {
                throw ResourceError.rejected("theora_movie_dimensions")
            }
            let location = ScriptLocation(sourceFile: reference.sourceFile, sourceSHA256: digest,
                byteOffset: 0, byteLength: Int(size), rangeSHA256: digest, lineNumber: 1)
            return (location, (Int32(width), Int32(height)))
        }
        if pendingVariants.isEmpty { suppliedResources[try ScriptModuleCatalog.key(logical)] = reference }
        return movie
    }

    public mutating func load(_ logical: String) throws -> ScriptProgram {
        pendingVariants = try catalog.variants(for: logical)
        let entry = try catalog.resolve(logical), key = Data(entry.sourceFile.utf8)
        if let snapshot = cache[key] {
            cacheOrder.removeAll { $0 == key }
            cacheOrder.append(key)
            return snapshot
        }
        let (_,data) = try readResource(logical)
        let document = try ScriptDocument(data: data,relativePath: entry.sourceFile)
        let program: ScriptProgram
        if document.records.contains(where: { $0.kind == .include }) {
            var state = ScriptIncludeState()
            let records = try expand(entry,state: &state,depth: 0)
            program = try ScriptProgram(ScriptDocument(expandedSource: document.source,records: records),
                sources: state.sources,includesExpanded: true)
        } else { program = try ScriptProgram(document) }
        guard try directory.read(entry.sourceFile).sha256Hex == entry.sourceSHA256 else { throw ResourceError.rejected("module_source_changed_during_load") }
        try store(program); pendingVariants = []; return program
    }

    private mutating func expand(_ entry: ScriptModuleReference, state: inout ScriptIncludeState, depth: Int) throws -> [ScriptRecord] {
        guard depth < 16, state.visits < 100 else { throw ResourceError.rejected("include_depth_or_file_limit") }
        guard ContinuousClock.now < state.deadline else { throw ResourceError.rejected("include_expansion_time_limit") }
        let key = try ScriptModuleCatalog.key(entry.logicalPath)
        guard !state.active.contains(key) else { throw ResourceError.rejected("include_cycle_outside_profile") }
        state.visits += 1; state.seen.insert(key); state.active.insert(key)
        defer { state.active.remove(key) }
        let (_,data) = try readResource(entry.logicalPath)
        let document = try ScriptDocument(data: data,relativePath: entry.sourceFile)
        state.sources[Data(entry.sourceFile.utf8)] = document.source
        var output: [ScriptRecord] = []
        for record in document.records {
            guard !Task.isCancelled, ContinuousClock.now < state.deadline else { throw ResourceError.rejected("include_expansion_time_or_cancel_limit") }
            state.records += 1
            guard state.records <= 200_000 else { throw ResourceError.rejected("include_expanded_record_limit") }
            output.append(record)
            guard record.kind == .include else { continue }
            var path = (record.identifier ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            let once = path.hasPrefix("!")
            if once { path.removeFirst() }
            guard !path.isEmpty, !path.contains("//"), !path.contains("\"") else { throw ResourceError.rejected("include_path_shape_outside_profile") }
            let logical = try catalog.resourcePath(path,currentSourceFile: entry.sourceFile)
            pendingVariants = try catalog.variants(for: logical)
            let child = try catalog.resolve(logical), childKey = try ScriptModuleCatalog.key(child.logicalPath)
            guard childKey != key else { throw ResourceError.rejected("direct_self_include") }
            if once, state.seen.contains(childKey) { continue }
            output += try expand(child,state: &state,depth: depth+1)
        }
        return output
    }
}
