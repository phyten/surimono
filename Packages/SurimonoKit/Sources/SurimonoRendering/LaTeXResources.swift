import Foundation
import ImageIO
import SurimonoCore
import SurimonoFormats

extension DocumentRenderer {
    /// Every themed entry point (including exports and outline extraction) uses the same policy. Outside the
    /// sandbox, opening a document admits companion text under its directory and under the folders the reader allowed
    /// (`allowedResourceFolders`), never arbitrary files on the Mac.
    nonisolated static func latexFragment(
        _ source: DocumentSource, composition: LaTeXComposition, textWidthPoints: Double?, access: LocalResourceAccess?,
        onDenied: @escaping @Sendable (URL) -> Void,
        imageExists: @escaping @Sendable (URL) -> Bool
    ) throws -> HTMLFragment {
        let resources = CompanionTextResources(source, access: access, onDenied: onDenied)
        // The callbacks run on the converter's own thread, while this one waits for it.
        let measuredImages = SharedValue<[URL: CGSize]>([:])
        var fragment = LaTeXConverter.convert(
            try decodedText(source.data), composition: composition, documentURL: resources.file,
            textWidthPoints: textWidthPoints,
            imageExists: { resources.permits($0) && imageExists($0) },
            canProbePictureFallback: { access?.permits($0) != false },
            imageSizeInPoints: { url in
                if let cached = measuredImages.value[url] { return cached }
                let result = resources.read(url).flatMap(Self.imageSizeInPoints) ?? .zero
                measuredImages.value[url] = result
                return result
            }, readFile: { resources.read($0) },
            modificationDate: { url in
                guard resources.permits(url) else { return nil }
                return try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            },
            fileIdentity: { resources.identity($0) })
        resources.markRefusedFiles(in: &fragment)
        return fragment
    }

    /// graphicx trims in big points before scaling to the requested output width.
    /// Inspect metadata through the same confined read as other companion files, without decoding pixels.
    nonisolated static func imageSizeInPoints(_ bytes: Data) -> CGSize? {
        // An SVG's CSS pixels are 96 to the inch, as the svg package's Inkscape export measures them.
        if let reading = SVGIntrinsicSize.read(bytes) {
            guard case .size(let shape) = reading else { return nil }
            return CGSize(width: shape.width * 0.75, height: shape.height * 0.75)
        }
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
        _ source: DocumentSource, pageBreakLine: String, proof: ProofMarks, mapsSource: Bool, contentsDepth: Int?,
        reading: FormatReadingSettings,
        access: LocalResourceAccess?, onDenied: @escaping @Sendable (URL) -> Void
    ) throws -> HTMLFragment {
        let text = try decodedText(source.data)
        let directory = source.fileURL.flatMap { $0.isFileURL ? $0.deletingLastPathComponent() : nil }
        // Ordinary Markdown never needs to resolve a resource root on disk, so the roots are found on first use, on
        // the converter's own thread.
        let resources = SharedValue<CompanionTextResources?>(nil)
        let readBibliography: @Sendable (URL) -> Data? = { url in
            let found = resources.value ?? CompanionTextResources(source, access: access, onDenied: onDenied)
            resources.value = found
            return found.read(url)
        }
        var fragment =
            mapsSource
            ? MarkdownConverter.convertWithSourceMap(
                text, pageBreakLine: pageBreakLine, proof: proof, contentsDepth: contentsDepth, reading: reading,
                directory: directory,
                readFile: readBibliography
            ).fragment
            : MarkdownConverter.convert(
                text, pageBreakLine: pageBreakLine, proof: proof, contentsDepth: contentsDepth, reading: reading,
                directory: directory,
                readFile: readBibliography)
        resources.value?.markRefusedFiles(in: &fragment)
        return fragment
    }

    /// Find the default style without laying out pages or converting the body. Includes in the preamble
    /// must see exactly the same files as the subsequent conversion, including after a folder grant.
    public func latexClassInfo(for source: DocumentSource, composition: LaTeXComposition = .document)
        -> LaTeXDocumentClassInfo
    {
        if cachedLaTeXInfo?.source != source { cachedLaTeXInfo = (source, [:]) }
        if let info = cachedLaTeXInfo?.infos[composition] { return info }
        let resources = CompanionTextResources(source, access: resourceAccess(for: source), onDenied: { _ in })
        let infos = LaTeXConverter.classInfos(
            TextDecoding.decode(source.data, preservingLineEndings: true).text, composition: composition,
            documentURL: resources.file, readFile: { resources.read($0) }, fileIdentity: { resources.identity($0) })
        cachedLaTeXInfo?.infos.merge(infos.related) { _, new in new }
        cachedLaTeXInfo?.infos[composition] = infos.requested
        return infos.requested
    }
}

