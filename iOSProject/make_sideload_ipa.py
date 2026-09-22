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

Whether the App Group is *load-bearing* is a separate question. Nothing in the
Swift reads it -- the voice list is computed from the engine's own static build
table, not from shared defaults -- so it looks like it is not. But it was added
while chasing registration and the app has not been run on a device without it,
so that is an assumption, not a measurement. If voices stop appearing, build
with --keep-app-group on a paid account instead, or restore the block in
project.yml.

The repository's own project.yml is left alone: this writes a temporary spec
beside it, generates into a project of its own name, and cleans up after itself.

Usage:
    python3 make_sideload_ipa.py                       # -> build/iBestSpeech-sideload.ipa
    python3 make_sideload_ipa.py --out /tmp/foo.ipa
    python3 make_sideload_ipa.py --keep-app-group      # paid account

Requires: xcodegen, Xcode, and Frameworks/OpenBST.xcframework already built by
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
    parser.add_argument("--out", default=str(PROJECT_DIR / "build" / "iBestSpeech-sideload.ipa"),
                        help="where to write the .ipa")
    parser.add_argument("--keep-app-group", action="store_true",
                        help="keep the App Group entitlement (needs a paid account)")
    parser.add_argument("--configuration", default="Release", choices=["Release", "Debug"])
    args = parser.parse_args()

    framework = PROJECT_DIR / "Frameworks" / "OpenBST.xcframework"
    if not framework.exists():
        raise SystemExit(
            f"{framework} is missing. Run build_frameworks.py --upstream <openbst> first."
        )

    spec = SOURCE_SPEC.read_text()
    spec = rename_spec(spec, TEMP_PROJECT_NAME)
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
