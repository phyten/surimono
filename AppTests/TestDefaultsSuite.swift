import Foundation
import Synchronization

/// A UserDefaults suite of one test's own, so tests share no settings and leave no plist in ~/Library/Preferences.
struct TestDefaultsSuite {
    let name = "SurimonoTests.\(UUID().uuidString)"

    /// A new object for the suite on every call; all of them read and write the same settings.
    var defaults: UserDefaults { UserDefaults(suiteName: name)! }

    /// Empties the suite now and deletes its plist when the test process exits.
    ///
    /// cfprefsd creates the plist as soon as the suite is used, even only read, but writes later changes, the removal
    /// included, only about every ten seconds, and writes them even if the plist was deleted in the meantime. So the
    /// plist is deleted at exit, once cfprefsd has written the suite empty.
    func remove() {
        let standard = UserDefaults.standard
        // Set a value first and wait until cfprefsd has it: everything cfprefsd writes after `start` then holds a value
        // until it includes the removal, and there is surely a removal left to write.
        standard.setPersistentDomain(["removed": true], forName: name)
        standard.synchronize()
        let start = Date.now
        standard.removePersistentDomain(forName: name)
        let plist = URL.libraryDirectory.appending(path: "Preferences/\(name).plist")
        Self.removals.withLock { $0.append(Removal(plist: plist, start: start)) }
    }

    private struct Removal {
        let plist: URL
        let start: Date

        /// cfprefsd has written the suite empty since the removal started, so it has nothing left to write.
        var isWritten: Bool {
            // Read the date before the contents, so the contents are at least as new as the date.
            guard
                let modified = (try? FileManager.default.attributesOfItem(atPath: plist.path))?[.modificationDate]
                    as? Date,
                modified > start,
                let data = try? Data(contentsOf: plist)
            else { return false }
            let domain = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            return domain?.isEmpty == true
        }
    }

    /// The first removal registers the deletion at exit.
    private static let removals: Mutex<[Removal]> = {
        atexit { TestDefaultsSuite.deleteWrittenPlists() }
        return Mutex([])
    }()

    /// Deletes the plists of removed suites as cfprefsd writes them, waiting 30 seconds at most.
    private static func deleteWrittenPlists() {
        var pending = removals.withLock { $0 }
        let deadline = Date.now + 30
        while !pending.isEmpty, Date.now < deadline {
            pending.removeAll { removal in
                guard removal.isWritten else { return false }
                try? FileManager.default.removeItem(at: removal.plist)
                return true
            }
            if !pending.isEmpty { Thread.sleep(forTimeInterval: 0.1) }
        }
    }
}
