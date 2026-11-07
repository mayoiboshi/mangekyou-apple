import Foundation

public enum EvidenceStatus: String, Codable, Sendable { case verified, inferred, unsupported, notTested = "not_tested" }

public struct PackFooter: Encodable, Sendable {
    public let version: String
    public let declaredEntries: UInt32
    public let tableOffset: UInt64
    public let indexStatus: EvidenceStatus = .notTested

    public static func probe(_ tail: Data, fileSize: Int64) throws -> Self {
        guard fileSize >= 28, tail.count == 28 else { throw ResourceError.rejected("short_pack_footer") }
        let signature = tail.prefix(16).prefix(while: { $0 != 0 })
        guard let version = String(data: signature, encoding: .ascii),
              ["FilePackVer1.0", "FilePackVer2.0", "FilePackVer3.0", "FilePackVer3.1"].contains(version)
        else { throw ResourceError.rejected("unknown_pack_footer") }
        let count = try tail.u32(16)
        let offset = UInt64(try tail.u32(20)) | UInt64(try tail.u32(24)) << 32
        guard count <= 100_000, offset < UInt64(fileSize - 28),
              UInt64(fileSize - 28) - offset <= 32 * 1024 * 1024
        else { throw ResourceError.rejected("pack_index_bounds") }
        return Self(version: version, declaredEntries: count, tableOffset: offset)
    }
}

public struct ResourceEntry: Encodable, Identifiable, Sendable {
    public var id: String { relativePath }
    public let relativePath: String
    public let byteCount: Int64
    public let format: String
    public let status: EvidenceStatus
    public let pack: PackFooter?
    public let issue: String?
}

public struct Inventory: Encodable, Sendable {
    public let schemaVersion = 1
    public let scope = "Read-only file signatures and PACK footers; index, scripts and game execution are not tested"
    public let files: [ResourceEntry]
    public let totalBytes: Int64
    public let issues: [String]
    public let gameExecution: EvidenceStatus = .notTested
    public let originalFilesWritten = false
    public let externalUploads = false
    public var archives: [ResourceEntry] { files.filter { $0.pack != nil } }
}

public struct InventoryScanner: Sendable {
    public let maximumFiles: Int
    public let maximumDepth: Int
    public init(maximumFiles: Int = 20_000, maximumDepth: Int = 16) {
        self.maximumFiles = maximumFiles; self.maximumDepth = maximumDepth
    }
    public func scan(_ directory: SafeDirectory) throws -> Inventory {
        guard (1...20_000).contains(maximumFiles), (0...32).contains(maximumDepth)
        else { throw ResourceError.rejected("inventory_limits") }
        var files: [ResourceEntry] = [], issues: [String] = [], total: Int64 = 0
        var pending: [(String, Int)] = [("", 0)], visited = 0
        let deadline = Date().addingTimeInterval(30)
        while let (path, depth) = pending.popLast() {
            guard Date() < deadline else { throw ResourceError.rejected("inventory_time_limit") }
            for entry in try directory.entries(in: path) {
                visited += 1
                guard visited <= maximumFiles else { throw ResourceError.rejected("inventory_entry_limit") }
                let relative = path.isEmpty ? entry.name : path + "/" + entry.name
                if entry.kind == .directory {
                    if depth < maximumDepth { pending.append((relative, depth + 1)) }
                    else { issues.append(relative + ": directory_depth_limit") }
                    continue
                }
                if entry.kind != .regular {
                    issues.append(relative + ": " + (entry.kind == .symbolicLink ? "symlink_refused" : "non_regular_refused"))
                    continue
                }
                let sum = total.addingReportingOverflow(entry.size)
                guard !sum.overflow, entry.size >= 0 else { throw ResourceError.rejected("inventory_size_overflow") }
                total = sum.partialValue
                do {
                    files.append(try directory.withFile(relative) { fd, size in
                        guard size == entry.size else { throw ResourceError.rejected("file_changed_during_scan") }
                        let prefix = try SafeDirectory.read(fd: fd, offset: 0, count: Int(min(size, 64)))
                        var pack: PackFooter?
                        if relative.lowercased().hasSuffix(".pack") {
                            let tail = try SafeDirectory.read(fd: fd, offset: max(0, size - 28), count: Int(min(size, 28)))
                            pack = try PackFooter.probe(tail, fileSize: size)
                        }
                        let format = pack?.version ?? Self.signature(prefix)
                        return ResourceEntry(relativePath: relative, byteCount: size, format: format,
                            status: format == "Unknown" ? .unsupported : .verified, pack: pack, issue: nil)
                    })
                } catch {
                    files.append(ResourceEntry(relativePath: relative, byteCount: entry.size, format: "Unknown",
                        status: .unsupported, pack: nil, issue: String(describing: error)))
                    issues.append(relative + ": " + String(describing: error))
                }
            }
        }
        return Inventory(files: files.sorted { $0.relativePath < $1.relativePath }, totalBytes: total, issues: issues)
    }

    public static func signature(_ data: Data) -> String {
        if data.starts(with: [0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a]) { return "PNG" }
        if data.starts(with: Array("DPNG".utf8)) { return "DPNG" }
        if data.starts(with: [0xff,0xd8,0xff]) { return "JPEG" }
        if data.starts(with: Array("OggS".utf8)) { return "Ogg" }
        if data.starts(with: Array("RIFF".utf8)), data.count >= 12,
            data.subdata(in: 8..<12) == Data("WAVE".utf8) { return "WAV" }
        if data.starts(with: Array("abmp".utf8)) { return "ABMP-candidate" }
        if data.starts(with: Array("MZ".utf8)) { return "PE-candidate" }
        if data.starts(with: [0xff,0xfe]) { return "UTF16LE-candidate" }
        if data.starts(with: [0xfe,0xff]) { return "UTF16BE-candidate" }
        if data.starts(with: [0xef,0xbb,0xbf]) { return "UTF8-BOM-candidate" }
        return "Unknown"
    }
}

extension Data {
    public func u32(_ offset: Int) throws -> UInt32 {
        guard offset >= 0, count >= 4, offset <= count - 4 else { throw ResourceError.rejected("integer_out_of_bounds") }
        return (0..<4).reduce(0) { $0 | UInt32(self[startIndex + offset + $1]) << (8 * $1) }
    }
}
