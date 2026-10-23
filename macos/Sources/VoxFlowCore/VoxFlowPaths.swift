import Foundation

/// Emplacement unique des données de VoxFlow : ~/.voxflow (lexique, jeton, journaux,
/// environnement Python du démon).
public enum VoxFlowPaths {
    public static var dataDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".voxflow", isDirectory: true)
    }

    /// Dossier des premières versions de développement.
    public static var legacyDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".wispr_clone", isDirectory: true)
    }

    /// Copie le lexique appris et le jeton de l'ancien dossier, une seule fois.
    /// L'ancien dossier est laissé intact ; l'environnement Python est recréé par uv.
    @discardableResult
    public static func migrateLegacyDataIfNeeded(from legacy: URL = legacyDirectory, to target: URL = dataDirectory) -> [String] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: legacy.path),
              !manager.fileExists(atPath: target.appendingPathComponent("lexicon.db").path) else { return [] }
        try? manager.createDirectory(at: target, withIntermediateDirectories: true)
        var copied: [String] = []
        for name in ["lexicon.db", "lexicon.db-wal", "lexicon.db-shm", "token"] {
            let source = legacy.appendingPathComponent(name)
            let destination = target.appendingPathComponent(name)
            guard manager.fileExists(atPath: source.path), !manager.fileExists(atPath: destination.path) else { continue }
            if (try? manager.copyItem(at: source, to: destination)) != nil { copied.append(name) }
        }
        return copied
    }
}
