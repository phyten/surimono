import Foundation
import Testing

@testable import SurimonoCore

struct CriticMarkupTests {
    @Test("古い保存内容は記号表示になり既定のキーを増やさない")
    func persistence() throws {
        let finish = try JSONDecoder().decode(PrintFinish.self, from: Data("{}".utf8))
        #expect(finish.proof == .shown)
        #expect(!String(decoding: try JSONEncoder().encode(finish), as: UTF8.self).contains("proof"))
        var accepted = finish
        accepted.proof = .accepted
        #expect(try JSONDecoder().decode(PrintFinish.self, from: JSONEncoder().encode(accepted)).proof == .accepted)
    }
}
