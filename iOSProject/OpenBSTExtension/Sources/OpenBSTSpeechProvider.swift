import Foundation
import AVFoundation
import AudioToolbox

/// The rate this provider declares to the host.
///
/// The engine's builds run at 10000, 10800 or 11025 Hz depending on generation,
/// and the host picks a single output format when it instantiates the audio unit.
/// Declaring a fixed rate here and resampling during synthesis keeps playback at
/// the right pitch for every build; 22050 is the conventional choice for speech
/// providers.
private let kOutputSampleRate: Double = 22050.0

/// The system-wide voice provider behind iBestSpeech.
///
/// VoiceOver loads this as a speech synthesis provider extension. The audio unit
/// pulls samples on a real-time thread while `synthesizeSpeechRequest` runs on
/// another, so the render path must never allocate, take a lock, or block.
public final class OpenBSTSpeechProvider: AVSpeechSynthesisProviderAudioUnit {

    private static let voiceIdentifierPrefix = "com.devin.ibestspeech."

    /// Build ID to BCP-47 language tag. Every build the library carries must
    /// appear here or VoiceOver files the voice under the wrong language.
    private static let languageMap: [String: String] = [
        "1995": "en-US",
        "1998ENG": "en-US", "1998DUT": "nl-NL", "1998FRN": "fr-FR",
        "1998GRM": "de-DE", "1998ITL": "it-IT", "1998SPN": "es-ES",
        "2006ARA": "ar-SA", "2006DUT": "nl-NL", "2006ENG": "en-US",
        "2006FRE": "fr-FR", "2006GER": "de-DE", "2006GRE": "el-GR",
        "2006HEB": "he-IL", "2006ITA": "it-IT", "2006JPN": "ja-JP",
        "2006POL": "pl-PL", "2006POR": "pt-PT", "2006RUS": "ru-RU",
        "2006SPA": "es-ES",
    ]

    // MARK: - Audio unit plumbing

    private var _outputBusses: AUAudioUnitBusArray!
    private var outputBus: AUAudioUnitBus!

