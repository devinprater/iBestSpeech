#!/usr/bin/env python3
"""Report the newest build App Store Connect knows about, from `asc` JSON on stdin.

Used after an upload. The upload's own report is not evidence the build arrived
-- `asc publish` can report success for a delivery Apple later rejects during
processing -- so the check asks Apple what it actually holds.

Exits non-zero when there is no build, or when the newest one failed processing,
because a green workflow that uploaded nothing is the failure this exists to
catch.

Usage:
    asc builds list --app-id ID --output json | python3 iOSProject/latest_build.py
"""

import json
import sys

# Apple's build states. PROCESSING means it is still being examined; only
# VALID means it can actually be distributed.
GOOD = {"VALID", "PROCESSING"}
BAD = {"FAILED", "INVALID"}


def main():
    raw = sys.stdin.read()
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        sys.exit(f"could not read `asc` output as JSON: {exc}\n{raw[:500]}")

    rows = payload.get("data") or []
    if not rows:
        sys.exit("::error::no builds found for this app -- the upload did not land")

    # Newest first: asc returns them most recent first, but sort explicitly so a
    # change in ordering cannot make this report the wrong build.
    def uploaded_at(build):
        return (build.get("attributes") or {}).get("uploadedDate") or ""

    newest = max(rows, key=uploaded_at)
    attrs = newest.get("attributes") or {}

    version = attrs.get("version") or "?"
    number = attrs.get("buildNumber") or attrs.get("bundleVersion") or "?"
    state = attrs.get("processingState") or "?"
    expires = attrs.get("expirationDate") or "-"

    print(f"build {version} ({number}), state {state}, expires {expires}")

    if state in BAD:
        sys.exit(f"::error::Apple reports the newest build as {state}; "
                 "read the delivery errors in App Store Connect")
    if state not in GOOD:
        # An unknown state is not a pass. Say so rather than printing a cheerful
        # line for something never seen before.
        sys.exit(f"::error::unrecognised processing state {state!r}")

    print(f"{len(rows)} build(s) on record for this app")
    return 0


if __name__ == "__main__":
    sys.exit(main())
