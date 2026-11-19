import Testing

@testable import SurimonoFormats

struct LaTeXLabelMetricsTests {
    @Test("欧文三つの級数で節点の行送りを標準クラスの実測値に合わせる")
    func articleBaselines() {
        for (index, points) in [10, 11, 12].enumerated() {
            let metrics = LaTeXLabelMetrics(LaTeXDocumentClassInfo(name: "article", options: "\(points)pt"))
            #expect(metrics.baselines[4] == [12, 13.6, 14.5][index])
            #expect(metrics.baselines[3] == [11, 12, 13.6][index])
            #expect(metrics.baselines[2] == [9.5, 11, 12][index])
            #expect(metrics.japaneseScale == nil)
        }
    }

    @Test("和文クラスの全角幅と行送りを LuaLaTeX の箱に照合する")
    func japaneseBoxes() throws {
        for (index, points) in [10, 11, 12].enumerated() {
            let info = LaTeXDocumentClassInfo(name: "ltjsreport", options: "\(points)pt")
            let metrics = LaTeXLabelMetrics(info)
            let em = [10.0, 10.95, 12][index]
            let zw = try #require(metrics.japaneseScale) * em
            #expect(abs(zw - [9.24713, 10.12563, 11.09653][index]) < 0.0001)
            #expect(abs(metrics.baselines[4] - [16, 17.52002, 19.19995][index]) < 0.0001)
            #expect(abs(metrics.baselines[3] - [13, 14.23502, 15.59996][index]) < 0.0001)
            #expect(abs(metrics.baselines[2] - [11, 12.04501, 13.19997][index]) < 0.0001)
        }
        let classic = LaTeXLabelMetrics(LaTeXDocumentClassInfo(name: "ltjarticle"))
        #expect(classic.baselines[4] == 15)
        #expect(classic.japaneseScale == 0.962216)
    }
}