    public override init(componentDescription: AudioComponentDescription,
                         options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: kOutputSampleRate,
                                         channels: 1) else {
            throw NSError(domain: NSOSStatusErrorDomain,
                          code: Int(kAudioUnitErr_FormatNotSupported))
        }
        outputBus = try AUAudioUnitBus(format: format)
        _outputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
    }

    public override var outputBusses: AUAudioUnitBusArray { _outputBusses }

    // MARK: - Render state

    /// One synthesized utterance, already resampled to the output rate.
    ///
    /// Interpolation used to happen on the audio thread on every pull: two bounds
    /// checks, a divide and a branch per output frame. Resampling once during
    /// synthesis removes all of that from the real-time path, leaving the render
    /// block a plain copy — the most it should ever be asked to do.
    ///
    /// `position` is advanced only by the render thread, so no lock is needed.
    private final class SpeechState {
        let samples: [Float]
        var position: Int = 0

        init(samples: [Float]) { self.samples = samples }

        var isDrained: Bool { position >= samples.count }
    }

    private var state: SpeechState?
    private let stateLock = NSLock()   // guards swaps only; never taken in render

    /// The handle is kept between requests. Opening one costs about 0.05 ms, so
    /// recreating it per request would not be fatal, but keeping it also avoids
    /// re-reading the build's tables for every sentence VoiceOver speaks.
    private var engine: OpenBST?
    private var engineBuild: String?

    // MARK: - Voice registration

    public override var speechVoices: [AVSpeechSynthesisProviderVoice] {
        get {
            OpenBST.availableBuilds().map { build in
                let lang = Self.languageMap[build] ?? "en-US"
                return AVSpeechSynthesisProviderVoice(
                    name: "Keynote Gold (\(build))",
                    identifier: Self.voiceIdentifierPrefix + build,
                    primaryLanguages: [lang],
                    supportedLanguages: [lang]
                )
            }
        }
        set { /* The host may try to set this; the list is derived, not stored. */ }
    }

    // MARK: - Requests

    /// Pulls the build name out of a voice identifier.
    ///
    /// The system returns identifiers re-prefixed with the extension's bundle ID —
    /// it hands back "com.devin.ibestspeech.provider.com.devin.ibestspeech.2006ENG"
    /// for the identifier "com.devin.ibestspeech.2006ENG" that was registered.
    /// Matching on the last occurrence rather than a prefix is what keeps speech
    /// working.
    static func buildName(from identifier: String) -> String? {
        guard let range = identifier.range(of: voiceIdentifierPrefix, options: .backwards) else {
            return nil
        }
        let build = String(identifier[range.upperBound...])
        guard !build.isEmpty, OpenBST.availableBuilds().contains(build) else { return nil }
        return build
    }

    public override func synthesizeSpeechRequest(_ speechRequest: AVSpeechSynthesisProviderRequest) {
        guard let buildName = Self.buildName(from: speechRequest.voice.identifier),
              let bst = engineHandle(for: buildName)
        else {
            clearState()
            return
        }

        let parsed = SSMLText.parse(speechRequest.ssmlRepresentation)
        guard !parsed.pieces.isEmpty else {
            clearState()
            return
        }

        let sourceRate = Double(bst.sampleRate)
        let neutralPitch = EngineParameters.enginePitch(forVoiceOver: 50)
        let neutralRate = EngineParameters.engineRate(forVoiceOver: 0.5)

        var samples: [Float] = []
        var markers: [AVSpeechSynthesisMarker] = []

        for piece in parsed.pieces {
            switch piece {
            case .speech(let text, let pitch, let rate, _):
                guard !text.isEmpty else { continue }

                // Both settings are set every time, so a prosody element that
                // adjusts only one of them does not inherit the other's previous
                // value.
                bst.set(.pitch, pitch.map { EngineParameters.enginePitch(forVoiceOver: Double($0)) }
                        ?? neutralPitch)
                bst.set(.rate, rate.map { EngineParameters.engineRate(forVoiceOver: Double($0)) }
                        ?? neutralRate)

                guard let pcm = bst.synthesize(text), !pcm.isEmpty else { continue }

                if speechSynthesisOutputMetadataBlock != nil {
                    markers.append(contentsOf: Self.wordMarkers(in: text,
                                                                atByteOffset: samples.count * 4))
                }
                samples.append(contentsOf: Self.resample(pcm, from: sourceRate))

            case .pause(let seconds):
                // Silence is the only pause available: the engine renders one
                // utterance at a time and offers no rest primitive.
                let frames = Int(seconds * kOutputSampleRate)
                if frames > 0 { samples.append(contentsOf: repeatElement(0, count: frames)) }

            case .bookmark(let name):
                if speechSynthesisOutputMetadataBlock != nil {
                    markers.append(AVSpeechSynthesisMarker(bookmarkName: name,
                                                           atByteSampleOffset: samples.count * 4))
                }
            }
        }

        guard !samples.isEmpty else {
            clearState()
            return
        }

        // Markers describe positions in the audio, so the host gets them once the
        // audio they refer to exists.
        if let block = speechSynthesisOutputMetadataBlock, !markers.isEmpty {
            block(markers, speechRequest)
        }

        let newState = SpeechState(samples: samples)
        stateLock.lock()
        state = newState
        stateLock.unlock()
    }

    public override func cancelSpeechRequest() {
        clearState()
    }

    private func clearState() {
        stateLock.lock()
        state = nil
        stateLock.unlock()
    }

    /// The engine for `build`, reusing the open handle when it is the same build.
    private func engineHandle(for build: String) -> OpenBST? {
        if let engine, engineBuild == build { return engine }
        guard let opened = OpenBST(build: build) else { return nil }
        engine = opened
        engineBuild = build
        return opened
    }

    /// Word markers across `text`, so the host can highlight as it speaks.
    ///
    /// The range is into the text itself, which the system maps back to the
    /// original markup. The byte offset is where the utterance's audio starts: the
    /// engine reports no per-word timing, so a more precise number would be
    /// invented rather than measured. The host is documented to accept markers
    /// that reference audio not yet delivered, so this is within the contract.
    static func wordMarkers(in text: String,
                            atByteOffset startOffset: Int) -> [AVSpeechSynthesisMarker] {
        var markers: [AVSpeechSynthesisMarker] = []
        for word in text.split(separator: " ", omittingEmptySubsequences: true) {
            guard let range = text.range(of: word) else { continue }
            let location = text.utf16.distance(from: text.utf16.startIndex,
                                               to: range.lowerBound.samePosition(in: text.utf16)
                                               ?? text.utf16.startIndex)
            markers.append(AVSpeechSynthesisMarker(
                wordRange: NSRange(location: location, length: word.utf16.count),
                atByteSampleOffset: startOffset))
        }
        return markers
    }

    // MARK: - Resampling

    /// Linear resample from the build's rate to the output rate.
    ///
    /// Done once here rather than per frame in the render block. Linear
    /// interpolation is adequate for speech at these rates and leaves the audio
    /// thread doing nothing but a copy.
    static func resample(_ pcm: [Int16], from sourceRate: Double) -> [Float] {
        guard !pcm.isEmpty, sourceRate > 0 else { return [] }

        let step = sourceRate / kOutputSampleRate
        if step == 1.0 { return pcm.map { Float($0) / 32768.0 } }

        let outputCount = Int(Double(pcm.count) / step)
        guard outputCount > 0 else { return [] }

        var output = [Float](repeating: 0, count: outputCount)
        let lastIndex = pcm.count - 1
        for i in 0..<outputCount {
            let position = Double(i) * step
            let index = Int(position)
            if index >= lastIndex {
                output[i] = Float(pcm[lastIndex]) / 32768.0
                continue
            }
            let fraction = Float(position - Double(index))
            let a = Float(pcm[index]) / 32768.0
            let b = Float(pcm[index + 1]) / 32768.0
            output[i] = a + (b - a) * fraction
        }
        return output
    }

    // MARK: - Real-time render path

    public override var internalRenderBlock: AUInternalRenderBlock {
        return { [weak self] actionFlags, _, frameCount, _, outputData, _, _ in
            guard let self else { return noErr }

            let buffers = UnsafeMutableAudioBufferListPointer(outputData)
            guard buffers.count > 0,
                  let raw = buffers[0].mData,
                  buffers[0].mDataByteSize >= frameCount * UInt32(MemoryLayout<Float>.size)
            else { return noErr }

            let out = raw.assumingMemoryBound(to: Float.self)
            let written = self.fillBuffer(out, frames: Int(frameCount))

            // Tell the host this request is spent so it stops pulling.
            if written < Int(frameCount), self.currentRequestIsDrained {
                actionFlags.pointee.insert(.offlineUnitRenderAction_Complete)
            }
            return noErr
        }
    }

    /// True when a request exists and has been fully read out.
    private var currentRequestIsDrained: Bool {
        guard let s = state else { return false }
        return s.isDrained
    }

    /// Copies already-resampled samples out, silencing the remainder.
    /// Returns how many frames were written (0 once the request is drained).
    /// Runs on the audio thread: no allocation, no locks, no arithmetic beyond
    /// an index.
    func fillBuffer(_ buffer: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        guard frames > 0, let s = state else {
            buffer.update(repeating: 0, count: frames)
            return 0
        }

        let count = min(frames, s.samples.count - s.position)
        if count > 0 {
            s.samples.withUnsafeBufferPointer { source in
                guard let base = source.baseAddress else { return }
                buffer.update(from: base + s.position, count: count)
            }
            s.position += count
        }
        if count < frames {
            (buffer + count).update(repeating: 0, count: frames - count)
        }
        return count
    }
}
