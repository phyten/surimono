import PDFKit
import SurimonoCore
import SwiftUI

extension DocumentViewModel {
    func checkProseLayout(_ generation: Int, document: PDFDocument) throws {
        try Task.checkCancellation()
        guard proseGeneration == generation, paperDocument === document else { throw CancellationError() }
    }

    func dismissProseMark() {
        if !proseMark.spans.isEmpty { proseMark.dismiss() }
    }

    func selectProseFinding(_ row: ProsePanelReport.Row, generation: Int) {
        guard offersProse, isOutlineShown, contentsTab == .prose, generation == proseGeneration,
            let document = paperDocument, let first = row.spans.first, paper.canMarkProse(row.spans, in: document)
        else { return }
        if find.isPresented { find.close() }
        let visible = visibleReadingPages
        if !row.spans.contains(where: { visible.contains($0.page) || paper.isProsePageVisible($0.page) }) {
            jumpToReadingPage(first.page)
        }
        paper.revealProse(row.spans)
        proseMark.select(row.spans, findingID: row.id, generation: generation, readingPage: currentPageIndex)
    }
}

extension ProsePanelReport.Group {
    fileprivate var label: String {
        switch self {
        case .duplicate: String(localized: "Repeated Word")
        case .repetition: String(localized: "Close Repetition")
        case .longSentence: String(localized: "Long Sentence")
        }
    }
}

struct ProsePanel: View {
    let model: DocumentViewModel

    private enum Result: Sendable {
        case report(ProsePanelReport)
        case unavailable(ProseAnalysis.Reason)
    }

    @State private var result: Result?
    @State private var completed: Int?
    @State private var expanded: Set<ProsePanelReport.Group> = []

