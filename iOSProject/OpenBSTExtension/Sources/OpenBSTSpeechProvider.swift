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
///
/// The voice data is not in this bundle. The app is what imports it, and the
/// extension reads the same files out of the App Group container the two share
/// — so the voices offered are exactly the files the user has loaded, and an
/// install with no files loaded offers no voices at all.
public final class OpenBSTSpeechProvider: AVSpeechSynthesisProviderAudioUnit {

    private static let voiceIdentifierPrefix = "com.devin.ibestspeech."

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

    /// The handle is kept between requests, along with the bytes it reads from.
    ///
    /// ⛔ The engine stores a pointer into the image rather than copying it, so
    /// the `Data` must outlive the handle. Keeping both here, and replacing them
    /// together, is what makes that true; releasing the data while the handle
    /// lived would leave the engine reading freed memory on a later utterance.
    private var engine: OpenBST?
    private var engineBuild: String?
    private var engineImage: Data?

    // MARK: - Voice registration

    /// The voices this provider offers: the user's imported files, plus whatever
    /// the library carries compiled in.
    ///
    /// Read from disk on each call rather than cached, because the system asks for
    /// this list at times this process cannot predict — and a stale list would
    /// offer a voice whose file has since been removed, which fails silently when
    /// VoiceOver tries to use it.
    public override var speechVoices: [AVSpeechSynthesisProviderVoice] {
        get {
            var seen = Set<String>()
            var builds: [String] = []
            for build in ImportStore.storedBuilds() + Self.compiledInBuilds()
            where seen.insert(build).inserted {
                builds.append(build)
            }

            return builds.compactMap { build in
                guard let info = VoiceCatalog.info(for: build) else { return nil }
                return AVSpeechSynthesisProviderVoice(
                    name: VoiceCatalog.displayName(for: build),
                    identifier: Self.voiceIdentifierPrefix + build,
                    primaryLanguages: [info.language],
                    supportedLanguages: [info.language]
                )
            }
        }
        set { /* The host may try to set this; the list is derived, not stored. */ }
    }

    /// The builds whose tables are compiled into this copy of the engine.
    ///
    /// Empty for a public build, which carries none. `bst_builds` lists all
    /// twenty names whether or not any tables are present — the names are a
    /// static list — so each name is opened to find out whether it really has
    /// tables behind it.
    static func compiledInBuilds() -> [String] {
        OpenBST.availableBuilds().filter { OpenBST(build: $0) != nil }
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
        guard !build.isEmpty,
              ImportStore.storedBuilds().contains(build) || compiledInBuilds().contains(build)
        else { return nil }
        return build
    }

    public override func synthesizeSpeechRequest(_ speechRequest: AVSpeechSynthesisProviderRequest) {
        guard let buildName = Self.buildName(from: speechRequest.voice.identifier)
        else {
            clearState()
            return
        }

        // The language the requested voice speaks is the default for every
        // piece. A piece that is clearly in another language is spoken with that
        // language's build instead -- the engine keeps one voice per build, so
        // this is the only way to say two languages in one utterance.
        let defaultLanguage = VoiceCatalog.language(for: buildName)

        let parsed = SSMLText.parse(speechRequest.ssmlRepresentation,
                                    language: defaultLanguage)
        guard !parsed.pieces.isEmpty else {
            clearState()
            return
        }

        let neutralPitch = EngineParameters.enginePitch(forVoiceOver: 50)
        let neutralRate = EngineParameters.engineRate(forVoiceOver: 0.5)

        var samples: [Float] = []
        var markers: [AVSpeechSynthesisMarker] = []

        // One run per consecutive stretch of the same language, in order. A
        // piece that changed its mind about the language starts a new run, and
        // the build for a run is opened once and kept for it.
        var currentBuild: String?
        var currentHandle: OpenBST?

        for piece in parsed.pieces {
            switch piece {
            case .speech(let text, let pitch, let rate, _):
                guard !text.isEmpty else { continue }

                // A switch only when the detector is sure, and only to a build
                // whose tables are actually available — either the user's file
                // or the library's own. A detected language with nothing behind
                // it must not steal the words.
                var wantBuild = LanguageDetector.buildToSpeak(text,
                                                              insteadOf: defaultLanguage)
                    ?? buildName
                if ImportStore.data(for: wantBuild) == nil, !Self.compiledInBuilds().contains(wantBuild) {
                    wantBuild = buildName
                }

                if wantBuild != currentBuild {
                    // The build is opened from the user's own file when there is
                    // one, otherwise from the library's own tables; if neither
                    // works, fall back to the requested voice rather than drop
                    // the words.
                    let handle = engineHandle(for: wantBuild)
                        ?? (wantBuild == buildName ? nil : engineHandle(for: buildName))
                    currentBuild = handle == nil ? nil : wantBuild
                    currentHandle = handle
                }
                guard let bst = currentHandle else { continue }

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
                samples.append(contentsOf: Self.resample(pcm, from: Double(bst.sampleRate)))

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

    /// The engine for `build`, preferring the user's own file.
    ///
    /// The image is kept as well as the handle: the engine points into it rather
    /// than copying it, so dropping the `Data` would leave the engine reading
    /// memory that no longer belongs to us.
    private func engineHandle(for build: String) -> OpenBST? {
        if let engine, engineBuild == build { return engine }

        let opened: OpenBST?
        if let image = ImportStore.data(for: build) {
            let core = ImportStore.data(for: build, core: true)
            opened = OpenBST(build: build, image: image, core: core)
            // Held so the engine can keep pointing into it.
            engineImage = image
        } else {
            opened = OpenBST(build: build)
            // Nothing to hold: the tables are in the binary.
            engineImage = nil
        }
        guard let opened else { return nil }

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
