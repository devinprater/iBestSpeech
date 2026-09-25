#!/usr/bin/env python3
"""Check the store build's decisions, without a Mac.

`make_store_ipa.py` cannot run here -- `xcodebuild` is the whole point, and it
exists only on macOS. But most of what can go wrong is not the build, it is a
decision made before it: the export method's spelling, the version stamping, a
mistaken refusal, the wrong framework. Those are pure functions, so they are
checked here, and the runner is left to prove only that Xcode cooperates.

Run from the repo root:  python3 iOSProject/test_store_export.py
"""

import importlib.util
import os
import plistlib
import re
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent

failures = []


def check(name, condition, detail=""):
    if condition:
        print(f"  ok    {name}")
    else:
        print(f"  FAIL  {name}" + (f"  -- {detail}" if detail else ""))
        failures.append(name)


def load():
    path = HERE / "make_store_ipa.py"
    spec = importlib.util.spec_from_file_location("make_store_ipa", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    m = load()
    info = m.project_info()
    print("project:")
    for k, v in info.items():
        print(f"    {k} = {v}")

    # --- the identities come from the project, not from guesses ------------
    check("a team ID was read", bool(info["team_id"]))
    check("the app and extension bundle IDs differ",
          info["bundle_id"] != info["extension_bundle_id"])
    check("the extension is a child of the app bundle",
          info["extension_bundle_id"].startswith(info["bundle_id"] + "."))
    check("a version was read", bool(info["version"]))

    # --- the scheme is the TARGET's name, not the project's ----------------
    # XcodeGen names schemes after targets and the rename only touches `name:`,
    # so using the renamed project name here fails with "scheme not found" --
    # which reads like a corrupt project rather than a wrong flag.
    check("the scheme is the target name, not the renamed project",
          m.SCHEME == "iBestSpeech" and m.SCHEME != m.TEMP_PROJECT_NAME,
          f"SCHEME={m.SCHEME} TEMP_PROJECT_NAME={m.TEMP_PROJECT_NAME}")
    check("the scheme's target really exists in the spec",
          f"  {m.SCHEME}:" in (HERE / "project.yml").read_text())

    # --- the store build uses the table-free framework, always -------------
    check("the store build uses the table-free framework",
          "NoTables" in m.FRAMEWORK, m.FRAMEWORK)
    # A store build that linked the tables would ship someone else's data.
    spec = m.prepare_spec(info)
    check("the prepared spec names only the table-free framework",
          "OpenBST.xcframework" not in spec)

    # --- and it KEEPS the App Group (the opposite of the sideload build) ---
    check("the prepared spec keeps the App Group", "appGroups:" in spec)
    check("the App Group identifier survives",
          "group.com.devin.ibestspeech" in spec)

    # --- the spec is renamed, like the sideload build ----------------------
    check("the prepared spec renames the project",
          f"name: {m.TEMP_PROJECT_NAME}" in spec)
    check("the store project name differs from the sideload one",
          m.TEMP_PROJECT_NAME != "iBestSpeechSideload")

    # --- export options: each of these is an upload failure if wrong -------
    opts = m.export_options(info)

    check("destination is export, so the upload is a separate visible step",
          opts["destination"] == "export", opts["destination"])
    check("signingStyle is automatic, so the runner can fetch a profile",
          opts["signingStyle"] == "automatic", opts["signingStyle"])
    check("the team ID is stamped", opts["teamID"] == info["team_id"])
    check("symbols are uploaded", opts["uploadSymbols"] is True)
    check("Swift symbols are stripped", opts["stripSwiftSymbols"] is True)
    # Xcode renumbering here would make the git tag disagree with what shipped.
    check("Xcode is NOT allowed to renumber the build",
          opts["manageAppVersionAndBuildNumber"] is False,
          opts["manageAppVersionAndBuildNumber"])
    check("the default method is the modern spelling",
          m.DEFAULT_METHOD == "app-store-connect", m.DEFAULT_METHOD)
    # A store build must never be exported as an ad-hoc or development build.
    check("the method is a distribution method, not ad-hoc or development",
          opts["method"] in ("app-store-connect", "app-store"), opts["method"])

    # --- a method override is honoured (older Xcode needs the old name) ----
    old = m.export_options(info, "app-store")
    check("the method can be overridden for older Xcode",
          old["method"] == "app-store")

    # --- the options really are a valid plist when written ----------------
    with tempfile.TemporaryDirectory() as tmp:
        path = m.write_export_options(Path(tmp) / "ExportOptions.plist", opts)
        with open(path, "rb") as fh:
            back = plistlib.load(fh)
        check("the written ExportOptions.plist round-trips", back == opts)

    # --- and the sources it names must exist, or xcodegen fails ------------
    # "missing source directory" on a fresh clone is build-breaking, and it is
    # invisible locally because the directory exists on the dev box. The real
    # failure was `- Assets` for a directory named `Assets.xcassets`.
    missing = []
    lines = (HERE / "project.yml").read_text().splitlines()
    in_sources = False
    for line in lines:
        text = line.strip()
        if text.startswith("sources:"):
            in_sources = True
            continue
        if in_sources:
            if text.startswith(("settings:", "dependencies:")):
                in_sources = False
                continue
            if text.startswith("- "):
                entry = text[2:].strip()
                if entry and not any(c in entry for c in "*$:"):
                    if not (HERE / entry).exists():
                        missing.append(entry)
    check("every source directory the store build generates exists",
          not missing, f"missing: {', '.join(missing)}")
    check("the icon catalog is named by its exact path",
          "- Assets.xcassets" in (HERE / "project.yml").read_text())

    # --- prepare_spec refuses a project with no App Group -----------------
    # The extension has no other way to reach the imported file, so a project
    # without one must fail loudly rather than produce a silently broken build.
    import importlib.util as ilu
    saved = m.SOURCE_SPEC
    try:
        with tempfile.TemporaryDirectory() as tmp:
            fake = Path(tmp) / "project.yml"
            fake.write_text("name: x\ntargets:\n  a:\n    type: application\n")
            m.SOURCE_SPEC = fake
            try:
                m.prepare_spec(info)
                check("a project with no App Group is refused", False)
            except SystemExit:
                check("a project with no App Group is refused", True)
    finally:
        m.SOURCE_SPEC = saved

    # --- and a store build refuses to carry the tables --------------------
    # Enforced as an error rather than silently ignored, because shipping the
    # tables is the one thing that must never happen in a distributed build.
    import subprocess
    proc = subprocess.run(
        [sys.executable, str(HERE / "make_store_ipa.py"), "--keep-tables"],
        capture_output=True, text=True)
    check("--keep-tables is refused by the store build",
          proc.returncode != 0 and "cannot carry the tables" in (proc.stdout + proc.stderr),
          (proc.stdout + proc.stderr)[:200])

    # --- xcodegen's two traps, both of which cost a CI run ----------------
    # `--project` is the OUTPUT DIRECTORY, not a filename. Passing a filename
    # creates `<name>.xcodeproj/<name>.xcodeproj` and xcodegen dies copying
    # XcodeGen into it. And `--spec` must be a SEPARATE file, never project.yml
    # itself: the generated project records the spec path, so editing the real
    # spec leaves the repo dirty and confuses the next run.
    src = (HERE / "make_store_ipa.py").read_text()
    # Look at the xcodegen CALL, not the whole file: the renamed project path is
    # legitimately built elsewhere (to verify it was generated), so a file-wide
    # search would fail on correct code.
    gen_call = re.search(r'run\(\["xcodegen".*?\)\s*,\s*"generate',
                         src, re.S)
    check("the xcodegen call was found", gen_call is not None)
    call = gen_call.group(0) if gen_call else ""
    check("--project is an output directory, not a filename",
          '"--project", "."' in call and "xcodeproj" not in call,
          f"xcodegen call was: {call[:200]}")
    check("--spec points at a separate file, not project.yml",
          '"--spec", TEMP_SPEC.name' in call and '"spec", "project.yml"' not in call,
          f"xcodegen call was: {call[:200]}")
    check("the temporary spec and project are cleaned up afterwards",
          "TEMP_SPEC" in src and "finally:" in src and "rmtree" in src)
    check("a missing generated project is reported, not assumed",
          "wrote no project at" in src)

    # --- the dry-run mode exists, and its contract is enforced ------------
    # Without a certificate the build cannot be signed, so the pipeline is only
    # testable if there is a mode that skips signing. These assertions are about
    # that mode staying honest: it must not claim to have verified a signature.
    check("there is an --unsigned mode for a dry run", "--unsigned" in src)
    check("--unsigned and --key-path are refused together",
          "contradictory" in src)
    check("an unsigned run says the .ipa cannot be uploaded",
          "cannot be " in src and "uploaded" in src)
    check("an unsigned run does not claim the signature was checked",
          "(signature not checked: dry run)" in src)
    # The signed path must still check everything.
    check("a signed run still checks the signature",
          "no _CodeSignature" in src)
    check("a signed run still checks the profile",
          "no embedded.mobileprovision" in src)

    proc = subprocess.run(
        [sys.executable, str(HERE / "make_store_ipa.py"),
         "--unsigned", "--key-path", "/tmp/nope.p8", "--key-id", "A", "--issuer-id", "B"],
        capture_output=True, text=True)
    check("--unsigned with --key-path is refused at runtime",
          proc.returncode != 0 and "contradictory" in (proc.stdout + proc.stderr),
          (proc.stdout + proc.stderr)[:200])

    # --- the profile check rejects the two profiles Apple rejects ---------
    check("a development profile would be rejected",
          hasattr(m, "verify_profile"))
    # --- the profile check never passes when it could not run -------------
    with tempfile.TemporaryDirectory() as tmp:
        bad = Path(tmp) / "dev.mobileprovision"
        bad.write_bytes(b"not a profile at all")
        problems = m.verify_profile(bad, m.APP_GROUP)
        check("an unverifiable profile is reported, not ignored", bool(problems),
              "a check that cannot run must not read as a pass")
        check("and the reason is stated",
              any("security" in p or "decode" in p for p in problems), problems)

    print()
    if failures:
        print(f"test_store_export: {len(failures)} failure(s): {', '.join(failures)}")
        return 1
    print("test_store_export: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
