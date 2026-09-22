import SwiftUI

struct ContentView: View {
    @StateObject var audioManager = AudioManager()
    @State private var text: String = "Hello Keynote Gold"
    
    var body: some View {
        VStack(spacing: 20) {
            Text("OpenBST Simulator Test")
                .font(.title)
            
            TextField("Enter text", text: $text)
                .textFieldStyle(.roundedBorder)
                .padding()
            
            HStack {
                Button(action: { audioManager.speak(text: text) }) {
                    Text("Speak")
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                
                Button(action: { audioManager.playerNode.stop() }) {
                    Text("Stop")
                        .padding()
                        .background(Color.red)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
            }
            
            if audioManager.isSpeaking {
                ProgressView()
            }
            
            if let error = audioManager.lastError {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }
        }
        .padding()
    }
}
