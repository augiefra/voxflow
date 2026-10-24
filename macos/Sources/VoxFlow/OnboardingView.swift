import AppKit
import AVFoundation
import Combine
import SwiftUI
import VoxFlowCore

/// État de l'accueil : page, autorisations relues chaque seconde, touche choisie.
final class OnboardingModel: ObservableObject {
    static let pageCount = 5

    @Published var page = 0
    @Published var micGranted = AudioCapture.permissionGranted
    @Published var axGranted = AXHelper.isTrusted(prompt: false)
    @Published var globeOK = OnboardingModel.globeKeyFree
    @Published var keyHeld = false {
        didSet { if keyHeld, !oldValue, page == 3 { announce(L10n.tr("onboarding.key.detected", key.displayName)) } }
    }
    @Published var key: DictationKey
    @Published var testText = ""

    let engine: EngineController
    var onKeyChange: (DictationKey) -> Void = { _ in }
    var onFinish: () -> Void = {}
    private var timer: Timer?

    init(engine: EngineController, settings: VoxFlowSettings) {
        self.engine = engine
        key = settings.dictationKey
    }

    /// Réglages › Clavier › « Appuyer sur 🌐 pour » : « Ne rien faire » (0). Clé absente
    /// (réglage jamais touché) : le défaut de macOS n'est pas « Ne rien faire ».
    static var globeKeyFree: Bool {
        (UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int) == 0
    }

    func startWatching() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshPermissions() }
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    func refreshPermissions() {
        let mic = AudioCapture.permissionGranted
        let ax = AXHelper.isTrusted(prompt: false)
        let globe = Self.globeKeyFree
        // Autorisation accordée dans Réglages Système : l'accueil revient au premier plan.
        if (mic && !micGranted) || (ax && !axGranted) { onPermissionGranted() }
        if mic != micGranted { micGranted = mic }
        if ax != axGranted { axGranted = ax }
        if globe != globeOK { globeOK = globe }
    }

    var onPermissionGranted: () -> Void = {}

    private func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    func requestMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AudioCapture.requestPermission { [weak self] _ in self?.refreshPermissions() }
        } else {
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        }
    }

    func requestAccessibility() {
        _ = AXHelper.isTrusted(prompt: true)
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openKeyboardSettings() {
        open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    }

    func choose(_ newKey: DictationKey) {
        key = newKey
        onKeyChange(newKey)
    }

    func choose(_ newMode: EngineMode) {
        engine.confirmAndSetMode(newMode)
    }

    func next() {
        if page < Self.pageCount - 1 { page += 1 } else { onFinish() }
    }

    func back() {
        if page > 0 { page -= 1 }
    }

    private func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}

// MARK: - Fenêtre

final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    let model: OnboardingModel
    var onClose: () -> Void = {}

    init(model: OnboardingModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.title = L10n.tr("onboarding.windowTitle")
        window.contentView = NSHostingView(rootView: OnboardingView(model: model))
        window.center()
        super.init(window: window)
        window.delegate = self
        model.onPermissionGranted = { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.window?.makeKeyAndOrderFront(nil)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Le temps de l'accueil, VoxFlow a une icône dans le Dock et une place dans ⌘Tab :
    /// on le retrouve après un passage par Réglages Système.
    func present() {
        model.refreshPermissions()
        model.startWatching()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.stopWatching()
        NSApp.setActivationPolicy(.accessory)
        onClose()
    }
}

// MARK: - Vues

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.page {
                case 0: WelcomePage()
                case 1: EnginesPage(model: model)
                case 2: PermissionsPage(model: model)
                case 3: KeyPage(model: model)
                default: TryPage(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 48)
            .padding(.top, 36)

            EngineStatusView(engine: model.engine, compact: false)
                .padding(.horizontal, 48)
                .padding(.bottom, 16)

            HStack {
                Button(L10n.tr("onboarding.back")) { model.back() }
                    .opacity(model.page == 0 ? 0 : 1)
                    .disabled(model.page == 0)
                Spacer()
                PageDots(count: OnboardingModel.pageCount, current: model.page)
                Spacer()
                Button(model.page == OnboardingModel.pageCount - 1 ? L10n.tr("onboarding.finish") : L10n.tr("onboarding.next")) {
                    model.next()
                }
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(.bar)
        }
        .frame(width: 620, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct PageTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.system(size: 24, weight: .semibold)).multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle).font(.system(size: 13.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0 ..< count, id: \.self) { index in
                Circle().fill(index == current ? Color.primary : Color.secondary.opacity(0.35)).frame(width: 7, height: 7)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(L10n.tr("onboarding.pageOf", current + 1, count))
    }
}

/// La pilule de dictée, animée : point rouge, vagues, chrono. Fixe si « Réduire les
/// animations » est activé.
struct PillAnimation: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let t = reduceMotion ? 1.2 : context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 10) {
                Circle().fill(Color(red: 1, green: 0.27, blue: 0.23)).frame(width: 9, height: 9)
                    .opacity(0.65 + 0.35 * sin(t * 4.5))
                HStack(spacing: 3) {
                    ForEach(0 ..< 9, id: \.self) { index in
                        let phase = sin(t * 7 + Double(index) * 0.8) * sin(t * 2.3 + Double(index))
                        Capsule().fill(.white).frame(width: 3, height: 5 + 15 * abs(phase))
                    }
                }
                .frame(height: 22)
                Text(String(format: "0:%02d", Int(t) % 60 % 10 + 1)).font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color(white: 0.73))
            }
            .padding(.horizontal, 20)
            .frame(height: 42)
            .background(Capsule().fill(Color(white: 0.07)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        }
        .accessibilityHidden(true)
    }
}

