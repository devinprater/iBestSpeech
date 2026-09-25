#!/usr/bin/env python3
"""Check the TestFlight workflow and the scripts it pipes `asc` output into.

Two classes of mistake are worth catching here, and neither needs a Mac:

  1. A workflow that claims to gate something and does not. The worst case is an
     accidental upload: every one burns a build number at Apple permanently, so
     the gate has to be real. Checked by asserting that no step which reaches
     Apple can run unless dry_run is false.

  2. A parser that reads `asc`'s JSON wrongly. These run on the runner, where a
     mistake means either a wrong app ID or a cheerful "success" for an upload
     that failed processing. Both are checked against realistic payloads.

Run from the repo root:  python3 iOSProject/test_store_workflow.py
"""

import importlib.util
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
WORKFLOW = REPO / ".github" / "workflows" / "testflight.yml"

failures = []


def check(name, condition, detail=""):
    if condition:
        print(f"  ok    {name}")
    else:
        print(f"  FAIL  {name}" + (f"  -- {detail}" if detail else ""))
        failures.append(name)


def load(name):
    path = HERE / f"{name}.py"
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def workflow_steps(text):
    """Each step as (name, body), in order."""
    steps = []
    parts = re.split(r"^      - name: ", text, flags=re.M)[1:]
    for part in parts:
        name, _, body = part.partition("\n")
        steps.append((name.strip(), body))
    return steps


