import Foundation
import AVFoundation

/// Plays a sample buffer through the app so the engine can be auditioned
/// without VoiceOver. This is not the path VoiceOver uses; the extension is.
///
/// `AVAudioPlayerNode.scheduleBuffer` raises an Objective-C exception unless the
/// buffer's format is an exact match for the node's output format, and that
/// exception is not catchable in Swift — it aborts the process. The engine's
/// builds are mono at 10000/10800/11025 Hz while the node runs at the hardware
/// format, so every utterance is converted with an AVAudioConverter first.
///
/// The engine is started lazily and shut down once idle. An AVAudioEngine left
/// running holds the audio hardware open and keeps the app's audio session
/// active for the life of the process, which is felt as lag whenever the main
/// thread contends with it — most visibly when a twenty-row picker is pushed
/// and popped.
@MainActor
final class AudioManager: ObservableObject {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    @Published private(set) var isSpeaking = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastSpokenWith: String?
    @Published var selectedBuild: String = VoiceCatalog.englishBuild

    /// Populated straight from the library, so the picker can never offer a
    /// build the linked engine does not actually carry.
    let availableBuilds: [String] = OpenBST.availableBuilds()

    /// Picker display values, resolved once.
    ///
    /// The label carries the language, and looking that up inside the picker body
    /// re-ran the lookup for all twenty rows on every render. Pushing and popping
    /// the picker then did twenty dictionary walks per frame, which is what the
    /// lag in the voice list was.
    let buildChoices: [String] = VoiceCatalog.all
        .map(\.build)
        .filter { OpenBST.availableBuilds().contains($0) }

    private var idleTimer: Task<Void, Never>?
    private var graphReady = false

