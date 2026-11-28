import Foundation
import PDFKit
import SurimonoCore
import SurimonoFormats
import WebKit

/// Source headings and float captions can have identical text. Read their actual destinations
/// from a disposable print rather than guessing which occurrence of a title starts a section.
enum LaTeXPageReferences {
    struct Target: Decodable {
        var action: String
        var value: String
        var referenced: Bool
        var classPlain: Bool? = nil
    }

    struct Installation: Decodable {
        var targets: [Target]
        var missing: Int
    }

    struct Page: Equatable, Sendable {
        var label: String
        var lines: PageFurniture.Lines
        var hasFooter: Bool { lines.bottom.contains { !$0.isEmpty } }

        init(_ state: LaTeXPageNumbers) {
            label = state.label
            if let journal = state.journalPage {
                lines = .init(top: journal.top, bottom: journal.bottom)
                lines.journalPage = journal
                lines.headerFont = journal.headerFont
                lines.numberFont = journal.numberFont
                lines.headerNumberRanges = journal.top.enumerated().map { i, text in
                    i == journal.headerNumberSlot ? [NSRange(location: 0, length: text.utf16.count)] : []
                }
                lines.footerNumberRanges = journal.bottom.enumerated().map { i, text in
                    i == journal.footerNumberSlot ? [NSRange(location: 0, length: text.utf16.count)] : []
                }
                lines.headRule = journal.headRule
                return
            }
            lines = .init(top: state.header, bottom: state.footer)
            if let title = state.runningTitle, !title.isEmpty, lines.top[1] == title {
                lines.oversizedTitleFallback = state.runningTitleFallback
            }
            lines.usesFancyFields = state.usesFancyFields
            lines.spansOuterMargin = state.spansOuterMargin
            lines.headerFont = state.headerFont
            lines.numberFont = state.numberFont
            lines.headerNumberRanges = state.numberRanges(header: true)
            lines.footerNumberRanges = state.numberRanges(header: false)
            lines.headRule = state.ruleWidth("headrulewidth")
            lines.footRule = state.ruleWidth("footrulewidth")
        }
    }

    struct ExamScore: Codable, Equatable {
        var label: String
        var points: Double
    }

    struct Map {
        var examScores: [ExamScore] = []
        var pages: [Page]
        var references: [String: String]
    }

    struct MeasurementFailed: Error {}

    // This also runs in a fresh session when the disposable print fails. Building the labels
    // uses neither the destinations nor the measuring API that failed.
    static let prepareFields = """
        const links = [...document.querySelectorAll('nav.toc li > a[href^="#"],a.latex-pageref[href^="#"]')];
        const pageFields = links.map(link => {
          let field = link;
          if (link.closest('nav.toc')) {
            link.classList.add('latex-page-entry');
            const caption = document.createElement('span');
            while (link.firstChild) caption.append(link.firstChild);
            const leader = document.createElement('span');
            leader.className = 'latex-page-leader';
            const major = link.parentElement.matches('.latex-toc-part,.latex-toc-chapter') ||
              document.body.dataset.latexChapters === 'false' && link.parentElement.matches('.latex-toc-section');
            if (!major && !link.closest('[data-latex-undotted]')) {
              const dots = document.createElement('span');
              dots.className = 'latex-leader-dots';
              leader.setAttribute('aria-hidden', 'true');
              leader.append(dots);
            }
            field = document.createElement('span');
            field.className = 'latex-page-label';
            link.append(caption, leader, field);
          }
          field.textContent = '?';
          return {field, id: link.getAttribute('href').slice(1)};
        });
        """

