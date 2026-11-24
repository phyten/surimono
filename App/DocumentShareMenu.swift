import AppKit

/// SwiftUI owns the File row. AppKit owns the submenu, including validation of the current
/// NSDocument and discovery and dispatch of sharing services when the submenu is opened.
final class DocumentShareMenu {
    static let identifier = "surimono.menu.documentShare"
    fileprivate static let systemIdentifier = NSUserInterfaceItemIdentifier("surimono.menu.systemDocumentShare")

    // SwiftUI doesn't always bridge accessibilityIdentifier to NSMenuItem. A private
    // instance of the Share glyph also identifies the declared Label on those releases.
    static let glyph: NSImage = {
        let symbol = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
        let image = symbol?.copy() as? NSImage ?? NSImage(size: NSSize(width: 16, height: 16))
        image.setName(identifier)
        return image
    }()

    // DocumentGroup supplies the shared controller. Install the default before SwiftUI starts,
    // then cover its concrete subclass at launch without instantiating a competing controller.
    static func useExplicitPlacement(on controller: NSDocumentController.Type) {
        _ = identifyStandardItems
        let getter = #selector(getter: NSDocumentController.allowsAutomaticShareMenu)
        guard let method = class_getInstanceMethod(controller, getter) else { return }
        class_replaceMethod(controller, getter, explicitPlacement, method_getTypeEncoding(method))
    }

    // The SwiftUI bridge may wrap the standard item in a new NSMenuItem. Mark both
    // public objects at their source so either identifier survives a shallow copy.
    private static let identifyStandardItems: Void = {
        let controller = NSDocumentController.self
        if let factory = class_getInstanceMethod(controller, #selector(NSDocumentController.standardShareMenuItem)),
            let tagged = class_getInstanceMethod(controller, #selector(NSDocumentController.surimonoStandardShareItem))
        {
            method_exchangeImplementations(factory, tagged)
        }
    }()

    private static let explicitPlacement: IMP = {
        let disabled: @convention(block) (NSDocumentController) -> Bool = { _ in false }
        return imp_implementationWithBlock(disabled)
    }()

    private final class Binding {
        let standard: NSMenuItem
        let submenu: NSMenu

        init?(replacing previous: NSMenu?) {
            standard = NSDocumentController.shared.standardShareMenuItem()
            guard let submenu = standard.submenu, submenu !== previous, submenu.supermenu == nil else { return nil }
            self.submenu = submenu
            standard.submenu = nil
        }
    }

    private static var bindingKey: UInt8 = 0
    private static let standardDelegate = NSDocumentController.shared.standardShareMenuItem().submenu?.delegate
    fileprivate static let factoryDelegates = NSHashTable<AnyObject>(options: [.weakMemory, .objectPointerPersonality])

    static func isInstalled(on item: NSMenuItem) -> Bool {
        guard let binding = objc_getAssociatedObject(item, &bindingKey) as? Binding else { return false }
        return item.submenu === binding.submenu
    }

    private let suppressed = NSHashTable<NSMenuItem>.weakObjects()
    private let lastHidden = NSHashTable<NSMenuItem>.weakObjects()
    private let collapsed = NSHashTable<NSMenuItem>.weakObjects()
    private var inspecting: NSMenuItem?
    private var adjustingSeparators = false

    func bind(_ item: NSMenuItem) {
        guard item !== inspecting else { return }
        let existing = objc_getAssociatedObject(item, &Self.bindingKey) as? Binding
        guard existing != nil || item.submenu != nil || item.identifier == Self.systemIdentifier else { return }
        let previous = inspecting
        inspecting = item
        defer { inspecting = previous }

        // A system row may have the same title, action, SwiftUI class and even the same
        // AppKit delegate. Only an identifier from the declaration can claim a new header.
        if let existing, item.submenu === existing.submenu { return }
        let native =
            item.identifier == Self.systemIdentifier || item.submenu?.identifier == Self.systemIdentifier
            || item.submenu?.delegate.map { $0 === Self.standardDelegate || Self.factoryDelegates.contains($0) } == true
        let marked =
            existing != nil || item.accessibilityIdentifier() == Self.identifier || hasDeclaredGlyph(item)
            || (!native && item.submenu?.numberOfItems == 1 && item.submenu?.item(at: 0).map(hasDeclaredGlyph) == true)
        if marked {
            // SwiftUI detaches a named submenu before moving it to a new header. The
            // detach notifies synchronously. Leave that instance free for its new owner.
            guard let binding = Binding(replacing: existing?.submenu) else { return }
            objc_setAssociatedObject(item, &Self.bindingKey, binding, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            item.submenu = binding.submenu
            if suppressed.contains(item) {
                suppressed.remove(item)
                item.isHidden = false
            }
        } else if native {
            suppressed.add(item)
            if !item.isHidden { item.isHidden = true }
        }
    }

    private func hasDeclaredGlyph(_ item: NSMenuItem) -> Bool {
        // The caller guards reentry: an AppKit image read can post an item-change notification.
        guard let image = item.image else { return false }
        return image === Self.glyph || image.name() == Self.identifier
    }

    func fileChanged(_ file: NSMenu, at index: Int, notification: Notification.Name) {
        if notification != NSMenu.didRemoveItemNotification, (0..<file.numberOfItems).contains(index),
            let item = file.item(at: index)
        {
            let wasInstalled = Self.isInstalled(on: item)
            bind(item)
            // Changing a key equivalent or enabled state doesn't change the neighboring groups.
            if notification == NSMenu.didChangeItemNotification,
                lastHidden.contains(item) == item.isHidden, wasInstalled == Self.isInstalled(on: item)
            {
                return
            }
        }
        updateSeparators(in: file)
    }

    /// Hidden commands don't separate groups. Restore a separator we collapsed if a
    /// subsequent SwiftUI rebuild puts a visible command between the two separators.
    func updateSeparators(in file: NSMenu) {
        guard !adjustingSeparators else { return }
        adjustingSeparators = true
        defer { adjustingSeparators = false }
        var touchesShare = false
        var separators: [NSMenuItem] = []
        func finishRun(beforeShare: Bool) {
            for (index, separator) in separators.enumerated() {
                let redundant = index > 0 && (touchesShare || beforeShare)
                if redundant && !separator.isHidden {
                    collapsed.add(separator)
                    separator.isHidden = true
                } else if !redundant && collapsed.contains(separator) {
                    collapsed.remove(separator)
                    separator.isHidden = false
                }
            }
            touchesShare = beforeShare
            separators.removeAll(keepingCapacity: true)
        }
        for item in file.items {
            if item.isSeparatorItem {
                if !item.isHidden || collapsed.contains(item) { separators.append(item) }
            } else if item.isHidden {
                if suppressed.contains(item) { touchesShare = true }
            } else {
                finishRun(beforeShare: Self.isInstalled(on: item))
            }
        }
        finishRun(beforeShare: false)
        for item in file.items {
            if item.isHidden { lastHidden.add(item) } else { lastHidden.remove(item) }
        }
    }
}

extension NSDocumentController {
    @objc fileprivate dynamic func surimonoStandardShareItem() -> NSMenuItem {
        let item = surimonoStandardShareItem()
        if item.identifier == nil { item.identifier = DocumentShareMenu.systemIdentifier }
        if let menu = item.submenu {
            if menu.identifier == nil { menu.identifier = DocumentShareMenu.systemIdentifier }
            // A wrapper may keep the actual sharing delegate but neither identifier.
            if let delegate = menu.delegate { DocumentShareMenu.factoryDelegates.add(delegate) }
        }
        return item
    }
}
