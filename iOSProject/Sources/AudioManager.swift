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
    @Published var selectedBuild: String = ""
    /// The words the user has loaded, in the order they were added.
    @Published private(set) var words: [ImportedWord] = []

    /// The builds whose tables are compiled into the linked engine.
    ///
    /// Empty in a build that ships no table data, which is the whole point of a
    /// public build: then the user's own files are the only voices. Computed by
    /// actually opening each build rather than by listing the names, because
    /// `bst_builds` returns all twenty names whether or not any tables are
    /// compiled in — the names are a static list, not an inventory.
    private(set) lazy var compiledInBuilds: [String] = OpenBST.availableBuilds()
        .filter { OpenBST(build: $0) != nil }

    /// The builds that can be spoken right now: the user's files, plus whatever
    /// the library carries.
    ///
    /// Imported files come first so that loading a file always makes that voice
    /// available, even where the same build is also compiled in.
    var availableBuilds: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for build in words.map(\.build) + compiledInBuilds where seen.insert(build).inserted {
            ordered.append(build)
        }
        return ordered
    }

    /// True when this copy of the app carries no voice data of its own, which is
    /// what a public build does and what makes the file import mandatory.
    var shipsWithoutTables: Bool { compiledInBuilds.isEmpty }

    /// Picker display values, resolved once and kept in step with `words`.
    ///
    /// The label carries the language, and looking that up inside the picker body
    /// re-ran the lookup for all twenty rows on every render. Pushing and popping
    /// the picker then did twenty dictionary walks per frame, which is what the
    /// lag in the voice list was.
    @Published private(set) var buildChoices: [String] = []

    private var idleTimer: Task<Void, Never>?
    private var graphReady = false

    init() {
        // Tell the system to rebuild its voice list. Without this the provider's
        // voices are not enumerated, however correct the extension's plist is:
        // the system caches the voice list and only rebuilds it when asked.
        AVSpeechSynthesisProviderVoice.updateSpeechVoices()

        refreshWords()

        #if DEBUG
        runSelfTestIfRequested()
        #endif
    }

    // MARK: - The user's words

    /// Re-reads the imported files from the shared container.
    ///
    /// Read from disk rather than kept only in memory, so a file that arrives by
    /// another route — a restore, an import from a share sheet — is picked up
    /// here too.
    func refreshWords() {
        words = ImportStore.storedBuilds().compactMap { build in
            guard let data = ImportStore.data(for: build) else { return nil }
            var word = ImportedWord(build: build,
                                    fileName: ImportStore.fileName(for: build),
                                    byteCount: data.count)
            if let core = ImportStore.data(for: build, core: true) {
                word.coreFileName = ImportStore.coreFileName(for: build)
                word.coreByteCount = core.count
            }
            return word
        }
        buildChoices = words.map { VoiceCatalog.displayName(for: $0.build) }
        if !availableBuilds.contains(selectedBuild) {
            selectedBuild = availableBuilds.contains(VoiceCatalog.englishBuild)
                ? VoiceCatalog.englishBuild
                : (availableBuilds.first ?? "")
        }
    }

    /// Adds a file the user picked, working out what it is.
    ///
    /// Returns the outcome so the caller can say what happened; nothing is stored
    /// unless the file turned out to be usable, so a mis-picked file cannot leave
    /// a broken entry in the list.
    @discardableResult
    func addImport(data: Data, fileName: String) -> ImportOutcome {
        // A file picked while a 1998 module is waiting for its core is the core,
        // so the second pick completes the first rather than being an import of
        // its own.
        if isWaitingForCore {
            return completeImport(withCore: data, fileName: fileName)
        }

        let outcome = Identify.file(data, fileName: fileName)

        switch outcome {
        case .identified(let word):
            guard ImportStore.store(data: data, build: word.build) else {
                lastError = "The file could not be saved."
                return .notEngineFile(fileName: fileName, byteCount: data.count)
            }
            refreshWords()
            AVSpeechSynthesisProviderVoice.updateSpeechVoices()
            lastError = nil
            return outcome

        case .needsCore:
            // Hold the bytes until the user picks the matching core file.
            pendingCore = data
            pendingCoreName = fileName
            lastError = "That is a Keynote Gold 1998 file. It needs a second file beside it — the shared core module every 1998 voice needs — before it can speak."
            return outcome

        case .ambiguous(let options):
            lastError = "That file works as more than one voice (\(options.map(\.build).joined(separator: ", "))), so it was not added."
            return outcome

        case .notEngineFile(let name, let bytes):
            lastError = "\(name) is not a Keynote Gold file (\(bytes) bytes). Pick a .dll from a Keynote Gold or BeSTspeech installation."
            return outcome
        }
    }

    /// Completes a 1998 import once its core file has been picked too.
    @discardableResult
    func completeImport(withCore data: Data, fileName: String) -> ImportOutcome {
        guard let first = pendingCore, let firstName = pendingCoreName else {
            return addImport(data: data, fileName: fileName)
        }
        let outcome = Identify.pairing(first, data, fileNameA: firstName, fileNameB: fileName)
        guard case .identified(let word) = outcome else {
            lastError = "Those two files do not go together. The 1998 modules need their language file and the shared core module; the core is the one every 1998 voice needs."
            return outcome
        }
        guard ImportStore.store(data: first, build: word.build),
              ImportStore.store(data: data, build: word.build, core: true)
        else {
            lastError = "The files could not be saved."
            return outcome
        }
        pendingCore = nil
        pendingCoreName = nil
        refreshWords()
        AVSpeechSynthesisProviderVoice.updateSpeechVoices()
        lastError = nil
        return outcome
    }

    /// True while a 1998 language file is waiting for its core.
    var isWaitingForCore: Bool { pendingCore != nil }

    func remove(_ build: String) {
        ImportStore.remove(build: build)
        refreshWords()
        AVSpeechSynthesisProviderVoice.updateSpeechVoices()
    }

    private var pendingCore: Data?
    private var pendingCoreName: String?

    // MARK: - Playback

    func speak(text: String) {
        guard !selectedBuild.isEmpty else {
            lastError = "Load a Keynote Gold file first."
            return
        }
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
            // silence it would otherwise produce -- when English is loaded too.
            guard build != VoiceCatalog.englishBuild,
                  availableBuilds.contains(VoiceCatalog.englishBuild),
                  case .success(let out) = synthesize(trimmed, build: VoiceCatalog.englishBuild)
            else {
                lastError = "The \(build) voice cannot read that text."
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

    /// Opens a build, preferring the user's own file.
    ///
    /// A build can be spoken two ways, and which one applies is decided by what
    /// is present rather than by which copy of the app this is: if the user has
    /// loaded a file for this build it is used, otherwise the tables compiled
    /// into the library are. A public build has no compiled-in tables, so there
    /// the file is the only path and a build with no file simply will not open.
    static func openedHandle(for build: String) -> OpenBST? {
        if let data = ImportStore.data(for: build) {
            return OpenBST(build: build, image: data, core: ImportStore.data(for: build, core: true))
        }
        return OpenBST(build: build)
    }

    private func synthesize(_ text: String, build: String) -> SynthesisOutcome {
        guard let info = VoiceCatalog.info(for: build) else {
            return .failure("Unknown voice \(build).")
        }
        guard let bst = Self.openedHandle(for: build) else {
            return .failure("The \(build) voice could not be opened.")
        }
        let rate = bst.sampleRate

        // The text layer runs HERE, not only in the extension.
        //
        // Only the VoiceOver extension called it, so the same notification spoke
        // in VoiceOver and stopped dead in this app's own preview: the engine was
        // handed a raw ellipsis, which is 0 samples on the 1995 and 1998 voices
        // and garbled on 2006. Everything the layer does -- folding typography,
        // softening commas, separating adjacent numbers -- belongs on BOTH paths,
        // because the preview is what the user tests with and what they report
        // bugs against.
        let prepared = SSMLText.finish(text, sayAs: nil)

        // A build that reads Latin takes the string as UTF-8.
        guard let codePage = info.codePage else {
            guard let samples = bst.synthesize(prepared), !samples.isEmpty else {
                return .failure("The \(build) voice produced no audio.")
            }
            return .success(Utterance(samples: samples, rate: rate))
        }

        // Otherwise the build's own code page is tried first: that is how its
        // original was driven and it gives the closest output. A build handed a
        // script it does not read returns a sample count and then all zeros, so
        // the result is checked for actual signal, not just for a length.
        if let bytes = prepared.encoded(as: codePage), !bytes.isEmpty {
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

    // MARK: - Headless self test

    #if DEBUG
    /// Drives the playback path without the UI, for the simulator smoke check.
    ///
    /// `simctl launch … --selftest-speak` writes its findings to a file the host
    /// reads back, rather than trusting that stdout was captured.
    private func runSelfTestIfRequested() {
        guard CommandLine.arguments.contains("--selftest-speak") else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            var report = ""
            report += "imported words: \(self.availableBuilds.isEmpty ? "NONE" : self.availableBuilds.joined(separator: ", "))\n"
            for build in self.availableBuilds {
                self.lastError = nil
                self.speak(text: VoiceCatalog.sample(for: build), build: build)
                report += "native \(build) -> \(self.lastSpokenWith ?? "NOTHING")"
                    + (self.lastError.map { "; note=\($0)" } ?? "") + "\n"
            }

            // The decisive check: does the system list our provider's voices?
            // Apple's documentation is explicit that the system "takes up to
            // 30 seconds to refresh the list of available voices" after
            // updateSpeechVoices(), so this waits well past that.
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
                report += "  (none — the extension is not being loaded, or no files are loaded)\n"
            }

            let url = URL.documentsDirectory.appending(path: "selftest.txt")
            try? report.write(to: url, atomically: true, encoding: .utf8)
            NSLog("[selftest]\n%@", report)
        }
    }
    #endif
}