    static func install(token: String, runningMarks: Bool = false, classPlain: Bool = false, nativePrint: Bool = false)
        -> String
    {
        """
        \(prepareFields)
        const refs = new Map();
        let missing = 0;
        for (const {field, id} of pageFields) {
          const target = document.getElementById(id);
          if (!target) { missing++; continue; }
          if (!refs.has(target)) refs.set(target, []);
          refs.get(target).push(field);
        }
        const citations = new Map(), backRefs = new Map();
        if (document.body.hasAttribute('data-latex-page-backrefs')) {
          let serial = 0;
          for (const a of document.querySelectorAll('.latex-cite a[href^="#"]')) {
            const entry = document.getElementById(a.getAttribute('href').slice(1));
            if (!entry || entry.contains(a)) continue;
            if (!a.id) {
              let id;
              do { id = 'surimono-citation-' + (++serial); } while (document.getElementById(id));
              a.id = id;
            }
            if (!backRefs.has(entry)) {
              const field = document.createElement('span');
              (entry.querySelector(':scope > p:last-child') || entry).append(field);
              backRefs.set(entry, {field, occurrences:[]});
            }
            const occurrence = {id:a.id};
            backRefs.get(entry).occurrences.push(occurrence);
            citations.set(a, occurrence);
            if (!refs.has(a)) refs.set(a, []);
          }
        }
        const targets = [];
        const fields = [];
        // A page declaration between forced breaks has no height. Attach its probe to the next
        // printable block so neither the flow splitter nor native printing invents a blank page.
        function attach(el, probe) {
          const paragraph = el.closest('p');
          const bare = paragraph && !paragraph.textContent.trim() &&
            !paragraph.querySelector(':not(span:empty,span[data-latex-page-action],[data-latex-probe])');
          if (!el.matches('span:empty') || paragraph && !bare || el.closest('h1,h2,h3,h4,h5,h6,li,td,th,caption,figcaption')) {
            el.prepend(probe);
            return;
          }
          const localPage = el.dataset.latexPageAction === 'thispagestyle';
          if (bare) el = paragraph;
          const transparent = 'template,style,.latex-pagebreak,span:empty';
          let previous = el.previousElementSibling;
          while (previous && previous.matches('style,span:empty')) previous = previous.previousElementSibling;
          let next = el.nextElementSibling;
          // An inline maketitle still belongs to the current page. A separate title
          // has already shipped it, so a following declaration travels with the next text.
          const inlineTitle = previous?.matches('body[data-latex-title-layout="inline"] .latex-title-block');
          const shippedTitle = previous?.matches('body[data-latex-title-layout="separate"] .latex-title-block,.latex-titlepage');
          if (previous && !shippedTitle && !previous.matches(transparent) &&
              (localPage && inlineTitle || !next || next.matches('template[data-latex-break],.latex-pagebreak'))) {
            previous.append(probe);
            return;
          }
          while (next && next.matches(transparent)) next = next.nextElementSibling;
          if (next) next.prepend(probe);
          else el.prepend(probe);
        }
        const declarations = [...document.querySelectorAll('[data-latex-page-action]')];
        const plain = \(classPlain) || declarations.some(el => ['pagestyle','thispagestyle','fancyStyle'].includes(el.dataset.latexPageAction));
        const marks = \(runningMarks) || declarations.some(el =>
          el.dataset.value === 'fancy' || /leftmark|rightmark/.test(el.dataset.value || ''));
        const examPages = !!document.querySelector('table[data-exam-pages]');
        const chapters = document.body.dataset.latexChapters === 'true';
        for (const el of document.querySelectorAll('[data-latex-page-action],[data-exam-credit],[id],[data-latex-chapter-opening],.latex-title-block,.latex-titlepage')) {
          let action = el.dataset.latexPageAction || '';
          if (!el.matches('body[data-latex-class="amsbook"] .latex-title-block') && el.matches('.latex-titlepage,body[data-latex-title-layout="separate"] .latex-title-block,body[data-latex-chapters="true"]:not([data-latex-title-layout]) .latex-title-block')) action = 'title';
          let value = el.dataset.value || '';
          if (examPages && el.hasAttribute('data-exam-credit')) {
            action = 'examCredit'; value = el.dataset.examCredit;
          }
          if (marks && el.hasAttribute('data-latex-book-mark')) {
            action = el.matches('h3') ? 'rightmark' : 'majorMark';
            value = el.dataset.latexBookMark;
          }
          if (marks && !action && !el.closest('body:is([data-latex-class="amsart"],[data-latex-class="amsproc"])') && el.matches('h2[id^="sec-"],h3[id^="sec-"]') && el.querySelector(':scope > .secnum')) {
            const num = el.querySelector(':scope > .secnum');
            const number = num.textContent;
            const title = Array.from(el.childNodes).filter(n => n !== num && !n.hasAttribute?.('data-latex-probe')).map(n => n.textContent).join('');
            action = el.tagName === 'H2' ? 'majorMark' : 'rightmark';
            const text = number + ' ' + title;
            value = action === 'majorMark' || chapters ? text.toUpperCase() : text;
          }
          // Standard inline titles and chapter openings select plain locally. A measured chapter
          // can change the running marks on this same page as well.
          const classPlain = plain && action !== 'title' && !el.dataset.latexPageAction &&
            (el.matches('body[data-latex-title-layout="inline"]:not([data-latex-style]) .latex-title-block') || chapters && el.matches('h2[id^="sec-"],[data-latex-chapter-opening],body[data-latex-book-opening] .latex-part'));
          if (!refs.has(el) && !action && !classPlain) continue;
          if (el.matches('span[data-latex-page-action]')) el.style.position = 'absolute';
          const index = targets.length;
          if (citations.has(el)) citations.get(el).index = index;
          fields.push(refs.get(el) || []);
          targets.push({action, value, referenced: refs.has(el), classPlain});
          if (!\(nativePrint) && !el.matches('span:empty')) {
            // Flow already measures this element, including floated and wrapped captions.
            // Reading its top avoids WebKit's static position for an absolutely positioned link.
            el.dataset.latexPageTarget = index;
            continue;
          }
          const anchor = document.createElement('a');
          anchor.href = 'surimono-tex-page:\(token)/' + index;
          anchor.style.cssText = 'all:initial!important;position:absolute!important;display:block!important;width:1px!important;height:1px!important;margin:0!important;padding:0!important;border:0!important;font-size:0!important;line-height:0!important;background:transparent!important';
          anchor.dataset.latexProbe = index;
          if (\(nativePrint)) {
            // Some print backends omit empty link annotations. Ink only in the disposable pass
            // supplies an independent lookup, including duplicate and translated heading text.
            anchor.style.setProperty('font', '1px/1px monospace', 'important');
            anchor.style.setProperty('white-space', 'nowrap', 'important');
            anchor.textContent = 'SRM\(token.replacingOccurrences(of: "-", with: ""))X' + index + 'Z';
          }
          attach(el, anchor);
        }
        globalThis.surimonoTeXPages = {fields, backRefs};
        return JSON.stringify({targets, missing});
        """
    }

