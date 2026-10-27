import AppKit
import Carbon
import Sparkle
import VoxFlowCore

/// Chef d'orchestre : touche de dictée -> micro -> démon (Voxtral + Qwen) -> collage ->
/// surveillance des corrections -> apprentissage SQLite -> HUD.
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// VOXFLOW_PORT : essais en parallèle d'une version installée.
    private let port = Int(ProcessInfo.processInfo.environment["VOXFLOW_PORT"] ?? "") ?? 8765
    private let maxRecordingDuration: TimeInterval = 10 * 60

    private let settings = VoxFlowSettings.shared
    private let eventTap = GlobalEventTap()
    private lazy var fnController = FnKeyController(tap: eventTap, key: settings.dictationKey)
    private lazy var watcher = CorrectionWatcher(tap: eventTap)
    private lazy var client = InferenceClient(port: port)
    private lazy var engine = EngineController(
        manager: DaemonManager(daemonDirectory: Self.daemonDirectory(), port: port),
        client: client, settings: settings)
    private var onboarding: OnboardingWindowController?
    private var settingsWindow: SettingsWindowController?
    private var settingsModel: SettingsModel?
    private let audio = AudioCapture()
    /// Coupe le son du Mac pendant l'écoute, le rétablit dès la fin.
    private let muter = SystemAudioMuter()
    private let hud = HUDController()
    private let injector = TextInjector()
    private let learner = DiffLearner()
    private var history = DictationHistory()
    private var store: LexiconStore?
    /// Sparkle : démarré seulement si l'Info.plist porte un flux et une clé publique.
    private lazy var updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)

    private var statusItem: NSStatusItem!
    private var statusLineItem: NSMenuItem?
    private var lastStageKind = ""
    private var targetApp: NSRunningApplication?
    private var maxDurationWork: DispatchWorkItem?
    private var permissionTimer: Timer?
    /// Vrai entre le démarrage effectif du micro et l'arrêt de l'écoute.
    private var listening = false
    /// Écoute montrée (pilule, son coupé) ; une touche modificatrice ouvre d'abord le micro
    /// sans rien montrer.
    private var revealed = false
    /// Touche modificatrice : dictée impossible (moteurs, micro), affiché seulement si le
    /// geste se confirme.
    private var pendingNotice: String?
    /// Empêche App Nap de mettre l'app (et la priorité de son démon) en sommeil ;
    /// la veille du Mac reste autorisée.
    private var activity: NSObjectProtocol?

    // MARK: Cycle de vie

    func applicationDidFinishLaunching(_ notification: Notification) {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Dictée vocale VoxFlow"
        )
        muter.restoreAfterCrashIfNeeded()
        let migrated = VoxFlowPaths.migrateLegacyDataIfNeeded()
        if !migrated.isEmpty { AppLog.write("Données reprises de ~/.wispr_clone : \(migrated.joined(separator: ", "))") }
        settings.migrateModeConfirmation(previousInstall: FileManager.default.fileExists(atPath: DaemonManager.venvDirectory.path))
        do {
            store = try LexiconStore()
        } catch {
            NSLog("VoxFlow: lexique indisponible: \(error.localizedDescription)")
        }
        startUpdaterIfConfigured()
        setUpMainMenu()
        setUpStatusItem()

        fnController.delegate = self
        fnController.log = { message in AppLog.write(message) }
        fnController.onKeyEdge = { [weak self] down in
            self?.onboarding?.model.keyHeld = down
            self?.settingsModel?.keyHeld = down
        }
        watcher.delegate = self
        audio.onSamples = { [weak self] samples in self?.client.sendAudio(samples) }
        audio.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.hud.setLevel(level) }
        }
        engine.onChange = { [weak self] in self?.engineChanged() }
        engine.onReady = { [weak self] in
            guard let self, self.onboarding == nil, self.permissionsGranted else { return }
            self.hud.show(.notice(L10n.tr("hud.ready", self.fnController.key.displayName)))
        }

        if settings.onboardingCompleted {
            AudioCapture.requestPermission { [weak self] granted in
                if !granted { self?.hud.show(.error(L10n.tr("hud.micDenied"))) }
            }
            startEventTapWhenTrusted(prompt: true)
        } else {
            // L'accueil demande les autorisations au bon moment, pas toutes d'un coup.
            startEventTapWhenTrusted(prompt: false)
            showOnboarding()
        }
        engine.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        watcher.end(.superseded)
        audio.stop()
        muter.restore()
        engine.stop()
        AppLog.flush()
    }

    /// Le CGEventTap exige la permission Accessibilité. Accordée au lancement : le tap
    /// démarre. Accordée pendant que VoxFlow tourne : macOS ne livre pas les touches au
    /// tap avant un redémarrage (constaté sur macOS 27 : Fn muette jusqu'à la relance,
    /// même avec la coche verte), donc VoxFlow se relance tout seul, accueil compris.
    private func startEventTapWhenTrusted(prompt: Bool) {
        let trustedAtLaunch = AXHelper.isTrusted(prompt: prompt)
        if trustedAtLaunch {
            if startEventTap() { return }
            AppLog.write("Tap clavier impossible malgré l'accessibilité : nouvel essai chaque seconde")
        }
        permissionTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            guard let self, AXHelper.isTrusted(prompt: false) else { return }
            if trustedAtLaunch {
                if self.startEventTap() { timer.invalidate() }
                return
            }
            timer.invalidate()
            AppLog.write("Accessibilité accordée : redémarrage pour activer la touche")
            self.relaunch()
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    private func startEventTap() -> Bool {
        guard eventTap.start() else { return false }
        rebuildMenu()
        if CommandLine.arguments.contains(Self.relaunchedArgument) {
            hud.show(.notice(L10n.tr("hud.accessibilityRestarted")))
        }
        return true
    }

    static let relaunchedArgument = "--relaunched-for-accessibility"

    /// Nouvelle instance une fois celle-ci terminée (son démon arrêté, port libéré), avec
    /// cinq essais de `open` ; un échec final va dans app.log. Les variables VOXFLOW_* et
    /// HF_* et les arguments de lancement suivent, pour les essais isolés.
    private func relaunch() {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            AppLog.write("Redémarrage impossible hors d'un bundle .app")
            hud.show(.notice(L10n.tr("hud.restartNeeded")))
            return
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let env = ProcessInfo.processInfo.environment
            .filter { $0.key.hasPrefix("VOXFLOW_") || $0.key.hasPrefix("HF_") }
            .flatMap { ["--env", "\($0.key)=\($0.value)"] }
        let arguments = CommandLine.arguments.dropFirst().filter { $0 != Self.relaunchedArgument } + [Self.relaunchedArgument]
        let script = """
            log=$1; shift
            while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done
            /bin/sleep 0.5
            for attempt in 1 2 3 4 5; do
              error=$(/usr/bin/open "$@" 2>&1) && exit 0
              /bin/sleep 1
            done
            echo "$(/bin/date '+%Y-%m-%d %H:%M:%S.000') Redémarrage impossible : $error" >> "$log"
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", AppLog.url.path] + env + [Bundle.main.bundlePath, "--args"] + arguments
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            AppLog.write("Redémarrage impossible : \(error.localizedDescription)")
            hud.show(.notice(L10n.tr("hud.restartNeeded")))
        }
    }

    private var permissionsGranted: Bool { AudioCapture.permissionGranted && AXHelper.isTrusted(prompt: false) }

    /// Met à jour la ligne d'état du menu ; le menu n'est reconstruit qu'au changement
    /// de nature (prêt, en cours, échec), pas à chaque octet téléchargé. Un échec est
    /// signalé par le HUD quand l'accueil est fermé.
    private func engineChanged() {
        statusLineItem?.title = L10n.tr("menu.header", engine.statusLine)
        let kind: String
        let symbol: String
        switch engine.stage {
        case .ready: (kind, symbol) = ("ready", "waveform")
        case .failed: (kind, symbol) = ("failed", "exclamationmark.triangle")
        default: (kind, symbol) = ("busy", "arrow.down.circle")
        }
        guard kind != lastStageKind else { return }
        lastStageKind = kind
        if kind == "failed", onboarding == nil, !listening { hud.show(.error(engine.statusLine)) }
        statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "VoxFlow")
        rebuildMenu()
    }

    // MARK: Accueil et réglages

    private func showOnboarding() {
        if let onboarding {
            onboarding.present()
            return
        }
        // Premier accueil : il reprend à la page quittée (redémarrage pour l'accessibilité).
        let model = OnboardingModel(engine: engine, settings: settings,
                                    page: settings.onboardingCompleted ? 0 : settings.onboardingPage)
        model.onKeyChange = { [weak self] key in self?.changeKey(to: key) }
        let controller = OnboardingWindowController(model: model)
        // Seul « Terminer » clôt l'accueil : fermé avant, il revient au prochain lancement.
        model.onFinish = { [weak self, weak controller] in
            self?.settings.onboardingCompleted = true
            self?.settings.onboardingPage = 0
            controller?.close()
        }
        controller.onClose = { [weak self] in
            guard let self else { return }
            self.onboarding = nil
            if !self.permissionsGranted {
                self.hud.show(.notice(L10n.tr("hud.permissionsMissing")))
            } else if self.engine.isReady {
                self.hud.show(.notice(L10n.tr("hud.ready", self.fnController.key.displayName)))
            }
            self.rebuildMenu()
        }
        onboarding = controller
        controller.present()
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let model = SettingsModel(engine: engine, settings: settings)
            model.onKeyChange = { [weak self] key in self?.changeKey(to: key) }
            model.onShowOnboarding = { [weak self] in
                self?.settingsWindow?.close()
                self?.showOnboarding()
            }
            settingsModel = model
            settingsWindow = SettingsWindowController(model: model)
        }
        settingsModel?.key = fnController.key
        settingsWindow?.present()
    }

    private func changeKey(to key: DictationKey) {
        settings.dictationKey = key
        fnController.setKey(key)
        onboarding?.model.key = key
        onboarding?.model.keyHeld = false
        settingsModel?.key = key
        settingsModel?.keyHeld = false
        rebuildMenu()
    }

    /// Menu principal invisible (app de barre de menu) : sans lui, ⌘V, ⌘C et ⌘A ne
    /// marchent pas dans les champs de l'accueil, et l'essai de dictée ne collerait rien.
    private func setUpMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L10n.tr("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    /// Démon embarqué dans l'app (Contents/Resources/daemon), sinon VOXFLOW_DAEMON_DIR.
    private static func daemonDirectory() -> URL? {
        if let override = ProcessInfo.processInfo.environment["VOXFLOW_DAEMON_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return Bundle.main.resourceURL?.appendingPathComponent("daemon", isDirectory: true)
    }

    // MARK: Dictée

    /// Pourquoi une dictée est impossible maintenant, nil si tout est prêt.
    private func recordingProblem() -> String? {
        if !AudioCapture.permissionGranted { return L10n.tr("hud.micNotAllowed") }
        if !engine.isReady {
            return engine.failure.map(EngineController.title(for:))
                ?? L10n.tr("hud.notReady", Int((engine.fraction * 100).rounded(.down)))
        }
        return nil
    }

    /// Ouvre le micro. Avec Fn, l'écoute se montre aussitôt. Avec une touche modificatrice,
    /// la pilule, la coupure du son et la fin de la surveillance attendent `.showMode`, et
    /// un problème (moteurs pas prêts, micro refusé) ne s'affiche que si le geste se
    /// confirme : un ⌘-clic ou un ⌘C un peu lent ne montre rien.
    private func startRecording() {
        let quiet = fnController.key.isModifier
        pendingNotice = nil
        revealed = false
        // Accueil au premier plan avant la page Essai : l'appui sert seulement à vérifier la
        // touche. Dans une autre app, la dictée marche même si l'accueil reste ouvert.
        if let onboarding, onboarding.window?.isKeyWindow == true, onboarding.model.page < OnboardingModel.pageCount - 1 {
            fnController.forceCancel()
            return
        }
        // Saisie sécurisée (champ mot de passe, Terminal) : le tap ne voit plus les autres
        // touches, un raccourci ⌘ deviendrait une dictée.
        if quiet, IsSecureEventInputEnabled() {
            pendingNotice = L10n.tr("hud.secureInput")
            return
        }
        if let problem = recordingProblem() {
            if quiet {
                pendingNotice = problem
            } else {
                fnController.forceCancel()
                hud.show(.error(problem))
            }
            return
        }
        targetApp = NSWorkspace.shared.frontmostApplication
        if let targetApp { AXHelper.primeAccessibility(for: targetApp) }
        client.begin(bundleID: targetApp?.bundleIdentifier ?? "")
        do {
            try audio.start()
        } catch {
            client.cancel()
            if quiet {
                pendingNotice = error.localizedDescription
            } else {
                fnController.forceCancel()
                hud.show(.error(error.localizedDescription))
            }
            return
        }
        listening = true
        if !quiet { reveal(.listening) }
        let work = DispatchWorkItem { [weak self] in self?.fnController.forceStop() }
        maxDurationWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + maxRecordingDuration, execute: work)
    }

    /// Écoute confirmée : la surveillance des corrections précédente se termine, le son
    /// du Mac se coupe, la pilule apparaît.
    private func reveal(_ state: HUDState) {
        guard listening else { return }
        // Pilule d'abord : un « Appris » issu de la surveillance close attend alors la fin
        // de la dictée au lieu d'être aussitôt recouvert.
        hud.show(state)
        if !revealed {
            revealed = true
            watcher.end(.superseded)
            if muter.muteOutput() { AppLog.write("Son du Mac coupé pendant l'écoute") }
        }
    }

    private func showPendingNotice() {
        guard let notice = pendingNotice else { return }
        pendingNotice = nil
        hud.show(.error(notice))
    }

    private func stopAndProcess() {
        guard listening else {
            // Touche modificatrice : appui confirmé alors que la dictée était impossible.
            showPendingNotice()
            return
        }
        listening = false
        hud.show(.processing)
        if !revealed {
            revealed = true
            watcher.end(.superseded)
        }
        maxDurationWork?.cancel()
        audio.stop()
        muter.restore()
        fnController.setBusy(true)
        client.finish { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(dictation):
                self.deliver(dictation.text)
            case let .failure(error):
                self.fnController.setBusy(false)
                self.hud.show(.error(error.localizedDescription))
            }
        }
    }

    private func cancelRecording() {
        pendingNotice = nil
        let shown = revealed
        listening = false
        revealed = false
        maxDurationWork?.cancel()
        audio.stop()
        muter.restore()
        client.cancel()
        if shown { hud.hide() }
    }

    private func deliver(_ text: String) {
        guard !text.isEmpty else {
            fnController.setBusy(false)
            hud.hide()
            return
        }
        hud.hide()
        history.add(text)
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
        let key = fnController.key
        let header = disabled(L10n.tr("menu.header", engine.statusLine))
        statusLineItem = header
        menu.addItem(header)
        if engine.failure != nil {
            menu.addItem(action(L10n.tr("engine.retry"), #selector(retryEngine)))
        }
        menu.addItem(disabled(L10n.tr("menu.hint", key.displayName)))

        let historyItem = NSMenuItem(title: L10n.tr("menu.history"), action: nil, keyEquivalent: "")
        let historyMenu = NSMenu()
        if history.items.isEmpty {
            historyMenu.addItem(disabled(L10n.tr("menu.history.empty")))
        } else {
            historyMenu.addItem(disabled(L10n.tr("menu.history.hint")))
            for (index, text) in history.items.enumerated() {
                let item = action(DictationHistory.menuTitle(text), #selector(pasteFromHistory(_:)))
                item.representedObject = text
                item.toolTip = text
                if index < 9 { item.keyEquivalent = String(index + 1) }
                historyMenu.addItem(item)
            }
        }
        historyItem.submenu = historyMenu
        menu.addItem(historyItem)
        menu.addItem(.separator())

        let trusted = AXHelper.isTrusted(prompt: false)
        menu.addItem(action(L10n.tr(trusted ? "menu.accessibility.on" : "menu.accessibility.off"),
                            #selector(openAccessibilitySettings)))
        menu.addItem(action(L10n.tr(AudioCapture.permissionGranted ? "menu.mic.on" : "menu.mic.off"),
                            #selector(openMicrophoneSettings)))
        if key == .fn, !OnboardingModel.globeKeyFree {
            menu.addItem(action(L10n.tr("menu.globeKey"), #selector(openKeyboardSettings)))
        }
        menu.addItem(.separator())

        let rows = store?.recent(limit: 8) ?? []
        let lexiconItem = NSMenuItem(title: L10n.tr("menu.lexicon", store?.count() ?? 0), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        if rows.isEmpty { submenu.addItem(disabled(L10n.tr("menu.lexicon.empty"))) }
        for row in rows {
            let item = action(L10n.tr("menu.lexicon.forget", row.wrongVariant, row.canonicalTerm, row.frequency),
                              #selector(forgetRule(_:)))
            item.representedObject = NSNumber(value: row.id)
            submenu.addItem(item)
        }
        lexiconItem.submenu = submenu
        menu.addItem(lexiconItem)
        menu.addItem(action(L10n.tr("menu.settings"), #selector(showSettings), key: ","))
        menu.addItem(action(L10n.tr("menu.openFolder"), #selector(openDataFolder)))
        menu.addItem(action(L10n.tr("menu.restartEngine"), #selector(restartDaemon)))
        menu.addItem(.separator())
        menu.addItem(action(L10n.tr("menu.about"), #selector(showAbout)))
        if Self.updatesConfigured {
            let check = NSMenuItem(title: L10n.tr("menu.checkUpdates"),
                                   action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
            check.target = updater
            menu.addItem(check)
        }
        menu.addItem(action(L10n.tr("menu.licenses"), #selector(showLicenses)))
        menu.addItem(.separator())
        menu.addItem(action(L10n.tr("menu.quit"), #selector(quit), key: "q"))
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
        engine.retry()
    }

    @objc private func retryEngine() {
        engine.retry()
    }

    @objc private func pasteFromHistory(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        injector.pasteAndKeep(text)
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

// MARK: - Touche de dictée

extension AppController: FnKeyControllerDelegate {
    func fnKeyController(_ controller: FnKeyController, perform action: DictationAction) {
        switch action {
        case .startRecording: startRecording()
        case .showMode(.pushToTalk): reveal(.listening)
        case .showMode(.locked):
            if listening {
                reveal(.locked)
            } else {
                showPendingNotice()
                fnController.forceCancel()
            }
        case .stopAndProcess: stopAndProcess()
        case .cancelRecording: cancelRecording()
        case .scheduleTimer: break // géré par DictationKeyController
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
                learned.append(L10n.tr("hud.learned.item", correction.canonicalTerm, correction.wrongVariant))
            } catch {
                NSLog("VoxFlow: enregistrement impossible: \(error.localizedDescription)")
            }
        }
        if !learned.isEmpty {
            hud.show(.learned(L10n.tr("hud.learned", learned.joined(separator: ", "))))
            rebuildMenu()
        }
    }
}