    init() {
        // Tell the system to rebuild its voice list. Without this the provider's
        // voices are not enumerated, however correct the extension's plist is:
        // the system caches the voice list and only rebuilds it when asked.
        AVSpeechSynthesisProviderVoice.updateSpeechVoices()

        #if DEBUG
        // Headless smoke check: `simctl launch … --selftest-speak` drives the
        // playback path without the UI, which is how the scheduleBuffer abort was
        // caught. The result is written to a file the host reads back, rather
        // than trusting that stdout was captured.
        if CommandLine.arguments.contains("--selftest-speak") {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                var report = ""
                for build in ["2006ENG", "2006RUS", "2006GRE", "2006ARA", "2006HEB", "2006JPN"] {
                    self.lastError = nil
                    self.speak(text: VoiceCatalog.sample(for: build), build: build)
                    report += "native \(build) -> \(self.lastSpokenWith ?? "NOTHING")"
                        + (self.lastError.map { "; note=\($0)" } ?? "") + "\n"
                }
                report += "\n-- Latin text handed to every build (expect English fallback, never silence) --\n"
                for build in VoiceCatalog.all.map(\.build) {
                    self.lastError = nil
                    self.speak(text: "The quick brown fox jumps over the lazy dog.", build: build)
                    let used = self.lastSpokenWith ?? "NOTHING"
                    let ok = used == build ? "spoke it directly" : "fell back to \(used)"
                    report += "latin \(build) -> \(ok)"
                        + (self.lastError.map { "; note=\($0)" } ?? "") + "\n"
                }

                // The decisive check: does the system list our provider's voices?
                // Apple's documentation is explicit that the system "takes up to
                // 30 seconds to refresh the list of available voices" after
                // updateSpeechVoices(), so this waits well past that rather than
                // concluding too early.
                try? await Task.sleep(for: .seconds(40))
                report += "\n-- system voices from speech-synthesis providers --\n"
                let systemVoices = AVSpeechSynthesisVoice.speechVoices()
                let ours = systemVoices.filter { $0.identifier.hasPrefix("com.devin.ibestspeech.") }
                report += "total system voices: \(systemVoices.count)\n"
                report += "iBestSpeech voices: \(ours.count)\n"
                for v in ours.prefix(5) {
                    report += "  \(v.identifier) name=\(v.name) lang=\(v.language)\n"
                }
                if ours.isEmpty {
                    report += "  (none — the extension is not being loaded)\n"
                }
                let url = URL.documentsDirectory.appending(path: "selftest.txt")
                try? report.write(to: url, atomically: true, encoding: .utf8)
                NSLog("[selftest]\n%@", report)
            }
        }
        #endif
    }

    // MARK: - Playback

    func speak(text: String) {
        speak(text: text, build: selectedBuild)
    }

    func speak(text: String, build: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = "There is no text to speak."
            return
        }

        let samples: [Int16]
        let rate: Int
        let usedBuild: String

        switch synthesize(trimmed, build: build) {
        case .success(let out):
            samples = out.samples
            rate = out.rate
            usedBuild = build
        case .needsEnglishFallback:
            // This build cannot read the script it was handed; English beats the
            // silence it would otherwise produce.
            guard build != VoiceCatalog.englishBuild,
                  case .success(let out) = synthesize(trimmed, build: VoiceCatalog.englishBuild)
            else {
                lastError = "The \(build) voice cannot read that text, and English produced no audio either."
                return
            }
            samples = out.samples
            rate = out.rate
            usedBuild = VoiceCatalog.englishBuild
            lastError = "The \(build) voice only reads its own script, so this was spoken with English."
        case .failure(let message):
            lastError = message
            return
        }

        guard !samples.isEmpty,
              let buffer = playbackBuffer(from: samples, sampleRate: Double(rate))
        else {
            if lastError == nil { lastError = "Could not prepare an audio buffer." }
            return
        }

        guard startEngineIfNeeded() else { return }

        lastSpokenWith = usedBuild
        if usedBuild == build { lastError = nil }

        playerNode.stop()
        isSpeaking = true

        playerNode.scheduleBuffer(buffer, at: nil, options: .interrupts) { [weak self] in
            // Fires on an audio thread; hop back before touching published state.
            Task { @MainActor in
                self?.isSpeaking = false
                self?.scheduleIdleShutdown()
            }
        }
        playerNode.play()
    }

    func stop() {
        playerNode.stop()
        isSpeaking = false
        scheduleIdleShutdown()
    }

    // MARK: - Synthesis and script handling

    private struct Utterance {
        let samples: [Int16]
        let rate: Int
    }

    private enum SynthesisOutcome {
        case success(Utterance)
        case needsEnglishFallback
        case failure(String)
    }

    private func synthesize(_ text: String, build: String) -> SynthesisOutcome {
        guard let info = VoiceCatalog.info(for: build) else {
            return .failure("Unknown voice \(build).")
        }
        guard let bst = OpenBST(build: build) else {
            return .failure("Could not open the \(build) voice.")
        }
        let rate = bst.sampleRate

        // A build that reads Latin takes the string as UTF-8.
        guard let codePage = info.codePage else {
            guard let samples = bst.synthesize(text), !samples.isEmpty else {
                return .failure("The \(build) voice produced no audio.")
            }
            return .success(Utterance(samples: samples, rate: rate))
        }

        // Otherwise the build's own code page is tried first: that is how its
        // original was driven and it gives the closest output. A build handed a
        // script it does not read returns a sample count and then all zeros, so
        // the result is checked for actual signal, not just for a length.
        if let bytes = text.encoded(as: codePage), !bytes.isEmpty {
            let samples = Array(bytes).withUnsafeBufferPointer { buf -> [Int16]? in
                bst.producesSpeech(for: buf) ? bst.synthesize(bytes: buf) : nil
            }
            if let samples, !samples.isEmpty {
                return .success(Utterance(samples: samples, rate: rate))
            }
        }

        // No representation in that code page, or the build read it as silence.
        return .needsEnglishFallback
    }

    // MARK: - Engine lifecycle

    private func startEngineIfNeeded() -> Bool {
        if engine.isRunning { return true }

        activateSession()

        if !graphReady {
            // Connect at the mixer's own format. Passing nil leaves the node at
            // whatever the graph picks, and a mismatch against a scheduled buffer
            // is an assertion failure rather than an error to handle.
            engine.attach(playerNode)
            let mixerFormat = engine.mainMixerNode.outputFormat(forBus: 0)
            engine.connect(playerNode, to: engine.mainMixerNode, format: mixerFormat)
            graphReady = true
        }

        do {
            engine.prepare()
            try engine.start()
            return true
        } catch {
            lastError = "Could not start the audio engine: \(error.localizedDescription)"
            return false
        }
    }

    /// Releases the audio hardware after a short idle so the app stops competing
    /// with the main thread while nothing is playing.
    private func scheduleIdleShutdown() {
        idleTimer?.cancel()
        idleTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, !self.isSpeaking else { return }
                self.engine.stop()
                try? AVAudioSession.sharedInstance()
                    .setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }

    private func activateSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
        } catch {
            lastError = "Could not configure the audio session: \(error.localizedDescription)"
        }
    }

    /// Converts the engine's mono 16-bit samples into the player node's format.
    ///
    /// The returned buffer matches the node's output format, which is the
    /// precondition `scheduleBuffer` enforces.
    private func playbackBuffer(from pcm: [Int16], sampleRate: Double) -> AVAudioPCMBuffer? {
        guard sampleRate > 0,
              let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                               channels: 1),
              let source = AVAudioPCMBuffer(pcmFormat: sourceFormat,
                                            frameCapacity: AVAudioFrameCount(pcm.count))
        else { return nil }

        let channel = source.floatChannelData![0]
        for i in 0..<pcm.count {
            channel[i] = Float(pcm[i]) / 32768.0
        }
        source.frameLength = AVAudioFrameCount(pcm.count)

        // The node's format is only known once the graph exists.
        if !graphReady {
            guard startEngineIfNeeded() else { return nil }
        }
        let targetFormat = playerNode.outputFormat(forBus: 0)
        guard targetFormat.sampleRate > 0, targetFormat.channelCount > 0 else {
            lastError = "The audio output is unavailable."
            return nil
        }
        if sourceFormat == targetFormat { return source }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            lastError = "Could not convert \(Int(sampleRate)) Hz mono for playback."
            return nil
        }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(pcm.count) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            lastError = "Could not allocate the output buffer."
            return nil
        }

        var consumed = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return source
        }

        if let conversionError {
            lastError = "Audio conversion failed: \(conversionError.localizedDescription)"
            return nil
        }
        guard output.frameLength > 0 else {
            lastError = "Audio conversion produced no samples."
            return nil
        }
        return output
    }
}
