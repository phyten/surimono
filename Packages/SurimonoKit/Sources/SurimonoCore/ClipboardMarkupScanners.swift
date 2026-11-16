import Foundation

extension ClipboardScanners {
    private static let htmlNames = Set(
        "abbr area bdi bdo cite data datalist dfn dialog embed fieldset hgroup legend map menu meter object optgroup output param progress q rp rt ruby search selectedcontent track wbr center font o:p amp-img amp-ad html head body title meta link base style script noscript template slot div span p a img br hr h1 h2 h3 h4 h5 h6 ul ol li dl dt dd table caption colgroup col thead tbody tfoot tr th td article section header footer nav main aside figure figcaption details summary pre code kbd samp var blockquote strong em b i u s small sub sup mark del ins time address button input form label select option textarea video audio source picture canvas iframe svg path g rect circle text math annotation mrow mi mo mn msup mfrac semantics !doctype"
            .split(separator: " ").map(String.init))
    private static let voidNames: Set<String> = [
        "area", "embed", "param", "track", "wbr", "meta", "link", "base", "img", "br", "hr", "input", "source", "col",
    ]

    private static let optionalEnds: Set<String> = [
        "p", "li", "dt", "dd", "tr", "td", "th", "thead", "tbody", "tfoot", "colgroup", "option", "optgroup",
        "html", "head", "body", "rt", "rp",
    ]

