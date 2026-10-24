import AppKit

public enum HUDState: Equatable {
    case listening
    case locked
    case processing
    case learned(String)
    /// Message bref et positif (« VoxFlow est prêt »).
    case notice(String)
    case error(String)
}

/// Panneau qui ne prend jamais le focus (sinon le collage partirait dans le HUD).
final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Vagues façon Apple Music

/// Barres verticales arrondies qui suivent la voix : plates et immobiles en silence
/// (le chrono montre que l'écoute continue), plus hautes au centre quand tu parles.
final class WaveformView: NSView {
    private let barCount = 8
    private let barWidth: CGFloat = 3
    private let spacing: CGFloat = 2.5
    private let minHeight: CGFloat = 3
    private var bars: [CALayer] = []
    private var heights: [CGFloat]
    private var targets: [CGFloat]
    private var level: CGFloat = 0
    private var frameCount = 0
    /// Silhouette des vagues : barres centrales plus hautes.
    private let envelope: [CGFloat] = [0.45, 0.65, 0.85, 1, 1, 0.85, 0.65, 0.45]
    private var timer: Timer?
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    var color: NSColor = .white {
        didSet { bars.forEach { $0.backgroundColor = color.cgColor } }
    }

    override init(frame: NSRect) {
        heights = Array(repeating: 3, count: barCount)
        targets = Array(repeating: 0.3, count: barCount)
        super.init(frame: frame)
        wantsLayer = true
        for _ in 0..<barCount {
            let bar = CALayer()
            bar.cornerRadius = barWidth / 2
            bar.backgroundColor = color.cgColor
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing, height: 18)
    }

    /// Niveau 0…1 : montée rapide, retombée douce.
    func setLevel(_ value: Float) {
        let target = CGFloat(max(0, min(1, value)))
        level = target > level ? level + (target - level) * 0.7 : level + (target - level) * 0.3
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        level = 0
    }

    private func tick() {
        frameCount += 1
        // Légère variation entre barres ~8 fois par seconde, seulement quand il y a de la voix.
        if frameCount % 4 == 0 {
            targets = targets.map { _ in reduceMotion ? 1 : CGFloat.random(in: 0.7...1.0) }
        }
        let maxHeight = bounds.height
        for index in 0..<barCount {
            let voiced = level * envelope[index] * targets[index] * (maxHeight - minHeight)
            let goal = min(maxHeight, minHeight + voiced)
            heights[index] += (goal - heights[index]) * 0.5
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            let x = CGFloat(index) * (barWidth + spacing)
            bar.frame = CGRect(x: x, y: (maxHeight - heights[index]) / 2, width: barWidth, height: heights[index])
        }
        CATransaction.commit()
    }
}

// MARK: - Pilule « Dynamic Island »

/// Pilule noire en bas au centre de l'écran actif, au-dessus du Dock :
/// point rouge + vagues + chrono (écoute), cadenas + vagues + chrono + stop (mains
/// libres), étincelles + « Mise en forme… » (traitement IA), puis toasts.
public final class HUDController {
    private let height: CGFloat = 34
    private let panel: NonActivatingPanel
    private let stack = NSStackView()
    private let leadingIcon = NSImageView()
    private let recordDot = NSView()
    private let wave = WaveformView(frame: NSRect(x: 0, y: 0, width: 38, height: 18))
    private let label = NSTextField(labelWithString: "")
    private let clock = NSTextField(labelWithString: "0:00")
    private let stopIcon = NSImageView()
    private var clockTimer: Timer?
    private var recordingStart: Date?
    private var hideWork: DispatchWorkItem?
    private var pendingToast: String?
    public private(set) var current: HUDState?

    private static let red = NSColor(srgbRed: 1, green: 0.27, blue: 0.23, alpha: 1)
    private static let orange = NSColor(srgbRed: 1, green: 0.62, blue: 0.04, alpha: 1)
    private static let cyan = NSColor(srgbRed: 0.39, green: 0.82, blue: 1, alpha: 1)
    private static let green = NSColor(srgbRed: 0.19, green: 0.82, blue: 0.35, alpha: 1)
    private static let yellow = NSColor(srgbRed: 1, green: 0.84, blue: 0.04, alpha: 1)
    private static let secondary = NSColor(white: 0.73, alpha: 1)

