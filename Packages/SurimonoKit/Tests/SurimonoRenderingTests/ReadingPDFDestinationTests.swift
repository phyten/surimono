import PDFKit
import SurimonoCore
import Testing

@testable import SurimonoRendering

@MainActor
struct ReadingPDFDestinationTests {
    // Use independent PDF objects: PDFKit cannot author FitR and can lose a GoTo on write.
    private func file(
        link: String = "/Dest /left", bookmark: String = "/Dest (region)", open: Bool = false,
        mediaBox: String = "0 0 200 300", rect: String? = "10 10 20 20"
    ) -> Data {
        let annotations = rect == nil ? "" : "/Annots [4 0 R]"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /Outlines 5 0 R /Dests << /left [3 0 R /FitH null] >> /Names << /Dests << /Kids [10 0 R] >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [\(mediaBox)] /Resources << >> \(annotations) >>",
            "<< /Type /Annot /Subtype /Link /Rect [\(rect ?? "")] \(link) >>",
            "<< /Type /Outlines /First 6 0 R /Last 6 0 R /Count \(open ? 4 : 1) >>",
            "<< /Title (Parent) /Parent 5 0 R /First 7 0 R /Last 8 0 R /Count \(open ? 3 : -3) >>",
            "<< /Title (Branch) /Parent 6 0 R /Next 8 0 R /First 9 0 R /Last 9 0 R /Count 1 >>",
            "<< /Title (Tail) /Parent 6 0 R /Prev 7 0 R /Dest [3 0 R /Fit] >>",
            "<< /Title (Leaf) /Parent 7 0 R \(bookmark) >>",
            "<< /Limits [(region) (region)] /Names [(region) << /D [3 0 R /FitR 21 32 104 205] >>] >>",
        ]
        return pdf(objects)
    }

    private func pdf(_ objects: [String]) -> Data {
        var data = Data("%PDF-1.7\n".utf8)
        var offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(contentsOf: "\(index + 1) 0 obj\n\(object)\nendobj\n".utf8)
        }
        let start = data.count
        data.append(contentsOf: "xref\n0 \(offsets.count)\n0000000000 65535 f \n".utf8)
        for offset in offsets.dropFirst() {
            data.append(contentsOf: String(format: "%010d 00000 n \n", offset).utf8)
        }
        data.append(
            contentsOf: "trailer\n<< /Size \(offsets.count) /Root 1 0 R >>\nstartxref\n\(start)\n%%EOF"
                .utf8)
        return data
    }

    // The two pages have different horizontal origins so a link cannot use its own page's offset for its target.
    private func offsetPages() -> Data {
        pdf([
            "<< /Type /Catalog /Pages 2 0 R /Outlines 7 0 R >>",
            "<< /Type /Pages /Count 2 /Kids [3 0 R 4 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [11 2.000036 211 302] /Resources << >> /Annots [5 0 R 6 0 R 9 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [7 2.000036 207 302] /Resources << >> >>",
            "<< /Type /Annot /Subtype /Link /Rect [21 40 51 50] /Dest [4 0 R /XYZ 64 102 1.5] >>",
            "<< /Type /Annot /Subtype /Link /Rect [31 60 71 72] /Dest [4 0 R /FitH 162] >>",
            "<< /Type /Outlines /Count 1 /First 8 0 R /Last 8 0 R >>",
            "<< /Title (Region) /Parent 7 0 R /Dest [4 0 R /FitR 17 22 107 202] >>",
            "<< /Type /Annot /Subtype /Link /Rect [41 80 61 90] /A << /S /URI /URI (file:///paper.tex#section) >> >>",
        ])
    }

    @Test("柱を付けて複製しても、リンクの領域とリンク・しおりの行先は用紙内の同じ位置に残る", arguments: [true, false])
    func offsetPageNavigation(preservesOutline: Bool) async throws {
        let source = try #require(PDFDocument(data: offsetPages()))
        var options = PrintOptions()
        options.furniture = .name
        let placement = try #require(
            PDFComposer.furniture(
                onPage: 0, at: 0, pageCount: 2, layout: .a4Single, options: options,
                context: .init(fileName: "Paper.tex")))
        let bytes = try await ReadingPDFExporter.data(
            from: source, entries: [.init(level: 1, title: "Section", pageIndex: 1)], title: "Paper",
            preservesOutline: preservesOutline, headings: [.init(level: 1, text: "Section", id: "section")],
            sourceURL: URL(fileURLWithPath: "/paper.tex"), furniture: [0: placement])
        let saved = try #require(PDFDocument(data: bytes))
        let first = try #require(saved.page(at: 0)).bounds(for: .mediaBox)
        let second = try #require(saved.page(at: 1)).bounds(for: .mediaBox)
        let raw = try await ReadingPDFRawNavigation.read(bytes)
        let rectangles = [
            CGRect(x: 10, y: 37.999964, width: 30, height: 10),
            CGRect(x: 20, y: 57.999964, width: 40, height: 12),
            CGRect(x: 30, y: 77.999964, width: 20, height: 10),
        ]
        try #require(raw.links.count == rectangles.count)
        for (link, rect) in zip(raw.links, rectangles) {
            #expect(link.page == 0)
            #expect(abs(link.bounds.minX - first.minX - rect.minX) < 0.01)
            #expect(abs(link.bounds.minY - first.minY - rect.minY) < 0.01)
            #expect(abs(link.bounds.width - rect.width) < 0.01)
            #expect(abs(link.bounds.height - rect.height) < 0.01)
        }
        let xyz = try #require(raw.links[0].action.target)
        try #require(xyz.mode == "XYZ" && xyz.page == 1)
        #expect(abs(try #require(xyz.arguments[0]) - second.minX - 57) < 0.01)
        #expect(abs(try #require(xyz.arguments[1]) - second.minY - 99.999964) < 0.01)
        #expect(xyz.arguments[2] == 1.5)
        let fit = try #require(raw.links[1].action.target)
        try #require(fit.mode == "FitH" && fit.page == 1)
        #expect(abs(try #require(fit.arguments[0]) - second.minY - 159.999964) < 0.01)

        try #require(raw.outline.count == 1)
        let bookmark = try #require(raw.outline[0].action.target)
        #expect(bookmark.page == 1)
        if preservesOutline {
            #expect(raw.links[2].action == .other)
            try #require(bookmark.mode == "FitR")
            #expect(abs(try #require(bookmark.arguments[0]) - second.minX - 10) < 0.01)
            #expect(abs(try #require(bookmark.arguments[1]) - second.minY - 19.999964) < 0.01)
            #expect(abs(try #require(bookmark.arguments[2]) - second.minX - 100) < 0.01)
            #expect(abs(try #require(bookmark.arguments[3]) - second.minY - 199.999964) < 0.01)
        } else {
            #expect(raw.links[2].action.target == bookmark)
            try #require(bookmark.mode == "XYZ")
            #expect(abs(try #require(bookmark.arguments[0]) - second.minX) < 0.01)
            #expect(abs(try #require(bookmark.arguments[1]) - second.maxY) < 0.01)
        }
    }

    @Test("原点が変わる保存と変わらない保存のどちらでも、各表示方法の座標だけを移す")
    func destinationOperands() async throws {
        // Supply both layouts explicitly so coverage does not depend on the host PDFKit's choice of origin.
        for (before, after) in [
            ("XYZ null 80 1.5", "XYZ null 67 1.5"), ("XYZ 40 null 1.5", "XYZ 33 null 1.5"),
            ("FitH 80", "FitH 67"), ("FitBH 80", "FitBH 67"), ("FitV 40", "FitV 33"), ("FitBV 40", "FitBV 33"),
            ("FitH null", "FitH null"), ("FitR 17 23 107 203", "FitR 10 10 100 190"), ("Fit", "Fit"), ("FitB", "FitB"),
        ] {
            func link(_ operands: String) -> String { "/Dest [3 0 R /" + operands + "]" }
            let original = file(link: link(before), mediaBox: "7 13 207 313", rect: "17 23 27 33")
            let captured = try await ReadingPDFNavigation(#require(PDFDocument(data: original)))
            let unchanged = try await captured.verified(original, pageCount: 1, stage: "original")
            let shifted = file(link: link(before))
            let repaired = try await captured.verified(shifted, pageCount: 1, stage: "shifted")
            let expected = try await ReadingPDFRawNavigation.read(file(link: link(after)))
            let raw = try await ReadingPDFRawNavigation.read(repaired)
            #expect(raw.links[0].action == expected.links[0].action, "\(before)")
            let reread = try await ReadingPDFRawNavigation.read(unchanged)
            let input = try await ReadingPDFRawNavigation.read(original)
            #expect(reread.links[0].action == input.links[0].action, "\(before)")
        }
    }

    @Test("保存後に内部リンクの領域が移動するか注釈自体が消えたら書き出しを断る", arguments: [true, false])
    func damagedLinkIdentity(removed: Bool) async throws {
        let rect = "17 23 27 33"
        let source = try #require(PDFDocument(data: file(mediaBox: "7 13 207 313", rect: rect)))
        let expected = try await ReadingPDFNavigation(source)
        // Keeping the original absolute rectangle moves the link on the rebased page.
        let saved = file(rect: removed ? nil : rect)
        do {
            _ = try await expected.verified(saved, pageCount: 1, stage: "export")
            Issue.record("壊れた内部リンクが保存された")
        } catch ReadingPDFExporter.ExportError.navigation(let detail) {
            #expect(detail.contains(removed ? "missing link annotation" : "link identity differs"))
        }
    }

    @Test("解決できない内部リンクやしおりがあれば、宛先を持たない親項目として保存しない")
    func unresolvedTargets() async throws {
        for damaged in [
            file(link: "/A << /S /GoTo /D (missing) >>"),
            file(bookmark: "/Dest [null /Fit]"),
            file(bookmark: "/A << /S /GoTo >>"),
            file(link: "/Dest [3 0 R /Unknown 2]"),
            file(link: "/A << /S /GoTo /D [3 0 R /XYZ 0 100] >>"),
        ] {
            let document = try #require(PDFDocument(data: damaged))
            await #expect(throws: ReadingPDFExporter.ExportError.self) {
                _ = try await ReadingPDFExporter.data(from: document)
            }
        }
    }

    @Test("しおりやリンクの表示方法と引数を直し、nullと矩形座標を原文のまま保つ")
    func exactDestinations() async throws {
        let original = file()
        let expected = try #require(PDFDocument(data: original))
        let snapshot = try await ReadingPDFNavigation(expected)
        let readable = file(link: "/Dest [3 0 R /FitH null]", bookmark: "/Dest [3 0 R /FitR 21 32 104 205]")
        let clean = try await snapshot.verified(readable, pageCount: 1, stage: "clean")
        #expect(clean == readable)
        let damaged = file(
            link: "/Dest [3 0 R /FitV null]", bookmark: "/Dest [3 0 R /FitR 22 32 104 205]")
        let fixed = try await snapshot.verified(damaged, pageCount: 1, stage: "damaged")
        #expect(fixed.count > damaged.count)
        let provider = try #require(CGDataProvider(data: fixed as CFData))
        let document = try #require(CGPDFDocument(provider))
        defer { withExtendedLifetime(document) {} }
        let page = try #require(document.page(at: 1)?.dictionary)
        var annotations: CGPDFArrayRef?
        try #require(CGPDFDictionaryGetArray(page, "Annots", &annotations))
        var link: CGPDFDictionaryRef?
        try #require(CGPDFArrayGetDictionary(annotations!, 0, &link))
        var destination: CGPDFArrayRef?
        try #require(CGPDFDictionaryGetArray(link!, "Dest", &destination))
        var mode: UnsafePointer<CChar>?
        try #require(CGPDFArrayGetName(destination!, 1, &mode))
        #expect(String(cString: mode!) == "FitH")
        var argument: CGPDFObjectRef?
        try #require(CGPDFArrayGetObject(destination!, 2, &argument))
        #expect(CGPDFObjectGetType(argument!) == .null)

        var node = try #require(document.catalog)
        for key in ["Outlines", "First", "First", "First"] { node = try dictionary(node, key) }
        try #require(CGPDFDictionaryGetArray(node, "Dest", &destination))
        try #require(CGPDFArrayGetName(destination!, 1, &mode))
        #expect(String(cString: mode!) == "FitR")
        let arguments = try (2..<6).map { index in
            var n: CGPDFReal = 0
            try #require(CGPDFArrayGetNumber(destination!, index, &n))
            return n
        }
        #expect(arguments == [21, 32, 104, 205])
    }

    @Test("辞書の表示指定が一致していても、読み手が追えなくなったリンクとしおりを修復する", arguments: [false, true])
    func readerReadback(namedSource: Bool) async throws {
        let explicit = "/Dest [3 0 R /FitH null]"
        // The legacy name has the same FitH and null as the explicit destination. Quartz
        // resolves it even on systems where PDFKit reports a destination without a page.
        let named = file(link: "/Dest /left", bookmark: "/Dest /left")
        let view = try #require(PDFDocument(data: namedSource ? named : file(link: explicit, bookmark: explicit)))
        let expected = try await ReadingPDFNavigation(view)
        func pages(in document: PDFDocument) -> [Int?] {
            let annotation = document.page(at: 0)?.annotations.first
            let leaf = document.outlineRoot?.child(at: 0)?.child(at: 0)?.child(at: 0)
            return [
                (annotation?.action as? PDFActionGoTo)?.destination ?? annotation?.destination,
                leaf?.destination ?? (leaf?.action as? PDFActionGoTo)?.destination,
            ].map { dest in dest?.page.map { document.index(for: $0) } }
        }
        if !namedSource { try #require(pages(in: view) == [0, 0], "view: link, bookmark") }
        let target = ReadingPDFNavigationWriter.Destination(page: 0, mode: "FitH", arguments: [nil])
        #expect(expected.links.first?.action.target == target, "view: link")
        #expect(expected.outline.first { $0.title == "Leaf" }?.action.target == target, "view: bookmark")
        let saved = try #require(PDFDocument(data: named))
        let before = pages(in: saved)
        let bytes = try await expected.verified(named, pageCount: 1, stage: "saved")
        let reopened = try #require(PDFDocument(data: bytes))
        #expect(
            pages(in: reopened) == [0, 0], "view=\(pages(in: view)) saved=\(before) repaired=\(pages(in: reopened))")
        if before == [0, 0] {
            #expect(bytes == named)
        } else {
            let raw = try await ReadingPDFRawNavigation.read(bytes)
            if before[0] == nil { #expect(raw.links.first?.action == .internalDestination(target), "repaired: link") }
            if before[1] == nil {
                #expect(
                    raw.outline.first { $0.title == "Leaf" }?.action == .internalDestination(target),
                    "repaired: bookmark")
            }
        }
    }

    @Test("明示的な宛先に修復しても読み手がページを返さなければ書き出しを断る", arguments: [false, true])
    func unreadableAfterRepair(bookmark: Bool) async throws {
        let named = file(link: "/Dest /left", bookmark: "/Dest /left")
        let view = try #require(PDFDocument(data: named))
        let expected = try await ReadingPDFNavigation(view)
        let explicit = "/Dest [3 0 R /FitH null]"
        // Model a reader that loses just one destination on both opens. Quartz still reads
        // the actual saved and incrementally repaired bytes, including their destination operands.
        let unreadable = file(link: bookmark ? explicit : "", bookmark: bookmark ? "" : explicit)
        let item = bookmark ? "bookmark=3" : "p1 annotation=0"
        do {
            _ = try await expected.verified(named, pageCount: 1, stage: "export") { _ in
                PDFDocument(data: unreadable)
            }
            Issue.record("repaired \(item): accepted a destination without a readable page")
        } catch ReadingPDFExporter.ExportError.navigation(let detail) {
            #expect(detail.contains("saved \(item)"), "\(detail)")
            #expect(detail.contains("repaired \(item)"), "\(detail)")
        }
    }

    @Test("元の XYZ 辞書でページだけが欠けても、表示中の有効な行先を保存する")
    func liveDestinationWithMissingBackingPage() async throws {
        let source = try #require(PDFDocument(data: file(link: "/Dest [null /XYZ 20 40 null]")))
        let page = try #require(source.page(at: 0))
        let link = try #require(page.annotations.first)
        link.action = PDFActionGoTo(destination: source.destination(on: page, at: CGPoint(x: 35, y: 82)))
        let bytes = try await ReadingPDFExporter.data(from: source)
        let saved = try #require(PDFDocument(data: bytes))
        let annotation = try #require(saved.page(at: 0)?.annotations.first)
        let target = try #require((annotation.action as? PDFActionGoTo)?.destination ?? annotation.destination)
        #expect(
            target.page === saved.page(at: 0) && target.point == CGPoint(x: 35, y: 82),
            "saved: expected p1@(35,82), got \(target)")
    }

    @Test("元の PDF にあるリンクを表示中に移したら、新しい座標を保存する")
    func editedLink() async throws {
        let original = file(link: "/Dest [3 0 R /XYZ 20 40 null]")
        let document = try #require(PDFDocument(data: original))
        let page = try #require(document.page(at: 0))
        let annotation = try #require(page.annotations.first)
        let point = CGPoint(x: 58.51234567, y: 99.955640125)
        annotation.action = PDFActionGoTo(destination: document.destination(on: page, at: point))
        let exported = try await ReadingPDFExporter.data(
            from: document, entries: [], title: "Test", preservesOutline: true)
        let raw = try await ReadingPDFRawNavigation.read(exported)
        guard case .internalDestination(let destination) = raw.links.first?.action else {
            Issue.record("内部リンクの宛先がない")
            return
        }
        #expect(destination.mode == "XYZ")
        #expect(abs(try #require(destination.arguments[0]) - point.x) < 0.0001)
        #expect(abs(try #require(destination.arguments[1]) - point.y) < 0.0001)
    }

    private func dictionary(_ parent: CGPDFDictionaryRef, _ key: String) throws -> CGPDFDictionaryRef {
        var child: CGPDFDictionaryRef?
        try #require(CGPDFDictionaryGetDictionary(parent, key, &child))
        return try #require(child)
    }

    @Test("閉じた枝を復元して、ルートと枝の件数に見えている子孫だけを数える")
    func collapsedBranches() async throws {
        let expected = try #require(PDFDocument(data: file()))
        let open = file(open: true)
        let fixed = try await ReadingPDFNavigation(expected).verified(
            open, pageCount: 1, stage: "opened"
        )
        let provider = try #require(CGDataProvider(data: fixed as CFData))
        let document = try #require(CGPDFDocument(provider))
        defer { withExtendedLifetime(document) {} }
        var node = try #require(document.catalog)
        for (key, count) in [("Outlines", 1), ("First", -3), ("First", 1)] {
            node = try dictionary(node, key)
            var stored = 0
            try #require(CGPDFDictionaryGetInteger(node, "Count", &stored))
            #expect(stored == count)
        }
    }
}
