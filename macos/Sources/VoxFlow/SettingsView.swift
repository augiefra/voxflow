import AppKit
import SwiftUI
import VoxFlowCore

/// Réglages : touche de dictée, moteurs complets ou légers, revoir l'accueil.
final class SettingsModel: ObservableObject {
    @Published var key: DictationKey
    @Published var keyHeld = false
    let engine: EngineController
    var onKeyChange: (DictationKey) -> Void = { _ in }
    var onShowOnboarding: () -> Void = {}

    init(engine: EngineController, settings: VoxFlowSettings) {
        self.engine = engine
        key = settings.dictationKey
    }

    func choose(_ newKey: DictationKey) {
        key = newKey
        onKeyChange(newKey)
    }
}

final class SettingsWindowController: NSWindowController {
    init(model: SettingsModel) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 430),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L10n.tr("settings.title")
        window.contentView = NSHostingView(rootView: SettingsView(model: model, engine: model.engine))
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var engine: EngineController

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.tr("settings.key")).font(.system(size: 13, weight: .semibold))
                HStack(spacing: 10) {
                    ForEach(DictationKey.allCases, id: \.self) { key in
                        KeyCap(key: key, selected: model.key == key, held: model.key == key && model.keyHeld) { model.choose(key) }
                    }
                }
                Text(model.key == .fn ? L10n.tr("settings.key.fnNote") : KeyCap.note(for: model.key))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(L10n.tr(model.keyHeld ? "onboarding.key.detected" : "onboarding.key.pressToCheck", model.key.displayName))
                    .font(.system(size: 11.5, weight: model.keyHeld ? .semibold : .regular))
                    .foregroundStyle(model.keyHeld ? Color.green : Color.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.tr("settings.engines")).font(.system(size: 13, weight: .semibold))
                HStack(spacing: 12) {
                    ModeCard(mode: .full, selected: engine.mode == .full) { engine.confirmAndSetMode(.full, confirming: true) }
                    ModeCard(mode: .light, selected: engine.mode == .light) { engine.confirmAndSetMode(.light, confirming: true) }
                }
                .frame(height: 168)
                EngineStatusView(engine: engine, compact: true)
            }
            HStack {
                Button(L10n.tr("settings.showOnboarding")) { model.onShowOnboarding() }
                Spacer()
                Button(L10n.tr("menu.openFolder")) {
                    try? FileManager.default.createDirectory(at: DaemonManager.dataDirectory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(DaemonManager.dataDirectory)
                }
            }
        }
        .padding(24)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
