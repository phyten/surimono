import Foundation

extension ClipboardScanners {
    private static let htmlNames = Set(
        "center font o:p amp-img amp-ad html head body title meta link base style script noscript template slot div span p a img br hr h1 h2 h3 h4 h5 h6 ul ol li dl dt dd table caption colgroup col thead tbody tfoot tr th td article section header footer nav main aside figure figcaption details summary pre code kbd samp var blockquote strong em b i u s small sub sup mark del ins time address button input form label select option textarea video audio source picture canvas iframe svg path g rect circle text math annotation mrow mi mo mn msup mfrac semantics !doctype"
            .split(separator: " ").map(String.init))
    private static let voidNames: Set<String> = ["meta", "link", "base", "img", "br", "hr", "input", "source", "col"]

    struct HTMLAcceptance: Sendable {
        var tags = 0
        var document = false
        var valid = true
        var starts = false
    }

    static func htmlAcceptance(_ text: String, work: inout ClipboardWork) -> HTMLAcceptance {
        let bytes = Array(text.utf8)
        let lowerBytes = bytes.map { (65...90).contains($0) ? $0 + 32 : $0 }
        var result = HTMLAcceptance()
        var i = 0
        var stack: [String] = []
        var raw: String?
        var textStart = 0
        var first = true
        var rootJustOpened = false
        let commentOpen = Array("<!--".utf8)
        let commentClose = Array("-->".utf8)
        func string(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }
        func whitespace(_ b: UInt8) -> Bool { b == 32 || b == 9 || b == 10 || b == 13 || b == 12 }
        while i < bytes.count {
            work.visit()
            if let name = raw {
                let closing = Array("</\(name)".utf8)
                if bytes[i] == 60 && token(lowerBytes, i, closing, work: &work)
                    && (i + closing.count == bytes.count || whitespace(bytes[i + closing.count])
                        || bytes[i + closing.count] == 62)
                {
                    let body = string(textStart..<i)
                    // Server-side interpolation is meaningful even in JavaScript strings and CSS values.
                    if templateToken(body, work: &work) { result.valid = false }
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
                let body = string(textStart..<i)
                if !trimmed(body).isEmpty {
                    if first || stack.isEmpty || rootJustOpened { result.valid = false }
                    if unsafeText(body, html: true, work: &work) { result.valid = false }
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
            var closed = false
            while i < bytes.count {
                work.visit()
                let b = bytes[i]
                i += 1
                if let q = quote {
                    if b == q { quote = nil }
                } else if b == 34 || b == 39 {
                    quote = b
                } else if b == 62 {
                    closed = true
                    break
                }
            }
            let tag = string(start..<i)
            if !closed || !htmlNames.contains(name) { result.valid = false }
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
                    if ["ul", "ol"].contains(name) && stack.last == "li" { stack.removeLast() }
                    if stack.last == name { stack.removeLast() } else { result.valid = false }
                } else if !voidNames.contains(name) && !tag.hasSuffix("/>") {
                    if name == "li" && stack.last == "li" { stack.removeLast() }
                    stack.append(name)
                    if name == "script" || name == "style" || name == "textarea" || name == "title" { raw = name }
                    if name == "html" {
                        result.document = true
                        rootJustOpened = true
                    }
                }
            }
            textStart = i
        }
        if raw != nil || !stack.isEmpty { result.valid = false }
        if textStart < bytes.count {
            let suffix = string(textStart..<bytes.count)
            if !trimmed(suffix).isEmpty {
                if stack.isEmpty || first || rootJustOpened { result.valid = false }
                if unsafeText(suffix, html: true, work: &work) { result.valid = false }
            }
        }
        return result
    }

    static func templateToken(_ text: String, work: inout ClipboardWork) -> Bool {
        let bytes = Array(text.utf8)
        for i in bytes.indices {
            work.visit()
            guard i + 1 < bytes.count else { continue }
            if bytes[i] == 123 && (bytes[i + 1] == 123 || bytes[i + 1] == 37) { return true }
            if bytes[i] == 60 && (bytes[i + 1] == 37 || bytes[i + 1] == 63) { return true }
        }
        return false
    }

    private static func templateAttribute(_ text: String, work: inout ClipboardWork) -> Bool {
        let bytes = Array(text.utf8)
        var i = 0
        var quote: UInt8?
        var boundary = false
        while i < bytes.count {
            work.visit()
            let b = bytes[i]
            if let q = quote {
                if b == q { quote = nil }
            } else if b == 34 || b == 39 {
                quote = b
            } else if boundary {
                if b == 58 || b == 64 { return true }
                if b == 118 && i + 1 < bytes.count && bytes[i + 1] == 45 { return true }
            }
            boundary = b == 32 || b == 9 || b == 10 || b == 13
            i += 1
        }
        return false
    }

    static func safeInlineHTML(_ text: String, work: inout ClipboardWork) -> Bool {
        if templateToken(text, work: &work) || templateAttribute(text, work: &work) { return false }
        work.visit(text.utf8.count)
        if text.hasPrefix("<!--") { return text.hasSuffix("-->") }
        let name = text.dropFirst(text.hasPrefix("</") ? 2 : 1).prefix { !$0.isWhitespace && $0 != "/" && $0 != ">" }
            .lowercased()
        return htmlNames.contains(name)
    }

    static func html(_ window: ClipboardWindow, level: ClipboardFormatSettings.Carefulness, work: inout ClipboardWork)
        -> ClipboardCandidate
    {
        var candidate = ClipboardCandidate(kind: .html)
        let parsed = htmlAcceptance(window.text, work: &work)
        let first = trimmed(window.text)
        // Inline HTML in another document is not independent HTML-document evidence.
        guard parsed.tags > 0 || parsed.document else { return candidate }
        guard first.hasPrefix("<") || window.text.contains("<br>") else { return candidate }
        candidate.structures = max(1, parsed.tags)
        candidate.ownsStart = first.hasPrefix("<")
        candidate.accepted =
            parsed.valid && parsed.starts && !window.text.hasPrefix("    ") && !window.text.hasPrefix("\t")
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
        var running = ""
        for range in window.lines {
            let raw = window.string(range)
            let line = trimmed(raw)
            let lower = line.lowercased()
            work.visit(range.count)
            if let name = block {
                if lower == "#+end_\(name)" || (name == ":" && lower == "#+end:") {
                    block = nil
                } else if !["src", "example", "comment"].contains(name) {
                    running += orgInline(line, work: &work) + "\n"
                }
                continue
            }
            if drawer {
                if lower == ":end:" { drawer = false } else { running += orgInline(line, work: &work) + "\n" }
                continue
            }
            if lower.hasPrefix("#+begin_") {
                let name = String(lower.dropFirst(8).prefix { !$0.isWhitespace })
                block = name
                blocks += 1
                distinctive += 2
                began = true
            } else if lower.hasPrefix("#+begin:") {
                block = ":"
                began = true
                blocks += 1
                distinctive += 2
            } else if lower == ":properties:" || lower == ":logbook:" {
                drawer = true
                distinctive += 1
                began = true
            } else if matches(line, #"^#\+[a-zA-Z_]+:"#, work: &work) {
                keywords += 1
                distinctive += 1
                began = true
            } else if matches(raw, #"^\*+\s+\S"#, work: &work) {
                headings += 1
                if raw.hasPrefix("**") { secondary += 1 }
                if raw.hasPrefix("**") || matches(line, #"^\*+\s+(TODO|DONE|NEXT|WAITING|CANCELLED)\b"#, work: &work) {
                    distinctive += 1
                }
                began = true
                running += orgInline(line, work: &work) + "\n"
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
                if !line.hasPrefix(": ") { running += orgInline(line, work: &work) + "\n" }
            }
        }
        candidate.structures = distinctive > 0 || (headings >= 2 && !prefix) ? headings + distinctive : 0
        candidate.strength = 80
        candidate.ownsStart = !prefix && began
        candidate.accepted = !prefix && block == nil && !drawer && !unsafeText(running, work: &work)
        let requirement = level == .careful ? 3 : (level == .standard ? 2 : 1)
        candidate.sufficient = distinctive >= requirement || (distinctive >= 1 && headings >= 2)
        if headings == 0 && blocks == 0 { candidate.sufficient = keywords >= 3 }
        if keywords == 0 && blocks == 0 && secondary == 0 { candidate.sufficient = false }
        candidate.evidence = [.headings(headings), .metadata(keywords), .codeBlocks(blocks)]
        if !candidate.accepted { candidate.evidence.append(.conflictingSyntax) }
        return candidate
    }

    private static func orgInline(_ text: String, work: inout ClipboardWork) -> String {
        let bytes = Array(text.utf8)
        var output = bytes
        var delimiter: UInt8?
        var start = 0
        for i in bytes.indices {
            work.visit()
            if let d = delimiter {
                if bytes[i] == d {
                    for j in start...i {
                        output[j] = 32
                        work.visit()
                    }
                    delimiter = nil
                }
            } else if bytes[i] == 37 && i + 2 < bytes.count && bytes[i + 1] == 94 && bytes[i + 2] == 123 {
                delimiter = 125
                start = i
            } else if (bytes[i] == 61 || bytes[i] == 126) && (i == 0 || bytes[i - 1] == 32) {
                delimiter = bytes[i]
                start = i
            }
        }
        return String(decoding: output, as: UTF8.self)
    }
}

extension ClipboardScanners {
    static func markdownHTML(_ text: String, work: inout ClipboardWork, accepted: inout Bool) -> String {
        let bytes = Array(text.utf8)
        let lower = bytes.map { (65...90).contains($0) ? $0 + 32 : $0 }
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
            guard nameStart < bytes.count, (97...122).contains(lower[nameStart]) else {
                index += 1
                continue
            }
            index = nameStart
            while index < bytes.count && ![9, 10, 13, 32, 47, 62].contains(bytes[index]) {
                work.visit()
                index += 1
            }
            let name = String(decoding: lower[nameStart..<index], as: UTF8.self)
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
            let tag = String(decoding: bytes[start..<index], as: UTF8.self)
            if !closed || !safeInlineHTML(tag, work: &work) { accepted = false }
            if closing {
                if stack.last == name { stack.removeLast() } else { accepted = false }
            } else if !["meta", "link", "base", "img", "br", "hr", "input", "source", "col"].contains(name)
                && !tag.hasSuffix("/>")
            {
                if ["script", "style", "textarea", "title"].contains(name) {
                    let end = Array("</\(name)".utf8)
                    let bodyStart = index
                    var found = false
                    while index < bytes.count {
                        work.visit()
                        if token(lower, index, end, work: &work) && index + end.count < bytes.count
                            && [9, 10, 13, 32, 62].contains(bytes[index + end.count])
                        {
                            found = true
                            break
                        }
                        index += 1
                    }
                    if !found { accepted = false }
                    let body = String(decoding: bytes[bodyStart..<index], as: UTF8.self)
                    if templateToken(body, work: &work) { accepted = false }
                }
                stack.append(name)
            }
            erase(start..<index)
            work.visit(index - start)
        }
        if !stack.isEmpty { accepted = false }
        return String(decoding: output, as: UTF8.self)
    }
}