    @MainActor
    static func locations(in pdf: PDFDocument, token: String, count: Int) -> [Int: Int] {
        var pages: [Int: Int] = [:]
        let prefix = "surimono-tex-page:\(token)/"
        for index in 0..<pdf.pageCount {
            for link in pdf.page(at: index)?.annotations ?? [] {
                guard let url = link.url ?? (link.action as? PDFActionURL)?.url,
                    url.absoluteString.hasPrefix(prefix), let id = Int(url.absoluteString.dropFirst(prefix.count)),
                    (0..<count).contains(id), pages[id] == nil
                else { continue }
                pages[id] = index
            }
        }
        if pages.count < count {
            let prefix = "SRM" + token.replacingOccurrences(of: "-", with: "") + "X"
            for index in 0..<pdf.pageCount {
                guard let text = pdf.page(at: index)?.string else { continue }
                for entry in text.components(separatedBy: prefix).dropFirst() {
                    let digits = entry.prefix(while: { $0.isASCII && $0.isNumber })
                    guard let id = Int(digits), (0..<count).contains(id),
                        entry.dropFirst(digits.count).first == "Z", pages[id] == nil
                    else { continue }
                    pages[id] = index
                }
            }
        }
        return pages
    }

    static func map(
        _ initial: LaTeXPageNumbers, targets: [Target], locations: [Int: Int], pageCount: Int,
        restartsAfterTitle: Bool, blankPages: Set<Int> = []
    ) -> Map {
        var state = initial
        let byPage = Dictionary(grouping: targets.indices.filter { locations[$0] != nil }) { locations[$0] }
        let hasAllCredits = targets.indices.allSatisfy { targets[$0].action != "examCredit" || locations[$0] != nil }
        var result = Map(pages: [], references: [:])
        var journalStates: [LaTeXPageNumbers] = []
        var endOfPaper = pageCount
        for page in 0..<pageCount {
            let indices = byPage[page] ?? []
            var title = false
            var score = 0.0
            for index in indices {
                let target = targets[index]
                if target.action == "journalSupplement" { endOfPaper = min(endOfPaper, page) }
                if target.classPlain == true { state.apply("classPlain", value: "") }
                if target.action == "title" {
                    state.apply("thispagestyle", value: "empty")
                    title = true
                } else if target.action == "majorMark" {
                    state.apply("leftmark", value: target.value)
                    state.apply("rightmark", value: "")
                } else if target.action == "examCredit", let points = Double(target.value), points.isFinite {
                    score += points
                } else {
                    state.apply(target.action, value: target.value)
                }
            }
            if hasAllCredits && score > 0 {
                result.examScores.append(ExamScore(label: state.label, points: score))
            }
            if blankPages.contains(page) { state.apply("thispagestyle", value: "empty") }
            if initial.usesJournalFurniture {
                journalStates.append(state)
            } else {
                result.pages.append(Page(state))
            }
            for index in indices where targets[index].referenced {
                result.references[String(index)] = state.label
            }
            state.advance()
            if title && restartsAfterTitle { state.apply("page", value: "1") }
        }
        if let first = journalStates.first, let last = journalStates.prefix(endOfPaper).last {
            // Only shipout knows the last printed label; a separate English abstract is outside this range.
            let range = "\(first.label)–\(last.label)"
            result.pages = journalStates.map { state in
                var page = state
                page.journalPageRange = range
                return Page(page)
            }
        } else if !journalStates.isEmpty {
            result.pages = journalStates.map(Page.init)
        }
        return result
    }

