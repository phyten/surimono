import Foundation
import SurimonoCore
import SurimonoRendering

@testable import Surimono

/// Band tests keep every preference in a volatile domain and never write a preferences plist.
struct BandTestDefaultsSuite {
    let defaults: UserDefaults = BandTestMemoryDefaults()
    func remove() {}
}

private final class BandTestMemoryDefaults: UserDefaults, @unchecked Sendable {
    // These tests use the instance only on the main actor; UserDefaults owns the volatile storage.
    private let domain = "BandTests." + UUID().uuidString
    override func object(forKey key: String) -> Any? { volatileDomain(forName: domain)[key] }
    override func set(_ value: Any?, forKey key: String) {
        var values = volatileDomain(forName: domain)
        values[key] = value
        setVolatileDomain(values, forName: domain)
    }
    override func removeObject(forKey key: String) { set(nil, forKey: key) }
    override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    override func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
    override func string(forKey key: String) -> String? { object(forKey: key) as? String }
    override func bool(forKey key: String) -> Bool { object(forKey: key) as? Bool ?? false }
    override func integer(forKey key: String) -> Int { object(forKey: key) as? Int ?? 0 }
    override func double(forKey key: String) -> Double { object(forKey: key) as? Double ?? 0 }
}

@MainActor
extension DocumentViewModel {
    func isolateBandTestOutput() {
        printSubmit = { _, _, _ in }
        outputOverride = { _, _ in }
        printerListSource = { .empty }
    }
}

@MainActor
enum BandTestCatalog {
    nonisolated static let standardUnused: [BandLayout.Item] =
        [.transition, .floatOnTop, .showOnAllSpaces] + addedItems
    nonisolated static let addedItems: [BandLayout.Item] = [
        .readingDirection, .scrollDirection, .paperOrientation, .paperSeries, .cover, .selectText, .alwaysShowToolbar,
        .margins, .printSettings, .ignoreSlides, .beforePrinting, .viewOptions, .saveAsFile, .keysAndGestures,
    ]
    nonisolated static let standardSplitUnused: [BandLayout.Item] = [
        .layout, .zoom, .thumbnails, .readingDirection, .scrollDirection, .paperSeries, .cover, .margins,
        .printSettings, .ignoreSlides, .beforePrinting, .saveAsFile, .keysAndGestures, .readingSettings,
    ]
    /// The Split standard before the current one, for tests about saved layouts rather than about Standard itself.
    nonisolated static var quietSplit: BandArrangement {
        BandArrangement(
            entries: [
                .topLeft: [.part(.formatBadge)], .topRight: [.part(.print)],
                .bottomLeft: [
                    .part(.presentation), .separator, .part(.style), .part(.outline), .separator, .part(.layout),
                    .separator, .part(.zoom), .part(.thumbnails),
                ],
                .bottomRight: [.part(.chapter), .part(.pageIndicator), .part(.pageTurn), .part(.readingSettings)],
            ], unused: standardUnused)
    }
    nonisolated static var quietLayouts: BandArrangementVariants { BandArrangementVariants(split: quietSplit) }
}
