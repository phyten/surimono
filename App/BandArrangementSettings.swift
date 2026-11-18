import SurimonoCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings > Toolbar Arrangement: the active set's two variants drawn on a miniature of the view mode's window, where
/// parts and separators are dragged between the zones and "Parts to Add", or moved with the inspector's buttons.
struct BandArrangementSettings: View {
    @Bindable var session: BandArrangementEditorSession
    @State private var width: CGFloat = 0

    /// Beside the miniature only when both keep a useful width.
    private static let sidePaletteWidth: CGFloat = 760

    var body: some View {
        ScrollViewReader { proxy in
            editorScroll
                .task(id: session.selectionRevealRevision) {
                    guard session.selectionRevealRevision > 0 else { return }
                    // Let the destination chip enter the updated layout before resolving its scroll identity.
                    await Task.yield()
                    guard !Task.isCancelled, let selection = session.selection else { return }
                    // Without an anchor SwiftUI moves only as far as needed to reveal the chip.
                    proxy.scrollTo(Optional(selection))
                }
        }
    }

    private var editorScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if session.needsRecovery { RecoveryNotice(session: session) }
                RepairNotice(notices: session.preferences.bandArrangementNotices)
                if session.hasConflict { ConflictNotice(session: session) }
                Group {
                    SetBar(session: session)
                    StatusRow(session: session)
                    ModeRow(session: session)
                    if width >= Self.sidePaletteWidth {
                        HStack(alignment: .top, spacing: 14) {
                            VStack(alignment: .leading, spacing: 10) {
                                ArrangementMiniature(session: session)
                                MiniatureNotes(session: session)
                                Inspector(session: session)
                            }
                            UnusedPalette(session: session).frame(width: 230)
                        }
                    } else {
                        ArrangementMiniature(session: session)
                        MiniatureNotes(session: session)
                        UnusedPalette(session: session)
                        Inspector(session: session)
                    }
                }
                .disabled(session.needsRecovery)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .coordinateSpace(name: "band-editor")
        // As the other sections' grouped forms do: the first row closer to the title bar.
        .contentMargins(.top, -28, for: .scrollContent)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            width = $0
        }
        .onAppear { session.didAppear() }
        // A change saved elsewhere: followed while nothing is unsaved, told as a conflict otherwise.
        .onChange(of: session.store) { session.refresh() }
        // Everywhere but the zones and the palette: a separator dropped here is taken away.
        .onDrop(of: [.utf8PlainText], delegate: BandEditorDropDelegate(session: session, target: { _ in .outside }))
        .sheet(item: $session.dialog) { dialog in
            BandArrangementDialog(session: session, dialog: dialog)
        }
        .alert(
            Text("Save changes to the toolbar arrangement?"),
            // The buttons answer the question; dismissing the alert alone decides nothing.
            isPresented: Binding(get: { session.pendingLeave != nil && session.dialog == nil }, set: { _ in })
        ) {
            Button("Save") {
                if session.saveForLeaving() { session.proceed() }
            }
            Button("Discard", role: .destructive) {
                session.discardChanges()
                session.proceed()
            }
            Button("Cancel", role: .cancel) { session.cancelLeave() }
        } message: {
            if session.isStandardActive {
                Text("Standard does not change. Save keeps your changes as a new arrangement.")
            } else if session.hasConflict {
                Text("This arrangement was changed elsewhere. Save keeps your changes as a new arrangement.")
            } else {
                Text("Save replaces “\(session.activeName)” with your changes. Discard keeps it as it was saved.")
            }
        }
    }
}

// MARK: - The set and its state

private struct SetBar: View {
    @Bindable var session: BandArrangementEditorSession

    var body: some View {
        // In longer languages the set's label gives way before any button is cut short.
        ViewThatFits(in: .horizontal) {
            row(showsLabel: true)
            row(showsLabel: false)
        }
    }

