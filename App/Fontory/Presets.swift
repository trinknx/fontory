import Foundation

/// A saved preview text.
struct Preset: Codable, Hashable, Identifiable, Sendable {
    var name: String
    var text: String
    var id: String { name }
}

/// Reads and writes `presets.json` (`[{name, text}]`).
struct PresetStore: Sendable {
    let url: URL

    func load() -> [Preset] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Preset].self, from: data)) ?? []
    }

    func save(_ presets: [Preset]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(presets).write(to: url, options: .atomic)
    }

    /// Adds `preset`, replacing any preset with the same name.
    static func upserting(_ preset: Preset, into presets: [Preset]) -> [Preset] {
        var out = presets.filter { $0.name != preset.name }
        out.append(preset)
        return out
    }
}
