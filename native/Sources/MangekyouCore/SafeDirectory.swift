import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum ResourceError: Error, CustomStringConvertible, Sendable {
    case rejected(String)
    case system(String, Int32)
    public var description: String {
        switch self {
        case .rejected(let reason): return reason
        case .system(let operation, let code): return "\(operation): errno \(code)"
        }
    }
}

public struct DirectoryEntry: Sendable {
    public enum Kind: Sendable { case regular, directory, symbolicLink, other }
    public let name: String
    public let kind: Kind
    public let size: Int64
}

/// Each traversal opens components with O_NOFOLLOW. No write descriptor is exposed.
public struct SafeDirectory: Sendable {
    package struct AtomicReplacementReceipt: Sendable {
        package let directorySyncError: Int32?
        package let cleanupIssue: String?

        package init(directorySyncError: Int32?, cleanupIssue: String? = nil) {
            self.directorySyncError = directorySyncError
            self.cleanupIssue = cleanupIssue
        }
    }
    package enum AtomicDestinationExpectation: Sendable {
        case absent
        case sha256(String)
    }

    public let root: URL
    public init(_ root: URL) throws {
        guard root.isFileURL, root.path.hasPrefix("/"),
              !root.pathComponents.contains("..") else { throw ResourceError.rejected("invalid_root") }
        self.root = root
        let fd = try openPath([], directory: true)
        close(fd)
    }

