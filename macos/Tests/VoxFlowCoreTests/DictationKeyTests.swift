import CoreGraphics
import Foundation
import XCTest
@testable import VoxFlowCore

/// Bits « côté » lus dans IOLLEvent.h, combinés aux masques génériques de CGEventFlags.
private enum Flags {
    static let rightCmd = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10)
    static let leftCmd = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x8)
    static let bothCmd = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x18)
    static let rightOpt = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40)
    static let leftOpt = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x20)
    static let rightCtrl = CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x2000)
    static let leftShift = CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | 0x2)
    static let rightCmdLeftShift = CGEventFlags(rawValue: rightCmd.rawValue | leftShift.rawValue)
}

final class DictationKeyTests: XCTestCase {
    func testRightCommandPressAndRelease() {
        let key = DictationKey.rightCommand
        XCTAssertEqual(key.isDown(keyCode: 54, flags: Flags.rightCmd, wasDown: false), true)
        XCTAssertEqual(key.isDown(keyCode: 54, flags: [], wasDown: true), false)
    }

    func testLeftCommandIsNotTheDictationKey() {
        XCTAssertNil(DictationKey.rightCommand.isDown(keyCode: 55, flags: Flags.leftCmd, wasDown: false))
    }

    func testRightReleasedWhileLeftStillHeld() {
        let key = DictationKey.rightCommand
        XCTAssertEqual(key.isDown(keyCode: 54, flags: Flags.bothCmd, wasDown: false), true)
        XCTAssertEqual(key.isDown(keyCode: 54, flags: Flags.leftCmd, wasDown: true), false)
    }

    func testOptionAndControl() {
        XCTAssertEqual(DictationKey.rightOption.isDown(keyCode: 61, flags: Flags.rightOpt, wasDown: false), true)
        XCTAssertNil(DictationKey.rightOption.isDown(keyCode: 58, flags: Flags.leftOpt, wasDown: false))
        XCTAssertEqual(DictationKey.rightControl.isDown(keyCode: 62, flags: Flags.rightCtrl, wasDown: false), true)
        XCTAssertEqual(DictationKey.rightControl.isDown(keyCode: 62, flags: [], wasDown: true), false)
    }

    func testCapsLockIsIgnored() {
        XCTAssertNil(DictationKey.rightCommand.isDown(keyCode: 57, flags: .maskAlphaShift, wasDown: false))
        XCTAssertFalse(ModifierTable.othersHeld(besides: .rightCommand, flags: CGEventFlags(rawValue: Flags.rightCmd.rawValue | CGEventFlags.maskAlphaShift.rawValue)))
    }

    /// Clavier qui n'envoie pas les bits de côté : bascule à chaque événement de la touche.
    func testFallbackWithoutDeviceBits() {
        let key = DictationKey.rightCommand
        XCTAssertEqual(key.isDown(keyCode: 54, flags: .maskCommand, wasDown: false), true)
        XCTAssertEqual(key.isDown(keyCode: 54, flags: .maskCommand, wasDown: true), false)
        XCTAssertEqual(key.isDown(keyCode: 54, flags: [], wasDown: true), false)
    }

    /// Sans bits de côté, un autre modificateur se repère à son masque générique.
    func testOtherModifierWithoutDeviceBits() {
        XCTAssertTrue(ModifierTable.isPress(keyCode: 56, flags: [.maskCommand, .maskShift]))
        XCTAssertFalse(ModifierTable.isPress(keyCode: 56, flags: .maskCommand))
        XCTAssertTrue(ModifierTable.isPress(keyCode: 56, flags: Flags.rightCmdLeftShift))
        XCTAssertFalse(ModifierTable.isPress(keyCode: 56, flags: Flags.rightCmd))
    }

    func testFnKeepsItsHistoricBehaviour() {
        XCTAssertEqual(DictationKey.fn.isDown(keyCode: 63, flags: .maskSecondaryFn, wasDown: false), true)
        XCTAssertEqual(DictationKey.fn.isDown(keyCode: 179, flags: [], wasDown: true), false)
        XCTAssertNil(DictationKey.fn.isDown(keyCode: 54, flags: Flags.rightCmd, wasDown: false))
    }

