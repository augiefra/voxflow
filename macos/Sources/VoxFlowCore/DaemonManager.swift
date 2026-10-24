import CryptoKit
import Foundation

/// Réponse de GET /health (voir daemon/model_store.py, `Progress.snapshot`).
/// Seul `status` est garanti : un démon 0.1.0 ne renvoie que `status` et `error`, et
/// `pid`, `mode` et `version` n'existent que depuis 0.1.1.
public struct DaemonHealth: Decodable, Equatable {
    public struct Model: Decodable, Equatable {
        public let id: String
        public let state: String
        public let done: Int64
        public let total: Int64
    }

    public struct Retry: Decodable, Equatable {
        public let code: String
        public let attempt: Int
        public let inS: Int

        enum CodingKeys: String, CodingKey {
            case code, attempt
            case inS = "in_s"
        }
    }

    public let status: String
    public var error: String?
    public var phase: String?
    public var model: String?
    public var bytesDone: Int64?
    public var bytesTotal: Int64?
    public var speedBps: Int64?
    public var etaS: Int?
    public var models: [Model]?
    public var errorCode: String?
    public var retryable: Bool?
    public var diskFreeBytes: Int64?
    public var diskNeededBytes: Int64?
    public var retry: Retry?
    public var pid: Int32?
    /// « full » ou « light ».
    public var mode: String?
    /// Version de l'app qui a lancé le démon (VOXFLOW_APP_VERSION), nil s'il a été lancé à la main.
    public var version: String?

    enum CodingKeys: String, CodingKey {
        case status, error, phase, model, models, retryable, retry, pid, mode, version
        case bytesDone = "bytes_done"
        case bytesTotal = "bytes_total"
        case speedBps = "speed_bps"
        case etaS = "eta_s"
        case errorCode = "error_code"
        case diskFreeBytes = "disk_free_bytes"
        case diskNeededBytes = "disk_needed_bytes"
    }
}

/// Erreur de préparation des moteurs, avec un code stable que l'interface traduit.
public struct EngineFailure: Error, Equatable {
    /// network, tls, disk_full, low_memory, unsupported_cpu, hub_unavailable, hub_refused,
    /// integrity, app_damaged, crashed, port_busy, unknown
    public let code: String
    public let detail: String
    public var retryable = true
    public var diskNeeded: Int64?
    public var diskFree: Int64?

    public init(code: String, detail: String, retryable: Bool = true, diskNeeded: Int64? = nil, diskFree: Int64? = nil) {
        self.code = code
        self.detail = detail
        self.retryable = retryable
        self.diskNeeded = diskNeeded
        self.diskFree = diskFree
    }
}

/// Suit la sortie de `uv sync` (lignes « Downloading x (12.2MiB) » puis « Downloaded x »).
public struct EnvironmentProgress {
    /// Taille approximative de Python et des paquets du démon (mesurée : ~150 Mo).
    public static let expectedBytes: Int64 = 160_000_000
    public private(set) var announced: [String: Int64] = [:]
    public private(set) var downloaded: Int64 = 0
    public private(set) var finished = false

    public init() {}

    public var fraction: Double {
        if finished { return 1 }
        let total = max(Self.expectedBytes, announced.values.reduce(0, +))
        return min(0.99, Double(downloaded) / Double(total))
    }

    public mutating func consume(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("Downloading "), let open = trimmed.lastIndex(of: "("), trimmed.hasSuffix(")") {
            let name = String(trimmed.dropFirst("Downloading ".count)[..<open]).trimmingCharacters(in: .whitespaces)
            let size = String(trimmed[trimmed.index(after: open)...].dropLast())
            announced[name] = Self.parseSize(size)
        } else if trimmed.hasPrefix("Downloaded ") {
            let name = String(trimmed.dropFirst("Downloaded ".count))
            downloaded += announced[name] ?? 0
        } else if trimmed.hasPrefix("Installed ") || trimmed.hasPrefix("Audited ") {
            finished = true
        }
    }

    static func parseSize(_ text: String) -> Int64 {
        let units: [(String, Double)] = [("GiB", 1_073_741_824), ("MiB", 1_048_576), ("KiB", 1024), ("B", 1)]
        for (unit, factor) in units where text.hasSuffix(unit) {
            let number = Double(text.dropLast(unit.count).trimmingCharacters(in: .whitespaces)) ?? 0
            return Int64(number * factor)
        }
        return 0
    }

