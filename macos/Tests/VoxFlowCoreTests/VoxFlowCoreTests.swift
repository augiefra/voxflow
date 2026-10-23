import Carbon.HIToolbox
import CoreAudio
import CoreGraphics
import Foundation
import XCTest
@testable import VoxFlowCore

final class DictationStateMachineTests: XCTestCase {
    func testHoldIsPushToTalk() {
        var machine = DictationStateMachine()
        XCTAssertEqual(machine.fnDown(at: 10.0), [.startRecording, .showMode(.pushToTalk)])
        XCTAssertEqual(machine.fnUp(at: 10.45), [.stopAndProcess])
        XCTAssertEqual(machine.state, .idle)
    }

    func testDoubleTapLocksThenSinglePressStops() {
        var machine = DictationStateMachine()
        _ = machine.fnDown(at: 0)
        let release = machine.fnUp(at: 0.12)
        guard case let .scheduleTimer(id, delay)? = release.first else { return XCTFail("minuterie attendue") }
        XCTAssertEqual(delay, 0.40, accuracy: 0.0001)
        XCTAssertEqual(machine.fnDown(at: 0.45), [], "second appui 330 ms après le relâchement")
        XCTAssertEqual(machine.fnUp(at: 0.55), [.showMode(.locked)])
        XCTAssertEqual(machine.state, .lockedRecording)
        XCTAssertEqual(machine.timerFired(id: id), [], "la minuterie périmée ne doit rien annuler")
        XCTAssertEqual(machine.fnDown(at: 12.0), [.stopAndProcess])
        XCTAssertEqual(machine.fnUp(at: 12.1), [])
        XCTAssertEqual(machine.state, .idle)
    }

    func testSingleShortTapIsCancelled() {
        var machine = DictationStateMachine()
        _ = machine.fnDown(at: 0)
        guard case let .scheduleTimer(id, _)? = machine.fnUp(at: 0.1).first else { return XCTFail() }
        XCTAssertEqual(machine.timerFired(id: id), [.cancelRecording])
        XCTAssertEqual(machine.state, .idle)
    }

    func testSlightlyLongTapStillCountsAsTap() {
        var machine = DictationStateMachine()
        _ = machine.fnDown(at: 0)
        guard case .scheduleTimer? = machine.fnUp(at: 0.27).first else { return XCTFail("tap attendu") }
        _ = machine.fnDown(at: 0.5)
        XCTAssertEqual(machine.fnUp(at: 0.6), [.showMode(.locked)])
    }

    func testTapThenHoldBehavesLikePushToTalk() {
        var machine = DictationStateMachine()
        _ = machine.fnDown(at: 0)
        _ = machine.fnUp(at: 0.1)
        _ = machine.fnDown(at: 0.2)
        XCTAssertEqual(machine.fnUp(at: 1.5), [.stopAndProcess])
    }

    func testFnShortcutCancelsAndIgnoresRelease() {
        var machine = DictationStateMachine()
        _ = machine.fnDown(at: 0)
        XCTAssertEqual(machine.otherKeyDown(isEscape: false), [.cancelRecording])
        XCTAssertEqual(machine.fnUp(at: 0.5), [])
        XCTAssertEqual(machine.state, .idle)
    }

    func testTypingWhileLockedIsAllowedEscapeCancels() {
        var machine = DictationStateMachine()
        _ = machine.fnDown(at: 0); _ = machine.fnUp(at: 0.1); _ = machine.fnDown(at: 0.2); _ = machine.fnUp(at: 0.3)
        XCTAssertEqual(machine.otherKeyDown(isEscape: false), [])
        XCTAssertEqual(machine.otherKeyDown(isEscape: true), [.cancelRecording])
    }

    func testBusyIgnoresPress() {
        var machine = DictationStateMachine()
        machine.isBusy = true
        XCTAssertEqual(machine.fnDown(at: 0), [])
        XCTAssertEqual(machine.fnUp(at: 1), [])
    }
}

final class FnKeyControllerTests: XCTestCase {
    private final class Recorder: FnKeyControllerDelegate {
        var actions: [DictationAction] = []
        func fnKeyController(_ controller: FnKeyController, perform action: DictationAction) { actions.append(action) }
    }

