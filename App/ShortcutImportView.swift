import SurimonoCore
import SwiftUI

struct ShortcutImportView: View {
    let controller: ShortcutController
    @State var review: ShortcutImportReview
    @Environment(\.dismiss) private var dismiss
    @State private var acknowledged = false
    @State private var error: String?

    private var validator: ShortcutValidator { ShortcutValidator(environment: controller.environment) }
    @State private var validation = ReviewValidation()

    private struct ReviewValidation {
        var plan: ShortcutChangePlan?
        var blocked: [ShortcutOperationID] = []
        var issues: [ShortcutValidationIssue] = []
        var firstConflict: ShortcutConflict?
    }

    private struct ReviewInput: Equatable {
        let review: ShortcutImportReview
        let environment: ShortcutValidationContext
        let externalKeys: [ShortcutOperationID: ShortcutCombination]
        let ambiguities: Set<ShortcutOperationID>
    }

    private var input: ReviewInput {
        .init(
            review: review, environment: controller.environment,
            externalKeys: controller.externalMenuKeys, ambiguities: controller.menuAmbiguities)
    }

    private func updateValidation() {
        let validator = validator
        validation = .init(
            plan: try? review.plan(using: validator), blocked: controller.importBlockedOperations(review),
            issues: review.issues(using: validator), firstConflict: validator.conflicts(in: review.configuration).first)
        acknowledged = false
        error = nil
    }
    private var needsAcknowledgement: Bool {
        validation.plan?.requiresPrintingAcknowledgement == true
            || validation.plan?.requiresGlobalAcknowledgement == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Shortcuts — Merge").font(.headline)
            Text("Operations missing from the file keep their current keys. Nothing changes until you apply.")
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    refusals
                    conflicts
                    changes(title: "In Surimono", operations: review.changed.filter { !isGlobal($0) && !isOutput($0) })
                    changes(title: "Printing and Export", operations: review.changed.filter(isOutput))
                    changes(title: "Global", operations: review.changed.filter(isGlobal))
                    if !review.unknown.isEmpty || !review.skipped.isEmpty {
                        Text("Skipped Entries").font(.headline)
                        ForEach(review.unknown, id: \.self) { id in
                            Text(
                                String.localizedStringWithFormat(
                                    String(localized: "Unknown or fixed operation: %@"), id))
                        }
                        ForEach(review.skipped.sorted { $0.rawValue < $1.rawValue }, id: \.self) { id in
                            Text(ShortcutText.name(id))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if needsAcknowledgement {
                Toggle(
                    "I understand that global keys work in other apps and printing keys can send pages to a printer.",
                    isOn: $acknowledged
                )
                .fixedSize(horizontal: false, vertical: true)
            }
            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    do {
                        try controller.applyImport(review, acknowledged: acknowledged)
                        dismiss()
                    } catch {
                        self.error = ShortcutController.message(error)
                    }
                }
                .disabled(
                    validation.plan == nil || !validation.blocked.isEmpty || (needsAcknowledgement && !acknowledged)
                )
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 520, height: 440)
        .onChange(of: input, initial: true) { _, _ in updateValidation() }
        .onAppear { controller.refreshEnvironment() }
        .onChange(of: error) { _, value in ShortcutHints.announce(value) }
    }

    private func isGlobal(_ id: ShortcutOperationID) -> Bool { ShortcutOperation.operation(id).isGlobal }
    private func isOutput(_ id: ShortcutOperationID) -> Bool {
        [.printing, .export].contains(ShortcutOperation.operation(id).safety)
    }

    private func keyText(_ keys: [ShortcutCombination]) -> Text {
        Text(
            keys.isEmpty
                ? String(localized: "Unassigned") : keys.map { controller.layout.display($0) }.joined(separator: " / ")
        )
        .font(keys.isEmpty ? .caption : .caption.monospaced())
    }

    @ViewBuilder private func changes(title: LocalizedStringKey, operations: [ShortcutOperationID]) -> some View {
        if !operations.isEmpty {
            Text(title).font(.headline)
            ForEach(operations, id: \.self) { id in
                VStack(alignment: .leading, spacing: 4) {
                    Text(ShortcutText.name(id))
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        keyText(review.original.keys(for: id))
                        Text(verbatim: "→").font(.caption)
                        keyText(review.configuration.keys(for: id))
                    }
                    if let warning = ShortcutText.outputWarning(id) { Text(warning).font(.caption) }
                    skip(id)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func skip(_ id: ShortcutOperationID) -> some View {
        Button(String.localizedStringWithFormat(String(localized: "Keep current: %@"), ShortcutText.name(id))) {
            review.skip(id)
        }
    }

    private var refusals: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(validation.issues.enumerated()), id: \.offset) { _, issue in
                Text(ShortcutText.name(issue.operation) + ": " + ShortcutText.reason(issue.code))
                    .foregroundStyle(.red)
                skip(issue.operation)
            }
            ForEach(validation.blocked, id: \.self) { id in
                Text(
                    ShortcutText.name(id) + ": "
                        + String(localized: "This operation cannot be changed in this build or is managed by macOS.")
                )
                .foregroundStyle(.red)
                skip(id)
            }
        }
    }

    private var conflicts: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Present one direction of each conflict. Re-evaluation exposes any remaining overlap.
            if let conflict = validation.firstConflict {
                Text("Which operation keeps this key?").font(.headline)
                Text(controller.layout.display(conflict.proposed.combination)).monospaced()
                let owners = [conflict.operation] + conflict.owners.map(\.operation)
                ForEach(Array(Set(owners)).sorted { $0.rawValue < $1.rawValue }, id: \.self) { owner in
                    Button(String.localizedStringWithFormat(String(localized: "Use for %@"), ShortcutText.name(owner)))
                    {
                        let key =
                            owner == conflict.operation
                            ? conflict.proposed.combination
                            : conflict.owners.first { $0.operation == owner }?.binding.combination
                        if let key { review.keep(owner, key: key, validator: validator) }
                    }
                }
            }
        }
    }
}