    /// Labels contain only digits, alphabetic characters or roman numerals produced by the counter.
    static func fill(_ values: [String: String], physicalPages: [Int: Int] = [:], examScores: [ExamScore] = []) throws
        -> String
    {
        let scores = String(decoding: try JSONEncoder().encode(examScores), as: UTF8.self)
        let pages = String(decoding: try JSONEncoder().encode(physicalPages), as: UTF8.self)
        let labels = String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
        return """
            const labels = \(labels);
            const scores = \(scores), pages = \(pages);
            // Question and part labels own their points on their physical page, even when a question spans pages.
            for (const table of document.querySelectorAll('table[data-exam-pages]')) {
              if (!scores.length) continue;
              const total = scores.reduce((sum, entry) => sum + entry.points, 0);
              const grade = table.dataset.examGrade === 'true';
              let rows;
              if (table.dataset.examPages === 'h') {
                rows = [['Page:', ...scores.map(s => s.label), 'Total'], ['Points:', ...scores.map(s => s.points), total]];
                if (grade) rows.push(['Score:', ...Array(scores.length + 1).fill('')]);
              } else {
                rows = [['Page', 'Points'], ...scores.map(s => [s.label, s.points]), ['Total:', total]];
                if (grade) rows.forEach((row, i) => row.push(i === 0 ? 'Score' : ''));
              }
              const body = document.createElement('tbody');
              for (const values of rows) {
                const row = body.insertRow();
                for (const value of values) row.insertCell().textContent = value;
              }
              table.tBodies[0].replaceWith(body);
            }
            let changedBackRefs = false;
            for (const {field, occurrences} of surimonoTeXPages.backRefs.values()) {
              const links = new Map();
              for (const {id,index} of occurrences) {
                const page = pages[index];
                if (labels[index] && page != null && !links.has(page)) links.set(page, {label:labels[index], id});
              }
              const elements = [];
              for (const page of [...links.keys()].sort((a,b) => a-b)) {
                const {label,id} = links.get(page);
                const a = document.createElement('a');
                a.href = '#' + id; a.textContent = label; a.dataset.latexBackref = '';
                elements.push(elements.length ? ', ' : ' ', a);
              }
              const before = field.textContent;
              field.replaceChildren(...elements);
              changedBackRefs ||= before !== field.textContent;
            }
            const updates = surimonoTeXPages.fields.flatMap((fields, index) =>
              fields.map(field => ({field, label: labels[index] ?? '?'})));
            const metric = field => {
              const row = field.parentElement.getBoundingClientRect();
              const cell = field.getBoundingClientRect();
              return [row.height, cell.width, cell.height].join(',');
            };
            const before = updates.map(({field}) => metric(field));
            for (const {field, label} of updates) field.textContent = label;
            // Inline references can wrap differently on paper. TOC columns reserve space for two digits.
            return !changedBackRefs && !scores.length && updates.every(({field}, i) => field.classList.contains('latex-page-label') &&
              metric(field) === before[i]) ? 'stable' : 'remeasure';
            """
    }