    /// Essai réel : macOS envoie un keyDown 179 (touche Globe) après un tap bref.
    func testGlobeKeyDownBetweenTapsStillLocks() {
        let controller = FnKeyController(tap: GlobalEventTap())
        let recorder = Recorder()
        controller.delegate = recorder
        controller.handle(.flagsChanged(keyCode: 63, flags: .maskSecondaryFn))
        controller.handle(.flagsChanged(keyCode: 63, flags: []))
        controller.handle(.keyDown(keyCode: 179, flags: [], characters: "", isRepeat: false))
        controller.handle(.flagsChanged(keyCode: 63, flags: .maskSecondaryFn))
        controller.handle(.flagsChanged(keyCode: 63, flags: []))
        controller.handle(.keyDown(keyCode: 179, flags: [], characters: "", isRepeat: false))
        XCTAssertEqual(controller.state, .lockedRecording)
        XCTAssertFalse(recorder.actions.contains(.cancelRecording))
        controller.handle(.flagsChanged(keyCode: 63, flags: .maskSecondaryFn))
        XCTAssertEqual(recorder.actions.last, .stopAndProcess)
    }

    func testRealShortcutStillCancels() {
        let controller = FnKeyController(tap: GlobalEventTap())
        let recorder = Recorder()
        controller.delegate = recorder
        controller.handle(.flagsChanged(keyCode: 63, flags: .maskSecondaryFn))
        controller.handle(.keyDown(keyCode: 123, flags: .maskSecondaryFn, characters: "", isRepeat: false)) // Fn+←
        XCTAssertEqual(recorder.actions.last, .cancelRecording)
    }
}

final class DiffLearnerTests: XCTestCase {
    let learner = DiffLearner()

    func testLearnsCityName() {
        let result = learner.extract(
            initial: "On se retrouve à Allo demain matin pour la visite.",
            final: "On se retrouve à Allauch demain matin pour la visite.",
            bundleID: "com.apple.mail"
        )
        XCTAssertEqual(result, [LearnedCorrection(wrongVariant: "Allo", canonicalTerm: "Allauch",
                                                  contextHint: "se retrouve à … demain matin pour",
                                                  appBundleID: "com.apple.mail")])
    }

    func testLearnsMultiWordBrand() {
        let result = learner.extract(
            initial: "J'ai mis à jour l'app facil a beau ce matin.",
            final: "J'ai mis à jour l'app FacilAbo ce matin.",
            bundleID: "com.tinyspeck.slackmacgap"
        )
        XCTAssertEqual(result.map(\.wrongVariant), ["facil a beau"])
        XCTAssertEqual(result.map(\.canonicalTerm), ["FacilAbo"])
    }

    func testLearnsCasingOfJargon() {
        let result = learner.extract(initial: "Ouvre facilabo sur l'iPhone.", final: "Ouvre FacilAbo sur l'iPhone.", bundleID: "")
        XCTAssertEqual(result.map(\.canonicalTerm), ["FacilAbo"])
    }

    func testElisionAndTypographicApostrophe() {
        let result = learner.extract(
            initial: "Le rendez-vous avec la ville d'Allo s'est très bien passé.",
            final: "Le rendez-vous avec la ville d’Allauch s’est très bien passé.",
            bundleID: ""
        )
        XCTAssertEqual(result.map(\.wrongVariant), ["Allo"])
        XCTAssertEqual(result.map(\.canonicalTerm), ["Allauch"])
    }

    func testIgnoresGrammarFixesAndSentenceCase() {
        XCTAssertTrue(learner.extract(initial: "Il est content est fier.", final: "Il est content et fier.", bundleID: "").isEmpty)
        XCTAssertTrue(learner.extract(initial: "c'est parti. on y va", final: "C'est parti. On y va", bundleID: "").isEmpty)
    }

    func testIgnoresUnrelatedSubstitution() {
        XCTAssertTrue(learner.extract(initial: "Envoie le devis à Paul demain.", final: "Envoie le devis à Martine demain.", bundleID: "").isEmpty)
    }

