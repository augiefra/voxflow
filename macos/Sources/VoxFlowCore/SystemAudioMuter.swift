import AudioToolbox
import CoreAudio
import Foundation

/// Coupe la sortie audio du Mac pendant la dictée et la rétablit ensuite.
///
/// On ne touche à rien si le son était déjà coupé. Le périphérique coupé est noté
/// dans les préférences : si VoxFlow quitte en pleine dictée, il rétablit le son au
/// lancement suivant.
public final class SystemAudioMuter {
    private enum Method: String {
        case mute
        case volume
    }

    private struct Muted {
        let device: AudioDeviceID
        let uid: String
        let method: Method
        let previousVolume: Float32
    }

    private static let defaultsKey = "VoxFlowMutedOutput"
    private let defaults: UserDefaults
    private var muted: Muted?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var isMuting: Bool { muted != nil }

    /// Coupe la sortie par défaut. Renvoie vrai si VoxFlow a effectivement coupé le son.
    @discardableResult
    public func muteOutput() -> Bool {
        guard muted == nil, let device = Self.defaultOutputDevice(), let uid = Self.uid(of: device) else { return false }
        if Self.isSettable(device, kAudioDevicePropertyMute) {
            guard Self.uint32(device, kAudioDevicePropertyMute) == 0 else { return false }
            guard Self.setUInt32(device, kAudioDevicePropertyMute, 1) else { return false }
            remember(Muted(device: device, uid: uid, method: .mute, previousVolume: 0))
            return true
        }
        // Certains périphériques (HDMI, Bluetooth) n'ont pas de « mute » : volume à zéro.
        let volumeSelector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
        guard Self.isSettable(device, volumeSelector), let volume = Self.float32(device, volumeSelector), volume > 0,
              Self.setFloat32(device, volumeSelector, 0) else { return false }
        remember(Muted(device: device, uid: uid, method: .volume, previousVolume: volume))
        return true
    }

    /// Rétablit le son coupé par VoxFlow (sans effet sinon).
    public func restore() {
        guard let muted else { return }
        Self.apply(restoreOf: muted.method, device: muted.device, previousVolume: muted.previousVolume)
        self.muted = nil
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    /// Au lancement : rétablit un son resté coupé après un arrêt brutal de VoxFlow.
    public func restoreAfterCrashIfNeeded() {
        guard let saved = defaults.dictionary(forKey: Self.defaultsKey),
              let uid = saved["uid"] as? String,
              let method = (saved["method"] as? String).flatMap(Method.init(rawValue:)) else { return }
        defaults.removeObject(forKey: Self.defaultsKey)
        guard let device = Self.device(forUID: uid) else { return }
        Self.apply(restoreOf: method, device: device, previousVolume: Float32(saved["volume"] as? Double ?? 0.5))
    }

    private func remember(_ state: Muted) {
        muted = state
        defaults.set(["uid": state.uid, "method": state.method.rawValue, "volume": Double(state.previousVolume)],
                     forKey: Self.defaultsKey)
    }

    private static func apply(restoreOf method: Method, device: AudioDeviceID, previousVolume: Float32) {
        switch method {
        case .mute:
            _ = setUInt32(device, kAudioDevicePropertyMute, 0)
        case .volume:
            _ = setFloat32(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, previousVolume)
        }
    }

    // MARK: CoreAudio

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultOutputDevice() -> AudioDeviceID? {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private static func uid(of device: AudioDeviceID) -> String? {
        var address = address(kAudioDevicePropertyDeviceUID, scope: kAudioObjectPropertyScopeGlobal)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    private static func device(forUID uid: String) -> AudioDeviceID? {
        var address = address(kAudioHardwarePropertyTranslateUIDToDevice, scope: kAudioObjectPropertyScopeGlobal)
        var cfUID = uid as CFString
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { pointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), pointer, &size, &device)
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private static func isSettable(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> Bool {
        var address = address(selector)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    static func uint32(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func setUInt32(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector, _ value: UInt32) -> Bool {
        var address = address(selector)
        var value = value
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    private static func float32(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> Float32? {
        var address = address(selector)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func setFloat32(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector, _ value: Float32) -> Bool {
        var address = address(selector)
        var value = value
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }
}