    /// NSPrintOperation can ship a page for the intervening empty div even when the next chapter
    /// already has break-before. Only coalesce vertical commands with no printable content between.
    static let coalesceNativeBreaks = """
        if (!document.body.matches('.format-latex')) return;
        const invisible = 'template,style,span[data-latex-page-action]:empty,span[id]:empty,.latex-pagebreak[hidden]';
        function adjacent(marker, direction) {
          let sibling = marker[direction];
          while (sibling && (sibling.nodeType === 3 && !sibling.textContent.trim() ||
              sibling.nodeType === 1 && sibling.matches(invisible))) sibling = sibling[direction];
          return sibling;
        }
        const forced = value => ['always','page','left','right'].includes(value);
        for (const marker of document.querySelectorAll('.latex-pagebreak')) {
          const next = adjacent(marker, 'nextSibling');
          const prior = adjacent(marker, 'previousSibling');
          if (next?.nodeType === 1 && next.matches('h2,h3,h4,h5,h6')) next.dataset.latexAfterBreak = '';
          if ((marker.parentElement === document.body && (!prior || !next)) ||
              next?.nodeType === 1 && (next.matches('.latex-pagebreak') || forced(getComputedStyle(next).breakBefore)) ||
              prior?.nodeType === 1 && forced(getComputedStyle(prior).breakAfter)) marker.hidden = true;
        }
        """

    /// Reads the targets' pages from a measured vertical strip and fills the fields before its capture. It returns
    /// whether the strip must be measured again: filling moved the text, and the pages may still change.
    @MainActor final class VerticalMeasurement {
        private(set) var pages: [Page] = []
        private(set) var incomplete = false
        private var previous: (locations: [Int: Int], references: [String: String])?

        func resolver(
            _ numbers: LaTeXPageNumbers, installation: Installation, restartsAfterTitle: Bool, in webView: WKWebView
        ) -> @MainActor ([Int: Int], Int, Bool, ContinuousClock.Instant) async throws -> Bool {
            { [self] pageOfSource, pageCount, isLastPass, deadline in
                let json = try await webView.evaluateForPrinting(verticalTargets, until: deadline) as? String
                let sources = json.flatMap { try? JSONDecoder().decode([String: Int].self, from: Data($0.utf8)) } ?? [:]
                var locations: [Int: Int] = [:]
                for (key, source) in sources {
                    if let index = Int(key), let page = pageOfSource[source] { locations[index] = page }
                }
                let map = LaTeXPageReferences.map(
                    numbers, targets: installation.targets, locations: locations, pageCount: pageCount,
                    restartsAfterTitle: restartsAfterTitle)
                pages = map.pages
                incomplete = installation.missing != 0 || installation.targets.indices.contains { locations[$0] == nil }
                // The strip already holds these numbers when the last measurement placed everything as before.
                let settled = previous.map { $0.locations == locations && $0.references == map.references } ?? false
                var layout = "stable"
                if !settled {
                    layout =
                        try await webView.evaluateForPrinting(
                            try fill(map.references, physicalPages: locations, examScores: map.examScores),
                            until: deadline) as? String ?? "remeasure"
                    previous = (locations, map.references)
                }
                guard layout == "stable" || isLastPass else { return true }
                _ = try await webView.evaluateForPrinting(removeProbes, until: deadline)
                // The last pass keeps its numbers, but the strip is still measured again if they moved the text.
                return layout != "stable"
            }
        }
    }

    /// The source band of each target in the measured vertical strip. A vertical line starts at its right edge.
    /// A heading's box also holds the space before it, which can lie in the previous band, so its first line counts.
    static let verticalTargets = """
        const sources = {};
        const range = document.createRange();
        for (const el of document.querySelectorAll('[data-latex-page-target],a[data-latex-probe]')) {
          const index = el.dataset.latexPageTarget ?? el.dataset.latexProbe;
          // A probe stands at the start of the element it was put in, or at its end when appended to it.
          const probe = el.matches('a[data-latex-probe]');
          range.selectNodeContents(probe ? el.parentElement : el);
          const lines = [...range.getClientRects()].filter(r => r.width && r.height);
          let box = (probe && !el.nextSibling ? lines.at(-1) : lines[0]) ?? el.getBoundingClientRect();
          if (!box.width && !box.height) box = el.parentElement.getBoundingClientRect();
          if (!box.width && !box.height) continue;
          sources[index] = surimonoVerticalFragment(new DOMRect(box.right - 1, box.top, 1, box.height)).slice;
        }
        return JSON.stringify(sources);
        """

    static let removeProbes = """
        for (const probe of document.querySelectorAll('[data-latex-probe]')) probe.remove();
        for (const el of document.querySelectorAll('[data-latex-page-target]')) el.removeAttribute('data-latex-page-target');
        delete globalThis.surimonoTeXPages;
        return 'clean';
        """
}
