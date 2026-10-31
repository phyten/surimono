import SurimonoCore
import Testing

@testable import Surimono

@MainActor
struct WheelPreferencesTests {
    @Test("スクロール感度は標準で始まり、変更を保存する")
    func persists() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let preferences = AppPreferences(defaults: suite.defaults)
        #expect(preferences.wheelSensitivity == .normal)
        preferences.wheelSensitivity = .low
        #expect(AppPreferences(defaults: suite.defaults).wheelSensitivity == .low)
    }

    @Test("未知のスクロール感度は標準に戻す")
    func unknownValue() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        suite.defaults.set("unknown", forKey: "wheelSensitivity")
        #expect(AppPreferences(defaults: suite.defaults).wheelSensitivity == .normal)
    }
}
