import Darwin
import Foundation

/// Reads a file only if what actually opens lies under a root. Checking a path first and reading it afterwards leaves
/// a gap in which a file or any folder on the way can be replaced by a link; a checked descriptor cannot be replaced.
public enum ConfinedFile {
    public static let defaultMaximumSize = 1 << 31

    public static func read(
        _ url: URL, within root: String, maximumSize: Int = defaultMaximumSize,
        afterValidation: (() throws -> Void)? = nil
    ) throws -> Data {
        let descriptor = try open(url)
        defer { Darwin.close(descriptor) }
        guard try openedPath(descriptor).hasPrefix(root.hasSuffix("/") ? root : root + "/") else {
            throw CocoaError(.fileReadNoPermission)
        }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0 else { throw posixError() }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0, info.st_size <= maximumSize else {
            throw CocoaError(.fileReadNoPermission)
        }
        try afterValidation?()
        return try readBytes(descriptor, size: Int(info.st_size), maximumSize: maximumSize)
    }

    /// Nonblocking, so that fstat can reject a FIFO without waiting for a writer.
    public static func open(_ url: URL) throws -> Int32 {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NONBLOCK) } ?? -1
        }
        guard descriptor >= 0 else { throw posixError() }
        return descriptor
    }

    public static func canonicalPath(_ url: URL) throws -> String {
        try url.withUnsafeFileSystemRepresentation { path in
            guard let path, let resolved = Darwin.realpath(path, nil) else { throw posixError() }
            defer { Darwin.free(resolved) }
            return String(cString: resolved)
        }
    }

    public static func openedPath(_ descriptor: Int32) throws -> String {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard Darwin.fcntl(descriptor, F_GETPATH, &path) == 0 else { throw posixError() }
        return try path.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress, let path = String(validatingCString: base) else {
                throw CocoaError(.fileReadNoPermission)
            }
            return path
        }
    }

    public static func readBytes(_ descriptor: Int32, size: Int, maximumSize: Int) throws -> Data {
        var data = Data()
        data.reserveCapacity(size)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            // A file can grow after fstat, so enforce the limit while reading as well.
            let count = Darwin.read(descriptor, &buffer, min(buffer.count, maximumSize - data.count + 1))
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError()
            }
            if count == 0 { return data }
            guard count <= maximumSize - data.count else { throw CocoaError(.fileReadTooLarge) }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    public static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