    var body: some View {
        let generation = model.proseGeneration
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let generation, completed == generation, let result {
                    switch result {
                    case .report(let report):
                        figures(report.facts)
                        Divider()
                        if report.groups.isEmpty {
                            Text("No repetitions or long sentences found.")
                        } else {
                            ForEach(ProsePanelReport.Group.allCases, id: \.self) { group in
                                if let rows = report.groups[group] {
                                    findings(rows, group: group, generation: generation)
                                }
                            }
                        }
                    case .unavailable(.noProse): Text("There is no prose to check.")
                    case .unavailable: Text("Only Japanese and English can be checked.")
                    }
                } else if model.data.isEmpty {
                    Text("There is no prose to check.")
                } else {
                    Text("Checking…")
                }
            }
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: generation) {
            guard !Task.isCancelled, model.proseGeneration == generation else { return }
            completed = nil
            result = nil
            model.dismissProseMark()
            #if DEBUG
                model.snapshotProseReady = false
            #endif
            guard let generation, let source = model.displayedChangeSource, let document = model.paperDocument else {
                return
            }
            do {
                let initial = try await Self.analyse(source.data, format: source.format)
                try model.checkProseLayout(generation, document: document)
                result = initial
                completed = generation
                if case .report(let pending) = initial {
                    expanded = pending.initiallyExpanded ? Set(pending.groups.keys) : []
                    if !pending.groups.isEmpty {
                        // PDFKit owns the displayed pages on the main actor. Yield between page reads.
                        var pages: [String] = []
                        for index in 0..<document.pageCount {
                            await Task.yield()
                            try model.checkProseLayout(generation, document: document)
                            pages.append(document.page(at: index)?.string ?? "")
                        }
                        let report = try await Self.pair(pending, pages: pages)
                        try model.checkProseLayout(generation, document: document)
                        result = .report(report)
                        #if DEBUG
                            if let n = DebugSnapshot.argument("SurimonoProseFinding").flatMap(Int.init), n > 0 {
                                let rows = ProsePanelReport.Group.allCases.flatMap { report.groups[$0] ?? [] }
                                if rows.indices.contains(n - 1) {
                                    model.selectProseFinding(rows[n - 1], generation: generation)
                                }
                            }
                        #endif
                    }
                }
                #if DEBUG
                    model.snapshotProseReady = true
                #endif
            } catch is CancellationError {
                // The next visible generation owns the result.
            } catch {
                assertionFailure("Unexpected prose analysis failure")
            }
        }
        .onDisappear {
            model.dismissProseMark()
            #if DEBUG
                model.snapshotProseReady = false
            #endif
        }
    }

    @concurrent private static func analyse(_ data: Data, format: DocumentFormat) async throws -> Result {
        try Task.checkCancellation()
        switch try await ProseCheck.analysis(of: TextDecoding.decode(data).text, format: format) {
        case .notAnalysed(let reason): return .unavailable(reason)
        case .analysed(let report): return .report(try ProsePanelReport(report: report))
        }
    }

    @concurrent private static func pair(_ report: ProsePanelReport, pages: [String]) async throws -> ProsePanelReport {
        try report.located(on: pages)
    }

    private func findings(_ rows: [ProsePanelReport.Row], group: ProsePanelReport.Group, generation: Int) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { expanded.contains(group) },
                set: { if $0 { expanded.insert(group) } else { expanded.remove(group) } }
            )
        ) {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(rows) { row in
                    finding(row, group: group, generation: generation)
                }
            }
            .padding(.vertical, 4)
        } label: {
            HStack {
                Text(verbatim: group.label)
                Spacer(minLength: 4)
                Text(verbatim: rows.count.formatted()).monospacedDigit().foregroundStyle(PrintPalette.ink2)
            }
            .contentShape(Rectangle())
        }
        .disclosureGroupStyle(PanelDisclosureStyle())
    }

    private func finding(_ row: ProsePanelReport.Row, group: ProsePanelReport.Group, generation: Int) -> some View {
        let detail = detail(for: row)
        let selected = model.proseMark.findingID == row.id
        var place = AttributedString(row.excerpt.place)
        place.font = .system(size: 12, weight: .bold)
        let excerpt = AttributedString(row.excerpt.before) + place + AttributedString(row.excerpt.after)
        return Button {
            model.selectProseFinding(row, generation: generation)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(excerpt)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .lineLimit(1).truncationMode(.tail)
                Text(verbatim: detail).font(.caption).foregroundStyle(PrintPalette.ink2)
            }
            .foregroundStyle(PrintPalette.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background { ContentsRowBackground(isCurrent: selected) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(row.location != .found)
        .accessibilityValue(accessibilityValue(for: row.location))
        .accessibilityLabel(Text(verbatim: [group.label, row.excerpt.text, detail].joined(separator: " ")))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func accessibilityValue(for location: ProsePanelReport.Location) -> Text {
        switch location {
        case .checking: Text("Checking…")
        case .missing: Text("Could not locate this passage on the page.")
        case .found: Text(verbatim: "")
        }
    }

    private func detail(for row: ProsePanelReport.Row) -> String {
        var parts = [row.spans.first.map { String(format: String(localized: "Page %lld"), $0.page + 1) } ?? "—"]
        if case .longSentence(let count, let unit) = row.kind { parts.append(length(Double(count), unit)) }
        return parts.joined(separator: " · ")
    }

    private func length(_ count: Double, _ unit: ProseLengthUnit) -> String {
        if unit == .words {
            return Self.words(count, bundle: .main, locale: Locale(identifier: model.language))
        }
        return String(
            format: String(localized: "%@ characters"), count.formatted(.number.precision(.fractionLength(0...1))))
    }

    static func words(_ count: Double, bundle: Bundle, locale: Locale) -> String {
        let format = String(localized: "%.15g words", bundle: bundle)
        return String(format: format, locale: locale, count)
    }

    private func figures(_ facts: ProseFacts) -> some View {
        VStack(spacing: 5) {
            figure("Sentences", facts.sentenceCount.formatted())
            let medians = [
                facts.japanese.map { length($0.medianLength, .characters) },
                facts.english.map { length($0.medianLength, .words) },
            ].compactMap { $0 }
            figure("Median Length", medians.joined(separator: " / "))
            figure("Long Sentences", ((facts.japanese?.longCount ?? 0) + (facts.english?.longCount ?? 0)).formatted())
            if let scripts = facts.scripts {
                let percent = FloatingPointFormatStyle<Double>.Percent.percent.precision(.fractionLength(0))
                figure(
                    "Script Mix",
                    String(
                        format: String(localized: "Kanji %1$@ · Kana %2$@ · Latin %3$@"),
                        scripts.share(scripts.kanji).formatted(percent),
                        scripts.share(scripts.hiragana + scripts.katakana).formatted(percent),
                        scripts.share(scripts.latin).formatted(percent)))
            }
        }
    }

    private func figure(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label)
            Spacer(minLength: 0)
            Text(verbatim: value).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(verbatim: value))
    }
}
