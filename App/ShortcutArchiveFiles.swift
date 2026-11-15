import AppKit
import SurimonoCore
import UniformTypeIdentifiers

/// Panels are injectable; neither import nor cancellation registers keys or writes preferences.
@MainActor
struct ShortcutArchiveFiles {
    var open: (@escaping (URL?) -> Void) -> Void = { finish in
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { finish($0 == .OK ? panel.url : nil) }
    }
    var save: (@escaping (URL?) -> Void) -> Void = { finish in
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Surimono Shortcuts.json"
        panel.begin { finish($0 == .OK ? panel.url : nil) }
    }
    var protectedURLs: () -> [URL] = {
        DocumentWindows.shared.openModels.flatMap(\.protectedSourceURLs)
    }

    func importFile(completion: @escaping (Result<Data, any Error>?) -> Void) {
        open { url in
            guard let url else {
                completion(nil)
                return
            }
            completion(
                Result {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    let data = try handle.read(upToCount: ShortcutStore.maximumBytes + 1) ?? Data()
                    guard data.count <= ShortcutStore.maximumBytes else { throw ShortcutModelError.dataTooLarge }
                    return data
                })
        }
    }

    func exportFile(_ configuration: ShortcutConfiguration, completion: @escaping (Result<Void, any Error>?) -> Void) {
        let data: Data
        do { data = try ShortcutArchive(configuration: configuration).encode() } catch {
            completion(.failure(error))
            return
        }
        save { url in
            guard let url else {
                completion(nil)
                return
            }
            completion(
                Result {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    guard DocumentViewModel.canExport(to: url, sourceURLs: protectedURLs()) else {
                        throw CocoaError(.fileWriteNoPermission)
                    }
                    try data.write(to: url, options: .atomic)
                })
        }
    }

    static func message(_ error: any Error) -> String {
        if case ShortcutModelError.unsupportedVersion = error {
            return String(localized: "This shortcut file uses an unsupported version. Update Surimono to import it.")
        }
        if error is ShortcutModelError {
            return String(localized: "This shortcut file is invalid or exceeds the import limits. Nothing was changed.")
        }
        return String(localized: "The shortcut file could not be read or saved. Nothing was changed.")
    }
}
