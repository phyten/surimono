import Foundation
import SurimonoCore
import Testing

struct PrinterProfileTests {
    @Test("読めない綴じ方や値だけを捨ててほかのプリンター設定を残す")
    func tolerantDecoding() throws {
        let data = Data(
            #"{"rotatesBackSides":{"longEdge":true,"shortEdge":"bad","future":true},"pageOrder":"future"}"#.utf8)
        let profile = try JSONDecoder().decode(PrinterProfile.self, from: data)
        #expect(profile.rotation(for: .longEdge, default: false))
        #expect(!profile.rotation(for: .shortEdge, default: false))
        #expect(profile.resolvedPageOrder(default: .firstSheetFirst) == .firstSheetFirst)
        #expect(
            try JSONDecoder().decode(PrinterProfile.self, from: Data(#"{"rotatesBackSides":42}"#.utf8))
                == PrinterProfile())
    }

    @Test("綴じ方ごとの値を優先し未設定なら既定値を使い片面は回転しない")
    func defaults() {
        let profile = PrinterProfile(rotatesBackSides: [.shortEdge: false], pageOrder: .firstSheetFirst)
        #expect(profile.rotation(for: .longEdge, default: true))
        #expect(!profile.rotation(for: .shortEdge, default: true))
        #expect(!profile.rotation(for: .none, default: true))
        #expect(profile.resolvedPageOrder(default: .lastSheetFirst) == .firstSheetFirst)
    }

    @Test("手で変えた綴じ方だけを更新してJSONへ保存する")
    func updating() throws {
        var profile = PrinterProfile(rotatesBackSides: [.longEdge: false], pageOrder: .firstSheetFirst)
        profile.setRotation(true, for: .shortEdge)
        profile.setRotation(true, for: .none)
        #expect(profile.rotatesBackSides == [.longEdge: false, .shortEdge: true])
        #expect(try JSONDecoder().decode(PrinterProfile.self, from: JSONEncoder().encode(profile)) == profile)
    }

    @Test("古い文書の回転だけを無視し新しい文書のJSONには回転を書かない")
    func documentMigration() throws {
        let old = Data(
            #"{"printOptions":{"marginsInMillimeters":12,"showsPageNumbers":true,"rotatesBackSides":true}}"#.utf8)
        let decoded = try JSONDecoder().decode(DocumentSettings.self, from: old)
        #expect(decoded.printOptions == PrintOptions(marginsInMillimeters: 12, showsPageNumbers: true))
        var settings = decoded
        settings.printOptions?.rotatesBackSides = true
        let json = try JSONEncoder().encode(settings)
        #expect(!String(decoding: json, as: UTF8.self).contains("rotatesBackSides"))
        #expect(try JSONDecoder().decode(DocumentSettings.self, from: json) == decoded)
    }
}
