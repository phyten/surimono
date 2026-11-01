import Foundation
import SurimonoCore
import Testing

@testable import Surimono

@MainActor
struct BandControlsTests {
    @Test("紙の帯はよく変える操作に絞りその他の7操作は幅に関係なくメニューに置く")
    func paperControls() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = DocumentViewModel(
            data: Data(), fileURL: nil, format: .markdown,
            preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: directory))
        model.viewOptions.layout = .spread
        #expect(
            BandLayout.Item.applicable(for: model, stage: .full) == [
                .formatBadge, .style, .layout, .transition, .print,
            ])
        #expect(
            SecondaryViewControl.applicable(for: model) == [
                .direction, .scrollAxis, .paperOrientation, .cover, .selectText, .floatOnTop, .keepMenuVisible,
            ])
        model.viewOptions.layout = .single
        #expect(
            SecondaryViewControl.applicable(for: model) == [
                .direction, .scrollAxis, .paperOrientation, .selectText, .floatOnTop, .keepMenuVisible,
            ])
        #expect(BandLayout.Item.applicable(for: model, stage: .compact) == [.print])
    }

    @Test("拡大率は拡大中だけ帯に現れ画像には文字選択を出さない")
    func imageControls() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = DocumentViewModel(
            data: Data(), fileURL: nil, format: .image,
            preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: directory))
        #expect(!BandLayout.Item.applicable(for: model, stage: .full).contains(.zoom))
        #expect(!BandLayout.Item.applicable(for: model, stage: .full).contains(.style))
        #expect(!SecondaryViewControl.applicable(for: model).contains(.selectText))
        model.zoom = 2
        #expect(BandLayout.Item.applicable(for: model, stage: .full).contains(.zoom))
    }
}