    private func row(showsLabel: Bool) -> some View {
        HStack(spacing: 8) {
            if showsLabel { Text("Arrangement Set").fixedSize() }
            Picker(
                "Arrangement Set",
                selection: Binding(
                    get: { session.active },
                    set: { selection in
                        guard selection != session.active else { return }
                        session.request(.selectSet(selection))
                    })
            ) {
                Text("Standard").tag(BandArrangementSelection.standard)
                if !session.store.sets.isEmpty { Divider() }
                ForEach(session.store.sets) { set in
                    Text(verbatim: set.name).tag(BandArrangementSelection.user(set.id))
                }
            }
            .labelsHidden()
            .fixedSize()
            // Saving stays a button: it is what a change on screen needs. Making and managing sets is in the menu.
            Button("Overwrite") { session.overwrite() }
                .disabled(!session.canOverwrite)
                .help(
                    session.isStandardActive
                        ? LocalizedStringKey("Standard cannot be overwritten. Duplicate it to keep your changes.")
                        : LocalizedStringKey("Save the changes into this arrangement")
                )
                .fixedSize()
            Menu {
                Button("Duplicate…") { session.dialog = .duplicate }
                    .help("Save the arrangement on screen under a new name")
                Button("New…") { session.request(.newSet) }
                    .help("Start a new arrangement from Standard")
                Divider()
                // Standard has no name to change and cannot go; its menu still makes copies and new sets.
                Button("Rename…") { session.dialog = .rename }
                    .disabled(session.isStandardActive)
                Button("Delete…") { session.dialog = .delete }
                    .disabled(session.isStandardActive)
            } label: {
                Label("Manage Arrangement", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Manage Arrangement")
            Spacer(minLength: 0)
        }
    }
}

/// Whether the miniature shows unsaved changes.
private struct StatusRow: View {
    let session: BandArrangementEditorSession

    var body: some View {
        Group {
            if session.isDirty {
                (Text(Image(systemName: "circle.fill")).font(.system(size: 6)).baselineOffset(1.5)
                    + Text(verbatim: " ") + Text("Unsaved Changes").fontWeight(.semibold)
                    + Text(verbatim: "  ")
                    + Text("Save to apply to all view windows.").foregroundStyle(.secondary))
                    .foregroundStyle(PrintPalette.warn)
            } else {
                Text("All view windows use this arrangement.").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The editor's history and the way back to Standard: they act on the variants being edited, so they sit with the
/// choice of which one is edited rather than with the set.
private struct EditHistoryControls: View {
    let session: BandArrangementEditorSession

    var body: some View {
        HStack(spacing: 8) {
            ControlGroup {
                Button {
                    session.undo()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!session.canUndo)
                .help("Undo (⌘Z)")
                Button {
                    session.redo()
                } label: {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                }
                .disabled(!session.canRedo)
                .help("Redo (⇧⌘Z)")
            }
            .labelStyle(.iconOnly)
            .fixedSize()
            Button("Back to Standard") { session.backToStandard() }
                .disabled(session.draft == BandArrangementVariants())
                .help("Put both variants back as Standard has them, without saving")
                .fixedSize()
        }
    }
}

/// Which variant is edited, and the editing controls at its trailing end. Each set keeps both variants; which one the
/// windows use is chosen in View & Page Turn.
private struct ModeRow: View {
    @Bindable var session: BandArrangementEditorSession

    var body: some View {
        // No popover hangs from these controls, so trading one arrangement for another here closes nothing.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                choice
                inUseNote
                Spacer(minLength: 8)
                EditHistoryControls(session: session)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    choice
                    Spacer(minLength: 8)
                    EditHistoryControls(session: session)
                }
                inUseNote
            }
            VStack(alignment: .leading, spacing: 6) {
                choice
                inUseNote
                HStack {
                    Spacer(minLength: 0)
                    EditHistoryControls(session: session)
                }
            }
        }
    }

    private var choice: some View {
        HStack(spacing: 10) {
            Text("Editing").fixedSize()
            Picker("Editing", selection: $session.mode) {
                Text("Top Only").tag(MenuArrangement.top)
                Text("Split Top and Bottom").tag(MenuArrangement.split)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    /// Said only when the layout being edited is not the one the windows use; otherwise the picker already shows it.
    @ViewBuilder private var inUseNote: some View {
        if session.mode != session.preferences.menuArrangement {
            let inUse =
                session.preferences.menuArrangement == .top
                ? String(localized: "Top Only") : String(localized: "Split Top and Bottom")
            Text(verbatim: String(format: String(localized: "In use: %@"), inUse))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize()
                .help("Change it under View & Page Turn > Toolbar Layout.")
        }
    }
}

/// What loading repaired or left out of the saved arrangements, until the first save writes the repaired store (and
/// keeps the original aside).
private struct RepairNotice: View {
    let notices: [BandRepairNotice]

    var body: some View {
        let lines = notices.filter(\.losesData).compactMap(\.editorText).reduce(into: [String]()) { lines, line in
            if !lines.contains(line) { lines.append(line) }
        }
        if !lines.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "wrench.and.screwdriver").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Some saved toolbar arrangements were repaired when they were read.").fontWeight(.semibold)
                    ForEach(lines, id: \.self) { line in
                        Text(verbatim: "• " + line)
                    }
                    Text("The data as it was read is kept aside the first time you save.")
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12))
            .padding(12)
            .background(CornerRole.tile.shape.fill(Color.accentColor.opacity(0.1)))
        }
    }
}

/// The saved arrangement changed elsewhere under unsaved changes: Overwrite is off; a copy keeps the changes.
private struct ConflictNotice: View {
    let session: BandArrangementEditorSession

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(PrintPalette.warn)
            Text(
                "This arrangement was changed elsewhere while you edited it. Duplicate keeps your changes as a new arrangement."
            )
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Use Saved") { session.discardChanges() }
                .fixedSize()
                .help("Discard your changes and show the arrangement as it is saved now")
        }
        .font(.system(size: 12))
        .padding(10)
        .background(CornerRole.tile.shape.fill(PrintPalette.warnTint))
    }
}

