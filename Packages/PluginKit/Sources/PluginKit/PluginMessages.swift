import Foundation
import NotchKit

/// Current wire protocol version, sent to plugins in `hello`.
public let pluginProtocolVersion = 1

/// One line of JSON from a plugin's stdout.
public enum PluginMessage: Equatable, Sendable {
    case ready
    case render(UINode)
    case attention(ModuleAttention)
    case accessory(symbol: String, text: String?)

    /// Longest line accepted; a plugin that never ends a line cannot grow memory without bound.
    public static let maxLineBytes = 256 * 1024

    public static func parse(line: Data) -> PluginMessage? {
        guard line.count <= maxLineBytes,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "ready":
            return .ready
        case "render":
            guard let root = object["root"],
                  let data = try? JSONSerialization.data(withJSONObject: root),
                  let node = try? JSONDecoder().decode(UINode.self, from: data) else { return nil }
            return .render(node)
        case "attention":
            switch object["level"] as? String {
            case "none": return .attention(.none)
            case "active": return .attention(.active)
            case "needsInput": return .attention(.needsInput)
            default: return nil
            }
        case "accessory":
            guard let symbol = object["symbol"] as? String else { return nil }
            return .accessory(symbol: symbol, text: object["text"] as? String)
        default:
            return nil
        }
    }
}

/// Messages the host writes to a plugin's stdin, one JSON object per line.
public enum HostMessage: Equatable, Sendable {
    case hello(locale: String)
    case activate
    case deactivate
    case action(id: String)

    public func encoded() -> Data {
        var object: [String: Any]
        switch self {
        case .hello(let locale): object = ["type": "hello", "protocol": pluginProtocolVersion, "locale": locale]
        case .activate: object = ["type": "activate"]
        case .deactivate: object = ["type": "deactivate"]
        case .action(let id): object = ["type": "action", "id": id]
        }
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        data.append(0x0A)
        return data
    }
}

/// Splits a byte stream into newline-terminated lines, dropping overlong ones.
struct LineBuffer {
    private var pending = Data()
    private var discarding = false

    mutating func append(_ chunk: Data) -> [Data] {
        var lines: [Data] = []
        for byte in chunk {
            if byte == 0x0A {
                if !discarding, !pending.isEmpty { lines.append(pending) }
                pending.removeAll(keepingCapacity: true)
                discarding = false
            } else if !discarding {
                pending.append(byte)
                if pending.count > PluginMessage.maxLineBytes {
                    pending.removeAll()
                    discarding = true
                }
            }
        }
        return lines
    }
}
