import SurimonoCore
import SwiftUI

/// Shared choices for a placed chip and the complete index. No presentation belongs to a measured chip.
struct BandPartChoices: View {
    @Bindable var model: DocumentViewModel
    let id: BandMenuContent.ID

    var body: some View {
        switch id {
        case .readingDirection:
            Picker("Reading Direction", selection: model.viewOption(\.direction)) {
                Text("Left to Right · Bound Left").tag(ViewOptions.Direction.leftToRight)
                Text("Right to Left · Bound Right").tag(ViewOptions.Direction.rightToLeft)
            }
            .pickerStyle(.inline).labelsHidden()
        case .scrollDirection:
            Picker("Scroll Direction", selection: model.viewOption(\.scrollAxis)) {
                Text("Vertical").tag(ViewOptions.ScrollAxis.vertical)
                Text("Horizontal").tag(ViewOptions.ScrollAxis.horizontal)
            }
            .pickerStyle(.inline).labelsHidden()
        case .paperOrientation: PaperOrientationControl(model: model).choices
        case .paperSeries: PaperSeriesPicker(model: model).pickerStyle(.inline).labelsHidden()
        case .margins: MarginChoices(model: model, unit: .current)
        default: EmptyView()
        }
    }
}

#if DEBUG
    /// A hosted test measures the visible text or compact symbol independently of the button's anchor.
    final class BandLabelMeasurements {
        var drawn: [BandLayout.Item: (form: BandLayout.Form, width: CGFloat)] = [:]
    }

    extension EnvironmentValues {
        @Entry var bandLabelMeasurements: BandLabelMeasurements? = nil
    }
#endif

/// The model supplies values and actions; the catalog supplies the chip's stable accessible name and symbol.
struct BandAdditionalPart: View {
    @Bindable var model: DocumentViewModel
    let item: BandLayout.Item
    let form: BandLayout.Form

    #if DEBUG
        @Environment(\.bandLabelMeasurements) private var measurements
    #endif

    var body: some View {
        if let id = BandMenuContent.ID(rawValue: item.rawValue) {
            let content = BandMenuContent(model: model)
            let entry = content.entry(id)
            control(entry)
                .fixedSize()
                .disabled(!entry.isEnabled)
                .help(help(entry, content: content))
                .accessibilityIdentifier("band.part." + item.rawValue)
                .accessibilityLabel(Text(verbatim: item == .beforePrinting ? entry.title : item.editorName))
                .accessibilityValue(Text(verbatim: accessibilityValue(entry)))
        }
    }

    @ViewBuilder private func control(_ entry: BandMenuContent.Entry) -> some View {
        if item.isBandChoice {
            Menu {
                BandPartChoices(model: model, id: entry.id)
            } label: {
                label(entry)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        } else if entry.isChecked != nil {
            Toggle(
                isOn: Binding(
                    get: { BandMenuContent(model: model).entry(entry.id).isChecked ?? false },
                    set: { BandMenuContent(model: model).setChecked($0, for: entry.id) })
            ) {
                label(entry)
            }
            .toggleStyle(BandPartToggleStyle())
        } else {
            Button {
                perform(entry.id)
            } label: {
                label(entry)
                    .foregroundStyle(isOpen ? AnyShapeStyle(PrintPalette.ai) : AnyShapeStyle(PrintPalette.ink))
            }
        }
    }

    @ViewBuilder private func label(_ entry: BandMenuContent.Entry) -> some View {
        let content = HStack(spacing: 3) {
            let icon = Image(systemName: symbol)
            if form == .full {
                icon
                inspected(Text(verbatim: labelText(entry)).lineLimit(1).monospacedDigit())
            } else {
                inspected(icon)
            }
            if form != .full, item == .beforePrinting {
                Text(verbatim: String(model.printIssueCount)).monospacedDigit()
            }
            if item.isBandChoice { BandMenuChevron() }
        }
        if #available(macOS 26, *) {
            content
        } else {
            // Keep the native button, but replace its label when the planner switches between icon and text.
            content.fixedSize(horizontal: true, vertical: false).id(form)
        }
    }

    @ViewBuilder private func inspected<Content: View>(_ content: Content) -> some View {
        #if DEBUG
            if let measurements {
                content.onGeometryChange(for: CGFloat.self) {
                    $0.size.width
                } action: {
                    measurements.drawn[item] = (form, $0)
                }
            } else {
                content
            }
        #else
            content
        #endif
    }

    func labelText(_ entry: BandMenuContent.Entry) -> String {
        if item == .scrollDirection {
            return model.viewOptions.scrollAxis == .vertical
                ? String(localized: "Vertical Scroll") : String(localized: "Horizontal Scroll")
        }
        return entry.value ?? entry.title
    }

    private var symbol: String {
        switch item {
        case .readingDirection: model.viewOptions.direction == .rightToLeft ? "arrow.left" : "arrow.right"
        case .scrollDirection:
            model.viewOptions.scrollAxis == .horizontal ? "arrow.left.and.right" : "arrow.up.and.down"
        default: item.additionalSymbol ?? "questionmark"
        }
    }

    private var isOpen: Bool {
        switch item {
        case .viewOptions: model.isViewOptionsPresented
        case .printSettings: model.isPrintFinishPresented
        default: false
        }
    }

    private func accessibilityValue(_ entry: BandMenuContent.Entry) -> String {
        if let value = entry.value { return value }
        if let checked = entry.isChecked { return checked ? String(localized: "On") : String(localized: "Off") }
        if item == .viewOptions || item == .printSettings {
            return isOpen ? String(localized: "Open") : String(localized: "Closed")
        }
        return ""
    }

    private func help(_ entry: BandMenuContent.Entry, content: BandMenuContent) -> String {
        let title =
            entry.isChecked != nil || item == .viewOptions || item == .printSettings
            ? choice(item.editorName, accessibilityValue(entry)) : entry.title
        return content.help(
            for: .init(
                id: entry.id, title: title, value: entry.value, isChecked: entry.isChecked, isEnabled: entry.isEnabled))
    }

    private func perform(_ id: BandMenuContent.ID) {
        if id == .viewOptions {
            model.isViewOptionsPresented.toggle()
        } else {
            BandMenuContent(model: model).perform(id)
        }
    }
}

extension BandLayout.Item {
    var isBandChoice: Bool {
        switch self {
        case .readingDirection, .scrollDirection, .paperOrientation, .paperSeries, .margins: true
        default: false
        }
    }

    var additionalSymbol: String? {
        switch self {
        case .readingDirection: "arrow.right"
        case .scrollDirection: "arrow.up.and.down"
        case .paperOrientation: "rectangle.portrait.rotate"
        case .paperSeries: "doc.on.doc"
        case .cover: "book.closed"
        case .selectText: "character.cursor.ibeam"
        case .alwaysShowToolbar: "rectangle.topthird.inset.filled"
        case .margins: "rectangle.dashed"
        case .printSettings: "doc.badge.gearshape"
        case .ignoreSlides: "play.rectangle"
        case .beforePrinting: "exclamationmark.triangle"
        case .viewOptions: "slider.horizontal.3"
        case .saveAsFile: "square.and.arrow.down"
        case .keysAndGestures: "keyboard"
        default: nil
        }
    }
}

/// Match the pin: ordinary ink off, indigo on, with AppKit dimming only disabled controls.
private struct BandPartToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
                .selectionRule(configuration.isOn)
                .foregroundStyle(configuration.isOn ? AnyShapeStyle(PrintPalette.ai) : AnyShapeStyle(PrintPalette.ink))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}
