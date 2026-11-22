import Foundation
import RobustnessSupport
import SurimonoCore
import SurimonoFormats
import Testing

/// A ZIP of images is read in memory: the selection and the members' bytes, never files on disk.
// A sanitizer slows the readers several times over; under AddressSanitizer the hostile archives took three minutes.
@Suite(.timeLimit(.minutes(Sanitizer.isActive ? 10 : 1)))
struct ZipRobustnessTests {
    private static func readImages(_ bytes: [UInt8]) async throws -> SmallStack.Outcome<Int> {
        try await SmallStack.run(limit: SmallStack.limit(forBytes: bytes.count)) {
            guard let archive = try? ZipArchive(data: Data(bytes)) else { return 0 }
            let selection = ZipImageSelection(archive: archive)
            return selection.images.reduce(0) { total, entry in
                total + ((try? archive.contents(of: entry).count) ?? 0)
            }
        }
    }

    @Test("壊れた・偽った ZIP の画像の束を読んでも、落ちず時間内に終わる")
    func hostileArchives() async throws {
        for item in HostileInputs.cases(for: .zipArchive) where !item.isLong {
            if case .timedOut = try await Self.readImages(HostileInputs.$quick.withValue(true) { item.bytes() }) {
                Issue.record("\(item) did not finish in time")
            }
        }
    }

    @Test("ZIP の中の名前が .. や絶対パスでも、その場所にファイルを作らない")
    func membersStayInMemory() async throws {
        let token = UUID().uuidString
        let temporary = FileManager.default.temporaryDirectory
        let absolute = temporary.appendingPathComponent("surimono-absolute-\(token).png").path
        let image = BinaryInputs.png(width: 1, height: 1)
        let archive = try ZipArchive(
            data: Data(
                BinaryInputs.zip([
                    .init("../../surimono-escape-\(token).png", image), .init(absolute, image),
                    .init("a/../../../surimono-up-\(token).png", image),
                ])))
        let selection = ZipImageSelection(archive: archive)
        for entry in selection.images { _ = try? archive.contents(of: entry) }
        let places = [
            temporary, temporary.deletingLastPathComponent(),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).deletingLastPathComponent(),
        ]
        for place in places {
            for name in ["surimono-escape-\(token).png", "surimono-up-\(token).png"] {
                #expect(!FileManager.default.fileExists(atPath: place.appendingPathComponent(name).path))
            }
        }
        #expect(!FileManager.default.fileExists(atPath: absolute))
    }

    @Test("中身の大きさを 4 GB と偽った ZIP の画像は、読み込まずにエラーにする")
    func declaredSizeLies() throws {
        let image = BinaryInputs.png(width: 1, height: 1)
        let archive = try ZipArchive(data: Data(BinaryInputs.zip([.init("a.png", image, declaredSize: 0xFFFF_FFF0)])))
        let entry = try #require(archive.entries.first)
        #expect(throws: (any Error).self) { try archive.contents(of: entry) }
    }
}
