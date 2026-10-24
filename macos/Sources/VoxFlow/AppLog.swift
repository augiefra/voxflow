import Foundation
import VoxFlowCore

/// Journal texte de l'app : ~/.voxflow/app.log (appuis Fn, apprentissages).
enum AppLog {
    private static let queue = DispatchQueue(label: "voxflow.log")
    static let url = DaemonManager.dataDirectory.appendingPathComponent("app.log")
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    /// Attend les lignes en cours d'écriture (avant de quitter).
    static func flush() {
        queue.sync {}
    }

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url)
            }
        }
    }
}
