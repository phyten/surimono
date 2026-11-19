import Foundation
import ImageIO
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
        let resources = CompanionTextResources(source, access: access, onDenied: onDenied)
        var measuredImages: [URL: CGSize] = [:]
        return LaTeXConverter.convert(
            try decodedText(source.data), documentURL: resources.file, textWidthPoints: textWidthPoints,
            imageExists: { resources.permits($0) && imageExists($0) },
            imageSizeInPoints: { url in
                if let cached = measuredImages[url] { return cached }
                let result = resources.read(url).flatMap(Self.imageSizeInPoints) ?? .zero
                measuredImages[url] = result
                return result
            }, readFile: resources.read,
            modificationDate: { url in
                guard resources.permits(url) else { return nil }
                return try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            },
            fileIdentity: resources.identity)
    }

    /// graphicx trims in big points before scaling to the requested output width.
    /// Inspect metadata through the same confined read as other companion files, without decoding pixels.
    nonisolated static func imageSizeInPoints(_ bytes: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Double,
            let height = properties[kCGImagePropertyPixelHeight] as? Double
        else { return nil }
        func dpi(_ key: CFString) -> Double {
            guard let value = properties[key] as? Double, value.isFinite, value > 0 else { return 72 }
            return value
        }
        let size = CGSize(
            width: width * 72 / dpi(kCGImagePropertyDPIWidth), height: height * 72 / dpi(kCGImagePropertyDPIHeight))
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return (5...8).contains(orientation) ? CGSize(width: size.height, height: size.width) : size
    }

    nonisolated static func markdownFragment(
        _ source: DocumentSource, pageBreakLine: String, proof: ProofMarks, mapsSource: Bool,
        access: LocalResourceAccess?, onDenied: @escaping () -> Void
    ) throws -> HTMLFragment {
        let text = try decodedText(source.data)
        let directory = source.fileURL.flatMap { $0.isFileURL ? $0.deletingLastPathComponent() : nil }
        // Ordinary Markdown never needs to resolve a resource root on disk.
        lazy var resources = CompanionTextResources(source, access: access, onDenied: {})
        func readBibliography(_ url: URL) -> Data? {
            let data = resources.read(url)
            if data == nil, access != nil { onDenied() }
            return data
        }
        if mapsSource {
            return MarkdownConverter.convertWithSourceMap(
                text, pageBreakLine: pageBreakLine, proof: proof, directory: directory, readFile: readBibliography
            ).fragment
        }
        return MarkdownConverter.convert(
            text, pageBreakLine: pageBreakLine, proof: proof, directory: directory, readFile: readBibliography)
    }

    /// Find the default style without laying out pages or converting the body. Includes in the preamble
    /// must see exactly the same files as the subsequent conversion, including after a folder grant.
    public func latexClassInfo(for source: DocumentSource) -> LaTeXDocumentClassInfo {
        let resources = CompanionTextResources(source, access: resourceAccess(for: source), onDenied: {})
        return LaTeXConverter.documentClassInfo(
            TextDecoding.decode(source.data).text, documentURL: resources.file,
            readFile: resources.read, fileIdentity: resources.identity)
    }
}

private struct CompanionTextResources {
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
