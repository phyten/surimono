import AppKit
import Observation
import SurimonoCore

@Observable
final class UserLibrary {
    private(set) var themes: [PrintTheme] = []
    private(set) var presets: [HTMLCleanupPreset] = []
    private(set) var presetErrors: [HTMLCleanupPresetLoadError] = []
    private(set) var error: String?
    private(set) var revision = 0
    let root: URL

    init(root: URL? = nil) {
        self.root =
            root
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Surimono", isDirectory: true)
        reload()
    }

    func reload() {
        error = nil
        do {
            themes = try PrintThemeLibrary.load(userDirectory: root.appendingPathComponent("Styles"))
        } catch {
            self.error = error.localizedDescription
            // A broken user stylesheet must not hide the bundled themes.
            themes = (try? PrintThemeLibrary.load()) ?? []
        }
        do {
            let loaded = try HTMLCleanupPresetLibrary.load(userDirectory: root.appendingPathComponent("Presets"))
            presets = loaded.presets
            presetErrors = loaded.errors
        } catch {
            self.error = error.localizedDescription
            // A failed user directory must not prevent rendering unrelated document formats.
            presets = (try? HTMLCleanupPresetLibrary.load())?.presets ?? []
            presetErrors = []
        }
        revision += 1
    }

    func openFolder(_ name: String) {
        do {
            let url = root.appendingPathComponent(name, isDirectory: true)
            let isNew = !FileManager.default.fileExists(atPath: url.path)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            if name == "Presets", isNew {
                let example = HTMLCleanupPreset(
                    id: "user:example", name: "Example", localizedNames: ["ja": "見本"],
                    removeSelectors: ["nav", "aside"], extraCSS: "body { color: black; }")
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                var data = try encoder.encode(example)
                data.append(0x0A)
                try data.write(to: url.appendingPathComponent("example.json.sample"), options: .atomic)
            }
            if !NSWorkspace.shared.open(url) { throw CocoaError(.fileReadUnknown) }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