    /// Classe l'échec d'après les dernières lignes de uv.
    public static func failure(from output: String) -> EngineFailure {
        let lower = output.lowercased()
        let lastLine = output.split(separator: "\n").last.map(String.init) ?? ""
        if lower.contains("no space left on device") {
            return EngineFailure(code: "disk_full", detail: lastLine)
        }
        let network = ["error sending request", "failed to fetch", "dns error", "failed to lookup", "could not connect",
                       "tcp connect error", "network is unreachable", "timed out", "connection refused",
                       "connection reset", "failed to download"]
        if network.contains(where: lower.contains) {
            return EngineFailure(code: "network", detail: lastLine)
        }
        return EngineFailure(code: "unknown", detail: lastLine)
    }
}

/// Prépare l'environnement Python du démon avec le uv embarqué, puis lance le démon.
///
/// Tout vit dans ~/.voxflow (Python, cache uv, venv, modèles) : rien dans ~/.local,
/// et `rm -rf ~/.voxflow` désinstalle tout.
public final class DaemonManager {
    public let daemonDirectory: URL?
    public let port: Int
    /// Appelé sur le thread principal quand le démon s'arrête (code de sortie).
    public var onExit: ((Int32) -> Void)?
    private var process: Process?
    private var setupProcess: Process?
    /// Demandes en attente de la préparation en cours (une seule préparation à la fois).
    private var setupWaiters: [(progress: (Double) -> Void, completion: (Result<Void, EngineFailure>) -> Void)] = []

    public static var dataDirectory: URL { VoxFlowPaths.dataDirectory }
    static var venvDirectory: URL { dataDirectory.appendingPathComponent("venv", isDirectory: true) }
    static var readyMarker: URL { venvDirectory.appendingPathComponent(".voxflow-ready") }
    public static var logURL: URL { dataDirectory.appendingPathComponent("daemon.log") }

    public init(daemonDirectory: URL?, port: Int = 8765) {
        self.daemonDirectory = daemonDirectory
        self.port = port
    }

    public var isManagingProcess: Bool { process?.isRunning == true }
    public var isPreparing: Bool { setupProcess?.isRunning == true }

