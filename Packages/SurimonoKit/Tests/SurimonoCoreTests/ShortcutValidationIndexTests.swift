import Foundation
import Testing

@testable import SurimonoCore

struct ShortcutValidationIndexTests {
    @Test("全キーと16修飾と二つの綴りと60予約でも既定の検証を2秒以内に終える")
    func fullProjection() throws {
        let codes = (UInt16(0)..<128).filter { ShortcutKey.macVirtualKey($0).isSupported }
        var projection: [ShortcutProjection] = []
        for code in codes {
            let character = code == 15 ? "r" : String(try #require(UnicodeScalar(0x4E00 + UInt32(code))))
            for raw: UInt8 in 0..<16 {
                let flags = ShortcutModifiers(rawValue: raw)
                let physical = ShortcutCombination(key: .macVirtualKey(code), modifiers: flags)
                for spelling in [character, character.uppercased()] {
                    projection.append(
                        .init(logical: .init(key: .character(spelling), modifiers: flags), physical: physical))
                }
            }
        }
        var reservations = codes.prefix(59).map {
            ShortcutSystemReservation(
                combination: .init(key: .macVirtualKey($0), modifiers: [.control, .option, .shift, .command]))
        }
        reservations.append(.init(combination: .init(key: .macVirtualKey(15), modifiers: .command)))
        #expect(projection.count == codes.count * 16 * 2)
        #expect(reservations.count == 60)
        let clock = ContinuousClock()
        let start = clock.now
        let context = ShortcutValidationContext(reservations: reservations, projection: projection)
        let validator = ShortcutValidator(environment: context)
        let issues = validator.issues(in: .init())
        let conflicts = validator.conflicts(in: .init())
        let elapsed = start.duration(to: clock.now)
        #expect(elapsed < .seconds(2))
        #expect(
            issues == [
                .init(
                    code: .systemReserved, operation: .documentReload,
                    combination: .init(key: .character("r"), modifiers: .command))
            ])
        #expect(conflicts.isEmpty)
        #expect(context == ShortcutValidationContext(reservations: reservations, projection: projection))
    }

    @Test("システム画面だけの矢印予約を除きControl矢印と裸のFキー予約は守る")
    func arrowReservations() {
        let arrows: [(UInt16, ShortcutNamedKey)] = [
            (123, .leftArrow), (124, .rightArrow), (125, .downArrow), (126, .upArrow),
        ]
        var reservations: [ShortcutSystemReservation] = []
        var projection: [ShortcutProjection] = []
        for (code, key) in arrows {
            let values: [UInt32] = [0x20000, 0x21000, 0x21200, 0x21a00] + (code <= 124 ? [0x21000, 0x20800] : [])
            reservations += values.map { .init(combination: .init(key: .macVirtualKey(code), modifiers: .carbon($0))) }
            for raw: UInt8 in 0..<16 {
                let flags = ShortcutModifiers(rawValue: raw)
                projection.append(
                    .init(
                        logical: .init(key: .named(key), modifiers: flags),
                        physical: .init(key: .macVirtualKey(code), modifiers: flags)))
            }
        }
        for (code, key): (UInt16, ShortcutNamedKey) in [(103, .f11), (111, .f12)] {
            reservations.append(.init(combination: .init(key: .macVirtualKey(code))))
            projection.append(.init(logical: .init(key: .named(key)), physical: .init(key: .macVirtualKey(code))))
        }
        let validator = ShortcutValidator(environment: .init(reservations: reservations, projection: projection))
        for (_, key) in arrows {
            #expect(validator.issues(for: .readingLeft, combination: .init(key: .named(key))).isEmpty)
        }
        #expect(
            validator.issues(for: .readingLeft, combination: .init(key: .named(.leftArrow), modifiers: .option)).isEmpty
        )
        #expect(
            validator.issues(for: .readingLeft, combination: .init(key: .named(.leftArrow), modifiers: .control)).map(
                \.code) == [.workspaceNavigation])
        #expect(
            validator.issues(
                for: .readingLeft, combination: .init(key: .named(.leftArrow), modifiers: [.control, .shift])
            ).map(\.code) == [.systemReserved])
        for key: ShortcutNamedKey in [.f11, .f12] {
            #expect(
                validator.issues(for: .readingLeft, combination: .init(key: .named(key))).map(\.code) == [
                    .systemReserved
                ])
        }
    }
}
