# iBestSpeech iOS Setup

## Generate the project

The `.xcodeproj` is generated, not hand-edited:

```sh
cd iOSProject
python3 build_frameworks.py --upstream ~/openbst   # rebuild the XCFramework
xcodegen generate                                   # write iBestSpeech.xcodeproj
```

## Targets

- `iBestSpeech` — the app. Installs, and provides the audition screen.
- `iBestSpeechProvider` — the `app-extension` that supplies voices to the
  system. Embedded in the app; never installed standalone.

## Making the voice appear in VoiceOver

1. Build and run on a device.
2. Settings, Accessibility, VoiceOver, Speech, Voices, English.
3. Pick **Keynote Gold**.

The provider publishes one voice per engine build. If the list is empty the
extension is not being loaded — check that it is embedded and that both targets
use the same team.

## Why the XCFramework is built by a script

The simulator slice is fat (`arm64` + `x86_64`) and the filenames inside each
slice have to match what `Info.plist` declares. Hand-assembling the framework
got both wrong: it listed `libbst_ios.a` for the simulator slice, where the
file actually on disk was `libbst_sim.a`, so device objects were linked into
simulator builds. `build_frameworks.py` lets `xcodebuild -create-xcframework`
write the plist instead of maintaining it by hand.

## Known constraints

- Deployment target is iOS 17.0.
- Header search paths are conditioned on the SDK. Listing both slices in one
  array lets the device headers win for simulator builds and the link fails.
- `frameworks:` is not part of the XcodeGen spec and is silently ignored. The
  library must be listed under `dependencies:` or it never reaches the link
  phase.
- The Swift wrapper lives in `Shared/` because the extension needs it too: the
  provider runs in its own process and cannot see the app target's sources.
