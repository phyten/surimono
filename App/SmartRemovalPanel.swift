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
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                Spacer()
                Button {
                    model.endSmartRemovalReview()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Close")
            }
            Text(String(format: String(localized: "%lld parts removed"), removedCount))
                .font(.subheadline.weight(.semibold)).padding(.top, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.smartRemovalCandidates) { candidate in
                        CandidateRow(
                            candidate: candidate, isKept: model.smartRemovalKeptIDs.contains(candidate.id),
                            toggle: { model.toggleKeep(candidate.id) })
                        Divider()
                    }
                }
            }
            .padding(.vertical, 8)
            Text(
                "The dashed frames on the paper show what was removed. Detection runs on this Mac only; nothing is sent anywhere. The result is remembered for this content."
            )
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Turn Off") { model.setSmartRemoval(enabled: false) }
                Spacer()
                Button("Done") { model.endSmartRemovalReview() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
            .padding(.top, 10)
        }
        .padding(12)
        .frame(width: 280)
        .paperOverlayBackground(cornerRadius: 12, tintOpacity: 0.985)
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
                    Text(verbatim: candidate.excerpt).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(verbatim: candidate.reason).font(.caption2).monospaced().foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            Button(isKept ? "Remove" : "Keep", action: toggle).controlSize(.small)
        }
        .padding(.vertical, 8)
        .opacity(isKept ? 0.6 : 1)
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
