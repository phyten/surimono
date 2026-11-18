import Foundation

/// The guide that comes with the app: an ordinary Markdown document that explains the app and is worth printing as a
/// booklet. It is written in Japanese and in English; every other interface language gets the English one.
enum GettingStarted {
    /// The resource names, which are also the titles of the windows that show them.
    enum Edition: String, CaseIterable {
        case japanese = "Surimono の使い方"
        case english = "Getting Started with Surimono"
    }

    /// Only the language the interface is shown in counts: a reader whose interface is French reads the English
    /// guide even when Japanese comes later in their list, so that the guide's labels match the menus they see.
    static func edition(for languages: [String]) -> Edition {
        guard let first = languages.first else { return .english }
        return Locale.Language(identifier: first).languageCode == .japanese ? .japanese : .english
    }

    static func url(for languages: [String] = Bundle.main.preferredLocalizations, in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: edition(for: languages).rawValue, withExtension: "md")
    }

    static func sampleURL(for languages: [String] = Bundle.main.preferredLocalizations, in bundle: Bundle = .main)
        -> URL?
    {
        let name = edition(for: languages) == .japanese ? "Surimono 見本" : "Surimono Sample"
        return bundle.url(forResource: name, withExtension: "md")
    }

    /// A file inside the app is not one the reader chose, so it has no place among their recent files.
    static func isInsideApp(_ url: URL, bundle: Bundle = .main) -> Bool {
        guard url.isFileURL else { return false }
        let app = bundle.bundleURL.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(app.hasSuffix("/") ? app : app + "/")
    }
}
