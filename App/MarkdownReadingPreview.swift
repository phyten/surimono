#if DEBUG
    import SurimonoCore
    import SwiftUI

    /// Snapshot edits belong to this view and never enter the document's saved settings.
    struct MarkdownReadingPreview: View {
        let documentName: String
        let fileURL: URL?
        let contents: ReadingFileInstructions?
        let defaults: FormatReadingChoices
        let close: () -> Void
        @State private var document = FormatReadingChoices()
        @State private var allowsFileChanges = false

        var ids: [ReadingSettingID] { ReadingCatalogue.rows(for: .markdown).map(\.id) }

        private func file(for id: ReadingSettingID) -> ReadingFileInstructions {
            id == .tableOfContents ? contents ?? .init() : .init()
        }

        func resolution(_ id: ReadingSettingID) -> ReadingRowResolution? {
            document.resolve(
                id, for: .markdown, file: file(for: id), defaults: defaults, allowsFileChanges: allowsFileChanges)
        }

        private func revertAll() { document = .init() }

        var body: some View {
            let permission = Binding(
                get: { allowsFileChanges },
                set: { allow in
                    if !allow {
                        document.revert(.tableOfContents, for: .markdown, fileOnly: file(for: .tableOfContents))
                    }
                    allowsFileChanges = allow
                })
            let changed = ids.count { resolution($0)?.isChanged == true }
            ReadingPanel(
                title: "Markdown", ready: contents != nil, changed: changed,
                allowsFileChanges: contents?.present == nil && contents?.depth == nil ? nil : permission,
                close: close, revert: revertAll
            ) {
                EmptyView()
            } rows: {
                ReadingPanelSection(ids: ids) { id in
                    if let row = resolution(id) {
                        FormatReadingControl(
                            id: id, row: row, documentName: documentName, fileURL: fileURL,
                            allowsFileChanges: allowsFileChanges,
                            set: {
                                document.set(
                                    $0, for: id, format: .markdown, file: file(for: id), defaults: defaults,
                                    allowsFileChanges: allowsFileChanges)
                            },
                            revert: { document.revert(id, for: .markdown) })
                    }
                }
            }
        }
    }
#endif