    /// Préférences d'essai dans le dossier temporaire (domaine désigné par son chemin) :
    /// rien n'est laissé dans ~/Library/Preferences.
    private func temporaryDefaults() -> (String, UserDefaults) {
        let suite = FileManager.default.temporaryDirectory.appendingPathComponent("voxflow.tests.\(UUID().uuidString)").path
        addTeardownBlock {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(atPath: suite + ".plist")
        }
        return (suite, UserDefaults(suiteName: suite)!)
    }

    func testSettingsStore() {
        let (_, defaults) = temporaryDefaults()
        let settings = VoxFlowSettings(defaults: defaults)
        XCTAssertEqual(settings.dictationKey, .fn)
        for key in DictationKey.allCases {
            settings.dictationKey = key
            XCTAssertEqual(VoxFlowSettings(defaults: defaults).dictationKey, key)
        }
        defaults.set("inconnue", forKey: "dictationKey")
        XCTAssertEqual(settings.dictationKey, .fn)
        XCTAssertFalse(settings.onboardingCompleted)
        settings.engineMode = .light
        XCTAssertEqual(settings.engineMode, .light)
    }

    /// Accueil : seul Voxtral se télécharge tant que le mode n'est pas validé.
    func testRunningModeWaitsForConfirmation() {
        let (_, defaults) = temporaryDefaults()
        let settings = VoxFlowSettings(defaults: defaults)
        settings.engineMode = .full
        XCTAssertEqual(settings.runningMode, .light)
        settings.engineModeConfirmed = true
        XCTAssertEqual(settings.runningMode, .full)
        settings.engineModeConfirmed = false
        settings.onboardingCompleted = true // installations déjà accueillies
        XCTAssertEqual(settings.runningMode, .full)
        XCTAssertEqual(settings.onboardingPage, 0)
        settings.onboardingPage = 2
        XCTAssertEqual(VoxFlowSettings(defaults: defaults).onboardingPage, 2)
    }

    func testModeConfirmationMigration() {
        let (suite, defaults) = temporaryDefaults()
        let fresh = VoxFlowSettings(defaults: defaults)
        fresh.migrateModeConfirmation(previousInstall: false)
        // Après la relance de l'accessibilité, l'environnement Python existe : rien ne change.
        fresh.migrateModeConfirmation(previousInstall: true)
        XCTAssertFalse(fresh.engineModeConfirmed)

        defaults.removePersistentDomain(forName: suite)
        let upgraded = VoxFlowSettings(defaults: defaults)
        upgraded.engineMode = .full
        upgraded.migrateModeConfirmation(previousInstall: true)
        XCTAssertTrue(upgraded.engineModeConfirmed)
        XCTAssertEqual(upgraded.runningMode, .full)
    }

    func testRecommendedMode() {
        XCTAssertEqual(EngineMode.recommended(physicalMemory: 8 << 30), .light)
        XCTAssertEqual(EngineMode.recommended(physicalMemory: 16 << 30), .full)
        XCTAssertEqual(EngineMode.full.downloadBytes, 7_444_716_257)
        // Même seuil que le démon (15,5 Gio) : la carte Complet est désactivée en dessous.
        XCTAssertFalse(EngineMode.full.isPossible(physicalMemory: 15 << 30))
        XCTAssertTrue(EngineMode.full.isPossible(physicalMemory: 16 << 30))
        XCTAssertTrue(EngineMode.light.isPossible(physicalMemory: 8 << 30))
    }
}

/// Contrôleur avec horloge et minuteries simulées.
final class ModifierKeyControllerTests: XCTestCase {
    private final class Recorder: FnKeyControllerDelegate {
        var actions: [DictationAction] = []
        func fnKeyController(_ controller: DictationKeyController, perform action: DictationAction) { actions.append(action) }
    }

    private var time: TimeInterval = 0
    private var timers: [(at: TimeInterval, block: () -> Void)] = []
    private var recorder = Recorder()
    private var edges: [Bool] = []

    private func makeController(_ key: DictationKey) -> DictationKeyController {
        time = 0
        timers = []
        recorder = Recorder()
        let controller = DictationKeyController(tap: GlobalEventTap(), key: key, now: { [unowned self] in self.time },
                                                schedule: { [unowned self] delay, block in self.timers.append((self.time + delay, block)) })
        controller.delegate = recorder
        edges = []
        controller.onKeyEdge = { [unowned self] down in self.edges.append(down) }
        return controller
    }