private struct RecoveryNotice: View {
    let session: BandArrangementEditorSession

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(PrintPalette.warn)
            VStack(alignment: .leading, spacing: 6) {
                Text("The saved toolbar arrangements could not be read.").fontWeight(.semibold)
                Text(
                    "The toolbar uses Standard for now, and nothing is saved. Starting over keeps the unreadable data aside instead of deleting it."
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Button("Start Over") { session.startOver() }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .padding(12)
        .background(CornerRole.tile.shape.fill(PrintPalette.warnTint))
    }
}

// MARK: - The miniature window

private enum MiniatureMetrics {
    static let chipHeight: CGFloat = 26
    static let chipSpacing: CGFloat = 3
    static let bandHeight: CGFloat = 38
}

private struct ArrangementMiniature: View {
    let session: BandArrangementEditorSession

    var body: some View {
        VStack(spacing: 0) {
            MiniatureBandLayout(fixedPrefix: 2) {
                TrafficLightDots()
                Text("File Name")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PrintPalette.ink)
                    .lineLimit(1)
                    .fixedSize()
                    .help("The file name always follows the traffic lights.")
                    .accessibilityLabel(Text("File Name"))
                    .accessibilityValue(Text("Fixed"))
                ZoneEditor(session: session, zone: .topLeft)
                ZoneEditor(session: session, zone: .topRight)
                if !docksMore { MoreLock() }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(minHeight: MiniatureMetrics.bandHeight)
            .background(PrintPalette.raised)
            .overlay(alignment: .bottom) { Divider() }
            Paper(spread: true)
                .frame(height: session.mode == .split ? 46 : 72)
            if session.mode == .split {
                MiniatureBandLayout(fixedPrefix: 0) {
                    ZoneEditor(session: session, zone: .bottomLeft)
                    ZoneEditor(session: session, zone: .bottomRight)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(minHeight: MiniatureMetrics.bandHeight)
                .background(PrintPalette.raised)
                .overlay(alignment: .top) { Divider() }
            }
        }
        .clipShape(CornerRole.toast.shape)
        .overlay(CornerRole.toast.shape.strokeBorder(PrintPalette.line2))
        .shadow(color: PrintPalette.popShadow, radius: 6, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Toolbar Arrangement"))
    }

    /// As in the window: Print last on the top right stays after "…".
    private var docksMore: Bool { session.arrangement.topRight.last == .part(.print) }
}

private struct TrafficLightDots: View {
    var body: some View {
        HStack(spacing: 6) {
            ForEach([0xED6A5E, 0xF4BF4F, 0x61C554], id: \.self) { hex in
                Circle()
                    .fill(
                        Color(
                            .sRGB, red: Double(hex >> 16) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                            blue: Double(hex & 0xFF) / 255)
                    )
                    .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
                    .frame(width: 10, height: 10)
            }
        }
        .accessibilityHidden(true)
    }
}

/// "…" stays where it is: every operation is also available there.
private struct MoreLock: View {
    var body: some View {
        Image(systemName: "ellipsis.circle")
            .font(.system(size: 13))
            .foregroundStyle(PrintPalette.ink2)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "lock.fill").font(.system(size: 6.5, weight: .bold))
                    .foregroundStyle(PrintPalette.ink3)
                    .padding(1)
                    .background(Circle().fill(PrintPalette.raised))
                    .offset(x: 3, y: 3)
            }
            .frame(width: 24, height: MiniatureMetrics.chipHeight)
            .help("“…” is fixed. All operations are also available here.")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "…"))
            .accessibilityValue(Text("Fixed"))
    }
}

private struct Paper: View {
    let spread: Bool

    var body: some View {
        ZStack {
            PrintPalette.stage
            HStack(spacing: 2) {
                ForEach(0..<(spread ? 2 : 1), id: \.self) { _ in
                    Rectangle().fill(PrintPalette.pictogramPaper)
                        .aspectRatio(0.72, contentMode: .fit)
                        .shadow(color: PrintPalette.paperShadow, radius: 2, y: 1)
                }
            }
            .padding(.vertical, 10)
        }
        .accessibilityHidden(true)
    }
}

