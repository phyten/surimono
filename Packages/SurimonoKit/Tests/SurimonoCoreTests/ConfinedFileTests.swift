import Foundation
import SurimonoCore
import Testing

struct ConfinedFileTests {
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let inside: URL
        let outside: URL

        init() throws {
            inside = root.appendingPathComponent("inside")
            outside = root.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try Data("外".utf8).write(to: outside.appendingPathComponent("secret.md"))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
        var canonicalInside: String { (try? ConfinedFile.canonicalPath(inside)) ?? "" }
    }

    @Test("ルートの下のファイルを読む")
    func readsInside() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let file = fixture.inside.appendingPathComponent("a.md")
        try Data("中".utf8).write(to: file)
        #expect(try ConfinedFile.read(file, within: fixture.canonicalInside) == Data("中".utf8))
    }

    @Test("ルートの外を指すリンクは読まない")
    func refusesLink() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let link = fixture.inside.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: fixture.outside.appendingPathComponent("secret.md"))
        #expect(throws: (any Error).self) { try ConfinedFile.read(link, within: fixture.canonicalInside) }
    }

    @Test("途中のフォルダーがルートの外へのリンクなら読まない")
    func refusesLinkedFolder() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let folder = fixture.inside.appendingPathComponent("sub")
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: fixture.outside)
        #expect(throws: (any Error).self) {
            try ConfinedFile.read(folder.appendingPathComponent("secret.md"), within: fixture.canonicalInside)
        }
    }

    @Test("ルートの中を指すリンクは読む")
    func allowsInnerLink() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let file = fixture.inside.appendingPathComponent("a.md")
        try Data("中".utf8).write(to: file)
        let link = fixture.inside.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(try ConfinedFile.read(link, within: fixture.canonicalInside) == Data("中".utf8))
    }

    @Test("同じ名前で始まる隣のフォルダーはルートの下に数えない")
    func refusesSiblingWithSamePrefix() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sibling = fixture.root.appendingPathComponent("inside-2")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let file = sibling.appendingPathComponent("a.md")
        try Data("隣".utf8).write(to: file)
        #expect(throws: (any Error).self) { try ConfinedFile.read(file, within: fixture.canonicalInside) }
    }

    @Test("確かめた後にリンクへ差し替えられても、確かめた記述子の中身を読む")
    func readsCheckedDescriptor() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let file = fixture.inside.appendingPathComponent("a.md")
        try Data("確かめた中身".utf8).write(to: file)
        let data = try ConfinedFile.read(file, within: fixture.canonicalInside) {
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createSymbolicLink(
                at: file, withDestinationURL: fixture.outside.appendingPathComponent("secret.md"))
        }
        #expect(data == Data("確かめた中身".utf8))
    }

    @Test("通常のファイルでないものは読まない")
    func refusesDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let folder = fixture.inside.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try ConfinedFile.read(folder, within: fixture.canonicalInside) }
    }

    @Test("上限を超えるファイルは読まない")
    func refusesLargeFile() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let file = fixture.inside.appendingPathComponent("a.md")
        try Data(repeating: 0x61, count: 11).write(to: file)
        #expect(throws: (any Error).self) {
            try ConfinedFile.read(file, within: fixture.canonicalInside, maximumSize: 10)
        }
    }
}
