import CoreGraphics
import Foundation

// MARK: - Machine à états pure (testable sans clavier)

public enum DictationMode: Equatable {
    case pushToTalk
    case locked
}

public enum DictationState: Equatable {
    /// Rien en cours.
    case idle
    /// Fn enfoncée, enregistrement en cours (push-to-talk ou premier tap).
    case pressed(since: TimeInterval)
    /// Premier tap court relâché : on attend un second appui (l'enregistrement continue).
    case awaitingSecondTap(releasedAt: TimeInterval)
    /// Second appui en cours.
    case secondPress(since: TimeInterval)
    /// Mains libres : la dictée continue jusqu'au prochain appui sur Fn.
    case lockedRecording
    /// Fn encore enfoncée après un arrêt ou une annulation : le relâchement est ignoré.
    case waitingForRelease

    public var isRecording: Bool {
        switch self {
        case .pressed, .awaitingSecondTap, .secondPress, .lockedRecording: return true
        case .idle, .waitingForRelease: return false
        }
    }
}

public enum DictationAction: Equatable {
    case startRecording
    case showMode(DictationMode)
    case stopAndProcess
    case cancelRecording
    case scheduleTimer(id: Int, after: TimeInterval)
}

public struct DictationTiming: Equatable {
    /// Au-delà, un appui maintenu est un push-to-talk.
    public var holdThreshold: TimeInterval = 0.300
    /// En deçà, un appui est un tap. Égal au seuil de maintien : pas de zone morte
    /// (avec 250 ms, un tap un peu appuyé annulait le double-tap à l'essai réel).
    public var tapMaxDuration: TimeInterval = 0.300
    /// Délai après le premier tap pour réappuyer (400 ms : rythme naturel d'un double-tap).
    public var doubleTapWindow: TimeInterval = 0.400

    public init() {}
}

/// Push-to-talk (maintien > 300 ms) et verrouillage par double-tap (< 250 ms, puis
/// second tap dans les 250 ms). L'enregistrement démarre dès le premier appui pour
/// ne perdre aucun mot ; il est annulé si le geste n'aboutit à aucun des deux modes.
public struct DictationStateMachine {
    public private(set) var state: DictationState = .idle
    /// Vrai pendant le traitement IA d'une dictée : un nouvel appui est ignoré.
    public var isBusy = false
    public let timing: DictationTiming
    private var timerGeneration = 0

    public init(timing: DictationTiming = DictationTiming()) {
        self.timing = timing
    }

    public mutating func fnDown(at time: TimeInterval) -> [DictationAction] {
        switch state {
        case .idle:
            guard !isBusy else { return [] }
            state = .pressed(since: time)
            return [.startRecording, .showMode(.pushToTalk)]
        case .awaitingSecondTap:
            timerGeneration += 1
            state = .secondPress(since: time)
            return []
        case .lockedRecording:
            state = .waitingForRelease
            return [.stopAndProcess]
        case .pressed, .secondPress, .waitingForRelease:
            return []
        }
    }

    public mutating func fnUp(at time: TimeInterval) -> [DictationAction] {
        switch state {
        case let .pressed(since):
            let held = time - since
            if held >= timing.holdThreshold {
                state = .idle
                return [.stopAndProcess]
            }
            if held < timing.tapMaxDuration {
                timerGeneration += 1
                state = .awaitingSecondTap(releasedAt: time)
                return [.scheduleTimer(id: timerGeneration, after: timing.doubleTapWindow)]
            }
            // Entre 250 et 300 ms : ni tap net ni maintien, on annule.
            state = .idle
            return [.cancelRecording]
        case let .secondPress(since):
            if time - since >= timing.holdThreshold {
                // Tap puis maintien : se comporte comme un push-to-talk.
                state = .idle
                return [.stopAndProcess]
            }
            state = .lockedRecording
            return [.showMode(.locked)]
        case .waitingForRelease:
            state = .idle
            return []
        case .idle, .awaitingSecondTap, .lockedRecording:
            return []
        }
    }

    public mutating func timerFired(id: Int) -> [DictationAction] {
        guard id == timerGeneration, case .awaitingSecondTap = state else { return [] }
        state = .idle
        return [.cancelRecording]
    }

    /// Une autre touche pendant que Fn est tenue (Fn+flèche, Fn+F1, Fn+E…) est un
    /// raccourci système, pas une dictée. Échap annule aussi le mode verrouillé.
    public mutating func otherKeyDown(isEscape: Bool) -> [DictationAction] {
        switch state {
        case .pressed, .secondPress:
            state = .waitingForRelease
            return [.cancelRecording]
        case .awaitingSecondTap:
            timerGeneration += 1
            state = .idle
            return [.cancelRecording]
        case .lockedRecording:
            guard isEscape else { return [] }
            state = .idle
            return [.cancelRecording]
        case .idle, .waitingForRelease:
            return []
        }
    }

