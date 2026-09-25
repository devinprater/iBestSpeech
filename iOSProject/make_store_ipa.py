#!/usr/bin/env python3
"""Build a SIGNED App Store .ipa -- the kind TestFlight and the App Store accept.

This is the opposite of `make_sideload_ipa.py` in the one way that matters:

    sideload .ipa   UNSIGNED. No provisioning profile, no _CodeSignature, so a
                    re-signing tool (iLoader, AltStore, Sideloadly) can replace
                    the signature with the user's own.
    store .ipa      SIGNED with an Apple Distribution certificate and an App
                    Store provisioning profile. Apple refuses anything else, and
                    refuses it *after* a delivery that takes twenty minutes.

So they are two products of one codebase, not one product with a flag.

The engine is the same table-free one the public build uses: the voice data
belongs to Berkeley/HumanWare, so nothing distributed carries it, and each
tester imports their own Keynote Gold file. `--keep-tables` is refused rather
than offered -- the bundled build exists for the author's own device, and
sideloading it is how he tests that.

Unlike the sideload build, the App Group is KEPT: a paid account can hold one,
and it is the only channel from the app to the speech extension.

Requires macOS with Xcode. Nothing here can run on Linux -- `xcodebuild` is the
whole point -- so this script is exercised on the CI runner, and its decisions
are unit-tested separately by test_store_export.py, which needs no Mac.

Usage:
    python3 make_store_ipa.py \
        --key-id ABC123 --issuer-id DEF456 --key-path ~/.keys/AuthKey_ABC123.p8
"""

import argparse
import importlib.util
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

PROJECT_DIR = Path(__file__).resolve().parent
SOURCE_SPEC = PROJECT_DIR / "project.yml"
INFO_PLIST = PROJECT_DIR / "Info" / "Info.plist"
TEMP_PROJECT_NAME = "iBestSpeechStore"
APP_GROUP = "group.com.devin.ibestspeech"

# The scheme is derived from the TARGET, not from the project: renaming the
# project does not rename the targets, and XcodeGen auto-generates one scheme per
# target. So this stays `iBestSpeech` even though the project is renamed --
# passing the renamed project name here fails with "scheme not found", which
# reads like a corrupt project rather than a wrong flag.
SCHEME = "iBestSpeech"

# The table-free engine. A store build must not carry the tables either.
FRAMEWORK = "OpenBSTNoTables.xcframework"

# `app-store-connect` is the current spelling (Xcode 15.4+). Older Xcode called
# it `app-store`; override with --method if a runner rejects the new name.
DEFAULT_METHOD = "app-store-connect"


