import Foundation

/// Readers mark the lists while assembling a fragment. Keep their identities alongside the final HTML so ordinary
/// conversion (including Quick Look and export) keeps the original markup, down to its attribute order.
public enum ReaderContentsKind: String, Sendable {
    case lead, text, contents, figures, tables

    // Raw HTML in the manuscript cannot be mistaken for one of the reader's temporary tags.
    fileprivate static let attribute = "data-surimono-" + UUID().uuidString.lowercased()

    func mark(_ nav: String) -> String {
        guard nav.hasPrefix("<nav ") else { return nav }
        return "<nav \(ReaderContentsKind.attribute)=\"\(rawValue)\" " + nav.dropFirst(5)
    }
}

extension HTMLFragment {
    func recordingContents(_ file: ReadingFileInstructions = .init()) -> Self {
        var result = self
        result.contentsInstructions = file
        guard body.contains("<nav \(ReaderContentsKind.attribute)=") || body.contains("<nav class=\"beamer-toc\"")
        else {
            return result
        }
        var index = 0
        var html = ""
        HTMLScanner.forEachToken(body) { token in
            switch token {
            case .opaque(let text), .text(let text): html += text
            case .tag(let tag):
                var source = tag.source
                if tag.name == "nav", !tag.isClosing {
                    if let raw = tag.attribute(ReaderContentsKind.attribute),
                        let kind = ReaderContentsKind(rawValue: raw)
                    {
                        result.contentsKinds[index] = kind
                        source = source.replacingOccurrences(
                            of: " \(ReaderContentsKind.attribute)=\"\(raw)\"", with: "")
                    } else if tag.attribute("class") == "beamer-toc" {
                        result.contentsKinds[index] = .contents
                    }
                    index += 1
                }
                html += source
            }
        }
        result.body = html
        return result
    }

    package var leadEntries: [DocumentHeading]? {
        if let index = contentsKinds.first(where: { $0.value == .lead })?.key {
            return DocumentOutline.contentsHeadings(in: body, navIndex: index)
        }
        return proposedLeadContents.map { DocumentOutline.contentsHeadings(in: $0.html, navIndex: 0) }
    }

    package func prependingLead(_ nav: String) -> Self {
        guard !nav.isEmpty else { return self }
        var copy = self
        copy.body = Self.placingLead(nav, in: body)
        copy.contentsKinds = Dictionary(uniqueKeysWithValues: contentsKinds.map { ($0.key + 1, $0.value) })
        copy.contentsKinds[0] = .lead
        return copy
    }

    /// The body with the lead contents at its head, after the title when the body opens with one: a first-level
    /// heading the document begins with and the only one it has is its title, as the contents leave it out, and the
    /// contents come after a title. Among several first-level headings the first is a chapter the contents list. The
    /// elements are read as elements: a heading in a comment or with an upper-case tag counts as what it is.
    package static func placingLead(_ nav: String, in body: String) -> String {
        guard !nav.isEmpty else { return body }
        enum Stage {
            case start, title, afterTitle, rest
        }
        var stage = Stage.start
        var head = ""
        var titled = false
        var anotherTitle = false
        HTMLScanner.forEachToken(body) { token in
            guard !anotherTitle else { return }
            let source: String
            var opensTitle = false
            var closesTitle = false
            switch token {
            case .text(let text), .opaque(let text): source = text
            case .tag(let tag):
                source = tag.source
                opensTitle = tag.name == "h1" && !tag.isClosing
                closesTitle = tag.name == "h1" && tag.isClosing
            }
            switch stage {
            case .start:
                head += source
                if opensTitle {
                    stage = .title
                } else if case .tag = token {
                    stage = .rest
                } else if case .text(let text) = token, !text.allSatisfy(\.isWhitespace) {
                    stage = .rest
                }
            case .title:
                head += source
                if closesTitle {
                    stage = .afterTitle
                    titled = true
                }
            case .afterTitle:
                // The line break after the title stays with it.
                if case .text(let text) = token, text.hasPrefix("\n") { head += "\n" }
                stage = .rest
                if opensTitle { anotherTitle = true }
            case .rest:
                if opensTitle { anotherTitle = true }
            }
        }
        guard titled, !anotherTitle else { return nav + body }
        return head + nav + String(body.dropFirst(head.count))
    }

