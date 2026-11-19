import Foundation

extension LaTeXReader {
    /// Print each frame's contents once. Its overlay and alignment options describe projection,
    /// while the surrounding document continues to choose the paper and page breaks.
    func handleBeamerCommand(_ name: String) -> Bool {
        guard document.classInfo.name == "beamer" else { return false }
        switch name {
        case "frame":
            skipFrameOptions()
            let reader = LaTeXReader(argument() ?? "", document: document, isBlock: true)
            readBeamerFrame(reader)
        case "titlepage":
            makeTitle()
        case "frametitle", "framesubtitle":
            skipOverlay()
            _ = optional()
            frameHeading(argument() ?? "", subtitle: name == "framesubtitle")
        case "setbeamertemplate":
            let template = argument()
            let choice = optional()
            if choice == nil { _ = argument() }
            if template == "caption", choice == "numbered" || choice == "default" {
                document.numberedBeamerCaptions = choice == "numbered"
            } else {
                document.recordUnknown("\\setbeamertemplate")
            }
        default: return false
        }
        return true
    }

    func readBeamerEnvironment(_ name: String, body: String) {
        let reader = LaTeXReader(body, document: document, isBlock: true)
        if name == "frame" {
            reader.skipFrameOptions()
            readBeamerFrame(reader)
        } else {
            reader.skipOverlay()
            let title = reader.argument().map(inline) ?? ""
            let heading = title.isEmpty ? "" : "<p class=\"latex-beamer-block-title\"><strong>\(title)</strong></p>\n"
            appendBlock("<div class=\"latex-beamer-block\">\n" + heading + reader.read() + "</div>\n")
        }
    }

    private func readBeamerFrame(_ reader: LaTeXReader) {
        let previous = document.insideBeamerFrame
        let numberedCaptions = document.numberedBeamerCaptions
        document.insideBeamerFrame = true
        defer {
            document.insideBeamerFrame = previous
            document.numberedBeamerCaptions = numberedCaptions
        }
        reader.skipSpaces()
        if reader.peek() == "{", let title = reader.argument() {
            frameHeading(title, subtitle: false)
            reader.skipSpaces()
            if reader.peek() == "{", let subtitle = reader.argument() { frameHeading(subtitle, subtitle: true) }
        }
        appendBlock(reader.read())
    }

    private func frameHeading(_ source: String, subtitle: Bool) {
        let title = inline(source)
        guard !title.isEmpty else { return }
        let tag = subtitle ? "h3" : "h2"
        appendBlock("<\(tag) class=\"latex-beamer-frame-title\">\(title)</\(tag)>\n")
    }

    private func skipFrameOptions() {
        skipOverlay()
        while optional() != nil {}
    }

    private func skipOverlay() {
        skipSpaces()
        // An unmatched angle bracket in prose must not consume the rest of the frame.
        if peek() == "<", let end = characters[index...].firstIndex(where: { $0 == ">" || $0 == "\n" }),
            characters[end] == ">"
        {
            index = end + 1
        }
    }
}
