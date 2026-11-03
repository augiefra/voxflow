import AVFAudio
import Darwin
import Foundation
import Speech

private func uptime() -> Double { ProcessInfo.processInfo.systemUptime }

private func processCPUSeconds() -> Double {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
    let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
    return user + system
}

private actor ResultsLog {
    private let startedAt: Double
    private var inputEndedAt: Double?
    private var firstVolatileAt: Double?
    private var firstFinalAt: Double?
    private var lastFinalAt: Double?
    private var finalTexts: [String] = []
    private var finalCount = 0
    private var volatileCount = 0
    private var failure: String?

    init(startedAt: Double) { self.startedAt = startedAt }

    func markInputEnded(at time: Double) { inputEndedAt = time }

    func record(_ result: SpeechTranscriber.Result, at time: Double) {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isFinal {
            finalCount += 1
            finalTexts.append(text)
            if firstFinalAt == nil { firstFinalAt = time }
            lastFinalAt = time
        } else {
            volatileCount += 1
            if firstVolatileAt == nil { firstVolatileAt = time }
        }
    }

    func recordFailure(_ error: Error) { failure = String(describing: error) }

    func snapshot() -> (String, Int, Int, Double?, Double?, Double?, Double?, String?) {
        let firstVolatileMs = firstVolatileAt.map { ($0 - startedAt) * 1000 }
        let firstFinalMs = firstFinalAt.map { ($0 - startedAt) * 1000 }
        let finalAfterStopMs = lastFinalAt.flatMap { end in inputEndedAt.map { (end - $0) * 1000 } }
        let lastFinalMs = lastFinalAt.map { ($0 - startedAt) * 1000 }
        return (finalTexts.joined(separator: " "), finalCount, volatileCount,
                firstVolatileMs, firstFinalMs, finalAfterStopMs, lastFinalMs, failure)
    }
}

@main
struct SpeechBench {
    static func main() async {
        guard CommandLine.arguments.count == 2 else {
            fputs("usage: speech_bench <french.wav|aiff>\n", stderr)
            exit(64)
        }

        let audioURL = URL(fileURLWithPath: CommandLine.arguments[1])
        do {
            try await run(audioURL)
        } catch {
            fputs("ERROR: \(error)\n", stderr)
            exit(1)
        }
    }

    static func run(_ audioURL: URL) async throws {
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw BenchError.message("audio file not found: \(audioURL.path)")
        }
        guard SpeechTranscriber.isAvailable else {
            throw BenchError.message("SpeechTranscriber.isAvailable is false on this Mac")
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "fr-FR")) else {
            throw BenchError.message("fr-FR is not in SpeechTranscriber.supportedLocales")
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let previousReservations = await AssetInventory.reservedLocales
        let hadReservation = previousReservations.contains { $0.identifier == locale.identifier }
        var reservedByBench = false
        if !hadReservation {
            reservedByBench = try await AssetInventory.reserve(locale: locale)
        }
        let status = await AssetInventory.status(forModules: [transcriber])
        guard status == .installed else {
            if reservedByBench { _ = await AssetInventory.release(reservedLocale: locale) }
            throw BenchError.message("Speech assets are \(status); benchmark will not download/install models")
        }

        do {
            try await runInstalled(audioURL, transcriber: transcriber)
        } catch {
            if reservedByBench { _ = await AssetInventory.release(reservedLocale: locale) }
            throw error
        }
        if reservedByBench { _ = await AssetInventory.release(reservedLocale: locale) }
    }

    static func runInstalled(_ audioURL: URL, transcriber: SpeechTranscriber) async throws {
        let file = try AVAudioFile(forReading: audioURL)
        let sourceFormat = file.processingFormat
        let sampleRate = sourceFormat.sampleRate
        guard sampleRate > 0, file.length > 0 else {
            throw BenchError.message("audio file has no frames or a zero sample rate")
        }
        guard let analysisFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber], considering: sourceFormat
        ) else {
            throw BenchError.message("SpeechAnalyzer returned no compatible audio format")
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let converter = AnalyzerInputConverter(analyzerFormat: analysisFormat)
        let (inputSequence, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        let startedCPU = processCPUSeconds()
        let prepStarted = uptime()
        try await analyzer.prepareToAnalyze(in: analysisFormat)
        let prepareMs = (uptime() - prepStarted) * 1000

        let resultLog = ResultsLog(startedAt: uptime())
        let resultTask = Task {
            do {
                for try await result in transcriber.results {
                    await resultLog.record(result, at: uptime())
                }
            } catch {
                await resultLog.recordFailure(error)
            }
        }
        try await analyzer.start(inputSequence: inputSequence)
        let feedStarted = uptime()
        let audioDuration = Double(file.length) / sampleRate
        let chunkFrames = AVAudioFrameCount(max(1, Int(sampleRate * 0.2)))
        var framesSent: Int64 = 0
        var inputCount = 0

        while framesSent < file.length {
            let remaining = file.length - framesSent
            let requested = AVAudioFrameCount(min(Int64(chunkFrames), remaining))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: requested) else {
                throw BenchError.message("could not allocate an audio buffer")
            }
            try file.read(into: buffer, frameCount: requested)
            let frames = Int64(buffer.frameLength)
            guard frames > 0 else { break }
            let audioTime = AVAudioTime(sampleTime: AVAudioFramePosition(framesSent), atRate: sampleRate)
            for input in try converter.convert(buffer, at: audioTime) {
                inputContinuation.yield(input)
                inputCount += 1
            }
            framesSent += frames
            let deadline = feedStarted + Double(framesSent) / sampleRate
            let delay = deadline - uptime()
            if delay > 0 {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        for input in try converter.flush() {
            inputContinuation.yield(input)
            inputCount += 1
        }

        let inputEndedAt = uptime()
        await resultLog.markInputEnded(at: inputEndedAt)
        inputContinuation.finish()
        let finalizeStarted = uptime()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        await resultTask.value
        let finishedAt = uptime()
        let cpuSeconds = processCPUSeconds() - startedCPU
        let summary = await resultLog.snapshot()

        print("audio=\(audioURL.path)")
        print("locale=\(transcriber.selectedLocales.map(\.identifier).joined(separator: ","))")
        print(String(format: "audio_duration_s=%.3f", audioDuration))
        print(String(format: "prepare_ms=%.1f", prepareMs))
        print("input_buffers=\(inputCount)")
        if let value = summary.3 { print(String(format: "first_volatile_from_start_ms=%.1f", value)) }
        else { print("first_volatile_from_start_ms=none") }
        if let value = summary.4 { print(String(format: "first_final_from_start_ms=%.1f", value)) }
        else { print("first_final_from_start_ms=none") }
        if let value = summary.5 { print(String(format: "last_final_after_input_end_ms=%.1f", value)) }
        else { print("last_final_after_input_end_ms=none") }
        print(String(format: "finalize_call_to_stream_end_ms=%.1f", (finishedAt - finalizeStarted) * 1000))
        print(String(format: "process_cpu_s_including_prepare_feed_finalize=%.3f", cpuSeconds))
        print("final_result_count=\(summary.1)")
        print("volatile_result_count=\(summary.2)")
        print("transcript=\(summary.0)")
        if let failure = summary.7 { print("result_stream_error=\(failure)") }
    }
}

private enum BenchError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case .message(let value): return value }
    }
}
