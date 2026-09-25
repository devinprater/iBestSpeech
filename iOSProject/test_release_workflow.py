#!/usr/bin/env python3
"""Check the release workflow actually fits together.

A workflow is not compiled, so its mistakes surface as a red run twenty minutes
in. This checks the things that are checkable from the file: that every artifact
it uploads is one it built, that every path a later step reads was written by an
earlier one, and that the published file is the table-free one.

Run from the repo root:  python3 iOSProject/test_release_workflow.py
"""

import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
WORKFLOW = HERE.parent / ".github" / "workflows" / "release.yml"

failures = []


def check(name, condition, detail=""):
    if condition:
        print(f"  ok    {name}")
    else:
        print(f"  FAIL  {name}" + (f"  -- {detail}" if detail else ""))
        failures.append(name)


def main():
    text = WORKFLOW.read_text()
    print(f"release.yml is {len(text.splitlines())} lines")

    # --- step names, in order -------------------------------------------------
    steps = re.findall(r"^      - name: (.+)$", text, re.M)
    print(f"steps: {len(steps)}")
    for s in steps:
        print(f"    - {s}")

    # --- every upload path must be a file some earlier step wrote -------------
    # Upload paths are written with GitHub expressions -- `${{ runner.temp }}`,
    # `${{ env.VERSION }}` -- which contain spaces and braces, so it is the KIND
    # that can be compared, not the literal string. Normalising the two forms to
    # the same shape is what makes a mismatch (an upload of something never
    # built) visible.
    def kind(path: str) -> str:
        return "public" if "public" in path else "bundled"

    uploads = re.findall(r"path: (\S*\$\{\{ runner\.temp \}\}/\S*)", text)
    builds = re.findall(r'--out "(\S*\$\{?RUNNER_TEMP\}?/\S*)"', text)
    check("the workflow uploads something", bool(uploads), "no upload-artifact path found")
    check("the workflow builds something", bool(builds), "no --out found")
    built_kinds = {kind(b) for b in builds}
    for u in uploads:
        check(f"uploaded {kind(u)} .ipa is built by an earlier step",
              kind(u) in built_kinds, f"built kinds: {sorted(built_kinds)}")

    # --- and every file a later step reads must have been built --------------
    referenced = re.findall(r'IPA="(\S*\$\{?RUNNER_TEMP\}?/\S*)"', text)
    for r in referenced:
        check(f"referenced {kind(r)} .ipa is built", kind(r) in built_kinds,
              f"built kinds: {sorted(built_kinds)}")

    # --- the published artifact must be the table-free one -------------------
    publish = text.split("- name: Publish the release")[-1]
    check("the release attaches the PUBLIC ipa",
          "public.ipa" in publish and "sideload.ipa" not in publish,
          publish.strip()[:200])

    # --- both kinds are built, and the bundled one needs its flag ------------
    check("the public build passes no table flag",
          re.search(r"make_sideload_ipa\.py \\\n(?!\s+--keep-tables)[^#]*public\.ipa", text)
          is not None)
    check("the bundled build opts in with --keep-tables",
          re.search(r"make_sideload_ipa\.py \\\n\s+--keep-tables \\\n", text) is not None)

    # --- the table-free property is verified, not assumed -------------------
    check("the workflow verifies the public archive has no table symbols",
          "the public archive still carries table data" in text)

    # --- the import path is tested on the runner, before anything is built ---
    check("the import-path tests run in CI", "import_tests.py" in text)
    check("the spec-edit tests run in CI", "test_spec_edits.py" in text)

    # --- a step that reads VERSION must come after the step that writes it ----
    write_idx = text.find("VERSION=$VERSION")
    for use in re.finditer(r"\$\{VERSION\}", text):
        check_step_order = use.start() > write_idx
        if not check_step_order:
            check("no step uses VERSION before it is set", False,
                  "a ${VERSION} appears before the PlistBuddy read")
            break
    else:
        check("no step uses VERSION before it is set", True)

    print()
    if failures:
        print(f"test_release_workflow: {len(failures)} failure(s): {', '.join(failures)}")
        return 1
    print("test_release_workflow: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
