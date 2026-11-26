import SwiftUI

typealias ReadingSettingChange = (name: String, current: String, new: String)

struct ReadingDefaults<Value: Equatable> {
    struct Alternative {
        let values: Value
        let status: LocalizedStringResource
        let action: LocalizedStringResource
        let confirmation: LocalizedStringResource
        let question: LocalizedStringResource
    }

    let builtIn: Value
    let alternatives: [Alternative]
    let current: Value

    func canApply(_ values: Value) -> Bool { current != values }

    func reset(question: LocalizedStringResource) -> Alternative {
        .init(
            values: builtIn, status: "Surimono defaults", action: "Reset to Defaults…", confirmation: "Reset",
            question: question)
    }

    var status: LocalizedStringResource? {
        guard !alternatives.isEmpty else { return nil }
        if current == builtIn { return "Surimono defaults" }
        return alternatives.first { $0.values == current }?.status ?? "Custom"
    }
}

enum ReadingDefaultsConfirmation {
    static func message(heading: String, changes: [ReadingSettingChange], bundle: Bundle = .main) -> String {
        let limit = changes.count > 8 ? 6 : changes.count
        var entries = changes.prefix(limit).map { change in
            String(localized: "• \(change.name)\n\(change.current) → \(change.new)", bundle: bundle)
        }
        if limit < changes.count {
            entries.append(String(localized: "• and \(changes.count - limit) more", bundle: bundle))
        }
        return ([heading] + entries).joined(separator: "\n\n")
    }
}

/// The grouped form scrolls independently of the actions that replace its values.
struct ReadingDefaultsControls<Value: Equatable, Header: View, Rows: View>: View {
    let defaults: ReadingDefaults<Value>
    let resetQuestion: LocalizedStringResource
    let differences: (Value, Value) -> [ReadingSettingChange]
    let apply: (Value) -> Void
    @ViewBuilder let header: Header
    @ViewBuilder let rows: Rows
    @State private var pending: ReadingDefaults<Value>.Alternative?
    #if DEBUG
        var snapshotTarget: Value?
    #endif

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    rows
                } header: {
                    HStack {
                        header
                        Spacer()
                        if let status = defaults.status {
                            Text(status).foregroundStyle(.secondary)
                        }
                    }
                    .font(.body).textCase(nil)
                    .accessibilityElement(children: .contain)
                }
            }
            .formStyle(.grouped)
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack { actions }.fixedSize()
                VStack(alignment: .trailing) { actions }
            }
            .environment(\.settingsRowVerticalInset, 0)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 20).padding(.vertical, 10)
        }
        .alert(
            Text(pending?.question ?? resetQuestion),
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { target in
            if target.values == defaults.builtIn {
                Button(role: .destructive) {
                    apply(target.values)
                } label: {
                    Text(target.confirmation)
                }
                Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
            } else {
                Button {
                    apply(target.values)
                } label: {
                    Text(target.confirmation)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                Button("Cancel", role: .cancel) {}
            }
        } message: { target in
            let changes = differences(defaults.current, target.values)
            let heading =
                target.values == defaults.builtIn
                ? String(localized: "The following \(changes.count) settings will reset to Surimono defaults:")
                : String(localized: "The following \(changes.count) settings will change:")
            Text(verbatim: ReadingDefaultsConfirmation.message(heading: heading, changes: changes))
        }
        #if DEBUG
            .onAppear {
                if let snapshotTarget, defaults.canApply(snapshotTarget) {
                    pending =
                        snapshotTarget == defaults.builtIn
                        ? reset : defaults.alternatives.first { $0.values == snapshotTarget }
                }
            }
        #endif
    }

    private var reset: ReadingDefaults<Value>.Alternative {
        defaults.reset(question: resetQuestion)
    }

    @ViewBuilder private var actions: some View {
        if defaults.alternatives.count > 1 {
            Menu("Other Defaults") {
                ForEach(defaults.alternatives, id: \.action.key) { button($0) }
            }
        } else if let alternative = defaults.alternatives.first {
            button(alternative).settingSearchRow(alternative.action.key, fillsRow: false)
        }
        button(reset).settingSearchRow(reset.action.key, fillsRow: false)
    }

    private func button(_ target: ReadingDefaults<Value>.Alternative) -> some View {
        Button {
            pending = target
        } label: {
            Text(target.action)
        }
        .disabled(!defaults.canApply(target.values))
    }
}
