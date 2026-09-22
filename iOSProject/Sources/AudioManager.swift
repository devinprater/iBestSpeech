import Foundation
import AVFoundation

/// Plays a sample buffer through the app so the engine can be auditioned
/// without VoiceOver. This is not the path VoiceOver uses; the extension is.
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
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)

        do {
            try engine.start()
        } catch {
            lastError = "Could not start audio engine: \(error.localizedDescription)"
        }
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

        let sampleRate = Double(bst.sampleRate)
        guard sampleRate > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(pcm.count))
        else {
            lastError = "Could not prepare an audio buffer."
            return
        }

        let channel = buffer.floatChannelData![0]
        for i in 0..<pcm.count {
            channel[i] = Float(pcm[i]) / 32768.0
        }
        buffer.frameLength = AVAudioFrameCount(pcm.count)

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
}
