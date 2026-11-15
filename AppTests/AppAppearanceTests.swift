import AppKit
import Testing

@testable import Surimono

@MainActor
struct AppAppearanceTests {
    /// Stands in for the application, whose appearance the hosted tests must not change.
    private final class Recorder {
        var names: [NSAppearance.Name?] = []
        func set(_ appearance: NSAppearance?) { names.append(appearance?.name) }
    }

    @Test("何も保存されていなければ外観はライト")
    func defaultIsLight() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        #expect(AppPreferences(defaults: suite.defaults).appearance == .light)
    }

    @Test("ライトは Aqua、ダークは Dark Aqua、システムに合わせるは外観を指定しない")
    func choicesMapToAppearances() {
        #expect(AppAppearance.light.appearance?.name == .aqua)
        #expect(AppAppearance.dark.appearance?.name == .darkAqua)
        #expect(AppAppearance.system.appearance == nil)
    }

    @Test("起動時に保存された外観をアプリへ当てる")
    func appliesStoredChoiceAtStart() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        suite.defaults.set("dark", forKey: "appearance")
        let recorder = Recorder()
        let keeper = AppearanceKeeper(
            preferences: AppPreferences(defaults: suite.defaults), override: nil, setAppearance: recorder.set)
        keeper.start()
        #expect(recorder.names == [.darkAqua])
    }

    @Test("外観を変えるとすぐアプリへ当たり、次の起動にも残る")
    func changeAppliesAndPersists() async {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let preferences = AppPreferences(defaults: suite.defaults)
        let recorder = Recorder()
        let keeper = AppearanceKeeper(preferences: preferences, override: nil, setAppearance: recorder.set)
        keeper.start()
        preferences.appearance = .system
        for _ in 0..<50 where recorder.names.count < 2 { try? await Task.sleep(for: .milliseconds(10)) }
        preferences.appearance = .dark
        for _ in 0..<50 where recorder.names.count < 3 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(recorder.names == [.aqua, nil, .darkAqua])
        #expect(AppPreferences(defaults: suite.defaults).appearance == .dark)
    }

    @Test("開発用の外観の指定は設定より優先し、設定には書かない")
    func debugOverrideIsNotSaved() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let preferences = AppPreferences(defaults: suite.defaults)
        let recorder = Recorder()
        let keeper = AppearanceKeeper(preferences: preferences, override: .dark, setAppearance: recorder.set)
        keeper.start()
        #expect(recorder.names == [.darkAqua])
        #expect(preferences.appearance == .light)
        #expect(suite.defaults.object(forKey: "appearance") == nil)
    }
}
