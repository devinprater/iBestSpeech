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
@MainActor
final class AudioManager: ObservableObject {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    @Published private(set) var isSpeaking = false
    @Published private(set) var lastError: String?
    @Published var selectedBuild: String = "2006ENG"

    /// Populated straight from the library, so the picker can never offer a
    /// build the linked engine does not actually carry.
    let availableBuilds: [String] = OpenBST.availableBuilds()

    init() {
        activateSession()

        engine.attach(playerNode)
        // Connect at the mixer's own format. Passing nil leaves the node at
        // whatever the graph picks, and a later mismatch against a scheduled
        // buffer is an assertion failure, not an error to handle.
        let mixerFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.connect(playerNode, to: engine.mainMixerNode, format: mixerFormat)

        do {
            try engine.start()
        } catch {
            lastError = "Could not start the audio engine: \(error.localizedDescription)"
        }

        #if DEBUG
        // Headless smoke check: `simctl launch … --selftest-speak` exercises the
        // playback path without driving the UI, which is how the scheduleBuffer
        // abort was caught. The result is written to a file so the host can read
        // it back rather than trusting that stdout was captured.
        if CommandLine.arguments.contains("--selftest-speak") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.speak(text: "Self test of the speech engine.")
                let note = "speak() returned normally; lastError=\(self?.lastError ?? "nil")\n"
                let url = URL.documentsDirectory.appending(path: "selftest.txt")
                try? note.write(to: url, atomically: true, encoding: .utf8)
                NSLog("[selftest] %@", note)
            }
        }
        #endif
    }

    func speak(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = "There is no text to speak."
            return
        }

        guard let bst = OpenBST(build: selectedBuild) else {
            lastError = "Could not open the \(selectedBuild) voice."
            return
        }

        guard let pcm = bst.synthesize(trimmed), !pcm.isEmpty else {
            lastError = "The \(selectedBuild) voice produced no audio for that text."
            return
        }

        guard let buffer = playbackBuffer(from: pcm, sampleRate: Double(bst.sampleRate)) else {
            if lastError == nil { lastError = "Could not prepare an audio buffer." }
            return
        }

        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                lastError = "The audio engine is not running: \(error.localizedDescription)"
                return
            }
        }

        lastError = nil
        playerNode.stop()
        isSpeaking = true

        playerNode.scheduleBuffer(buffer, at: nil, options: .interrupts) { [weak self] in
            // Fires on an audio thread; hop back before touching published state.
            Task { @MainActor in
                self?.isSpeaking = false
            }
        }
        playerNode.play()
    }

    func stop() {
        playerNode.stop()
        isSpeaking = false
    }

    // MARK: - Helpers

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
    /// The returned buffer is guaranteed to match the node's output format, which
    /// is the precondition `scheduleBuffer` enforces.
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
