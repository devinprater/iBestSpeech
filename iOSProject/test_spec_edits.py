#!/usr/bin/env python3
"""Check the spec rewriting `make_sideload_ipa.py` does, without xcodegen.

The packaging script edits project.yml as text: rename the project, optionally
drop the App Group, optionally repoint at a different XCFramework. A text edit
that leaves one reference behind produces a project that links one archive while
including another's headers, which fails far from the cause. So the edits are
checked here directly.

Run from anywhere:  python3 /path/to/test_spec_edits.py
"""

import importlib.util
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load_script():
    """Import make_sideload_ipa.py as a module without running main()."""
    path = HERE / "make_sideload_ipa.py"
    spec = importlib.util.spec_from_file_location("make_sideload_ipa", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


failures = []


def check(name, condition, detail=""):
    if condition:
        print(f"  ok    {name}")
    else:
        print(f"  FAIL  {name}" + (f"  -- {detail}" if detail else ""))
        failures.append(name)


def main():
    m = load_script()
    source = (HERE / "project.yml").read_text()
    print(f"project.yml is {len(source.splitlines())} lines")

    # --- rename -------------------------------------------------------------
    renamed = m.rename_spec(source, "iBestSpeechSideload")
    check("rename changes the name line",
          "name: iBestSpeechSideload" in renamed and "name: iBestSpeech\n" not in renamed)

    # --- App Group ----------------------------------------------------------
    stripped = m.strip_app_group(renamed)
    check("App Group block is gone", "appGroups:" not in stripped)
    check("App Group identifier is gone", "group.com.devin.ibestspeech" not in stripped)
    check("the targets survive the strip",
          "iBestSpeechProvider:" in stripped and "PRODUCT_NAME: iBestSpeechProvider" in stripped)
    # The strip removes the comment above the block too; make sure it did not eat
    # anything else that mattered.
    check("the framework dependency survives", "Frameworks/OpenBST.xcframework" in stripped)

    # --- framework repointing ----------------------------------------------
    # The spec names the framework SIX times: a header search path for each SDK
    # for each of the two targets (4), plus one dependency per target (2). All six
    # have to move together -- a header path left pointing at the old archive makes
    # the build link one version while compiling against another's headers, which
    # fails a long way from the cause.
    EXPECTED = 6
    for framework in ("OpenBSTNoTables.xcframework", "OpenBST.xcframework"):
        pointed = m.point_at_framework(stripped, framework)
        # Nothing may still point at the ORIGINAL name, once the new name's own
        # occurrences are removed from consideration.
        leftover = "Frameworks/OpenBST.xcframework" in pointed.replace(
            f"Frameworks/{framework}", "")
        check(f"no stale reference left pointing at {framework}", not leftover)
        count = pointed.count(f"Frameworks/{framework}")
        check(f"{framework} referenced in all six places", count == EXPECTED,
              f"found {count}")
        check(f"{framework}: four header search paths survive",
              pointed.count("HEADER_SEARCH_PATHS") == 4,
              f"found {pointed.count('HEADER_SEARCH_PATHS')}")
        check(f"{framework}: two framework dependencies survive",
              pointed.count("- framework:") == 2,
              f"found {pointed.count('- framework:')}")

    # --- the no-tables spec must not name a table-carrying framework --------
    pointed = m.point_at_framework(stripped, "OpenBSTNoTables.xcframework")
    check("the table-free spec names only the table-free framework",
          "OpenBST.xcframework" not in pointed)

    # --- a spec with no framework mention must be refused, not silently ok --
    try:
        m.point_at_framework("name: x\n", "OpenBSTNoTables.xcframework")
        check("repointing a spec with no framework fails loudly", False)
    except SystemExit:
        check("repointing a spec with no framework fails loudly", True)

    # --- every source directory the spec names must exist -------------------
    # XcodeGen fails on a fresh clone with "missing source directory" when a
    # source is named but absent. That is a build-breaking typo, and it once
    # shipped as `- Assets` for a directory called `Assets.xcassets`: green in
    # every local test, red only when a workflow actually ran xcodegen.
    import os as _os
    ios_project = HERE
    spec_lines = source.splitlines()
    in_sources = False
    missing_dirs = []
    for line in spec_lines:
        stripped = line.strip()
        if stripped.startswith("sources:"):
            in_sources = True
            continue
        if in_sources:
            if stripped.startswith(("settings:", "dependencies:")):
                in_sources = False
                continue
            if stripped.startswith("- "):
                entry = stripped[2:].strip()
                if entry and not any(c in entry for c in "*$:"):
                    if not _os.path.exists(ios_project / entry):
                        missing_dirs.append(entry)
    check("every source directory project.yml names exists",
          not missing_dirs,
          f"missing: {', '.join(missing_dirs)}")
    # And the icon catalog specifically, by its exact path.
    check("the icon catalog is named by its exact path",
          "- Assets.xcassets" in source and "- Assets\n" not in source)

    # --- and the default is the table-free kind -----------------------------
    parser_defaults = {}
    # Read the defaults straight out of argparse by asking the script.
    import argparse
    import contextlib
    import io

    with contextlib.redirect_stdout(io.StringIO()):
        with contextlib.redirect_stderr(io.StringIO()):
            try:
                sys.argv = ["make_sideload_ipa.py"]
                m.main()
            except SystemExit:
                pass  # it will fail on the missing framework, which is fine
    # Simpler and more direct: the flag exists and defaults to False, so the
    # table-free branch is what runs when nobody says anything.
    check("there is an explicit opt-IN for tables",
          "--keep-tables" in (HERE / "make_sideload_ipa.py").read_text())
    check("tables are not the default",
          'action="store_true",\n                        help="include the engine' 
          in (HERE / "make_sideload_ipa.py").read_text())

    print()
    if failures:
        print(f"test_spec_edits: {len(failures)} failure(s): {', '.join(failures)}")
        return 1
    print("test_spec_edits: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
