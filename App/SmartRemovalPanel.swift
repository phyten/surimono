import SurimonoCore
import SwiftUI

/// Lists what Smart Removal took out of an HTML document, so each part can be kept again. While the panel is open the
/// paper outlines the detected parts instead of removing them.
struct SmartRemovalPanel: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Smart Removal").font(.headline)
                Text(verbatim: "β")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(AppCornerShape.capsule.fill(PrintPalette.aiTint2))
                Spacer()
                PanelIconButton("xmark", label: "Close") { model.endSmartRemovalReview() }
                    .foregroundStyle(PrintPalette.ink2)
            }
            Text(String(format: String(localized: "%lld parts removed"), removedCount))
                .font(.subheadline.weight(.semibold)).padding(.top, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.smartRemovalCandidates) { candidate in
                        CandidateRow(
                            candidate: candidate, isKept: model.smartRemovalKeptIDs.contains(candidate.id),
                            toggle: { model.toggleKeep(candidate.id) })
                        Rectangle().fill(PrintPalette.line).frame(height: DisplayAccessibility.hairline)
                    }
                }
            }
            .padding(.vertical, 8)
            Text("The dashed frames show what was removed. Detection runs only on this Mac.")
                .font(.caption).foregroundStyle(PrintPalette.ink2).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Turn Off") { model.setSmartRemoval(enabled: false) }
                Spacer()
                Button("Done") { model.endSmartRemovalReview() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
            .padding(.top, 10)
        }
        .padding(12)
        .frame(width: 340)
        .paperOverlayBackground(.panel, tintOpacity: 0.985)
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }

    private var removedCount: Int {
        model.smartRemovalCandidates.filter { !model.smartRemovalKeptIDs.contains($0.id) }.count
    }
}

private struct CandidateRow: View {
    let candidate: SmartRemovalCandidate
    let isKept: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.category.title).font(.callout.weight(.semibold))
                if !candidate.excerpt.isEmpty {
                    Text(verbatim: candidate.excerpt).font(.caption).foregroundStyle(PrintPalette.ink2).lineLimit(2)
                }
            }
            // What matched is for the curious; on the row it read as markup.
            .help(Text(verbatim: candidate.reason))
            Spacer(minLength: 6)
            Button(isKept ? "Remove" : "Keep", action: toggle).controlSize(.small)
                .fixedSize()
        }
        .padding(.vertical, 8)
    }
}

extension SmartRemovalCandidate.Category {
    var title: LocalizedStringKey {
        switch self {
        case .cookieBanner: "Cookie Banner"
        case .stickyHeader: "Sticky Header"
        case .advertisement: "Advertisement"
        case .socialButtons: "Social Buttons"
        case .newsletter: "Newsletter Sign-up"
        case .relatedLinks: "Recommended Articles"
        case .popup: "Pop-up"
        }
    }
}
