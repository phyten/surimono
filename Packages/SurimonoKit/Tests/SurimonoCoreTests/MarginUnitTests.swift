import Foundation
import SurimonoCore
import Testing

struct MarginUnitTests {
    @Test("インチを使う地域ではインチ、それ以外ではミリで余白を見せる")
    func unitFollowsRegion() {
        #expect(MarginUnit.preferred(for: Locale(identifier: "en_US")) == .inches)
        #expect(MarginUnit.preferred(for: Locale(identifier: "ja_JP")) == .millimeters)
        #expect(MarginUnit.preferred(for: Locale(identifier: "en_GB")) == .millimeters)
        #expect(MarginUnit.preferred(for: Locale(identifier: "de_DE")) == .millimeters)
    }

    @Test("ミリでは打った値を 0.1mm に丸めて 0〜40mm に収める")
    func millimetersKeepTenths() {
        let unit = MarginUnit.millimeters
        #expect(unit.millimeters(from: 12.5) == 12.5)
        #expect(unit.millimeters(from: 12.34) == 12.3)
        #expect(unit.millimeters(from: 12.36) == 12.4)
        #expect(unit.millimeters(from: 41) == 40)
        #expect(unit.millimeters(from: -3) == 0)
        #expect(unit.millimeters(from: .nan) == nil)
    }

    @Test("インチでは 0.01 インチに丸め、ミリにして保存する")
    func inchesConvertToMillimeters() {
        let unit = MarginUnit.inches
        #expect(unit.millimeters(from: 0.25) == 6.35)
        #expect(unit.millimeters(from: 1) == 25.4)
        #expect(unit.millimeters(from: 0.333) == 8.38)
        #expect(unit.millimeters(from: 2) == 40)
    }

    @Test("保存したミリをその単位の桁で見せる")
    func storedMillimetersShowInUnit() {
        #expect(MarginUnit.millimeters.value(fromMillimeters: 12.5) == 12.5)
        #expect(MarginUnit.millimeters.value(fromMillimeters: 15) == 15)
        #expect(MarginUnit.inches.value(fromMillimeters: 15) == 0.59)
        #expect(MarginUnit.inches.value(fromMillimeters: 6.35) == 0.25)
        #expect(MarginUnit.inches.value(fromMillimeters: 25.4) == 1)
    }

    @Test("欄が見せている値をそのまま確定しても、保存した余白を丸め直さない")
    func committingShownValueKeepsStoredMargin() {
        #expect(MarginUnit.inches.millimeters(from: 0.49, replacing: 12.5) == nil)
        #expect(MarginUnit.inches.millimeters(from: 0.5, replacing: 12.5) == 12.7)
        #expect(MarginUnit.millimeters.millimeters(from: 12.3, replacing: 12.34) == nil)
        #expect(MarginUnit.millimeters.millimeters(from: 12.5, replacing: nil) == 12.5)
    }

    @Test("矢印は保存したミリを、ミリで 0.5mm、インチで 1.27mm（0.05 インチ）ずつ動かす")
    func steps() {
        #expect(MarginUnit.millimeters.stepped(12.5, by: 1) == 13)
        #expect(MarginUnit.millimeters.stepped(12.5, by: -1) == 12)
        #expect(MarginUnit.inches.stepped(12.7, by: 1) == 13.97)
        #expect(MarginUnit.inches.stepped(12.7, by: -1) == 11.43)
    }

    @Test("矢印はどちらの単位でも 0mm と 40mm の両端に届く", arguments: MarginUnit.allCases)
    func stepsReachBothEnds(unit: MarginUnit) {
        var margin = 0.0
        for _ in 0..<100 { margin = unit.stepped(margin, by: 1) }
        #expect(margin == 40)
        for _ in 0..<100 { margin = unit.stepped(margin, by: -1) }
        #expect(margin == 0)
    }

    @Test("端から 1 つ下げて 1 つ上げると、保存した値に戻る")
    func stepsDoNotDrift() {
        #expect(MarginUnit.inches.stepped(MarginUnit.inches.stepped(40, by: -1), by: 1) == 40)
        #expect(MarginUnit.inches.stepped(40, by: -1) == 38.73)
        #expect(MarginUnit.millimeters.stepped(MarginUnit.millimeters.stepped(40, by: -1), by: 1) == 40)
        #expect(MarginUnit.inches.stepped(MarginUnit.inches.stepped(12.5, by: 1), by: -1) == 12.5)
        #expect(MarginUnit.millimeters.stepped(MarginUnit.millimeters.stepped(12.34, by: 1), by: -1) == 12.34)
    }

    @Test("余白のメニューは 6 つの決まった値をミリで持ち、今の値がどれでもなければ加える")
    func choices() {
        #expect(MarginUnit.millimeters.choices(including: 15) == [0, 5, 10, 15, 20, 25])
        #expect(MarginUnit.millimeters.choices(including: 12.5) == [0, 5, 10, 12.5, 15, 20, 25])
        #expect(MarginUnit.millimeters.choices(including: nil) == [0, 5, 10, 15, 20, 25])
        #expect(MarginUnit.inches.choices(including: 6.35) == [0, 6.35, 12.7, 19.05, 25.4])
        #expect(MarginUnit.inches.choices(including: 15) == [0, 6.35, 12.7, 15, 19.05, 25.4])
    }

    @Test("インチで 0.5 と同じに見える 12.6mm は、0.5 インチ（12.7mm）とは別の選択肢になる")
    func currentThatShowsLikeAPresetStaysApart() {
        let choices = MarginUnit.inches.choices(including: 12.6)
        #expect(choices == [0, 6.35, 12.6, 12.7, 19.05, 25.4])
        #expect(MarginUnit.inches.value(fromMillimeters: 12.6) == MarginUnit.inches.value(fromMillimeters: 12.7))
    }

    @Test("余白の数字は単位の桁までで、余計な 0 を付けない")
    func formatting() {
        let locale = Locale(identifier: "en_US")
        #expect(MarginUnit.millimeters.formatted(12.5, locale: locale) == "12.5")
        #expect(MarginUnit.millimeters.formatted(15, locale: locale) == "15")
        #expect(MarginUnit.inches.formatted(6.35, locale: locale) == "0.25")
        #expect(MarginUnit.inches.formatted(25.4, locale: locale) == "1")
        #expect(MarginUnit.millimeters.formatted(12.5, locale: Locale(identifier: "de_DE")) == "12,5")
    }

    @Test("保存した余白は範囲に収めるだけで、12.5mm や 6.35mm を丸めない")
    func clampingKeepsFractions() {
        #expect(PageMargins.clamped(12.5) == 12.5)
        #expect(PageMargins.clamped(6.35) == 6.35)
        #expect(PageMargins.clamped(45) == 40)
        #expect(PageMargins.clamped(-1) == 0)
        #expect(PageMargins.clamped(0.1 + 0.2) == 0.3)
    }
}
