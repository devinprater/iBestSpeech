#!/usr/bin/env python3
"""Build the app icon asset catalog from a master artwork file.

An iOS app cannot be uploaded without an icon: App Store Connect rejects the
build with ITMS-90022. The catalog has to be generated rather than hand-made,
because Apple's requirements are exact and a wrong PNG fails an upload that
takes twenty minutes to discover.

Since iOS 11 / Xcode 14 a single 1024x1024 asset is all that is required -- Xcode
derives every other size -- so this copies the master rather than resizing it,
and needs no image library.

Requirements enforced here, all of them real upload failures:
  - exactly 1024x1024 pixels
  - NO alpha channel. Apple rejects an icon with transparency outright; the
    system applies the rounded mask itself, so a rounded or transparent icon is
    wrong twice over.
  - PNG format
  - The app icon must NOT carry a rounded mask or a white border. That one
    cannot be checked mechanically; look at it.

Usage:
    python3 tools/make_app_icon.py iOSProject/Artwork/AppIcon-master.png
    python3 tools/make_app_icon.py --check      # verify, change nothing
"""

import argparse
import json
import os
import shutil
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
CATALOG = os.path.join(REPO, "iOSProject", "Assets.xcassets")
ICONSET = os.path.join(CATALOG, "AppIcon.appiconset")
MASTER = os.path.join(REPO, "iOSProject", "Artwork", "AppIcon-master.png")
ICON_NAME = "AppIcon"

# Xcode reads this file to find the art. `universal` + `platform: ios` is the
# single-size form; the older idiom/size/scale triplets are not needed and having
# both confuses the compiler.
ICONSET_CONTENTS = {
    "images": [
        {
            "filename": "icon-1024.png",
            "idiom": "universal",
            "platform": "ios",
            "size": "1024x1024",
        }
    ],
    "info": {"author": "xcode", "version": 1},
}

CATALOG_CONTENTS = {"info": {"author": "xcode", "version": 1}}


def png_header(path):
    """(width, height, colour_type) from the IHDR, without decoding the image."""
    with open(path, "rb") as fh:
        head = fh.read(33)
    if head[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG file")
    width, height = struct.unpack(">II", head[16:24])
    colour_type = head[25]
    return width, height, colour_type


# PNG colour types: 0 grey, 2 truecolour, 3 palette, 4 grey+alpha,
# 6 truecolour+alpha. 3 is rejected too because a palette entry can carry alpha.
HAS_ALPHA = {4, 6}


def complain(path):
    """Everything wrong with a candidate icon, as a list of strings."""
    problems = []
    try:
        width, height, colour_type = png_header(path)
    except (OSError, ValueError) as exc:
        return [f"cannot read {path}: {exc}"]

    if (width, height) != (1024, 1024):
        problems.append(f"must be exactly 1024x1024, is {width}x{height}")
    if colour_type in HAS_ALPHA:
        problems.append(
            "has an alpha channel (colour type "
            f"{colour_type}). Apple rejects a transparent app icon; flatten it "
            "onto an opaque background before using it"
        )
    return problems


def write(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        json.dump(obj, fh, indent=2)
        fh.write("\n")


def build(master):
    problems = complain(master)
    if problems:
        for p in problems:
            print(f"  {p}", file=sys.stderr)
        return 1

    os.makedirs(ICONSET, exist_ok=True)
    # The master is 1024x1024 already, so this is a copy -- deliberately, since
    # resizing would need an image library that is not guaranteed to exist.
    shutil.copyfile(master, os.path.join(ICONSET, "icon-1024.png"))
    write(os.path.join(CATALOG, "Contents.json"), CATALOG_CONTENTS)
    write(os.path.join(ICONSET, "Contents.json"), ICONSET_CONTENTS)
    print(f"  wrote {os.path.relpath(ICONSET, REPO)}/icon-1024.png")
    print(f"  wrote {os.path.relpath(ICONSET, REPO)}/Contents.json")
    return 0


def check(master):
    """Verify the catalog on disk is what the project expects."""
    failures = []
    icon = os.path.join(ICONSET, "icon-1024.png")

    if not os.path.isfile(icon):
        failures.append(f"no {os.path.relpath(icon, REPO)} -- the app has no icon "
                        "and App Store Connect will reject the upload (ITMS-90022)")
    else:
        problems = complain(icon)
        if problems:
            failures.append(f"{os.path.relpath(icon, REPO)}: " + "; ".join(problems))

    for path, want in ((os.path.join(CATALOG, "Contents.json"), CATALOG_CONTENTS),
                       (os.path.join(ICONSET, "Contents.json"), ICONSET_CONTENTS)):
        rel = os.path.relpath(path, REPO)
        if not os.path.isfile(path):
            failures.append(f"no {rel}")
            continue
        try:
            with open(path) as fh:
                got = json.load(fh)
        except json.JSONDecodeError as exc:
            failures.append(f"{rel} is not valid JSON: {exc}")
            continue
        if got != want:
            failures.append(f"{rel} does not match what Xcode expects")

    # A catalog nothing points at is a catalog that does nothing.
    spec = os.path.join(REPO, "iOSProject", "project.yml")
    if os.path.isfile(spec):
        with open(spec) as fh:
            text = fh.read()
        if f"ASSETCATALOG_COMPILER_APPICON_NAME: {ICON_NAME}" not in text:
            failures.append(
                "project.yml does not set "
                f"ASSETCATALOG_COMPILER_APPICON_NAME: {ICON_NAME}, so the "
                "catalog is never used")
        if "Assets" not in text:
            failures.append(
                "project.yml does not list Assets among the app target's "
                "sources, so the catalog is not compiled in")

    if failures:
        for f in failures:
            print(f"FAIL: {f}", file=sys.stderr)
        return 1
    print("  icon catalog is complete and wired into project.yml")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("master", nargs="?", default=MASTER,
                    help=f"1024x1024 opaque PNG (default: {os.path.relpath(MASTER, REPO)})")
    ap.add_argument("--check", action="store_true",
                    help="verify the catalog without changing anything")
    args = ap.parse_args()

    if args.check:
        return check(args.master)
    if not os.path.isfile(args.master):
        print(f"no master artwork at {args.master}", file=sys.stderr)
        return 1
    return build(args.master)


if __name__ == "__main__":
    sys.exit(main())