private struct WelcomePage: View {
    var body: some View {
        VStack(spacing: 26) {
            Spacer()
            PillAnimation()
            PageTitle(title: L10n.tr("onboarding.welcome.title"), subtitle: L10n.tr("onboarding.welcome.subtitle"))
            VStack(alignment: .leading, spacing: 10) {
                Bullet(symbol: "lock.fill", text: L10n.tr("onboarding.welcome.private"))
                Bullet(symbol: "bolt.fill", text: L10n.tr("onboarding.welcome.fast"))
                Bullet(symbol: "brain.head.profile", text: L10n.tr("onboarding.welcome.learns"))
            }
            Spacer()
        }
    }
}

private struct Bullet: View {
    let symbol: String
    let text: String

    var body: some View {
        Label {
            Text(text).font(.system(size: 13))
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
        }
    }
}

private struct EnginesPage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var engine: EngineController

    init(model: OnboardingModel) {
        self.model = model
        engine = model.engine
    }

    private var footnote: String {
        let memory = L10n.memory(ProcessInfo.processInfo.physicalMemory)
        let free = (try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage)
            .flatMap { $0 }.map { L10n.bytes($0) } ?? "?"
        return L10n.tr("onboarding.engines.footnote", memory, free)
    }

    var body: some View {
        VStack(spacing: 22) {
            PageTitle(title: L10n.tr("onboarding.engines.title"), subtitle: L10n.tr("onboarding.engines.subtitle"))
            HStack(spacing: 14) {
                ModeCard(mode: .full, selected: engine.mode == .full) { model.choose(.full) }
                ModeCard(mode: .light, selected: engine.mode == .light) { model.choose(.light) }
            }
            .frame(height: 168)
            Text(footnote).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer(minLength: 0)
        }
    }
}

