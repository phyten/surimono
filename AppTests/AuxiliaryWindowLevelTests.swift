import AppKit
import Testing

@testable import Surimono

@MainActor
struct AuxiliaryWindowLevelTests {
    private func window() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
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

    @Test("すべての操作スペースを切り替えるとフルスクリーンの役割だけが入れ替わる")
    func documentSpaces() {
        let document = window()
        defer { document.close() }
        document.collectionBehavior = [.fullScreenPrimary, .moveToActiveSpace, .participatesInCycle]
        ViewerWindow.setShowsOnAllSpaces(true, in: document)
        #expect(document.collectionBehavior == [.canJoinAllSpaces, .fullScreenAuxiliary, .participatesInCycle])
        ViewerWindow.setShowsOnAllSpaces(false, in: document)
        #expect(document.collectionBehavior == [.fullScreenPrimary, .moveToActiveSpace, .participatesInCycle])
    }

    @Test("補助の窓は文書の操作スペースに従い、解除後は元の役割に戻る")
    func auxiliarySpaces() {
        let coordinator = AuxiliaryWindowLevel(observesNotifications: false)
        let document = window()
        let auxiliary = window()
        defer {
            document.close()
            auxiliary.close()
        }
        coordinator.registerDocument(document)
        auxiliary.collectionBehavior = [.moveToActiveSpace, .fullScreenNone, .ignoresCycle]
        document.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        document.orderFront(nil)
        coordinator.refresh(windows: [auxiliary], presenting: auxiliary)
        #expect(!auxiliary.isVisible)
        #expect(auxiliary.collectionBehavior == [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle])
        auxiliary.orderFront(nil)
        coordinator.refresh(windows: [document, auxiliary])
        #expect(auxiliary.collectionBehavior == [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle])
        document.collectionBehavior = [.fullScreenPrimary]
        coordinator.refresh(windows: [document, auxiliary])
        #expect(auxiliary.collectionBehavior == [.moveToActiveSpace, .fullScreenNone, .ignoresCycle])
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
