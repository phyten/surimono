import CoreGraphics

enum SettingsWindowPlacement {
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

    static func frame(in visible: CGRect, savedContentSize: CGSize?, chrome: CGSize) -> CGRect {
        let content = savedContentSize ?? defaultContentSize
        let margin: CGFloat = 12
        func extent(_ preferred: CGFloat, minimum: CGFloat, available: CGFloat, decoration: CGFloat) -> CGFloat {
            max(minimum + decoration, min(preferred + decoration, available - 2 * margin))
        }
        let width = extent(
            content.width, minimum: minimumContentSize.width, available: visible.width, decoration: chrome.width)
        let height = extent(
            content.height, minimum: minimumContentSize.height, available: visible.height, decoration: chrome.height)
        return CGRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height)
    }
}