/// One zone of the miniature: its entries in order, wrapping when the zone is crowded, the insertion marker while a
/// drag hovers, and "…" before Print when Print is last on the top right.
private struct ZoneEditor: View {
    let session: BandArrangementEditorSession
    let zone: BandZoneID
    @State private var frames: [Int: CGRect] = [:]

    var body: some View {
        let entries = session.arrangement[zone]
        let space = "zone-\(zone.rawValue)"
        let targeted = session.dropTarget.map { if case .zone(zone, _) = $0 { true } else { false } } ?? false
        FlowLayout(spacing: MiniatureMetrics.chipSpacing) {
            ForEach(Self.identified(entries), id: \.id) { index, entry, _ in
                if zone == .topRight, index == entries.count - 1, entry == .part(.print) { MoreLock() }
                EntryChip(
                    session: session, location: BandEntryLocation(destination: .zone(zone), index: index), entry: entry
                )
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .named(space))
                } action: {
                    frames[index] = $0
                }
            }
        }
        .padding(3)
        .frame(minWidth: entries.isEmpty ? 74 : 0, minHeight: MiniatureMetrics.chipHeight + 6, alignment: .leading)
        .overlay {
            if entries.isEmpty {
                Text(verbatim: zone.editorName).font(.system(size: 10)).foregroundStyle(PrintPalette.ink3)
                    .lineLimit(1).fixedSize().allowsHitTesting(false)
            }
        }
        .background {
            CornerRole.largeControl.shape
                .fill(targeted ? Color.accentColor.opacity(0.12) : .clear)
            CornerRole.largeControl.shape
                .strokeBorder(
                    targeted ? Color.accentColor : PrintPalette.line3,
                    style: StrokeStyle(lineWidth: targeted ? 1.5 : 1, dash: targeted ? [] : [3, 3])
                )
                .opacity(entries.isEmpty || session.dropTarget != nil ? 1 : 0)
        }
        .overlay(alignment: .topLeading) {
            if case .zone(zone, let index) = session.dropTarget,
                let marker = BandEditorDrop.marker(at: index, frames: ordered(entries.count))
            {
                AppCornerShape.capsule.fill(Color.accentColor)
                    .frame(width: 2.5, height: marker.height)
                    .offset(x: marker.minX, y: marker.minY)
                    .allowsHitTesting(false)
            }
        }
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named("band-editor"))
        } action: {
            session.layoutFrames[zone.rawValue] = $0
        }
        .coordinateSpace(.named(space))
        .onDrop(
            of: [.utf8PlainText],
            delegate: BandEditorDropDelegate(session: session) { location in
                .zone(zone, index: BandEditorDrop.insertionIndex(at: location, frames: ordered(entries.count)))
            }
        )
        .help(zone.editorName)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: zone.editorName))
    }

    private func ordered(_ count: Int) -> [CGRect] {
        (0..<count).compactMap { frames[$0] }
    }

    /// Separators look alike; numbering them within the zone keeps each chip's identity while the parts move.
    static func identified(_ entries: [BandEntry]) -> [(index: Int, entry: BandEntry, id: String)] {
        var separators = 0
        return entries.enumerated().map { index, entry in
            switch entry {
            case .part(let item): return (index, entry, item.rawValue)
            case .separator:
                separators += 1
                return (index, entry, "\(BandEntry.separatorToken)-\(separators)")
            }
        }
    }
}

