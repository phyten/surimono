import Foundation
import SurimonoCore
import Testing

struct ContentHashTests {
    @Test("abcの内容は既知のSHA256になる")
    func abc() {
        #expect(
            ContentHash.of(Data("abc".utf8)).hex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("空の内容は既知のSHA256になる")
    func emptyData() {
        #expect(ContentHash.of(Data()).hex == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test("分割読み込みが必要なファイルも内容全体と同じハッシュになる")
    func chunkedFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Data((0..<(256 * 8193)).map { UInt8($0 % 256) })
        try data.write(to: url)

        let hash = try ContentHash.ofFile(at: url)
        #expect(hash.hex == "ad4707187ce2c9c3d16909bd20eb1c440fa9d2717bff5b836db2d32f997da4d2")
        #expect(hash == ContentHash.of(data))
    }

    @Test("存在しないファイルのハッシュ取得はエラーになる")
    func missingFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(throws: (any Error).self) { try ContentHash.ofFile(at: url) }
    }

    @Test("画像集合のキーは選択順によらず固定の形式で計算する")
    func imageSetOrder() {
        let a = ContentHash.of(Data("a".utf8))
        let b = ContentHash.of(Data("b".utf8))
        let c = ContentHash.of(Data("c".utf8))
        for hashes in [[a, b, c], [a, c, b], [b, a, c], [b, c, a], [c, a, b], [c, b, a]] {
            #expect(
                ContentHash.imageSet(hashes).hex == "e008d0f21f01a3789c84db45d472eb56d310a5c81c67ef056f8f5a5ae8e0f7d3")
        }
    }

    @Test("画像集合では同じ画像の重複も個数に含める")
    func imageSetDuplicates() {
        let a = ContentHash.of(Data("a".utf8))
        let b = ContentHash.of(Data("b".utf8))
        #expect(ContentHash.imageSet([a, a, b]) != ContentHash.imageSet([a, b]))
        #expect(
            ContentHash.imageSet([a, a, b]).hex == "c2022afcb9639536fcee36e940b20ce4ddf8949a655bd25cf536e22eba76acc7")
    }

    @Test("画像を差し替えると画像集合のキーが変わる")
    func imageSetReplacement() {
        let a = ContentHash.of(Data("a".utf8))
        let b = ContentHash.of(Data("b".utf8))
        let c = ContentHash.of(Data("c".utf8))
        #expect(ContentHash.imageSet([a, b]) != ContentHash.imageSet([a, c]))
    }

    @Test("画像を追加または削除すると画像集合のキーが変わる")
    func imageSetMembership() {
        let a = ContentHash.of(Data("a".utf8))
        let b = ContentHash.of(Data("b".utf8))
        #expect(ContentHash.imageSet([a]) != ContentHash.imageSet([a, b]))
    }

    @Test("空の画像集合は固定のキーになる")
    func emptyImageSet() {
        #expect(ContentHash.imageSet([]).hex == "16aa38b708619025a1dcd50ff8ab6b8ec20a3e6012c911a9a0cc16352ad9c4c8")
    }

    @Test("大文字の16進数は小文字に正規化する")
    func uppercaseHex() throws {
        let hash = try #require(ContentHash(hex: "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"))
        #expect(hash.hex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("64文字以外または16進数以外の文字列は受け付けない")
    func invalidHex() {
        for hex in [
            "", String(repeating: "a", count: 63), String(repeating: "a", count: 65),
            String(repeating: "g", count: 64), String(repeating: "１", count: 64),
            " " + String(repeating: "a", count: 63),
        ] {
            #expect(ContentHash(hex: hex) == nil)
        }
    }

    @Test("JSONでは単一の16進文字列として往復できる")
    func codableRoundTrip() throws {
        let hash = ContentHash.of(Data("abc".utf8))
        let encoded = try JSONEncoder().encode(hash)
        #expect(
            String(decoding: encoded, as: UTF8.self)
                == "\"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\"")
        #expect(try JSONDecoder().decode(ContentHash.self, from: encoded) == hash)
    }

    @Test("JSONの不正なハッシュ文字列は復号時に拒否する")
    func invalidJSON() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ContentHash.self, from: Data("\"invalid\"".utf8))
        }
    }

    @Test("短縮表示は先頭6文字で通常の表示は全64文字になる")
    func display() {
        let hash = ContentHash.of(Data("abc".utf8))
        #expect(hash.abbreviated == "ba7816")
        #expect(hash.description == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("ハッシュは生バイトの昇順に比較できる")
    func comparison() throws {
        let low = try #require(ContentHash(hex: "09ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"))
        let high = try #require(ContentHash(hex: "0a00000000000000000000000000000000000000000000000000000000000000"))
        #expect(low < high)
        #expect(!(high < low))
        #expect(!(low < low))
    }

    @Test("同じ内容のハッシュは集合で同一のキーとして扱える")
    func hashable() throws {
        let hash = ContentHash.of(Data("abc".utf8))
        let uppercase = try #require(
            ContentHash(hex: "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"))
        #expect(Set([hash, uppercase]).count == 1)
    }
}
