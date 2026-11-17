#if DEBUG
    import AppKit
    import SurimonoCore
    import SurimonoRendering
    import Testing

    @testable import Surimono

    /// The screenshot argument that names a printer must not reach a printer, even when the name is that of a printer set
    /// up on the Mac: it replaces every way out, whatever the name. Nothing here needs a printer, and the test uses a
    /// made-up name so that a regression cannot print on a developer's Mac.
    @MainActor
    struct DebugPrinterNameTests {
        @MainActor private final class Fixture {
            let suite = TestDefaultsSuite()
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let preferences: AppPreferences

            init() {
                preferences = AppPreferences(defaults: suite.defaults)
                preferences.layoutID = "a4Duplex"
            }

            func model() -> DocumentViewModel {
                DocumentViewModel(
                    data: TestFixtures.textPDF(["ONE", "TWO", "THREE", "FOUR", "FIVE"]), fileURL: nil, format: .pdf,
                    preferences: preferences, library: UserLibrary(root: root), renderer: DocumentRenderer())
            }

            func cleanUp() {
                try? FileManager.default.removeItem(at: root)
                suite.remove()
            }
        }

        private func wait(until condition: () -> Bool) async throws {
            for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
            try #require(condition())
        }

        @Test(
            "撮影でプリンター名を指定すると、印刷・両面のテスト・手動両面のどれも外へ送らず差し替え先にだけ届く",
            .timeLimit(.minutes(1)))
        func namedPrinterSendsNothing() async throws {
            let fixture = Fixture()
            defer { fixture.cleanUp() }
            // A name no Mac has: the argument replaces every way out whatever the name is, so the check does not need
            // (and must not use) the name of a printer that is really set up here.
            let name = "Surimono Test Printer \(UUID().uuidString.prefix(8))"
            let model = fixture.model()
            defer { model.stop() }
            var sent: [String] = []
            DebugSnapshot.showPrinterName(name, in: model) { sent.append($0) }
            model.enterPrintMode()
            model.start()
            try await wait { model.canOutput }
            #expect(model.selectedPrinterName == name)

            model.printDocument(quick: true)
            try await wait { sent.contains("print \(name)") }
            try await wait { model.canStartPrint }

            model.printDuplexTest()
            try await wait { sent.contains("duplexTest \(name)") }
            try await wait { !model.isPrinting && model.canStartPrint }

            model.printDocument(intent: .manualDuplex)
            try await wait { sent.contains("manualDuplex \(name)") }
            // Manual duplex that cannot start may fall back to an ordinary print; that one reaches the stub as well.
            #expect(Array(sent.prefix(3)) == ["print \(name)", "duplexTest \(name)", "manualDuplex \(name)"])
            #expect(sent.allSatisfy { $0.hasSuffix(" \(name)") })
        }
    }
#endif
