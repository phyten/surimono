import Foundation

public enum SandboxEnvironment {
    public static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }
}

public struct LocalResourceAccess: Equatable, Sendable {
    public let documentURL: URL
    public let folders: [URL]

    public init(documentURL: URL, folders: [URL] = []) {
        self.documentURL = documentURL
        self.folders = folders
    }

    public var documentFolder: URL { documentURL.deletingLastPathComponent() }

    public static func contains(_ file: URL, in folder: URL) -> Bool {
        guard file.isFileURL, folder.isFileURL else { return false }
        let root = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let path = file.standardizedFileURL.resolvingSymlinksInPath().path
        return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    public func permits(_ file: URL) -> Bool {
        guard file.isFileURL else { return false }
        let resolved = file.standardizedFileURL.resolvingSymlinksInPath()
        return resolved.path == documentURL.standardizedFileURL.resolvingSymlinksInPath().path
            || folders.contains { Self.contains(file, in: $0) }
    }
}
