import Foundation

struct LaTeXCorrespondence {
    var name = ""
    var address = ""
    var signature: String?
    var recipient = ""
    var openedLetter = false
    var letterCount = 0
    var contacts: [String] = []
    var photo: (name: String, width: String, frame: String)?
    var color = "blue"

    // The classic palette is expressed as sRGB so the PDF and HTML use the same section ink.
    static let defaultInk = "#3873b3"
    static let palette = [
        "blue": defaultInk, "burgundy": "#980000", "cerulean": "#0081a7", "green": "#59b34d", "grey": "#737373",
        "orange": "#f28c26", "purple": "#8054cc", "red": "#f23333", "black": "#000000",
    ]
}

extension LaTeXReader {
    func handleCorrespondence(_ command: String) -> Bool {
        switch document.classInfo.name {
        case "letter": return letterCommand(command)
        case "moderncv": return cvCommand(command)
        default: return false
        }
    }

    func readLetter(_ source: String) {
        let reader = LaTeXReader(source, document: document, isBlock: true)
        document.correspondence.recipient = reader.argument() ?? ""
        document.correspondence.openedLetter = false
        let page =
            document.correspondence.letterCount > 0
            ? "<div class=\"latex-pagebreak\" data-latex-break=\"clear\"></div>" : ""
        document.correspondence.letterCount += 1
        reader.pageAction("thispagestyle", "empty")
        let body = reader.read()
        let header = document.correspondence.openedLetter ? "" : letterHeader()
        appendBlock("\(page)<section class=\"latex-letter\">\(header)\(body)</section>\n")
    }

    private func letterHeader() -> String {
        let state = document.correspondence
        let address = inline(state.address)
        let date = inline(document.frontMatter.date ?? document.today())
        return "<div class=\"latex-letter-sender\">\(address)<p>\(date)</p></div>"
            + "<div class=\"latex-letter-recipient\">\(inline(state.recipient))</div>"
    }

    private func letterCommand(_ command: String) -> Bool {
        switch command {
        case "name": document.correspondence.name = argument() ?? ""
        case "address": document.correspondence.address = argument() ?? ""
        case "signature": document.correspondence.signature = argument()
        case "opening":
            guard !document.correspondence.openedLetter else {
                appendBlock("<p>\(inline(argument() ?? ""))</p>")
                return true
            }
            document.correspondence.openedLetter = true
            appendBlock(letterHeader() + "<p class=\"latex-letter-opening\">\(inline(argument() ?? ""))</p>")
        case "closing":
            let close = inline(argument() ?? "")
            let state = document.correspondence
            let signature = inline(state.signature ?? state.name)
            let indent = state.address.isEmpty ? "" : " latex-letter-indented"
            appendBlock("<div class=\"latex-letter-closing\(indent)\">\(close)<p>\(signature)</p></div>")
        case "ps": appendBlock("")
        case "cc", "encl":
            let label = command == "cc" ? "cc" : "encl"
            appendBlock("<p class=\"latex-letter-attachment\">\(label): \(inline(argument() ?? ""))</p>")
        default: return false
        }
        return true
    }

    private func cvCommand(_ command: String) -> Bool {
        switch command {
        case "moderncvstyle": _ = argument()
        case "moderncvcolor": document.correspondence.color = argument() ?? "blue"
        case "name":
            let first = argument() ?? ""
            document.correspondence.name = [first, argument() ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        case "address":
            var lines = [argument() ?? ""]
            for _ in 0..<2 {
                skipSpaces()
                if peek() == "{" { lines.append(argument() ?? "") }
            }
            document.correspondence.address = lines.filter { !$0.isEmpty }.joined(separator: "\\\\")
        case "phone", "social", "email", "homepage", "extrainfo":
            let label = optional() ?? ""
            if command == "social" { _ = optional() }
            let value = argument() ?? ""
            document.correspondence.contacts.append(label.isEmpty ? value : "\(label): \(value)")
        case "photo":
            let width = optional().flatMap(LaTeXSymbols.printLength) ?? "17.5%"
            let frame = LaTeXSymbols.printLength(optional() ?? "0.4pt") ?? "0"
            document.correspondence.photo = (argument() ?? "", width, frame)
        case "makecvtitle", "maketitle": cvTitle()
        case "section": section("section", numbered: false)
        case "cventry", "cvitem", "cvitemwithcomment", "cvdoubleitem", "cvlistitem", "cvlistdoubleitem":
            cvRow(command)
        default: return false
        }
        return true
    }

    private func cvTitle() {
        guard !document.makingTitle else { return }
        document.makingTitle = true
        defer { document.makingTitle = false }
        let state = document.correspondence
        let name = inline(state.name)
        let title = inline(document.frontMatter.title ?? "")
        document.titleHTML = title.isEmpty ? name : title
        let contacts = ([state.address] + state.contacts).filter { !$0.isEmpty }.map { "<div>\(inline($0))</div>" }
            .joined()
        var photo = ""
        if let image = state.photo {
            let resolved = document.imageSource(image.name)
            let alt = HTML.escape(image.name)
            photo =
                resolved.url == nil
                ? alt
                : "<img src=\"\(HTML.escape(resolved.source))\" alt=\"\(alt)\" style=\"width: \(image.width); border: \(image.frame) solid currentColor\">"
        }
        appendBlock(
            "<header class=\"latex-cv-title\"><div><h1>\(name)</h1><p>\(title)</p></div><div>\(contacts)</div>\(photo)</header>"
        )
    }

    private func cvRow(_ command: String) {
        let spacing = optional().flatMap(LaTeXSymbols.printLength)
        let style = spacing.map { " style=\"--cv-item-skip: \($0)\"" } ?? ""
        func field() -> String { inline(argument() ?? "") }
        func cell(_ label: String, _ body: String) -> String {
            "<div class=\"latex-cv-item\"\(style)><div class=\"latex-cv-label\">\(label)</div><div>\(body)</div></div>"
        }
        switch command {
        case "cventry":
            let year = field()
            let title = field()
            let employer = field()
            let details = [
                title.isEmpty ? "" : "<strong>\(title)</strong>",
                employer.isEmpty ? "" : "<em>\(employer)</em>", field(), field(),
            ]
            .filter { !$0.isEmpty }.joined(separator: ", ")
            let body = blocks(argument() ?? "")
            appendBlock(cell(year, details + (body.isEmpty ? "" : "<div class=\"latex-cv-detail\">\(body)</div>")))
        case "cvdoubleitem":
            let left = cell(field(), field())
            appendBlock("<div class=\"latex-cv-pair\">\(left)\(cell(field(), field()))</div>")
        case "cvlistdoubleitem":
            let first = field()
            appendBlock(
                cell("", "<div class=\"latex-cv-double\"><span>• \(first)</span><span>• \(field())</span></div>"))
        case "cvlistitem": appendBlock(cell("", "• " + field()))
        case "cvitemwithcomment":
            let label = field()
            let body = field()
            let comment = field()
            appendBlock(cell(label, "<div class=\"latex-cv-comment\">\(body) <em>\(comment)</em></div>"))
        default: appendBlock(cell(field(), blocks(argument() ?? "")))
        }
    }
}