struct ModeCard: View {
    let mode: EngineMode
    let selected: Bool
    let action: () -> Void
    /// Mode refusé par le démon sur ce Mac (complet sous 16 Go).
    private var possible: Bool { mode.isPossible() }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L10n.tr("mode.\(mode.rawValue).name")).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                }
                Text(L10n.bytes(mode.downloadBytes)).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Text(L10n.tr("mode.\(mode.rawValue).detail")).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !possible {
                    Text(L10n.tr("mode.full.needsMemory")).font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        .foregroundStyle(.secondary)
                } else if mode == EngineMode.recommended() {
                    Text(L10n.tr("mode.recommended")).font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .foregroundStyle(Color.accentColor)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(!possible)
        .opacity(possible ? 1 : 0.55)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct PermissionsPage: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 22) {
            PageTitle(title: L10n.tr("onboarding.permissions.title"), subtitle: L10n.tr("onboarding.permissions.subtitle"))
            VStack(spacing: 12) {
                PermissionRow(symbol: "mic.fill", title: L10n.tr("permission.mic.title"),
                              detail: L10n.tr("permission.mic.detail"), granted: model.micGranted,
                              button: L10n.tr("permission.allow")) { model.requestMicrophone() }
                PermissionRow(symbol: "keyboard", title: L10n.tr("permission.ax.title"),
                              detail: L10n.tr("permission.ax.detail"), granted: model.axGranted,
                              button: L10n.tr("permission.openSettings")) { model.requestAccessibility() }
            }
            if !model.axGranted {
                Text(L10n.tr("permission.ax.hint")).font(.system(size: 12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct PermissionRow: View {
    let symbol: String
    let title: String
    let detail: String
    let granted: Bool
    let button: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 18)).frame(width: 28).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if granted {
                Label(L10n.tr("permission.granted"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.system(size: 13, weight: .medium))
            } else {
                Button(button, action: action)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

private struct KeyPage: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 20) {
            PageTitle(title: L10n.tr("onboarding.key.title"), subtitle: L10n.tr("onboarding.key.subtitle"))
            HStack(spacing: 10) {
                ForEach(DictationKey.allCases, id: \.self) { key in
                    KeyCap(key: key, selected: model.key == key, held: model.key == key && model.keyHeld) { model.choose(key) }
                }
            }
            if model.key == .fn {
                HStack(spacing: 10) {
                    Image(systemName: model.globeOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(model.globeOK ? Color.green : Color.orange)
                    Text(L10n.tr(model.globeOK ? "onboarding.key.globeOK" : "onboarding.key.globeTodo"))
                        .font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                    if !model.globeOK { Button(L10n.tr("onboarding.key.openKeyboard")) { model.openKeyboardSettings() } }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            } else {
                Text(KeyCap.note(for: model.key))
                    .font(.system(size: 12.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(model.axGranted
                ? L10n.tr(model.keyHeld ? "onboarding.key.detected" : "onboarding.key.pressToCheck", model.key.displayName)
                : L10n.tr("onboarding.key.needsAccessibility"))
                .font(.system(size: 12.5, weight: model.keyHeld ? .semibold : .regular))
                .foregroundStyle(model.keyHeld ? Color.green : Color.secondary)
            Spacer(minLength: 0)
        }
    }
}

struct KeyCap: View {
    let key: DictationKey
    let selected: Bool
    var held = false
    let action: () -> Void

    /// Note sous une touche modificatrice : raccourcis préservés, clavier externe pour ⌃,
    /// conflit possible avec le raccourci de la Dictée de macOS (« deux appuis sur ⌘ »…).
    static func note(for key: DictationKey) -> String {
        var parts = [L10n.tr("onboarding.key.modifierNote", key.symbol)]
        if key.needsExternalKeyboard { parts.append(L10n.tr("key.externalKeyboard")) }
        if macDictationEnabled { parts.append(L10n.tr("key.macDictation")) }
        return parts.joined(separator: " ")
    }

    static var macDictationEnabled: Bool {
        UserDefaults(suiteName: "com.apple.assistant.support")?.bool(forKey: "Dictation Enabled") ?? false
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text(key == .fn ? "fn  🌐" : key.symbol).font(.system(size: key == .fn ? 17 : 24, weight: .medium))
                    .frame(height: 30)
                Text(L10n.tr("key.\(key.rawValue).short")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(width: 112, height: 82)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(held ? Color.green.opacity(0.18) : Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(key.displayName)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct TryPage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var engine: EngineController
    @FocusState private var focused: Bool

    init(model: OnboardingModel) {
        self.model = model
        engine = model.engine
    }

    var body: some View {
        VStack(spacing: 18) {
            PageTitle(title: L10n.tr("onboarding.try.title"), subtitle: L10n.tr("onboarding.try.subtitle", model.key.displayName))
            TextEditor(text: $model.testText)
                .font(.system(size: 14))
                .focused($focused)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(height: 110)
                .accessibilityLabel(L10n.tr("onboarding.try.field"))
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.3)))
            Text(engine.isReady ? L10n.tr("onboarding.try.ready") : L10n.tr("onboarding.try.notReady"))
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .onAppear { focused = true }
    }
}

// MARK: - Avancement des moteurs (accueil et réglages)

struct EngineStatusView: View {
    @ObservedObject var engine: EngineController
    let compact: Bool

    var body: some View {
        if let failure = engine.failure {
            VStack(alignment: .leading, spacing: 8) {
                Label(EngineController.title(for: failure), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.orange)
                Text(EngineController.message(for: failure)).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if engine.autoRetryScheduled {
                    Text(L10n.tr("engine.autoRetry")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                HStack {
                    if failure.retryable {
                        Button(L10n.tr("engine.retry")) { engine.retry() }
                    }
                    if engine.mode == .full, !["unsupported_cpu", "app_damaged", "port_busy"].contains(failure.code) {
                        Button(L10n.tr("engine.switchToLight")) { engine.setMode(.light) }
                    }
                    if failure.code == "disk_full" {
                        Button(L10n.tr("engine.openStorage")) {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!)
                        }
                    }
                    Button(L10n.tr("engine.copyLog")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(DaemonManager.logTail(), forType: .string)
                    }
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.08)))
        } else if engine.isReady {
            Label(engine.statusLine, systemImage: "checkmark.circle.fill")
                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(.green)
                .frame(maxWidth: .infinity, alignment: compact ? .leading : .center)
        } else {
            VStack(alignment: compact ? .leading : .center, spacing: 6) {
                ProgressView(value: engine.fraction).progressViewStyle(.linear)
                    .frame(maxWidth: compact ? .infinity : 340)
                Text(compact ? engine.statusLine : L10n.tr("onboarding.background", engine.statusLine))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if let detail = engine.detailLine {
                    Text(detail).font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: compact ? .leading : .center)
        }
    }
}
