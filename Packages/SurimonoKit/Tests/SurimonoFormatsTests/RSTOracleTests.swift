import Foundation
import Testing

@testable import SurimonoFormats

struct RSTOracleTests {
    @Test("自作の原稿を Docutils で得た構造と全件照合する")
    func comparesRenderedTrees() throws {
        let fixtures = try #require(Bundle.module.resourceURL?.appending(path: "Fixtures/RST"))
        let files = FileManager.default
        let directory = files.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: directory) }
        for group in ["blocks", "inline", "directives"] {
            let output = directory.appending(path: group)
            try files.createDirectory(at: output, withIntermediateDirectories: false)
            for source in try files.contentsOfDirectory(
                at: fixtures.appending(path: group), includingPropertiesForKeys: nil)
            where source.pathExtension == "rst" {
                let input = TextDecoding.decode(try Data(contentsOf: source)).text
                let html = RSTConverter.convert(input, directory: source.deletingLastPathComponent()).body
                try html.write(
                    to: output.appending(path: source.deletingPathExtension().lastPathComponent + ".html"),
                    atomically: true, encoding: .utf8)
            }
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "python3", root.appending(path: "Tools/RST/compare.py").path, "--fixtures", fixtures.path,
            "--html", directory.path,
        ]
        if ProcessInfo.processInfo.environment["SURIMONO_RST_LIVE"] == "1" {
            process.arguments?.append("--live")
        }
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
