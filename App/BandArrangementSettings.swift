import SurimonoCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings > Toolbar Arrangement: the active set's two variants drawn on a miniature of the view mode's window, where
/// parts and separators are dragged between the zones and "Parts to Add", or moved with the inspector's buttons.
struct BandArrangementSettings: View {
    @Bindable var session: BandArrangementEditorSession
    let hints: BandHintSession
    @AccessibilityFocusState(for: .voiceOver) private var focusedAccessibleChip: BandEditorSelection?

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { pane in
                editorScroll(paneWidth: pane.size.width)
                    .modifier(SettingsSearchReveal(proxy: proxy, isForm: false))
            }
            .task(id: session.accessibilityFocusDestination) {
                guard let destination = session.accessibilityFocusDestination else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                focusedAccessibleChip = destination
                session.accessibilityFocusDestination = nil
            }
            .task(id: session.selectionRevealRevision) {
                guard session.selectionRevealRevision > 0 else { return }
                // Let the destination chip enter the updated layout before resolving its scroll identity.
                await Task.yield()
                guard !Task.isCancelled, let selection = session.selection else { return }
                // Without an anchor SwiftUI moves only as far as needed to reveal the chip.
                proxy.scrollTo(Optional(selection))
            }
        }
        .modifier(
            BandHintHost(session: hints, editor: true, blocked: session.dialog != nil || session.pendingLeave != nil)
        )
    }

    private var partsRow: some View {
        @Bindable var preferences = session.preferences
        return HStack(spacing: 10) {
            Text("Parts").fixedSize()
            Picker("Parts", selection: $preferences.bandNames) {
                Text("Icons and Names").tag(BandLayout.Names.shown)
                Text("Icons Only").tag(BandLayout.Names.hidden)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    private func editorScroll(paneWidth: CGFloat) -> some View {
        ScrollView {
            BandEditorPageLayout(paneWidth: paneWidth) {
                VStack(alignment: .leading, spacing: 10) {
                    partsRow.settingSearchRow("Parts")
                    if session.needsRecovery { RecoveryNotice(session: session).settingSearchRow("Start Over") }
                    RepairNotice(notices: session.preferences.bandArrangementNotices)
                    if session.hasConflict { ConflictNotice(session: session).settingSearchRow("Use Saved") }
                    Group {
                        SetBar(session: session).settingSearchRow("Arrangement Set")
                        StatusRow(session: session)
                        ModeRow(session: session).settingSearchRow("Editing")
                    }
                    .disabled(session.needsRecovery)
                }
                ArrangementMiniature(session: session, accessibilityFocus: $focusedAccessibleChip).settingSearchRow(
                    "Toolbar Arrangement"
                )
                .disabled(session.needsRecovery)
                MiniatureNotes(session: session)
                    .disabled(session.needsRecovery)
                UnusedPalette(session: session, accessibilityFocus: $focusedAccessibleChip).settingSearchRow(
                    "Parts to Add"
                )
                .disabled(session.needsRecovery)
                Inspector(session: session).settingSearchRow("Move To")
                    .disabled(session.needsRecovery)
            }
            .padding(.vertical, 14)
        }
        .coordinateSpace(name: "band-editor")
        // A change saved elsewhere: followed while nothing is unsaved, told as a conflict otherwise.
        .onChange(of: session.store) { session.refresh() }
        .contentShape(Rectangle())
        .onDrop(of: [.utf8PlainText], delegate: BandEditorDropDelegate(session: session))
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
                (Text(Image(systemName: "circle.fill")).font(.system(size: 10)).baselineOffset(1.5)
                    + Text(verbatim: " ") + Text("Unsaved Changes").fontWeight(.semibold)
                    + Text(verbatim: "  ")
                    + Text("Save to apply to all view windows.").foregroundStyle(PrintPalette.ink2))
                    .foregroundStyle(PrintPalette.warn)
            } else {
                Text("All view windows use this arrangement.").foregroundStyle(PrintPalette.ink2)
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
/// windows use is chosen in View and Page Turn.
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
                .foregroundStyle(PrintPalette.ink2)
                .fixedSize()
                .help("Change it under View and Page Turn > Toolbar Layout.")
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
                Image(systemName: "wrench.and.screwdriver").foregroundStyle(.tint).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Some saved toolbar arrangements were repaired when they were read.").fontWeight(.semibold)
                    ForEach(lines, id: \.self) { line in
                        Text(verbatim: "• " + line)
                    }
                    Text("The data as it was read is kept aside the first time you save.")
                        .foregroundStyle(PrintPalette.ink2)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12))
            .padding(12)
            .background(
                CornerRole.tile.shape.fill(
                    DisplayAccessibility.shared.options.fill(.accentColor, opacity: 0.1, over: PrintPalette.raised)))
        }
    }
}

