import Foundation
import Testing

@testable import Surimono

@MainActor
struct AppUpdaterTests {
    @Test("終了時に入れる更新の通知がデリゲートに接続されている")
    func delegateCallbacks() {
        #expect(
            AppUpdater.shared.responds(
                to: NSSelectorFromString("updater:willInstallUpdateOnQuit:immediateInstallationBlock:")))
    }

    @Test("更新待ちがなければ言語の再起動を提案し通常経路だけを呼ぶ")
    func ordinaryRelaunch() async {
        let relaunch = UpdateRelaunch()
        #expect(relaunch.notice == .offerRelaunch)
        var launches = 0
        let performed = await relaunch.perform { launches += 1 }
        #expect(performed)
        #expect(launches == 1)
    }

    @Test("更新待ちの通知は引き継がずfalseを返し次回起動の案内だけを出す")
    func pendingInstallation() async {
        let relaunch = UpdateRelaunch()
        #expect(!relaunch.updateWillInstallOnQuit())
        #expect(relaunch.hasPendingInstallation)
        #expect(relaunch.notice == .nextLaunch)
        #expect(
            relaunch.notice.message == String(localized: "The language changes the next time you open Surimono."))
        var launches = 0
        let performed = await relaunch.perform { launches += 1 }
        #expect(!performed)
        #expect(launches == 0)
    }

    @Test("再起動の提案後に更新待ちになっても新しいインスタンスを起動しない")
    func pendingAfterOffer() async {
        let relaunch = UpdateRelaunch()
        #expect(relaunch.notice == .offerRelaunch)
        _ = relaunch.updateWillInstallOnQuit()
        var launches = 0
        let performed = await relaunch.perform { launches += 1 }
        #expect(!performed)
        #expect(launches == 0)
        #expect(relaunch.notice == .nextLaunch)
    }

    @Test("一度インストール待ちになったら、そのプロセスの間は再起動を提案しない")
    func pendingInstallationStays() async {
        let relaunch = UpdateRelaunch()
        _ = relaunch.updateWillInstallOnQuit()
        #expect(relaunch.hasPendingInstallation)
        #expect(relaunch.notice == .nextLaunch)
        var launches = 0
        let performed = await relaunch.perform { launches += 1 }
        #expect(!performed)
        #expect(launches == 0)
    }

    @Test("自動確認が許可されていれば、起動のたびに裏でアップデートを確認する")
    func checksOnLaunchWhenAllowed() {
        let updater = FakeUpdater(automaticallyChecksForUpdates: true)
        AppUpdater.checkOnLaunch(updater)
        #expect(updater.backgroundChecks == 1)
    }

    @Test("自動確認が許可されていなければ、起動しても通信しない")
    func staysOfflineOnLaunchWithoutConsent() {
        let updater = FakeUpdater(automaticallyChecksForUpdates: false)
        AppUpdater.checkOnLaunch(updater)
        #expect(updater.backgroundChecks == 0)
    }

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

@MainActor
private final class FakeUpdater: LaunchUpdateChecking {
    let automaticallyChecksForUpdates: Bool
    private(set) var backgroundChecks = 0

    init(automaticallyChecksForUpdates: Bool) {
        self.automaticallyChecksForUpdates = automaticallyChecksForUpdates
    }

    func checkForUpdatesInBackground() {
        backgroundChecks += 1
    }
}
