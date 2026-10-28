import SwiftUI

@main
struct SurimonoApp: App {
    var body: some Scene {
        DocumentGroup(viewing: SurimonoDocument.self) { configuration in
            DocumentViewer(document: configuration.document, fileURL: configuration.fileURL)
        }
        Settings {
            Text("Settings will be available in a future version.")
                .padding()
                .frame(width: 360, height: 120)
        }
    }
}
