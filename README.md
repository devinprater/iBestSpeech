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
- Entities are decoded, and characters the engine cannot read are folded away,
  because the engine reads a single-byte code page: a curly quote or an em dash
  has no representation there, and a *literal* one behaves worse than an entity
  did, splicing a stray glyph onto the word it follows. Named entities were
  already handled; the same characters arriving literally are now folded to the
  same ASCII, so both spellings produce the same audio.
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
test corpus never covers the case (this is fixed in the engine now, see
`Patches/`, but the text layer keeps the separator so an older engine is still
intelligible). A **colon** is inserted between them, which the engine reads as a
short pause; a pause between numbers is natural speech anyway, and the
alternative is silence.

A colon rather than a comma, and the difference is not cosmetic. Where a comma
works the colon is **byte-identical** to it — `hello, world` and `hello: world`
are 13839 samples each on 1995 and 13869 on 1998ENG. But on all **thirteen** 2006
builds a comma **ends the text**: the comma and every word after it is never
spoken. `Room 101, 202 and more words here` says "Room 101" and stops. That is
what the original binaries do, so it is reproduced faithfully, which is exactly
why the text layer must not use a comma. The colon keeps the tail on all twenty
builds. A comma the user wrote is left alone; only the separator this layer
inserts is a colon.

**Emoji and other characters the engine cannot read are spoken as their
descriptions.** The engine reads one byte per character, so an emoji is a
code-page glyph and the result is not silence but nonsense: measured on 2006ENG a
lone `✓` is 37,691 samples and six word tokens, and `©` and `®` produce a sample
count with **no word tokens at all**.

The descriptions come from the Unicode Common Locale Data Repository, from the
same `tts` annotation and the same mirror that NVDA turns into its emoji symbol
dictionaries (`nvaccess/nvda#8758`), in the language the voice speaks —
`😀` is "grinning face" in English and "grinsendes Gesicht" in German. 3,870 entries in English, 29,982 across the thirteen locales, generated into
`Shared/CLDRText.swift` by `tools/build_tables.py`.

Two things the raw data cannot be used for, both measured:

- **CLDR writes its descriptions with `:` and `,`** — 2,784 entries carry one.
  A comma ends the text on every 2006 build, and the description is what gets
  spoken, so "family: man, woman, girl" would say "family" and stop. Both are
  stripped. The colon is safe and could have stayed; removing it too keeps the
  descriptions uniform.
- **CLDR also annotates 30 punctuation characters** (`!`, `,`, `.`, `:`, `~`).
  Those are characters the engine already reads, and substituting them would
  rewrite the punctuation of ordinary text — "hello, world" would become
  "hello comma world". Only characters outside ASCII are replaced, which is the
  same line NVDA draws: its punctuation symbols speak only at the highest symbol
  level, while emoji speak at every level (`nvaccess/nvda#9707`).

A character is looked up by its base form as well as whole, because `❤️` is one
`Character` to Swift — the heart plus a variation selector — and CLDR keys its
description on the heart alone.

**Terms the engine mispronounces are in a dictionary.** The engine reads an
unknown compound as one word: `FaceTime`'s token stream is **identical to
`facetime`**, so it comes out as one odd word rather than "face time", and
`iPhone`, `macOS`, `AirDrop`, `SQL` and the rest go the same way. `tools/dictionary.txt`
holds 138 such terms — Apple product names, networking and file-format
initialisms, and modern usage the 1990s lexicon has no entry for — and
`tools/build_tables.py` generates `Shared/Pronunciations.swift` from it.

Every entry was measured against the built engine first: an entry whose term the
engine already reads correctly is doing nothing but costing a lookup, and
`python3 tools/build_tables.py --check` reports those against all three English
builds. It found and removed twelve. Matching is case-sensitive and whole-word,
which is what keeps a term like `AI` from rewriting the same letters inside a
French word.

**A voice follows the language of the text.** The engine keeps one voice per
build, so speaking two languages in one utterance means detecting the language
and synthesizing with that language's build. `Shared/LanguageDetector.swift`
does the detection in two stages: the script first, where Cyrillic, Greek,
Arabic, Hebrew and kana each belong to exactly one build and a single character
settles it; then function words — "the", "der", "le" — for the eight languages
that share the Latin alphabet, scored as whole words and requiring both a floor
and a clear win over the runner-up.

It **declines far more often than it guesses**, and that is the design. A single
word like "Hallo" is in several of these languages, so a one-word text never
switches a voice; a word three languages share claims nothing. A wrong switch
changes the voice the user hears, which is worse than no switch.

This deliberately does not use `NLLanguageRecognizer`, which would be better at
it: that framework exists only on Apple platforms, so nothing about the file
could be tested off-device, and an untestable language guess is exactly the kind
of thing that looks fine here and is wrong on a phone. 24 tests cover the
unambiguous cases and the refusals.

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

**Invisible characters are removed, not folded.** The system wraps an
accessibility value in bidirectional marks — most often the first-strong isolate,
`U+2068` — and to this engine a mark is a code-page glyph like any other, so it
is spliced onto the following word. In Messages that is the stray sound heard
before "Read": the engine reads "Read" together with the mark that came with it.
A soft hyphen, a byte order mark or a non-breaking space is worse still and makes
the whole utterance **silent**. Bidi marks and isolates, zero width characters,
soft hyphen and the byte order mark are therefore deleted; a non-breaking space
becomes an ordinary one.

