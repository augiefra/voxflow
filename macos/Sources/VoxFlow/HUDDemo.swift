import AppKit
import VoxFlowCore

/// `VoxFlow --hud-demo` : fait défiler les états de la pilule (sans micro ni Fn),
/// pour vérifier le rendu.
final class HUDDemo: NSObject, NSApplicationDelegate {
    private let hud = HUDController()
    private var levelTimer: Timer?
    private var t: Double = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.t += 0.03
            // Voix simulée : syllabes de 0,2 s, puis un silence en mains libres.
            let speaking = self.hud.current == .listening || (self.hud.current == .locked && self.t.truncatingRemainder(dividingBy: 4) < 2)
            self.hud.setLevel(speaking ? Float(0.45 + 0.4 * abs(sin(self.t * 15))) : 0)
        }
        // `--hud-demo <état>` fige un seul état 6 s (captures fiables) ; sans état, défilé complet.
        let learned = HUDState.learned("Appris : FacilAbo (au lieu de 'Facilabo')")
        let single: [String: HUDState] = ["ecoute": .listening, "verrouille": .locked, "traitement": .processing, "appris": learned]
        let arguments = CommandLine.arguments
        let requested = arguments.firstIndex(of: "--hud-demo").flatMap { $0 + 1 < arguments.count ? single[arguments[$0 + 1]] : nil }
        let steps: [(Double, HUDState?)] = requested.map { [(0.3, $0), (6.3, nil)] } ?? [
            (0.5, .listening), (3.5, .locked), (8.5, .processing), (10.5, learned), (13.5, nil),
        ]
        for (delay, state) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                if let state { self?.hud.show(state) } else { NSApp.terminate(nil) }
            }
        }
    }
}
