import AppKit
import Sparkle
import VoxFlowCore

/// Chef d'orchestre : Fn -> micro -> démon (Voxtral + Qwen) -> collage ->
/// surveillance des corrections -> apprentissage SQLite -> HUD.
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let port = 8765
    private let maxRecordingDuration: TimeInterval = 10 * 60

    private let eventTap = GlobalEventTap()
    private lazy var fnController = FnKeyController(tap: eventTap)
    private lazy var watcher = CorrectionWatcher(tap: eventTap)
    private lazy var client = InferenceClient(port: port)
    private lazy var daemon = DaemonManager(daemonDirectory: Self.daemonDirectory(), port: port)
    private let audio = AudioCapture()
    /// Coupe le son du Mac pendant l'écoute, le rétablit dès la fin.
    private let muter = SystemAudioMuter()
    private let hud = HUDController()
    private let injector = TextInjector()
    private let learner = DiffLearner()
    private var store: LexiconStore?
    /// Sparkle : démarré seulement si l'Info.plist porte un flux et une clé publique.
    private lazy var updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)

    private var statusItem: NSStatusItem!
    private var daemonStatus = "arrêté"
    private var targetApp: NSRunningApplication?
    private var maxDurationWork: DispatchWorkItem?
    private var permissionTimer: Timer?
    private var launchAttempted = false
    /// Empêche App Nap de mettre l'app (et la priorité de son démon) en sommeil ;
    /// la veille du Mac reste autorisée.
    private var activity: NSObjectProtocol?

    // MARK: Cycle de vie

    func applicationDidFinishLaunching(_ notification: Notification) {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Dictée à la touche Fn"
        )
        muter.restoreAfterCrashIfNeeded()
        let migrated = VoxFlowPaths.migrateLegacyDataIfNeeded()
        if !migrated.isEmpty { AppLog.write("Données reprises de ~/.wispr_clone : \(migrated.joined(separator: ", "))") }
        do {
            store = try LexiconStore()
        } catch {
            NSLog("VoxFlow: lexique indisponible: \(error.localizedDescription)")
        }
        startUpdaterIfConfigured()
        setUpStatusItem()

        fnController.delegate = self
        fnController.log = { message in AppLog.write(message) }
        watcher.delegate = self
        audio.onSamples = { [weak self] samples in self?.client.sendAudio(samples) }
        audio.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.hud.setLevel(level) }
        }

        AudioCapture.requestPermission { [weak self] granted in
            if !granted { self?.hud.show(.error("Micro refusé : Réglages > Confidentialité > Micro")) }
        }
        startEventTapWhenTrusted()
        refreshDaemon()
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refreshDaemon() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        watcher.end(.superseded)
        audio.stop()
        muter.restore()
        daemon.stop()
    }

    /// Le CGEventTap exige la permission Accessibilité ; on la demande puis on
    /// réessaie toutes les 2 s jusqu'à ce qu'elle soit accordée.
    private func startEventTapWhenTrusted() {
        if AXHelper.isTrusted(prompt: true), eventTap.start() {
            rebuildMenu()
            return
        }
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self, AXHelper.isTrusted(prompt: false), self.eventTap.start() else { return }
            timer.invalidate()
            self.rebuildMenu()
        }
    }

    private func refreshDaemon() {
        client.health { [weak self] status, error in
            guard let self else { return }
            switch status {
            case "ready": self.daemonStatus = "prêt"
            case "loading": self.daemonStatus = "chargement des modèles…"
            case "error": self.daemonStatus = "erreur : \(error ?? "voir daemon.log")"
            default:
                self.daemonStatus = self.daemon.isManagingProcess ? "démarrage…" : "arrêté"
                if !self.launchAttempted {
                    self.launchAttempted = true
                    self.launchDaemon()
                }
            }
            self.rebuildMenu()
        }
    }

    private func launchDaemon() {
        do {
            try daemon.launch()
            daemonStatus = "démarrage…"
        } catch {
            daemonStatus = "arrêté (\(error.localizedDescription))"
        }
        rebuildMenu()
    }

    /// Démon embarqué dans l'app (Contents/Resources/daemon), sinon VOXFLOW_DAEMON_DIR.
    private static func daemonDirectory() -> URL? {
        if let override = ProcessInfo.processInfo.environment["VOXFLOW_DAEMON_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return Bundle.main.resourceURL?.appendingPathComponent("daemon", isDirectory: true)
    }

    // MARK: Dictée

    private func startRecording() {
        guard AudioCapture.permissionGranted else {
            fnController.forceCancel()
            hud.show(.error("Micro non autorisé"))
            return
        }
        watcher.end(.superseded)
        targetApp = NSWorkspace.shared.frontmostApplication
        if let targetApp { AXHelper.primeAccessibility(for: targetApp) }
        client.begin(bundleID: targetApp?.bundleIdentifier ?? "")
        if muter.muteOutput() { AppLog.write("Son du Mac coupé pendant l'écoute") }
        do {
            try audio.start()
        } catch {
            muter.restore()
            client.cancel()
            fnController.forceCancel()
            hud.show(.error(error.localizedDescription))
            return
        }
        hud.show(.listening)
        let work = DispatchWorkItem { [weak self] in self?.fnController.forceStop() }
        maxDurationWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + maxRecordingDuration, execute: work)
    }

    private func stopAndProcess() {
        maxDurationWork?.cancel()
        audio.stop()
        muter.restore()
        fnController.setBusy(true)
        hud.show(.processing)
        client.finish { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(dictation):
                self.deliver(dictation.text)
            case let .failure(error):
                self.fnController.setBusy(false)
                self.hud.show(.error(error.localizedDescription))
                self.refreshDaemon()
            }
        }
    }

    private func cancelRecording() {
        maxDurationWork?.cancel()
        audio.stop()
        muter.restore()
        client.cancel()
        hud.hide()
    }

    private func deliver(_ text: String) {
        guard !text.isEmpty else {
            fnController.setBusy(false)
            hud.hide()
            return
        }
        hud.hide()
        let app = NSWorkspace.shared.frontmostApplication ?? targetApp
        injector.paste(text) { [weak self] in
            guard let self else { return }
            self.fnController.setBusy(false)
            // Laisse l'app appliquer le collage avant de lire le champ (T_paste).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                let context = PasteContext.capture(insertedText: text, app: app)
                self.watcher.begin(context: context)
            }
        }
    }

    // MARK: Barre de menu

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "VoxFlow")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }

    private func rebuildMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()
        menu.addItem(disabled("VoxFlow — démon : \(daemonStatus)"))
        menu.addItem(disabled("Maintenir Fn : dictée · Double-tap Fn : mains libres"))
        menu.addItem(.separator())

        let trusted = AXHelper.isTrusted(prompt: false)
        menu.addItem(action(trusted ? "Accessibilité : autorisée" : "Accessibilité : à autoriser…",
                            #selector(openAccessibilitySettings)))
        menu.addItem(action(AudioCapture.permissionGranted ? "Micro : autorisé" : "Micro : à autoriser…",
                            #selector(openMicrophoneSettings)))
        if let usage = UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int, usage != 0 {
            menu.addItem(action("⚠︎ Touche 🌐 : régler « Ne rien faire »…", #selector(openKeyboardSettings)))
        }
        menu.addItem(.separator())

        let rows = store?.recent(limit: 8) ?? []
        let lexiconItem = NSMenuItem(title: "Lexique appris : \(store?.count() ?? 0) règle(s)", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        if rows.isEmpty { submenu.addItem(disabled("Aucune correction apprise")) }
        for row in rows {
            let item = action("Oublier « \(row.wrongVariant) » → \(row.canonicalTerm) (×\(row.frequency))", #selector(forgetRule(_:)))
            item.representedObject = NSNumber(value: row.id)
            submenu.addItem(item)
        }
        lexiconItem.submenu = submenu
        menu.addItem(lexiconItem)
        menu.addItem(action("Ouvrir le dossier ~/.voxflow", #selector(openDataFolder)))
        menu.addItem(action("Relancer le démon", #selector(restartDaemon)))
        menu.addItem(.separator())
        menu.addItem(action("À propos de VoxFlow", #selector(showAbout)))
        if Self.updatesConfigured {
            let check = NSMenuItem(title: "Rechercher des mises à jour…",
                                   action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
            check.target = updater
            menu.addItem(check)
        }
        menu.addItem(action("Licences tierces…", #selector(showLicenses)))
        menu.addItem(.separator())
        menu.addItem(action("Quitter VoxFlow", #selector(quit), key: "q"))
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func openAccessibilitySettings() {
        _ = AXHelper.isTrusted(prompt: true)
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    @objc private func openMicrophoneSettings() {
        AudioCapture.requestPermission { _ in }
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    @objc private func openKeyboardSettings() {
        open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    }

    @objc private func openDataFolder() {
        try? FileManager.default.createDirectory(at: DaemonManager.dataDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(DaemonManager.dataDirectory)
    }

    @objc private func restartDaemon() {
        daemon.stop()
        launchAttempted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.launchDaemon() }
    }

    @objc private func forgetRule(_ sender: NSMenuItem) {
        guard let id = (sender.representedObject as? NSNumber)?.int64Value else { return }
        try? store?.delete(id: id)
        rebuildMenu()
    }

    // MARK: À propos, licences, mises à jour

    private static var updatesConfigured: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        let feed = info["SUFeedURL"] as? String ?? ""
        let key = info["SUPublicEDKey"] as? String ?? ""
        return !feed.isEmpty && !key.isEmpty
    }

    private func startUpdaterIfConfigured() {
        guard Self.updatesConfigured else { return }
        updater.startUpdater()
    }

    @objc private func showAbout() {
        AboutPanel.show()
    }

    @objc private func showLicenses() {
        guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "txt") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func open(_ urlString: String) {
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }
}

// MARK: - Sparkle

extension AppController: SPUStandardUserDriverDelegate {
    /// App de barre de menu : Sparkle signale la mise à jour sans voler le focus.
    var supportsGentleScheduledUpdateReminders: Bool { true }
}

// MARK: - Fn

extension AppController: FnKeyControllerDelegate {
    func fnKeyController(_ controller: FnKeyController, perform action: DictationAction) {
        switch action {
        case .startRecording: startRecording()
        case .showMode(.pushToTalk): hud.show(.listening)
        case .showMode(.locked): hud.show(.locked)
        case .stopAndProcess: stopAndProcess()
        case .cancelRecording: cancelRecording()
        case .scheduleTimer: break // géré par FnKeyController
        }
    }
}

// MARK: - Apprentissage

extension AppController: CorrectionWatcherDelegate {
    func correctionWatcher(_ watcher: CorrectionWatcher, didFinishWith initial: String, final: String, bundleID: String) {
        let corrections = learner.extract(initial: initial, final: final, bundleID: bundleID)
        guard let store, !corrections.isEmpty else { return }
        var learned: [String] = []
        for correction in corrections {
            do {
                try store.record(correction)
                learned.append("\(correction.canonicalTerm) (au lieu de '\(correction.wrongVariant)')")
            } catch {
                NSLog("VoxFlow: enregistrement impossible: \(error.localizedDescription)")
            }
        }
        if !learned.isEmpty {
            hud.show(.learned("Appris : " + learned.joined(separator: ", ")))
            rebuildMenu()
        }
    }
}
