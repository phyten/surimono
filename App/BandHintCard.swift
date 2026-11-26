import SwiftUI

struct BandHintPlacement: Layout {
    let rect: CGRect
    let above: Bool
    let canFlip: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let card = subviews.first else { return }
        let singleLine = ceil(card.sizeThatFits(.unspecified).width)
        let width = min(max(160, singleLine), 300, max(1, bounds.width - 16))
        let size = card.sizeThatFits(ProposedViewSize(width: width, height: nil))
        let x = max(8, min(rect.midX - width / 2, bounds.width - width - 8))
        let y =
            above || (canFlip && rect.maxY + 6 + size.height > bounds.height - 8)
            ? rect.minY - size.height - 6 : rect.maxY + 6
        card.place(
            at: CGPoint(x: bounds.minX + x, y: bounds.minY + max(8, min(y, bounds.height - size.height - 8))),
            anchor: .topLeading, proposal: ProposedViewSize(width: width, height: size.height))
    }
}

struct BandHintCard: View {
    let content: BandHintContent
    var showName = true
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let shape = RoundedRectangle(cornerRadius: BandDesign.hintRadius(AppPreferences.shared.corners))
        VStack(alignment: .leading, spacing: 3) {
            if showName || content.state != nil || !content.shortcut.isEmpty {
                HStack(spacing: 6) {
                    if showName {
                        Text(verbatim: content.name).font(.system(size: 12, weight: .medium)).fixedSize(
                            horizontal: false, vertical: true)
                    }
                    if let state = content.state {
                        Text(verbatim: state).font(.system(size: 12))
                            .lineLimit(1)
                            .foregroundStyle(content.active ? PrintPalette.ai : PrintPalette.ink.opacity(0.80))
                    }
                    if !content.shortcut.isEmpty {
                        Spacer(minLength: 0)
                        Text(verbatim: content.shortcut).font(.system(size: 11, weight: .medium)).fixedSize()
                            .foregroundStyle(PrintPalette.ink.opacity(0.80))
                    }
                }
            }
            Text(verbatim: content.reason ?? content.detail)
                .font(.system(size: 12))
                .foregroundStyle(PrintPalette.ink.opacity(0.80))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(PrintPalette.ink)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            shape.fill(dark ? Color(.sRGB, red: 39 / 255, green: 49 / 255, blue: 61 / 255) : PrintPalette.raised)
        )
        .shadow(color: .black.opacity(dark ? 0.24 : 0.12), radius: 6, y: 2)
    }
}