    func testIgnoresRewrittenSentence() {
        let result = learner.extract(
            initial: "Je pense que Allo est une bonne idée pour demain.",
            final: "Finalement on annule tout Allauch reste fermé.",
            bundleID: ""
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testPhoneticKeys() {
        XCTAssertEqual(FrenchText.phonetic("facil a beau"), FrenchText.phonetic("FacilAbo"))
        XCTAssertEqual(FrenchText.phonetic("facile à beau"), "fasilabo")
        XCTAssertGreaterThanOrEqual(FrenchText.similarity(FrenchText.phonetic("Allo"), FrenchText.phonetic("Allauch")), 0.6)
    }
}

final class CorrectionCaptureTests: XCTestCase {
    func testSegmentExtractionIgnoresSurroundingText() {
        let before = "Bonjour Paul,\n"
        let inserted = "On se voit à Allo jeudi."
        let after = "\nCordialement"
        let initial = before + inserted + after
        let final = before + "On se voit à Allauch jeudi." + after
        let insertion = NSRange(location: (before as NSString).length, length: (inserted as NSString).length)
        let (a, b) = CorrectionSegments.extract(initialFull: initial, insertion: insertion, finalFull: final)
        // La zone comparée est tout le texte collé (la règle des 60 % a besoin de la phrase).
        XCTAssertEqual(a, inserted)
        XCTAssertEqual(b, "On se voit à Allauch jeudi.")
        XCTAssertEqual(DiffLearner().extract(initial: a, final: b, bundleID: "").first?.canonicalTerm, "Allauch")
    }

    func testLocateInsertedTextFromCaret() {
        let value = "Salut ! J'ai testé facil a beau hier. Fin"
        let inserted = "J'ai testé facil a beau hier."
        let caret = NSRange(location: ("Salut ! " + inserted as NSString).length, length: 0)
        XCTAssertEqual(PasteContext.locate(inserted, in: value, caret: caret), NSRange(location: 8, length: (inserted as NSString).length))
        XCTAssertNil(PasteContext.locate("absent", in: value, caret: caret))
    }

    func testShadowBufferReplaysCorrection() {
        var buffer = KeystrokeShadowBuffer(text: "cd facil a beau")
        let none: () -> String? = { nil }
        // Option+Backspace x3 efface « beau », « a », « facil », puis on tape la correction.
        for _ in 0..<3 {
            XCTAssertTrue(buffer.apply(keyCode: Int64(kVK_Delete), flags: .maskAlternate, characters: "\u{7f}", pasteboard: none))
        }
        for character in "FacilAbo" {
            XCTAssertTrue(buffer.apply(keyCode: 0, flags: [], characters: String(character), pasteboard: none))
        }
        XCTAssertEqual(buffer.text, "cd FacilAbo")
        XCTAssertTrue(buffer.apply(keyCode: Int64(kVK_LeftArrow), flags: .maskCommand, characters: "", pasteboard: none))
        XCTAssertFalse(buffer.apply(keyCode: Int64(kVK_LeftArrow), flags: [], characters: "", pasteboard: none),
                       "sortir de la zone collée arrête le suivi")
        XCTAssertFalse(buffer.apply(keyCode: Int64(kVK_UpArrow), flags: [], characters: "", pasteboard: none))
    }

    func testShadowBufferSelectionReplace() {
        var buffer = KeystrokeShadowBuffer(text: "va à Allo")
        let none: () -> String? = { nil }
        for _ in 0..<4 {
            XCTAssertTrue(buffer.apply(keyCode: Int64(kVK_LeftArrow), flags: .maskShift, characters: "", pasteboard: none))
        }
        XCTAssertTrue(buffer.apply(keyCode: 9, flags: .maskCommand, characters: "v", pasteboard: { "Allauch" }))
        XCTAssertEqual(buffer.text, "va à Allauch")
    }
}

final class VoiceLevelMeterTests: XCTestCase {
    func testRoomNoiseStaysFlatVoiceRises() {
        var meter = VoiceLevelMeter()
        // 3 s de bruit de pièce à -52 dBFS (~47 mesures par seconde).
        var noise: Float = 0
        for _ in 0..<140 { noise = meter.level(forDecibels: -52) }
        XCTAssertEqual(noise, 0, accuracy: 0.001, "le souffle de la pièce ne doit pas faire bouger les vagues")
        XCTAssertGreaterThan(meter.level(forDecibels: -25), 0.5, "une voix normale doit faire monter les vagues")
        XCTAssertEqual(meter.level(forDecibels: -52), 0, accuracy: 0.001, "retour au silence : vagues à plat")
    }
}

/// Coupe vraiment le son du Mac un instant : VOXFLOW_TEST_AUDIO=1 swift test --filter SystemAudioMuterTests
final class SystemAudioMuterTests: XCTestCase {
    func testMuteThenRestoreDefaultOutput() throws {
        guard ProcessInfo.processInfo.environment["VOXFLOW_TEST_AUDIO"] == "1" else { throw XCTSkip("test audio réel désactivé") }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "voxflow-test-\(UUID().uuidString)"))
        let muter = SystemAudioMuter(defaults: defaults)
        let device = try XCTUnwrap(SystemAudioMuter.defaultOutputDevice())
        let before = SystemAudioMuter.uint32(device, kAudioDevicePropertyMute)
        let didMute = muter.muteOutput()
        if before == 0 {
            XCTAssertTrue(didMute)
            if didMute, SystemAudioMuter.uint32(device, kAudioDevicePropertyMute) != nil {
                XCTAssertEqual(SystemAudioMuter.uint32(device, kAudioDevicePropertyMute), 1)
            }
        }
        muter.restore()
        XCTAssertEqual(SystemAudioMuter.uint32(device, kAudioDevicePropertyMute), before, "état d'origine rétabli")
        XCTAssertFalse(muter.isMuting)
    }
}