    /// Arrêt imposé (durée maximale atteinte) : traite ce qui a été dicté.
    public mutating func forceStop() -> [DictationAction] {
        switch state {
        case .pressed, .secondPress:
            state = .waitingForRelease
        case .awaitingSecondTap, .lockedRecording:
            timerGeneration += 1
            state = .idle
        case .idle, .waitingForRelease:
            return []
        }
        return [.stopAndProcess]
    }

    /// Retour au repos (changement de touche). La génération des minuteries continue
    /// d'avancer : une minuterie de l'ancienne touche ne peut rien annuler.
    public mutating func reset() {
        timerGeneration += 1
        state = .idle
    }

    /// Annulation imposée (micro indisponible, démon absent…).
    public mutating func forceCancel() -> [DictationAction] {
        switch state {
        case .pressed, .secondPress:
            state = .waitingForRelease
        case .awaitingSecondTap, .lockedRecording:
            timerGeneration += 1
            state = .idle
        case .idle, .waitingForRelease:
            return []
        }
        return [.cancelRecording]
    }
}

// MARK: - Branchement sur le CGEventTap

public protocol FnKeyControllerDelegate: AnyObject {
    func fnKeyController(_ controller: DictationKeyController, perform action: DictationAction)
}

public typealias FnKeyController = DictationKeyController

/// Écoute le `CGEventTap`, détecte la touche de dictée et pilote la
/// `DictationStateMachine` (minuteries comprises) sur le thread principal.
///
/// Fn garde exactement son comportement historique. Une touche modificatrice suit en
/// plus la règle « raccourci » : le micro ne s'ouvre qu'après `armDelay` (150 ms) et
/// l'écoute ne se montre (`.showMode`) qu'après `confirmDelay` de plus ; une autre
/// touche, un clic, un défilement ou un autre modificateur avant cela annule sans rien
/// montrer. En mains libres, un appui ne termine la dictée qu'au relâchement d'un appui
/// resté seul (⌘V à droite en pleine dictée ne coupe pas l'écoute).
public final class DictationKeyController {
    public static let fnKeyCodes = ModifierTable.fnKeyCodes
    public static let escapeKeyCode: Int64 = 53

    public weak var delegate: FnKeyControllerDelegate?
    /// Journal des appuis (durées, transitions) pour régler les seuils.
    public var log: ((String) -> Void)?
    /// Appui (vrai) et relâchement (faux) de la touche : sert à l'essai de l'accueil.
    public var onKeyEdge: ((Bool) -> Void)?
    public private(set) var machine: DictationStateMachine
    public private(set) var key: DictationKey

    private let now: () -> TimeInterval
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private var keyIsDown = false
    private var lastEdge: TimeInterval = 0
    /// Vrai quand `.startRecording` a été transmis (micro ouvert).
    private var started = false
    private var armGeneration = 0
    /// Appui commencé alors qu'un autre modificateur était tenu : ignoré jusqu'au relâchement.
    private var ignoringPress = false
    /// Mains libres : appui en cours qui terminera la dictée s'il reste seul.
    private var lockedStopCandidate = false