    public static func components(_ relative: String, allowEmpty: Bool = false) throws -> [String] {
        if relative.isEmpty && allowEmpty { return [] }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !relative.isEmpty, !relative.contains("\\"), !relative.contains("\0"),
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains(":") })
        else { throw ResourceError.rejected("unsafe_relative_path") }
        return parts
    }

    private func openPath(_ tail: [String], directory: Bool) throws -> Int32 {
        let base = root.path.split(separator: "/").map(String.init)
        guard !base.contains("."), !base.contains("..") else { throw ResourceError.rejected("unsafe_root_component") }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw ResourceError.system("open_root", errno) }
        do {
            let parts = base + tail
            for (index, part) in parts.enumerated() {
                let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK |
                    ((index < parts.count - 1 || directory) ? O_DIRECTORY : 0)
                let next = part.withCString { openat(fd, $0, flags) }
                guard next >= 0 else { throw ResourceError.system("open_component", errno) }
                close(fd); fd = next
            }
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw ResourceError.system("file_stat", errno) }
            let expected = directory ? S_IFDIR : S_IFREG
            guard (info.st_mode & S_IFMT) == expected else { throw ResourceError.rejected("not_expected_file_kind") }
            return fd
        } catch { close(fd); throw error }
    }

    public func entries(in relative: String = "") throws -> [DirectoryEntry] {
        let fd = try openPath(Self.components(relative, allowEmpty: true), directory: true)
        guard let stream = fdopendir(fd) else { let code = errno; close(fd); throw ResourceError.system("directory_stream", code) }
        defer { closedir(stream) }
        var result: [DirectoryEntry] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw ResourceError.system("read_directory", errno) }
                break
            }
            let capacity = MemoryLayout.size(ofValue: entry.pointee.d_name)
            let name: String? = withUnsafePointer(to: &entry.pointee.d_name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: capacity) { String(validatingCString: $0) }
            }
            guard let name else { throw ResourceError.rejected("invalid_utf8_file_name") }
            if name == "." || name == ".." { continue }
            _ = try Self.components(name)
            var info = stat()
            guard name.withCString({ fstatat(fd, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0
            else { throw ResourceError.system("entry_stat", errno) }
            let kind: DirectoryEntry.Kind
            switch info.st_mode & S_IFMT {
            case S_IFREG: kind = .regular
            case S_IFDIR: kind = .directory
            case S_IFLNK: kind = .symbolicLink
            default: kind = .other
            }
            result.append(DirectoryEntry(name: name, kind: kind, size: Int64(info.st_size)))
            if result.count > 20_000 { throw ResourceError.rejected("directory_entry_limit") }
        }
        return result.sorted { $0.name < $1.name }
    }

    public func withFile<T>(_ relative: String, _ body: (Int32, Int64) throws -> T) throws -> T {
        let fd = try openPath(Self.components(relative), directory: false)
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size >= 0 else { throw ResourceError.system("file_size", errno) }
        return try body(fd, Int64(info.st_size))
    }

    public static func movieSHA256(fd: Int32, size: Int64) throws -> String {
        guard size > 0, size <= 192*1024*1024 else { throw ResourceError.rejected("movie_size_limit") }
        var digest = SHA256()
        var offset: Int64 = 0
        while offset < size {
            try Task.checkCancellation()
            let count = Int(min(1024*1024, size-offset))
            digest.update(data: try read(fd: fd, offset: offset, count: count))
            offset += Int64(count)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func read(fd: Int32, offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, count >= 0, count <= 64 * 1024 * 1024,
              offset <= Int64.max - Int64(count) else { throw ResourceError.rejected("read_limit") }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { raw in
            var done = 0
            while done < count {
                let length = pread(fd, raw.baseAddress!.advanced(by: done), count - done, off_t(offset + Int64(done)))
                if length < 0 && errno == EINTR { continue }
                guard length > 0 else { throw ResourceError.rejected("short_or_failed_read") }
                done += length
            }
        }
        return data
    }

    public func read(_ relative: String, limit: Int = 16 * 1024 * 1024) throws -> Data {
        guard limit >= 0, limit <= 64 * 1024 * 1024 else { throw ResourceError.rejected("file_limit") }
        return try withFile(relative) { fd, size in
            guard size <= Int64(limit) else { throw ResourceError.rejected("file_size_limit") }
            return try Self.read(fd: fd, offset: 0, count: Int(size))
        }
    }

    func readIfPresent(_ name: String, limit: Int) throws -> Data? {
        guard try Self.components(name).count == 1 else {
            throw ResourceError.rejected("unsafe_relative_path")
        }
        do { return try read(name, limit: limit) }
        catch ResourceError.system("open_component", ENOENT) { return nil }
    }

    func withExclusiveSaveAccess<T>(_ body: () throws -> T) throws -> T {
        let directory = try openPath([], directory: true)
        defer { close(directory) }
        var result: Int32
        repeat { result = flock(directory, LOCK_EX | LOCK_NB) } while result < 0 && errno == EINTR
        guard result == 0 else {
            if errno == EWOULDBLOCK { throw ResourceError.rejected("save_directory_busy") }
            throw ResourceError.system("lock_save_directory", errno)
        }
        return try body()
    }

    func syncSaveDirectory() throws {
        let directory = try openPath([], directory: true)
        defer { close(directory) }
        if let error = Self.syncDirectory(directory) {
            throw ResourceError.system("sync_save_directory", error)
        }
    }

    // Allow the bounded save journal to carry a full-sized save and its metadata.
    static let maximumAtomicReplacementBytes = 16 * 1024 * 1024 + 4096

    private static func syncDirectory(_ fd: Int32) -> Int32? {
        var result: Int32
        repeat { result = fsync(fd) } while result < 0 && errno == EINTR
        return result == 0 ? nil : errno
    }

    /// Create a new bounded research output without replacing an existing entry.
    package func writeNew(_ name: String, data: Data, limit: Int = 16 * 1024 * 1024) throws {
        guard try Self.components(name).count == 1, data.count <= limit, limit <= 16 * 1024 * 1024 else {
            throw ResourceError.rejected("research_output_bounds")
        }
        let directory = try openPath([], directory: true)
        defer { close(directory) }
        let fd = name.withCString { openat(directory, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) }
        guard fd >= 0 else { throw ResourceError.system("create_research_output", errno) }
        var complete = false
        defer {
            close(fd)
            if !complete { _ = name.withCString { unlinkat(directory, $0, 0) } }
        }
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = write(fd, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ResourceError.system("write_research_output", errno) }
                written += count
            }
        }
        guard fsync(fd) == 0 else { throw ResourceError.system("sync_research_output", errno) }
        complete = true
    }

    /// Publish one verified file without exposing its partially written contents.
    /// This does not guarantee directory durability after a system crash.
    package func writeNewAtomically(_ name: String, data: Data, limit: Int = 16 * 1024 * 1024) throws {
        guard try Self.components(name).count == 1, limit >= 0, data.count <= limit,
              limit <= 16 * 1024 * 1024 else { throw ResourceError.rejected("research_output_bounds") }
        let directory = try openPath([], directory: true)
        defer { close(directory) }
        let temporary = ".mangekyou-stage-" + UUID().uuidString
        guard temporary != name else { throw ResourceError.rejected("research_output_temporary_collision") }
        let fd = temporary.withCString { openat(directory, $0, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) }
        guard fd >= 0 else { throw ResourceError.system("create_research_staging", errno) }
        defer {
            close(fd)
            _ = temporary.withCString { unlinkat(directory, $0, 0) }
        }
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = write(fd, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ResourceError.system("write_research_staging", errno) }
                written += count
            }
        }
        guard fsync(fd) == 0 else { throw ResourceError.system("sync_research_staging", errno) }
        var descriptorInfo = stat(), pathInfo = stat()
        guard fstat(fd, &descriptorInfo) == 0,
              temporary.withCString({ fstatat(directory, $0, &pathInfo, AT_SYMLINK_NOFOLLOW) }) == 0,
              descriptorInfo.st_dev == pathInfo.st_dev, descriptorInfo.st_ino == pathInfo.st_ino,
              (pathInfo.st_mode & S_IFMT) == S_IFREG, descriptorInfo.st_size == Int64(data.count),
              try Self.read(fd: fd, offset: 0, count: data.count).sha256Hex == data.sha256Hex else {
            throw ResourceError.rejected("research_staging_verification_failed")
        }
        let linked = temporary.withCString { source in
            name.withCString { destination in linkat(directory, source, directory, destination, 0) }
        }
        guard linked == 0 else { throw ResourceError.system("publish_research_output", errno) }
    }

    /// Atomically publish a complete replacement of one regular file. Any
    /// failure before rename leaves the previous slot untouched. The staged
    /// file is synced before rename and the containing directory is synced
    /// after rename so the name update is included in the durability request.
    /// The package-scoped hooks model interruption immediately before and
    /// after publication in tests; production callers omit them.
    /// A non-nil directorySyncError means rename already published the complete
    /// replacement, but syncing the containing directory failed; durability is
    /// uncertain and the new file is visible to this process.
    @discardableResult
    package func replaceAtomically(_ name: String, data: Data, limit: Int = 16 * 1024 * 1024,
                                   expectedDestination: AtomicDestinationExpectation? = nil,
                                   beforePublish: (() throws -> Void)? = nil,
                                   afterPublish: (() throws -> Void)? = nil,
                                   directorySyncErrorForTesting: ((Int32) -> Int32?)? = nil)
        throws -> AtomicReplacementReceipt {
        guard try Self.components(name).count == 1, limit >= 0, data.count <= limit,
              limit <= Self.maximumAtomicReplacementBytes else { throw ResourceError.rejected("atomic_replace_bounds") }
        let directory = try openPath([], directory: true)
        defer { close(directory) }
        var existing = stat()
        let lookup = name.withCString { fstatat(directory, $0, &existing, AT_SYMLINK_NOFOLLOW) }
        if lookup == 0 {
            guard (existing.st_mode & S_IFMT) == S_IFREG else {
                throw ResourceError.rejected("atomic_replace_target_not_regular")
            }
        } else if errno != ENOENT {
            throw ResourceError.system("atomic_replace_target_check", errno)
        }

        let temporary = ".mangekyou-stage-" + UUID().uuidString
        let fd = temporary.withCString { openat(directory, $0, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) }
        guard fd >= 0 else { throw ResourceError.system("create_atomic_replacement", errno) }
        defer {
            close(fd)
            _ = temporary.withCString { unlinkat(directory, $0, 0) }
        }
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = write(fd, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ResourceError.system("write_atomic_replacement", errno) }
                written += count
            }
        }
        guard fsync(fd) == 0 else { throw ResourceError.system("sync_atomic_replacement", errno) }
        var descriptorInfo = stat(), pathInfo = stat()
        guard fstat(fd, &descriptorInfo) == 0,
              temporary.withCString({ fstatat(directory, $0, &pathInfo, AT_SYMLINK_NOFOLLOW) }) == 0,
              descriptorInfo.st_dev == pathInfo.st_dev, descriptorInfo.st_ino == pathInfo.st_ino,
              (pathInfo.st_mode & S_IFMT) == S_IFREG, descriptorInfo.st_size == Int64(data.count),
              try Self.read(fd: fd, offset: 0, count: data.count).sha256Hex == data.sha256Hex else {
            throw ResourceError.rejected("atomic_replacement_verification_failed")
        }
        try beforePublish?()
        // This narrows ordinary races but is not an atomic compare-and-swap:
        // a non-cooperating writer can still replace the path before renameat.
        if case .some(.sha256(let expected)) = expectedDestination {
            try Self.requireMatchingFile(name, in: directory, sha256: expected, limit: limit)
        }
        let publish: Int32 = temporary.withCString { source in
            name.withCString { destination in
                if case .some(.absent) = expectedDestination {
                    return linkat(directory, source, directory, destination, 0)
                }
                return renameat(directory, source, directory, destination)
            }
        }
        guard publish == 0 else {
            if case .some(.absent) = expectedDestination, errno == EEXIST {
                throw ResourceError.rejected("atomic_replace_destination_changed")
            }
            throw ResourceError.system("publish_atomic_replacement", errno)
        }
        if case .some(.absent) = expectedDestination {
            _ = temporary.withCString { unlinkat(directory, $0, 0) }
        }
        let directorySyncError: Int32?
        if let directorySyncErrorForTesting {
            directorySyncError = directorySyncErrorForTesting(directory)
        } else {
            directorySyncError = Self.syncDirectory(directory)
        }
        try afterPublish?()
        return AtomicReplacementReceipt(directorySyncError: directorySyncError)
    }

    /// Roll back a file created by the current operation after verifying it.
    func removeCreatedFile(_ name: String, sha256: String, limit: Int) throws {
        if let error = try removeMatchingFile(name, sha256: sha256, limit: limit) {
            throw ResourceError.system("sync_created_file_removal", error)
        }
    }

    /// Return a sync error separately once the directory entry has been removed.
    func removeMatchingFile(_ name: String, sha256: String, limit: Int) throws -> Int32? {
        guard try Self.components(name).count == 1, (0...Self.maximumAtomicReplacementBytes).contains(limit) else {
            throw ResourceError.rejected("atomic_replace_bounds")
        }
        let directory = try openPath([], directory: true)
        defer { close(directory) }
        try Self.requireMatchingFile(name, in: directory, sha256: sha256, limit: limit)
        guard name.withCString({ unlinkat(directory, $0, 0) }) == 0 else {
            throw ResourceError.system("remove_created_file", errno)
        }
        return Self.syncDirectory(directory)
    }

    private static func requireMatchingFile(_ name: String, in directory: Int32, sha256: String, limit: Int) throws {
        let targetFD = name.withCString { openat(directory, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
        guard targetFD >= 0 else { throw ResourceError.rejected("atomic_replace_destination_changed") }
        defer { close(targetFD) }
        var descriptor = stat(), path = stat()
        guard fstat(targetFD, &descriptor) == 0, (descriptor.st_mode & S_IFMT) == S_IFREG,
              descriptor.st_size >= 0, descriptor.st_size <= limit,
              name.withCString({ fstatat(directory, $0, &path, AT_SYMLINK_NOFOLLOW) }) == 0,
              descriptor.st_dev == path.st_dev, descriptor.st_ino == path.st_ino,
              try read(fd: targetFD, offset: 0, count: Int(descriptor.st_size)).sha256Hex == sha256,
              name.withCString({ fstatat(directory, $0, &path, AT_SYMLINK_NOFOLLOW) }) == 0,
              descriptor.st_dev == path.st_dev, descriptor.st_ino == path.st_ino else {
            throw ResourceError.rejected("atomic_replace_destination_changed")
        }
    }
}
