import Foundation

/// Les dernières dictées, la plus récente en tête, pour les recoller depuis le menu quand
/// le collage est parti ailleurs (clic hors du champ). Gardées en mémoire seulement :
/// rien n'est écrit sur le disque, tout disparaît en quittant VoxFlow.
public struct DictationHistory {
    public let capacity: Int
    public private(set) var items: [String] = []

    public init(capacity: Int = 5) {
        self.capacity = capacity
    }

    public mutating func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.removeAll { $0 == text }
        items.insert(text, at: 0)
        if items.count > capacity { items.removeLast(items.count - capacity) }
    }

    /// Titre d'une ligne de menu : une seule ligne, coupée à `limit` caractères.
    public static func menuTitle(_ text: String, limit: Int = 60) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }
}
