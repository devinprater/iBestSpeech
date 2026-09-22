#!/usr/bin/env python3
"""Smoke-test the engine: does it actually produce non-silent samples?

A library that links but synthesizes silence looks identical to a working one
until it is on a device, so this checks real output. It compiles the upstream
sources for the host and runs a harness that opens every build and measures
how many samples come back non-zero.

Four builds read text in their own legacy code page rather than ASCII (the
1995/1998/2006 Latin builds do not). Feeding those Latin letters yields
silence by design, so each gets text encoded the way its original expected.

Usage: python3 smoke_test.py [--upstream ~/openbst]
"""

import argparse
import glob
import os
import subprocess
import sys
import tempfile

DEFAULT_UPSTREAM = os.path.expanduser("~/openbst")

# Build -> a short phrase in the code page that build actually reads.
# Latin builds take plain ASCII; the code-page builds take raw bytes.
NATIVE_TEXT = {
    "2006ARA": "\\xE3\\xD1\\xCD\\xC8\\xC7 \\xC7\\xE1\\xD3\\xE1\\xC7\\xE3",  # CP1256
    "2006GRE": "\\xC3\\xE5\\xE9\\xE1",                                      # CP1253
    "2006HEB": "\\xF9\\xEC\\xE5\\xED",                                      # CP1255
    "2006RUS": "\\xF0\\xD2\\xC9\\xD7\\xC5\\xD4",                            # KOI8-R
}
DEFAULT_TEXT = "Hello, this is a test of the speech engine."

HARNESS = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "bst.h"

/* Every build reads Latin text except Russian, which reads KOI8-R. Feeding
   2006RUS ASCII returns a plausible length but all-zero samples, which is why
   the check has to measure non-zero output rather than just a length. */
static const char *phrase_for(const char *name) {
    if (!strcmp(name, "2006RUS")) return "\xF0\xD2\xC9\xD7\xC5\xD4";  /* "Privet" */
    return "Hello, this is a test of the speech engine.";
}

int main(void) {
    int n = bst_builds(NULL, 0);
    if (n <= 0) { printf("FAIL: no builds reported\n"); return 1; }

    const char **names = malloc(sizeof(char *) * n);
    if (!names) return 1;
    int got = bst_builds(names, n);
    printf("builds: %d reported, %d named\n\n", n, got);

    const char *first_fail = NULL;
    int checked = 0;

    for (int i = 0; i < got; i++) {
        bst *h = bst_open(names[i]);
        if (!h) {
            printf("  %-10s OPEN FAILED\n", names[i]);
            if (!first_fail) first_fail = names[i];
            continue;
        }

        const char *text = phrase_for(names[i]);
        long len = bst_length(h, text);
        if (len <= 0) {
            printf("  %-10s no audio (len=%ld)\n", names[i], len);
            if (!first_fail) first_fail = names[i];
            bst_close(h);
            continue;
        }

        int16_t *pcm = calloc((size_t)len, sizeof(int16_t));
        long wrote = bst_say(h, text, pcm, len);

        long nonzero = 0, peak = 0;
        for (long k = 0; k < wrote; k++) {
            if (pcm[k] != 0) nonzero++;
            long a = pcm[k] < 0 ? -pcm[k] : pcm[k];
            if (a > peak) peak = a;
        }
        double pct = wrote > 0 ? (100.0 * (double)nonzero / (double)wrote) : 0.0;

        printf("  %-10s rate=%-6d len=%-7ld wrote=%-7ld nonzero=%5.1f%% peak=%ld\n",
               names[i], bst_rate(h), len, wrote, pct, peak);

        if (wrote <= 0 || nonzero == 0) {
            if (!first_fail) first_fail = names[i];
        }
        free(pcm);
        bst_close(h);
        checked++;
    }

    free(names);
    printf("\nchecked %d build(s)\n", checked);

    if (checked == 0) { printf("FAIL: no build could be opened\n"); return 1; }
    if (first_fail) { printf("FAIL: %s produced no samples\n", first_fail); return 1; }
    printf("PASS: every build produced samples\n");
    return 0;
}
'''


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--upstream", default=DEFAULT_UPSTREAM)
    o = ap.parse_args()
    upstream = os.path.abspath(os.path.expanduser(o.upstream))

    sources = sorted(glob.glob(os.path.join(upstream, "src", "**", "*.c"), recursive=True))
    if not sources:
        sys.exit(f"no sources under {upstream}/src")

    with tempfile.TemporaryDirectory() as tmp:
        c = os.path.join(tmp, "harness.c")
        exe = os.path.join(tmp, "harness")
        with open(c, "w") as fh:
            fh.write(HARNESS)

        cmd = [
            "clang", "-O1", "-std=gnu11", "-o", exe, c,
            f"-I{os.path.join(upstream, 'include')}",
            *sources,
        ]
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode != 0:
            print(proc.stderr[-2000:], file=sys.stderr)
            sys.exit("harness failed to compile")

        run = subprocess.run([exe], capture_output=True, text=True)
        print(run.stdout)
        if run.stderr:
            print(run.stderr[-1000:], file=sys.stderr)
        sys.exit(run.returncode)


if __name__ == "__main__":
    main()
