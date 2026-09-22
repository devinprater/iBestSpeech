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

Each build reads text as bytes in a legacy single-byte code page, which is what
its original did. Measured against the built library:

- **2006RUS** reads CP1251. Latin text returns a plausible sample count and then
  all silence, so it needs Cyrillic.
- **2006ARA** reads CP1256, and **2006GRE** reads CP1253; both also read Latin.
- **2006HEB** reads Latin — it speaks Hebrew phonetics written in Latin letters,
  which is how the engine's own suite drives it.
- The rest read Latin.

Where a build cannot read the script it is given, the English voice speaks
instead, and the app says so rather than going quiet.

## Speech handling

The system hands a speech provider SSML, and this resolves it rather than
stripping it:

- Tags become a **space**, never nothing. Deleting one joins the words it sat
  between: `iBestSpeech<break/>recently` came out "iBestSpeechrecently".
- Entities are decoded, and typographic characters folded to ASCII, because the
  engine reads a single-byte code page and cannot represent a curly quote or an
  em dash.
- `prosody` pitch, rate and volume, per piece, so a nested element adjusts only
  its own span.
- `break` becomes real silence, from `time` or `strength`, capped so a malformed
  value cannot stall the queue.
- `mark` is reported back to the system as a marker, so the host can act on it.
- `say-as interpret-as="characters"` and `digits` are spelled out. The engine
  already normalizes numbers, currency, dates and times itself, so the other
  modes pass through unchanged rather than being mangled by an approximation.
- `sub` speaks its alias, `phoneme` its text content, and `lexicon` is skipped.

**Two numbers in a row with only a space between them produce no audio at all**,
across every build — "555 1234", "10 20 30", "Room 101 202". The engine's own
test corpus never covers the case. A comma is inserted between them, which the
engine reads as a short pause; a pause between numbers is natural speech anyway,
and the alternative is silence.

A **clock time** needs different treatment again, because the colon between its
digits is worse than silent — it makes the engine produce no samples at all, on
every build. The colon is rewritten as a hyphen **and a space**, and both halves
matter:

- The hyphen takes the engine's number-group separator path, its only route for
  two runs of digits. Writing a full stop instead, which is what an earlier
  version did, sends "5.19" down the decimal rule: the engine says "five point
  one nine", announcing an hour and minutes as a fraction. A hyphen makes it say
  "five nineteen".
- The space keeps the runs apart. Without it "5-19" is one two-group number, and
  the 1998 English module truncates the second group to silence.

With both, "5:19 PM" reads exactly as "five nineteen PM" does — byte-identical
audio on the 1995 and 2006 English builds. Colons that are not times are left
alone: "Note: hello", "Chapter 3: page 5" and "http://x.com" already work.

Rate and pitch are translated to the engine's settings, which differ from
VoiceOver's in ways that are not obvious:

- The engine's `rate` scales utterance **duration**, so larger is slower, while
  VoiceOver's 0 is slowest. Passing the value through inverted the control.
- Pitch runs the same way in both, but the engine's floor is not a low pitch —
  it leaves the voiced range and buzzes, so the lower half is compressed onto
  the engine's usable minimum.

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

Re-run `xcodegen generate` after adding or moving any source file: targets take
their file list at generate time, so a new file is otherwise simply absent and
the build fails with "cannot find X in scope" for code that is plainly there.

## Tests

Three suites, each compiled together with the file it checks, so none of them can
drift from the shipping code.

```sh
cd iOSProject

# SSML parsing, 69 checks
swiftc -parse-as-library Shared/SSMLText.swift Tests/SSMLTextTests.swift \
  -o /tmp/ssmltests && /tmp/ssmltests

# rate and pitch mapping, 15 checks
swiftc -parse-as-library Shared/EngineParameters.swift Tests/EngineParameterTests.swift \
  -o /tmp/paramtests && /tmp/paramtests

# voice identifier parsing, 9 checks
swift iOSProject/Tests/VoiceIdentifierTests.swift
```

Every one of these covers behaviour that fails **silently** — nothing errors, the
voice just says the wrong thing or nothing at all — which is why they are worth
more here than they would be elsewhere.

### Checking that it actually speaks

Linking is not the same as speaking: a build can succeed and still emit silence.
This exercises the engine directly and measures how much of each build's output
is non-zero.

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
  Sources/                    the app: engine audition screen
  Shared/OpenBST.swift        Swift wrapper over the C API, used by both targets
  Shared/SSMLText.swift       SSML into text, pauses and markers
  Shared/EngineParameters.swift  VoiceOver's pitch and rate onto the engine's
  Shared/VoiceCatalog.swift   per-build language, code page and sample phrase
  OpenBSTExtension/Sources/   the AVSpeechSynthesisProviderAudioUnit
  Info/                       app and extension Info.plists
  Tests/                      the three suites above
  build_frameworks.py         cross-compiles the engine into an XCFramework
  smoke_test.py               verifies the engine produces audio
  project.yml                 XcodeGen spec
```

The shared files live in `Shared/` because the extension needs them too: the
provider is a separate process and cannot see the app target's sources.

## Sideloading

To install without a developer account — iLoader, AltStore, SideStore, Sideloadly
— you need an .ipa those tools can re-sign with your own Apple ID. The release
`.ipa` is not one: it is signed to a specific device list, and they cannot
re-sign a binary whose entitlements they cannot grant.

```sh
cd iOSProject
python3 make_sideload_ipa.py     # -> build/iBestSpeech-sideload.ipa
```

That builds the app with signing disabled entirely, so the packaged .ipa has no
signature, no provisioning profile, and nothing to undo before re-signing. It
also strips the App Group from the entitlements, because **a free Apple ID cannot
obtain one** — a profile granting it needs a paid account, and the sideloading
tools reject the .ipa outright. This is the same reason `AltStore` refuses some
apps and not others.

One caveat, stated rather than buried: **removing the App Group is untested on a
device.** Nothing in the Swift reads it — the voice list comes from the engine's
own static build table, not from shared defaults — so it looks like it was
declared while chasing registration and never used. But it was added at the point
registration started working, and no run has confirmed the app functions without
it. If the voices do not appear in Settings after sideloading, that is the first
suspect: rebuild with `--keep-app-group` on a paid account.

The script leaves `project.yml` alone — it writes a temporary spec beside it,
generates into a project of its own name, and cleans up — so the repository's
working configuration is never modified.

## Licence

The engine is [openbst](https://github.com/Mudb0y/openbst) by Stanislaw
Przedzinkowski: its C code is MIT. Its **tables are not** — they are read out
of Berkeley Speech Technologies' binaries and are Berkeley's work and later
HumanWare's. The MIT licence covers the code and says nothing about the
tables. That is why the compiled `.a` files are not committed here: this
repository carries the iOS integration only.

The `.ipa` attached to a release, however, does contain those tables, because an
installable app cannot avoid embedding them — see [LICENSE](LICENSE) and
[NOTICE.md](NOTICE.md) before you download it. That release is signed ad hoc for
a specific set of registered devices, so it installs only on those; build from
source with your own team to run it anywhere else.

Use the tables where you have the right to.
