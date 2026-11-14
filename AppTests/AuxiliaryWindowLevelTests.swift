import AppKit
import Testing

@testable import Surimono

@MainActor
struct AuxiliaryWindowLevelTests {
    private func window() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test("固定した文書がある間だけ補助の窓を上げ文書のレベルは変えない")
    func levels() {
        let coordinator = AuxiliaryWindowLevel(observesNotifications: false)
        let document = window()
        let auxiliary = window()
        defer {
            document.close()
            auxiliary.close()
        }
        coordinator.registerDocument(document)
        document.level = .floating
        auxiliary.orderFront(nil)
        document.orderFront(nil)
        coordinator.refresh(windows: [document, auxiliary])
        #expect(auxiliary.level == .floating)
        #expect(document.level == .floating)
        document.level = .normal
        coordinator.refresh(windows: [document, auxiliary])
        #expect(auxiliary.level == .normal)
        #expect(document.level == .normal)
    }

    @Test("パネルと子窓と非表示の窓と独自レベルの窓は昇格しない")
    func exclusions() {
        #expect(
            !AuxiliaryWindowLevel.shouldRaise(
                isDocument: true, isPanel: false, isVisible: true, isTitled: true, hasParent: false, level: .normal))
        #expect(
            !AuxiliaryWindowLevel.shouldRaise(
                isDocument: false, isPanel: true, isVisible: true, isTitled: true, hasParent: false, level: .normal))
        #expect(
            !AuxiliaryWindowLevel.shouldRaise(
                isDocument: false, isPanel: false, isVisible: false, isTitled: true, hasParent: false, level: .normal))
        #expect(
            !AuxiliaryWindowLevel.shouldRaise(
                isDocument: false, isPanel: false, isVisible: true, isTitled: false, hasParent: false, level: .normal))
        #expect(
            !AuxiliaryWindowLevel.shouldRaise(
                isDocument: false, isPanel: false, isVisible: true, isTitled: true, hasParent: true, level: .normal))
        #expect(
            !AuxiliaryWindowLevel.shouldRaise(
                isDocument: false, isPanel: false, isVisible: true, isTitled: true, hasParent: false, level: .floating))
    }
}
