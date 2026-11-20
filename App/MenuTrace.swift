import AppKit
import OSLog

enum MenuTrace {
    static let enabled = UserDefaults.standard.bool(forKey: "SurimonoMenuTrace")
    static let noHider = UserDefaults.standard.bool(forKey: "SurimonoMenuNoHider")
    static let noBridgeWrites = UserDefaults.standard.bool(forKey: "SurimonoMenuNoBridgeWrites")
    private static let logger = Logger(subsystem: "io.github.phyten.Surimono", category: "menu")
    private static let file = MenuTraceFile()
    private static let fixedTitles = Set(
        (ShortcutMenuBridge.entries.flatMap { $0.parents + $0.titles }
            + ["Recently Closed Clipboard Documents", "Recent Binders", "Remove from List"]).map {
                Bundle.main.localizedString(forKey: $0, value: $0, table: nil)
            })

    // Plain diagnostics must never become dependencies of a Commands body.
    private static var evaluations: [String: Int] = [:]
    private static var currentWrite: (id: ObjectIdentifier, owner: String)?

    static func commandsBody(_ name: String, version: UInt64) {
        guard enabled else { return }
        evaluations[name, default: 0] += 1
        record("body=\(name) count=\(evaluations[name, default: 0]) version=\(version)")
    }

    static func writer(for id: ObjectIdentifier?) -> String {
        if let currentWrite, currentWrite.id == id { return currentWrite.owner }
        return "unknown"
    }

    static func writing(_ item: NSMenuItem, owner: String, _ mutate: () -> Void) {
        let previous = currentWrite
        currentWrite = (ObjectIdentifier(item), owner)
        defer { currentWrite = previous }
        mutate()
    }

    static func start() {
        _ = noHider
        _ = noBridgeWrites
        record("start noHider=\(noHider) noBridgeWrites=\(noBridgeWrites)")
    }

    static func record(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let event = message()
        let line = "\(Date().timeIntervalSince1970) \(event)"
        logger.debug("\(line, privacy: .public)")
        file.append(line)
    }

    private static let executableName = Bundle.main.executableURL?.lastPathComponent ?? "Surimono"

    static func externalFrames(_ symbols: [String]) -> String {
        // Notification delivery and the stack reader precede the external caller making the edit.
        let frames = symbols.prefix(12).compactMap { line -> String? in
            let parts = line.split(separator: " ", maxSplits: 3)
            guard parts.count == 4, parts[1] != executableName, !parts[1].hasPrefix("Surimono"),
                !line.contains("callStackSymbols")
            else { return nil }
            return "\(parts[1]) \(parts[3])"
        }
        let caller = frames.first {
            !$0.contains("__CFNOTIFICATIONCENTER") && !$0.contains("_CFXRegistrationPost")
                && !$0.contains("_CFXNotification") && !$0.contains("NSNotificationCenter postNotification")
        }
        var message = " externalFrame=[\(caller ?? frames.first ?? "unavailable")]"
        if let validation = frames.first(where: { $0.contains("validateUserInterfaceItem") }) {
            message += " validationFrame=[\(validation)]"
        }
        return message
    }

    static func itemName(_ item: NSMenuItem?) -> String {
        guard let item else { return "-" }
        // A document name, clipboard excerpt, service or user-defined setting can appear anywhere in the tree.
        if fixedTitles.contains(item.title) { return item.title }
        return item.action.map(NSStringFromSelector) ?? "<item>"
    }

    static func menuName(_ menu: NSMenu, root: NSMenu?) -> String {
        if menu === root { return "main" }
        if let index = root?.items.firstIndex(where: { $0.submenu === menu }) {
            let names = ["application", "file", "edit", "view", "document", "window", "help"]
            return names.indices.contains(index) ? names[index] : "menu[\(index)]"
        }
        return fixedTitles.contains(menu.title) ? menu.title : "<submenu>"
    }
}

/// AppKit supplies only an index *after* removal. Keep redacted rows, never the items or their documents.
final class MenuTraceInventory {
    private struct Row {
        let id: ObjectIdentifier
        let fields: String
        let hidden: Bool

        init(_ item: NSMenuItem, inspectImage: Bool) {
            id = ObjectIdentifier(item)
            hidden = item.isHidden
            // AppKit can materialize an image and notify just by reading it. Never probe images at tracking begin.
            let image = inspectImage ? String(item.image != nil) : "unobserved"
            fields =
                "item=\(MenuTrace.itemName(item)) id=\(id.hashValue) image=\(image) state=\(item.state.rawValue) indentationLevel=\(item.indentationLevel) hidden=\(hidden) alternate=\(item.isAlternate)"
        }
    }

    private final class Rows {
        var items: [Row]
        init(_ items: [NSMenuItem]) { self.items = items.map { Row($0, inspectImage: false) } }
    }

    private let menus = NSMapTable<NSMenu, Rows>.weakToStrongObjects()

    private let hiddenChangeStack: (() -> [String])?

    init(hiddenChangeStack: (() -> [String])? = nil) {
        self.hiddenChangeStack = hiddenChangeStack
    }

    func seed(_ menu: NSMenu, reportVisibleEditsAt version: UInt64? = nil) {
        let items = menu.items
        if menus.object(forKey: menu) == nil { menus.setObject(Rows(items), forKey: menu) }
        var previous: NSMenuItem?
        for (index, item) in items.enumerated() {
            if let version, DocumentEditMenu.protects(item, after: previous), !item.isHidden || item.isAlternate {
                MenuTrace.record(
                    "exposed-edit index=\(index) \(Row(item, inspectImage: false).fields) version=\(version)")
            }
            if let submenu = item.submenu { seed(submenu, reportVisibleEditsAt: version) }
            previous = item
        }
    }

