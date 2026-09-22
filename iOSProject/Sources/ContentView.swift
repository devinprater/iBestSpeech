import SwiftUI

/// The app's single screen: a test bench for the engine.
///
/// Installing the app is what registers the voice with the system, so the
/// primary job of this screen is to tell the user how to find the voice in
/// VoiceOver and to let them audition it without leaving.
struct ContentView: View {
    @StateObject private var audioManager = AudioManager()
    @State private var text: String = "Hello from iBestSpeech. This is the Keynote Gold voice, running on iOS."

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Text to speak", text: $text, axis: .vertical)
                        .lineLimit(3...6)
                        .accessibilityLabel("Text to speak")
                } header: {
                    Text("Preview text")
                }

                Section {
                    Picker("Voice", selection: $audioManager.selectedBuild) {
                        ForEach(audioManager.availableBuilds, id: \.self) { build in
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
                    Text("Test the engine")
                }

                if let error = audioManager.lastError {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .accessibilityLabel("Error: \(error)")
                    }
                }

                Section {
                    Text("To use this voice everywhere, open Settings, then Accessibility, then VoiceOver, then Speech, then Voice, then English. Keynote Gold appears in that list once this app is installed.")
                        .font(.callout)
                } header: {
                    Text("Use with VoiceOver")
                }

                Section {
                    Text("\(audioManager.availableBuilds.count) engine builds are available.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("About")
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
}

#Preview {
    ContentView()
}
