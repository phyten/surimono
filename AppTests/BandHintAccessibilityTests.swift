import AppKit
import SurimonoCore
import SurimonoFormats
import SwiftUI
import Testing

@testable import Surimono

@MainActor
struct BandHintAccessibilityTests {
    private struct Node {
        let role: NSAccessibility.Role?
        let name: String?
        let help: String?
        let selected: Bool
    }

    private func window(hosting view: some View, size: CGSize, title: String? = nil) -> NSWindow {
        let controller = NSHostingController(rootView: view.environment(\.accessibilityEnabled, true))
        controller.sizingOptions = []
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: title == nil ? .borderless : [.titled, .closable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(size)
        if let title { window.title = title }
        window.alphaValue = 0
        window.orderFrontRegardless()
        controller.view.layoutSubtreeIfNeeded()
        return window
    }

    private func nodes(
        in view: some View, size: CGSize = CGSize(width: 500, height: 80), pressingRadio title: String? = nil
    ) -> [Node] {
        let window = window(hosting: view, size: size)
        defer { window.close() }
        return nodes(in: window, pressingRadio: title)
    }

    // SwiftUI virtual elements can expose AX selectors without protocol conformance. Native menu cells
    // can return an attributed string even for a selector that AppKit imports as String.
    private func string(_ node: AnyObject, _ selector: Selector) -> String? {
        guard node.responds(to: selector) else { return nil }
        let raw = node.perform(selector)?.takeUnretainedValue()
        return (raw as? NSAttributedString)?.string ?? raw as? String
    }

    private func nodes(in window: NSWindow, pressingRadio title: String? = nil) -> [Node] {
        var result: [Node] = []
        func collect(_ children: [Any]) {
            for child in children {
                let node = child as AnyObject
                let role = node.accessibilityRole?()
                let name =
                    string(node, #selector(NSAccessibilityProtocol.accessibilityLabel))
                    ?? string(node, #selector(NSAccessibilityProtocol.accessibilityTitle))
                let rawValue: Any? = node.accessibilityValue?()
                let selected =
                    role == .radioButton
                    ? (rawValue as? NSNumber)?.boolValue == true
                    : node.isAccessibilitySelected?() == true
                result.append(
                    Node(
                        role: role, name: name,
                        help: string(node, #selector(NSAccessibilityProtocol.accessibilityHelp)),
                        selected: selected))
                if let title, role == .radioButton, name == title { _ = node.accessibilityPerformPress?() }
                collect(node.accessibilityChildren?() ?? [])
            }
        }
        collect(window.contentView?.accessibilityChildren() ?? [])
        return result
    }

    @Test("全帯部品の読み上げ要素にはカードの説明があり、二択とページ送りは各ボタンで読める")
    func parts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = AppPreferences(defaults: BandTestDefaultsSuite().defaults)
        let pdf = TestFixtures.textPDF(["First", "Second"])
        let url = directory.appendingPathComponent("Band hints.pdf")
        try pdf.write(to: url)
        func model(
            file: URL? = nil, format: DocumentFormat = .pdf, bundle: ImageBundleModel? = nil, binder: BinderModel? = nil
        ) -> DocumentViewModel {
            let model = DocumentViewModel(
                data: format == .pdf ? pdf : Data("# Title".utf8), fileURL: file, format: format,
                preferences: preferences, library: UserLibrary(root: directory), imageBundle: bundle,
                settingsStore: DocumentSettingsStore(directory: directory.appendingPathComponent("Settings")),
                binder: binder)
            model.isolateBandTestOutput()
            return model
        }
        let document = model(file: url)
        let images = model(bundle: ImageBundleModel(urls: [directory.appendingPathComponent("A.png")]))
        let html = model(format: .html)
        html.setHTMLPresentation(.paper, capturesWeb: false)
        defer {
            document.stop()
            images.stop()
            html.stop()
        }
        document.start()
        let deadline = ContinuousClock.now + .seconds(5)
        while document.pageIndicator == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(document.pageIndicator != nil)
        for item in BandLayout.Item.allCases {
            let model =
                switch item {
                case .thumbnails: images
                case .presentation, .style, .ignoreSlides: html
                default: document
                }
            let hint = BandHintContent.band(item, model: model).accessibilityHint
            for form: BandLayout.Form in [.full, .compact] where form == .full || item.hasCompactForm(for: model) {
                let tree = nodes(in: BandPart(model: model, item: item, form: form))
                switch item {
                case .presentation, .layout, .pageTurn:
                    let choices: [(String, String)]
                    if item == .presentation {
                        choices = HTMLPresentation.allCases.map { ($0.name, hint) }
                    } else if item == .layout {
                        choices = ViewOptions.Layout.displayOrder.map { ($0.name, hint) }
                    } else {
                        choices = [false, true].map { forward in
                            (
                                forward ? String(localized: "Next Page") : String(localized: "Previous Page"),
                                BandHintContent.turn(forward: forward, model: model).accessibilityHint
                            )
                        }
                    }
                    for (name, help) in choices {
                        let role: NSAccessibility.Role = item == .layout ? .radioButton : .button
                        let elements = tree.filter { $0.role == role && $0.name == name }
                        #expect(elements.count == 1 && elements.first?.help == help, "\(item) / \(name)")
                        if item == .presentation {
                            #expect(elements.first?.selected == (name == model.htmlPresentation.name))
                        }
                        if item == .layout {
                            #expect(elements.first?.selected == (name == model.viewOptions.layout.name))
                        }
                    }
                default:
                    let controls = tree.filter {
                        [.button, .menuButton, .popUpButton, .checkBox].contains($0.role)
                    }
                    let leaves = controls.isEmpty ? tree.filter { $0.role == .staticText } : controls
                    #expect(!leaves.isEmpty && leaves.allSatisfy { $0.help == hint }, "\(item)")
                }
            }
        }

        let clipboard = model(format: .markdown)
        clipboard.textFormatOrigin = .automatic
        clipboard.textReopener = { _ in }
        let binder = model(binder: BinderModel(orderedURLs: [url]))
        defer {
            clipboard.stop()
            binder.stop()
        }
        for (item, alternative): (BandLayout.Item, DocumentViewModel) in [
            (.formatBadge, clipboard), (.style, clipboard), (.thumbnails, binder),
        ] {
            let tree = nodes(in: BandPart(model: alternative, item: item, form: .full))
            let hint = BandHintContent.band(item, model: alternative)
            #expect(
                tree.contains {
                    [.button, .menuButton, .popUpButton].contains($0.role) && $0.help == hint.accessibilityHint
                }, "\(item)")
        }

        let other: ViewOptions.Layout = document.viewOptions.layout == .single ? .spread : .single
        _ = nodes(in: BandPart(model: document, item: .layout, form: .full), pressingRadio: other.name)
        #expect(document.viewOptions.layout == other)

        document.currentPageIndex = 1
        let turns = nodes(in: BandPart(model: document, item: .pageTurn, form: .full))
        #expect(
            turns.contains {
                $0.name == String(localized: "Next Page") && $0.help == String(localized: "End of Document")
            })

        let window = fixedBandWindow(document, title: "Band hints")
        defer { window.close() }
        let expected = String(localized: "All operations are also available in “…”.")
        let fixed = nodes(in: window)
        #expect(fixed.contains { $0.role == .staticText && $0.help == url.path })
        #expect(fixed.contains { $0.role == .menuButton && $0.help == expected })

        // Hit-test the visible menu so a hint on another element cannot satisfy the menu assertion.
        let frame = try #require(document.bandAnchors.frames[.more])
        let host = try #require(window.contentView)
        let y = host.isFlipped ? frame.midY : host.bounds.height - frame.midY
        let screenPoint = window.convertPoint(toScreen: host.convert(NSPoint(x: frame.midX, y: y), to: nil))
        let more = try #require(window.accessibilityHitTest(screenPoint)) as AnyObject
        #expect(more.accessibilityRole?() == .menuButton)
        #expect(string(more, #selector(NSAccessibilityProtocol.accessibilityHelp)) == expected)
    }

    private func fixedBandWindow(_ document: DocumentViewModel, title: String) -> NSWindow {
        let menu = OverlayMenuState()
        menu.bandWidth = 1600
        menu.bandWidths[.name] = 120
        for item in BandLayout.Item.allCases { menu.bandWidths[.item(item, .full)] = 60 }
        let band = BandZone(edge: .top, isShown: true, height: ViewerWindow.titleBandHeight) {
            OverlayBand(model: document, menu: menu, plans: BandPlans(model: document, menu: menu))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .modifier(BandHintHost(session: BandHintSession()))
        .coordinateSpace(name: BandAnchors.coordinateSpace)
        return window(hosting: band, size: CGSize(width: menu.bandWidth, height: 180), title: title)
    }

    @Test(
        "システムのAXツリーに公開された「…」のメニューボタンがカードの説明を持つ",
        .enabled(if: AXIsProcessTrusted(), "macOS のアクセシビリティへのアクセスが必要"))
    func exportedMore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = DocumentViewModel(
            data: TestFixtures.textPDF(["More"]), fileURL: nil, format: .pdf,
            preferences: AppPreferences(defaults: BandTestDefaultsSuite().defaults),
            library: UserLibrary(root: directory),
            settingsStore: DocumentSettingsStore(directory: directory.appendingPathComponent("Settings")))
        model.isolateBandTestOutput()
        defer { model.stop() }
        let title = UUID().uuidString
        let window = fixedBandWindow(model, title: title)
        defer { window.close() }
        window.orderBack(nil)
        window.alphaValue = 1
        let help = try await exportedMenuHelp(windowTitle: title, menuTitle: String(localized: "More"))
        #expect(help == String(localized: "All operations are also available in “…”."))
    }

    // A system AX client can see a different element from the in-process menu cell. Keep the main
    // actor available to serve its requests. The window title isolates this band from other test windows.
    private func exportedMenuHelp(windowTitle: String, menuTitle: String) async throws -> String? {
        try await Task.detached {
            func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
                return value
            }
            let app = AXUIElementCreateApplication(getpid())
            func testWindow() -> AXUIElement? {
                let windows = attribute(kAXWindowsAttribute, of: app) as? [AXUIElement] ?? []
                return windows.first { attribute(kAXTitleAttribute, of: $0) as? String == windowTitle }
            }
            // AppKit publishes new windows to AX clients asynchronously.
            let deadline = ContinuousClock.now + .seconds(2)
            var window = testWindow()
            while window == nil && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
                window = testWindow()
            }
            var children = [try #require(window)]
            while let element = children.popLast() {
                if attribute(kAXRoleAttribute, of: element) as? String == kAXMenuButtonRole,
                    attribute(kAXTitleAttribute, of: element) as? String == menuTitle
                {
                    return attribute(kAXHelpAttribute, of: element) as? String
                }
                children += attribute(kAXChildrenAttribute, of: element) as? [AXUIElement] ?? []
            }
            return nil
        }.value
    }

