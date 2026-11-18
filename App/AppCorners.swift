import SwiftUI

nonisolated enum CornerPreset: String, CaseIterable {
    case square, standard, round

    var usesSystemControls: Bool { self == .standard }

    func radius(for role: CornerRole, shortestSide: CGFloat) -> CGFloat {
        switch self {
        case .square: min(role.rawValue / 6, 2)
        case .standard: role.rawValue
        case .round: max(role.rawValue, min(role.rawValue * 1.6, shortestSide * 0.4))
        }
    }
}

// Standard uses the original radius of each piece, including the nested controls in the toolbar editor.
nonisolated enum CornerRole: CGFloat, CaseIterable {
    case rule = 1
    case thumbnail = 2
    case tag = 3
    case segment = 3.5
    case badge = 4
    case segmentGroup = 4.5
    case smallControl = 5
    case control = 6
    case largeControl = 7
    case tile = 8
    case compactToast = 9
    case toast = 10
    case panel = 12
    case sheet = 14

    @MainActor var shape: AppCornerShape { AppCornerShape(role: self, preset: AppPreferences.shared.corners) }
}

nonisolated struct AppCornerShape: InsettableShape {
    let role: CornerRole?
    let preset: CornerPreset
    private let maximumRadius: CGFloat
    private var insetAmount: CGFloat = 0

    init(role: CornerRole?, preset: CornerPreset, maximumRadius: CGFloat = .infinity) {
        self.maximumRadius = maximumRadius
        self.role = role
        self.preset = preset
    }

    static func spreadFrame(preset: CornerPreset) -> Self {
        Self(role: .badge, preset: preset, maximumRadius: 6)
    }

    @MainActor static var capsule: Self { Self(role: nil, preset: AppPreferences.shared.corners) }

    nonisolated func path(in rect: CGRect) -> Path {
        if let role {
            let radius = preset.radius(for: role, shortestSide: min(rect.width, rect.height))
            return RoundedRectangle(cornerRadius: min(radius, maximumRadius)).inset(by: insetAmount).path(in: rect)
        }
        if preset == .square {
            return RoundedRectangle(cornerRadius: 2).inset(by: insetAmount).path(in: rect)
        }
        return Capsule().inset(by: insetAmount).path(in: rect)
    }

    nonisolated func inset(by amount: CGFloat) -> Self {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}