    private func contentsKind(of nav: HTMLScanner.Tag, at index: Int) -> ReaderContentsKind? {
        contentsKinds[index] ?? (nav.attribute("class")?.split(separator: " ").contains("toc") == true ? .text : nil)
    }

    /// Classify the original navs, before the finish removes a lead or hides a manuscript marker.
    package var sourceContentsKinds: Set<ReaderContentsKind> {
        var kinds = Set(contentsKinds.values)
        // The legacy AsciiDoc reader folds a manuscript macro into its automatic lead contents.
        if coalescesContentsInLegacy, kinds.contains(.lead) { kinds.insert(.text) }
        guard !kinds.contains(.text), body.contains("<nav") else { return kinds }
        var index = 0
        HTMLScanner.forEachToken(body) { token in
            if case .tag(let tag) = token, tag.name == "nav", !tag.isClosing {
                if let kind = contentsKind(of: tag, at: index) { kinds.insert(kind) }
                index += 1
            }
        }
        return kinds
    }

    /// Only a customized finish needs a different body. Skip whole nav elements, including nested markup.
    package func filteringContents(_ hidden: Set<ReaderContentsKind>, forPaper: Bool) -> String {
        guard !hidden.isEmpty || forPaper, body.contains("<nav") else { return body }
        var html = ""
        var index = 0
        var skipping = 0
        HTMLScanner.forEachToken(body) { token in
            switch token {
            case .opaque(let text), .text(let text):
                if skipping == 0 { html += text }
            case .tag(let tag):
                if tag.name == "nav" {
                    if tag.isClosing {
                        if skipping > 0 {
                            skipping -= 1
                            return
                        }
                    } else {
                        let kind = contentsKind(of: tag, at: index)
                        index += 1
                        if skipping == 0, forPaper, kind == .text {
                            let attribute = hidden.contains(.text) ? "data-surimono-hidden" : "data-surimono-in-text"
                            html += String(tag.source.dropLast()) + " " + attribute + ">"
                            return
                        }
                        if skipping > 0 || kind.map(hidden.contains) == true {
                            if !tag.isSelfClosing { skipping += 1 }
                            return
                        }
                    }
                }
                if skipping == 0 { html += tag.source }
            }
        }
        return html
    }
}

extension HTMLFragment {
    func addingLeadContents(depth: ReadingDepth?) -> Self {
        guard let depth else { return self }
        var headings = DocumentOutline.headings(inHTML: body)
        return addingLeadContents(headings: &headings, depth: depth)
    }

    package func addingLeadContents(headings: inout [DocumentHeading], depth: ReadingDepth) -> Self {
        guard !headings.isEmpty else { return self }
        var copy = self
        if headings.contains(where: { $0.id?.isEmpty != false }) {
            var ids: Set<String> = []
            HTMLScanner.forEachToken(body) { token in
                if case .tag(let tag) = token, let id = tag.attribute("id") { ids.insert(id) }
            }
            var next = 0
            var anchored = ""
            HTMLScanner.forEachToken(body) { token in
                switch token {
                case .text(let text), .opaque(let text): anchored += text
                case .tag(let tag):
                    if !tag.isClosing, ["h1", "h2", "h3", "h4", "h5", "h6"].contains(tag.name),
                        tag.attribute("id") == nil
                    {
                        repeat { next += 1 } while ids.contains("surimono-heading-\(next)")
                        anchored += String(tag.source.dropLast()) + " id=\"surimono-heading-\(next)\">"
                    } else {
                        anchored += tag.source
                    }
                }
            }
            copy.body = anchored
            headings = DocumentOutline.headings(inHTML: anchored)
        }
        // A heading with a formula is listed as it is printed, as the manuscript's own contents list it.
        let printedHTML = DocumentOutline.headingsContentsHTML(inHTML: copy.body)
        let anchors = headings.enumerated().map { index, heading in
            MarkdownExtensions.HeadingAnchor(
                level: heading.level, id: heading.id ?? "", text: heading.text,
                html: heading.printedText.contains(DocumentHeading.formulaStart) && printedHTML.count == headings.count
                    ? printedHTML[index] : nil)
        }
        let nav = MarkdownExtensions.tableOfContents(anchors, levels: depth.headingLevels, title: contentsTitle)
        return copy.prependingLead(nav)
    }
}