    public init(
        tap: GlobalEventTap,
        key: DictationKey = .fn,
        timing: DictationTiming = DictationTiming(),
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, block in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block)
        }
    ) {
        machine = DictationStateMachine(timing: timing)
        self.key = key
        self.now = now
        self.schedule = schedule
        tap.addHandler { [weak self] event in self?.handle(event) }
    }

    public var state: DictationState { machine.state }

    public func setBusy(_ busy: Bool) { machine.isBusy = busy }

    public func forceStop() { route(machine.forceStop()) }

    public func forceCancel() { route(machine.forceCancel()) }

    /// Change de touche à chaud ; une dictée en cours est annulée.
    public func setKey(_ newKey: DictationKey) {
        guard newKey != key else { return }
        if machine.state != .idle { forceCancel() }
        machine.reset()
        if keyIsDown { onKeyEdge?(false) }
        keyIsDown = false
        ignoringPress = false
        lockedStopCandidate = false
        started = false
        armGeneration += 1
        key = newKey
        log?("Touche de dictée : \(newKey.rawValue)")
    }

    func handle(_ event: GlobalEventTap.Event) {
        switch event {
        case let .flagsChanged(keyCode, flags):
            if let down = key.isDown(keyCode: keyCode, flags: flags, wasDown: keyIsDown) {
                guard down != keyIsDown else { return }
                keyIsDown = down
                onKeyEdge?(down)
                down ? keyPressed(flags: flags) : keyReleased()
            } else if key.isModifier, keyIsDown || machine.state != .idle,
                      ModifierTable.isPress(keyCode: keyCode, flags: flags) {
                otherInput(isEscape: false, what: "modificateur \(keyCode)")
            }
        case let .keyDown(keyCode, _, _, _):
            // Après un appui bref sur 🌐, macOS émet aussi un keyDown 179 : c'est la touche
            // Fn elle-même, pas un raccourci (sinon chaque double-tap était annulé).
            if key == .fn, Self.fnKeyCodes.contains(keyCode) { return }
            otherInput(isEscape: keyCode == Self.escapeKeyCode, what: "touche \(keyCode)")
        case .mouseDown:
            // ⌘-clic, ⌥-clic… : raccourci, pas dictée. Fn garde son comportement (ignoré).
            guard key.isModifier else { return }
            otherInput(isEscape: false, what: "clic")
        case .scroll:
            // ⌃-défilement (zoom), ⌘-défilement… : raccourci aussi.
            guard key.isModifier else { return }
            otherInput(isEscape: false, what: "défilement")
        }
    }

    // MARK: Interne

    private func keyPressed(flags: CGEventFlags) {
        let time = now()
        if key.isModifier, ModifierTable.othersHeld(besides: key, flags: flags) {
            ignoringPress = true
            log?("\(key.symbol) ↓ avec un autre modificateur : ignoré")
            return
        }
        if key.isModifier, machine.state == .lockedRecording {
            lockedStopCandidate = true
            return
        }
        transition(down: true, at: time)
        if key.armDelay > 0, !started, isHeld(machine.state) { arm() }
    }

    private func keyReleased() {
        if ignoringPress {
            ignoringPress = false
            return
        }
        let time = now()
        if lockedStopCandidate {
            lockedStopCandidate = false
            transition(down: true, at: time)
        }
        transition(down: false, at: time)
    }

    private func transition(down: Bool, at time: TimeInterval) {
        let before = machine.state
        let actions = down ? machine.fnDown(at: time) : machine.fnUp(at: time)
        log?(String(format: "%@ %@ (+%.0f ms) %@ -> %@ %@", key.symbol, down ? "↓" : "↑", (time - lastEdge) * 1000,
                    "\(before)", "\(machine.state)", "\(actions)"))
        lastEdge = time
        route(actions)
    }

    /// Autre touche, clic ou modificateur pendant que la touche est tenue ou attendue.
    private func otherInput(isEscape: Bool, what: String) {
        if lockedStopCandidate {
            lockedStopCandidate = false // raccourci en mains libres : la dictée continue
            return
        }
        guard machine.state != .idle else { return }
        let actions = machine.otherKeyDown(isEscape: isEscape)
        if !actions.isEmpty { log?("\(what) pendant la dictée -> \(actions)\(started ? "" : " (silencieux)")") }
        route(actions)
    }

    private func isHeld(_ state: DictationState) -> Bool {
        switch state {
        case .pressed, .secondPress: return true
        default: return false
        }
    }

    private func arm() {
        armGeneration += 1
        let generation = armGeneration
        schedule(key.armDelay) { [weak self] in
            guard let self, generation == self.armGeneration, !self.started, self.isHeld(self.machine.state) else { return }
            self.started = true
            self.log?("\(self.key.symbol) tenue \(Int(self.key.armDelay * 1000)) ms : micro ouvert")
            self.dispatch([.startRecording])
            self.schedule(self.key.confirmDelay) { [weak self] in
                guard let self, generation == self.armGeneration, self.started, self.isHeld(self.machine.state) else { return }
                self.dispatch([.showMode(.pushToTalk)])
            }
        }
    }

    /// Filtre les actions d'une touche modificatrice tant que l'écoute n'a pas démarré.
    private func route(_ actions: [DictationAction]) {
        var out: [DictationAction] = []
        for action in actions {
            switch action {
            case .startRecording:
                if key.armDelay == 0 {
                    started = true
                    out.append(action)
                }
            case .showMode(.pushToTalk):
                if started { out.append(action) }
            case .showMode(.locked):
                if !started {
                    started = true
                    armGeneration += 1
                    out.append(.startRecording)
                }
                out.append(action)
            case .stopAndProcess, .cancelRecording:
                armGeneration += 1
                guard started else { continue } // rien n'a été montré : annulation silencieuse
                started = false
                out.append(action)
            case .scheduleTimer:
                out.append(action)
            }
        }
        dispatch(out)
    }

    private func dispatch(_ actions: [DictationAction]) {
        for action in actions {
            if case let .scheduleTimer(id, delay) = action {
                schedule(delay) { [weak self] in
                    guard let self else { return }
                    let actions = self.machine.timerFired(id: id)
                    if !actions.isEmpty { self.log?("Délai du second tap écoulé -> \(actions)") }
                    self.route(actions)
                }
            } else {
                delegate?.fnKeyController(self, perform: action)
            }
        }
    }
}