/// The saved arrangement changed elsewhere under unsaved changes: Overwrite is off; a copy keeps the changes.
private struct ConflictNotice: View {
    let session: BandArrangementEditorSession

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(PrintPalette.warn).accessibilityHidden(
                true)
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
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(PrintPalette.warn).accessibilityHidden(
                true)
            VStack(alignment: .leading, spacing: 6) {
                Text("The saved toolbar arrangements could not be read.").fontWeight(.semibold)
                Text(
                    "The toolbar uses Standard for now, and nothing is saved. Starting over keeps the unreadable data aside instead of deleting it."
                )
                .foregroundStyle(PrintPalette.ink2)
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

struct ArrangementMiniature: View {
    let session: BandArrangementEditorSession
    let accessibilityFocus: AccessibilityFocusState<BandEditorSelection?>.Binding

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
                ZoneEditor(session: session, accessibilityFocus: accessibilityFocus, zone: .topLeft)
                ZoneEditor(session: session, accessibilityFocus: accessibilityFocus, zone: .topRight)
                if !docksMore { MoreLock() }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(minHeight: MiniatureMetrics.bandHeight)
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named("band-editor"))
            } action: {
                session.layoutFrames["topBand"] = $0
            }
            .background(PrintPalette.raised)
            .overlay(alignment: .bottom) { Divider() }
            Paper(spread: true)
                .frame(height: session.mode == .split ? 46 : 72)
            if session.mode == .split {
                MiniatureBandLayout(fixedPrefix: 0) {
                    ZoneEditor(session: session, accessibilityFocus: accessibilityFocus, zone: .bottomLeft)
                    ZoneEditor(session: session, accessibilityFocus: accessibilityFocus, zone: .bottomRight)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(minHeight: MiniatureMetrics.bandHeight)
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .named("band-editor"))
                } action: {
                    session.layoutFrames["bottomBand"] = $0
                }
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
    private var docksMore: Bool { session.arrangement.topRight.last { $0.item != nil } == .part(.print) }
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
                    .overlay(Circle().strokeBorder(PrintPalette.line2, lineWidth: DisplayAccessibility.hairline))
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
                Image(systemName: "lock.fill").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(PrintPalette.ink3)
                    .padding(1)
                    .background(Circle().fill(PrintPalette.raised))
                    .offset(x: 3, y: 3)
            }
            .frame(width: 24, height: MiniatureMetrics.chipHeight)
            .help("“…” is fixed. All operations are also available here.")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("More")
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
    let accessibilityFocus: AccessibilityFocusState<BandEditorSelection?>.Binding
    let zone: BandZoneID
    @FocusState private var focusedChip: BandEditorSelection?

    var body: some View {
        let entries = session.arrangement[zone]
        let space = "zone-\(zone.rawValue)"
        let targeted = session.dropTarget.map { if case .zone(zone, _) = $0 { true } else { false } } ?? false
        FlowLayout(spacing: MiniatureMetrics.chipSpacing) {
            ForEach(Self.identified(entries), id: \.id) { index, entry, _ in
                if zone == .topRight, entry == .part(.print), entries[(index + 1)...].allSatisfy({ $0 == .separator }) {
                    MoreLock()
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: DockedMoreFrame.self, value: geometry.frame(in: .named(space)))
                            }
                        }
                }
                EntryChip(
                    session: session, accessibilityFocus: accessibilityFocus,
                    location: BandEntryLocation(destination: .zone(zone), index: index), entry: entry,
                    didMoveWithKeys: { focusedChip = session.selection }
                )
                .focused($focusedChip, equals: entry.item.map(BandEditorSelection.part) ?? .separator(zone, index))
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: BandChipFrames.self, value: [index: geometry.frame(in: .named(space))])
                    }
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
                .fill(
                    targeted
                        ? DisplayAccessibility.shared.options.fill(
                            .accentColor, opacity: 0.12, over: PrintPalette.raised) : .clear)
            CornerRole.largeControl.shape
                .strokeBorder(
                    targeted
                        ? (DisplayAccessibility.shared.options.increasedContrast
                            ? PrintPalette.ink2 : Color.accentColor) : PrintPalette.line3,
                    style: StrokeStyle(lineWidth: targeted ? 1.5 : 1, dash: targeted ? [] : [3, 3])
                )
                .opacity(entries.isEmpty || session.dropTarget != nil ? 1 : 0)
        }
        .overlay(alignment: .topLeading) {
            if case .zone(zone, let index) = session.dropTarget,
                let marker = session.dropMarker
                    ?? BandEditorDrop.Slots(zone: zone, session: session).marker(at: index)
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
        .onPreferenceChange(DockedMoreFrame.self) { frame in
            if zone == .topRight { session.dockedMoreFrame = frame }
        }
        .onPreferenceChange(BandChipFrames.self) { frames in
            // Publish one complete layout. An unmeasured zone accepts drops at its end.
            let ordered = (0..<entries.count).compactMap { frames[$0] }
            session.chipFrames[zone] = ordered.count == entries.count ? ordered : []
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: zone.editorName))
        .accessibilityAction(named: Text("Add Separator")) {
            session.insertSeparator(in: zone, at: entries.count)
        }
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
                .foregroundStyle(PrintPalette.ink2)
            if session.message == nil, !session.hasIdleSeparators {
                Text("Narrow windows hide parts of the toolbar.")
                    .foregroundStyle(PrintPalette.ink2)
            }
            if let message = session.message {
                Label {
                    Text(verbatim: message.text)
                } icon: {
                    Image(systemName: message.isWarning ? "exclamationmark.circle" : "checkmark.circle")
                }
                .foregroundStyle(
                    message.isWarning ? AnyShapeStyle(PrintPalette.warn) : AnyShapeStyle(PrintPalette.ink2))
            }
            if session.hasIdleSeparators {
                Label {
                    Text("A faint separator appears on the toolbar only between two parts.")
                } icon: {
                    Image(systemName: "info.circle")
                }
                .foregroundStyle(PrintPalette.ink2)
            }
        }
        .font(.system(size: 11))
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Chips

