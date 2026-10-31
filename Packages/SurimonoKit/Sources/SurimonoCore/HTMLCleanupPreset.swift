import Foundation

public struct HTMLCleanupPreset: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var localizedNames: [String: String]
    public var removeSelectors: [String]
    public var keepSelectors: [String]
    public var extraCSS: String
    public var disablesJavaScript: Bool
    public internal(set) var isBuiltIn = false

    public init(
        id: String, name: String, localizedNames: [String: String] = [:], removeSelectors: [String] = [],
        keepSelectors: [String] = [], extraCSS: String = "", disablesJavaScript: Bool = false
    ) {
        self.id = id
        self.name = name
        self.localizedNames = localizedNames
        self.removeSelectors = removeSelectors
        self.keepSelectors = keepSelectors
        self.extraCSS = extraCSS
        self.disablesJavaScript = disablesJavaScript
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, localizedNames, removeSelectors, keepSelectors, extraCSS, disablesJavaScript
    }

    private enum LegacyKeys: String, CodingKey { case ja }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        localizedNames = try values.decodeIfPresent([String: String].self, forKey: .localizedNames) ?? [:]
        if let japanese = try legacy.decodeIfPresent(String.self, forKey: .ja), localizedNames["ja"] == nil {
            localizedNames["ja"] = japanese
        }
        removeSelectors = try values.decodeIfPresent([String].self, forKey: .removeSelectors) ?? []
        keepSelectors = try values.decodeIfPresent([String].self, forKey: .keepSelectors) ?? []
        extraCSS = try values.decodeIfPresent(String.self, forKey: .extraCSS) ?? ""
        disablesJavaScript = try values.decodeIfPresent(Bool.self, forKey: .disablesJavaScript) ?? false
    }

    public func displayName(language: String = "en") -> String {
        UILanguage.name(localizedNames, language: language, english: name)
    }
}

public struct HTMLCleanupPresetLoadError: Equatable, Sendable {
    public let url: URL
    public let message: String
}

public struct HTMLCleanupPresetLoadResult: Sendable {
    public let presets: [HTMLCleanupPreset]
    public let errors: [HTMLCleanupPresetLoadError]
}

public enum HTMLCleanupPresetLibrary {
    public static func load(userDirectory: URL? = nil) throws -> HTMLCleanupPresetLoadResult {
        let decoder = JSONDecoder()
        var presets = try ["none", "clean", "article", "print"].map { name in
            var preset = try decoder.decode(
                HTMLCleanupPreset.self, from: Data(contentsOf: CoreResources.url(name, extension: "json")))
            preset.isBuiltIn = true
            return preset
        }
        var errors: [HTMLCleanupPresetLoadError] = []
        var identifiers = Set(presets.map(\.id))
        for url in try CoreResources.userFiles(in: userDirectory, extension: "json") {
            do {
                let preset = try decoder.decode(HTMLCleanupPreset.self, from: Data(contentsOf: url))
                guard !preset.id.isEmpty, identifiers.insert(preset.id).inserted else {
                    errors.append(
                        HTMLCleanupPresetLoadError(url: url, message: "The preset ID is empty or duplicated."))
                    continue
                }
                presets.append(preset)
            } catch {
                errors.append(HTMLCleanupPresetLoadError(url: url, message: error.localizedDescription))
            }
        }
        return HTMLCleanupPresetLoadResult(
            presets: presets.sorted { ($0.name, $0.id) < ($1.name, $1.id) }, errors: errors)
    }
}

public enum HTMLCleanupScript {
    /// Execute via WKWebView.evaluateJavaScript, independently of the setting that disables page scripts.
    public static func javaScript(for preset: HTMLCleanupPreset) -> String {
        guard !preset.removeSelectors.isEmpty || !preset.keepSelectors.isEmpty || !preset.extraCSS.isEmpty else {
            return ""
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(preset) else { return "" }
        let json = String(decoding: data, as: UTF8.self)
        return """
            (() => {
              const preset = \(json);
              let kept = null;
              for (const selector of preset.keepSelectors) {
                try {
                  kept = document.querySelector(selector);
                  if (kept) break;
                } catch (_) {}
              }
              if (kept && document.body && kept !== document.body && document.body.contains(kept)) {
                document.body.replaceChildren(kept);
              }
              for (const selector of preset.removeSelectors) {
                try {
                  document.querySelectorAll(selector).forEach(node => {
                    if (node !== document.body && node !== document.documentElement && node !== kept) node.remove();
                  });
                } catch (_) {}
              }
              if (preset.extraCSS) {
                let style = document.getElementById('surimono-cleanup-style');
                if (!style || style.tagName !== 'STYLE') {
                  style = document.createElement('style');
                  style.id = 'surimono-cleanup-style';
                  (document.head || document.documentElement).appendChild(style);
                }
                style.textContent = preset.extraCSS;
              }
            })();
            """
    }
}
