import Foundation

public struct DictationResult: Decodable, Equatable {
    public let raw: String
    public let text: String
    public let lexiconTerms: [String]?
    public let timings: [String: Double]?

    enum CodingKeys: String, CodingKey {
        case raw, text, timings
        case lexiconTerms = "lexicon_terms"
    }
}

public enum InferenceError: Error, LocalizedError {
    case missingToken
    case server(String)
    case timeout
    case disconnected(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken: return L10n.tr("error.notReady")
        case let .server(message): return L10n.tr("error.engine", message)
        case .timeout: return L10n.tr("error.timeout")
        case let .disconnected(message): return L10n.tr("error.unreachable", message)
        }
    }
}

/// Client WebSocket du démon : l'audio part pendant la dictée, la transcription
/// Voxtral avance en parallèle, et seul le nettoyage reste à faire à l'arrêt.
public final class InferenceClient {
    public static var tokenURL: URL {
        VoxFlowPaths.dataDirectory.appendingPathComponent("token")
    }

    public let port: Int
    public let tokenFile: URL
    /// Texte partiel (thread principal).
    public var onPartial: ((String) -> Void)?

    private let queue = DispatchQueue(label: "voxflow.inference")
    private let session = URLSession(configuration: .ephemeral)
    private var task: URLSessionWebSocketTask?
    private var pendingFinal: ((Result<DictationResult, Error>) -> Void)?
    private var sessionError: String?
    private var timeoutWork: DispatchWorkItem?
    private var sentSamples = 0

    public init(port: Int = 8765, tokenFile: URL = InferenceClient.tokenURL) {
        self.port = port
        self.tokenFile = tokenFile
    }

    /// État du démon via GET /health, ou nil s'il ne répond pas (thread principal).
    public func health(_ completion: @escaping (DaemonHealth?) -> Void) {
        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        session.dataTask(with: request) { data, _, _ in
            let health = data.flatMap { try? JSONDecoder().decode(DaemonHealth.self, from: $0) }
            DispatchQueue.main.async { completion(health) }
        }.resume()
    }

    /// Ouvre une dictée. L'audio peut être envoyé immédiatement : le démon traite les
    /// messages dans l'ordre et ne reçoit l'audio qu'une fois la session créée.
    public func begin(bundleID: String) {
        queue.async { [self] in
            sessionError = nil
            sentSamples = 0
            guard let socket = connectedTask() else {
                sessionError = InferenceError.missingToken.localizedDescription
                return
            }
            let start: [String: Any] = ["type": "start", "bundle_id": bundleID, "sample_rate": Int(AudioCapture.sampleRate)]
            send(json: start, on: socket)
        }
    }

    /// Thread-safe : appelé depuis le thread audio.
    public func sendAudio(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) } // Float32 little-endian sur Apple Silicon
        queue.async { [self] in
            guard let task, sessionError == nil else { return }
            sentSamples += samples.count
            task.send(.data(data)) { [weak self] error in
                if let error { self?.fail(.disconnected(error.localizedDescription)) }
            }
        }
    }

    /// Termine la dictée et attend la transcription nettoyée (thread principal).
    public func finish(_ completion: @escaping (Result<DictationResult, Error>) -> Void) {
        queue.async { [self] in
            let deliver: (Result<DictationResult, Error>) -> Void = { result in
                DispatchQueue.main.async { completion(result) }
            }
            if let sessionError {
                deliver(.failure(InferenceError.server(sessionError)))
                return
            }
            guard let task else {
                deliver(.failure(InferenceError.missingToken))
                return
            }
            pendingFinal = deliver
            send(json: ["type": "stop"], on: task)
            // Marge pour le LLM : 20 s + 1 s par tranche de 4 s d'audio.
            let audioSeconds = Double(sentSamples) / AudioCapture.sampleRate
            let work = DispatchWorkItem { [weak self] in self?.fail(.timeout) }
            timeoutWork = work
            queue.asyncAfter(deadline: .now() + 20 + audioSeconds / 4, execute: work)
        }
    }

    public func cancel() {
        queue.async { [self] in
            if let task { send(json: ["type": "cancel"], on: task) }
            pendingFinal = nil
            timeoutWork?.cancel()
        }
    }

    // MARK: Interne (file `queue`)

    private func connectedTask() -> URLSessionWebSocketTask? {
        if let task, task.state == .running { return task }
        guard let token = try? String(contentsOf: tokenFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return nil }
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/v1/dictation")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 4 * 1024 * 1024
        task = socket
        socket.resume()
        receive(on: socket)
        return socket
    }

    private func receive(on socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                switch result {
                case let .success(message):
                    if case let .string(text) = message { self.handle(text) }
                    self.receive(on: socket)
                case let .failure(error):
                    if self.task === socket { self.task = nil }
                    self.fail(.disconnected(error.localizedDescription))
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }
        switch type {
        case "partial":
            if let partial = json["text"] as? String, let onPartial {
                DispatchQueue.main.async { onPartial(partial) }
            }
        case "final":
            timeoutWork?.cancel()
            let result = Result { try JSONDecoder().decode(DictationResult.self, from: data) }
            pendingFinal?(result.mapError { $0 as Error })
            pendingFinal = nil
        case "error":
            let message = json["message"] as? String ?? "?"
            if pendingFinal != nil { fail(.server(message)) } else { sessionError = message }
        default:
            break // "ready", "cancelled"
        }
    }

    private func fail(_ error: InferenceError) {
        queue.async { [self] in
            timeoutWork?.cancel()
            if let pendingFinal {
                pendingFinal(.failure(error))
                self.pendingFinal = nil
            } else if sessionError == nil {
                sessionError = error.localizedDescription
            }
        }
    }

    private func send(json: [String: Any], on socket: URLSessionWebSocketTask) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { [weak self] error in
            if let error { self?.fail(.disconnected(error.localizedDescription)) }
        }
    }
}
