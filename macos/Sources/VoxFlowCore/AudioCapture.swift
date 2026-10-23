import AVFoundation
import Foundation

/// Niveau de voix 0…1 à partir du RMS (dBFS), au-dessus d'un bruit de fond appris :
/// le souffle de la pièce reste à 0, seule la voix fait monter les vagues.
public struct VoiceLevelMeter {
    /// Bruit de fond estimé : suit aussitôt les creux, remonte lentement (~10 s).
    public private(set) var noiseFloor: Float = -60
    /// Marge au-dessus du bruit de fond avant de considérer qu'il y a de la voix.
    public var gateMargin: Float = 8
    /// Plage (dB) de voix qui va de 0 à 1.
    public var range: Float = 28

    public init() {}

    public mutating func level(forDecibels decibels: Float) -> Float {
        if decibels < noiseFloor {
            noiseFloor = decibels
        } else {
            noiseFloor += (decibels - noiseFloor) * 0.002
        }
        noiseFloor = min(max(noiseFloor, -75), -25)
        return min(1, max(0, (decibels - noiseFloor - gateMargin) / range))
    }
}

/// Capture micro via `AVAudioEngine`, convertie en PCM Float32 16 kHz mono.
/// Les blocs sont livrés au fil de l'eau (sur le thread audio) pour être envoyés
/// au démon pendant que l'utilisateur parle.
public final class AudioCapture {
    public enum CaptureError: Error, LocalizedError {
        case noInputDevice
        case converterUnavailable

        public var errorDescription: String? {
            switch self {
            case .noInputDevice: return "Aucun micro disponible"
            case .converterUnavailable: return "Conversion audio 16 kHz impossible"
            }
        }
    }

    public static let sampleRate: Double = 16_000

    /// Appelé sur le thread audio avec des échantillons 16 kHz mono.
    public var onSamples: (([Float]) -> Void)?
    /// Niveau 0…1 (RMS en dB normalisé), appelé sur le thread audio.
    public var onLevel: ((Float) -> Void)?

    public private(set) var isRunning = false

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioCapture.sampleRate,
                                             channels: 1, interleaved: false)!
    private var configObserver: NSObjectProtocol?
    private var meter = VoiceLevelMeter()

    public init() {
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            // Changement de micro (AirPods branchés…) : on reconstruit la chaîne.
            guard let self, self.isRunning else { return }
            self.stop()
            try? self.start()
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    public static var permissionGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    public static func requestPermission(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    public func start() throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw CaptureError.noInputDevice }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CaptureError.converterUnavailable
        }
        self.converter = converter
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.converter = nil
            throw error
        }
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        isRunning = false
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter, buffer.frameLength > 0 else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var delivered = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if delivered {
                inputStatus.pointee = .noDataNow
                return nil
            }
            delivered = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0, let channel = output.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        onSamples?(samples)

        if let onLevel {
            let meanSquare = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)
            onLevel(meter.level(forDecibels: 10 * log10(max(meanSquare, 1e-10))))
        }
    }
}