/// Under the miniature: whether it shows unsaved changes, what the last step did, and why some separators look faint.
private struct MiniatureNotes: View {
    let session: BandArrangementEditorSession

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // How to edit, which the miniature itself does not show: the inspector below explains a selected part.
            Text("Drag parts to arrange them. Select one to see what it does.")
                .foregroundStyle(.secondary)
            if session.message == nil, !session.hasIdleSeparators {
                Text("Narrow windows hide parts of the toolbar.")
                    .foregroundStyle(.secondary)
            }
            if let message = session.message {
                Label {
                    Text(verbatim: message.text)
                } icon: {
                    Image(systemName: message.isWarning ? "exclamationmark.circle" : "checkmark.circle")
                }
                .foregroundStyle(message.isWarning ? AnyShapeStyle(PrintPalette.warn) : AnyShapeStyle(.secondary))
            }
            if session.hasIdleSeparators {
                Label {
                    Text("A faint separator appears on the toolbar only between two parts.")
                } icon: {
                    Image(systemName: "info.circle")
                }
                .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Chips

/// One entry of the draft: a part drawn as on the band, or a separator. Click or Space selects it, and it drags.
private struct EntryChip: View {
    let session: BandArrangementEditorSession
    let location: BandEntryLocation
    let entry: BandEntry
    var showsName = false

    private var selection: BandEditorSelection? {
        switch entry {
        case .part(let item): .part(item)
        case .separator:
            if case .zone(let zone) = location.destination { .separator(zone, location.index) } else { nil }
        }
    }

    private var isSelected: Bool { selection != nil && session.selection == selection }
    private var isIdle: Bool {
        guard case .zone(let zone) = location.destination else { return false }
        return session.separatorIsIdle(at: location.index, in: zone)
    }

    var body: some View {
        content
            .frame(minHeight: MiniatureMetrics.chipHeight)
            .padding(.horizontal, entry == .separator ? 1 : (entry == .part(.print) && !showsName ? 1 : 4))
            .background {
                CornerRole.control.shape
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : (plain ? .clear : PrintPalette.raised))
                CornerRole.control.shape
                    .strokeBorder(
                        isSelected ? Color.accentColor : (plain ? .clear : PrintPalette.line2),
                        lineWidth: isSelected ? 1.5 : 1)
            }
            .id(selection)
            .contentShape(Rectangle())
            .onTapGesture { session.select(selection) }
            // Like a button: in the key view loop only with keyboard navigation, so a click never leaves a focus ring.
            .focusable(interactions: .activate)
            .onKeyPress(keys: [.space, .return]) { _ in
                session.select(selection)
                return .handled
            }
            .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                session.select(selection)
                session.removeSelection()
                return .handled
            }
            .onKeyPress(keys: [.leftArrow, .rightArrow], phases: .down) { press in
                guard press.modifiers.contains(.option) else { return .ignored }
                session.select(selection)
                session.moveSelection(by: press.key == .leftArrow ? -1 : 1)
                return .handled
            }
            .onDrag {
                BandEditorDrop.provider(session.beginDrag(.entry(location, entry)))
            }
            .help(help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: name))
            .accessibilityValue(Text(verbatim: positionText))
            .accessibilityHint(entry == .part(.print) ? Text("Required; cannot be removed.") : Text(verbatim: ""))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { session.select(selection) }
            .accessibilityActions { BandEntryActions(session: session, selection: selection) }
    }

    /// The miniature's parts on the band need no chip of their own around a separator or the vermilion Print.
    private var plain: Bool { !showsName && (entry == .separator || entry == .part(.print)) }

    @ViewBuilder private var content: some View {
        switch entry {
        case .separator:
            SeparatorMark(isIdle: isIdle)
        case .part(let item):
            HStack(spacing: 6) {
                BandPartGlyph(item: item, besideName: showsName)
                if showsName {
                    Text(verbatim: item.editorName).font(.system(size: 12)).foregroundStyle(PrintPalette.ink)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var name: String {
        entry.item?.editorName ?? String(localized: "Separator")
    }

    private var help: String {
        guard let item = entry.item else {
            return isIdle
                ? String(localized: "Separator: appears on the toolbar only between two parts.")
                : String(localized: "Separator")
        }
        return choice(item.editorName, item.editorDescription)
    }

    private var positionText: String {
        let count = session.arrangement[location.destination].count
        return String(
            format: String(localized: "%1$@, position %2$lld of %3$lld"), location.destination.editorName,
            location.index + 1, count)
            + (entry.item?.editorAvailability.map { ". " + $0 } ?? "")
    }
}

/// The accessibility actions of a chip, the same moves as the inspector's buttons.
private struct BandEntryActions: View {
    let session: BandArrangementEditorSession
    let selection: BandEditorSelection?

    var body: some View {
        Button("Move Earlier") { act { session.moveSelection(by: -1) } }
        Button("Move Later") { act { session.moveSelection(by: 1) } }
        ForEach(session.zones, id: \.self) { zone in
            Button(String(format: String(localized: "Move to %@"), zone.editorName)) {
                act { session.moveSelection(to: .zone(zone)) }
            }
        }
        if case .separator = selection {
            Button("Delete") { act { session.removeSelection() } }
        } else if selection != .part(.print) {
            Button("Remove from Toolbar") { act { session.removeSelection() } }
        }
    }

    private func act(_ action: () -> Void) {
        session.select(selection)
        action()
    }
}

private struct SeparatorMark: View {
    let isIdle: Bool

    var body: some View {
        Rectangle()
            .fill(isIdle ? PrintPalette.line3 : PrintPalette.ink3)
            .frame(width: 1.5, height: 16)
            .opacity(isIdle ? 0.7 : 1)
            .frame(width: 7)
    }
}

// MARK: - Parts to Add

private struct UnusedPalette: View {
    let session: BandArrangementEditorSession

    private var heading: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Parts to Add").font(.headline)
            Text("All operations are also available in “…”.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var body: some View {
        let unused = session.arrangement.unused
        let targeted = session.dropTarget == .unused
        VStack(alignment: .leading, spacing: 8) {
            // Beside the miniature the palette is narrow: the separator then goes under the explanation.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 10) {
                    heading
                    Spacer(minLength: 0)
                    SeparatorSource(session: session)
                }
                VStack(alignment: .leading, spacing: 8) {
                    heading
                    SeparatorSource(session: session)
                }
            }
            if unused.isEmpty {
                Text("Every part is on the toolbar.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(BandPaletteGroup.project(unused)) { group in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(verbatim: group.id.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityAddTraits(.isHeader)
                        FlowLayout(spacing: 6, constrainsChips: true) {
                            ForEach(group.parts) { part in
                                EntryChip(
                                    session: session, location: part.location,
                                    entry: .part(part.id), showsName: true
                                )
                                .onGeometryChange(for: CGRect.self) {
                                    $0.frame(in: .named("band-editor"))
                                } action: {
                                    session.layoutFrames["unused-" + part.id.rawValue] = $0
                                }
                            }
                        }
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named("band-editor"))
        } action: {
            session.layoutFrames["palette"] = $0
        }
        .background {
            // The grouped forms' box, so the editor sits on the same ground as the other sections.
            CornerRole.tile.shape.fill(
                targeted ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(.quinary))
            if targeted { CornerRole.tile.shape.strokeBorder(Color.accentColor, lineWidth: 1.5) }
        }
        .onDrop(
            of: [.utf8PlainText], delegate: BandEditorDropDelegate(session: session, target: { _ in .unused })
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Parts to Add"))
    }
}

/// The palette's separator, which can be dragged into the zones any number of times. Pressed, it adds one after the
/// selected entry.
private struct SeparatorSource: View {
    let session: BandArrangementEditorSession

    var body: some View {
        Button {
            session.insertSeparatorAfterSelection()
        } label: {
            HStack(spacing: 6) {
                SeparatorMark(isIdle: false)
                Text("Separator").font(.system(size: 12))
                Image(systemName: "plus").font(.system(size: 9, weight: .bold)).foregroundStyle(PrintPalette.ink2)
            }
            .padding(.horizontal, 7)
            .frame(height: MiniatureMetrics.chipHeight)
            .background {
                CornerRole.control.shape.fill(PrintPalette.raised)
                CornerRole.control.shape
                    .strokeBorder(PrintPalette.line3, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(PrintPalette.ink)
        .onDrag { BandEditorDrop.provider(session.beginDrag(.newSeparator)) }
        .help("Drag into a zone, or select a part and press to add a separator after it.")
        .accessibilityHint(Text("Adds a separator after the selected part."))
    }
}

// MARK: - Inspector

private struct Inspector: View {
    let session: BandArrangementEditorSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let location = session.selectedLocation, let entry = session.selectedEntry {
                details(location, entry)
            } else {
                Text("Select a part to see what it does and where it can go.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CornerRole.tile.shape.fill(.quinary))
    }

    @ViewBuilder
    private func details(_ location: BandEntryLocation, _ entry: BandEntry) -> some View {
        let count = session.arrangement[location.destination].count
        HStack(alignment: .center, spacing: 10) {
            Group {
                if let item = entry.item { BandPartGlyph(item: item) } else { SeparatorMark(isIdle: false) }
            }
            .frame(minWidth: 30, minHeight: MiniatureMetrics.chipHeight)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: entry.item?.editorName ?? String(localized: "Separator"))
                    .font(.system(size: 13, weight: .semibold))
                Text(
                    verbatim: String(
                        format: String(localized: "%1$@, position %2$lld of %3$lld"),
                        location.destination.editorName, location.index + 1, count)
                )
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        Group {
            if let item = entry.item {
                Text(verbatim: item.editorDescription)
                if let availability = item.editorAvailability {
                    Text(verbatim: availability).foregroundStyle(.secondary)
                }
            } else {
                Text("Draws a thin line between the parts on either side.")
                if case .zone(let zone) = location.destination, session.separatorIsIdle(at: location.index, in: zone) {
                    Text("Not shown in this position.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.system(size: 12))
        .fixedSize(horizontal: false, vertical: true)
        let destination = Binding(get: { location.destination }, set: { session.moveSelection(to: $0) })
        HStack(spacing: 8) {
            Text("Move To").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize()
            // Segments show every place at once; a pop-up menu takes their place when they do not fit.
            ViewThatFits(in: .horizontal) {
                destinationPicker(destination, entry).pickerStyle(.segmented).controlSize(.small).fixedSize()
                destinationPicker(destination, entry).pickerStyle(.menu).controlSize(.small).fixedSize()
            }
            Spacer(minLength: 0)
        }
        if case .zone = location.destination {
            HStack(spacing: 8) {
                Button {
                    session.moveSelection(by: -1)
                } label: {
                    Label("Move Earlier", systemImage: "chevron.left")
                }
                .disabled(!session.canMove(location, by: -1))
                .help("Move Earlier (⌥←)")
                Button {
                    session.moveSelection(by: 1)
                } label: {
                    Label("Move Later", systemImage: "chevron.right")
                }
                .disabled(!session.canMove(location, by: 1))
                .help("Move Later (⌥→)")
                Button("Add Separator After") { session.insertSeparatorAfterSelection() }
                Spacer(minLength: 0)
                if entry == .separator {
                    Button("Delete", role: .destructive) { session.removeSelection() }
                }
            }
            .controlSize(.small)
        }
    }

    private func destinationPicker(_ selection: Binding<BandDestination>, _ entry: BandEntry) -> some View {
        Picker("Move To", selection: selection) {
            ForEach(destinations(for: entry), id: \.self) { destination in
                Text(verbatim: destination.editorName).tag(destination)
            }
        }
        .labelsHidden()
    }

    /// A separator has no place in "Parts to Add": it is deleted instead. Print may not go there at all.
    private func destinations(for entry: BandEntry) -> [BandDestination] {
        session.destinations.filter { $0 != .unused || entry.item.map { $0 != .print } == true }
    }
}

// MARK: - Dialogs

/// Naming a set (Duplicate, New, Rename, and the copy a changed Standard is saved as) and deleting the set in use.
private struct BandArrangementDialog: View {
    let session: BandArrangementEditorSession
    let dialog: BandArrangementEditorSession.Dialog
    @State private var name = ""
    @State private var problem: String?
    @State private var replacement: BandArrangementSelection = .standard
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: title).font(.headline)
            if dialog == .delete {
                deleteContent
            } else {
                nameContent
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    // Naming the copy was part of saving before leaving or quitting: neither happens now.
                    if dialog == .saveCopy { session.cancelLeave() }
                    session.dialog = nil
                }
                .keyboardShortcut(.cancelAction)
                if dialog == .delete {
                    // Return does not delete: the destructive button is never the default.
                    Button("Delete", role: .destructive) { confirm() }
                } else {
                    Button("Save") { confirm() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            switch dialog {
            case .duplicate, .saveCopy: name = session.proposedCopyName()
            case .new: name = session.proposedNewName()
            case .rename: name = session.activeName
            case .delete: replacement = .standard
            }
        }
    }

    private var title: String {
        switch dialog {
        case .duplicate: String(localized: "Duplicate Arrangement")
        case .saveCopy: String(localized: "Save as a New Arrangement")
        case .new: String(localized: "New Arrangement")
        case .rename: String(localized: "Rename Arrangement")
        case .delete: String(format: String(localized: "Delete “%@”?"), session.activeName)
        }
    }

    @ViewBuilder private var nameContent: some View {
        switch dialog {
        case .duplicate, .saveCopy:
            Text(
                "The arrangement on screen, unsaved changes included, is saved under this name and used in all view windows."
            )
            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .new:
            Text("A new arrangement starts as Standard and is used in all view windows.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        default:
            EmptyView()
        }
        TextField("Arrangement Name", text: $name)
            .textFieldStyle(.roundedBorder)
            .onChange(of: name) { problem = nil }
            .onSubmit { confirm() }
        if let problem {
            Text(verbatim: problem).font(.system(size: 11)).foregroundStyle(.red)
        }
    }

    @ViewBuilder private var deleteContent: some View {
        Text("This arrangement is in use. Choose the one all view windows use instead.")
            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Picker("Use Instead", selection: $replacement) {
            ForEach(session.replacements, id: \.self) { selection in
                Text(verbatim: session.name(of: selection)).tag(selection)
            }
        }
        if session.isDirty {
            Text("The unsaved changes are discarded with it.").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        Text("You can undo this.").font(.system(size: 11)).foregroundStyle(.secondary)
    }

    private func confirm() {
        let result: String?
        switch dialog {
        case .duplicate, .saveCopy: result = session.duplicate(named: name)
        case .new: result = session.createSet(named: name)
        case .rename:
            result = session.nameProblem(name, excluding: session.active) ?? session.rename(to: name)
        case .delete: result = session.deleteActive(replacement: replacement)
        }
        if let result {
            problem = result
            return
        }
        session.dialog = nil
        if dialog == .saveCopy { session.proceed() }
    }
}

// MARK: - Layout

/// Lines of chips that wrap at the proposed width, each line centered on its tallest chip.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4
    var constrainsChips = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (subview, frame) in zip(subviews, result.frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: .init(frame.size))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        let sizes = subviews.map {
            let ideal = $0.sizeThatFits(.unspecified)
            return constrainsChips && ideal.width > width
                ? $0.sizeThatFits(ProposedViewSize(width: width, height: nil)) : ideal
        }
        var lines: [[Int]] = [[]]
        var x: CGFloat = 0
        for (index, size) in sizes.enumerated() {
            let needed = lines[lines.count - 1].isEmpty ? size.width : x + spacing + size.width
            if !lines[lines.count - 1].isEmpty, needed > width + 0.5 {
                lines.append([index])
                x = size.width
            } else {
                lines[lines.count - 1].append(index)
                x = needed
            }
        }
        var frames = Array(repeating: CGRect.zero, count: sizes.count)
        var y: CGFloat = 0
        var widest: CGFloat = 0
        for line in lines where !line.isEmpty {
            let height = line.map { sizes[$0].height }.max() ?? 0
            var x: CGFloat = 0
            for index in line {
                frames[index] = CGRect(
                    x: x, y: y + (height - sizes[index].height) / 2, width: sizes[index].width,
                    height: sizes[index].height)
                x += sizes[index].width + spacing
            }
            widest = max(widest, x - spacing)
            y += height + lineSpacing
        }
        return (frames, CGSize(width: max(widest, 0), height: max(y - lineSpacing, 0)))
    }
}

// MARK: - Drag and drop

enum BandEditorDrop {
    /// Only this app can read the payload: dragged onto another app, a chip carries nothing.
    static func provider(_ payload: BandEditorPayload) -> NSItemProvider {
        let provider = NSItemProvider()
        let data = Data(payload.string.utf8)
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .ownProcess
        ) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    /// The entry a drop at `point` goes before: the first chip on the pointer's line whose middle is past the
    /// pointer, or the end of that line. Frames are the zone's chips in order, in the zone's coordinates.
    static func insertionIndex(at point: CGPoint, frames: [CGRect]) -> Int {
        guard !frames.isEmpty else { return 0 }
        let onLine = frames.indices.filter { frames[$0].minY - 3 <= point.y && point.y <= frames[$0].maxY + 3 }
        let line: [Int]
        if onLine.isEmpty {
            // Above or below every line: the nearest one.
            let nearest = frames.indices.min { abs(frames[$0].midY - point.y) < abs(frames[$1].midY - point.y) } ?? 0
            line = frames.indices.filter { abs(frames[$0].midY - frames[nearest].midY) < 1 }
        } else {
            line = onLine
        }
        if let before = line.first(where: { frames[$0].midX > point.x }) { return before }
        return (line.last ?? frames.count - 1) + 1
    }

    /// Where the insertion marker stands for a drop before `index`, between two chips or after the last one.
    static func marker(at index: Int, frames: [CGRect]) -> CGRect? {
        guard !frames.isEmpty else { return nil }
        let half = MiniatureMetrics.chipSpacing / 2
        if index < frames.count {
            let frame = frames[index]
            return CGRect(x: frame.minX - half - 1.25, y: frame.minY, width: 2.5, height: frame.height)
        }
        guard let frame = frames.last else { return nil }
        return CGRect(x: frame.maxX + half - 1.25, y: frame.minY, width: 2.5, height: frame.height)
    }

    /// Reads the one payload of a drop and hands it to the session; nothing else is accepted.
    static func perform(_ info: DropInfo, on target: BandEditorDropTarget, session: BandArrangementEditorSession)
        -> Bool
    {
        let providers = info.itemProviders(for: [.utf8PlainText])
        guard providers.count == 1, let provider = providers.first else {
            session.dropTarget = nil
            return false
        }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier) { data, _ in
            let text = data.flatMap { String(data: $0, encoding: .utf8) }
            Task { @MainActor in
                guard let text, let payload = BandEditorPayload(string: text) else {
                    session.dropTarget = nil
                    return
                }
                session.drop(payload, on: target)
            }
        }
        return true
    }
}

struct BandEditorDropDelegate: DropDelegate {
    let session: BandArrangementEditorSession
    let target: (CGPoint) -> BandEditorDropTarget

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.utf8PlainText]) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let target = target(info.location)
        if session.dropTarget != target { session.dropTarget = target }
        return DropProposal(operation: session.proposal(for: target))
    }

    func dropExited(info: DropInfo) {
        if session.dropTarget == target(info.location) { session.dropTarget = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        let target = target(info.location)
        guard session.proposal(for: target) != .forbidden else {
            session.dropTarget = nil
            return false
        }
        return BandEditorDrop.perform(info, on: target, session: session)
    }
}
