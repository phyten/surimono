import AppKit
import Darwin

/// Files are placed only below the folder selected by the reader; creating the folder reserves its name atomically.
enum ExportFiles {
    static func newFolder(in parent: URL, name: String) throws -> URL {
        let name = name.isEmpty || name == "." || name == ".." ? "Document" : name
        for suffix in 1...10_000 {
            let folder = parent.appendingPathComponent(suffix == 1 ? name : "\(name) \(suffix)", isDirectory: true)
            if Darwin.mkdir(folder.path, 0o700) == 0 { return folder }
            guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    static func pageName(_ name: String, index: Int, count: Int) -> String {
        let digits = max(2, String(count).count)
        return name + "-" + String(format: "%0*d", digits, index + 1) + ".png"
    }
}
