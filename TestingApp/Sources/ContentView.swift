import SwiftUI

struct ContentView: View {
    @StateObject private var audioManager = AudioManager()
    @State private var text: String = "Hello, this is a test of the Keynote Gold voice."
    @State private var selectedBuild: String = "2006ENG"
    @State private var availableBuilds: [String] = []
    
    var body: some View {
        VStack(spacing: 20) {
            Text("OpenBST iOS Tester")
                .font(.title)
                .padding()
            
            TextField("Text to speak", text: $text)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .padding()
            
            HStack {
                Text("Voice:")
                Picker("Build", selection: $selectedBuild) {
                    ForEach(availableBuilds, id: \.self) { build in
                        Text(build).tag(build)
                    }
                }
                .pickerStyle(MenuPickerStyle())
            }
            .padding()
            
            Button(action: synthesizeAndPlay) {
                Label("Speak", systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            .padding()
            
            Button(action: { audioManager.stop() }) {
                Text("Stop")
                    .foregroundColor(.red)
            }
            
            Spacer()
        }
        .onAppear {
            availableBuilds = OpenBST.availableBuilds()
            if !availableBuilds.isEmpty {
                selectedBuild = availableBuilds.first!
            }
        }
        .padding()
    }
    
    private func synthesizeAndPlay() {
        guard let bst = OpenBST(build: selectedBuild) else {
            print("Could not open build \(selectedBuild)")
            return
        }
        
        if let samples = bst.synthesize(text) {
            audioManager.play(samples: samples, sampleRate: Double(bst.sampleRate))
        } else {
            print("Synthesis failed for text: \(text)")
        }
    }
}