    /// uv embarqué (Contents/Helpers/uv), sinon VOXFLOW_UV ou un uv installé (développement).
    public static func findUV() -> URL? {
        let fileManager = FileManager.default
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/uv")
        if fileManager.isExecutableFile(atPath: bundled.path) { return bundled }
        if let override = ProcessInfo.processInfo.environment["VOXFLOW_UV"], fileManager.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        let home = fileManager.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/uv", "/opt/homebrew/bin/uv", "/usr/local/bin/uv", "\(home)/.cargo/bin/uv"]
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    /// Environnement hermétique : ni la config uv ni le PATH de l'utilisateur n'interviennent.
    static func environment() -> [String: String] {
        let current = ProcessInfo.processInfo.environment
        let data = dataDirectory.path
        var env: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "UV_PYTHON_INSTALL_DIR": "\(data)/python",
            "UV_PYTHON_BIN_DIR": "\(data)/python/bin",
            "UV_CACHE_DIR": "\(data)/uv-cache",
            "UV_PROJECT_ENVIRONMENT": venvDirectory.path,
            "UV_PYTHON_PREFERENCE": "only-managed",
            "UV_NO_CONFIG": "1",
            "NO_COLOR": "1",
            "TERM": "dumb",
            "PYTHONUNBUFFERED": "1",
            "PYTHONIOENCODING": "utf-8",
            // Pas de PYTHONDONTWRITEBYTECODE : le cache .pyc du venv fait gagner ~3 s par
            // lancement. Le démon protège lui-même le bundle signé (import de model_store).
        ]
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            env["VOXFLOW_APP_VERSION"] = version
        }
        // Espace « disponible pour un usage important » (purgeable APFS compris), comme le
        // Finder et Réglages › Stockage ; statfs seul le sous-estime.
        if let available = try? dataDirectory.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage {
            env["VOXFLOW_DISK_AVAILABLE"] = String(available)
        }
        for (key, value) in current {
            let upper = key.uppercased()
            if ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG"].contains(key) || key.hasPrefix("HF_") || key.hasPrefix("VOXFLOW_")
                || upper.hasSuffix("_PROXY") || upper.hasPrefix("SSL_CERT_") {
                env[key] = value
            }
        }
        return env
    }

    /// Empreinte de uv.lock : un nouveau verrou impose de refaire l'environnement.
    private func lockDigest() -> String? {
        guard let lock = daemonDirectory?.appendingPathComponent("uv.lock"),
              let data = try? Data(contentsOf: lock) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public var isEnvironmentReady: Bool {
        guard let digest = lockDigest(),
              let marker = try? String(contentsOf: Self.readyMarker, encoding: .utf8) else { return false }
        return marker.trimmingCharacters(in: .whitespacesAndNewlines) == digest
            && FileManager.default.isExecutableFile(atPath: Self.venvDirectory.appendingPathComponent("bin/python").path)
    }

    public func invalidateEnvironment() {
        try? FileManager.default.removeItem(at: Self.readyMarker)
    }

    /// Télécharge Python 3.12 et les paquets du démon (~150 Mo, une fois). Rappels sur le
    /// thread principal. Pendant une préparation en cours, la demande attend sa fin.
    public func prepareEnvironment(progress: @escaping (Double) -> Void,
                                   completion: @escaping (Result<Void, EngineFailure>) -> Void) {
        setupWaiters.append((progress, completion))
        guard setupProcess == nil else { return }
        let completion: (Result<Void, EngineFailure>) -> Void = { [weak self] result in self?.finishSetup(result) }
        guard let daemonDirectory, let digest = lockDigest() else {
            return completion(.failure(EngineFailure(code: "app_damaged", detail: "daemon", retryable: false)))
        }
        guard let uv = Self.findUV() else {
            return completion(.failure(EngineFailure(code: "app_damaged", detail: "uv", retryable: false)))
        }
        let log: FileHandle
        do {
            log = try openLog()
        } catch {
            return completion(.failure(EngineFailure(code: "unknown", detail: error.localizedDescription)))
        }
        log.write(Data("\n== Préparation de Python (\(Date())) ==\n".utf8))

        let process = Process()
        process.executableURL = uv
        process.arguments = ["sync", "--frozen", "--python", "3.12", "--project", daemonDirectory.path, "--color", "never"]
        process.environment = Self.environment()
        process.currentDirectoryURL = Self.dataDirectory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        var parser = EnvironmentProgress()
        var buffer = ""
        var tail: [String] = []
        var logOpen = true
        let lock = NSLock()
        // Journal, analyse et fermeture sous le même verrou : rien ne s'écrit après close.
        let consume: (Data) -> Double = { data in
            lock.lock()
            defer { lock.unlock() }
            if logOpen { log.write(data) }
            buffer += String(decoding: data, as: UTF8.self)
            var lines = buffer.components(separatedBy: "\n")
            buffer = lines.removeLast()
            for line in lines where !line.isEmpty {
                parser.consume(line)
                tail = Array((tail + [line]).suffix(40))
            }
            return parser.fraction
        }
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let fraction = consume(data)
            DispatchQueue.main.async { self?.setupWaiters.forEach { $0.progress(fraction) } }
        }
        process.terminationHandler = { [weak self] finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            // Les dernières lignes de uv (celles de l'erreur) peuvent rester dans le tube.
            let rest = pipe.fileHandleForReading.readDataToEndOfFile()
            if !rest.isEmpty { _ = consume(rest) }
            lock.lock()
            let output = (tail + [buffer]).joined(separator: "\n")
            logOpen = false
            try? log.close()
            lock.unlock()
            let status = finished.terminationStatus
            if status == 0 { try? digest.write(to: Self.readyMarker, atomically: true, encoding: .utf8) }
            DispatchQueue.main.async {
                // Préparation abandonnée (stop) : ses demandes ont déjà été détachées.
                guard let self, self.setupProcess === finished else { return }
                self.setupProcess = nil
                self.finishSetup(status == 0 ? .success(()) : .failure(EnvironmentProgress.failure(from: output)))
            }
        }
        do {
            try process.run()
            setupProcess = process
        } catch {
            completion(.failure(EngineFailure(code: "app_damaged", detail: error.localizedDescription, retryable: false)))
        }
    }

    private func finishSetup(_ result: Result<Void, EngineFailure>) {
        let waiters = setupWaiters
        setupWaiters = []
        waiters.forEach { $0.completion(result) }
    }

    /// Lance le démon avec le Python du venv. `light` : transcription seule (sans Qwen).
    public func launch(light: Bool) throws {
        guard !isManagingProcess else { return }
        guard let daemonDirectory,
              FileManager.default.fileExists(atPath: daemonDirectory.appendingPathComponent("inference_daemon.py").path)
        else { throw EngineFailure(code: "app_damaged", detail: "daemon", retryable: false) }

        Self.compactLog()
        let log = try openLog()
        log.write(Data("\n== Démarrage du démon, mode \(light ? "léger" : "complet") (\(Date())) ==\n".utf8))
        let process = Process()
        process.executableURL = Self.venvDirectory.appendingPathComponent("bin/python")
        process.arguments = [daemonDirectory.appendingPathComponent("inference_daemon.py").path, "--port", String(port),
                             "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)]
            + (light ? ["--no-llm"] : [])
        process.environment = Self.environment()
        process.standardOutput = log
        process.standardError = log
        process.currentDirectoryURL = Self.dataDirectory
        // Sans cela, le démon d'une app de barre de menu hérite d'une priorité
        // d'arrière-plan (App Nap) qui bride le GPU.
        process.qualityOfService = .userInitiated
        process.terminationHandler = { [weak self] finished in
            try? log.close()
            DispatchQueue.main.async {
                guard let self, self.process === finished else { return }
                self.process = nil
                self.onExit?(finished.terminationStatus)
            }
        }
        try process.run()
        self.process = process
    }

    /// Arrête la préparation de Python et le démon ; `completion` une fois le port libéré.
    public func stop(then completion: (() -> Void)? = nil) {
        if let setupProcess {
            self.setupProcess = nil
            setupWaiters = []
            setupProcess.terminate()
        }
        stopDaemon(then: completion)
    }

    /// Arrête le démon seulement (la préparation de Python ne dépend pas du mode).
    /// `completion` sur le thread principal, une fois le processus terminé.
    public func stopDaemon(then completion: (() -> Void)? = nil) {
        guard let process, process.isRunning else {
            self.process = nil
            completion?()
            return
        }
        self.process = nil
        process.terminate()
        guard let completion else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            Self.waitForExit(of: process.processIdentifier, isRunning: { process.isRunning })
            DispatchQueue.main.async(execute: completion)
        }
    }

    /// Attend la fin d'un processus déjà prévenu (SIGTERM) ; SIGKILL au bout de 3 s.
    static func waitForExit(of pid: pid_t, isRunning: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while isRunning(), Date() < deadline { usleep(50000) }
        if isRunning() {
            kill(pid, SIGKILL)
            while isRunning() { usleep(20000) }
        }
    }

    /// Démon VoxFlow qui n'est pas le nôtre (autre version, autre mode, ancien démon sans
    /// `pid`) : on l'arrête pour libérer le port. Renvoie faux si le port est tenu par un
    /// autre programme. Bloquant : à appeler hors du thread principal.
    public func terminateForeignDaemon(pid knownPID: Int32?) -> Bool {
        let pids = knownPID.map { [$0] } ?? Self.listeningPIDs(port: port)
        let daemons = pids.filter { Self.command(of: $0).contains("inference_daemon.py") }
        guard !daemons.isEmpty else { return false }
        for pid in daemons {
            kill(pid, SIGTERM)
            Self.waitForExit(of: pid, isRunning: { kill(pid, 0) == 0 })
        }
        return true
    }

    static func listeningPIDs(port: Int) -> [Int32] {
        run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"])
            .split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    static func command(of pid: Int32) -> String {
        run("/bin/ps", ["-o", "command=", "-p", String(pid)])
    }

    private static func run(_ tool: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func openLog() throws -> FileHandle {
        try FileManager.default.createDirectory(at: Self.dataDirectory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: Self.logURL.path) {
            FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: Self.logURL)
        handle.seekToEndOfFile()
        return handle
    }

    /// Dernières lignes du journal, pour « Copier le journal ». Le texte dicté que les
    /// versions précédentes y écrivaient est masqué : le journal peut finir sur GitHub.
    public static func logTail(maxBytes: Int = 64 * 1024) -> String {
        redactDictations(rawTail(maxBytes: maxBytes).text)
    }

    private static func rawTail(maxBytes: Int) -> (text: String, truncated: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return ("", false) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let truncated = size > UInt64(maxBytes)
        try? handle.seek(toOffset: truncated ? size - UInt64(maxBytes) : 0)
        return (String(decoding: handle.readDataToEndOfFile(), as: UTF8.self), truncated)
    }

    /// Le journal n'avait pas de rotation et la 0.1.0 y écrivait le texte dicté : à chaque
    /// lancement du démon, on n'en garde que le dernier Mo, texte masqué.
    static func compactLog(keeping maxBytes: Int = 1 << 20) {
        let (raw, truncated) = rawTail(maxBytes: maxBytes)
        var text = redactDictations(raw)
        guard truncated || text != raw else { return }
        if truncated, let newline = text.firstIndex(of: "\n") { text = String(text[text.index(after: newline)...]) }
        try? Data(text.utf8).write(to: logURL, options: .atomic)
    }

    /// « Dictée 2.1s : 'bonjour' -> 'Bonjour.' (LLM …) » devient « Dictée 2.1s : [texte masqué] ».
    static func redactDictations(_ log: String) -> String {
        log.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard line.contains("Dictée") || line.contains("Sortie LLM"),
                  let colon = line.range(of: " : "),
                  let first = line[colon.upperBound...].first, first == "'" || first == "\"" else { return String(line) }
            return String(line[..<colon.upperBound]) + "[texte masqué]"
        }.joined(separator: "\n")
    }
}
