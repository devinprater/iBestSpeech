import SwiftUI
import UniformTypeIdentifiers

/// The app's single screen: where the user loads their own Keynote Gold files
/// and then auditions the voices.
///
/// The app ships no voice data, so this screen is not decoration — until a file
/// is loaded there is nothing to hear and no voice in VoiceOver. That makes the
/// import the first thing on the screen and the first thing VoiceOver reads.
///
/// Only the navigation title is a real heading. The section labels below are
/// plain text, which keeps the rotor's heading list to a single entry instead
/// of making the user step through five of them.
struct ContentView: View {
    @StateObject private var audioManager = AudioManager()
    @State private var text: String = ""
    @State private var isImporting = false
    @State private var pendingRemoval: String?
    /// Spoken after an import so the outcome is not just a visual change.
    @State private var announcement: String?

    var body: some View {
        NavigationStack {
            Form {
                filesSection

                if !audioManager.availableBuilds.isEmpty {
                    previewSection
                    voicesSection
                }

                if let error = audioManager.lastError {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .accessibilityLabel("Note: \(error)")
                    }
                }

                aboutSection
                versionSection
            }
            .navigationTitle("iBestSpeech")
            .safeAreaInset(edge: .bottom) {
                if audioManager.isSpeaking {
                    HStack(spacing: 8) {
                        ProgressView()
                            .accessibilityHidden(true)
                        Text("Speaking")
                    }
                    .padding()
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Speaking")
                }
            }
            .fileImporter(isPresented: $isImporting,
                          allowedContentTypes: Self.importableTypes,
                          allowsMultipleSelection: false) { result in
                handleImport(result)
            }
        }
    }

    // MARK: - Sections

    private var filesSection: some View {
        Section {
            Button {
                isImporting = true
            } label: {
                Label(audioManager.isWaitingForCore
                      ? "Load the core file"
                      : "Load a voice file",
                      systemImage: "folder.badge.plus")
                    .frame(minHeight: 44)
            }
            .accessibilityHint(audioManager.isWaitingForCore
                ? "The 1998 file is waiting for the shared core module."
                : "Opens the file picker. Choose a Keynote Gold or BeSTspeech file, or an NVDA addon that contains one.")

            if audioManager.words.isEmpty {
                Text("No voice files are loaded, so there is nothing to speak with yet. Load a Keynote Gold file to begin. If you already have an NVDA addon that contains a Keynote Gold or BeSTspeech voice, you can load that instead — the app takes the voice out of it for you.")
                    .font(.callout)
                    .accessibilityLabel("No voice files are loaded. Load a Keynote Gold file to begin. You can also load an NVDA addon that contains one, and the app will take the voice out of it.")
            } else {
                ForEach(audioManager.words) { word in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(word.displayName)
                            Text("\(word.byteCount) bytes\(word.coreFileName == nil ? "" : ", with its core file")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            pendingRemoval = word.build
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(word.displayName)")
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(word.summary)
                }
            }
        } header: {
            label("Your voice files")
        }
        .confirmationDialog("Remove this voice file?",
                            isPresented: Binding(get: { pendingRemoval != nil },
                                                 set: { if !$0 { pendingRemoval = nil } })) {
            Button("Remove", role: .destructive) {
                if let build = pendingRemoval { audioManager.remove(build) }
                pendingRemoval = nil
            }
            Button("Keep", role: .cancel) { pendingRemoval = nil }
        }
    }

    private var previewSection: some View {
        Section {
            TextField("Text to speak", text: $text, axis: .vertical)
                .lineLimit(3...6)
                .accessibilityLabel("Text to speak")

            Button {
                audioManager.speak(text: text)
            } label: {
                Label("Speak", systemImage: "play.circle.fill")
                    .frame(minHeight: 44)
            }

            Button(role: .destructive) {
                audioManager.stop()
            } label: {
                Label("Stop", systemImage: "stop.circle.fill")
                    .frame(minHeight: 44)
            }
            .disabled(!audioManager.isSpeaking)
        } header: {
            label("Preview text")
        }
    }

    private var voicesSection: some View {
        Section {
            Picker("Voice", selection: $audioManager.selectedBuild) {
                ForEach(audioManager.words) { word in
                    Text(word.displayName).tag(word.build)
                }
            }
            .accessibilityLabel("Engine voice")
            .accessibilityHint("Chooses which loaded voice to speak with.")
            .onChange(of: audioManager.selectedBuild) { _, newBuild in
                // Each build reads a different language, and a phrase in the
                // wrong script comes back as silence, so the sample text follows
                // the selected voice.
                text = VoiceCatalog.sample(for: newBuild)
            }
        } header: {
            label("Test the engine")
        }
    }

    private var aboutSection: some View {
        Section {
            if !ImportStore.isShared {
                // A sideloaded build with the App Group stripped: the app can
                // import and preview, but the extension cannot see the files, so
                // the voice never reaches VoiceOver. Saying so is the difference
                // between a bug report and a known limitation.
                Text("This copy was installed without the shared container entitlement, so the voices work here but may not appear in VoiceOver. A build with that entitlement — the kind TestFlight installs — does not have this limit.")
                    .font(.callout)
                    .accessibilityLabel("Note. This copy was installed without the shared container entitlement, so the voices work here but may not appear in VoiceOver.")
            }

            Text("To use these voices everywhere, open Settings, then Accessibility, then VoiceOver, then Speech, then Voice. Each loaded voice appears in that list.")
                .font(.callout)

            Text("iBestSpeech includes the Keynote Gold speech engine. It does not include the voice data, which belongs to the people who made it. The files you load stay on this device and are used only by this app.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text("You can load a single voice file, or a whole NVDA addon that contains one. An addon is opened here on the device: the voices inside it are taken out and the rest of the addon is ignored. Nothing is downloaded, and an addon will only work if it actually contains a Keynote Gold or BeSTspeech voice.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            label("How this works")
        }
    }

    // MARK: - Import

    /// What the picker will let the user choose.
    ///
    /// Left deliberately wide: the originals are 16-bit Windows libraries and the
    /// system has no type for those, so a narrow filter would make the very files
    /// this app needs unselectable. The contents are what decide whether a file is
    /// usable, not its type.
    private static var importableTypes: [UTType] {
        var types: [UTType] = [.item, .data]
        if let dll = UTType(filenameExtension: "dll") { types.append(dll) }
        // An NVDA addon is not a type the system knows, so it resolves to a
        // dynamic identifier; adding it makes the picker show those files as
        // selectable rather than greyed out. Not fatal if the system has no
        // answer -- `.item` and `.data` above already keep everything pickable.
        if let addon = UTType(filenameExtension: "nvda-addon") { types.append(addon) }
        return types
    }

    /// Whether a picked file should go down the addon path.
    ///
    /// The extension is a hint, not a promise, and in the wild these archives
    /// are sometimes plain `.zip`, so a zip's contents are checked too. A `.dll`
    /// is never sniffed -- asking the zip reader about every engine module would
    /// be wasted work on the common path.
    private static func isAddon(url: URL, data: Data) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "nvda-addon" { return true }
        if ext == "zip" { return NVDAAddon.looksLikeAddon(data) }
        return false
    }

    /// Reports what came out of an addon, which may be several voices.
    private func handleAddon(data: Data, fileName: String) {
        switch audioManager.addAddonImport(data: data, fileName: fileName) {
        case .loaded(let words):
            let names = words.map(\.displayName).joined(separator: ", ")
            announce(words.count == 1
                     ? "Loaded \(names)."
                     : "Loaded \(words.count) voices: \(names).")
        case .noEngines(let addonName, _):
            announce(audioManager.lastError
                     ?? "\(addonName) does not contain a voice this app can use.")
        case .notAnAddon:
            announce(audioManager.lastError ?? "That is not an NVDA addon.")
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        let outcome: ImportOutcome?
        switch result {
        case .failure(let error):
            announcement = "The file could not be opened: \(error.localizedDescription)"
            outcome = nil
        case .success(let urls):
            guard let url = urls.first else { outcome = nil; return }
            // A file from the picker lives outside the app's container and the
            // access is scoped, so the bytes are read now and copied into the
            // shared container rather than referenced.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            guard let data = try? Data(contentsOf: url) else {
                announcement = "That file could not be read."
                outcome = nil
                break
            }
            // An NVDA addon holds a whole synthesizer rather than being a single
            // module, so it takes its own path and can yield several voices.
            if Self.isAddon(url: url, data: data) {
                handleAddon(data: data, fileName: url.lastPathComponent)
                return
            }
            outcome = audioManager.addImport(data: data,
                                             fileName: url.lastPathComponent)
        }

        guard let outcome else {
            announce(announcement)
            return
        }

        switch outcome {
        case .identified(let word):
            announce("Loaded \(word.displayName).")
        case .needsCore:
            announce("That file needs a second file. Pick the shared core module next.")
        case .ambiguous(let options):
            announce("That file works as more than one voice: \(options.map(\.displayName).joined(separator: ", ")). It was not added.")
        case .notEngineFile:
            announce(audioManager.lastError ?? "That is not a Keynote Gold file.")
        }
    }

    /// Speaks an outcome so it is not a silent visual change for a blind user.
    private func announce(_ message: String?) {
        guard let message else { return }
        announcement = message
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    /// A section label that is styled like a header but carries no heading trait,
    /// so VoiceOver's heading rotor lists only the navigation title.
    private func label(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            // No all-caps. SwiftUI uppercases a section header by default, and
            // that is not merely a style choice for this app: the engine SPELLS
            // an all-caps run letter by letter, so "Your voice files" would be
            // read out as a string of capitals by the app's own voices. Asking
            // for the text as written also reads better on screen.
            .textCase(nil)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityRemoveTraits(.isHeader)
    }

    /// What this copy of the app is, so a bug report can name the build.
    ///
    /// Read from the bundle rather than written here: a version hard-coded in a
    /// view is a version that goes stale the first time a release is cut, and a
    /// wrong version in a bug report is worse than none.
    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        return "Version \(version), build \(build)"
    }

    private var versionSection: some View {
        Section {
            Text(Self.versionText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityLabel(Self.versionText)
        } header: {
            label("About")
        }
    }
}

#Preview {
    ContentView()
}
