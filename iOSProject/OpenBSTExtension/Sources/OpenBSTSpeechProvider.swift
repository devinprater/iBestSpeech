import Foundation
import AVFoundation
import AudioToolbox

/// The rate this provider declares to the host.
///
/// The engine's builds run at 10000, 10800 or 11025 Hz depending on
/// generation, and the host picks a single output format when it instantiates
/// the audio unit. Declaring a fixed rate here and resampling on the render
/// thread keeps playback at the right pitch for every build; 22050 is the
/// conventional choice for speech providers.
private let kOutputSampleRate: Double = 22050.0

/// The system-wide voice provider behind iBestSpeech.
///
/// VoiceOver loads this as a speech synthesis provider extension. The audio
/// unit pulls samples on a real-time thread while `synthesizeSpeechRequest`
/// runs on another, so the render path must never allocate, take a lock, or
/// block.
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

    /// One synthesized utterance. `position` is a fractional index into
    /// `samples` and is advanced only by the render thread.
    private final class SpeechState {
        let samples: [Int16]
        let step: Double          // source samples consumed per output sample
        var position: Double = 0

        init(samples: [Int16], sourceSampleRate: Double) {
            self.samples = samples
            self.step = sourceSampleRate / kOutputSampleRate
        }

        var isDrained: Bool { position >= Double(samples.count) }
    }

    private var state: SpeechState?
    private let stateLock = NSLock()   // guards swaps only; never taken in render

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
    /// The system returns identifiers re-prefixed with the extension's bundle
    /// ID — it hands back "com.devin.ibestspeech.provider.com.devin.ibestspeech.
    /// 2006ENG" for the identifier "com.devin.ibestspeech.2006ENG" that was
    /// registered. Matching on the last matching occurrence rather than a prefix
    /// is what keeps speech working.
    static func buildName(from identifier: String) -> String? {
        guard let range = identifier.range(of: voiceIdentifierPrefix, options: .backwards) else {
            return nil
        }
        let build = String(identifier[range.upperBound...])
        guard !build.isEmpty, OpenBST.availableBuilds().contains(build) else { return nil }
        return build
    }

    public override func synthesizeSpeechRequest(_ speechRequest: AVSpeechSynthesisProviderRequest) {
        let voiceID = speechRequest.voice.identifier
        guard let buildName = Self.buildName(from: voiceID) else { return }

        let (text, pitch, rate) = SSMLText.textAndParameters(from: speechRequest.ssmlRepresentation)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            clearState()
            return
        }
        guard let bst = OpenBST(build: buildName) else { return }

        if let pitch { bst.set(.pitch, pitch) }
        if let rate { bst.set(.rate, rate) }

        guard let samples = bst.synthesize(text), !samples.isEmpty else {
            clearState()
            return
        }

        let newState = SpeechState(samples: samples,
                                   sourceSampleRate: Double(bst.sampleRate))
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

    // MARK: - Real-time render path

    public override var internalRenderBlock: AUInternalRenderBlock {
        return { [weak self] actionFlags, _, frameCount, _, outputData, _, _ in
            guard let self else { return noErr }

            let buffers = UnsafeMutableAudioBufferListPointer(outputData)
            guard buffers.count > 0,
                  let raw = buffers[0].mData,
                  buffers[0].mDataByteSize >= frameCount * UInt32(MemoryLayout<Float>.size) else {
                return noErr
            }

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

    /// Fills `buffer` with resampled samples, silencing the remainder.
    /// Returns how many frames were written (0 once the request is drained).
    /// Runs on the audio thread: no allocation, no locks.
    func fillBuffer(_ buffer: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        guard frames > 0 else { return 0 }

        guard let s = state else {
            buffer.update(repeating: 0, count: frames)
            return 0
        }

        let samples = s.samples
        let count = samples.count
        var i = 0

        while i < frames {
            let pos = s.position
            if pos >= Double(count) { break }

            let idx = Int(pos)
            let next = idx + 1 < count ? idx + 1 : idx
            let frac = Float(pos - Double(idx))
            let a = Float(samples[idx]) / 32768.0
            let b = Float(samples[next]) / 32768.0

            buffer[i] = a + (b - a) * frac
            s.position += s.step
            i += 1
        }

        if i < frames {
            (buffer + i).update(repeating: 0, count: frames - i)
        }
        return i
    }

    // MARK: - SSML

    /// Strips tags to plain text and lifts `rate`/`pitch` if the system sent them.
    ///
    /// VoiceOver sends prosody values as percentages (e.g. `rate="150%"`), so a
    /// trailing `%` is accepted and ignored rather than discarding the value.
}
