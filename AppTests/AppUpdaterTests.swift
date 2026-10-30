import Foundation
import Testing

@testable import Surimono

@MainActor
struct AppUpdaterTests {
    @Test("開発版は appcast を持たず、アップデーターを動かさない")
    func developmentBuildHasNoUpdater() {
        #expect(AppUpdater.feedURL(in: Bundle.main.infoDictionary) == nil)
        #expect(!AppUpdater.shared.isAvailable)
    }

    @Test("アプリに更新の署名を確かめる公開鍵が入っている")
    func publicKeyIsEmbedded() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        #expect(key == "J2DmT6aAkfRg6szOm5nH4hjIqVaCdeIso9phuWHieiA=")
    }

    @Test("Info.plist の appcast の URL を読み取る")
    func feedURLIsRead() {
        let feed = "https://github.com/phyten/surimono/releases/latest/download/appcast.xml"
        #expect(AppUpdater.feedURL(in: ["SUFeedURL": feed]) == URL(string: feed))
    }

    @Test("appcast の URL が空か無いときは、確認先なしとみなす")
    func emptyFeedMeansNoUpdates() {
        #expect(AppUpdater.feedURL(in: ["SUFeedURL": ""]) == nil)
        #expect(AppUpdater.feedURL(in: [:]) == nil)
        #expect(AppUpdater.feedURL(in: nil) == nil)
    }
}
