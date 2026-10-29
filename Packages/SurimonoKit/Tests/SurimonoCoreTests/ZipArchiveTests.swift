import Compression
import Foundation
import SurimonoCore
import Testing

struct ZipArchiveTests {
    @Test("無圧縮とDEFLATEの内容をメモリ上で読み戻せる", arguments: [UInt16(0), UInt16(8)])
    func roundTrip(method: UInt16) throws {
        let content = Data(repeating: 0x61, count: 200_000)
        let archive = try ZipArchive(data: makeZip([Item("image.jpg", content: content, method: method)]))
        let entry = try #require(archive.entries.first)
        #expect(entry.path == "image.jpg")
        #expect(entry.uncompressedSize == 200_000)
        #expect(entry.method == method)
        #expect(try archive.contents(of: entry) == content)
    }

    @Test("空のファイルも読み戻せる", arguments: [UInt16(0), UInt16(8)])
    func emptyFile(method: UInt16) throws {
        let archive = try ZipArchive(data: makeZip([Item("empty.png", content: Data(), method: method)]))
        #expect(try archive.contents(of: archive.entries[0]) == Data())
    }

    @Test("画像を深いフォルダも含めてフォルダ優先の自然順に並べる")
    func imageOrder() throws {
        let archive = try ZipArchive(
            data: makeZip([
                Item("2日目/IMG_1.jpg"), Item("1日目/IMG_10.jpg"), Item("1日目/IMG_2.jpg"),
                Item("3日目/奥/さらに奥/IMG_1.PNG"),
            ]))
        #expect(
            ZipImageSelection(archive: archive).images.map(\.path) == [
                "1日目/IMG_2.jpg", "1日目/IMG_10.jpg", "2日目/IMG_1.jpg", "3日目/奥/さらに奥/IMG_1.PNG",
            ])
    }

    @Test("画像以外と隠しファイルを除外しディレクトリは除外件数に含めない")
    func exclusions() throws {
        let archive = try ZipArchive(
            data: makeZip([
                Item("メモ.txt"), Item(".DS_Store"), Item("__MACOSX/._image.jpg"),
                Item("hidden/.secret/image.png"), Item("folder/", content: Data()), Item("image.JPG"),
            ]))
        let selection = ZipImageSelection(archive: archive)
        #expect(selection.images.map(\.path) == ["image.JPG"])
        #expect(selection.excludedPaths == ["__MACOSX/._image.jpg", ".DS_Store", "hidden/.secret/image.png", "メモ.txt"])
    }

    @Test("フラグのないUTF8の日本語名を読む")
    func unflaggedUTF8() throws {
        let archive = try ZipArchive(data: makeZip([Item("日本語/画像.jpg", flags: 0)]))
        #expect(archive.entries[0].path == "日本語/画像.jpg")
    }

    @Test("ShiftJISの日本語名を読む")
    func shiftJIS() throws {
        var item = Item("unused", flags: 0)
        item.name = Data([0x89, 0xE6, 0x91, 0x9C, 0x2E, 0x6A, 0x70, 0x67])
        let archive = try ZipArchive(data: makeZip([item]))
        #expect(archive.entries[0].path == "画像.jpg")
    }

    @Test("UTF8とShiftJISで読めない名前はCP437で読む")
    func cp437() throws {
        var item = Item("unused", flags: 0)
        item.name = Data([0x82, 0x2E, 0x6A, 0x70, 0x67])
        let archive = try ZipArchive(data: makeZip([item]))
        #expect(archive.entries[0].path == "é.jpg")
    }

    @Test("Unicodeパス拡張は元の名前のCRCが一致したときだけ採用する", arguments: [true, false])
    func unicodePath(matches: Bool) throws {
        var item = Item("legacy.jpg", flags: 0)
        var payload = Data([1])
        payload.le(matches ? crc(item.name) : UInt32(0))
        payload.append(Data("画像.jpg".utf8))
        item.extra = extraField(0x7075, payload)
        let archive = try ZipArchive(data: makeZip([item]))
        #expect(archive.entries[0].path == (matches ? "画像.jpg" : "legacy.jpg"))
    }

    @Test("UTF8フラグの不正な名前を拒否する")
    func invalidUTF8() {
        var item = Item("unused")
        item.name = Data([0xFF, 0x2E, 0x6A, 0x70, 0x67])
        #expect(throws: ZipArchive.ReadError.corrupted) { try ZipArchive(data: makeZip([item])) }
    }

    @Test("区切りと先頭を正規化して親ディレクトリ参照を画像から除外する")
    func pathSafety() throws {
        let archive = try ZipArchive(
            data: makeZip([
                Item("./folder\\image.jpg"), Item("/root.jpg"), Item("../escape.jpg"),
                Item("folder/../escape.jpg"), Item("safe/..hidden.jpg"),
            ]))
        let selection = ZipImageSelection(archive: archive)
        #expect(selection.images.map(\.path) == ["folder/image.jpg", "root.jpg"])
        #expect(selection.excludedPaths == ["../escape.jpg", "folder/../escape.jpg", "safe/..hidden.jpg"])
    }

    @Test("暗号化された画像は一覧に残して読み込み時に拒否する", arguments: [UInt16(1), UInt16(64)])
    func encrypted(flag: UInt16) throws {
        let archive = try ZipArchive(data: makeZip([Item("image.jpg", flags: flag)]))
        #expect(archive.entries[0].isEncrypted)
        #expect(ZipImageSelection(archive: archive).images.count == 1)
        #expect(throws: ZipArchive.ReadError.encrypted) { try archive.contents(of: archive.entries[0]) }
    }

    @Test("未対応の圧縮方式は読み込み時に方式番号付きで拒否する")
    func unsupportedMethod() throws {
        let archive = try ZipArchive(data: makeZip([Item("image.jpg", method: 99)]))
        #expect(throws: ZipArchive.ReadError.unsupportedCompression(99)) {
            try archive.contents(of: archive.entries[0])
        }
    }

    @Test("展開した内容のCRCが一致しなければ拒否する")
    func checksum() throws {
        var item = Item("image.jpg")
        item.checksum = 0
        let archive = try ZipArchive(data: makeZip([item]))
        #expect(throws: ZipArchive.ReadError.checksumMismatch) { try archive.contents(of: archive.entries[0]) }
    }

    @Test("DEFLATEが宣言サイズを超えた時点で展開を打ち切る")
    func expansionLimit() throws {
        var item = Item("image.jpg", content: Data(repeating: 0x61, count: 1_000_000), method: 8)
        item.declaredSize = 1
        let archive = try ZipArchive(data: makeZip([item]))
        #expect(throws: ZipArchive.ReadError.entryTooLarge) { try archive.contents(of: archive.entries[0]) }
    }

    @Test("展開結果が宣言サイズより短ければ拒否する", arguments: [UInt16(0), UInt16(8)])
    func shortOutput(method: UInt16) throws {
        var item = Item("image.jpg", method: method)
        item.declaredSize = 100
        let archive = try ZipArchive(data: makeZip([item]))
        #expect(throws: ZipArchive.ReadError.corrupted) { try archive.contents(of: archive.entries[0]) }
    }

    @Test("壊れたDEFLATEは停止してエラーになる")
    func invalidDeflate() throws {
        var item = Item("image.jpg", method: 8)
        item.payload = Data([0xFF])
        let archive = try ZipArchive(data: makeZip([item]))
        #expect(throws: ZipArchive.ReadError.corrupted) { try archive.contents(of: archive.entries[0]) }
    }

    @Test("エントリ数の上限を初期化時に検証する")
    func countLimit() {
        #expect(throws: ZipArchive.ReadError.tooManyEntries) {
            try ZipArchive(data: makeZip([Item("a.jpg"), Item("b.jpg")]), limits: .init(maximumEntryCount: 1))
        }
    }

    @Test("宣言サイズの上限は読み込み前に検証する")
    func sizeLimit() throws {
        var item = Item("image.jpg")
        item.declaredSize = UInt64.max
        let archive = try ZipArchive(data: makeZip([item], zip64: true))
        #expect(throws: ZipArchive.ReadError.entryTooLarge) { try archive.contents(of: archive.entries[0]) }
    }

    @Test("呼び出し側が合計サイズを管理できるよう上限と宣言サイズを公開する")
    func totalLimitContract() throws {
        let archive = try ZipArchive(data: makeZip([Item("a.jpg"), Item("b.jpg")]), limits: .init(maximumTotalSize: 5))
        #expect(archive.limits.maximumTotalSize == 5)
        #expect(archive.entries.map(\.uncompressedSize) == [3, 3])
        #expect(ZipArchive.Limits.default.maximumEntryCount == 10_000)
        #expect(ZipArchive.Limits.default.maximumEntrySize == 268_435_456)
        #expect(ZipArchive.Limits.default.maximumTotalSize == 1_073_741_824)
    }

    @Test("ZIP64の終端と拡張フィールドからサイズと位置を読む")
    func zip64() throws {
        let archive = try ZipArchive(data: makeZip([Item("a.jpg"), Item("b.jpg", method: 8)], zip64: true))
        #expect(archive.entries.map(\.uncompressedSize) == [3, 3])
        for entry in archive.entries { #expect(try archive.contents(of: entry) == Data("abc".utf8)) }
    }

    @Test("データ記述子を使うファイルは中央ディレクトリのサイズを使う", arguments: [UInt16(0), UInt16(8)])
    func descriptor(method: UInt16) throws {
        let archive = try ZipArchive(data: makeZip([Item("image.jpg", method: method, flags: 8)]))
        #expect(try archive.contents(of: archive.entries[0]) == Data("abc".utf8))
    }

    @Test("最大長のコメントがあっても終端を見つける")
    func maximumComment() throws {
        let archive = try ZipArchive(data: makeZip([Item("image.jpg")], comment: Data(repeating: 0x61, count: 65_535)))
        #expect(archive.entries.map(\.path) == ["image.jpg"])
    }

    @Test("途中で切れたZIPと無関係なデータはクラッシュせず拒否する")
    func truncated() {
        let data = makeZip([Item("image.jpg")], zip64: true)
        for length in 0..<data.count {
            do {
                _ = try ZipArchive(data: Data(data.prefix(length)))
                Issue.record("Truncated archive was accepted at \(length)")
            } catch {
                #expect(
                    (error as? ZipArchive.ReadError) == .notAZipArchive
                        || (error as? ZipArchive.ReadError) == .corrupted)
            }
        }
        #expect(throws: ZipArchive.ReadError.notAZipArchive) { try ZipArchive(data: Data(repeating: 0xFF, count: 100)) }
    }

    @Test("範囲外の中央ディレクトリ位置を拒否する")
    func invalidDirectoryOffset() {
        var data = makeZip([Item("image.jpg")])
        data.setLE(UInt32.max - 1, at: data.count - 6)
        #expect(throws: ZipArchive.ReadError.corrupted) { try ZipArchive(data: data) }
    }

    @Test("範囲外のローカルヘッダ位置を読み込み時に拒否する")
    func invalidLocalOffset() throws {
        var data = makeZip([Item("image.jpg")])
        let centralOffset = 30 + 9 + 3
        data.setLE(UInt32.max - 1, at: centralOffset + 42)
        let archive = try ZipArchive(data: data)
        #expect(throws: ZipArchive.ReadError.corrupted) { try archive.contents(of: archive.entries[0]) }
    }

    @Test("不正な拡張フィールドの長さを拒否する")
    func malformedExtra() {
        var item = Item("image.jpg")
        item.extra = Data([0x75, 0x70, 0xFF, 0xFF])
        #expect(throws: ZipArchive.ReadError.corrupted) { try ZipArchive(data: makeZip([item])) }
    }

    @Test("空のZIPは空の一覧になる")
    func emptyArchive() throws {
        let archive = try ZipArchive(data: makeZip([]))
        #expect(archive.entries.isEmpty)
        #expect(ZipImageSelection(archive: archive).images.isEmpty)
        #expect(ZipImageSelection(archive: archive).excludedPaths.isEmpty)
    }

    @Test("外部実装で生成したrawDEFLATEと既知のCRCを読める")
    func independentDeflate() throws {
        var item = Item("image.jpg", method: 8)
        // Python zlib.compressobj(wbits=-15) and zlib.crc32(b"abc").
        item.payload = Data([0x4B, 0x4C, 0x4A, 0x06, 0x00])
        item.checksum = 0x3524_41C2
        let archive = try ZipArchive(data: makeZip([item]))
        #expect(try archive.contents(of: archive.entries[0]) == Data("abc".utf8))
    }

    @Test("開始インデックスがゼロでないDataからもZIPを読める")
    func slicedData() throws {
        var data = Data(repeating: 0, count: 10)
        data.append(makeZip([Item("image.jpg", method: 8)]))
        let archive = try ZipArchive(data: data.dropFirst(10))
        #expect(try archive.contents(of: archive.entries[0]) == Data("abc".utf8))
    }

    @Test("ZIP64では番兵値になったフィールドだけを拡張情報から読む", arguments: [20, 24, 42])
    func partialZIP64(field: Int) throws {
        var item = Item("image.jpg")
        var value = Data()
        value.le(UInt64(field == 42 ? 0 : 3))
        item.extra = extraField(1, value)
        var data = makeZip([item])
        data.setLE(UInt32.max, at: 42 + field)
        let archive = try ZipArchive(data: data)
        #expect(try archive.contents(of: archive.entries[0]) == Data("abc".utf8))
    }

    @Test("ZIP64の巨大な位置や長さを整数オーバーフローせず拒否する", arguments: [4, 40, 48, 64])
    func invalidZIP64(field: Int) {
        var data = makeZip([Item("image.jpg")], zip64: true)
        let record = data.count - 98
        data.setLE(UInt64.max, at: record + field)
        #expect(throws: ZipArchive.ReadError.corrupted) { try ZipArchive(data: data) }
    }

    @Test("ZIP64の巨大なエントリ数は確保前に拒否する")
    func hugeZIP64Count() {
        var data = makeZip([Item("image.jpg")], zip64: true)
        let record = data.count - 98
        data.setLE(UInt64.max, at: record + 24)
        data.setLE(UInt64.max, at: record + 32)
        #expect(throws: ZipArchive.ReadError.tooManyEntries) { try ZipArchive(data: data) }
    }

    @Test("不正なローカルヘッダの名前長を拒否する")
    func invalidLocalLength() throws {
        var data = makeZip([Item("image.jpg")])
        data.setLE(UInt16.max, at: 26)
        let archive = try ZipArchive(data: data)
        #expect(throws: ZipArchive.ReadError.corrupted) { try archive.contents(of: archive.entries[0]) }
    }

    @Test("ZIP内の各バイトを破損させても範囲外参照せず結果かエラーを返す")
    func corruptedBytes() throws {
        let original = makeZip([Item("image.jpg", method: 8)], zip64: true)
        for offset in original.indices {
            var data = original
            data[offset] ^= 0xFF
            do {
                let archive = try ZipArchive(
                    data: data, limits: .init(maximumEntryCount: 10, maximumEntrySize: 1024))
                for entry in archive.entries { _ = try archive.contents(of: entry) }
            } catch {
                #expect(error is ZipArchive.ReadError)
            }
        }
    }

    private struct Item {
        var name: Data
        var content: Data
        var method: UInt16
        var flags: UInt16
        var declaredSize: UInt64?
        var checksum: UInt32?
        var extra = Data()
        var payload: Data?

        init(_ name: String, content: Data = Data("abc".utf8), method: UInt16 = 0, flags: UInt16 = 0x800) {
            self.name = Data(name.utf8)
            self.content = content
            self.method = method
            self.flags = flags
        }
    }

    private func makeZip(_ items: [Item], zip64: Bool = false, comment: Data = Data()) -> Data {
        var data = Data()
        var directory = Data()
        for item in items {
            let offset = UInt64(data.count)
            let payload = item.payload ?? (item.method == 8 ? deflate(item.content) : item.content)
            let size = item.declaredSize ?? UInt64(item.content.count)
            let checksum = item.checksum ?? crc(item.content)
            let descriptor = item.flags & 8 != 0
            data.le(UInt32(0x0403_4B50))
            data.le(UInt16(zip64 ? 45 : 20))
            data.le(item.flags)
            data.le(item.method)
            data.le(UInt32(0))
            data.le(descriptor ? UInt32(0) : checksum)
            data.le(descriptor ? UInt32(0) : UInt32(payload.count))
            data.le(descriptor ? UInt32(0) : UInt32(truncatingIfNeeded: size))
            data.le(UInt16(item.name.count))
            data.le(UInt16(0))
            data.append(item.name)
            data.append(payload)
            if descriptor {
                data.le(UInt32(0x0807_4B50))
                data.le(checksum)
                data.le(UInt32(payload.count))
                data.le(UInt32(truncatingIfNeeded: size))
            }
            var extra = item.extra
            if zip64 {
                var values = Data()
                values.le(size)
                values.le(UInt64(payload.count))
                values.le(offset)
                extra.append(extraField(1, values))
            }
            directory.le(UInt32(0x0201_4B50))
            directory.le(UInt16(20))
            directory.le(UInt16(zip64 ? 45 : 20))
            directory.le(item.flags)
            directory.le(item.method)
            directory.le(UInt32(0))
            directory.le(checksum)
            directory.le(zip64 ? UInt32.max : UInt32(payload.count))
            directory.le(zip64 ? UInt32.max : UInt32(truncatingIfNeeded: size))
            directory.le(UInt16(item.name.count))
            directory.le(UInt16(extra.count))
            directory.le(UInt16(0))
            directory.le(UInt16(0))
            directory.le(UInt16(0))
            directory.le(UInt32(0))
            directory.le(zip64 ? UInt32.max : UInt32(offset))
            directory.append(item.name)
            directory.append(extra)
        }
        let directoryOffset = UInt64(data.count)
        data.append(directory)
        if zip64 {
            let recordOffset = UInt64(data.count)
            data.le(UInt32(0x0606_4B50))
            data.le(UInt64(44))
            data.le(UInt16(45))
            data.le(UInt16(45))
            data.le(UInt32(0))
            data.le(UInt32(0))
            data.le(UInt64(items.count))
            data.le(UInt64(items.count))
            data.le(UInt64(directory.count))
            data.le(directoryOffset)
            data.le(UInt32(0x0706_4B50))
            data.le(UInt32(0))
            data.le(recordOffset)
            data.le(UInt32(1))
        }
        data.le(UInt32(0x0605_4B50))
        data.le(UInt16(0))
        data.le(UInt16(0))
        data.le(zip64 ? UInt16.max : UInt16(items.count))
        data.le(zip64 ? UInt16.max : UInt16(items.count))
        data.le(zip64 ? UInt32.max : UInt32(directory.count))
        data.le(zip64 ? UInt32.max : UInt32(directoryOffset))
        data.le(UInt16(comment.count))
        data.append(comment)
        return data
    }

    private func extraField(_ id: UInt16, _ payload: Data) -> Data {
        var data = Data()
        data.le(id)
        data.le(UInt16(payload.count))
        data.append(payload)
        return data
    }

    private func deflate(_ input: Data) -> Data {
        if input.isEmpty { return Data([0x03, 0x00]) }
        var output = [UInt8](repeating: 0, count: input.count + 1024)
        let count = input.withUnsafeBytes { source in
            output.withUnsafeMutableBufferPointer { destination in
                compression_encode_buffer(
                    destination.baseAddress!, destination.count, source.bindMemory(to: UInt8.self).baseAddress!,
                    source.count, nil, COMPRESSION_ZLIB)
            }
        }
        precondition(count > 0)
        return Data(output.prefix(count))
    }

    // A bitwise reference implementation independent of the reader's lookup table.
    private func crc(_ data: Data) -> UInt32 {
        var value = UInt32.max
        for byte in data {
            value ^= UInt32(byte)
            for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 0 ? 0 : 0xEDB8_8320) }
        }
        return value ^ UInt32.max
    }
}

extension Data {
    fileprivate mutating func le<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    fileprivate mutating func setLE<T: FixedWidthInteger>(_ value: T, at offset: Int) {
        var bytes = Data()
        bytes.le(value)
        replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }
}
