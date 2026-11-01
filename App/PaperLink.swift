import AppKit
import SurimonoCore
import SurimonoRendering

enum PaperLinkAction: Equatable {
    case external, document, missingFile, unsupported

    static func resolve(_ url: URL, fileExists: Bool, isRegularFile: Bool, format: DocumentFormat?) -> Self {
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto": return .external
        case "file":
            guard fileExists else { return .missingFile }
            // A directory named like a document is still not something the viewer can read.
            return isRegularFile && format != nil ? .document : .unsupported
        default: return .unsupported
        }
    }
}

struct PaperLinkHandler {
    var isSandboxed: () -> Bool = { SandboxEnvironment.isSandboxed }
    var openExternal: (URL) async throws -> Void = { url in
        let configuration = NSWorkspace.OpenConfiguration()
        // Failures belong in the document's toast, not a LaunchServices error dialog.
        configuration.promptsUserIfNeeded = false
        _ = try await NSWorkspace.shared.open(url, configuration: configuration)
    }
    var openDocument: (URL) -> Void = { OpenRouter.shared.open([$0]) }

    func open(_ url: URL, onToast: (Toast) -> Void) async {
        let sandboxed = isSandboxed()
        let url = sandboxed ? (LocalResourceSchemeHandler.fileURL(for: url) ?? url) : url
        if sandboxed, url.isFileURL, !FileManager.default.isReadableFile(atPath: url.path) {
            onToast(
                Toast(
                    systemImage: "folder",
                    title: String(localized: "Allow folder access to display images and other resources"),
                    action: .allowFolderAccess))
            return
        }
        let exists = url.isFileURL && FileManager.default.fileExists(atPath: url.path)
        let file = url.isFileURL ? url.resolvingSymlinksInPath() : url
        let values = exists ? try? file.resourceValues(forKeys: [.isRegularFileKey]) : nil
        var format = DocumentFormat(fileExtension: url.pathExtension)
        // A failed LaunchServices lookup must not hide a readable file with a known extension.
        if exists, format == nil, let type = try? file.resourceValues(forKeys: [.contentTypeKey]).contentType {
            format = DocumentFormat(contentType: type)
        }
        let action = PaperLinkAction.resolve(
            url, fileExists: exists, isRegularFile: values?.isRegularFile == true, format: format)
        switch action {
        case .external:
            do {
                try await openExternal(url)
            } catch {
                onToast(cannotOpen(url))
            }
        case .document:
            openDocument(url)
        case .missingFile:
            onToast(
                Toast(
                    systemImage: "exclamationmark.triangle",
                    title: String(localized: "The linked file could not be found"),
                    detail: url.lastPathComponent))
        case .unsupported:
            onToast(cannotOpen(url))
        }
    }

    private func cannotOpen(_ url: URL) -> Toast {
        Toast(
            systemImage: "exclamationmark.triangle", title: String(localized: "This link cannot be opened"),
            detail: url.isFileURL ? url.lastPathComponent : url.absoluteString)
    }
}
