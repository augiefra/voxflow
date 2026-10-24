import AppKit
import Combine
import VoxFlowCore

/// Prépare et surveille les moteurs : Python et ses paquets (uv embarqué), puis le démon,
/// qui télécharge et charge les modèles. Publie un état unique pour l'accueil, les
/// réglages et le menu.
final class EngineController: ObservableObject {
    enum Stage: Equatable {
        case idle
        /// Python 3.12 et paquets du démon (~150 Mo, une fois).
        case preparing
        /// Démon lancé : import de MLX, contrôle des modèles.
        case checking
        case downloading
        /// Coupure (réseau, Hub, fichier abîmé) : le démon réessaie tout seul.
        case waitingRetry(code: String)
        /// Chargement en mémoire et préchauffage.
        case loading
        case ready
        case failed(EngineFailure)
    }

    @Published private(set) var stage: Stage = .idle
    /// Avancement global, de Python jusqu'au dernier octet des modèles.
    @Published private(set) var fraction: Double = 0
    @Published private(set) var bytesDone: Int64 = 0
    @Published private(set) var bytesTotal: Int64 = 0
    @Published private(set) var speed: Int64 = 0
    @Published private(set) var eta: Int?
    @Published private(set) var mode: EngineMode
    /// Après un échec réseau durable, un nouvel essai automatique est prévu.
    @Published private(set) var autoRetryScheduled = false

    /// Appelé une fois quand les moteurs deviennent prêts.
    var onReady: (() -> Void)?
    /// Appelé à chaque changement visible (menu).
    var onChange: (() -> Void)?

    private let manager: DaemonManager
    private let client: InferenceClient
    private var environmentFraction: Double = 0
    private var generation = 0
    private var pollTimer: Timer?
    private var answered = false
    private var lastCrashRelaunch: Date?
    private var autoRetryTimer: Timer?
    private var autoRetryAttempts = 0
    /// Démon trouvé déjà à l'écoute et repris : sa fin se déduit du silence de /health.
    private var adopted = false
    private var missedPolls = 0

    private static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    init(manager: DaemonManager, client: InferenceClient, mode: EngineMode) {
        self.manager = manager
        self.client = client
        self.mode = mode
        manager.onExit = { [weak self] status in self?.daemonExited(status: status) }
    }

    var isReady: Bool { stage == .ready }

    var failure: EngineFailure? {
        if case let .failed(failure) = stage { return failure }
        return nil
    }

    /// Lance la préparation (idempotent). Un démon déjà à l'écoute n'est repris que s'il
    /// vient de cette version de l'app (ou a été lancé à la main) et tourne dans le bon
    /// mode ; un autre démon VoxFlow est arrêté pour libérer le port.
    func start() {
        switch stage {
        case .idle, .failed: break
        default: return
        }
        cancelAutoRetry()
        generation += 1
        let current = generation
        client.health { [weak self] health in
            guard let self, current == self.generation else { return }
            guard let health else { return self.prepareThenLaunch(generation: current) }
            if health.pid != nil, health.mode == self.mode.rawValue, health.version == nil || health.version == Self.appVersion {
                AppLog.write("Démon déjà à l'écoute repris (pid \(health.pid ?? 0))")
                self.adopted = true
                self.missedPolls = 0
                self.answered = true
                self.apply(health)
                self.startPolling()
            } else {
                self.replaceForeignDaemon(health, generation: current)
            }
        }
    }