    public init() {
        panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let background = NSView()
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor(white: 0.07, alpha: 1).cgColor
        background.layer?.cornerRadius = height / 2
        background.layer?.cornerCurve = .continuous
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor(white: 1, alpha: 0.08).cgColor
        panel.contentView = background

        recordDot.wantsLayer = true
        recordDot.layer?.backgroundColor = Self.red.cgColor
        recordDot.layer?.cornerRadius = 3.5
        leadingIcon.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        stopIcon.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: L10n.tr("a11y.stopHint"))
        stopIcon.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        stopIcon.contentTintColor = Self.secondary
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.textColor = NSColor(white: 0.9, alpha: 1)
        label.lineBreakMode = .byTruncatingMiddle
        clock.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        clock.textColor = Self.secondary

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [recordDot, leadingIcon, wave, label, clock, stopIcon] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(view)
        }
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            recordDot.widthAnchor.constraint(equalToConstant: 7),
            recordDot.heightAnchor.constraint(equalToConstant: 7),
            wave.widthAnchor.constraint(equalToConstant: wave.intrinsicContentSize.width),
            wave.heightAnchor.constraint(equalToConstant: 18),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
    }

    public func show(_ state: HUDState) {
        // Un toast « Appris » n'interrompt pas une dictée : il attend la fin.
        if case let .learned(message) = state, let current, !isTransient(current) {
            pendingToast = message
            return
        }
        hideWork?.cancel()
        current = state
        configure(for: state)
        layoutAndPresent()

        if isTransient(state) {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.8, execute: work)
        }
    }

    public func hide() {
        hideWork?.cancel()
        current = nil
        stopRecordingVisuals()
        pulse(leadingIcon, false)
        pulse(recordDot, false)
        panel.orderOut(nil)
        if let toast = pendingToast {
            pendingToast = nil
            show(.learned(toast))
        }
    }

    public func setLevel(_ level: Float) {
        wave.setLevel(level)
    }

    // MARK: Interne

    private func configure(for state: HUDState) {
        let recording = state == .listening || state == .locked
        recordDot.isHidden = state != .listening
        leadingIcon.isHidden = state == .listening
        wave.isHidden = !recording
        clock.isHidden = !recording
        stopIcon.isHidden = state != .locked
        label.isHidden = recording
        pulse(leadingIcon, state == .processing)
        pulse(recordDot, state == .listening)

        switch state {
        case .listening, .locked:
            if state == .locked {
                setIcon("lock.fill", Self.orange, L10n.tr("a11y.locked"))
                wave.color = Self.orange
            } else {
                wave.color = .white
            }
            startRecordingVisuals()
        case .processing:
            stopRecordingVisuals()
            setIcon("sparkles", Self.cyan, L10n.tr("a11y.processing"))
            label.stringValue = L10n.tr("hud.processing")
        case let .learned(message):
            stopRecordingVisuals()
            setIcon("checkmark.circle.fill", Self.green, L10n.tr("a11y.learned"))
            label.stringValue = message
        case let .notice(message):
            stopRecordingVisuals()
            setIcon("checkmark.circle.fill", Self.green, message)
            label.stringValue = message
        case let .error(message):
            stopRecordingVisuals()
            setIcon("exclamationmark.triangle.fill", Self.yellow, L10n.tr("a11y.error"))
            label.stringValue = message
        }
    }

    private func setIcon(_ symbol: String, _ color: NSColor, _ description: String) {
        leadingIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        leadingIcon.contentTintColor = color
    }

    /// Le chrono démarre à la première écoute et continue en passant en mains libres.
    private func startRecordingVisuals() {
        if recordingStart == nil { recordingStart = Date() }
        updateClock()
        wave.start()
        guard clockTimer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.updateClock() }
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    private func stopRecordingVisuals() {
        wave.stop()
        clockTimer?.invalidate()
        clockTimer = nil
        recordingStart = nil
    }

    private func updateClock() {
        let elapsed = Int(Date().timeIntervalSince(recordingStart ?? Date()))
        clock.stringValue = String(format: "%d:%02d", elapsed / 60, elapsed % 60)
    }

    private func isTransient(_ state: HUDState) -> Bool {
        switch state {
        case .learned, .notice, .error: return true
        case .listening, .locked, .processing: return false
        }
    }

    private func pulse(_ view: NSView, _ on: Bool) {
        view.wantsLayer = true
        if on {
            guard view.layer?.animation(forKey: "pulse") == nil else { return }
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 1
            animation.toValue = 0.35
            animation.duration = 0.7
            animation.autoreverses = true
            animation.repeatCount = .infinity
            view.layer?.add(animation, forKey: "pulse")
        } else {
            view.layer?.removeAnimation(forKey: "pulse")
        }
    }

    private func layoutAndPresent() {
        stack.layoutSubtreeIfNeeded()
        let width = max(height * 2, ceil(stack.fittingSize.width))
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: visible.midX - width / 2, y: visible.minY + 24)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        // L'ombre suit la forme de la fenêtre : à recalculer à chaque changement de largeur,
        // sinon l'ancienne silhouette reste dessinée autour de la pilule.
        panel.invalidateShadow()
        panel.orderFrontRegardless()
    }
}
