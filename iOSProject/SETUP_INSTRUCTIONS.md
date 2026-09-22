# OpenBST iOS Setup Instructions

## 1. Create Xcode Project
- Create a new iOS App project (SwiftUI).
- Minimum Deployment Target: iOS 17.0.

## 2. Add Framework
- Drag and drop `OpenBST.xcframework` into the project.
- In "General" -> "Frameworks, Libraries, and Embedded Content", ensure it is set to "Do Not Embed" (since it's a static library).

## 3. Add Source Files
- Add `OpenBST.swift`, `AudioManager.swift`, and `ContentView.swift` to the project.

## 4. Configure Bridging Header
- Create a file named `Bridging-Header.h` in the project root.
- Add the following line:
  `#include "bst.h"`
- In "Build Settings", search for "Objective-C Bridging Header" and set it to the path of this file (e.g., `OpenBST_App/Bridging-Header.h`).

## 5. Run
- Set the entry point to `ContentView`.
- Build and run on an iOS ARM64 device.

## 6. Implementing the System-Wide Voice (Extension)
To make the voice available to VoiceOver:
1. **Add a New Target**: In Xcode, add a new target of type **"Speech Synthesis Provider"**.
2. **Name the Target**: .
3. **Add Sources**: Add `OpenBSTSpeechProvider.swift` and `OpenBSTAudioUnit.swift` to this target.
4. **Link Framework**: Add `OpenBST.xcframework` to the extension target.
5. **App Group**: Create an App Group (e.g., `group.com.devin.openbst`) and enable it for both the main App and the Extension.
6. **Deployment**: Install the app on your device. Go to **Settings -> Accessibility -> VoiceOver -> Speech -> Voices** and look for **"Keynote Gold"**.