/// Reads the text a document names (bibliographies, inputs, listings) from the folders it may read: the folders the
/// reader allowed and, outside the sandbox, where opening the document already lets the app read, its own folder.
/// A file outside them is refused, and can be read once a folder that contains it is allowed. A file that is not
/// there is only missing: no folder would help it.
private struct CompanionTextResources: Sendable {
    /// `refused`: outside the folders the document may read, which a folder grant answers. `denied`: the system's
    /// own file permissions, which no grant changes.
    enum Failure: Error { case refused, denied, missing, other }

    let file: URL?
    let access: LocalResourceAccess?
    let onDenied: @Sendable (URL) -> Void
    let roots: [String]
    /// Why each read failed, kept until the reader says which named files it could not read in the end.
    let failures = SharedValue<[URL: Failure]>([:])

    init(_ source: DocumentSource, access: LocalResourceAccess?, onDenied: @escaping @Sendable (URL) -> Void) {
        self.access = access
        self.onDenied = onDenied
        let file = source.fileURL.flatMap { $0.isFileURL ? $0 : nil }
        self.file = file
        let ownFolder = access == nil ? [file?.deletingLastPathComponent()].compactMap { $0 } : []
        let folders = ownFolder + (access?.folders ?? source.allowedResourceFolders)
        roots = folders.compactMap { try? ConfinedFile.canonicalPath($0) }
    }

    func identity(_ url: URL) -> URL {
        permits(url) ? url.resolvingSymlinksInPath().standardizedFileURL : url.standardizedFileURL
    }

    func permits(_ url: URL) -> Bool {
        guard access?.permits(url) != false else {
            onDenied(url)
            return false
        }
        return url.isFileURL
    }

    func read(_ url: URL) -> Data? {
        switch contents(of: url) {
        case .success(let data): return data
        case .failure(let failure):
            failures.value[url] = failure
            // Inside the sandbox every refusal asks for the folder at once, as images do. Outside it only a named
            // file the reader could not find anywhere else does (`markRefusedFiles`).
            if failure == .refused, access != nil { onDenied(url) }
            return nil
        }
    }

    private func contents(of url: URL) -> Result<Data, Failure> {
        // Inside the sandbox a place outside the grant cannot even be looked at, so it is refused, not missing.
        guard access?.permits(url) != false else { return .failure(.refused) }
        guard url.isFileURL else { return .failure(.other) }
        do {
            // Compare two real paths: Foundation can spell /private/var as /var on macOS.
            let canonical = try ConfinedFile.canonicalPath(url)
            guard let root = roots.first(where: { canonical.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }) else {
                return .failure(.refused)
            }
            // Validate the descriptor as well as the name: a changed symlink cannot redirect this read.
            return .success(try ConfinedFile.read(url, within: root, maximumSize: 8_000_004))
        } catch let error as POSIXError where error.code == .EACCES || error.code == .EPERM {
            // Inside the sandbox this is the sandbox refusing a place it was not given, which a grant answers.
            return .failure(access == nil ? .denied : .refused)
        } catch let error as POSIXError where error.code == .ENOENT || error.code == .ENOTDIR {
            return .failure(.missing)
        } catch {
            return .failure(.other)
        }
    }

    /// Marks each named file the reader could not read in the end with the place it was refused, and asks for a
    /// folder for it. A file found in a later place, or missing from every place, asks for nothing.
    func markRefusedFiles(in fragment: inout HTMLFragment) {
        let failures = failures.value
        for index in fragment.unreadFiles.indices {
            guard let url = fragment.unreadFiles[index].candidates.first(where: { failures[$0] == .refused })
            else { continue }
            fragment.unreadFiles[index].refusedURL = url
            onDenied(url)
        }
    }
}

/// A value that converter callbacks change on the converter's own thread while the caller waits.
final class SharedValue<Value>: @unchecked Sendable {
    // Every access goes through `lock`.
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// A flag that converter callbacks set on the converter's own thread.
final class LockedFlag: Sendable {
    private let flag = SharedValue(false)
    func set() { flag.value = true }
    var isSet: Bool { flag.value }
}
