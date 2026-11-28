import Foundation
import Testing

@testable import SurimonoRendering

/// The DOM and printed texts are given as already folded strings; no PDF is involved.
struct PrintedTextAlignmentTests {
    private func placements(_ dom: String, _ paper: String) throws -> [Int32] {
        try PrintedTextAlignment.placements(dom: Array(dom.utf16), paper: Array(paper.utf16))
    }

    /// The printed index where each occurrence of `word` in `dom` landed, nil where it is not placed.
    private func landing(of word: String, occurrence: Int, in dom: String, _ result: [Int32]) -> Int32? {
        var from = dom.startIndex
        var found: Range<String.Index>?
        for _ in 0...occurrence {
            found = dom.range(of: word, range: from..<dom.endIndex)
            guard let found else { return nil }
            from = found.upperBound
        }
        guard let found else { return nil }
        let offset = dom.utf16.distance(from: dom.startIndex, to: found.lowerBound)
        return result[offset] >= 0 ? result[offset] : nil
    }

    @Test("印字で 1 文字欠けた語の後も、続く本文の位置が決まる")
    func lostLetterIsTolerated() throws {
        let dom = "filler line zero filler line one filler line two"
        let paper = "filer line zero filer line one filer line two"
        let result = try placements(
            dom.replacingOccurrences(of: " ", with: ""), paper.replacingOccurrences(of: " ", with: ""))
        let folded = dom.replacingOccurrences(of: " ", with: "")
        #expect(landing(of: "linetwo", occurrence: 0, in: folded, result) != nil)
        #expect(result.filter { $0 >= 0 }.count * 10 >= folded.utf16.count * 7)
    }

    @Test("繰り返す語と読み順の入れ替わりでは、別の出現に対応づけずに位置を決めない")
    func repeatedTermIsNotPlacedOnAnotherOccurrence() throws {
        // DOM: a term list whose definitions are printed after all the terms (a grid of terms and definitions),
        // then a heading-like term repeated further on.
        let dom = "firstterm" + "firstdefinition" + "repeatedterm" + "bodytwo" + "repeatedterm" + "bodytwo"
        let paper = "firstterm" + "repeatedterm" + "firstdefinition" + "bodytwo" + "repeatedterm" + "bodytwo"
        let result = try placements(dom, paper)
        let firstRepeat = landing(of: "repeatedterm", occurrence: 0, in: dom, result)
        // Placed at most on its own printed occurrence (index 9), never on the later one (index 43).
        #expect(firstRepeat == nil || firstRepeat == 9)
    }
}
