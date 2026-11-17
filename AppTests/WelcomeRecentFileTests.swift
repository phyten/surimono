import Foundation
import Testing

@testable import Surimono

@MainActor
struct WelcomeRecentFileTests {
    @Test("最近使ったファイルの場所は、ホームの中なら ~ から書き、外ならそのまま書く")
    func folderNames() {
        let home = "/Users/reader"
        #expect(
            RecentFileRow.folder(of: URL(fileURLWithPath: "/Users/reader/Documents/notes.md"), home: home)
                == "~/Documents")
        #expect(RecentFileRow.folder(of: URL(fileURLWithPath: "/Users/reader/notes.md"), home: home) == "~")
        #expect(RecentFileRow.folder(of: URL(fileURLWithPath: "/Volumes/Share/a.pdf"), home: home) == "/Volumes/Share")
        // A folder that only begins with the same letters is not inside the home.
        #expect(
            RecentFileRow.folder(of: URL(fileURLWithPath: "/Users/readers/a.md"), home: home) == "/Users/readers")
    }
}
