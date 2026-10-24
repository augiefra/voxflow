import AppKit
import SwiftUI
import VoxFlowCore

/// `VoxFlow --snapshots <dossier>` : rend en PNG les pages de l'accueil, les états des
/// moteurs et les réglages, en clair et en sombre, sans démon ni autorisations ni écran.
/// La langue suit `-AppleLanguages`.
final class SnapshotDemo: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshots"), index + 1 < arguments.count else {
            NSApp.terminate(nil)
            return
        }
        let folder = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "com.ericcologni.voxflow.snapshots")!
        defaults.removePersistentDomain(forName: "com.ericcologni.voxflow.snapshots")
        let settings = VoxFlowSettings(defaults: defaults)
        settings.engineModeConfirmed = true // états d'une installation dont le mode est choisi
        let engine = EngineController(manager: DaemonManager(daemonDirectory: nil), client: InferenceClient(port: 1), settings: settings)
        let model = OnboardingModel(engine: engine, settings: settings)
        let downloading = { engine.simulate(.downloading, fraction: 0.42, done: 3_080_000_000, total: 7_444_716_257,
                                            speed: 118_000_000, eta: 37) }

        for (name, appearance) in [("clair", NSAppearance.Name.aqua), ("sombre", .darkAqua)] {
            for page in 0 ..< OnboardingModel.pageCount {
                model.page = page
                downloading()
                render(OnboardingView(model: model), size: NSSize(width: 620, height: 560), appearance: appearance,
                       to: folder.appendingPathComponent("accueil-\(page + 1)-\(name).png"))
            }
        }
        model.page = 3
        model.key = .rightCommand
        render(OnboardingView(model: model), size: NSSize(width: 620, height: 560), appearance: .aqua,
               to: folder.appendingPathComponent("accueil-4-commande-clair.png"))
        model.key = .fn
        model.page = 2
        (model.micGranted, model.axGranted) = (false, false)
        render(OnboardingView(model: model), size: NSSize(width: 620, height: 560), appearance: .aqua,
               to: folder.appendingPathComponent("accueil-3-a-autoriser-clair.png"))
        (model.micGranted, model.axGranted) = (true, true)

        let states: [(String, () -> Void)] = [
            ("preparation", { engine.simulate(.preparing, fraction: 0.01) }),
            ("telechargement", downloading),
            ("nouvel-essai", { engine.simulate(.waitingRetry(code: "network"), fraction: 0.42) }),
            ("chargement", { engine.simulate(.loading, fraction: 0.99) }),
            ("pret", { engine.simulate(.ready, fraction: 1) }),
            ("erreur-reseau", { engine.simulate(.failed(EngineFailure(code: "network", detail: "")), fraction: 0.42) }),
            ("erreur-disque", { engine.simulate(.failed(EngineFailure(code: "disk_full", detail: "", diskNeeded: 8_500_000_000,
                                                                     diskFree: 2_100_000_000)), fraction: 0.1) }),
            ("erreur-memoire", { engine.simulate(.failed(EngineFailure(code: "low_memory", detail: "", retryable: false)), fraction: 0.02) }),
        ]
        for (name, apply) in states {
            apply()
            render(EngineStatusView(engine: engine, compact: false).padding(20).frame(width: 620), size: NSSize(width: 620, height: 150),
                   appearance: .aqua, to: folder.appendingPathComponent("etat-\(name).png"))
        }
        model.page = 4
        engine.simulate(.ready, fraction: 1)
        render(OnboardingView(model: model), size: NSSize(width: 620, height: 560), appearance: .aqua,
               to: folder.appendingPathComponent("accueil-5-pret-clair.png"))

        downloading()
        let settingsModel = SettingsModel(engine: engine, settings: settings)
        // La vraie fenêtre des Réglages, à la taille qu'elle prend d'elle-même.
        for (name, appearance) in [("clair", NSAppearance.Name.aqua), ("sombre", .darkAqua)] {
            let controller = SettingsWindowController(model: settingsModel)
            guard let window = controller.window, let content = window.contentView else { continue }
            window.appearance = NSAppearance(named: appearance)
            content.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            print("Réglages (\(name)) : fenêtre \(window.contentLayoutRect.size), contenu idéal \(content.fittingSize)")
            capture(content, to: folder.appendingPathComponent("reglages-\(name).png"))
        }
        NSApp.terminate(nil)
    }

    private func render<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name, to url: URL) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        capture(host, to: url)
    }

    private func capture(_ view: NSView, to url: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
