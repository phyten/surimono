import Foundation
import Testing

@testable import SurimonoCore

struct PrintSettingSetArchiveTests {
    private let set = PrintSettingSet(name: "余白", settings: DocumentSettings(themeID: "missing", presetID: "custom"))

    @Test("書き出した設定セットは未登録のスタイルとプリセットを含めて元に戻る")
    func roundTrip() throws {
        let data = try PrintSettingSetArchive.encode([set])
        #expect(try PrintSettingSetArchive.decode(data) == [set])
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["surimono"] as? Int == 1)
    }

    @Test("配列の設定セットも読め、未知のキーは読み飛ばす")
    func bareArray() throws {
        let json = #"[{"id":"\#(set.id)","name":"余白","themeID":"missing","presetID":"custom","extra":true}]"#
        #expect(try PrintSettingSetArchive.decode(Data(json.utf8)) == [set])
    }

    @Test("名前と内容が同じなら識別子が違っても追加しない")
    func identical() {
        var copy = set
        copy.id = UUID()
        let result = PrintSettingSetArchive.merge([copy], into: [set])
        #expect(result.additions.isEmpty && result.alreadyHere == ["余白"])
    }

    @Test("名前が衝突したら空いた番号で追加し、同じ読み込みを繰り返しても増えない")
    func collision() {
        var other = set
        other.textScale = 1.5
        var second = set
        second.name = "余白 2"
        let result = PrintSettingSetArchive.merge([other, other], into: [set, second])
        #expect(result.additions.map(\.name) == ["余白 3"])
        #expect(result.additions.first?.id != set.id)
        #expect(result.additions.first?.textScale == 1.5)
        #expect(result.alreadyHere == ["余白 3"])
    }

    @Test("読めないファイルや壊れたセットがあれば全体を断る")
    func invalid() {
        for json in ["bad", #"{"sets":[]}"#, #"[{"name":"A"}]"#] {
            #expect(throws: PrintSettingSetArchive.FileError.invalid) {
                try PrintSettingSetArchive.decode(Data(json.utf8))
            }
        }
    }

    @Test("新しい版は中の形式を解釈する前に断る")
    func future() {
        #expect(throws: PrintSettingSetArchive.FileError.unsupportedVersion) {
            try PrintSettingSetArchive.decode(Data(#"{"surimono":2,"sets":{}}"#.utf8))
        }
    }
}
