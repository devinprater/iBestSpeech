#!/usr/bin/env python3
"""Build an unsigned IPA that sideloading tools can re-sign.

Sideloading tools -- iLoader, AltStore, SideStore, Sideloadly -- work by taking
an .ipa and signing it with *your* Apple ID. That only works if the .ipa is
either unsigned or signed by someone else: a build signed to a specific device
list (which is what `xcodebuild -exportArchive` with a development profile
produces) is useless to them, because they cannot re-sign a binary whose
entitlements they cannot grant.

There are two obstacles, and this script handles both.

**Signing.** The build here disables signing entirely, so the packaged .ipa has
no signature and no provisioning profile and is free for a tool to replace.

**Entitlements.** A free Apple ID cannot obtain an App Group. A profile that
grants one requires a paid account, so an .ipa carrying the entitlement is
rejected at signing time by the tools that use free accounts. This script strips
the App Group from the XcodeGen spec before generating, so the resulting binary
asks for nothing a free account cannot provide.

⛔ **Stripping the App Group costs the file import half its function.** The
entitlement is what lets the provider extension read the engine files the user
imports: without it the app still imports and previews them from its own
container, but the extension cannot see that container, so the voice never
appears in VoiceOver's list. The app states this in its own interface when it
detects the situation (ImportStore.isShared), so it is a known limitation rather
than a mystery. For a build meant to last, install with --keep-app-group on a
paid account — which TestFlight requires anyway.

Two kinds of payload:

    (default)     carries the engine's tables. For your own device.
    --no-tables   carries NO table data. This is the distributable kind: the
                  tables belong to Berkeley/HumanWare, so they are left out and
                  the user supplies their own Keynote Gold file. Needs
                  Frameworks/OpenBSTNoTables.xcframework, built with
                  `build_frameworks.py --no-tables`.

The repository's own project.yml is left alone: this writes a temporary spec
beside it, generates into a project of its own name, and cleans up after itself.

Usage:
    python3 make_sideload_ipa.py                       # -> build/iBestSpeech-sideload.ipa
    python3 make_sideload_ipa.py --out /tmp/foo.ipa
    python3 make_sideload_ipa.py --no-tables           # distributable, no voice data
    python3 make_sideload_ipa.py --keep-app-group      # paid account

Requires: xcodegen, Xcode, and the XCFramework already built by
build_frameworks.py.
"""

import argparse
import os
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

PROJECT_DIR = Path(__file__).resolve().parent
SOURCE_SPEC = PROJECT_DIR / "project.yml"
TEMP_SPEC = PROJECT_DIR / "project-sideload.yml"
TEMP_PROJECT_NAME = "iBestSpeechSideload"


def strip_app_group(spec: str) -> str:
    """Remove the `appGroups:` block and the comment describing it."""
    lines = spec.splitlines(keepends=True)
    kept: list[str] = []
    index = 0

    while index < len(lines):
        line = lines[index]

        if line.startswith("appGroups:"):
            # Drop the block: the key and everything indented under it.
            index += 1
            while index < len(lines) and (
                lines[index].startswith((" ", "\t")) or not lines[index].strip()
            ):
                index += 1
            # Drop the comment block sitting above it, which describes a block
            # that is no longer there.
            while kept and (kept[-1].lstrip().startswith("#") or not kept[-1].strip()):
                kept.pop()
            if kept and not kept[-1].endswith("\n"):
                kept[-1] += "\n"
            continue

        kept.append(line)
        index += 1

    return "".join(kept)


def rename_spec(spec: str, name: str) -> str:
    for line in spec.splitlines():
        if line.startswith("name:"):
            return spec.replace(line, f"name: {name}", 1)
    raise SystemExit("project.yml has no `name:` line to rename")


def point_at_framework(spec: str, framework: str) -> str:
    """Repoint the project at a different XCFramework.

    The spec names the framework in two places per target -- the header search
    paths and the dependency -- and both have to move together or the build links
    one archive while including the other's headers.
    """
    old = "Frameworks/OpenBST.xcframework"
    new = f"Frameworks/{framework}"
    if old not in spec:
        raise SystemExit(f"the spec does not mention {old}")
    return spec.replace(old, new)