    private func replaceForeignDaemon(_ health: DaemonHealth, generation current: Int) {
        AppLog.write("Autre démon sur le port (version \(health.version ?? "?"), mode \(health.mode ?? "?")) : arrêt")
        set(.checking)
        let manager = manager
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let freed = manager.terminateForeignDaemon(pid: health.pid)
            DispatchQueue.main.async {
                guard let self, current == self.generation else { return }
                if freed {
                    self.prepareThenLaunch(generation: current)
                } else {
                    self.fail(EngineFailure(code: "port_busy", detail: String(manager.port)))
                }
            }
        }
    }

    /// Relance tout (Python compris) une fois l'ancien démon arrêté et le port libéré.
    func retry() {
        generation += 1
        pollTimer?.invalidate()
        cancelAutoRetry()
        adopted = false
        set(.idle)
        manager.stop { [weak self] in self?.start() }
    }

    /// Complet ↔ léger : relance le démon. Les fichiers déjà téléchargés sont gardés,
    /// et un téléchargement interrompu reprend où il en était. L'installation de Python,
    /// qui ne dépend pas du mode, continue.
    func setMode(_ newMode: EngineMode) {
        guard newMode != mode else { return }
        mode = newMode
        VoxFlowSettings.shared.engineMode = newMode
        guard stage != .idle else { return }
        generation += 1
        pollTimer?.invalidate()
        cancelAutoRetry()
        bytesDone = 0
        bytesTotal = 0
        let preparing = stage == .preparing
        set(.idle)
        if preparing {
            start()
        } else {
            adopted = false
            manager.stopDaemon { [weak self] in self?.start() }
        }
    }

    /// Le mode complet ajoute Qwen (4,3 Go) : depuis un mode léger qui marche, on prévient
    /// que la dictée s'arrête le temps du téléchargement.
    func confirmAndSetMode(_ newMode: EngineMode) {
        guard newMode != mode else { return }
        if newMode == .full, isReady {
            let alert = NSAlert()
            alert.messageText = L10n.tr("mode.switchFull.title")
            alert.informativeText = L10n.tr("mode.switchFull.message",
                                            L10n.bytes(EngineMode.full.downloadBytes - EngineMode.light.downloadBytes))
            alert.addButton(withTitle: L10n.tr("mode.switchFull.confirm"))
            alert.addButton(withTitle: L10n.tr("mode.switchFull.cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        setMode(newMode)
    }

    func stop() {
        generation += 1
        pollTimer?.invalidate()
        cancelAutoRetry()
        manager.stop()
    }

    /// Captures de contrôle (`--snapshots`) : impose un état sans démon.
    func simulate(_ newStage: Stage, fraction value: Double, done: Int64 = 0, total: Int64 = 0, speed newSpeed: Int64 = 0, eta newEta: Int? = nil) {
        stage = newStage
        fraction = value
        bytesDone = done
        bytesTotal = total
        speed = newSpeed
        eta = newEta
    }

    // MARK: Préparation et lancement

    private func prepareThenLaunch(generation current: Int) {
        if manager.isEnvironmentReady {
            environmentFraction = 1
            launch(generation: current)
            return
        }
        environmentFraction = 0
        set(.preparing)
        recompute()
        manager.prepareEnvironment(progress: { [weak self] value in
            guard let self, current == self.generation else { return }
            self.environmentFraction = value
            self.recompute()
        }, completion: { [weak self] result in
            guard let self, current == self.generation else { return }
            switch result {
            case .success:
                self.environmentFraction = 1
                self.launch(generation: current)
            case let .failure(failure):
                AppLog.write("Préparation de Python impossible : \(failure.code) \(failure.detail)")
                self.fail(failure)
            }
        })
    }

    private func launch(generation current: Int) {
        do {
            answered = false
            try manager.launch(light: mode == .light)
            AppLog.write("Démon lancé (mode \(mode.rawValue))")
            set(.checking)
            recompute()
            startPolling()
        } catch let failure as EngineFailure {
            fail(failure)
        } catch {
            fail(EngineFailure(code: "unknown", detail: error.localizedDescription))
        }
    }

    private func daemonExited(status: Int32) {
        AppLog.write("Démon arrêté (code \(status))")
        let log = DaemonManager.logTail(maxBytes: 4096)
        // Plantage d'un démon prêt : relance automatique, au plus une par tranche de 10 min
        // (un démon qui plante à chaque dictée ne recharge pas ses 7 Go en boucle).
        if stage == .ready, lastCrashRelaunch.map({ Date().timeIntervalSince($0) > 600 }) ?? true {
            lastCrashRelaunch = Date()
            set(.idle)
            start()
            return
        }
        // Environnement incomplet (paquet manquant, Python supprimé) : refait au prochain essai.
        if ["ModuleNotFoundError", "ImportError", "No such file or directory", "dyld"].contains(where: log.contains) {
            manager.invalidateEnvironment()
        }
        if case .failed = stage { return }
        // Port tenu par un programme qui ne parle pas le contrat /health.
        if log.split(separator: "\n").last?.contains("Écoute impossible") == true {
            return fail(EngineFailure(code: "port_busy", detail: String(manager.port)))
        }
        let lastLine = log.split(separator: "\n").last.map(String.init) ?? "code \(status)"
        fail(EngineFailure(code: "crashed", detail: lastLine))
    }

    /// Échec affiché ; après une coupure réseau durable, nouvel essai tout seul, de plus
    /// en plus espacé (1, 2 puis 5 min).
    private func fail(_ failure: EngineFailure) {
        pollTimer?.invalidate()
        if stage != .failed(failure) { AppLog.write("Échec des moteurs : \(failure.code) \(failure.detail)") }
        set(.failed(failure))
        guard failure.retryable, ["network", "hub_unavailable"].contains(failure.code) else { return }
        let delays: [TimeInterval] = [60, 120, 300]
        let delay = delays[min(autoRetryAttempts, delays.count - 1)]
        autoRetryAttempts += 1
        autoRetryTimer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self, case .failed = self.stage else { return }
            AppLog.write("Nouvel essai automatique après « \(failure.code) »")
            self.retry()
        }
        RunLoop.main.add(timer, forMode: .common)
        autoRetryTimer = timer
        autoRetryScheduled = true
    }

    private func cancelAutoRetry() {
        autoRetryTimer?.invalidate()
        autoRetryTimer = nil
        autoRetryScheduled = false
    }

    // MARK: Suivi

    private func startPolling(fast: Bool = false) {
        pollTimer?.invalidate()
        let interval: TimeInterval = stage == .ready && !fast ? 5 : 0.5
        let current = generation
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self, current == self.generation else { return }
            self.client.health { health in
                guard current == self.generation else { return }
                guard let health else { return self.missedPoll() }
                let recovered = self.missedPolls > 0
                self.missedPolls = 0
                self.answered = true
                let wasReady = self.stage == .ready
                self.apply(health)
                if recovered || wasReady != (self.stage == .ready) { self.startPolling() }
            }
        }
        // Mode commun : l'avancement continue de s'afficher pendant que le menu est ouvert.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// Pas de réponse : démarrage de Python ou arrêt de notre démon (onExit tranche), ou
    /// fin d'un démon repris, que personne d'autre ne signalera.
    private func missedPoll() {
        guard adopted else { return }
        missedPolls += 1
        // Premier silence : on resserre le suivi pour trancher en 1,5 s plutôt qu'en 15.
        if missedPolls == 1 { return startPolling(fast: true) }
        guard missedPolls >= 3 else { return }
        AppLog.write("Démon repris disparu : relance")
        adopted = false
        pollTimer?.invalidate()
        set(.idle)
        start()
    }

    private func apply(_ health: DaemonHealth) {
        bytesDone = health.bytesDone ?? 0
        bytesTotal = health.bytesTotal ?? mode.downloadBytes
        speed = health.speedBps ?? 0
        eta = health.etaS
        switch health.status {
        case "ready":
            let first = stage != .ready
            set(.ready)
            autoRetryAttempts = 0
            if first { onReady?() }
        case "error":
            fail(EngineFailure(code: health.errorCode ?? "unknown", detail: health.error ?? "",
                               retryable: health.retryable ?? true,
                               diskNeeded: health.diskNeededBytes, diskFree: health.diskFreeBytes))
        default:
            if let retry = health.retry {
                set(.waitingRetry(code: retry.code))
            } else {
                switch health.phase {
                case "downloading": set(.downloading)
                case "loading", "warmup": set(.loading)
                default: set(.checking)
                }
            }
        }
        recompute()
    }

    private func recompute() {
        let environment = Double(EnvironmentProgress.expectedBytes)
        let total = Double(bytesTotal > 0 ? bytesTotal : mode.downloadBytes)
        var value = (environmentFraction * environment + Double(bytesDone)) / (environment + total)
        if stage == .loading { value = max(value, 0.99) }
        if stage == .ready { value = 1 }
        if abs(value - fraction) > 0.0005 || value == 1 { fraction = min(1, value) }
        onChange?()
    }

    private func set(_ newStage: Stage) {
        guard newStage != stage else { return }
        stage = newStage
        onChange?()
    }

    // MARK: Textes

    /// Ligne d'état courte (menu, réglages).
    var statusLine: String {
        let percent = Int((fraction * 100).rounded(.down))
        switch stage {
        case .idle: return L10n.tr("engine.idle")
        case .preparing: return L10n.tr("engine.preparing", percent)
        case .checking: return L10n.tr("engine.starting")
        case .downloading: return L10n.tr("engine.downloading", percent)
        case let .waitingRetry(code):
            return L10n.tr(Self.retryCodes.contains(code) ? "engine.retrying.\(code)" : "engine.retrying")
        case .loading: return L10n.tr("engine.loading")
        case .ready: return mode == .full ? L10n.tr("engine.ready.full") : L10n.tr("engine.ready.light")
        case let .failed(failure): return Self.title(for: failure)
        }
    }

    /// « 3,1 Go sur 7,4 Go · 120 Mo/s · 2 min » pendant le téléchargement.
    var detailLine: String? {
        guard stage == .downloading, bytesTotal > 0 else { return nil }
        var parts = [L10n.tr("engine.bytes", L10n.bytes(bytesDone), L10n.bytes(bytesTotal))]
        if speed > 0 { parts.append(L10n.tr("engine.speed", L10n.bytes(speed))) }
        if let eta, eta > 0 {
            let formatter = DateComponentsFormatter()
            formatter.unitsStyle = .short
            formatter.allowedUnits = eta >= 3600 ? [.hour, .minute] : eta >= 60 ? [.minute] : [.second]
            if let text = formatter.string(from: TimeInterval(eta)) { parts.append(L10n.tr("engine.eta", text)) }
        }
        return parts.joined(separator: " · ")
    }

    static func title(for failure: EngineFailure) -> String {
        L10n.tr(knownCodes.contains(failure.code) ? "failure.\(failure.code).title" : "failure.unknown.title")
    }

    private static let retryCodes: Set<String> = ["network", "hub_unavailable", "integrity"]

    static func message(for failure: EngineFailure) -> String {
        switch failure.code {
        case "port_busy":
            return L10n.tr("failure.port_busy.message", failure.detail)
        case "disk_full":
            if let needed = failure.diskNeeded, let free = failure.diskFree {
                return L10n.tr("failure.disk_full.detail", L10n.bytes(needed), L10n.bytes(free))
            }
            return L10n.tr("failure.disk_full.message")
        case _ where knownCodes.contains(failure.code):
            return L10n.tr("failure.\(failure.code).message")
        default:
            return failure.detail
        }
    }

    private static let knownCodes: Set<String> = [
        "network", "tls", "disk_full", "low_memory", "unsupported_cpu", "hub_unavailable", "hub_refused",
        "integrity", "app_damaged", "crashed", "port_busy",
    ]
}
