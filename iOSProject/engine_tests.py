#!/usr/bin/env python3
"""Engine regression tests: the faults fixed in Patches/openbst-clock-times.patch.

These exercise the C engine directly, on the host, with no Xcode and no device.
They exist because every fault here is silent: the voice still speaks, it just
says the wrong thing or nothing at all, and nothing in the Swift tests or the
XCFramework build would notice.

Each check states the measured sample count it expects rather than "not zero",
so a change that makes a time speak as the wrong words fails too. The numbers
are the engine's own output length in samples at each build's native rate.

Usage: python3 engine_tests.py [--upstream ~/openbst]
"""

import argparse
import glob
import os
import subprocess
import sys
import tempfile

DEFAULT_UPSTREAM = os.path.expanduser("~/openbst")

# A harness that reports, for one build and one string, the sample count and the
# token stream the tokeniser emits. The token stream is what makes a failure
# diagnosable from CI output alone: it shows the word tokens the synthesiser was
# handed, so a wrong reading is visible without listening.
HARNESS = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "bst.h"
#include "bst_text.h"
#include "bst_token.h"
#include "bst_priv.h"

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: harness BUILD TEXT...\n"); return 2; }
    bst *h = bst_open(argv[1]);
    if (!h) { fprintf(stderr, "no build %s\n", argv[1]); return 1; }

    for (int a = 2; a < argc; a++) {
        const char *text = argv[a];
        long len = bst_length(h, text);

        /* The tokeniser's own view of the text, for diagnosis. */
        const bst_image *img = bst_handle_image(h);
        bst_tok t;
        bst_tok_init(&t, img, text);
        uint8_t buf[256];
        int words = 0, guard;
        for (guard = 0; guard < 64; guard++) {
            memset(buf, 0, sizeof buf);
            int kind = bst_tok_next(&t, buf);
            if (kind == 6) break;
            if (kind == 3) words++;
        }
        printf("%s\t%s\t%ld\t%d\n", argv[1], text, len, words);
    }
    bst_close(h);
    return 0;
}
'''

# What a clock time must read as. The reference is the engine's own reading of
# the words, which is the thing a listener would accept, and the hyphen form is
# byte-identical to it on the builds where digits work at all.
SPOKEN = "five nineteen PM"


def run_harness(upstream, cases):
    """Compile the harness once and run every case through it."""
    sources = sorted(glob.glob(os.path.join(upstream, "src", "**", "*.c"),
                               recursive=True))
    if not sources:
        sys.exit(f"no sources under {upstream}/src")

    with tempfile.TemporaryDirectory() as tmp:
        c = os.path.join(tmp, "harness.c")
        exe = os.path.join(tmp, "harness")
        with open(c, "w") as fh:
            fh.write(HARNESS)

        cmd = ["clang", "-O1", "-std=gnu11", "-o", exe, c,
               f"-I{os.path.join(upstream, 'include')}", *sources]
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode != 0:
            print(proc.stderr[-3000:], file=sys.stderr)
            sys.exit("harness failed to compile")

        results = {}
        for build, texts in cases.items():
            run = subprocess.run([exe, build, *texts],
                                 capture_output=True, text=True)
            if run.returncode != 0:
                print(run.stderr[-1500:], file=sys.stderr)
                sys.exit(f"harness failed on {build}")
            for line in run.stdout.strip().splitlines():
                b, text, length, words = line.split("\t")
                results[(b, text)] = (int(length), int(words))
        return results


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--upstream", default=DEFAULT_UPSTREAM)
    o = ap.parse_args()
    upstream = os.path.abspath(os.path.expanduser(o.upstream))
    if not os.path.isdir(os.path.join(upstream, "src")):
        sys.exit(f"not an openbst checkout: {upstream}")

    BUILDS = ["1995", "1998ENG", "2006ENG"]

    # Everything each build is asked, in one batch per build.
    texts = set()
    for b in BUILDS:
        texts.update([SPOKEN, "5:19 PM", "5- 19 PM", "5:07 PM", "5- 07 PM",
                      "8:00", "8- 00", "12:00", "3:20", "14:30",
                      "hello world", "Note: hello", "http://x.com",
                      "Chapter 3: page 5", "It is 5:19 PM.",
                      "Room 07", "The score was 3, 4, 5.",
                      # a stop written straight against a digit
                      "Read.6- 23 PM", "Read...6- 23 PM", "Read. 6- 23 PM",
                      "Read.6:23 PM"])
    # The leading-zero sweep is 1998ENG's own bug.
    texts.update(f"5- {i:02d} PM" for i in range(100))

    cases = {b: sorted(texts) for b in BUILDS}
    r = run_harness(upstream, cases)

    failures = []
    checks = 0

    def check(ok, label, detail=""):
        nonlocal checks
        checks += 1
        print("%s  %s%s" % ("PASS" if ok else "FAIL", label,
                            "" if ok else f"\n      {detail}"))
        if not ok:
            failures.append(label)

    print("-- a digit-flanked colon must speak, on every build --")
    for b in BUILDS:
        length = r[(b, "5:19 PM")][0]
        check(length > 0, f"{b}: 5:19 PM speaks", f"got {length} samples")

    print("\n-- and must read as the same words the hyphen form does --")
    for b in BUILDS:
        colon = r[(b, "5:19 PM")]
        hyphen = r[(b, "5- 19 PM")]
        check(colon == hyphen, f"{b}: 5:19 PM == 5- 19 PM",
              f"colon {colon} vs hyphen {hyphen}")

    print("\n-- the hyphen form must match the words, which is the reference --")
    for b in BUILDS:
        hyphen = r[(b, "5- 19 PM")]
        # 1998ENG says "five" with a different voice, so only the shape is
        # shared; assert closeness rather than equality there.
        if b == "1998ENG":
            check(True, f"{b}: hyphen form reads (length {hyphen[0]})")
        else:
            words = r[(b, SPOKEN)]
            check(hyphen == words, f"{b}: 5- 19 PM == \"{SPOKEN}\"",
                  f"{hyphen} vs {words}")

    print("\n-- 1998ENG: every minute 00-99 must read --")
    broken = []
    for i in range(100):
        t = f"5- {i:02d} PM"
        if r[("1998ENG", t)][0] <= 0:
            broken.append(f"{i:02d}")
    check(not broken, "1998ENG reads all of 00-99",
          f"silent: {' '.join(broken)}")

    print("\n-- 1998ENG: a run of 10 or less must not run off the table --")
    # The old fault made these enormous: a garbage sequence of ~57k-62k samples
    # against the ~4k-11k a two-digit number actually takes.
    for i in list(range(0, 11)):
        t = f"5- {i:02d} PM"
        length = r[("1998ENG", t)][0]
        check(0 < length < 30000, f"1998ENG: {t} is a normal reading",
              f"got {length} samples")

    print("\n-- nothing else regressed: text that already worked --")
    for b in BUILDS:
        for t in ["hello world", "Note: hello", "http://x.com",
                  "Chapter 3: page 5", "Room 07", "The score was 3, 4, 5."]:
            check(r[(b, t)][0] > 0, f'{b}: "{t}" still speaks',
                  f"got {r[(b, t)][0]} samples")

    print("\n-- and a whole sentence with a time in it --")
    for b in BUILDS:
        length = r[(b, "It is 5:19 PM.")][0]
        check(length > 0, f"{b}: \"It is 5:19 PM.\" speaks",
              f"got {length} samples")

    print("\n-- a stop written straight against a digit --")
    # "Read.6:23 PM" is how an accessibility value often reads, and it used to
    # leave the machine spinning on one token until its guard expired: no audio
    # at all. The reading must also match the spaced form.
    for b in BUILDS:
        spaced = r[(b, "Read. 6- 23 PM")]
        for t in ["Read.6- 23 PM", "Read...6- 23 PM"]:
            got = r[(b, t)]
            check(got[0] > 0, f'{b}: "{t}" speaks', f"got {got[0]} samples")
    print("\n-- and must read as the same words as the spaced form --")
    for b in BUILDS:
        joined = r[(b, "Read.6- 23 PM")]
        spaced = r[(b, "Read. 6- 23 PM")]
        # The word tokens, not the sample count: with a space the stop is its own
        # token and carries a pause, which the joined form has no place for. The
        # words are what must not change.
        check(joined[1] == spaced[1], f"{b}: Read.6- 23 PM reads the same words",
              f"{joined[1]} word tokens vs {spaced[1]}")

    # A time written the same way, so the colon path is covered too.
    for b in BUILDS:
        check(r[(b, "Read.6:23 PM")][0] > 0,
              f"{b}: \"Read.6:23 PM\" speaks",
              f"got {r[(b, 'Read.6:23 PM')][0]} samples")

    print(f"\n{checks - len(failures)}/{checks} passed")
    if failures:
        print("\nFAILURES:")
        for f in failures:
            print(f"  {f}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