    private static func htmlName(_ name: String) -> Bool {
        htmlNames.contains(name)
            || (name.contains("-") && name.first?.isLetter == true
                && name.utf8.allSatisfy {
                    (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
                })
    }

    private static func impliedClose(_ open: String, before next: String) -> Bool {
        switch open {
        case "li": return next == "li"
        case "dt", "dd": return next == "dt" || next == "dd"
        case "td", "th": return ["td", "th", "tr", "thead", "tbody", "tfoot"].contains(next)
        case "tr": return ["tr", "thead", "tbody", "tfoot"].contains(next)
        case "thead", "tbody", "tfoot": return ["thead", "tbody", "tfoot"].contains(next)
        case "option": return ["option", "optgroup"].contains(next)
        case "optgroup": return next == "optgroup"
        case "rt", "rp": return next == "rt" || next == "rp"
        case "head": return next == "body"
        case "colgroup": return next != "col" && next != "template"
        case "p":
            return [
                "p", "div", "section", "article", "aside", "blockquote", "dl", "fieldset", "footer",
                "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hgroup", "hr", "main", "menu", "nav", "ol",
                "pre", "search", "table", "ul",
            ].contains(next)
        default: return false
        }
    }

    struct HTMLAcceptance: Sendable {
        var tags = 0
        var document = false
        var valid = true
        var starts = false
    }

    static func htmlAcceptance(_ bytes: [UInt8], work: inout ClipboardWork) -> HTMLAcceptance {
        var result = HTMLAcceptance()
        var i = 0
        var stack: [String] = []
        var raw: [UInt8]?
        var textStart = 0
        var first = true
        var rootJustOpened = false
        let commentOpen = Array("<!--".utf8)
        let commentClose = Array("-->".utf8)
        func string(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }
        func whitespace(_ b: UInt8) -> Bool { b == 32 || b == 9 || b == 10 || b == 13 || b == 12 }
        while i < bytes.count {
            work.visit()
            if let closing = raw {
                if bytes[i] == 60 && token(bytes, i, closing, folded: true, work: &work)
                    && (i + closing.count == bytes.count || whitespace(bytes[i + closing.count])
                        || bytes[i + closing.count] == 62)
                {
                    let body = ClipboardSlice(bytes, textStart..<i)
                    // Server-side interpolation is meaningful even in JavaScript strings and CSS values.
                    if stack.last != "pre" && stack.last != "code" && templateToken(body, work: &work) {
                        result.valid = false
                    }
                    raw = nil
                    textStart = i
                } else {
                    i += 1
                    continue
                }
            }
            guard bytes[i] == 60 else {
                i += 1
                continue
            }
            if textStart < i {
                let body = ClipboardSlice(bytes, textStart..<i)
                if !body.trimmed.isEmpty {
                    if first || stack.isEmpty || rootJustOpened { result.valid = false }
                    if unsafeText(bytes, range: body.range, html: true, work: &work) { result.valid = false }
                }
            }
            rootJustOpened = false
            if token(bytes, i, commentOpen, work: &work) {
                result.starts = result.starts || first
                first = false
                i += 4
                var closed = false
                while i < bytes.count {
                    work.visit()
                    if bytes[i] == 45 && token(bytes, i, commentClose, work: &work) {
                        i += 3
                        closed = true
                        break
                    }
                    i += 1
                }
                if !closed { result.valid = false }
                textStart = i
                continue
            }
            let start = i
            i += 1
            let closing = i < bytes.count && bytes[i] == 47
            if closing { i += 1 }
            let nameStart = i
            while i < bytes.count && !whitespace(bytes[i]) && bytes[i] != 62 && bytes[i] != 47 {
                work.visit()
                i += 1
            }
            let originalName = string(nameStart..<i)
            let name = originalName.lowercased()
            var quote: UInt8?
            var braces = 0
            var closed = false
            while i < bytes.count {
                work.visit()
                let b = bytes[i]
                i += 1
                if let q = quote {
                    if b == q { quote = nil }
                } else if b == 34 || b == 39 {
                    quote = b
                } else if b == 123 {
                    braces += 1
                    result.valid = false
                } else if b == 125 {
                    braces = max(0, braces - 1)
                } else if b == 62 && braces == 0 {
                    closed = true
                    break
                }
            }
            let tag = ClipboardSlice(bytes, start..<i)
            if !closed || !htmlName(name) { result.valid = false }
            if templateToken(tag, work: &work) || templateAttribute(tag, work: &work) { result.valid = false }
            if first {
                result.starts = true
                first = false
            }
            if name == "!doctype" {
                result.document = true
                rootJustOpened = true
            } else if !name.isEmpty {
                result.tags += 1
                if closing {
                    while let last = stack.last, last != name && optionalEnds.contains(last) { stack.removeLast() }
                    if stack.last == name { stack.removeLast() } else { result.valid = false }
                } else if !voidNames.contains(name) && !tag.hasSuffix("/>") {
                    while let last = stack.last, impliedClose(last, before: name) { stack.removeLast() }
                    stack.append(name)
                    if ["script", "style", "textarea", "title", "pre", "code"].contains(name) {
                        raw = Array("</\(name)".utf8)
                    }
                    if name == "html" {
                        result.document = true
                        rootJustOpened = true
                    }
                }
            }
            textStart = i
            // Rejection is final; the caller already knows whether HTML owns the start.
            // Keep the observed tags without tokenizing the rest of a hostile fragment.
            if !result.valid { return result }
        }
        if raw != nil || stack.contains(where: { !optionalEnds.contains($0) }) { result.valid = false }
        if textStart < bytes.count {
            let suffix = ClipboardSlice(bytes, textStart..<bytes.count)
            if !suffix.trimmed.isEmpty {
                if stack.isEmpty || first || rootJustOpened { result.valid = false }
                if unsafeText(bytes, range: suffix.range, html: true, work: &work) { result.valid = false }
            }
        }
        return result
    }

    static func templateToken(_ text: ClipboardSlice, work: inout ClipboardWork) -> Bool {
        let bytes = text.bytes
        for i in text.range {
            work.visit()
            guard i + 1 < text.range.upperBound else { continue }
            if bytes[i] == 123 && (bytes[i + 1] == 123 || bytes[i + 1] == 37) { return true }
            if bytes[i] == 60 && (bytes[i + 1] == 37 || bytes[i + 1] == 63) { return true }
        }
        // Blade and Razor directives are source syntax even outside tags.
        work.visit(text.count)
        guard bytes[text.range].contains(64) else { return false }
        for directive in ["@if", "@foreach", "@for", "@model", "@Model.", "@ViewData[", "@{", "@endif", "@endforeach"] {
            work.visit(text.count)
            if text.contains(directive) { return true }
        }
        return false
    }

    private static func templateAttribute(_ text: ClipboardSlice, work: inout ClipboardWork) -> Bool {
        let bytes = text.bytes
        var i = text.range.lowerBound
        var quote: UInt8?
        var boundary = false
        while i < text.range.upperBound {
            work.visit()
            let b = bytes[i]
            if let q = quote {
                if b == q { quote = nil }
            } else if b == 34 || b == 39 {
                quote = b
            } else if boundary {
                if [58, 64, 42, 40, 91].contains(b) { return true }
                if b == 118 && i + 1 < text.range.upperBound && bytes[i + 1] == 45 { return true }
            }
            if quote == nil && (b == 123 || (b == 61 && i + 1 < text.range.upperBound && bytes[i + 1] == 62)) {
                return true
            }
            boundary = b == 32 || b == 9 || b == 10 || b == 13
            i += 1
        }
        return false
    }

    static func safeInlineHTML(_ text: ClipboardSlice, work: inout ClipboardWork) -> Bool {
        if templateToken(text, work: &work) || templateAttribute(text, work: &work) { return false }
        work.visit(text.count)
        if text.hasPrefix("<!--") { return text.hasSuffix("-->") }
        let start = min(text.range.upperBound, text.range.lowerBound + (text.hasPrefix("</") ? 2 : 1))
        var end = start
        while end < text.range.upperBound && text.bytes[end] != 47 && text.bytes[end] != 62 {
            let scalar = text.scalar(at: end)
            if Unicode.Scalar(scalar.value)?.properties.isWhitespace == true { break }
            end += scalar.width
        }
        let name = ClipboardSlice(text.bytes, start..<end).string.lowercased()
        return htmlName(name)
    }

    static func html(_ window: ClipboardWindow, level: ClipboardFormatSettings.Carefulness, work: inout ClipboardWork)
        -> ClipboardCandidate
    {
        var candidate = ClipboardCandidate(kind: .html)
        work.visit(window.bytes.count)
        guard window.bytes.contains(60) else { return candidate }
        let parsed = htmlAcceptance(window.bytes, work: &work)
        let first = ClipboardSlice(window.bytes).trimmed
        // Inline HTML in another document is not independent HTML-document evidence.
        guard parsed.tags > 0 || parsed.document else { return candidate }
        guard first.hasPrefix("<") || ClipboardSlice(window.bytes).contains("<br>") else { return candidate }
        candidate.structures = max(1, parsed.tags)
        candidate.ownsStart = first.hasPrefix("<")
        candidate.accepted =
            parsed.valid && parsed.starts && !ClipboardSlice(window.bytes).hasPrefix("    ") && window.bytes.first != 9
        candidate.strength = parsed.document ? 90 : 50
        let requirement = level == .careful ? 10 : (level == .standard ? 4 : 2)
        candidate.sufficient = parsed.document || parsed.tags >= requirement
        candidate.evidence = [.markup(parsed.tags)]
        if parsed.document { candidate.evidence.append(.document) }
        if !parsed.valid { candidate.evidence.append(.incomplete) }
        return candidate
    }

    static func org(_ window: ClipboardWindow, level: ClipboardFormatSettings.Carefulness, work: inout ClipboardWork)
        -> ClipboardCandidate
    {
        var candidate = ClipboardCandidate(kind: .org)
        var block: String?
        var drawer = false
        var began = false
        var prefix = false
        var headings = 0
        var distinctive = 0
        var keywords = 0
        var blocks = 0
        var secondary = 0
        var markdownStars = false
        var running: [UInt8] = []
        running.reserveCapacity(window.bytes.count)
        for range in window.lines {
            let raw = ClipboardSlice(window.bytes, range)
            let line = raw.trimmed
            work.visit(range.count)
            if let name = block {
                if line.equals("#+end_\(name)", folded: true) || (name == ":" && line.equals("#+end:", folded: true)) {
                    block = nil
                } else if !["src", "example", "comment"].contains(name) {
                    appendOrgInline(line, to: &running, work: &work)
                }
                continue
            }
            if drawer {
                if line.equals(":end:", folded: true) {
                    drawer = false
                } else {
                    appendOrgInline(line, to: &running, work: &work)
                }
                continue
            }
            if line.hasPrefix("#+begin_", folded: true) {
                let start = line.range.lowerBound + 8
                let end = line.wordEnd(from: start)
                let name = ClipboardSlice(window.bytes, start..<end).string.lowercased()
                block = name
                blocks += 1
                distinctive += 2
                began = true
            } else if line.hasPrefix("#+begin:", folded: true) {
                block = ":"
                began = true
                blocks += 1
                distinctive += 2
            } else if line.equals(":properties:", folded: true) || line.equals(":logbook:", folded: true) {
                drawer = true
                distinctive += 1
                began = true
            } else if line.hasPrefix("#+") && matches(line, #"^#\+[a-zA-Z_]+:"#, work: &work) {
                keywords += 1
                distinctive += 1
                began = true
            } else if raw.first == 42 && matches(raw, #"^\*+\s+\S"#, work: &work) {
                headings += 1
                if raw.hasPrefix("* ") && (line.contains("**") || line.contains("[[")) { markdownStars = true }
                if raw.hasPrefix("**") { secondary += 1 }
                if raw.hasPrefix("**") || matches(line, #"^\*+\s+(TODO|DONE|NEXT|WAITING|CANCELLED)\b"#, work: &work) {
                    distinctive += 1
                }
                began = true
                appendOrgInline(line, to: &running, work: &work)
            } else if line.hasPrefix("|") {
                if began { distinctive += 1 }
            } else if line.hasPrefix("# ") || line.isEmpty {
                continue
            } else {
                if !began { prefix = true }
                if line.contains("[[") || line.hasPrefix("SCHEDULED:") || line.hasPrefix("DEADLINE:") {
                    distinctive += 1
                    secondary += 1
                }
                // Fixed-width example lines and inline verbatim own their syntax under Org's grammar.
                if !line.hasPrefix(": ") { appendOrgInline(line, to: &running, work: &work) }
            }
        }
        candidate.structures = distinctive > 0 || (headings >= 2 && !prefix) ? headings + distinctive : 0
        candidate.strength = 80
        candidate.ownsStart = !prefix && began
        if headings > 0 && secondary > 0 && keywords == 0 && blocks == 0
            && ClipboardSlice(window.bytes).contains("[[") && !ClipboardSlice(window.bytes).contains("][")
        {
            markdownStars = true
        }
        candidate.accepted = !prefix && block == nil && !drawer && !markdownStars && !unsafeText(running, work: &work)
        let requirement = level == .careful ? 3 : (level == .standard ? 2 : 1)
        candidate.sufficient = distinctive >= requirement || (distinctive >= 1 && headings >= 2)
        if headings == 0 && blocks == 0 { candidate.sufficient = keywords >= 3 }
        if keywords == 0 && blocks == 0 && secondary == 0 { candidate.sufficient = false }
        candidate.evidence = [.headings(headings), .metadata(keywords), .codeBlocks(blocks)]
        if !candidate.accepted { candidate.evidence.append(.conflictingSyntax) }
        return candidate
    }

    private static func appendOrgInline(_ text: ClipboardSlice, to output: inout [UInt8], work: inout ClipboardWork) {
        let bytes = text.bytes
        let base = output.count - text.range.lowerBound
        output.append(contentsOf: bytes[text.range])
        var delimiter: UInt8?
        var start = 0
        for i in text.range {
            work.visit()
            if let d = delimiter {
                if bytes[i] == d {
                    for j in start...i {
                        output[base + j] = 32
                        work.visit()
                    }
                    delimiter = nil
                }
            } else if bytes[i] == 37 && i + 2 < text.range.upperBound && bytes[i + 1] == 94 && bytes[i + 2] == 123 {
                delimiter = 125
                start = i
            } else if (bytes[i] == 61 || bytes[i] == 126) && (i == text.range.lowerBound || bytes[i - 1] == 32) {
                delimiter = bytes[i]
                start = i
            }
        }
        output.append(10)
    }

}

extension ClipboardScanners {
    static func markdownHTML(_ bytes: [UInt8], work: inout ClipboardWork, accepted: inout Bool) -> [UInt8] {
        var output = bytes
        var stack: [String] = []
        var index = 0
        func erase(_ range: Range<Int>) {
            for i in range { if output[i] != 10 { output[i] = 32 } }
        }
        while index < bytes.count {
            work.visit()
            if !stack.isEmpty && bytes[index] == 123 { accepted = false }
            guard bytes[index] == 60, index + 1 < bytes.count else {
                index += 1
                continue
            }
            let start = index
            let comment = token(bytes, index, Array("<!--".utf8), work: &work)
            if comment {
                index += 4
                var closed = false
                while index < bytes.count {
                    work.visit()
                    if token(bytes, index, Array("-->".utf8), work: &work) {
                        index += 3
                        closed = true
                        break
                    }
                    index += 1
                }
                if !closed { accepted = false }
                erase(start..<index)
                work.visit(index - start)
                continue
            }
            let closing = bytes[index + 1] == 47
            let nameStart = index + (closing ? 2 : 1)
            guard nameStart < bytes.count, (65...90).contains(bytes[nameStart]) || (97...122).contains(bytes[nameStart])
            else {
                index += 1
                continue
            }
            index = nameStart
            while index < bytes.count && ![9, 10, 13, 32, 47, 62].contains(bytes[index]) {
                work.visit()
                index += 1
            }
            let name = String(decoding: bytes[nameStart..<index], as: UTF8.self).lowercased()
            var quote: UInt8?
            var closed = false
            while index < bytes.count {
                work.visit()
                let byte = bytes[index]
                index += 1
                if let q = quote {
                    if byte == q { quote = nil }
                } else if byte == 34 || byte == 39 {
                    quote = byte
                } else if byte == 62 {
                    closed = true
                    break
                }
            }
            let tag = ClipboardSlice(bytes, start..<index)
            if !closed || !safeInlineHTML(tag, work: &work) { accepted = false }
            if closing {
                if stack.last == name { stack.removeLast() } else { accepted = false }
            } else if ![
                "area", "embed", "param", "track", "wbr", "meta", "link", "base", "img", "br", "hr", "input", "source",
                "col",
            ].contains(name)
                && !tag.hasSuffix("/>")
            {
                if ["script", "style", "textarea", "title"].contains(name) {
                    let end = Array("</\(name)".utf8)
                    let bodyStart = index
                    var found = false
                    while index < bytes.count {
                        work.visit()
                        if token(bytes, index, end, folded: true, work: &work) && index + end.count < bytes.count
                            && [9, 10, 13, 32, 62].contains(bytes[index + end.count])
                        {
                            found = true
                            break
                        }
                        index += 1
                    }
                    if !found { accepted = false }
                    let body = ClipboardSlice(bytes, bodyStart..<index)
                    if templateToken(body, work: &work) { accepted = false }
                }
                stack.append(name)
            }
            erase(start..<index)
            work.visit(index - start)
        }
        if !stack.isEmpty { accepted = false }
        return output
    }
}
