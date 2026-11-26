import CoreGraphics

struct SettingsWindowPlacement {
    static let minimumContentSize = CGSize(width: 820, height: 540)
    // The sidebar and scroll bar leave at least 760 pt for the editor's two-column layout.
    static let defaultContentSize = CGSize(width: 1040, height: 760)

    static func screen<Screen>(
        key: Screen?, screens: [Screen], pointer: CGPoint, frame: (Screen) -> CGRect
    ) -> Screen? {
        key ?? screens.first { frame($0).contains(pointer) } ?? screens.first
    }

    static func needsPlacement(isVisible: Bool, isMiniaturized: Bool, onActiveSpace: Bool, onTargetScreen: Bool) -> Bool
    {
        !isVisible || isMiniaturized || !onActiveSpace || !onTargetScreen
    }

    let frame: CGRect
    let contentMinimum: CGSize

    init(in visible: CGRect, savedContentSize: CGSize?, chrome: CGSize) {
        let preferred = savedContentSize ?? Self.defaultContentSize
        let margin: CGFloat = 12
        let limit = CGSize(width: max(0, visible.width - 2 * margin), height: max(0, visible.height - 2 * margin))
        contentMinimum = CGSize(
            width: min(Self.minimumContentSize.width, max(0, limit.width - chrome.width)),
            height: min(Self.minimumContentSize.height, max(0, limit.height - chrome.height)))
        let width = min(limit.width, max(preferred.width, contentMinimum.width) + chrome.width)
        let height = min(limit.height, max(preferred.height, contentMinimum.height) + chrome.height)
        frame = CGRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height)
    }
}
