# iBestSpeech

The BeSTspeech / Keynote Gold speech synthesizer as an iOS app and a
system-wide VoiceOver voice.

Install the app and its speech provider extension registers with iOS, so
**Keynote Gold** shows up in Settings under Accessibility, VoiceOver, Speech,
Voices and can be selected for everything VoiceOver speaks.

## What it speaks

All twenty builds the engine carries, across thirteen languages and three
generations, each exposed as its own voice:

- **1995** — English.
- **1998** (11025 Hz) — English, Dutch, French, German, Italian, Spanish.
- **2006** (10000 Hz, Russian 10800 Hz) — Arabic, Dutch, English, French,
  German, Greek, Hebrew, Italian, Japanese, Polish, Portuguese, Russian,
  Spanish.

Note that the 2006 Russian build reads text in KOI8-R, which is what its
original did. Handed Latin text it returns a plausible sample count and then
all silence, so it needs Cyrillic to say anything.

## Building

Requires Xcode, `xcodegen`, and an upstream [openbst](https://github.com/Mudb0y/openbst)
checkout with the C sources.

```sh
# 1. Cross-compile the engine and assemble the XCFramework
cd iOSProject
python3 build_frameworks.py --upstream ~/openbst

# 2. Generate the Xcode project
xcodegen generate

# 3. Build and run
open iBestSpeech.xcodeproj
```

`build_frameworks.py` compiles for `arm64-apple-ios` and lipos the simulator
slice as `arm64 + x86_64`, so the project builds both on Apple silicon and on
Intel Macs. The XCFramework is not checked in — it is large, it is regenerated
by that script, and the compiled tables are not ours to redistribute (below).

### Checking that it actually speaks

Linking is not the same as speaking: a build can succeed and still emit
silence. This exercises the engine directly and measures how much of each
build's output is non-zero.

```sh
python3 smoke_test.py --upstream ~/openbst
```

## Signing

The project sets `DEVELOPMENT_TEAM: LMYZ738293` in `project.yml`. Change that
to your own team, or set it in Xcode under Signing & Capabilities. A wildcard
team provisioning profile covers both the app and the extension.

## Layout

```
iOSProject/
  Sources/                  the app: engine audition screen
  Shared/OpenBST.swift      Swift wrapper over the C API, used by both targets
  OpenBSTExtension/Sources/ the AVSpeechSynthesisProviderAudioUnit
  Info/                     app and extension Info.plists
  build_frameworks.py       cross-compiles the engine into an XCFramework
  smoke_test.py             verifies the engine produces audio
  project.yml               XcodeGen spec
```

The Swift wrapper lives in `Shared/` because the extension needs it too: the
provider is a separate process and cannot see the app target's sources.

## Licence

The engine is [openbst](https://github.com/Mudb0y/openbst) by Stanislaw
Przedzinkowski: its C code is MIT. Its **tables are not** — they are read out
of Berkeley Speech Technologies' binaries and are Berkeley's work and later
HumanWare's. The MIT licence covers the code and says nothing about the
tables. That is why the compiled `.a` files are not committed here: this
repository carries the iOS integration only. Use the tables where you have the
right to.