final class LexiconStoreTests: XCTestCase {
    func testRecordIncrementsFrequency() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voxflow-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try LexiconStore(url: url)
        let rule = LearnedCorrection(wrongVariant: "facil a beau", canonicalTerm: "FacilAbo", contextHint: "l'app … ce", appBundleID: "x")
        XCTAssertEqual(try store.record(rule), 1)
        let sameRuleOtherCase = LearnedCorrection(wrongVariant: "Facil a beau", canonicalTerm: "FacilAbo", contextHint: "", appBundleID: "y")
        XCTAssertEqual(try store.record(sameRuleOtherCase), 2)
        XCTAssertEqual(store.count(), 1)
        let row = try XCTUnwrap(store.recent().first)
        XCTAssertEqual(row.frequency, 2)
        try store.delete(id: row.id)
        XCTAssertEqual(store.count(), 0)
    }
}

/// Test d'intégration avec le démon en mode --mock (lancé à part) :
/// VOXFLOW_TEST_PORT=8797 VOXFLOW_TEST_TOKEN=/chemin/token swift test --filter DaemonProtocolTests
final class DaemonProtocolTests: XCTestCase {
    func testStreamingRoundTripWithMockDaemon() throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["VOXFLOW_TEST_PORT"].flatMap(Int.init), let token = env["VOXFLOW_TEST_TOKEN"] else {
            throw XCTSkip("démon de test non lancé")
        }
        let client = InferenceClient(port: port, tokenFile: URL(fileURLWithPath: token))
        let done = expectation(description: "final")
        client.begin(bundleID: "com.apple.TextEdit")
        for _ in 0..<20 { client.sendAudio([Float](repeating: 0, count: 1600)) } // 2 s de silence
        client.finish { result in
            switch result {
            case let .success(dictation):
                XCTAssertTrue(dictation.raw.contains("2.0 secondes"), dictation.raw)
                XCTAssertTrue(dictation.text.hasPrefix("FacilAbo test"), dictation.text)
                XCTAssertEqual(dictation.lexiconTerms, ["FacilAbo"])
            case let .failure(error):
                XCTFail(error.localizedDescription)
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 15)
    }
}

final class VoxFlowPathsTests: XCTestCase {
    func testMigrationCopiesLexiconAndTokenOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let legacy = root.appendingPathComponent("legacy"), target = root.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: legacy.appendingPathComponent("venv"), withIntermediateDirectories: true)
        try Data("db".utf8).write(to: legacy.appendingPathComponent("lexicon.db"))
        try Data("tok".utf8).write(to: legacy.appendingPathComponent("token"))
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(VoxFlowPaths.migrateLegacyDataIfNeeded(from: legacy, to: target), ["lexicon.db", "token"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("venv").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("lexicon.db").path))
        XCTAssertEqual(VoxFlowPaths.migrateLegacyDataIfNeeded(from: legacy, to: target), [])
    }
}