    /// Avance l'horloge en déclenchant les minuteries échues, dans l'ordre.
    private func advance(to target: TimeInterval) {
        while let next = timers.enumerated().filter({ $0.element.at <= target }).min(by: { $0.element.at < $1.element.at }) {
            timers.remove(at: next.offset)
            time = next.element.at
            next.element.block()
        }
        time = target
    }

    private func press(_ controller: DictationKeyController, at t: TimeInterval, flags: CGEventFlags = Flags.rightCmd) {
        advance(to: t)
        controller.handle(.flagsChanged(keyCode: 54, flags: flags))
    }

    private func release(_ controller: DictationKeyController, at t: TimeInterval) {
        advance(to: t)
        controller.handle(.flagsChanged(keyCode: 54, flags: []))
    }

    func testHoldStartsAfterArmDelayThenStops() {
        let controller = makeController(.rightCommand)
        press(controller, at: 0)
        advance(to: 0.1)
        XCTAssertEqual(recorder.actions, [])
        advance(to: 0.2)
        XCTAssertEqual(recorder.actions, [.startRecording]) // micro ouvert, rien de montré
        advance(to: 0.35)
        XCTAssertEqual(recorder.actions, [.startRecording, .showMode(.pushToTalk)])
        release(controller, at: 0.6)
        XCTAssertEqual(recorder.actions.last, .stopAndProcess)
        XCTAssertEqual(controller.state, .idle)
    }

    func testCommandCIsSilent() {
        let controller = makeController(.rightCommand)
        press(controller, at: 0)
        advance(to: 0.08)
        controller.handle(.keyDown(keyCode: 8, flags: Flags.rightCmd, characters: "c", isRepeat: false))
        release(controller, at: 0.2)
        advance(to: 1)
        XCTAssertEqual(recorder.actions, [])
        XCTAssertEqual(controller.state, .idle)
    }

    func testKeyAfterStartCancels() {
        let controller = makeController(.rightCommand)
        press(controller, at: 0)
        advance(to: 0.4)
        controller.handle(.keyDown(keyCode: 8, flags: Flags.rightCmd, characters: "c", isRepeat: false))
        XCTAssertEqual(recorder.actions, [.startRecording, .showMode(.pushToTalk), .cancelRecording])
    }

    /// ⌘-clic tenu un peu plus longtemps : le micro s'est ouvert, rien n'a été montré.
    func testSlowCommandClickCancelsBeforeShowing() {
        let controller = makeController(.rightCommand)
        press(controller, at: 0)
        advance(to: 0.25)
        controller.handle(.mouseDown)
        release(controller, at: 0.5)
        advance(to: 1)
        XCTAssertEqual(recorder.actions, [.startRecording, .cancelRecording])
        XCTAssertEqual(controller.state, .idle)
    }

    func testScrollWithModifierIsAShortcut() {
        let controller = makeController(.rightControl)
        controller.handle(.flagsChanged(keyCode: 62, flags: Flags.rightCtrl))
        advance(to: 0.05)
        controller.handle(.scroll)
        advance(to: 1)
        XCTAssertEqual(recorder.actions, [])
    }

    func testScrollIsIgnoredWithFn() {
        let controller = makeController(.fn)
        controller.handle(.flagsChanged(keyCode: 63, flags: .maskSecondaryFn))
        controller.handle(.scroll)
        XCTAssertEqual(recorder.actions, [.startRecording, .showMode(.pushToTalk)])
    }

    func testCommandClickIsSilent() {
        let controller = makeController(.rightCommand)
        press(controller, at: 0)
        advance(to: 0.05)
        controller.handle(.mouseDown)
        advance(to: 1)
        XCTAssertEqual(recorder.actions, [])
    }

    func testOtherModifierPressedDuringHoldCancels() {
        let controller = makeController(.rightCommand)
        press(controller, at: 0)
        advance(to: 0.05)
        controller.handle(.flagsChanged(keyCode: 56, flags: Flags.rightCmdLeftShift))
        advance(to: 1)
        XCTAssertEqual(recorder.actions, [])
    }

