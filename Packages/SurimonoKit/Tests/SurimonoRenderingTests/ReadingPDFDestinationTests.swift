import PDFKit
import Testing

@testable import SurimonoRendering

@MainActor
struct ReadingPDFDestinationTests {
    // Use independent PDF objects: PDFKit cannot author FitR and can lose a GoTo on write.
    private func file(
        link: String = "/Dest /left", bookmark: String = "/Dest (region)", open: Bool = false
    ) -> Data {
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /Outlines 5 0 R /Dests << /left [3 0 R /FitH null] >> /Names << /Dests << /Kids [10 0 R] >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 300] /Resources << >> /Annots [4 0 R] >>",
            "<< /Type /Annot /Subtype /Link /Rect [10 10 20 20] \(link) >>",
            "<< /Type /Outlines /First 6 0 R /Last 6 0 R /Count \(open ? 4 : 1) >>",
            "<< /Title (Parent) /Parent 5 0 R /First 7 0 R /Last 8 0 R /Count \(open ? 3 : -3) >>",
            "<< /Title (Branch) /Parent 6 0 R /Next 8 0 R /First 9 0 R /Last 9 0 R /Count 1 >>",
            "<< /Title (Tail) /Parent 6 0 R /Prev 7 0 R /Dest [3 0 R /Fit] >>",
            "<< /Title (Leaf) /Parent 7 0 R \(bookmark) >>",
            "<< /Limits [(region) (region)] /Names [(region) << /D [3 0 R /FitR 21 32 104 205] >>] >>",
        ]
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

    @Test("解決できない内部リンクやしおりがあれば、宛先を持たない親項目として保存しない")
    func unresolvedTargets() async throws {
        for damaged in [
            file(link: "/A << /S /GoTo /D (missing) >>"),
            file(bookmark: "/Dest [null /Fit]"),
            file(bookmark: "/A << /S /GoTo >>"),
            file(link: "/Dest [3 0 R /Unknown 2]"),
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
        let clean = try await snapshot.verified(original, pageCount: 1, stage: "clean")
        #expect(clean == original)
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

    @Test("辞書の表示指定が一致していても、読み手が追えなくなったリンクとしおりを修復する")
    func readerReadback() async throws {
        let explicit = "/Dest [3 0 R /FitH null]"
        let view = try #require(PDFDocument(data: file(link: explicit, bookmark: explicit)))
        let expected = try await ReadingPDFNavigation(view)
        // The legacy name has the same FitH and null as the explicit destination. Quartz
        // resolves it even on systems where PDFKit reports a destination without a page.
        let named = file(link: "/Dest /left", bookmark: "/Dest /left")
        func pages(in document: PDFDocument) -> [Int?] {
            let annotation = document.page(at: 0)?.annotations.first
            let leaf = document.outlineRoot?.child(at: 0)?.child(at: 0)?.child(at: 0)
            return [
                (annotation?.action as? PDFActionGoTo)?.destination ?? annotation?.destination,
                leaf?.destination ?? (leaf?.action as? PDFActionGoTo)?.destination,
            ].map { dest in dest?.page.map { document.index(for: $0) } }
        }
        try #require(pages(in: view) == [0, 0], "view: link, bookmark")
        let saved = try #require(PDFDocument(data: named))
        let before = pages(in: saved)
        let bytes = try await expected.verified(named, pageCount: 1, stage: "saved")
        let reopened = try #require(PDFDocument(data: bytes))
        #expect(pages(in: reopened) == [0, 0], "view=[0,0] saved=\(before) repaired=\(pages(in: reopened))")
        if before == [0, 0] { #expect(bytes == named) }
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
