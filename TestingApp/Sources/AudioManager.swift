import Foundation
import AVFoundation

class AudioManager: NSObject, ObservableObject {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    
    override init() {
        super.init()
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)
        
        do {
            try engine.start()
        } catch {
            print("AudioEngine start error: \(error)")
        }
    }
    
    func play(samples: [Int16], sampleRate: Double) {
        // Convert Int16 PCM to Float32 for AVAudioPCMBuffer
        let floatSamples = samples.map { Float(/bin/bash) / 32768.0 }
        
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(floatSamples.count))!
        
        buffer.frameLength = AVAudioFrameCount(floatSamples.count)
        let channelData = buffer.floatChannelData![0]
        
        for i in 0..<floatSamples.count {
            channelData[i] = floatSamples[i]
        }
        
        playerNode.stop()
        playerNode.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        playerNode.play()
    }
    
    func stop() {
        playerNode.stop()
    }
}
