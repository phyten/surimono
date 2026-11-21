import Foundation

/// Text font resources shared by WebKit's CSS aliases and the native PDF page furniture.
/// Keep the CTAN filenames so each face can be verified against the unmodified OFL distribution.
package enum ComputerModernFamily: String, CaseIterable {
    case roman = "Surimono Computer Modern"
    case typewriter = "Surimono Computer Modern Typewriter"
    case sans = "Surimono Computer Modern Sans"

    package var faces: [(file: String, weight: String, style: String)] {
        switch self {
        case .roman:
            [
                ("cmunrm", "normal", "normal"), ("cmunbx", "bold", "normal"),
                ("cmunti", "normal", "italic"), ("cmunbi", "bold", "italic"),
                ("cmunsl", "normal", "oblique"), ("cmunbl", "bold", "oblique"),
            ]
        case .typewriter:
            [
                ("cmuntt", "normal", "normal"), ("cmuntb", "bold", "normal"),
                ("cmunit", "normal", "italic"), ("cmuntx", "bold", "italic"), ("cmunst", "normal", "oblique"),
            ]
        case .sans:
            [
                ("cmunss", "normal", "normal"), ("cmunsx", "bold", "normal"),
                ("cmunsi", "normal", "oblique"), ("cmunso", "bold", "oblique"),
            ]
        }
    }

    package static func data(for file: String) -> Data? {
        Bundle.module.url(forResource: file, withExtension: "otf").flatMap { try? Data(contentsOf: $0) }
    }
}