def main():
    text = WORKFLOW.read_text()
    print(f"testflight.yml is {len(text.splitlines())} lines")

    # --- the workflow must not run on a push ------------------------------
    check("it is manual-only, so a tag cannot trigger an upload",
          re.search(r"^on:\s*\n\s+workflow_dispatch:", text, re.M) is not None
          and "push:" not in text.split("jobs:")[0])
    check("dry_run defaults to true",
          re.search(r"dry_run:\s*\n\s+description:.*\n\s+type: boolean\s*\n\s+default: true",
                    text) is not None)

    # --- nothing that reaches Apple runs without the gate ------------------
    # These are the steps whose failure mode is a burned build number.
    reaching = ("Install asc", "Write the API key where asc can read it",
                "Find the app record", "Upload to TestFlight",
                "Read the build back from Apple")
    steps = dict(workflow_steps(text))
    for name in reaching:
        body = steps.get(name)
        if body is None:
            check(f"step {name!r} exists", False)
            continue
        # The condition may sit on the step itself or be inherited, so require it
        # on the step: an ungated step here is the whole risk.
        check(f"{name!r} cannot run without dry_run == false",
              "inputs.dry_run == false" in body,
              "an ungated step here would upload on any trigger")

    # --- the key is never echoed ------------------------------------------
    check("the .p8 is never printed", "cat \"$KEY\"" not in text and "echo \"$KEY\"" not in text)
    check("the key is written with restrictive permissions",
          text.count("chmod 600") >= 2)
    check("the key is removed at the end",
          "rm -f" in text and "always()" in text)

    # --- it ships the table-free build ------------------------------------
    check("the store script refuses tables", "keep-tables" in
          (HERE / "make_store_ipa.py").read_text())
    check("the .ipa is kept as an artifact so a failed upload can be retried",
          "upload-artifact" in text and "store-ipa" in text)

    # --- and it reads Apple back ------------------------------------------
    check("the workflow reads the build back rather than trusting the upload",
          "latest_build.py" in text)
    check("the app ID is looked up, not hardcoded",
          "find_app.py" in text and "--app \"123" not in text)

    # --- every `asc` flag in the workflow must exist ----------------------
    # An invented flag fails at runtime, on the runner, ten minutes in, after a
    # build. `--app-id` for `--app` was exactly that mistake -- it looked right
    # and the whole step would have died at the upload. Ask the real binary when
    # it is here, and fall back to the flags recorded from `asc 5.5.0` so the
    # check still runs on a machine without it.
    recorded = {
        "apps list": {"--bundle-id", "--limit", "--name", "--next", "--output",
                      "--paginate", "--pretty", "--sku", "--sort"},
        "builds list": {"--app", "--build-number", "--exclude-expired", "--include",
                        "--limit", "--next", "--output", "--paginate", "--platform",
                        "--pretty", "--processing-state", "--sort", "--version"},
        "publish testflight": {"--app", "--build-id", "--build-number", "--confirm",
                               "--group", "--ipa", "--locale", "--notify", "--output",
                               "--platform", "--pretty", "--submit", "--test-notes",
                               "--timeout", "--upload-only", "--version", "--wait"},
    }
    known_flags = {}
    asc_path = shutil.which("asc")
    if asc_path:
        for command in recorded:
            proc = subprocess.run([asc_path, *command.split(), "--help"],
                                  capture_output=True, text=True)
            flags = set(re.findall(r"^\s+(--[a-z0-9-]+)", proc.stdout, re.M))
            known_flags[command] = flags or recorded[command]
        print(f"  (checking asc flags against the real {asc_path})")
    else:
        known_flags = recorded
        print("  (asc is not on this host; checking against the flags recorded "
              "from asc 5.5.0)")

    # Pull every `asc <subcommand...> --flag` out of the workflow's run blocks.
    #
    # Only real commands: a shell COMMENT inside the step also mentions the flag
    # (`# --app is the numeric App Store Connect app ID`), and counting that as
    # an invented flag is a false positive that would train you to ignore this
    # check. So drop comment lines, then join `\`-continued lines so a flag on
    # the next line is still attributed to its command.
    def command_pairs(body):
        pairs = []
        current = None
        for line in body.splitlines():
            if line.strip().startswith("#"):
                continue
            joined = line.rstrip()
            continued = joined.endswith("\\")
            text_line = joined[:-1] if continued else joined

            if current is None:
                for command in recorded:
                    marker = "asc " + command
                    at = text_line.find(marker)
                    if at >= 0:
                        current = command
                        text_line = text_line[at + len(marker):]
                        break
            if current is not None:
                for flag in re.findall(r"(--[a-z0-9-]+)", text_line):
                    pairs.append((current, flag))
                if not continued:
                    current = None
        return pairs

    used = []
    steps_body = text.split("jobs:", 1)[-1]
    for step_name, body in workflow_steps("      - name: " + steps_body):
        used.extend(command_pairs(body))
    # Steps are also keyed by their `run: |` blocks; the split above covers them,
    # and this second pass catches any content the first missed.
    used.extend(command_pairs(text))
    used = sorted(set(used))

    check("the workflow actually calls asc", bool(used), "no asc calls found")
    # Prove the extraction sees the REAL commands: a parser that finds nothing
    # would make the unknown-flag check pass while checking nothing at all.
    expected_pairs = {("publish testflight", "--upload-only"),
                      ("publish testflight", "--app"),
                      ("builds list", "--app"),
                      ("apps list", "--output")}
    missing_pairs = sorted(expected_pairs - set(used))
    check("the extractor found the flags that are definitely there",
          not missing_pairs,
          f"extraction missed: {missing_pairs}")

    unknown = sorted({(c, f) for c, f in used if f not in known_flags.get(c, set())})
    check("every asc flag in the workflow exists on the real binary",
          not unknown,
          f"invented flag(s): {', '.join(f'{c} {f}' for c, f in unknown)}")

    # Guard the specific mistake that was made, so it cannot come back.
    check("the workflow does not use the nonexistent --app-id",
          "--app-id" not in text)

    # --- and the CLI is pinned with a checksum, not "latest" --------------
    check("asc is installed at a pinned version, not 'latest'",
          "releases/download/${ASC_VERSION}" in text and "asccli.sh/install" not in text)
    check("the downloaded binary's checksum is verified before running it",
          "checksums.txt" in text and "shasum -a 256" in text)

    # --- find_app.py ------------------------------------------------------
    fa = load("find_app")
    real = {"data": [
        {"id": "987654321", "attributes": {"bundleId": "com.other.app", "name": "Other"}},
        {"id": "1234567890", "attributes": {"bundleId": "com.devin.ibestspeech",
                                            "name": "iBestSpeech"}},
    ]}
    check("find_app finds the right app among several",
          fa.find_app(real, "com.devin.ibestspeech") == "1234567890")
    check("find_app returns None for an app that is not there",
          fa.find_app(real, "com.not.present") is None)
    check("find_app copes with an empty account", fa.find_app({"data": []}, "x") is None)
    check("find_app copes with no data key at all", fa.find_app({}, "x") is None)
    # The ID comes back as a string because it is used as a shell argument; an
    # integer that large is fine in Python but the JSON may quote it.
    check("find_app handles a quoted ID",
          fa.find_app({"data": [{"id": "42", "attributes": {"bundleId": "b"}}]}, "b") == "42")

    # Run it as the workflow does, with the ID on stdout and nothing else.
    proc = subprocess.run(
        [sys.executable, str(HERE / "find_app.py"), "com.devin.ibestspeech"],
        input=json.dumps(real), capture_output=True, text=True)
    check("find_app prints only the ID on stdout",
          proc.stdout.strip() == "1234567890", repr(proc.stdout))
    missing = subprocess.run(
        [sys.executable, str(HERE / "find_app.py"), "com.nope"],
        input=json.dumps(real), capture_output=True, text=True)
    check("find_app prints nothing for a missing app (so the workflow can react)",
          missing.stdout.strip() == "", repr(missing.stdout))
    check("find_app still explains itself on stderr",
          "not in the account" in missing.stderr, repr(missing.stderr))

    # --- latest_build.py --------------------------------------------------
    lb = load("latest_build")

    def run_latest(payload):
        return subprocess.run(
            [sys.executable, str(HERE / "latest_build.py")],
            input=json.dumps(payload), capture_output=True, text=True)

    valid = {"data": [
        {"id": "1", "attributes": {"version": "1.0.12", "buildNumber": "13",
                                   "processingState": "VALID",
                                   "uploadedDate": "2026-09-25T01:00:00-07:00"}},
    ]}
    proc = run_latest(valid)
    check("a VALID build passes", proc.returncode == 0, proc.stdout + proc.stderr)
    check("it names the version and build",
          "1.0.12" in proc.stdout and "13" in proc.stdout, proc.stdout)

    processing = {"data": [
        {"id": "1", "attributes": {"version": "1.0.12", "buildNumber": "13",
                                   "processingState": "PROCESSING",
                                   "uploadedDate": "2026-09-25T01:00:00-07:00"}},
    ]}
    check("a build still PROCESSING is accepted, not called a failure",
          run_latest(processing).returncode == 0)

    failed = {"data": [
        {"id": "1", "attributes": {"version": "1.0.12", "buildNumber": "13",
                                   "processingState": "FAILED",
                                   "uploadedDate": "2026-09-25T01:00:00-07:00"}},
    ]}
    proc = run_latest(failed)
    check("a FAILED build FAILS the step", proc.returncode != 0, proc.stdout)

    proc = run_latest({"data": []})
    check("no builds at all FAILS the step", proc.returncode != 0, proc.stdout)

    proc = run_latest({})
    check("a payload with no data key FAILS rather than passing",
          proc.returncode != 0, proc.stdout)

    # An unrecognised state must not read as success. This is the shape a new
    # Apple state would take, and a cheerful pass would be a lie.
    odd = {"data": [
        {"id": "1", "attributes": {"version": "1", "buildNumber": "1",
                                   "processingState": "SOMETHING_NEW",
                                   "uploadedDate": "2026-09-25T01:00:00-07:00"}},
    ]}
    proc = run_latest(odd)
    check("an unknown state FAILS rather than passing", proc.returncode != 0, proc.stdout)

    # The newest build must be the one reported, which matters for the day a
    # second build exists and the older one failed.
    two = {"data": [
        {"id": "2", "attributes": {"version": "1.0.13", "buildNumber": "14",
                                   "processingState": "VALID",
                                   "uploadedDate": "2026-09-26T01:00:00-07:00"}},
        {"id": "1", "attributes": {"version": "1.0.12", "buildNumber": "13",
                                   "processingState": "FAILED",
                                   "uploadedDate": "2026-09-25T01:00:00-07:00"}},
    ]}
    proc = run_latest(two)
    check("the NEWEST build is reported, not the failing older one",
          proc.returncode == 0 and "1.0.13" in proc.stdout,
          proc.stdout + proc.stderr)

    # Garbage in must be a clear failure, not a traceback nobody can read.
    proc = subprocess.run([sys.executable, str(HERE / "latest_build.py")],
                          input="not json at all", capture_output=True, text=True)
    check("unreadable input fails with a message",
          proc.returncode != 0 and "JSON" in (proc.stdout + proc.stderr),
          proc.stdout + proc.stderr)

    print()
    if failures:
        print(f"test_store_workflow: {len(failures)} failure(s): {', '.join(failures)}")
        return 1
    print("test_store_workflow: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
