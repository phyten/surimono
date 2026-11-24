import SurimonoCore
import SwiftUI

extension DocumentViewModel {
    /// SwiftUI can deliver a control or layout callback after the view has left its window.
    func windowAction<Value>(_ action: @escaping (DocumentViewModel, Value) -> Void)
        -> @MainActor @Sendable (Value) -> Void
    {
        { [weak self] value in
            guard let self, !isWindowClosed else { return }
            action(self, value)
        }
    }

    /// A native control may keep its selection after the window closes. Keep only its displayed value
    /// in that case. Accessors receive the live model so neither closure has to capture it.
    func controlBinding<Value>(
        get: @escaping (DocumentViewModel) -> Value, set: @escaping (DocumentViewModel, Value) -> Void
    ) -> Binding<Value> {
        let initialValue = get(self)
        return Binding(
            get: { [weak self] in self.map(get) ?? initialValue },
            set: windowAction(set))
    }

    func controlBinding<Value>(_ path: ReferenceWritableKeyPath<DocumentViewModel, Value>) -> Binding<Value> {
        controlBinding(get: { $0[keyPath: path] }, set: { $0[keyPath: path] = $1 })
    }

    /// A change made by this control overrides the initial view options.
    func viewOption<Value>(_ path: WritableKeyPath<ViewOptions, Value>) -> Binding<Value> {
        controlBinding(
            get: { $0.viewOptions[keyPath: path] },
            set: { model, value in model.updateViewOptions { $0[keyPath: path] = value } })
    }
}
