import Foundation
import Testing

@testable import Surimono

/// Hosted tests run the Debug build, which must stay a separate app from the installed release.
@MainActor
struct DevelopmentBuildTests {
    @Test("開発版は公開版と別のバンドル ID を使い、設定を共有しない")
    func bundleIdentifier() {
        #expect(Bundle.main.bundleIdentifier == "io.github.phyten.Surimono.debug")
    }

    @Test("開発版は Surimono Dev と表示される")
    func displayName() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String == "Surimono Dev")
    }

    @Test("開発版は DEV の帯のアイコンを使う")
    func icon() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String == "AppIcon-Dev")
    }
}