    private struct EditorChips: View {
        let session: BandArrangementEditorSession
        @AccessibilityFocusState(for: .voiceOver) private var focus: BandEditorSelection?
        var body: some View {
            VStack {
                ArrangementMiniature(session: session, accessibilityFocus: $focus)
                UnusedPalette(session: session, accessibilityFocus: $focus)
            }
        }
    }

    @Test("配置済み・未配置のチップと区切り線ではカードの文が読み上げ要素に届く")
    func editorChips() {
        let session = BandArrangementEditorSession(
            preferences: AppPreferences(defaults: BandTestDefaultsSuite().defaults))
        let editor = EditorChips(session: session)
        let tree = nodes(in: editor, size: CGSize(width: 1200, height: 820))
        for item in BandLayout.Item.allCases {
            let hint = BandHintContent.editor(item)
            #expect(tree.contains { $0.role == .button && $0.name == hint.name && $0.help == hint.detail }, "\(item)")
        }
        let separators = tree.filter { $0.role == .button && $0.name == String(localized: "Separator") }
        #expect(
            separators.contains {
                $0.help == String(localized: "Separator: appears on the toolbar only between two parts.")
            })
        let detail = String(localized: "Drag into a zone, or select a part and press to add a separator after it.")
        let defaultAction = choice(String(localized: "Add Separator"), BandZoneID.topLeft.editorName)
        #expect(separators.contains { $0.help == detail + " " + defaultAction })
        session.select(.part(.print))
        let selected = nodes(in: editor, size: CGSize(width: 1200, height: 820))
        #expect(
            selected.contains {
                $0.role == .button
                    && $0.help == detail + " " + String(localized: "Adds a separator after the selected part.")
            })
    }
}
