import AppKit
import SurimonoCore
import UniformTypeIdentifiers

extension DocumentViewModel {
    /// Text and images that opened from memory can become a file; a file that was opened stays as it is.
    var canSaveAsFile: Bool { memoryContent?.isEmpty == false }

    private var savedFileName: String {
        let name = displayName.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "/", with: "-")
        // A document named after a file, as one handed over by Shortcuts is, keeps that file's extension.
        if DocumentFormat(fileExtension: (name as NSString).pathExtension) == format { return name }
        return "\(name).\(ClipboardContent.fileExtension(of: memoryContent ?? Data(), format: format))"
    }

    /// Writes the document to a new file of the reader's choosing. The window goes on showing the same memory.
    func saveAsFile() {
        guard canSaveAsFile, let bytes = memoryContent else { return }
        let name = savedFileName
        let finish: (URL?) -> Void = { [weak self] url in
            if let url { self?.write(bytes, to: url) }
        }
        if let chooseSaveDestination { return chooseSaveDestination(name, finish) }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        if let type = UTType(filenameExtension: (name as NSString).pathExtension) {
            panel.allowedContentTypes = [type]
        }
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            finish(response == .OK ? panel.url : nil)
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func write(_ bytes: Data, to url: URL) {
        do {
            guard Self.canExport(to: url, sourceURLs: protectedSourceURLs) else {
                throw CocoaError(.fileWriteNoPermission)
            }
            try bytes.write(to: url, options: .atomic)
            showToast(
                Toast(
                    systemImage: "checkmark.circle",
                    title: String(format: String(localized: "Saved as %@"), url.lastPathComponent)))
        } catch {
            showToast(
                Toast(
                    systemImage: "exclamationmark.triangle",
                    title: String(localized: "The file could not be saved."),
                    detail: error.localizedDescription),
                dismissAfter: nil)
        }
    }
}
