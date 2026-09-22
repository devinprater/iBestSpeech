import Foundation
import AVFoundation

/// Drives `AVSpeechSynthesizer` with one of this app's own provider voices.
///
/// This is the path VoiceOver uses: the system instantiates the extension, hands
/// it SSML, and pulls rendered audio. Exercising it here proves the extension
/// works end to end, which the in-app engine test cannot — that one plays audio
/// from the app's own process and never touches the extension.
@MainActor
final class ExtensionProbe: NSObject, AVSpeechSynthesizerDelegate {

    private let synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<String, Never>?
    private var events: [String] = []

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Speaks `text` with `voice` and reports what the system did.
    func speak(_ text: String, voice: AVSpeechSynthesisVoice) async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            continuation = cont
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = voice
            synthesizer.speak(utterance)

            // Give up rather than hang if the extension never responds.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(15))
                self.finish("timed out; events=\(self.events.joined(separator: ","))")
            }
        }
    }

    private func finish(_ result: String) {
        guard let cont = continuation else { return }
        continuation = nil
        cont.resume(returning: result)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.events.append("started")
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.events.append("finished")
            self.finish("finished OK; events=\(self.events.joined(separator: ","))")
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.events.append("cancelled")
            self.finish("cancelled; events=\(self.events.joined(separator: ","))")
        }
    }
}
