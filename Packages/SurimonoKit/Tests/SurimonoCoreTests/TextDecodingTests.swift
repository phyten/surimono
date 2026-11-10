import CoreFoundation
import Foundation
import SurimonoCore
import Testing

struct TextDecodingTests {
    @Test("短い西欧語を日本語と取り違えずWindows1252から復元する", arguments: ["Señor Muñoz", "élève château"])
    func shortWesternEuropean(source: String) throws {
        let data = try #require(source.data(using: .windowsCP1252))
        #expect(TextDecoding.decode(data).text == source)
    }

    @Test(
        "英語のアポストロフィと引用符をWindows1252から復元する",
        arguments: [
            "It’s a wonderful day.", "Don’t forget to print.", "She said “no”, twice.",
            "The printers’ guide – “Paper, ink…” – isn’t long.", "‘Single’ quotes, and we’ve seen them.",
        ])
    func curlyPunctuation(source: String) throws {
        let data = try #require(source.data(using: .windowsCP1252))
        #expect(TextDecoding.decode(data).text == source)
    }

    @Test("かなのない短い韓国語をEUC-KRから復元する", arguments: ["안녕하세요", "한국어 문서입니다"])
    func shortKorean(source: String) throws {
        let encoding = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.EUC_KR.rawValue)))
        let data = try #require(source.data(using: encoding))
        #expect(TextDecoding.decode(data).text == source)
    }

    @Test(
        "ひらがなと全角カタカナのない短い日本語は日本語の文字コードとして復元する",
        arguments: [
            ("東京", String.Encoding.shiftJIS), ("東京", .japaneseEUC), ("日本語", .japaneseEUC), ("100円", .shiftJIS),
            ("Windows版", .shiftJIS), ("ｶﾀｶﾅ", .shiftJIS), ("担当", .shiftJIS), ("Windows担当", .shiftJIS),
            ("WindowsServer担当", .shiftJIS),
            ("Photoshop値", .shiftJIS), ("Illustrator本体", .shiftJIS),
            ("Name: 堀", .shiftJIS), ("Direction: 北", .shiftJIS), ("Color: 墨", .shiftJIS), ("Name: 徹", .shiftJIS),
        ])
    func shortJapaneseWithoutKana(source: String, encoding: String.Encoding) throws {
        let data = try #require(source.data(using: encoding))
        let decoded = TextDecoding.decode(data)
        #expect(decoded.text == source)
        #expect(decoded.encoding == encoding)
    }

    @Test("漢字中心の氏名と住所のCSVをShift_JISとして復元する")
    func kanjiCSV() throws {
        let source = "氏名,住所\n山田太郎,東京都千代田区永田町\n鈴木一郎,大阪府大阪市北区梅田\n"
        let data = try #require(source.data(using: .shiftJIS))
        let decoded = TextDecoding.decode(data)
        #expect(decoded.text == "氏名,住所\n山田太郎,東京都千代田区永田町\n鈴木一郎,大阪府大阪市北区梅田\n")
        #expect(decoded.encoding == .shiftJIS)
    }

    @Test("西欧語のアクセントをWindows1252から復元する")
    func westernEuropean() throws {
        let source =
            "Les élèves lisent un livre sur la façade. François prépare une crème fraîche. Cette méthode semble très agréable."
        let data = try #require(source.data(using: .windowsCP1252))
        #expect(TextDecoding.decode(data).text == source)
    }

    @Test(
        "韓国語と繁体字と簡体字を元の文字コードから復元する",
        arguments: [
            ("오늘은 도서관에서 책을 읽습니다. 새로운 문서를 열고 내용을 확인합니다. 인쇄하기 전에 종이를 준비합니다.", CFStringEncodings.EUC_KR.rawValue),
            ("今天我們在圖書館閱讀書籍。請先開啟文件，確認內容之後再列印。這份資料包含繁體中文字。", CFStringEncodings.big5.rawValue),
            ("今天我们在图书馆阅读书籍。请先打开文件，确认内容之后再打印。这份资料包含简体中文。", CFStringEncodings.GB_18030_2000.rawValue),
        ])
    func otherAsianLanguages(source: String, cfEncoding: Int) throws {
        let encoding = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cfEncoding)))
        let data = try #require(source.data(using: encoding))
        #expect(TextDecoding.decode(data).text == source)
    }

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
        "短い日本語をShift_JISとEUC_JPから復元する", arguments: ["日本", "日本語", "東京", "東京大阪", "ひらがな", "カタカナ", "印刷用の文章"],
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
            ("ｶﾀｶﾅ", String.Encoding.japaneseEUC), ("ｱｲｳｴｵ ｶｷｸｹｺ", .japaneseEUC),
        ])
    func ambiguousHalfWidthKana(source: String, encoding: String.Encoding) throws {
        let data = try #require(source.data(using: encoding))
        let decoded = TextDecoding.decode(data)
        withKnownIssue("両方の文字コードで往復でき、現在の日本語スコアは半角カナより漢字を優先する") {
            #expect(decoded.text == source && decoded.encoding == encoding)
        }
    }
}