    func testPressWithShiftAlreadyHeldIsIgnored() {
        let controller = makeController(.rightCommand)
        press(controller, at: 0, flags: Flags.rightCmdLeftShift)
        advance(to: 0.5)
        controller.handle(.flagsChanged(keyCode: 54, flags: Flags.leftShift))
        advance(to: 1)
        XCTAssertEqual(recorder.actions, [])
        XCTAssertEqual(controller.state, .idle)
    }

    func testSingleShortTapShowsNothing() {
        let controller = makeController(.rightCommand)
        press(controller, at: 0)
        release(controller, at: 0.08)
        advance(to: 1)
        XCTAssertEqual(recorder.actions, [])
        XCTAssertEqual(controller.state, .idle)
    }

    func testDoubleTapLocksThenCleanPressStops() {
        let controller = makeController(.rightCommand)
        press(controller, at: 0)
        release(controller, at: 0.08)
        press(controller, at: 0.2)
        release(controller, at: 0.28)
        XCTAssertEqual(recorder.actions, [.startRecording, .showMode(.locked)])
        XCTAssertEqual(controller.state, .lockedRecording)
        // ⌘V à droite en pleine dictée : la dictée continue.
        press(controller, at: 2)
        controller.handle(.keyDown(keyCode: 9, flags: Flags.rightCmd, characters: "v", isRepeat: false))
        release(controller, at: 2.1)
        XCTAssertEqual(controller.state, .lockedRecording)
        XCTAssertEqual(recorder.actions.count, 2)
        // Appui seul : fin de la dictée au relâchement.
        press(controller, at: 4)
        XCTAssertEqual(controller.state, .lockedRecording)
        release(controller, at: 4.1)
        XCTAssertEqual(recorder.actions.last, .stopAndProcess)
        XCTAssertEqual(controller.state, .idle)
    }

    func testLockedEscapeCancels() {
        let controller = makeController(.rightCommand)
        press(controller, at: 0)
        release(controller, at: 0.08)
        press(controller, at: 0.2)
        release(controller, at: 0.28)
        controller.handle(.keyDown(keyCode: 53, flags: [], characters: "", isRepeat: false))
        XCTAssertEqual(recorder.actions.last, .cancelRecording)
    }

    func testTapThenHoldIsPushToTalk() {
        let controller = makeController(.rightCommand)
        press(controller, at: 0)
        release(controller, at: 0.08)
        press(controller, at: 0.2)
        advance(to: 0.6)
        XCTAssertEqual(recorder.actions, [.startRecording, .showMode(.pushToTalk)])
        release(controller, at: 0.9)
        XCTAssertEqual(recorder.actions.last, .stopAndProcess)
    }

    func testBusyIgnoresPress() {
        let controller = makeController(.rightCommand)
        controller.setBusy(true)
        press(controller, at: 0)
        advance(to: 1)
        XCTAssertEqual(recorder.actions, [])
    }

    func testFnStartsImmediately() {
        let controller = makeController(.fn)
        controller.handle(.flagsChanged(keyCode: 63, flags: .maskSecondaryFn))
        XCTAssertEqual(recorder.actions, [.startRecording, .showMode(.pushToTalk)])
        XCTAssertTrue(timers.isEmpty)
    }

    func testGlobeKeyDownCountsAsShortcutForOtherKeys() {
        let controller = makeController(.rightCommand)
        press(controller, at: 0)
        advance(to: 0.4)
        controller.handle(.keyDown(keyCode: 179, flags: Flags.rightCmd, characters: "", isRepeat: false))
        XCTAssertEqual(recorder.actions.last, .cancelRecording)
    }

    func testSetKeyCancelsAndSwitches() {
        let controller = makeController(.fn)
        controller.handle(.flagsChanged(keyCode: 63, flags: .maskSecondaryFn))
        controller.setBusy(false)
        controller.setKey(.rightOption)
        XCTAssertEqual(recorder.actions.last, .cancelRecording)
        XCTAssertEqual(controller.state, .idle)
        recorder.actions = []
        controller.handle(.flagsChanged(keyCode: 63, flags: []))
        controller.handle(.flagsChanged(keyCode: 63, flags: .maskSecondaryFn))
        XCTAssertEqual(recorder.actions, [])
        controller.handle(.flagsChanged(keyCode: 61, flags: Flags.rightOpt))
        advance(to: 0.3)
        XCTAssertEqual(recorder.actions, [.startRecording, .showMode(.pushToTalk)])
    }

