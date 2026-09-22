import SwiftUI

/// The app's single screen: a test bench for the engine.
///
/// Installing the app is what registers the voice with the system, so the
/// primary job of this screen is to tell the user how to find the voice in
/// VoiceOver and to let them audition it without leaving.
///
/// Only the navigation title is a real heading. The section labels below are
/// plain text, which keeps the rotor's heading list to a single entry instead
/// of making the user step through five of them.
struct ContentView: View {
    @StateObject private var audioManager = AudioManager()
    @State private var text: String = VoiceCatalog.sample(for: VoiceCatalog.englishBuild)

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Text to speak", text: $text, axis: .vertical)
                        .lineLimit(3...6)
                        .accessibilityLabel("Text to speak")
                        .onChange(of: audioManager.selectedBuild) { _, newBuild in
                            // Each build reads a different language, and a phrase
                            // in the wrong script comes back as silence, so the
                            // sample text follows the selected voice.
                            text = VoiceCatalog.sample(for: newBuild)
                        }
                } header: {
                    label("Preview text")
                }

                Section {
                    Picker("Voice", selection: $audioManager.selectedBuild) {
                        ForEach(audioManager.buildChoices, id: \.self) { build in
                            Text(build).tag(build)
                        }
                    }
                    .accessibilityLabel("Engine build")
                    .accessibilityHint("Chooses which generation and language of the engine to speak with.")

                    Button {
                        audioManager.speak(text: text)
                    } label: {
                        Label("Speak", systemImage: "play.circle.fill")
                            .frame(minHeight: 44)
                    }
                    .disabled(audioManager.availableBuilds.isEmpty)

                    Button(role: .destructive) {
                        audioManager.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.circle.fill")
                            .frame(minHeight: 44)
                    }
                    .disabled(!audioManager.isSpeaking)
                } header: {
                    label("Test the engine")
                }

                if let error = audioManager.lastError {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .accessibilityLabel("Note: \(error)")
                    }
                }

                Section {
                    Text("To use this voice everywhere, open Settings, then Accessibility, then VoiceOver, then Speech, then Voice, then English. Keynote Gold appears in that list once this app is installed.")
                        .font(.callout)
                } header: {
                    label("Use with VoiceOver")
                }

                Section {
                    Text("\(audioManager.availableBuilds.count) engine builds are available. Where a build cannot read the text it is given, the English voice speaks instead.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    label("About")
                }
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
        }
    }

    /// A section label that is styled like a header but carries no heading trait,
    /// so VoiceOver's heading rotor lists only the navigation title.
    private func label(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityRemoveTraits(.isHeader)
    }
}

#Preview {
    ContentView()
}