    func change(_ note: Notification, in menu: NSMenu, root: NSMenu?, depth: Int, version: UInt64) -> String {
        let index = note.userInfo?["NSMenuItemIndex"] as? Int ?? -1
        let prior = menus.object(forKey: menu)
        let count = menu.numberOfItems
        var row: Row?
        var exposed = false
        var hiddenChangeFields = ""
        if note.name == NSMenu.didRemoveItemNotification {
            if let prior, prior.items.count == count + 1, prior.items.indices.contains(index) {
                row = prior.items.remove(at: index)
            } else {
                // An already populated, detached menu can first become observable on a removal.
                // Its former item is unknowable; never report the new occupant of the same index.
                menus.setObject(Rows(menu.items), forKey: menu)
            }
        } else if (0..<count).contains(index), let item = menu.item(at: index) {
            let previous = prior.flatMap { $0.items.indices.contains(index) ? $0.items[index] : nil }
            let actual = Row(item, inspectImage: note.name == NSMenu.didChangeItemNotification)
            row = actual
            if let prior, note.name == NSMenu.didAddItemNotification, prior.items.count + 1 == count {
                prior.items.insert(actual, at: index)
            } else if let prior, prior.items.count == count {
                prior.items[index] = actual
            } else {
                menus.setObject(Rows(menu.items), forKey: menu)
            }
            if let submenu = item.submenu, menus.object(forKey: submenu) == nil { seed(submenu) }
            if DocumentEditMenu.protects(item, after: index > 0 ? menu.item(at: index - 1) : nil) {
                exposed = !actual.hidden || item.isAlternate
                if note.name == NSMenu.didChangeItemNotification, let previous, previous.id == actual.id,
                    previous.hidden != actual.hidden
                {
                    hiddenChangeFields =
                        " hiddenChange=\(previous.hidden)→\(actual.hidden)"
                        + MenuTrace.externalFrames(hiddenChangeStack?() ?? Thread.callStackSymbols)
                }
            }
        }
        let fields = row?.fields ?? "item=unavailable id=unavailable"
        return
            "\(note.name.rawValue) menu=\(MenuTrace.menuName(menu, root: root)) index=\(index) \(fields) writer=\(MenuTrace.writer(for: row?.id)) depth=\(depth) version=\(version)"
            + (exposed ? " exposed-edit" : "") + hiddenChangeFields
    }
}

/// Disk I/O is ordered off the event thread; tracing a stuck tracking loop must not need a main-queue turn.
private final class MenuTraceFile: Sendable {
    private let queue = DispatchQueue(label: "io.github.phyten.Surimono.menu-trace")
    private let url: URL
    private let limit = 1_000_000

    init() {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Surimono")
        url = directory.appendingPathComponent("menu-trace.log")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data().write(to: url, options: .atomic)
        } catch {
            Logger(subsystem: "io.github.phyten.Surimono", category: "menu").debug(
                "Could not initialize menu trace file")
        }
    }

    func append(_ line: String) {
        let bytes = Data((line + "\n").utf8)
        queue.async { [url, limit] in
            do {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                if try handle.seekToEnd() + UInt64(bytes.count) > UInt64(limit) {
                    try handle.truncate(atOffset: 0)
                }
                try handle.write(contentsOf: bytes)
            } catch {
                Logger(subsystem: "io.github.phyten.Surimono", category: "menu").debug("Could not append menu trace")
            }
        }
    }
}

/// Every native mutation goes through this boundary, including restoration of an original target.
final class MenuWrites {
    private(set) var counts: [String: Int] = [:]
    let owner: String

    private let canWrite: () -> Bool

    private let isTracking: () -> Bool

    init(_ owner: String, canWrite: @escaping () -> Bool, isTracking: @escaping () -> Bool = { false }) {
        self.owner = owner
        self.canWrite = canWrite
        self.isTracking = isTracking
    }

    func change(
        _ item: NSMenuItem, _ property: String, from old: @autoclosure () -> String,
        to new: @autoclosure () -> String, _ write: () -> Void
    ) {
        // A native setter can synchronously post notifications, even in the middle of a pass.
        guard canWrite() else { return }
        counts[property, default: 0] += 1
        MenuTrace.record(
            "write writer=\(owner) id=\(ObjectIdentifier(item).hashValue) \(MenuTrace.itemName(item)) \(property) \(old()) → \(new()) tracking=\(isTracking())"
                + (owner == "hider" && isTracking() ? " exposed-edit property=\(property)" : "")
                + (owner == "hider" && property == "isHidden" ? MenuTrace.externalFrames(Thread.callStackSymbols) : "")
        )
        if MenuTrace.enabled { MenuTrace.writing(item, owner: owner, write) } else { write() }
    }

    func set<Value: Equatable>(
        _ item: NSMenuItem, _ path: ReferenceWritableKeyPath<NSMenuItem, Value>,
        _ property: String, _ value: Value, describe: (Value) -> String = { String(describing: $0) }
    ) {
        let previous = item[keyPath: path]
        guard previous != value else { return }
        change(item, property, from: describe(previous), to: describe(value)) {
            item[keyPath: path] = value
        }
    }
}
