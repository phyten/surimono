import SwiftUI
import Testing

@testable import Surimono

@MainActor
func settingsPaneContainer(in view: NSView) -> SettingsPaneContainer? {
    if let pane = view as? SettingsPaneContainer { return pane }
    for child in view.subviews {
        if let pane = settingsPaneContainer(in: child) { return pane }
    }
    return nil
}

@MainActor
struct RetainedSettingsPaneTests {
    private let inputs = SettingsPaneContainer.Inputs(
        hits: SettingsSearchHits(), locale: .current, direction: .leftToRight, scheme: .light)

    @Test("初訪問だけで各ホストを追加し、区分を往復しても同じ子ビューを同じ順序で保つ")
    func retainsContent() {
        let pane = SettingsPaneContainer()
        var builds = 0
        func show(_ section: SettingsSection?) {
            pane.update(section: section, inputs: inputs) { _, _ in
                builds += 1
                return AnyView(Text("Settings"))
            }
        }
        show(nil)
        #expect(pane.subviews.isEmpty)
        show(.general)
        show(.keyboardShortcuts)
        show(.toolbarArrangement)
        let children = pane.subviews
        #expect(children.count == 3)
        for section: SettingsSection in [.general, .keyboardShortcuts, .toolbarArrangement, .general] {
            show(section)
            #expect(pane.subviews.map { ObjectIdentifier($0) } == children.map { ObjectIdentifier($0) })
            #expect(pane.subviews.filter { !$0.isHidden }.count == 1)
        }
        #expect(builds == 3)
        show(.styles)
        #expect(pane.subviews.count == 3)
        #expect(builds == 4)
    }

    private final class AttachmentProbe: NSView {
        var detachments = 0
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if window != nil && newWindow == nil { detachments += 1 }
            super.viewWillMove(toWindow: newWindow)
        }
    }

    @Test("SwiftUI から区分を切り替えても訪問済みのペインは窓から外れない")
    func staysInWindow() throws {
        func detail(_ section: SettingsSection) -> some View {
            SettingsDetail(section: section, hits: SettingsSearchHits()) { Text(verbatim: $0.rawValue) }
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 540), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSHostingView(rootView: detail(.keyboardShortcuts))
        window.contentView = root
        window.alphaValue = 0
        window.orderBack(nil)
        root.layoutSubtreeIfNeeded()
        let pane = try #require(settingsPaneContainer(in: root))
        let shortcuts = try #require(pane.subviews.first)
        let probe = AttachmentProbe()
        shortcuts.addSubview(probe)
        // Identity alone would miss a removal followed by reinsertion of the same host.
        for section: SettingsSection in [.general, .styles, .toolbarArrangement, .keyboardShortcuts] {
            root.rootView = detail(section)
            root.layoutSubtreeIfNeeded()
            #expect(settingsPaneContainer(in: root) === pane)
            #expect(shortcuts.superview === pane)
            #expect(shortcuts.isHidden == (section != .keyboardShortcuts))
            #expect(probe.window === window)
        }
        #expect(probe.detachments == 0)
    }

    @Test("隠れたペインの寸法は窓を広げても変わらず再表示で追いつく")
    func hiddenFrame() throws {
        let pane = SettingsPaneContainer(frame: CGRect(x: 0, y: 0, width: 600, height: 450))
        func show(_ section: SettingsSection) {
            pane.update(section: section, inputs: inputs) { _, _ in AnyView(EmptyView()) }
        }
        show(.keyboardShortcuts)
        let shortcuts = try #require(pane.subviews.first)
        let original = shortcuts.frame
        show(.general)
        pane.setFrameSize(NSSize(width: 800, height: 540))
        pane.layoutSubtreeIfNeeded()
        #expect(shortcuts.isHidden)
        #expect(shortcuts.frame == original)
        #expect(pane.subviews.last?.frame == pane.bounds)
        show(.keyboardShortcuts)
        #expect(!shortcuts.isHidden)
        #expect(shortcuts.frame == pane.bounds)
    }

    @Test("他の区分の検索は隠れたルートを更新せず、同じ検索へ戻ると表示位置を改めて求める")
    func hiddenSearch() throws {
        let pane = SettingsPaneContainer()
        var search = inputs
        search.hits = SettingsSearchHits(query: "print", anchors: ["document.print"])
        var visits: [SettingsSearchHits] = []
        func show(_ section: SettingsSection) {
            pane.update(section: section, inputs: search) { selected, hits in
                if selected == .keyboardShortcuts { visits.append(hits) }
                return AnyView(EmptyView())
            }
        }
        show(.keyboardShortcuts)
        let first = try #require(visits.first)
        #expect(first.canReveal)
        show(.general)
        #expect(!first.canReveal)
        show(.keyboardShortcuts)
        #expect(visits.count == 2)
        #expect(visits.last?.canReveal == true)
        #expect(!first.canReveal)
    }

    @Test("非表示にしたペインはフォーカスを手放し、Tab とクリックの対象から外れる")
    func hiddenPane() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 220), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let pane = SettingsPaneContainer(frame: window.contentLayoutRect)
        window.contentView = pane
        pane.update(section: .keyboardShortcuts, inputs: inputs) { _, _ in AnyView(EmptyView()) }
        let host = try #require(pane.subviews.first)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 20))
        host.addSubview(field)
        #expect(window.makeFirstResponder(field))
        // An editing field can lend focus to the window's shared field editor.
        #expect(window.firstResponder === field || field.currentEditor().map { window.firstResponder === $0 } == true)
        pane.update(section: nil, inputs: inputs) { _, _ in AnyView(EmptyView()) }
        #expect(host.isHidden)
        #expect(field.currentEditor() == nil)
        #expect(window.firstResponder !== field)
        #expect(host.isAccessibilityHidden())
        #expect(!field.canBecomeKeyView)
        #expect(pane.hitTest(NSPoint(x: 10, y: 10)) !== field)
        pane.update(section: .keyboardShortcuts, inputs: inputs) { _, _ in AnyView(EmptyView()) }
        #expect(window.makeFirstResponder(field))
    }
}
