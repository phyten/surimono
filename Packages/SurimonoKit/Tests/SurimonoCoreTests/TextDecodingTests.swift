import Foundation
import SurimonoCore
import Testing

struct TextDecodingTests {
    @Test(
        "日本語を各文字コードから復元する",
        arguments: [
            String.Encoding.utf8, .shiftJIS, .japaneseEUC, .iso2022JP,
        ])
    func japanese(encoding: String.Encoding) throws {
        let source = "日本語の文章です。漢字とひらがな、カタカナを印刷します。"
        let data = try #require(source.data(using: encoding))
        let decoded = TextDecoding.decode(data)
        #expect(decoded.text == source)
        #expect(decoded.encoding == encoding)
    }

    @Test(
        "BOMを優先して本文から除く",
        arguments: [
            (String.Encoding.utf8, [UInt8](arrayLiteral: 0xEF, 0xBB, 0xBF)),
            (.utf16LittleEndian, [0xFF, 0xFE]), (.utf16BigEndian, [0xFE, 0xFF]),
            (.utf32LittleEndian, [0xFF, 0xFE, 0, 0]), (.utf32BigEndian, [0, 0, 0xFE, 0xFF]),
        ])
    func bom(encoding: String.Encoding, prefix: [UInt8]) throws {
        let source = "日本語😀\r\n次\r末尾"
        let data = Data(prefix) + (try #require(source.data(using: encoding)))
        let decoded = TextDecoding.decode(data)
        #expect(decoded.text == "日本語😀\n次\n末尾")
        #expect(decoded.encoding == encoding)
    }

    @Test("ASCIIと空データをUTF8として読む", arguments: ["", "abc\t123", "one\r\ntwo\rthree"])
    func ascii(source: String) {
        let decoded = TextDecoding.decode(Data(source.utf8))
        #expect(decoded.encoding == .utf8)
        #expect(
            decoded.text
                == source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
    }

    @Test("壊れたUTF8のBOM付きデータでもクラッシュせず置換する")
    func malformed() {
        #expect(TextDecoding.decode(Data([0xEF, 0xBB, 0xBF, 0xFF])).text == "�")
    }

    @Test(
        "短い日本語をShift_JISとEUC_JPから復元する", arguments: ["日本", "日本語", "東京大阪", "ひらがな", "カタカナ", "印刷用の文章"],
        [String.Encoding.shiftJIS, .japaneseEUC])
    func shortJapanese(source: String, encoding: String.Encoding) throws {
        let data = try #require(source.data(using: encoding))
        let decoded = TextDecoding.decode(data)
        #expect(decoded.text == source)
        #expect(decoded.encoding == encoding)
    }

    @Test(
        "半角カナ中心の文をShift_JISとEUC_JPから復元する",
        arguments: [
            ("ﾌﾟﾘﾝﾄします", String.Encoding.shiftJIS), ("ﾌﾟﾘﾝﾄします", .japaneseEUC),
            ("ｱｲｳｴｵ ｶｷｸｹｺ", .shiftJIS),
        ])
    func halfWidthKana(source: String, encoding: String.Encoding) throws {
        let data = try #require(source.data(using: encoding))
        let decoded = TextDecoding.decode(data)
        #expect(decoded.text == source)
        #expect(decoded.encoding == encoding)
    }

    @Test(
        "ASCIIと日本語の混在文をShift_JISとEUC_JPから復元する", arguments: ["ABC 日本語 123", "A4で印刷 PDF 2 pages", "Hello 東京!"],
        [String.Encoding.shiftJIS, .japaneseEUC])
    func mixedJapanese(source: String, encoding: String.Encoding) throws {
        let data = try #require(source.data(using: encoding))
        let decoded = TextDecoding.decode(data)
        #expect(decoded.text == source)
        #expect(decoded.encoding == encoding)
    }

    @Test(
        "既知の制限として半角カナだけの一部の文は別の日本語文字コードへ誤判定する",
        arguments: [
            ("ｶﾀｶﾅ", String.Encoding.shiftJIS), ("ｶﾀｶﾅ", .japaneseEUC), ("ｱｲｳｴｵ ｶｷｸｹｺ", .japaneseEUC),
        ])
    func ambiguousHalfWidthKana(source: String, encoding: String.Encoding) throws {
        let data = try #require(source.data(using: encoding))
        let decoded = TextDecoding.decode(data)
        withKnownIssue("両方の文字コードで往復でき、現在の日本語スコアは半角カナより漢字を優先する") {
            #expect(decoded.text == source && decoded.encoding == encoding)
        }
    }
}