/// One entry of the draft: a part drawn as on the band, or a separator. Click or Space selects it, and it drags.
private struct EntryChip: View {
    @Environment(\.bandHints) private var hints
    let session: BandArrangementEditorSession
    let accessibilityFocus: AccessibilityFocusState<BandEditorSelection?>.Binding
    let location: BandEntryLocation
    let entry: BandEntry
    var showsName = false
    var didMoveWithKeys: () -> Void = {}

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
        let name = entry.item?.editorName ?? String(localized: "Separator")
        let hint =
            entry.item.map(BandHintContent.editor)
            ?? .init(name: name, detail: String(localized: "Separator: appears on the toolbar only between two parts."))
        content(name: name)
            .frame(minHeight: MiniatureMetrics.chipHeight)
            .padding(.horizontal, entry == .separator ? 1 : (entry == .part(.print) && !showsName ? 1 : 4))
            .background {
                CornerRole.control.shape
                    .fill(
                        isSelected
                            ? DisplayAccessibility.shared.options.fill(
                                .accentColor, opacity: 0.18, over: PrintPalette.raised)
                            : (plain ? .clear : PrintPalette.raised))
                CornerRole.control.shape
                    .strokeBorder(
                        isSelected
                            ? (DisplayAccessibility.shared.options.increasedContrast
                                ? PrintPalette.ink2 : Color.accentColor) : (plain ? .clear : PrintPalette.line2),
                        lineWidth: isSelected ? 1.5 : 1)
            }
            .settingSearchRow(
                entry.item?.rawValue ?? "separator-\(location.destination)-\(location.index)", fillsRow: false
            )
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
                didMoveWithKeys()
                return .handled
            }
            .onDrag {
                hints?.beginDrag()
                return BandEditorDrop.provider(session.beginDrag(.entry(location, entry)))
            }
            .bandHint(
                entry.item?.rawValue ?? "separator-\(location.destination)-\(location.index)",
                hint
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: name))
            .accessibilityValue(Text(verbatim: positionText))
            .accessibilityHint(Text(verbatim: hint.accessibilityHint))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { session.select(selection) }
            .accessibilityActions { BandEntryActions(session: session, selection: selection) }
            .accessibilityFocused(accessibilityFocus, equals: selection)
    }

    /// The miniature's parts on the band need no chip of their own around a separator or the vermilion Print.
    private var plain: Bool { !showsName && (entry == .separator || entry == .part(.print)) }

    @ViewBuilder private func content(name: String) -> some View {
        switch entry {
        case .separator:
            SeparatorMark(isIdle: isIdle)
        case .part(let item):
            HStack(spacing: 6) {
                BandPartGlyph(
                    item: item, besideName: showsName,
                    iconOnly: !showsName && session.preferences.bandNames == .hidden)
                if showsName {
                    Text(verbatim: name).font(.system(size: 12)).foregroundStyle(PrintPalette.ink)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
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
        session.performAccessibilityAction(on: selection, action)
    }
}

private struct SeparatorMark: View {
    let isIdle: Bool

    var body: some View {
        Rectangle()
            .fill(isIdle ? PrintPalette.line3 : PrintPalette.ink3)
            .frame(width: 1.5, height: 16)
            .frame(width: 7)
    }
}

// MARK: - Parts to Add

struct UnusedPalette: View {
    let session: BandArrangementEditorSession
    let accessibilityFocus: AccessibilityFocusState<BandEditorSelection?>.Binding

    private var heading: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Parts to Add").font(.headline)
            Text("All operations are also available in “…”.")
                .font(.caption)
                .foregroundStyle(PrintPalette.ink2)
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
                Text("Every part is on the toolbar.").font(.caption).foregroundStyle(PrintPalette.ink2)
            } else {
                ForEach(BandPaletteGroup.project(unused)) { group in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(verbatim: group.id.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(PrintPalette.ink2)
                            .accessibilityAddTraits(.isHeader)
                        FlowLayout(spacing: 6, constrainsChips: true) {
                            ForEach(group.parts) { part in
                                EntryChip(
                                    session: session, accessibilityFocus: accessibilityFocus, location: part.location,
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
                targeted
                    ? AnyShapeStyle(
                        DisplayAccessibility.shared.options.fill(.accentColor, opacity: 0.12, over: PrintPalette.raised)
                    ) : AnyShapeStyle(PrintPalette.hover))
            if targeted {
                CornerRole.tile.shape.strokeBorder(
                    DisplayAccessibility.shared.options.increasedContrast ? PrintPalette.ink2 : Color.accentColor,
                    lineWidth: 1.5)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Parts to Add"))
    }
}

/// The palette's separator, which can be dragged into the zones any number of times. Pressed, it adds one after the
/// selected entry.
private struct SeparatorSource: View {
    @Environment(\.bandHints) private var hints
    let session: BandArrangementEditorSession

    var body: some View {
        let detail = String(localized: "Drag into a zone, or select a part and press to add a separator after it.")
        let insertion =
            hasZoneSelection
            ? String(localized: "Adds a separator after the selected part.")
            : choice(String(localized: "Add Separator"), BandZoneID.topLeft.editorName)
        Button {
            session.insertSeparatorAfterSelection()
        } label: {
            HStack(spacing: 6) {
                SeparatorMark(isIdle: false)
                Text("Separator").font(.system(size: 12))
                Image(systemName: "plus").font(.system(size: 10, weight: .bold)).foregroundStyle(PrintPalette.ink2)
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
        .onDrag {
            hints?.beginDrag()
            return BandEditorDrop.provider(session.beginDrag(.newSeparator))
        }
        .bandHint(
            "separator",
            .init(name: String(localized: "Separator"), detail: detail)
        )
        .accessibilityHint(Text(verbatim: detail + " " + insertion))
    }

    private var hasZoneSelection: Bool {
        if case .zone = session.selectedLocation?.destination { return true }
        return false
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
                    .foregroundStyle(PrintPalette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CornerRole.tile.shape.fill(PrintPalette.hover))
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
                .font(.system(size: 11)).foregroundStyle(PrintPalette.ink2)
            }
            Spacer(minLength: 0)
        }
        Group {
            if let item = entry.item {
                Text(verbatim: item.editorDescription)
                if let availability = item.editorAvailability {
                    Text(verbatim: availability).foregroundStyle(PrintPalette.ink2)
                }
            } else {
                Text("Draws a thin line between the parts on either side.")
                if case .zone(let zone) = location.destination, session.separatorIsIdle(at: location.index, in: zone) {
                    Text("Not shown in this position.")
                        .foregroundStyle(PrintPalette.ink2)
                }
            }
        }
        .font(.system(size: 12))
        .fixedSize(horizontal: false, vertical: true)
        let destination = Binding(get: { location.destination }, set: { session.moveSelection(to: $0) })
        HStack(spacing: 8) {
            Text("Move To").font(.system(size: 12)).foregroundStyle(PrintPalette.ink2).fixedSize()
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
            .font(.system(size: 12)).foregroundStyle(PrintPalette.ink2).fixedSize(horizontal: false, vertical: true)
        case .new:
            Text("A new arrangement starts as Standard and is used in all view windows.")
                .font(.system(size: 12)).foregroundStyle(PrintPalette.ink2).fixedSize(horizontal: false, vertical: true)
        default:
            EmptyView()
        }
        TextField("Arrangement Name", text: $name)
            .textFieldStyle(.roundedBorder)
            .onChange(of: name) { problem = nil }
            .onSubmit { confirm() }
        if let problem {
            Text(verbatim: problem).font(.system(size: 11)).foregroundStyle(PrintPalette.warn)
        }
    }

    @ViewBuilder private var deleteContent: some View {
        Text("This arrangement is in use. Choose the one all view windows use instead.")
            .font(.system(size: 12)).foregroundStyle(PrintPalette.ink2).fixedSize(horizontal: false, vertical: true)
        Picker("Use Instead", selection: $replacement) {
            ForEach(session.replacements, id: \.self) { selection in
                Text(verbatim: session.name(of: selection)).tag(selection)
            }
        }
        if session.isDirty {
            Text("The unsaved changes are discarded with it.").font(.system(size: 11)).foregroundStyle(
                PrintPalette.ink2)
        }
        Text("You can undo this.").font(.system(size: 11)).foregroundStyle(PrintPalette.ink2)
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

/// The direct child of the vertical scroll view gets its cross-axis proposal before any controls are measured.
/// A wide header or chip may ask for more room, but cannot change its neighbour's wrapping width.
private struct BandEditorPageLayout: Layout {
    let paneWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = min(proposal.width ?? paneWidth, paneWidth)
        let frames = arrange(width: width, subviews: subviews)
        return CGSize(width: width, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (child, frame) in zip(subviews, arrange(width: bounds.width, subviews: subviews)) {
            child.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading, proposal: ProposedViewSize(width: frame.width, height: nil))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [CGRect] {
        // Header, miniature, notes, palette, inspector. Only the header has conditional children.
        guard subviews.count == 5 else { return [] }
        let margin: CGFloat = 20
        let rowSpacing: CGFloat = 10
        let columnSpacing: CGFloat = 14
        let pageWidth = max(0, width - 2 * margin)
        let beside = width >= 760
        let paletteWidth = beside ? 230 : pageWidth
        let editorWidth = beside ? pageWidth - paletteWidth - columnSpacing : pageWidth

        func frame(_ child: LayoutSubview, offset: CGFloat = 0, y: CGFloat, width: CGFloat) -> CGRect {
            let size = child.sizeThatFits(ProposedViewSize(width: width, height: nil))
            return CGRect(x: margin + offset, y: y, width: width, height: size.height)
        }
        let header = frame(subviews[0], y: 0, width: pageWidth)
        let miniature = frame(subviews[1], y: header.maxY + rowSpacing, width: editorWidth)
        let notes = frame(subviews[2], y: miniature.maxY + rowSpacing, width: editorWidth)
        let palette = frame(
            subviews[3], offset: beside ? editorWidth + columnSpacing : 0,
            y: beside ? miniature.minY : notes.maxY + rowSpacing, width: paletteWidth)
        let inspector = frame(subviews[4], y: (beside ? notes.maxY : palette.maxY) + rowSpacing, width: editorWidth)
        return [header, miniature, notes, palette, inspector]
    }
}

/// Lines of chips that wrap at the proposed width, each line centered on its tallest chip.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4
    var constrainsChips = false

    // Measurement and placement normally use the same width. Intrinsic sizes also survive width-only changes.
    struct Cache {
        let ideals: [CGSize]
        var width: CGFloat?
        var result: (frames: [CGRect], size: CGSize) = ([], .zero)
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(ideals: subviews.map { $0.sizeThatFits(.unspecified) })
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews, cache: &cache).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let result = arrange(width: bounds.width, subviews: subviews, cache: &cache)
        for (subview, frame) in zip(subviews, result.frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: .init(frame.size))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews, cache: inout Cache) -> (frames: [CGRect], size: CGSize) {
        if cache.width == width { return cache.result }
        let sizes = zip(subviews, cache.ideals).map { subview, ideal in
            return constrainsChips && ideal.width > width
                ? subview.sizeThatFits(ProposedViewSize(width: width, height: nil)) : ideal
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
        cache.width = width
        cache.result = (frames, CGSize(width: max(widest, 0), height: max(y - lineSpacing, 0)))
        return cache.result
    }
}

// MARK: - Drag and drop

private struct DockedMoreFrame: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

private struct BandChipFrames: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

enum BandEditorDrop {
    /// The lock occupies a place in the flow, but inserts before and after it both land before Print.
    struct Slots {
        let frames: [CGRect]
        let lockIndex: Int?

        init(zone: BandZoneID, session: BandArrangementEditorSession) {
            var frames = session.chipFrames[zone, default: []]
            let entries = session.arrangement[zone]
            if zone == .topRight, let lock = session.dockedMoreFrame, frames.count == entries.count,
                let last = entries.lastIndex(where: { $0.item != nil }), entries[last] == .part(.print)
            {
                frames.insert(lock, at: last)
                lockIndex = last
            } else {
                lockIndex = nil
            }
            self.frames = frames
        }

        func index(at point: CGPoint) -> Int {
            let slot = BandEditorDrop.insertionIndex(at: point, frames: frames)
            if let lockIndex, slot > lockIndex { return slot - 1 }
            return slot
        }

        func marker(at index: Int, pointerY: CGFloat? = nil) -> CGRect? {
            let slot = lockIndex.map { index > $0 ? index + 1 : index } ?? index
            return BandEditorDrop.marker(at: slot, frames: frames, pointerY: pointerY)
        }
    }

    /// All coordinates except the chip frames are in the scroll view's named space.
    static func placement(at point: CGPoint, in session: BandArrangementEditorSession) -> (
        target: BandEditorDropTarget, marker: CGRect?
    ) {
        let frames = session.layoutFrames
        for (band, left, right): (String, BandZoneID, BandZoneID) in [
            ("topBand", .topLeft, .topRight), ("bottomBand", .bottomLeft, .bottomRight),
        ] {
            guard session.zones.contains(left), let bounds = frames[band], bounds.contains(point) else { continue }
            // The zones can be side by side or stacked. Give their padding, fixed controls and gutter
            // to the nearest zone, including the space after the last chip on a wrapped line.
            let leftDistance = distance(to: frames[left.rawValue], from: point)
            let rightDistance = distance(to: frames[right.rawValue], from: point)
            let zone = leftDistance <= rightDistance ? left : right
            let count = session.arrangement[zone].count
            guard let rect = frames[zone.rawValue], let chips = session.chipFrames[zone], chips.count == count else {
                return (.zone(zone, index: count), nil)
            }
            let local = CGPoint(x: point.x - rect.minX, y: point.y - rect.minY)
            let slots = Slots(zone: zone, session: session)
            let index = slots.index(at: local)
            return (.zone(zone, index: index), slots.marker(at: index, pointerY: local.y))
        }
        return (frames["palette"]?.contains(point) == true ? .unused : .outside, nil)
    }

    private static func distance(to rect: CGRect?, from point: CGPoint) -> CGFloat {
        guard let rect else { return .infinity }
        return hypot(max(rect.minX - point.x, point.x - rect.maxX, 0), max(rect.minY - point.y, point.y - rect.maxY, 0))
    }

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
        let nearest = frames.min { abs($0.midY - point.y) < abs($1.midY - point.y) }
        guard let nearest else { return frames.count }
        let line = frames.indices.filter { abs(frames[$0].midY - nearest.midY) < 1 }
        if let before = line.first(where: { frames[$0].midX > point.x }) { return before }
        return (line.last ?? frames.count - 1) + 1
    }

    /// Where the insertion marker stands for a drop before `index`, between two chips or after the last one.
    static func marker(at index: Int, frames: [CGRect], pointerY: CGFloat? = nil) -> CGRect? {
        guard !frames.isEmpty, (0...frames.count).contains(index) else { return nil }
        let half = MiniatureMetrics.chipSpacing / 2
        let before = index < frames.count ? frames[index] : nil
        let after = index > 0 ? frames[index - 1] : nil
        // A wrap has two visual positions for the same index. Stay on the line the pointer is over.
        if let before {
            if let after, let pointerY, abs(after.midY - pointerY) < abs(before.midY - pointerY) {
                return CGRect(x: after.maxX + half - 1.25, y: after.minY, width: 2.5, height: after.height)
            }
            return CGRect(x: before.minX - half - 1.25, y: before.minY, width: 2.5, height: before.height)
        }
        return after.map { CGRect(x: $0.maxX + half - 1.25, y: $0.minY, width: 2.5, height: $0.height) }
    }

    /// Reads the one payload of a drop and hands it to the session; nothing else is accepted.
    static func perform(
        _ providers: [NSItemProvider], at point: CGPoint, in session: BandArrangementEditorSession,
        completion: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) -> Bool {
        let target = placement(at: point, in: session).target
        guard session.proposal(for: target) != .forbidden else {
            session.dropTarget = nil
            return false
        }
        guard providers.count == 1, let provider = providers.first else { return session.refuseDrop() }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier) { data, _ in
            let text = data.flatMap { String(data: $0, encoding: .utf8) }
            Task { @MainActor in
                guard let text, let payload = BandEditorPayload(string: text) else {
                    session.refuseDrop()
                    completion?(false)
                    return
                }
                let placed = session.drop(payload, on: target)
                completion?(placed)
            }
        }
        return true
    }
}

struct BandEditorDropDelegate: DropDelegate {
    let session: BandArrangementEditorSession

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.utf8PlainText]) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let (target, marker) = BandEditorDrop.placement(at: info.location, in: session)
        if session.dropMarker != marker { session.dropMarker = marker }
        if session.dropTarget != target { session.dropTarget = target }
        return DropProposal(operation: session.proposal(for: target))
    }

    func dropExited(info: DropInfo) {
        session.dropTarget = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        BandEditorDrop.perform(info.itemProviders(for: [.utf8PlainText]), at: info.location, in: session)
    }
}
