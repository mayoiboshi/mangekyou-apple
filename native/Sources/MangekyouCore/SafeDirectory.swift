import Foundation
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
}
