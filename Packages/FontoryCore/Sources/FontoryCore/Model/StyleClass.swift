import Foundation

/// Coarse design class of a face, shown as a sidebar group and matched by `#serif`-style search terms.
/// Raw values are stored in `faces.style_class`.
public enum StyleClass: Int, Sendable, CaseIterable, Codable, Hashable {
    case unknown = 0, serif, sans, slab, script, mono, display, symbol

    public var title: String {
        switch self {
        case .unknown: "Unknown"
        case .serif: "Serif"
        case .sans: "Sans"
        case .slab: "Slab"
        case .script: "Script"
        case .mono: "Mono"
        case .display: "Display"
        case .symbol: "Symbol"
        }
    }

    public static let browsable: [StyleClass] = [.serif, .sans, .slab, .script, .mono, .display, .symbol]
}
