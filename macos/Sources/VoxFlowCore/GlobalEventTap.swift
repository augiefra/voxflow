import ApplicationServices
import CoreGraphics
import Foundation

/// Unique `CGEventTap` de l'application : touche Fn (machine à états), frappes
/// pendant la surveillance post-collage, clics et défilements.
///
/// Le tap est actif (`.defaultTap`, qui demande la permission Accessibilité) mais
/// ne modifie ni ne bloque aucun événement : il les observe et les laisse passer.
/// Les événements synthétiques postés par VoxFlow (Cmd+V) portent un marqueur et
/// sont ignorés.
public final class GlobalEventTap {
    public enum Event {
        case flagsChanged(keyCode: Int64, flags: CGEventFlags)
        case keyDown(keyCode: Int64, flags: CGEventFlags, characters: String, isRepeat: Bool)
        case mouseDown
        /// Défilement de l'utilisateur (l'inertie qui suit est ignorée).
        case scroll
    }

    public typealias Handler = (Event) -> Void

    /// Valeur posée dans `eventSourceUserData` sur les événements que VoxFlow poste.
    public static let syntheticMarker: Int64 = 0x564F_5846 // "VOXF"

    private var handlers: [(id: UUID, handler: Handler)] = []
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    public init() {}

    deinit { stop() }

    public var isRunning: Bool {
        guard let tap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    @discardableResult
    public func addHandler(_ handler: @escaping Handler) -> UUID {
        let id = UUID()
        handlers.append((id, handler))
        return id
    }

    public func removeHandler(_ id: UUID) {
        handlers.removeAll { $0.id == id }
    }

    /// Crée le tap sur la boucle principale. Renvoie `false` sans permission Accessibilité.
    @discardableResult
    public func start() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon {
                let tap = Unmanaged<GlobalEventTap>.fromOpaque(refcon).takeUnretainedValue()
                tap.handle(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let machPort = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, machPort, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: machPort, enable: true)
        tap = machPort
        runLoopSource = source
        return true
    }

    public func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS coupe un tap jugé trop lent : on le réactive aussitôt.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        default:
            break
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker { return }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let translated: Event
        switch type {
        case .flagsChanged:
            translated = .flagsChanged(keyCode: keyCode, flags: event.flags)
        case .keyDown:
            translated = .keyDown(
                keyCode: keyCode,
                flags: event.flags,
                characters: Self.characters(of: event),
                isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            )
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            translated = .mouseDown
        case .scrollWheel:
            guard event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0 else { return }
            translated = .scroll
        default:
            return
        }
        for entry in handlers { entry.handler(translated) }
    }

    private static func characters(of event: CGEvent) -> String {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
        return String(utf16CodeUnits: buffer, count: length)
    }
}
