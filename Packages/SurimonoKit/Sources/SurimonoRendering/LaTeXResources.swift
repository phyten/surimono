import Foundation
import SurimonoCore
import SurimonoFormats

extension DocumentRenderer {
    /// Every themed entry point (including exports and outline extraction) uses the same policy. Outside the
    /// sandbox, opening a document admits companion text under its directory, never arbitrary files on the Mac.
    nonisolated static func latexFragment(
        _ source: DocumentSource, textWidthPoints: Double?, access: LocalResourceAccess?,
        onDenied: @escaping () -> Void,
        imageExists: @escaping (URL) -> Bool
    ) throws -> HTMLFragment {
        let resources = LaTeXResources(source, access: access, onDenied: onDenied)
        return LaTeXConverter.convert(
            try decodedText(source.data), documentURL: resources.file, textWidthPoints: textWidthPoints,
            imageExists: { resources.permits($0) && imageExists($0) }, readFile: resources.read,
            modificationDate: { url in
                guard resources.permits(url) else { return nil }
                return try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            },
            fileIdentity: resources.identity)
    }

    /// Find the default style without laying out pages or converting the body. Includes in the preamble
    /// must see exactly the same files as the subsequent conversion, including after a folder grant.
    public func latexClassInfo(for source: DocumentSource) -> LaTeXDocumentClassInfo {
        let resources = LaTeXResources(source, access: resourceAccess(for: source), onDenied: {})
        return LaTeXConverter.documentClassInfo(
            TextDecoding.decode(source.data).text, documentURL: resources.file,
            readFile: resources.read, fileIdentity: resources.identity)
    }
}

private struct LaTeXResources {
    let file: URL?
    let access: LocalResourceAccess?
    let onDenied: () -> Void
    let roots: [String]

    init(_ source: DocumentSource, access: LocalResourceAccess?, onDenied: @escaping () -> Void) {
        self.access = access
        self.onDenied = onDenied
        let file = source.fileURL.flatMap { $0.isFileURL ? $0 : nil }
        self.file = file
        let folders = access?.folders ?? [file?.deletingLastPathComponent()].compactMap { $0 }
        roots = folders.compactMap { try? ConfinedFile.canonicalPath($0) }
    }

    func identity(_ url: URL) -> URL {
        permits(url) ? url.resolvingSymlinksInPath().standardizedFileURL : url.standardizedFileURL
    }

    func permits(_ url: URL) -> Bool {
        guard access?.permits(url) != false else {
            onDenied()
            return false
        }
        return url.isFileURL
    }

    func read(_ url: URL) -> Data? {
        guard permits(url) else { return nil }
        do {
            // Compare two real paths: Foundation can spell /private/var as /var on macOS.
            let canonical = try ConfinedFile.canonicalPath(url)
            guard let root = roots.first(where: { canonical.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }) else {
                if access != nil { onDenied() }
                return nil
            }
            // Validate the descriptor as well as the name: a changed symlink cannot redirect this read.
            return try ConfinedFile.read(url, within: root, maximumSize: 8_000_004)
        } catch let error as POSIXError where error.code == .EACCES || error.code == .EPERM {
            if access != nil { onDenied() }
            return nil
        } catch {
            return nil
        }
    }
}
