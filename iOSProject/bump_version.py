#!/usr/bin/env python3
"""Set the app and extension version numbers.

Usage:
    python3 bump_version.py 1.0.2          # sets CFBundleVersion to 3
    python3 bump_version.py 1.0.2 --build 7

Both targets must agree: the provider extension is what the system reads when
listing voices, and iOS refuses to load an extension whose version does not
match its container.
"""

import argparse
import re
import sys
from pathlib import Path

PLISTS = [
    Path("iOSProject/Info/Info.plist"),
    Path("iOSProject/Info/ExtensionInfo.plist"),
]


def set_value(text: str, key: str, value: str) -> tuple[str, int]:
    return re.subn(
        rf"(<key>{key}</key>\s*<string>)[^<]*(</string>)",
        rf"\g<1>{value}\g<2>",
        text,
        count=1,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("version", help="CFBundleShortVersionString, e.g. 1.0.2")
    parser.add_argument("--build", help="CFBundleVersion (default: derived from the version)")
    args = parser.parse_args()

    if not re.fullmatch(r"\d+(\.\d+)*", args.version):
        sys.exit(f"not a version number: {args.version}")

    # A monotonically increasing build number is what App Store Connect wants;
    # deriving it from the version is good enough and cannot go backwards.
    build = args.build or str(sum(int(p) for p in args.version.split(".")))

    for path in PLISTS:
        if not path.exists():
            sys.exit(f"missing: {path} (run from the repository root)")
        text = path.read_text(encoding="utf-8")

        new, n_version = set_value(text, "CFBundleShortVersionString", args.version)
        new, n_build = set_value(new, "CFBundleVersion", build)

        if n_version != 1 or n_build != 1:
            sys.exit(f"{path}: expected to find each key once, found "
                     f"{n_version} and {n_build}")

        if new == text:
            print(f"{path}: already {args.version} ({build})")
            continue

        path.write_text(new, encoding="utf-8")
        print(f"{path}: -> {args.version} ({build})")

    return 0


if __name__ == "__main__":
    sys.exit(main())
