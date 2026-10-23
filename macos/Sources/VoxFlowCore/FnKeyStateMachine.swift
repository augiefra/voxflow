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
    func fnKeyController(_ controller: FnKeyController, perform action: DictationAction)
}

/// Écoute `kCGEventFlagsChanged`, détecte Fn/Globe via `CGEventFlags.maskSecondaryFn`
/// et pilote la `DictationStateMachine` (minuteries comprises) sur le thread principal.
public final class FnKeyController {
    /// kVK_Function ; certains claviers récents envoient 179 pour la touche Globe.
    public static let fnKeyCodes: Set<Int64> = [63, 179]
    public static let escapeKeyCode: Int64 = 53

    public weak var delegate: FnKeyControllerDelegate?
    /// Journal des appuis (durées, transitions) pour régler les seuils.
    public var log: ((String) -> Void)?
    public private(set) var machine: DictationStateMachine
    private var fnIsDown = false
    private var lastFnEdge: TimeInterval = 0

    public init(tap: GlobalEventTap, timing: DictationTiming = DictationTiming()) {
        machine = DictationStateMachine(timing: timing)
        tap.addHandler { [weak self] event in self?.handle(event) }
    }

    public var state: DictationState { machine.state }

    public func setBusy(_ busy: Bool) { machine.isBusy = busy }

    public func forceStop() { dispatch(machine.forceStop()) }

    public func forceCancel() { dispatch(machine.forceCancel()) }

    func handle(_ event: GlobalEventTap.Event) {
        let now = ProcessInfo.processInfo.systemUptime
        switch event {
        case let .flagsChanged(keyCode, flags):
            guard Self.fnKeyCodes.contains(keyCode) else { return }
            let down = flags.contains(.maskSecondaryFn)
            guard down != fnIsDown else { return }
            fnIsDown = down
            let before = machine.state
            let actions = down ? machine.fnDown(at: now) : machine.fnUp(at: now)
            log?(String(format: "Fn %@ (+%.0f ms) %@ -> %@ %@", down ? "↓" : "↑", (now - lastFnEdge) * 1000,
                        "\(before)", "\(machine.state)", "\(actions)"))
            lastFnEdge = now
            dispatch(actions)
        case let .keyDown(keyCode, _, _, _):
            // Après un appui bref sur 🌐, macOS émet aussi un keyDown 179 : c'est la touche
            // Fn elle-même, pas un raccourci (sinon chaque double-tap était annulé).
            guard machine.state != .idle, !Self.fnKeyCodes.contains(keyCode) else { return }
            let actions = machine.otherKeyDown(isEscape: keyCode == Self.escapeKeyCode)
            if !actions.isEmpty { log?("Touche \(keyCode) pendant la dictée -> \(actions)") }
            dispatch(actions)
        case .mouseDown:
            break
        }
    }

    private func dispatch(_ actions: [DictationAction]) {
        for action in actions {
            if case let .scheduleTimer(id, delay) = action {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self else { return }
                    let actions = self.machine.timerFired(id: id)
                    if !actions.isEmpty { self.log?("Délai du second tap écoulé -> \(actions)") }
                    self.dispatch(actions)
                }
            } else {
                delegate?.fnKeyController(self, perform: action)
            }
        }
    }
}