def run(command: list[str], description: str, **kwargs) -> subprocess.CompletedProcess:
    print(f"\n==> {description}")
    print("    " + " ".join(command))
    result = subprocess.run(command, cwd=PROJECT_DIR, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, **kwargs)
    if result.returncode != 0:
        print(result.stdout[-4000:])
        raise SystemExit(f"FAILED: {description}")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", default=None,
                        help="where to write the .ipa (default: build/iBestSpeech-<kind>.ipa)")
    parser.add_argument("--keep-app-group", action="store_true",
                        help="keep the App Group entitlement (needs a paid account)")
    parser.add_argument("--keep-tables", action="store_true",
                        help="include the engine's voice data. NOT distributable: those "
                             "tables belong to Berkeley/HumanWare. For your own device only.")
    parser.add_argument("--configuration", default="Release", choices=["Release", "Debug"])
    args = parser.parse_args()

    # Table-free is the DEFAULT, because it is the only distributable kind: the
    # voice data belongs to someone else, so a shipped app must not carry it and
    # the user imports their own Keynote Gold file instead. Making the bundled
    # build an explicit opt-in means it cannot be produced by forgetting a flag.
    framework_name = ("OpenBST.xcframework" if args.keep_tables
                      else "OpenBSTNoTables.xcframework")
    framework = PROJECT_DIR / "Frameworks" / framework_name
    if not framework.exists():
        hint = ("python3 build_frameworks.py --upstream <openbst>" if args.keep_tables
                else "python3 build_frameworks.py --upstream <openbst> --no-tables")
        raise SystemExit(f"{framework} is missing. Run: {hint}")

    if args.out is None:
        kind = "sideload" if args.keep_tables else "public"
        args.out = str(PROJECT_DIR / "build" / f"iBestSpeech-{kind}.ipa")

    spec = SOURCE_SPEC.read_text()
    spec = rename_spec(spec, TEMP_PROJECT_NAME)
    # Both the header search paths and the dependency have to move together, or
    # the build links one archive while including the other's headers.
    spec = point_at_framework(spec, framework_name)
    print(f"Linking {framework_name}"
          + (" (WITH voice data -- not distributable)" if args.keep_tables
             else " (no voice data -- the user supplies their own Keynote Gold file)"))
    if not args.keep_app_group:
        spec = strip_app_group(spec)
        print("App Group stripped: the .ipa will ask for nothing a free Apple ID "
              "cannot grant.")
    else:
        print("App Group kept: signing this needs a paid developer account.")

    if "appGroups:" in spec:
        raise SystemExit("strip failed: appGroups is still in the temporary spec")

    TEMP_SPEC.write_text(spec)
    project = PROJECT_DIR / f"{TEMP_PROJECT_NAME}.xcodeproj"
    derived = PROJECT_DIR / "build" / "sideload-derived"

    try:
        run(["xcodegen", "generate", "--spec", TEMP_SPEC.name, "--project", "."],
            "generating the sideload project")

        # Signing off entirely. The tools replace the signature, and any
        # signature we add here would only be one they have to undo.
        run([
            "xcodebuild",
            "-project", project.name,
            "-scheme", "iBestSpeech",
            "-configuration", args.configuration,
            "-sdk", "iphoneos",
            "-destination", "generic/platform=iOS",
            "-derivedDataPath", str(derived),
            "CODE_SIGNING_ALLOWED=NO",
            "CODE_SIGNING_REQUIRED=NO",
            "CODE_SIGN_IDENTITY=",
            "build",
        ], f"building unsigned ({args.configuration})")

        app = (derived / "Build" / "Products" / f"{args.configuration}-iphoneos"
               / "iBestSpeech.app")
        if not app.exists():
            raise SystemExit(f"built app not found at {app}")

        extension = app / "PlugIns" / "iBestSpeechProvider.appex"
        if not extension.exists():
            raise SystemExit(
                "the speech provider extension is not embedded. Sideloading this "
                "would give you an app with no voices."
            )

        # An .ipa is a zip with Payload/ at the root and nothing else.
        output = Path(args.out)
        output.parent.mkdir(parents=True, exist_ok=True)
        staging = PROJECT_DIR / "build" / "sideload-staging"
        if staging.exists():
            shutil.rmtree(staging)
        payload = staging / "Payload"
        payload.mkdir(parents=True)
        shutil.copytree(app, payload / app.name, symlinks=True)

        if output.exists():
            output.unlink()
        print(f"\n==> packaging {output.name}")
        with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
            for path in sorted(payload.rglob("*")):
                archive.write(path, path.relative_to(staging))

        # Verify what was produced rather than assuming: an unsigned .ipa must
        # carry no signature and no profile, or the tools cannot re-sign it.
        with zipfile.ZipFile(output) as archive:
            names = archive.namelist()

        problems = []
        if any("embedded.mobileprovision" in name for name in names):
            problems.append("contains a provisioning profile")
        if any("_CodeSignature" in name for name in names):
            problems.append("contains a code signature")
        if not any(name.endswith("PlugIns/iBestSpeechProvider.appex/"
                                 "iBestSpeechProvider") for name in names):
            problems.append("is missing the embedded extension binary")
        if not any(name.endswith("Payload/iBestSpeech.app/iBestSpeech") for name in names):
            problems.append("is missing the app binary")

        size = output.stat().st_size
        print(f"    {size:,} bytes, {len(names)} entries")

        if problems:
            for problem in problems:
                print(f"    PROBLEM: {problem}")
            raise SystemExit("the packaged .ipa is not sideloadable")

        print("    no provisioning profile, no code signature  -- re-signable")
        print(f"\nOK  {output}")
        if not args.keep_app_group:
            print("\nNote: the App Group was stripped for free-account compatibility.")
            print("If voices do not appear in Settings after sideloading, that is the")
            print("first suspect -- rebuild with --keep-app-group on a paid account.")
        return 0

    finally:
        # Leave the repository exactly as it was found.
        for path in (TEMP_SPEC, project):
            if path.is_dir():
                shutil.rmtree(path, ignore_errors=True)
            elif path.exists():
                path.unlink()
        shutil.rmtree(PROJECT_DIR / "build" / "sideload-staging", ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
