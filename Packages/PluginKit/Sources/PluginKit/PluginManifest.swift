import Foundation

/// `manifest.json` at the root of a plugin folder.
///
/// ```json
/// { "id": "com.example.clock", "name": { "default": "Clock", "zh-Hant": "時鐘" },
///   "symbol": "clock", "executable": "run.sh", "arguments": [], "order": 200 }
/// ```
public struct PluginManifest: Decodable, Equatable, Sendable {
    public struct LocalizedName: Decodable, Equatable, Sendable {
        public let values: [String: String]

        public init(values: [String: String]) { self.values = values }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let plain = try? container.decode(String.self) {
                values = ["default": plain]
            } else {
                values = try container.decode([String: String].self)
            }
        }

        /// Picks the best entry for a BCP-47 style language id such as "zh-Hant-TW".
        public func resolve(for language: String) -> String {
            var candidate = language
            while !candidate.isEmpty {
                if let value = values[candidate] { return value }
                guard let dash = candidate.lastIndex(of: "-") else { break }
                candidate = String(candidate[..<dash])
            }
            return values["default"] ?? values["en"] ?? values.values.sorted().first ?? ""
        }
    }

    public let id: String
    public let name: LocalizedName
    public let symbol: String
    public let executable: String
    public let arguments: [String]
    public let order: Int

    enum CodingKeys: String, CodingKey { case id, name, symbol, executable, arguments, order }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(LocalizedName.self, forKey: .name)
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "puzzlepiece.extension"
        executable = try c.decode(String.self, forKey: .executable)
        arguments = try c.decodeIfPresent([String].self, forKey: .arguments) ?? []
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 200
        guard Self.isValidID(id) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "id may only use letters, digits, '.', '-' and '_'")
        }
        guard !executable.hasPrefix("/"), !executable.contains("..") else {
            throw DecodingError.dataCorruptedError(forKey: .executable, in: c, debugDescription: "executable must be a path inside the plugin folder")
        }
    }

    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 80 && id.allSatisfy { $0.isLetter || $0.isNumber || ".-_".contains($0) }
    }
}