Accented characters are a real trade-off rather than a clean win. A localized
build does read its own accents — the 2006 German module says "über" with the
umlaut — but any text may be handed to any of the twenty builds, and the 1995
module goes silent on "café" instead of saying it. Diacritics are therefore
dropped after decomposition: "café" reaches the engine as "cafe". That costs an
accent to buy back speech that would otherwise be missing.

**The engine's lead-in character is neutralised.** A tilde introduces the
engine's own commands, and a literal one in text is obeyed rather than read:
"Read ~x] 6:23 PM" puts the parser into dictionary mode for the rest of the
utterance, and "~p]" phoneme mode. Measured on 1995, either turns a 24,866
sample utterance into roughly 34,000. A tilde becomes a space — not a deletion,
so that one sitting between two words cannot join them.

The engine's native **times-of-day** option is not reachable from here. The
Keynote GOLD manual and the B32 DLL both document `~n9,x]` (8:00 as "eight
o'clock"), default on, and the Android port exposes it. This port cannot turn it
on: a `~nN,x]` command is consumed and the rest of the utterance then produces
nothing at all, on every build, whichever value is given.

**The colon is fixed in the engine too.** `Patches/openbst-clock-times.patch`
carries two changes to an [openbst](https://github.com/Mudb0y/openbst) checkout,
applied before `build_frameworks.py` so they reach the shipped XCFramework. Both
are faults in the engine rather than in this project:

- **A digit-flanked colon produced no audio at all.** The transition table gives
  such a colon a state of its own, so `8:00` reaches the number reader as one
  token; the reader rejected any run containing a non-digit, and what followed
  fell to a fallback that never reached the machine. Each run either side of the
  colon is now read as a number. Measured on 1995, `5:19 PM` goes from zero
  samples to 18,549 — **byte-identical to `5- 19 PM`**, on nineteen of the
  twenty builds.
- **The 1998 English module's digit tables were four bytes low.** Every digit
  resolved one slot into the next name: a single digit read the *following*
  digit's name, and a two-digit run of 10 or less ran off the end of the table
  entirely. That is the "minutes starting with a zero are read as a long
  sequence" fault, and it was never about the leading zero — `5:10` failed the
  same way. All hundred values 00–99 now read, and 1998ENG's sample counts match
  1995's to within a voice difference. The other five 1998 languages are
  generated by `tools/analysis/mkmap.py`, which copies this map address for
  address, so they were corrected by the same change.
- **A stop written straight against a digit silenced the utterance.**
  `Read.6:23 PM` is how an accessibility value often reads, and it did nothing
  at all, on every build. The stop restarts the token at itself, so the number
  reader received the run `[".6"]`, rejected it, and left the state machine on
  the same token until its guard expired. With the tokeniser's trace on, that
  guard is what produced millions of repetitions of one line. A space after the
  stop hid the fault, because the space is eaten and the token restarts on the
  digit. Leading non-digits are now skipped, so `Read.6- 23 PM` reads the same
  words as `Read. 6- 23 PM`.

`iOSProject/engine_tests.py` covers all three, and the workflow at
`.github/workflows/build.yml` runs it on a Mac runner — building the XCFramework,
the Swift tests and the app as well. It also reverts the patch and requires the
tests to fail, so a test that has quietly stopped exercising anything cannot
pass.

**Still open, and worth stating plainly:** none found that I know of. The two
silences that were worked around in Swift — the colon and the stop-then-digit
shape — are now fixed in the engine, and the lead-in character and non-ASCII
folding remain in the SSML layer, where they belong.

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
git -C ~/openbst apply Patches/openbst-clock-times.patch   # clock times, see above
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

## Releasing

```sh
python3 iOSProject/bump_version.py 1.0.2      # both plists, together
$EDITOR ReleaseNotes/v1.0.2.md                # what changed, honestly
git commit -am "Version 1.0.2" && git push
git tag v1.0.2 && git push origin v1.0.2
```

Pushing the tag runs `.github/workflows/release.yml`, which builds the engine
with the patch applied, runs the engine tests, builds the XCFramework, packages
the sideloadable `.ipa`, verifies it, and attaches it to a GitHub Release.

Three things about that workflow are deliberate:

- **The version in the two plists is bumped by a script, not by hand.** The app
  and the extension must agree; iOS refuses to load an extension whose version
  does not match its container.
- **The `.ipa` is verified as a *sideloadable* artifact**, not merely as a zip:
  no provisioning profile, no code signature, the provider extension embedded,
  both binaries arm64 for iOS rather than for a simulator, and the engine's
  symbols actually present. A green build of an app with no engine in it would
  otherwise ship happily.
- **`workflow_dispatch` builds and uploads the `.ipa` as an artifact without
  publishing anything.** Do that first when changing the packaging: inspect the
  artifact, then push the tag. The tag path also requires `ReleaseNotes/v<tag>.md`
  to exist, so a release cannot go out without notes.


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
