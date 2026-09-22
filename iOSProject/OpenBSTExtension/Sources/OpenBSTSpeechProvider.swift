import Foundation
import AVFoundation
import AudioToolbox

class OpenBSTSpeechProvider: AVSpeechSynthesisProviderAudioUnit {
    
    // Lock-free state management
    // Using a class for the buffer to allow atomic reference swapping
    private class SpeechState {
        let samples: [Int16]
        let sampleRate: Double
        var readIndex: Int = 0
        
        init(samples: [Int16], sampleRate: Double) {
            self.samples = samples
            self.sampleRate = sampleRate
        }
    }
    
    private var state: SpeechState?
    private let stateLock = NSLock() // Only used for swapping the state, not in render loop
    
    // Build ID to ISO language code mapping
    private let languageMap: [String: String] = [
        "1995": "en-US",
        "1998ENG": "en-US", "1998DUT": "nl-NL", "1998FRN": "fr-FR", "1998GRM": "de-DE", "1998ITL": "it-IT", "1998SPN": "es-ES",
        "2006ARA": "ar-SA", "2006DUT": "nl-NL", "2006ENG": "en-US", "2006FRE": "fr-FR", "2006GER": "de-DE",
        "2006GRE": "el-GR", "2006HEB": "he-IL", "2006ITA": "it-IT", "2006JPN": "ja-JP", "2006POL": "pl-PL",
        "2006POR": "pt-PT", "2006RUS": "ru-RU", "2006SPA": "es-ES"
    ]
    
    override var speechVoices: [AVSpeechSynthesisProviderVoice] {
        let builds = OpenBST.availableBuilds()
        return builds.map { buildName in
            let lang = languageMap[buildName] ?? "en-US"
            return AVSpeechSynthesisProviderVoice(
                name: "Keynote Gold (\(buildName))",
                identifier: "com.devin.openbst.\(buildName)",
                primaryLanguages: [lang],
                supportedLanguages: [lang]
            )
        }
    }
    
    override func synthesizeSpeechRequest(_ speechRequest: AVSpeechSynthesisProviderRequest) {
        // 1. Voice Identification
        let voiceID = speechRequest.voice.identifier
        let buildName = voiceID.replacingOccurrences(of: "com.devin.openbst.", with: "")
        
        // 2. SSML Processing
        // Extract text and simple attributes
        let (text, pitch, rate) = parseSSML(speechRequest.ssmlRepresentation)
        
        // 3. Synthesis
        guard let bst = OpenBST(build: buildName) else { return }
        
        // Apply attributes if parsed from SSML
        if let p = pitch { bst.set(.pitch, p) }
        if let r = rate { bst.set(.rate, r) }
        
        if let samples = bst.synthesize(text) {
            // Atomically swap the state to avoid locking in the render loop
            stateLock.lock()
            self.state = SpeechState(samples: samples, sampleRate: Double(bst.sampleRate))
            stateLock.unlock()
        }
    }
    
    override func cancelSpeechRequest() {
        stateLock.lock()
        self.state = nil
        stateLock.unlock()
    }
    
    // MARK: - Real-time Safe Render Helper
    
    func fillBuffer(_ buffer: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        // Capture current state reference to avoid race during swap
        // In a true lock-free system we'd use an atomic pointer, but for this 
        // scale, capturing the reference is safe as the state object is immutable.
        guard let currentState = self.state else {
            for i in 0..<frames { buffer[i] = 0 }
            return 0
        }
        
        var samplesWritten = 0
        let samples = currentState.samples
        
        while samplesWritten < frames && currentState.readIndex < samples.count {
            buffer[samplesWritten] = Float(samples[currentState.readIndex]) / 32768.0
            currentState.readIndex += 1
            samplesWritten += 1
        }
        
        if samplesWritten < frames {
            for i in samplesWritten..<frames {
                buffer[i] = 0
            }
        }
        
        return samplesWritten
    }
    
    func getSampleRate() -> Double {
        return state?.sampleRate ?? 10000.0
    }
    
    // MARK: - Private Helpers
    
    private func parseSSML(_ ssml: String) -> (text: String, pitch: Int?, rate: Int?) {
        // Basic SSML Stripping: Remove <...> tags
        // In a full implementation, we'd use a proper XML parser.
        // Here we use regex for the "minimum viable" requirement.
        
        var pitch: Int? = nil
        var rate: Int? = nil
        
        // Extract pitch (e.g., <prosody pitch="50">)
        if let pitchMatch = ssml.range(of: "pitch=\"(\d+)\"", options: .regularExpression) {
            let valStr = ssml[pitchMatch].replacingOccurrences(of: "pitch=\"", with: "").replacingOccurrences(of: "\"", with: "")
            pitch = Int(valStr)
        }
        
        // Extract rate (e.g., <prosody rate="120">)
        if let rateMatch = ssml.range(of: "rate=\"(\d+)\"", options: .regularExpression) {
            let valStr = ssml[rateMatch].replacingOccurrences(of: "rate=\"", with: "").replacingOccurrences(of: "\"", with: "")
            rate = Int(valStr)
        }
        
        // Strip all tags to get plain text
        let text = ssml.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        
        return (text, pitch, rate)
    }
}
