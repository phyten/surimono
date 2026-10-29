import Foundation
import JavaScriptCore
import SurimonoCore
import Testing

struct SmartRemovalTests {
    @Test("生成したJavaScriptを構文解析でき本文がなければ空のJSONを返す")
    func executableScript() throws {
        let context = try #require(JSContext())
        context.evaluateScript("var document = { body: null };")
        let script = SmartRemovalScript.javaScript(
            for: SmartRemovalRequest(keptIDs: ["#\"</script>\\\n"], highlightsCandidates: true))
        let function = try #require(context.evaluateScript("(function() { \(script) })"))
        #expect(context.exception == nil)
        #expect(function.call(withArguments: [])?.toString() == "[]")
        #expect(context.exception == nil)
    }

    @Test("候補のJSONを往復して識別子と根拠を保持する")
    func candidatesRoundTrip() throws {
        let candidate = SmartRemovalCandidate(
            id: "#cookie", category: .cookieBanner, excerpt: "Cookie choices", reason: "position: fixed")
        let json = String(decoding: try JSONEncoder().encode([candidate]), as: UTF8.self)
        #expect(SmartRemovalScript.candidates(fromJSON: json) == [candidate])
    }

    @Test("不正な候補JSONは空の一覧として扱う", arguments: ["", "null", "{}", "[{}]", "not JSON"])
    func invalidJSON(_ json: String) {
        #expect(SmartRemovalScript.candidates(fromJSON: json) == [])
    }

    @Test("未知の分類を含む候補JSONは安全に無視する")
    func unknownCategory() {
        let json = ##"[{"id":"#x","category":"unknown","excerpt":"text","reason":"test"}]"##
        #expect(SmartRemovalScript.candidates(fromJSON: json) == [])
    }

    @Test("残す識別子と確認モードをJSONで往復できる")
    func requestRoundTrip() throws {
        let request = SmartRemovalRequest(keptIDs: ["#newsletter"], highlightsCandidates: true)
        #expect(try JSONDecoder().decode(SmartRemovalRequest.self, from: JSONEncoder().encode(request)) == request)
        #expect(Set([request, request]).count == 1)
        #expect(SmartRemovalRequest().keptIDs == [])
        #expect(!SmartRemovalRequest().highlightsCandidates)
    }

    @Test("引用符やスクリプト終端を含む識別子を安全なJSONリテラルで埋め込む")
    func safeRequestEmbedding() throws {
        let request = SmartRemovalRequest(keptIDs: ["#a\"\\\n</script>\u{2028}\u{2029}"], highlightsCandidates: true)
        let script = SmartRemovalScript.javaScript(for: request)
        let firstLine = try #require(script.split(separator: "\n").first)
        let prefix = "const request = "
        #expect(firstLine.hasPrefix(prefix))
        let json = firstLine.dropFirst(prefix.count).dropLast()
        #expect(try JSONDecoder().decode(SmartRemovalRequest.self, from: Data(json.utf8)) == request)
        #expect(!script.contains("</script>"))
        #expect(!script.contains("\u{2028}"))
        #expect(!script.contains("\u{2029}"))
        #expect(script == SmartRemovalScript.javaScript(for: request))
    }
}