def load_sideload_module():
    """Import make_sideload_ipa for its project.yml text edits.

    Those helpers are already unit-tested (test_spec_edits.py). Reusing them
    keeps one definition of how the spec is rewritten, so a change cannot land
    in one packaging path and miss the other.
    """
    path = PROJECT_DIR / "make_sideload_ipa.py"
    if not path.is_file():
        raise SystemExit(f"missing {path}")
    spec = importlib.util.spec_from_file_location("make_sideload_ipa", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def read_plist_values(path, keys):
    with open(path, "rb") as fh:
        data = plistlib.load(fh)
    return {k: data[k] for k in keys if k in data}


def target_bundle_id(spec, target):
    """The bundle ID a target is built with, from project.yml.

    Not from the Info.plist: those hold `$(PRODUCT_BUNDLE_IDENTIFIER)`, a build
    variable. Reading the plist instead gives the literal string for both the app
    and the extension -- two "different" IDs that are the same placeholder, which
    is how a comparison against either one silently checks nothing.
    """
    lines = spec.splitlines()
    inside = False
    for line in lines:
        if re.match(rf"^  {re.escape(target)}:\s*$", line):
            inside = True
            continue
        if inside:
            # A new top-level target entry ends this one.
            if re.match(r"^  \S", line) and not line.startswith("    "):
                break
            found = re.search(r"PRODUCT_BUNDLE_IDENTIFIER:\s*(\S+)", line)
            if found:
                return found.group(1)
    raise SystemExit(f"no PRODUCT_BUNDLE_IDENTIFIER for target {target} in project.yml")


def project_info():
    """The team and bundle IDs, read from the project rather than hardcoded."""
    spec = SOURCE_SPEC.read_text()
    team = re.search(r"DEVELOPMENT_TEAM:\s*(\S+)", spec)
    if not team:
        raise SystemExit("project.yml has no DEVELOPMENT_TEAM")

    # Version is a literal in the plist, so it comes from there; the identifiers
    # are build variables, so they come from the spec.
    app = read_plist_values(INFO_PLIST, ["CFBundleShortVersionString",
                                         "CFBundleVersion"])
    if "CFBundleShortVersionString" not in app:
        raise SystemExit("Info.plist has no CFBundleShortVersionString")

    return {
        "team_id": team.group(1),
        "bundle_id": target_bundle_id(spec, "iBestSpeech"),
        "extension_bundle_id": target_bundle_id(spec, "iBestSpeechProvider"),
        "version": app["CFBundleShortVersionString"],
        "build": app.get("CFBundleVersion", "1"),
    }


def export_options(info, method=DEFAULT_METHOD):
    """The ExportOptions.plist, as a dict.

    Pure and separate from the build so the decisions in it can be tested on a
    machine with no Xcode -- several of them are upload failures if wrong.
    """
    return {
        # `app-store-connect` is what Xcode 15.4+ expects; `app-store` is the
        # older name. A runner that rejects it needs --method app-store.
        "method": method,
        # Write the IPA to disk; do not have Xcode also upload it. The upload is
        # a separate, visible step (asc), so a failure says which half broke.
        "destination": "export",
        "teamID": info["team_id"],
        # Automatic signing plus -allowProvisioningUpdates lets the runner create
        # or refresh the App Store profile from the API key. With manual signing
        # a `provisioningProfiles` map would be required instead.
        "signingStyle": "automatic",
        "stripSwiftSymbols": True,
        "uploadSymbols": True,
        # Respect the version and build number already in Info.plist. Letting
        # Xcode renumber here would make the tag disagree with what shipped.
        "manageAppVersionAndBuildNumber": False,
    }


def write_export_options(path, options):
    with open(path, "wb") as fh:
        plistlib.dump(options, fh)
    return path


def prepare_spec(info):
    """The project.yml the store build uses.

    Renamed like the sideload build, and pointed at the table-free framework.
    Unlike the sideload build, the App Group is NOT stripped: it needs to be in
    the entitlements for the extension to see the user's file, and unlike a free
    account a paid one can hold it.
    """
    m = load_sideload_module()
    spec = SOURCE_SPEC.read_text()
    spec = m.rename_spec(spec, TEMP_PROJECT_NAME)
    spec = m.point_at_framework(spec, FRAMEWORK)
    if "appGroups:" not in spec:
        raise SystemExit(
            "project.yml has no appGroups block, so the extension cannot read "
            "the user's imported file")
    return spec


def run(command, description, **kwargs):
    print(f"  {description}")
    proc = subprocess.run(command, capture_output=True, text=True, **kwargs)
    if proc.returncode != 0:
        tail = (proc.stdout or "")[-3000:] + (proc.stderr or "")[-3000:]
        raise SystemExit(f"{description} failed:\n{tail}")
    return proc


def verify_profile(profile_path, want_group):
    """What the embedded provisioning profile actually grants.

    `-allowProvisioningUpdates` will happily issue a profile WITHOUT the App
    Group if the App ID does not have the capability enabled, and the build then
    goes green, the upload succeeds, and the extension cannot read the user's
    file on a real device. Apple's side is the only place that can fix it, so
    fail here instead of shipping it.
    """
    # `security` is macOS-only. If it is absent, say so rather than returning no
    # problems: a check that could not run must never read as a pass.
    if shutil.which("security") is None:
        return ["cannot verify the provisioning profile: the `security` tool is "
                "not available on this host (it is macOS-only)"]

    proc = subprocess.run(["security", "cms", "-D", "-i", str(profile_path)],
                          capture_output=True)
    if proc.returncode != 0:
        return ["could not decode the embedded provisioning profile"]
    try:
        plist = plistlib.loads(proc.stdout)
    except Exception as exc:  # noqa: BLE001 - any parse failure is the same news
        return [f"the embedded profile is not a readable plist: {exc}"]

    problems = []
    entitlements = plist.get("Entitlements", {})
    groups = entitlements.get("com.apple.security.application-groups", [])
    if want_group and want_group not in groups:
        problems.append(
            f"the profile does not grant {want_group} (it grants {groups or 'none'}). "
            "Enable App Groups on the App ID in the developer portal, then re-run")
    if entitlements.get("get-task-allow"):
        problems.append(
            "the profile is a DEVELOPMENT profile (get-task-allow is true); the "
            "App Store rejects a distribution build signed with one")
    if plist.get("ProvisionsAllDevices"):
        problems.append("the profile is an enterprise profile, not App Store")
    return problems


def verify_ipa(ipa_path, info, signed=True):
    """Everything Apple checks that can be checked before uploading.

    A store IPA is the mirror image of a sideload one: it MUST be signed and
    MUST carry a profile. With `signed=False` (a dry run, which has no
    certificate), the signature and profile checks are skipped and the rest --
    icon, version, extension, and that it is table-free -- still run, so the
    build path is verified even before the Admin key exists.
    """
    failures = []
    with tempfile.TemporaryDirectory() as tmp:
        run(["unzip", "-q", str(ipa_path), "-d", tmp], "unpack for inspection")
        # Xcode names the bundle after PRODUCT_NAME (iBestSpeech), NOT after the
        # project, so the renamed project does not rename the product. Find it.
        app = Path(tmp) / "Payload" / "iBestSpeech.app"
        if not app.is_dir():
            candidates = list((Path(tmp) / "Payload").glob("*.app"))
            if not candidates:
                return ["the .ipa contains no Payload/*.app"]
            app = candidates[0]

        with open(app / "Info.plist", "rb") as fh:
            plist = plistlib.load(fh)
        # The executable name comes from the plist, so it cannot drift from the
        # bundle name the way a guess can.
        executable = plist.get("CFBundleExecutable") or app.stem
        main_binary = app / executable
        extension = app / "PlugIns" / "iBestSpeechProvider.appex"

        # --- signed, and the signature is valid ---------------------------
        if not signed:
            # A dry run has no distribution certificate, so signing is turned
            # off in the build and can only be reported, not checked.
            print("  (dry run: the signature and profile are not checked)")
        elif not (app / "_CodeSignature").is_dir():
            failures.append("no _CodeSignature: this is unsigned, which is a "
                            "sideload build, not a store build")
        else:
            proc = subprocess.run(
                ["codesign", "--verify", "--deep", "--strict", str(app)],
                capture_output=True, text=True)
            if proc.returncode != 0:
                failures.append("the signature does not verify: "
                                + (proc.stderr or "").strip()[:300])

        # --- a distribution profile is embedded ---------------------------
        profile = app / "embedded.mobileprovision"
        if signed and not profile.is_file():
            failures.append("no embedded.mobileprovision: the App Store rejects "
                            "a build without one")
        elif signed:
            failures.extend(verify_profile(profile, APP_GROUP))

        # --- the extension is there and also signed ------------------------
        if not extension.is_dir():
            failures.append("the provider extension is not embedded, so the "
                            "install would have no voices")
        elif signed and not (extension / "_CodeSignature").is_dir():
            failures.append("the provider extension is unsigned")

        # --- the icon, without which ITMS-90022 ---------------------------
        if not (app / "Assets.car").is_file():
            failures.append("no Assets.car: the icon catalog did not compile")
        if not plist.get("CFBundleIconName"):
            failures.append("CFBundleIconName missing (ITMS-90022)")
        if plist.get("CFBundleIdentifier") != info["bundle_id"]:
            failures.append(
                f"bundle ID is {plist.get('CFBundleIdentifier')}, "
                f"expected {info['bundle_id']}")
        if plist.get("CFBundleShortVersionString") != info["version"]:
            failures.append(
                f"version is {plist.get('CFBundleShortVersionString')}, "
                f"expected {info['version']}")

        # --- and it must NOT carry the tables -----------------------------
        # The tables are megabytes; a store build that still has them is both a
        # rights problem and a sign the wrong framework was linked.
        if main_binary.is_file():
            size = main_binary.stat().st_size
            # Measured: the bundled binary is ~5.7 MB, the table-free one ~2.0 MB.
            if size > 4_000_000:
                failures.append(
                    f"the app binary is {size:,} bytes, which is bundled-build "
                    "size -- the tables are in a build that must not carry them")
        else:
            failures.append(f"no main binary at {main_binary.name}")

    return failures


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=None,
                    help="where to write the .ipa (default: build/iBestSpeech-<ver>-store.ipa)")
    ap.add_argument("--key-id", default=os.environ.get("ASC_KEY_ID"),
                    help="App Store Connect API key ID (or $ASC_KEY_ID)")
    ap.add_argument("--issuer-id", default=os.environ.get("ASC_ISSUER_ID"),
                    help="App Store Connect issuer ID (or $ASC_ISSUER_ID)")
    ap.add_argument("--key-path", default=os.environ.get("ASC_PRIVATE_KEY_PATH"),
                    help="path to AuthKey_*.p8 (or $ASC_PRIVATE_KEY_PATH)")
    ap.add_argument("--method", default=DEFAULT_METHOD,
                    help=f"export method (default: {DEFAULT_METHOD})")
    ap.add_argument("--keep-tables", action="store_true",
                    help="refused: see the error message")
    ap.add_argument("--unsigned", action="store_true",
                    help="build without a certificate, to exercise the pipeline "
                         "before an Admin API key exists; the result is NOT "
                         "uploadable, and the signature is not checked")
    ap.add_argument("--configuration", default="Release",
                    choices=["Release", "Debug"])
    args = ap.parse_args()

    if args.unsigned and args.key_path:
        raise SystemExit("--unsigned and --key-path are contradictory: one asks "
                         "for no certificate, the other to authenticate so one "
                         "can be obtained")

    if args.keep_tables:
        raise SystemExit(
            "a store build cannot carry the tables: they belong to "
            "Berkeley/HumanWare and this artifact goes to testers. For your own "
            "device, build the bundled sideload IPA instead "
            "(make_sideload_ipa.py --keep-tables).")

    info = project_info()
    print(f"iBestSpeech {info['version']} ({info['build']}), team {info['team_id']}")
    print(f"  bundle: {info['bundle_id']} + {info['extension_bundle_id']}")
    print(f"  engine: {FRAMEWORK} (no voice data; testers import their own)")

    if args.out is None:
        args.out = str(PROJECT_DIR / "build" / f"iBestSpeech-{info['version']}-store.ipa")
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)

    # XcodeGen reads project.yml and writes iBestSpeechStore.xcodeproj.
    (PROJECT_DIR / "project.yml").write_text(prepare_spec(info))
    print(f"  wrote project.yml for {TEMP_PROJECT_NAME}")

    auth = []
    if args.key_path:
        # Authenticating with an API key is what makes this runnable on a CI
        # runner with nobody logged in. Without it, -allowProvisioningUpdates
        # has no credentials and signing fails.
        for flag, value in (("--key-id", args.key_id), ("--issuer-id", args.issuer_id)):
            if not value:
                raise SystemExit(f"{flag} is required alongside --key-path")
        auth = [
            "-authenticationKeyPath", os.path.abspath(os.path.expanduser(args.key_path)),
            "-authenticationKeyID", args.key_id,
            "-authenticationKeyIssuerID", args.issuer_id,
        ]
    else:
        print("  warning: no API key, so signing depends on a logged-in Xcode")

    with tempfile.TemporaryDirectory() as tmp:
        options_path = write_export_options(Path(tmp) / "ExportOptions.plist",
                                            export_options(info, args.method))
        archive = Path(tmp) / f"{TEMP_PROJECT_NAME}.xcarchive"

        run(["xcodegen", "generate", "--spec", "project.yml",
             "--project", f"{TEMP_PROJECT_NAME}.xcodeproj"],
            "generate the Xcode project", cwd=PROJECT_DIR)

        # Archive for a real device, not a simulator: a simulator build cannot
        # be uploaded, and code signing is skipped for it entirely.
        archive_cmd = ["xcodebuild", "archive",
                       "-project", f"{TEMP_PROJECT_NAME}.xcodeproj",
                       "-scheme", SCHEME,
                       "-configuration", args.configuration,
                       "-destination", "generic/platform=iOS",
                       "-archivePath", str(archive)]
        if args.unsigned:
            # No certificate on a dry run, so sign to run locally only -- which
            # still produces a real archive to export and inspect.
            archive_cmd += ["CODE_SIGNING_ALLOWED=NO"]
        else:
            archive_cmd += ["-allowProvisioningUpdates", *auth]
        archive_cmd += ["MARKETING_VERSION=" + info["version"],
                        "CURRENT_PROJECT_VERSION=" + info["build"]]
        run(archive_cmd, "archive", cwd=PROJECT_DIR)

        # Do not take the exit code as proof: require the archive to be there.
        if not Path(archive).is_dir():
            raise SystemExit(f"xcodebuild reported success but wrote no archive "
                             f"at {archive}")

        # Export re-signs for distribution and produces the .ipa. With
        # --unsigned there is no certificate to sign with, so this uses the same
        # export path but with signing off, which still exercises xcodebuild's
        # packaging -- that is what makes the dry run meaningful.
        if args.unsigned:
            run(["xcodebuild", "-exportArchive",
                 "-archivePath", str(archive),
                 "-exportOptionsPlist", str(options_path),
                 "-exportPath", str(out.parent),
                 ], "export the .ipa (unsigned)", cwd=PROJECT_DIR)
        else:
            run(["xcodebuild", "-exportArchive",
                 "-archivePath", str(archive),
                 "-exportOptionsPlist", str(options_path),
                 "-exportPath", str(out.parent),
                 "-allowProvisioningUpdates",
                 *auth,
                 ],
                "export the signed .ipa", cwd=PROJECT_DIR)

        # xcodebuild names the exported .ipa after the SCHEME/app, not after the
        # renamed project, so find what it wrote rather than guessing.
        if not out.is_file():
            candidates = [p for p in out.parent.glob("*.ipa") if p != out]
            # Newest first: a stale ipa from an earlier run must not be mistaken
            # for the one just exported.
            candidates.sort(key=lambda p: p.stat().st_mtime, reverse=True)
            if candidates:
                shutil.move(str(candidates[0]), str(out))

    if not out.is_file():
        raise SystemExit(f"no .ipa was produced at {out}")
    print(f"  wrote {out} ({out.stat().st_size:,} bytes)")
    if args.unsigned:
        print("  NOTE: built without a certificate -- this .ipa cannot be "
              "uploaded. It exists to prove the build and packaging path.")

    print("verifying what Apple will check:")
    failures = verify_ipa(out, info, signed=not args.unsigned)
    if failures:
        for f in failures:
            print(f"FAIL: {f}", file=sys.stderr)
        return 1
    if args.unsigned:
        print("  iconed, extensioned, versioned, and table-free "
              "(signature not checked: dry run)")
    else:
        print("  signed, profiled, iconed, and table-free")
    return 0


if __name__ == "__main__":
    sys.exit(main())