    /// La minuterie du second tap de l'ancienne touche ne peut pas annuler un geste de la nouvelle.
    func testStaleTimerAfterSetKeyIsIgnored() {
        let controller = makeController(.fn)
        controller.handle(.flagsChanged(keyCode: 63, flags: .maskSecondaryFn))
        advance(to: 0.1)
        controller.handle(.flagsChanged(keyCode: 63, flags: [])) // tap : second appui attendu jusqu'à 0,5 s
        advance(to: 0.15)
        controller.setKey(.rightOption)
        recorder.actions = []
        advance(to: 0.2)
        controller.handle(.flagsChanged(keyCode: 61, flags: Flags.rightOpt))
        advance(to: 0.28)
        controller.handle(.flagsChanged(keyCode: 61, flags: []))
        advance(to: 0.55)
        controller.handle(.flagsChanged(keyCode: 61, flags: Flags.rightOpt))
        advance(to: 0.6)
        controller.handle(.flagsChanged(keyCode: 61, flags: []))
        XCTAssertEqual(controller.state, .lockedRecording)
        XCTAssertEqual(recorder.actions, [.startRecording, .showMode(.locked)])
    }

    /// Changer de touche pendant qu'elle est tenue : l'accueil apprend le relâchement.
    func testSetKeyWhileHeldReportsRelease() {
        let controller = makeController(.fn)
        controller.handle(.flagsChanged(keyCode: 63, flags: .maskSecondaryFn))
        controller.setKey(.rightCommand)
        XCTAssertEqual(edges, [true, false])
    }
}

final class EngineSetupTests: XCTestCase {
    func testEnvironmentProgressFromUVOutput() {
        var progress = EnvironmentProgress()
        progress.consume("Downloading cpython-3.12.15-macos-aarch64-none (download) (23.9MiB)")
        progress.consume(" Downloaded cpython-3.12.15-macos-aarch64-none (download)")
        XCTAssertEqual(progress.downloaded, Int64(23.9 * 1_048_576))
        progress.consume("Downloading mlx-metal (74.5MiB)")
        progress.consume("Downloading pygments (1.2MiB)")
        progress.consume(" Downloaded pygments")
        XCTAssertGreaterThan(progress.fraction, 0.1)
        XCTAssertLessThan(progress.fraction, 0.99)
        progress.consume("Installed 42 packages in 118ms")
        XCTAssertEqual(progress.fraction, 1)
    }

    func testUVFailureClassification() {
        XCTAssertEqual(EnvironmentProgress.failure(from: "error: Failed to install\n  Caused by: No space left on device (os error 28)").code, "disk_full")
        XCTAssertEqual(EnvironmentProgress.failure(from: "error: Request failed\n  Caused by: dns error: failed to lookup address").code, "network")
        XCTAssertEqual(EnvironmentProgress.failure(from: "error: something else").code, "unknown")
    }

