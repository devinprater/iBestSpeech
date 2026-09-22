# Third-party notice

iBestSpeech is an iOS integration of someone else's speech engine. Almost
nothing in the audio you hear is ours, and the release archive carries data
that we are not in a position to license to you.

## What the released app contains

The `.ipa` attached to a release contains the compiled engine **including its
tables**. The tables are read out of Berkeley Speech Technologies' binaries and
are Berkeley's work and later HumanWare's; see LICENSE. They are not ours to
license, and no licence from this project grants you any right to them. Use them
where you have the right to.

This is why the repository itself carries no compiled engine: the XCFramework is
gitignored and regenerated locally by `build_frameworks.py`. The `.ipa` exists
only because an installable app cannot avoid embedding it.

## Installing the released `.ipa`

Be aware before you download it that the attached build is **signed ad hoc for a
specific set of registered devices**, not for general distribution. Its
provisioning profile lists individual device identifiers and expires, so it will
not install on an arbitrary iPhone or iPad -- the install will fail on a device
that is not in the profile. It also carries another developer's signing
identity.

If you want to run this, build it from source with your own team. The README
explains how; `DEVELOPMENT_TEAM` in `project.yml` is the one line to change.

## The engine

- **openbst** by Stanislaw Przedzinkowski -- <https://github.com/Mudb0y/openbst>
  The C engine, MIT. Its tables are the restricted part described above.
- **BeSTspeech / Keynote GOLD** -- the commercial products these tables came
  from, by Berkeley Speech Technologies and later HumanWare. Neither is
  affiliated with this project, and neither has endorsed it.

## Naming

"Keynote Gold" is used in voice names because that is what these builds were
sold as, and users recognise it. It is a trademark of its respective owner. Its
use here is descriptive and implies no affiliation.

## What is actually ours

The iOS integration only:

- `iOSProject/Sources` and `iOSProject/OpenBSTExtension/Sources` -- the app and
  the speech provider extension
- `iOSProject/Shared` -- the Swift wrapper over the engine's C API, the SSML
  parser, the rate and pitch mapping, the voice catalogue
- `iOSProject/Tests` -- the test suites
- `iOSProject/build_frameworks.py`, `iOSProject/smoke_test.py`, `project.yml`

That is the part offered under the MIT licence in LICENSE.
