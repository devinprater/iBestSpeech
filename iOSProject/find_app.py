#!/usr/bin/env python3
"""Find an app's numeric App Store Connect ID, from `asc apps list` JSON on stdin.

`asc publish testflight --app` wants the numeric ID, not the bundle identifier,
and the two look nothing alike. Doing the lookup in a script rather than inline
in a workflow means it can be tested against the shapes `asc` really returns.

Prints the ID, or nothing when the app has no record -- the caller treats an
empty result as "make the app by hand", because the API cannot create one.

Usage:
    asc apps list --output json | python3 iOSProject/find_app.py com.example.app
"""

import json
import sys


def find_app(payload, bundle_id):
    """The numeric ID for a bundle identifier, or None."""
    rows = payload.get("data") or []
    for row in rows:
        attrs = row.get("attributes") or {}
        if attrs.get("bundleId") == bundle_id:
            return str(row.get("id") or "")
    return None


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: find_app.py <bundle-id> < asc-apps-list.json")
    bundle_id = sys.argv[1]

    raw = sys.stdin.read()
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        sys.exit(f"could not read `asc` output as JSON: {exc}\n{raw[:500]}")

    found = find_app(payload, bundle_id)
    if not found:
        # Deliberately silent on stdout: the workflow turns this into the
        # "create the app record by hand" message. A message here would become
        # the app ID.
        print("", end="")
        print(f"{bundle_id} is not in the account", file=sys.stderr)
        return 0
    print(found)
    return 0


if __name__ == "__main__":
    sys.exit(main())
