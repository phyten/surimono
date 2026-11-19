import AppKit
import Observation
import SwiftUI

/// AppKit windows and independently hosted SwiftUI panels need the same live display settings.
@MainActor @Observable
final class DisplayAccessibility {
    nonisolated struct Options: Equatable, Sendable {
        var increasedContrast: Bool
        var reduceTransparency: Bool

        /// Blend against the intended surface before drawing so nothing behind the panel can show through.
        func fill(_ color: Color, opacity: Double, over surface: Color) -> Color {
            reduceTransparency ? surface.mix(with: color, by: opacity) : color.opacity(opacity)
        }
    }

    static let shared = DisplayAccessibility(center: NSWorkspace.shared.notificationCenter, read: read)
    private(set) var options: Options
    private let center: NotificationCenter
    @ObservationIgnored private var observer: NSObjectProtocol?

    init(center: NotificationCenter, read: @escaping @MainActor () -> Options) {
        self.center = center
        options = read()
        observer = center.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                let current = read()
                if self?.options != current { self?.options = current }
            }
        }
    }

    isolated deinit {
        if let observer { center.removeObserver(observer) }
    }

    private static func read() -> Options {
        let workspace = NSWorkspace.shared
        var options = Options(
            increasedContrast: workspace.accessibilityDisplayShouldIncreaseContrast,
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency)
        #if DEBUG
            if let value = DebugSnapshot.argument("SurimonoIncreaseContrast") {
                options.increasedContrast = (value as NSString).boolValue
            }
            if let value = DebugSnapshot.argument("SurimonoReduceTransparency") {
                options.reduceTransparency = (value as NSString).boolValue
            }
        #endif
        return options
    }

    func applyAppearance(_ appearance: NSAppearance?, to application: NSApplication) {
        if let appearance {
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            application.appearance =
                options.increasedContrast
                ? NSAppearance(named: dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
                : appearance
        } else {
            application.appearance = nil
            #if DEBUG
                // A screenshot can exercise the native controls even when the host uses standard contrast.
                if options.increasedContrast != NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
                    let dark = application.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    application.appearance = NSAppearance(
                        named: options.increasedContrast
                            ? (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
                            : (dark ? .darkAqua : .aqua))
                }
            #endif
        }
    }

    static func focusColor(onSelectedControl selected: Bool = false) -> Color {
        let options = shared.options
        if selected && (options.increasedContrast || options.reduceTransparency) { return .white }
        return options.increasedContrast || options.reduceTransparency
            ? PrintPalette.ink2 : Color(nsColor: .keyboardFocusIndicatorColor)
    }

    /// The chosen system accent can be too light for AppKit's white selected text.
    nonisolated static func selectionInk(on ground: Color.Resolved) -> Color {
        let luminance = 0.2126 * ground.linearRed + 0.7152 * ground.linearGreen + 0.0722 * ground.linearBlue
        return 1.05 / (luminance + 0.05) >= 4.5 ? .white : .black
    }

    static var hairline: CGFloat { shared.options.increasedContrast ? 1 : 0.5 }
}

extension View {
    /// Icon-only chips cannot carry a text underline.
    func selectionRule(_ active: Bool, color: Color = PrintPalette.ai) -> some View {
        overlay(alignment: .bottom) {
            if active && DisplayAccessibility.shared.options.increasedContrast {
                Rectangle().fill(color).frame(width: 10, height: 2).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }

    /// A change in line weight or an underline remains visible when the accent and background look alike.
    func emphasisForDisplayContrast(_ active: Bool) -> some View {
        underline(active && DisplayAccessibility.shared.options.increasedContrast)
    }
}
