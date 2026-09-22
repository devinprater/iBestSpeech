import Foundation
import AVFoundation

class AudioManager: ObservableObject {
    let engine = AVAudioEngine()
    let playerNode = AVAudioPlayerNode()
    
    @Published var isSpeaking = false
    @Published var lastError: String?

    init() {
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)
        
        do {
            try engine.start()
        } catch {
            print("Audio Engine Error: \(error)")
        }
        
        // DEBUG: Automatically trigger synthesis for runtime testing
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.testSynthesis()
        }
    }

    func testSynthesis() {
        print("DEBUG: Starting automatic test synthesis...")
        speak(text: "Testing Keynote Gold on Simulator")
    }

    func speak(text: String) {
        guard let bst = OpenBST(build: "2006ENG") else {
            self.lastError = "Failed to initialize OpenBST engine"
            return
        }

        guard let pcm = bst.synthesize(text) else {
            self.lastError = "Synthesis failed for text: \(text)"
            return
        }

        let sampleRate = bst.sampleRate
        print("DEBUG: Synthesized \(pcm.count) samples at \(sampleRate)Hz")

        // Verify non-zero samples to ensure the engine actually produced audio
        let hasAudio = pcm.contains { $0 != 0 }
        print("DEBUG: Audio contains signal: \(hasAudio)")

        // Correct AVAudioFormat for Float32 PCM
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1) else {
            self.lastError = "Failed to create audio format"
            return
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.count)) else {
            self.lastError = "Failed to create audio buffer"
            return
        }
        
        // Fill the buffer with Float32 samples converted from Int16
        let channelData = buffer.floatChannelData![0]
        for i in 0..<pcm.count {
            channelData[i] = Float32(pcm[i]) / 32768.0
        }
        
        buffer.frameLength = AVAudioFrameCount(pcm.count)

        playerNode.stop()
        playerNode.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        playerNode.play()
        
        isSpeaking = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.isSpeaking = false
        }
    }
}
