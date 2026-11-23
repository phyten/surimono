import Foundation
import SurimonoCore
import Testing

@testable import Surimono

@MainActor
struct BandControlsTests {
    @Test("紙の帯は適用できる部品を幅に関係なく返す")
    func paperControls() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = BandTestDefaultsSuite()
        defer { suite.remove() }
        let model = DocumentViewModel(
            data: Data(), fileURL: nil, format: .markdown,
            preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: directory))
        model.isolateBandTestOutput()
        model.viewOptions.layout = .spread
        #expect(
            BandLayout.Item.applicable(for: model) == [
                .formatBadge, .style, .outline, .layout, .transition, .floatOnTop, .showOnAllSpaces, .print,
                .readingDirection, .scrollDirection, .paperOrientation, .paperSeries, .cover, .selectText,
                .alwaysShowToolbar, .margins, .printSettings, .viewOptions, .keysAndGestures,
            ])
        model.layoutID = PrintLayout.a4BookletA5.id
        model.choosePaperSeries(.letter)
        #expect(model.mode == .view)
        #expect(model.trayPaperSeries == .letter)
        #expect(model.layoutID == PrintLayout.letterBookletHalfLetter.id)
        model.viewOptions.layout = .single
        #expect(!BandLayout.Item.applicable(for: model).contains(.cover))
    }

    @Test("拡大率は拡大中だけ帯に現れ画像には文字選択を出さない")
    func imageControls() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = BandTestDefaultsSuite()
        defer { suite.remove() }
        let model = DocumentViewModel(
            data: Data(), fileURL: nil, format: .image,
            preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: directory))
        model.isolateBandTestOutput()
        #expect(!BandLayout.Item.applicable(for: model).contains(.zoom))
        #expect(!BandLayout.Item.applicable(for: model).contains(.style))
        #expect(!BandLayout.Item.applicable(for: model).contains(.selectText))
        model.zoom = 2
        #expect(BandLayout.Item.applicable(for: model).contains(.zoom))
    }
}