    func testHealthDecodesOldAndNewPayloads() throws {
        let old = try JSONDecoder().decode(DaemonHealth.self, from: Data(#"{"status":"ready","error":""}"#.utf8))
        XCTAssertEqual(old.status, "ready")
        XCTAssertNil(old.bytesTotal)

        let downloading = try JSONDecoder().decode(DaemonHealth.self, from: Data("""
        {"status":"loading","error":"","phase":"downloading","model":"llm","file":"model.safetensors",
         "bytes_done":4660000000,"bytes_total":7444716257,"speed_bps":142800000,"eta_s":19,
         "models":[{"id":"asr","state":"ready","done":3148828619,"total":3148828619}],
         "error_code":null,"retryable":null,"disk_free_bytes":302847139840,"disk_needed_bytes":8518440000,
         "retry":{"code":"network","attempt":1,"in_s":2},"futur":true}
        """.utf8))
        XCTAssertEqual(downloading.phase, "downloading")
        XCTAssertEqual(downloading.bytesTotal, 7_444_716_257)
        XCTAssertEqual(downloading.retry?.inS, 2)
        XCTAssertEqual(downloading.models?.first?.state, "ready")

        let failed = try JSONDecoder().decode(DaemonHealth.self, from: Data("""
        {"status":"error","error":"Il faut 8.5 Go libres","error_code":"disk_full","retryable":true}
        """.utf8))
        XCTAssertEqual(failed.errorCode, "disk_full")
        XCTAssertEqual(failed.retryable, true)

        let owned = try JSONDecoder().decode(DaemonHealth.self, from: Data("""
        {"status":"ready","error":"","pid":4242,"mode":"light","version":"0.1.1"}
        """.utf8))
        XCTAssertEqual(owned.pid, 4242)
        XCTAssertEqual(owned.mode, "light")
        XCTAssertEqual(owned.version, "0.1.1")
    }

    /// Le texte dicté écrit par les versions précédentes ne part pas avec « Copier le journal ».
    func testLogTailMasksDictatedText() {
        let log = """
        08:01:02 INFO Dictée 2.1s : 'mon code secret' -> 'Mon code secret.' (LLM : non, court)
        08:01:03 WARNING Sortie LLM rejetée, nettoyage de secours : "texte privé"
        08:01:04 INFO Démon prêt
        """
        let masked = DaemonManager.redactDictations(log)
        XCTAssertFalse(masked.contains("secret"))
        XCTAssertFalse(masked.contains("privé"))
        XCTAssertTrue(masked.contains("Dictée 2.1s : [texte masqué]"))
        XCTAssertTrue(masked.contains("Démon prêt"))
        // Format 0.1.1 : longueurs et durées, gardées telles quelles.
        let current = "08:00 INFO Dictée 2.1s : 14 -> 15 caractères (LLM : court, {'audio_s': 2.1})"
        XCTAssertEqual(DaemonManager.redactDictations(current), current)
    }
}

/// Les deux langues ont les mêmes clés et les mêmes marqueurs, et chaque clé citée
/// dans le code existe.
final class LocalizationTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func table(_ lang: String, _ name: String = "Localizable") throws -> [String: String] {
        let url = root.appendingPathComponent("Resources/\(lang).lproj/\(name).strings")
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], url.path)
    }

    private func markers(_ text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: "%(\\d+\\$)?(@|ld|d)")
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { (text as NSString).substring(with: $0.range) }.sorted()
    }

    func testBothLanguagesMatch() throws {
        for name in ["Localizable", "InfoPlist"] {
            let fr = try table("fr", name)
            let en = try table("en", name)
            XCTAssertEqual(Set(fr.keys), Set(en.keys), name)
            for (key, value) in fr {
                XCTAssertFalse(value.isEmpty, key)
                XCTAssertEqual(markers(value), markers(en[key] ?? ""), key)
            }
        }
    }

    func testEveryKeyUsedInCodeExists() throws {
        let fr = try table("fr")
        let sources = root.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        let regex = try NSRegularExpression(pattern: #"L10n\.tr\("([a-zA-Z0-9_.]+)""#)
        var used = Set<String>()
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                used.insert((text as NSString).substring(with: match.range(at: 1)))
            }
        }
        XCTAssertGreaterThan(used.count, 50)
        for key in used { XCTAssertNotNil(fr[key], "clé absente : \(key)") }
        // Clés construites à l'exécution.
        for key in DictationKey.allCases {
            XCTAssertNotNil(fr["key.\(key.rawValue)"])
            XCTAssertNotNil(fr["key.\(key.rawValue).short"])
        }
        for mode in EngineMode.allCases {
            XCTAssertNotNil(fr["mode.\(mode.rawValue).name"])
            XCTAssertNotNil(fr["mode.\(mode.rawValue).detail"])
        }
        for code in ["network", "tls", "disk_full", "low_memory", "unsupported_cpu", "hub_unavailable", "hub_refused",
                     "integrity", "app_damaged", "crashed", "port_busy"] {
            XCTAssertNotNil(fr["failure.\(code).title"], code)
            XCTAssertNotNil(fr["failure.\(code).message"], code)
        }
        for key in ["menu.accessibility.on", "menu.accessibility.off", "menu.mic.on", "menu.mic.off",
                    "onboarding.key.globeOK", "onboarding.key.globeTodo", "onboarding.key.detected",
                    "onboarding.key.pressToCheck", "failure.unknown.title"] {
            XCTAssertNotNil(fr[key], key)
        }
    }
}
