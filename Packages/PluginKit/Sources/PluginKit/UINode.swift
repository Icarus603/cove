import Foundation

/// A declarative view a plugin sends to be drawn in its tab.
public indirect enum UINode: Equatable, Sendable {
    public enum TextStyle: String, Sendable { case title, body, caption, mono }
    public enum Tint: String, Sendable { case primary, secondary, red, green, yellow, blue, orange, pink }

    case vstack(spacing: Double, children: [UINode])
    case hstack(spacing: Double, children: [UINode])
    case text(String, style: TextStyle, tint: Tint)
    case symbol(String, size: Double, tint: Tint)
    case button(id: String, title: String, symbol: String?)
    case progress(value: Double, label: String?)
    case spacer
    case divider
}

extension UINode: Decodable {
    private enum Keys: String, CodingKey {
        case type, spacing, children, text, style, color, name, size, id, title, symbol, value, label
    }

    /// Nesting past this is refused, so a hostile plugin cannot exhaust the stack.
    static let maxDepth = 24
    static let maxChildren = 200

    public init(from decoder: Decoder) throws {
        let depth = decoder.codingPath.count / 2
        guard depth <= Self.maxDepth else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "view nested too deeply"))
        }
        let c = try decoder.container(keyedBy: Keys.self)
        let tint = try c.decodeIfPresent(String.self, forKey: .color).flatMap(Tint.init(rawValue:)) ?? .primary
        switch try c.decode(String.self, forKey: .type) {
        case "vstack", "hstack":
            let children = try c.decodeIfPresent([UINode].self, forKey: .children) ?? []
            guard children.count <= Self.maxChildren else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "too many children"))
            }
            let spacing = try c.decodeIfPresent(Double.self, forKey: .spacing) ?? 6
            let isV = try c.decode(String.self, forKey: .type) == "vstack"
            self = isV ? .vstack(spacing: spacing, children: children) : .hstack(spacing: spacing, children: children)
        case "text":
            let style = try c.decodeIfPresent(String.self, forKey: .style).flatMap(TextStyle.init(rawValue:)) ?? .body
            self = .text(try c.decode(String.self, forKey: .text), style: style, tint: tint)
        case "symbol":
            self = .symbol(try c.decode(String.self, forKey: .name), size: try c.decodeIfPresent(Double.self, forKey: .size) ?? 14, tint: tint)
        case "button":
            self = .button(id: try c.decode(String.self, forKey: .id), title: try c.decode(String.self, forKey: .title),
                           symbol: try c.decodeIfPresent(String.self, forKey: .symbol))
        case "progress":
            self = .progress(value: min(max(try c.decode(Double.self, forKey: .value), 0), 1),
                             label: try c.decodeIfPresent(String.self, forKey: .label))
        case "spacer": self = .spacer
        case "divider": self = .divider
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown view type \(other)")
        }
    }
}
