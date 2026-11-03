import Darwin
import Foundation
import Testing

@testable import SurimonoRendering

struct SnapshotResourceTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("page"), withIntermediateDirectories: true)
        try Data("original".utf8).write(to: root.appendingPathComponent("page/image.bin"))
        try Data("outside".utf8).write(to: root.appendingPathComponent("secret.bin"))
        return root
    }

    @Test("検証後にファイルを外へのリンクに差し替えても開いた元の内容だけを読む")
    func replacementAfterValidation() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("page")
        let file = directory.appendingPathComponent("image.bin")
        let data = try SnapshotSchemeHandler.readFile(for: "/image.bin", in: directory) {
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createSymbolicLink(
                at: file, withDestinationURL: root.appendingPathComponent("secret.bin"))
        }
        #expect(data == Data("original".utf8))
    }

    @Test("スナップショットは外へのリンクとFIFOと大きすぎるファイルを拒否する")
    func rejectsUnsafeResources() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("page")
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("link.bin"),
            withDestinationURL: root.appendingPathComponent("secret.bin"))
        #expect(mkfifo(directory.appendingPathComponent("pipe").path, 0o600) == 0)
        for path in ["/link.bin", "/pipe", "/../secret.bin", "/"] {
            #expect(throws: (any Error).self) { try SnapshotSchemeHandler.readFile(for: path, in: directory) }
        }
        #expect(throws: (any Error).self) {
            try SnapshotSchemeHandler.readFile(for: "/image.bin", in: directory, maximumSize: 3)
        }
    }

    @Test("検証後に成長したファイルも読み込み中の上限で拒否する")
    func growthAfterValidation() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("page")
        #expect(throws: CocoaError(.fileReadTooLarge)) {
            try SnapshotSchemeHandler.readFile(for: "/image.bin", in: directory, maximumSize: 8) {
                let handle = try FileHandle(forWritingTo: directory.appendingPathComponent("image.bin"))
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data("more".utf8))
            }
        }
    }

    @Test("許可範囲内のシンボリックリンクと元のバイト列を保つ")
    func internalLink() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("page")
        let bytes = Data([0x82, 0xa0, 0x82, 0xa2])
        try bytes.write(to: directory.appendingPathComponent("image.bin"))
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("link.bin"),
            withDestinationURL: directory.appendingPathComponent("image.bin"))
        #expect(try SnapshotSchemeHandler.readFile(for: "/link.bin", in: directory) == bytes)
    }
}
