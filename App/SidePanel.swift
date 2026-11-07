import AppKit
import SwiftUI

enum SidePanelMetrics {
    static let width: CGFloat = 260
}

struct SidePanel<Actions: View, Content: View>: View {
    let title: LocalizedStringKey
    let subtitle: String
    let actions: Actions
    let content: Content

    init(
        _ title: LocalizedStringKey, subtitle: String = "",
        @ViewBuilder actions: () -> Actions, @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.actions = actions()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 13, weight: .bold)).fixedSize()
                Text(verbatim: subtitle).font(.system(size: 11)).foregroundStyle(PrintPalette.ink2).lineLimit(1)
                Spacer(minLength: 0)
                HStack(spacing: 2) { actions }
            }
            content
        }
        .padding(12)
        .frame(width: SidePanelMetrics.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .foregroundStyle(PrintPalette.ink)
        .background(PrintPalette.raised)
        .overlay(alignment: .trailing) { Rectangle().fill(PrintPalette.line).frame(width: 1) }
    }
}

/// Reports a click on the row that is selected already, which the list keeps to itself. A tap gesture on the rows
/// would hear it too, but it stops the list's drag to reorder, and the list lets no mouse-up out of its tracking, so
/// the press is seen on its way in and then watched until it ends or turns into a drag.
struct SelectedRowClicks<Row: Equatable>: NSViewRepresentable {
    /// The row under the pointer, away from the row's buttons.
    let pointedRow: Row?
    let selection: Row?
    let onClick: (Row) -> Void

    func makeNSView(context: Context) -> Watcher { Watcher() }

    func updateNSView(_ view: Watcher, context: Context) {
        view.pointedRow = pointedRow
        view.selection = selection
        view.onClick = onClick
    }

    final class Watcher: NSView {
        var pointedRow: Row?
        var selection: Row?
        var onClick: ((Row) -> Void)?
        private var monitor: Any?
        private var pressTask: Task<Void, Never>?

        isolated deinit { stop() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                MainActor.assumeIsolated { self?.watchPress(of: event) }
                return event
            }
        }

        private func stop() {
            pressTask?.cancel()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func watchPress(of event: NSEvent) {
            pressTask?.cancel()
            guard event.window === window, let row = pointedRow, row == selection else { return }
            let start = NSEvent.mouseLocation
            pressTask = Task { [weak self] in
                while !Task.isCancelled {
                    let now = NSEvent.mouseLocation
                    guard hypot(now.x - start.x, now.y - start.y) < 4 else { return }
                    if NSEvent.pressedMouseButtons & 1 == 0 {
                        self?.onClick?(row)
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(30))
                }
            }
        }
    }
}

struct PanelIconButton: View {
    let symbol: String
    let label: LocalizedStringKey
    let action: () -> Void
    @State private var isHovered = false

    init(_ symbol: String, label: LocalizedStringKey, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(isHovered ? PrintPalette.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(label)
        .help(label)
    }
}

/// Keep problem names readable without letting a long excluded list crowd out the documents.
struct PanelFileIssues: View {
    let names: [String]
    let summary: String
    var status: LocalizedStringKey? = nil

    var body: some View {
        if !names.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                if !summary.isEmpty { Text(verbatim: summary) }
                ForEach(Array(names.prefix(5).enumerated()), id: \.offset) { _, name in
                    HStack(spacing: 8) {
                        Text(verbatim: name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        if let status { Text(status) }
                    }
                    .help(name)
                }
                if names.count > 5 {
                    Text(String(format: String(localized: "%lld more"), names.count - 5))
                }
            }
            .font(.system(size: 11)).foregroundStyle(PrintPalette.ink3)
        }
    }
}

struct PanelSortButton: View {
    let action: () -> Void

    var body: some View {
        Button("Sort by Name", action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(PrintPalette.ai)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
