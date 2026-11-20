import AppKit
import Testing

@testable import Surimono

@MainActor
struct MenuTraceTests {
    @Test("非表示の値が変わった標準編集項目だけに外部フレームを記録する")
    func hiddenChangeOrigin() {
        let menu = NSMenu()
        let save = menu.addItem(withTitle: "Private", action: #selector(NSDocument.save(_:)), keyEquivalent: "")
        let other = menu.addItem(withTitle: "Private", action: nil, keyEquivalent: "")
        var captures = 0
        let inventory = MenuTraceInventory {
            captures += 1
            return [
                "0 Surimono.debug.dylib 0xf menuChanged", "1 Foundation 0xf -[NSNotificationCenter postNotification:]",
                "2 AppKit 0xf -[NSMenuItem setHidden:]", "3 AppKit 0xf -[NSDocument validateUserInterfaceItem:]",
            ]
        }
        inventory.seed(menu)
        func change(_ index: Int) -> String {
            inventory.change(
                Notification(name: NSMenu.didChangeItemNotification, userInfo: ["NSMenuItemIndex": index]),
                in: menu, root: menu, depth: 1, version: 3)
        }
        save.isHidden = true
        let line = change(0)
        #expect(line.contains("hiddenChange=false→true externalFrame=[AppKit -[NSMenuItem setHidden:]]"))
        #expect(line.contains("validationFrame=[AppKit -[NSDocument validateUserInterfaceItem:]]"))
        #expect(!change(0).contains("externalFrame"))
        other.isHidden = true
        #expect(!change(1).contains("externalFrame"))
        #expect(captures == 1)
        let outsideLimit =
            Array(repeating: "0 Surimono 0xf Test", count: 12) + ["12 AppKit 0xf validateUserInterfaceItem:"]
        #expect(MenuTrace.externalFrames(outsideLimit) == " externalFrame=[unavailable]")
    }

    @Test("追跡ログは本文を出さず、変更と削除を同じ項目の識別子と書き手で追える")
    func itemIdentityAndAttribution() {
        let menu = NSMenu()
        let item = menu.addItem(
            withTitle: "Private clipboard excerpt", action: #selector(NSDocument.save(_:)), keyEquivalent: "")
        let inventory = MenuTraceInventory()
        inventory.seed(menu)
        let replacement = menu.addItem(withTitle: "Private file name", action: nil, keyEquivalent: "")
        func change(_ name: Notification.Name, at index: Int) -> String {
            inventory.change(
                Notification(name: name, object: menu, userInfo: ["NSMenuItemIndex": index]), in: menu, root: menu,
                depth: 2, version: 7)
        }
        let added = change(NSMenu.didAddItemNotification, at: 1)
        #expect(added.contains("id=\(ObjectIdentifier(replacement).hashValue) "))
        #expect(!added.contains(replacement.title))
        item.image = NSImage(size: NSSize(width: 1, height: 1))
        item.state = .on
        item.indentationLevel = 2
        let id = ObjectIdentifier(item).hashValue
        let changed = change(NSMenu.didChangeItemNotification, at: 0)
        for field in [
            "menu=main index=0", "item=saveDocument:", "id=\(id) ", "image=unobserved", "state=1", "indentationLevel=2",
            "writer=unknown depth=2 version=7", "exposed-edit",
        ] {
            #expect(changed.contains(field))
        }
        #expect(!changed.contains(item.title))
        MenuTrace.writing(item, owner: "hider") {
            #expect(change(NSMenu.didChangeItemNotification, at: 0).contains("writer=hider "))
            #expect(change(NSMenu.didChangeItemNotification, at: 1).contains("writer=unknown "))
        }
        menu.removeItem(at: 0)
        let removed = change(NSMenu.didRemoveItemNotification, at: 0)
        #expect(removed.contains("id=\(id) "))
        #expect(removed.contains("writer=unknown"))
        #expect(menu.item(at: 0) === replacement)
    }
}
