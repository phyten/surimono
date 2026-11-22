import Foundation
import Testing

@testable import Surimono

/// Hosted tests run the Debug build, which must stay a separate app from the installed release.
@MainActor
struct DevelopmentBuildTests {
    @Test("開発版は公開版と別のバンドル ID を使い、設定を共有しない")
    func bundleIdentifier() {
        #expect(Bundle.main.bundleIdentifier == "app.surimono.Surimono.debug")
    }

    @Test("配布するプライバシー宣言には利用する API と理由だけが入り、追跡もデータ収集もしない")
    func privacyManifest() throws {
        let url = try #require(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        let manifest = try #require(plist as? [String: Any])
        #expect(manifest["NSPrivacyTracking"] as? Bool == false)
        #expect((manifest["NSPrivacyTrackingDomains"] as? [Any])?.isEmpty == true)
        #expect((manifest["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty == true)

        let entries = try #require(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        var declared: [String: [String]] = [:]
        for entry in entries {
            let category = try #require(entry["NSPrivacyAccessedAPIType"] as? String)
            let reasons = try #require(entry["NSPrivacyAccessedAPITypeReasons"] as? [String])
            #expect(declared.updateValue(reasons.sorted(), forKey: category) == nil)
        }
        #expect(
            declared == [
                "NSPrivacyAccessedAPICategoryFileTimestamp": ["3B52.1", "C617.1"],
                "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1"],
                "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
            ])
    }

    @Test("開発版は Surimono Dev と表示される")
    func displayName() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String == "Surimono Dev")
    }

    @Test("開発版は DEV の帯のアイコンを使う")
    func icon() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String == "AppIcon-Dev")
    }

    @Test("開発版はスタイル・プリセット・文書ごとの設定を Surimono Dev のフォルダに保存する")
    func supportFolder() throws {
        let applicationSupport = try #require(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        #expect(UserLibrary.defaultRoot == applicationSupport.appendingPathComponent("Surimono Dev", isDirectory: true))
    }
}
