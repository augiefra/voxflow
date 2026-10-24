import CoreGraphics
import Foundation

/// Touche de dictée : Fn/🌐 (par défaut) ou une touche modificatrice de droite.
///
/// Les touches de droite se reconnaissent à leur keyCode et au bit « côté droit » que
/// macOS pose dans `CGEventFlags.rawValue` (NX_DEVICERCMDKEYMASK etc., IOLLEvent.h).
public enum DictationKey: String, CaseIterable, Codable {
    case fn
    case rightCommand
    case rightOption
    case rightControl

    public var keyCodes: Set<Int64> {
        switch self {
        case .fn: return [63, 179] // 179 : touche Globe de certains claviers récents
        case .rightCommand: return [54]
        case .rightOption: return [61]
        case .rightControl: return [62]
        }
    }

    /// Bit propre à la touche de droite dans `flags.rawValue`.
    var deviceMask: UInt64? {
        switch self {
        case .fn: return nil
        case .rightCommand: return 0x10
        case .rightOption: return 0x40
        case .rightControl: return 0x2000
        }
    }

    var genericMask: CGEventFlags {
        switch self {
        case .fn: return .maskSecondaryFn
        case .rightCommand: return .maskCommand
        case .rightOption: return .maskAlternate
        case .rightControl: return .maskControl
        }
    }

    public var isModifier: Bool { self != .fn }

    /// Délai avant d'ouvrir le micro : laisse passer ⌘C, ⌥E… sans rien démarrer.
    public var armDelay: TimeInterval { isModifier ? 0.15 : 0 }

    /// Délai de plus avant de montrer l'écoute (pilule, son coupé) : un ⌘-clic ou un
    /// défilement un peu lent annule encore sans rien montrer.
    public var confirmDelay: TimeInterval { isModifier ? 0.15 : 0 }

    /// Les claviers intégrés des MacBook n'ont pas de touche Contrôle à droite.
    public var needsExternalKeyboard: Bool { self == .rightControl }

    /// Symbole court affiché dans le menu et l'accueil.
    public var symbol: String {
        switch self {
        case .fn: return "fn"
        case .rightCommand: return "⌘"
        case .rightOption: return "⌥"
        case .rightControl: return "⌃"
        }
    }

    /// Nom complet localisé : « Fn (🌐) », « ⌘ droite »…
    public var displayName: String { L10n.tr("key.\(rawValue)") }

    /// État de la touche d'après un `flagsChanged`, `nil` s'il ne la concerne pas.
    /// `wasDown` sert au repli des claviers qui n'envoient pas les bits de côté.
    public func isDown(keyCode: Int64, flags: CGEventFlags, wasDown: Bool) -> Bool? {
        guard isModifier, let deviceMask else {
            return keyCodes.contains(keyCode) ? flags.contains(.maskSecondaryFn) : nil
        }
        let raw = flags.rawValue
        // Plus aucun modificateur de ce type tenu : la touche est relâchée, même si un
        // événement s'est perdu.
        if raw & genericMask.rawValue == 0 { return wasDown ? false : nil }
        guard keyCodes.contains(keyCode) else { return nil }
        if raw & ModifierTable.allDeviceBits != 0 { return raw & deviceMask != 0 }
        return !wasDown // repli : bascule à chaque événement de la touche
    }
}

/// Bits « côté » de chaque touche modificatrice (IOLLEvent.h), par keyCode.
enum ModifierTable {
    static let deviceBits: [Int64: UInt64] = [
        54: 0x10, 55: 0x8, // ⌘ droite, gauche
        60: 0x4, 56: 0x2, // ⇧ droite, gauche
        61: 0x40, 58: 0x20, // ⌥ droite, gauche
        62: 0x2000, 59: 0x1, // ⌃ droite, gauche
    ]
    static let allDeviceBits: UInt64 = deviceBits.values.reduce(0, |)
    /// Repli des claviers sans bits de côté : masque générique de chaque keyCode.
    static let genericMaskByKeyCode: [Int64: CGEventFlags] = [
        54: .maskCommand, 55: .maskCommand, 60: .maskShift, 56: .maskShift,
        61: .maskAlternate, 58: .maskAlternate, 62: .maskControl, 59: .maskControl,
    ]
    static let fnKeyCodes: Set<Int64> = [63, 179]
    /// Verr. Maj (57) n'est jamais un modificateur « tenu ».
    static let genericMasks: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]

    /// Un modificateur autre que `key` vient-il d'être enfoncé ?
    static func isPress(keyCode: Int64, flags: CGEventFlags) -> Bool {
        if fnKeyCodes.contains(keyCode) { return flags.contains(.maskSecondaryFn) }
        guard let bit = deviceBits[keyCode] else { return false }
        if flags.rawValue & allDeviceBits != 0 { return flags.rawValue & bit != 0 }
        return genericMaskByKeyCode[keyCode].map(flags.contains) ?? false
    }

    /// Un autre modificateur est-il tenu au moment où `key` s'enfonce ?
    static func othersHeld(besides key: DictationKey, flags: CGEventFlags) -> Bool {
        let raw = flags.rawValue
        if raw & allDeviceBits != 0 {
            let others = allDeviceBits & ~(key.deviceMask ?? 0)
            return raw & others != 0 || flags.contains(.maskSecondaryFn)
        }
        return !flags.intersection(genericMasks).subtracting(key.genericMask).isEmpty
    }
}

/// Réglages de l'utilisateur, dans les UserDefaults de l'app (VOXFLOW_DEFAULTS_SUITE : une
/// suite à part, pour les essais « première installation »).
public final class VoxFlowSettings {
    public static let shared = VoxFlowSettings(
        defaults: ProcessInfo.processInfo.environment["VOXFLOW_DEFAULTS_SUITE"].flatMap(UserDefaults.init(suiteName:)) ?? .standard)
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var dictationKey: DictationKey {
        get { defaults.string(forKey: "dictationKey").flatMap(DictationKey.init(rawValue:)) ?? .fn }
        set { defaults.set(newValue.rawValue, forKey: "dictationKey") }
    }

    /// Mode des moteurs ; tant que l'utilisateur n'a pas choisi, celui conseillé pour ce Mac.
    public var engineMode: EngineMode {
        get { defaults.string(forKey: "engineMode").flatMap(EngineMode.init(rawValue:)) ?? .recommended() }
        set { defaults.set(newValue.rawValue, forKey: "engineMode") }
    }

    public var onboardingCompleted: Bool {
        get { defaults.bool(forKey: "onboardingCompleted") }
        set { defaults.set(newValue, forKey: "onboardingCompleted") }
    }
}

/// Complet : Voxtral + Qwen (mise en forme par IA). Léger : Voxtral seul (`--no-llm`).
public enum EngineMode: String, CaseIterable, Codable {
    case full
    case light

    /// Octets à télécharger (révisions figées dans daemon/model_store.py).
    public var downloadBytes: Int64 { self == .full ? 3_148_828_619 + 4_295_887_638 : 3_148_828_619 }

    /// Le mode complet monte à ~9 Gio de mémoire (mesuré sur M4 Pro) : le démon le refuse
    /// sous 16 Go (seuil 15,5 Gio, daemon/model_store.py `check_machine`).
    public static let fullMinimumMemory: UInt64 = 31 << 29

    public static func recommended(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> EngineMode {
        physicalMemory >= fullMinimumMemory ? .full : .light
    }

    /// Le démon accepte-t-il ce mode sur ce Mac ?
    public func isPossible(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Bool {
        self == .light || physicalMemory >= Self.fullMinimumMemory
    }
}
