import SurimonoCore
import SwiftUI

/// What a drag would do, in words, for the place under the pointer and the places beside it. It is drawn from the same
/// plan that carries out the drop.
enum DropCopy {
    struct Text: Equatable {
        let title: String
        let detail: String
    }

    /// - Parameter ownName: The window's own document; nil when it holds images, which turn into a binder as a set.
    static func join(_ joining: DropPlan.Joining, plan: DropPlan, ownName: String?, position: Int?) -> Text {
        let count = plan.adding.count
        let notes = notes(for: plan)
        switch joining {
        case .newBinder:
            guard let ownName else {
                return Text(
                    title: String(localized: "Make a Binder and Add"),
                    detail: joined(String(localized: "Turns the images into a binder and adds to the end"), notes))
            }
            return Text(
                title: String(localized: "Make a Binder"),
                detail: joined(String(format: String(localized: "%2$lld more after %1$@"), ownName, count), notes))
        case .binder:
            return Text(
                title: String(localized: "Add to Binder"),
                detail: joined(
                    position.map { String(format: String(localized: "Puts %2$lld at position %1$lld"), $0 + 1, count) }
                        ?? String(format: String(localized: "Adds %lld at the end"), count), notes))
        case .images:
            return Text(
                title: String(localized: "Add Images"),
                detail: joined(
                    position.map {
                        String(format: String(localized: "Puts %2$lld images at position %1$lld"), $0 + 1, count)
                    } ?? String(format: String(localized: "Adds %lld images at the end"), count), notes))
        }
    }

    static func open(plan: DropPlan, isOpenElsewhere: Bool, isComparing: Bool) -> Text {
        let title = String(localized: "Open in a New Window")
        if isComparing { return Text(title: title, detail: String(localized: "Not added to the comparison")) }
        switch plan.opening {
        case .single(let url):
            if isOpenElsewhere {
                return Text(
                    title: String(localized: "Show Its Window"),
                    detail: String(localized: "It is open in another window"))
            }
            if plan.adding.isEmpty, OpenRequest.isArchive(url) {
                return Text(title: title, detail: String(localized: "ZIP archives cannot join a binder"))
            }
            return Text(
                title: title,
                detail: String(format: String(localized: "%@ opens in another window"), url.lastPathComponent))
        case .imageBundle(_, let excluded):
            return Text(
                title: title,
                detail: joined(String(localized: "Opens as an image bundle in another window"), left(excluded.count)))
        case .binder(_, let excluded):
            return Text(
                title: title,
                detail: joined(String(localized: "Opens as a binder in another window"), left(excluded.count)))
        case .unsupported, .empty:
            return Text(title: title, detail: "")
        }
    }

    static func refusal(_ refusal: DropPlan.Refusal) -> String {
        switch refusal {
        case .isThisDocument: String(localized: "This document is open here")
        case .alreadyIn: String(localized: "Already in this window")
        case .unsupported: String(localized: "This cannot be opened")
        }
    }

    private static func notes(for plan: DropPlan) -> [String] {
        var notes = left(plan.leftOut.count)
        if !plan.alreadyIn.isEmpty {
            notes.append(String(format: String(localized: "%lld are in it already"), plan.alreadyIn.count))
        }
        return notes
    }

    private static func left(_ count: Int) -> [String] {
        count > 0 ? [String(format: String(localized: "%lld cannot be added"), count)] : []
    }

    private static func joined(_ line: String, _ notes: [String]) -> String {
        ([line] + notes).joined(separator: String(localized: ". "))
    }
}

/// The places a drag over the window can land. Only the place under the pointer lights up.
struct DropOverlay: View {
    let model: DocumentViewModel

    private var session: DropSession { model.drop }

    var body: some View {
        if let plan = session.plan {
            ZStack {
                switch plan.choice {
                case .joinOrOpen(let joining):
                    PrintPalette.stage.opacity(0.6)
                    GeometryReader { geometry in
                        HStack(spacing: 12) {
                            place(copy(join: joining, plan: plan), isHovered: session.zone == .join)
                                .frame(width: (geometry.size.width - 12) * DropSession.joinShare)
                            place(copy(open: plan), isHovered: session.zone == .open)
                        }
                    }
                    .padding(12)
                case .join(let joining):
                    PrintPalette.stage.opacity(0.6)
                    place(copy(join: joining, plan: plan), isHovered: true).padding(12)
                case .open:
                    PrintPalette.stage.opacity(0.6)
                    place(copy(open: plan), isHovered: true).padding(12)
                case .refuse(let refusal):
                    Text(verbatim: DropCopy.refusal(refusal))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(PrintPalette.toastInk)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(PrintPalette.toast))
                }
            }
            .overlay(alignment: .topLeading) { insertionLine }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    private func copy(join joining: DropPlan.Joining, plan: DropPlan) -> DropCopy.Text {
        DropCopy.join(joining, plan: plan, ownName: model.fileURL?.lastPathComponent, position: session.insertion)
    }

    private func copy(open plan: DropPlan) -> DropCopy.Text {
        DropCopy.open(plan: plan, isOpenElsewhere: model.isOpenElsewhere(plan), isComparing: model.mode == .compare)
    }

    private func place(_ copy: DropCopy.Text, isHovered: Bool) -> some View {
        VStack(spacing: 4) {
            Text(verbatim: copy.title).font(.system(size: 15, weight: .bold))
            Text(verbatim: copy.detail).font(.system(size: 12)).foregroundStyle(PrintPalette.ink2)
        }
        .foregroundStyle(PrintPalette.ink)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        // The words stay readable over whatever is on the page behind them.
        .background(RoundedRectangle(cornerRadius: 8).fill(PrintPalette.raised))
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isHovered ? AnyShapeStyle(PrintPalette.aiTint) : AnyShapeStyle(.clear))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isHovered ? PrintPalette.ai : PrintPalette.line3,
                    style: StrokeStyle(lineWidth: isHovered ? 2 : 1.5, dash: isHovered ? [] : [6, 4]))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var insertionLine: some View {
        if let y = session.insertionY, let list = session.listFrame {
            RoundedRectangle(cornerRadius: 1)
                .fill(PrintPalette.ai)
                .frame(width: list.width - 8, height: 2)
                .offset(x: list.minX + 4, y: y - 1)
        }
    }
}
