#!/usr/bin/env python3
"""The import path, tested on the host against a table-free engine.

This is the suite that has to pass before a public build ships, because the
import path is the only way a public build can speak at all: with no tables in
the binary, a file the engine cannot identify is a voice the user cannot use.

The method mirrors what the app does, and each part of it is here because it was
measured rather than assumed:

  * an image is reconstructed from each build's own lifted tables, so the tests
    need no original Keynote DLL (see mkimage.c, written to a temp dir below);
  * identification is decided by whether the engine produces SOUND for the file,
    not by whether it opens it -- `bst_open_image` accepts a 2006 English module
    as all thirteen 2006 builds and as 1995, because they share a section layout;
  * "sound" means non-zero samples, because a build handed tables it cannot use
    returns a plausible sample count over an all-zero buffer;
  * the six 1998 modules need their shared core file as well, and are rejected
    outright without it -- that is a distinct, expected outcome, not a failure.

Usage: python3 import_tests.py [--upstream ~/openbst]
"""

import argparse
import glob
import os
import subprocess
import sys
import tempfile

DEFAULT_UPSTREAM = os.path.expanduser("~/openbst")

# Reconstructs a loadable image from a build's lifted tables. Written out here
# rather than kept as a fixture because the fixtures are the Berkeley tables and
# must not be committed.
MKIMAGE = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "bst.h"
#include "bst_text.h"

static void put16(uint8_t *p, size_t o, uint32_t v) {
    p[o] = (uint8_t)(v & 0xFF); p[o+1] = (uint8_t)((v >> 8) & 0xFF);
}
static void put32(uint8_t *p, size_t o, uint32_t v) {
    p[o] = (uint8_t)v; p[o+1] = (uint8_t)(v>>8);
    p[o+2] = (uint8_t)(v>>16); p[o+3] = (uint8_t)(v>>24);
}
int main(int argc, char **argv) {
    if (argc < 3) return 2;
    const bst_lifted *d = bst_lifted_for(argv[1]);
    if (!d) return 1;
    size_t n = 0;
    for (int i = 0; i < d->nsec; i++) {
        size_t e = (size_t)d->sec[i].raw + d->sec[i].rawsize;
        if (e > n) n = e;
    }
    for (int i = 0; i < d->nchunk; i++) {
        size_t e = (size_t)d->chunk[i].off + d->chunk[i].len;
        if (e > n) n = e;
    }
    uint8_t *f = calloc(n, 1);
    if (!f) return 1;
    for (int i = 0; i < d->nchunk; i++)
        memcpy(f + d->chunk[i].off, d->chunk[i].bytes, d->chunk[i].len);
    /* base 0 means the tables came from a 16-bit module. */
    if (d->base == 0) {
        const size_t ne = 0x80, segoff = 0x40;
        put16(f, 0x00, 0x5A4D); put32(f, 0x3C, (uint32_t)ne);
        f[ne] = 'N'; f[ne+1] = 'E';
        put16(f, ne+0x1C, (uint32_t)d->nsec);
        put16(f, ne+0x22, (uint32_t)segoff);
        put16(f, ne+0x32, 9);
        for (int i = 0; i < d->nsec; i++) {
            uint8_t *s = f + ne + segoff + i*8;
            uint32_t at = d->sec[i].raw, len = d->sec[i].vsize;
            if (at + len > n) len = (uint32_t)(n - at);
            int has = 0;
            for (int j = 0; j < d->nchunk; j++)
                if (d->chunk[j].off == at) { has = 1; break; }
            put16(s, 0, has ? (at >> 9) : 0);
            put16(s, 2, has ? len : 0);
            put16(s, 6, has ? len : 0);
        }
    } else {
        const size_t pe = 0x80, optsz = 0xE0, secoff = pe + 24 + optsz;
        put16(f, 0x00, 0x5A4D); put32(f, 0x3C, (uint32_t)pe);
        f[pe] = 'P'; f[pe+1] = 'E';
        put16(f, pe+4, 0x8664);
        put16(f, pe+6, (uint32_t)d->nsec);
        put16(f, pe+20, (uint32_t)optsz);
        put32(f, pe+24+28, d->base);
        for (int i = 0; i < d->nsec; i++) {
            uint8_t *h = f + secoff + i*40;
            put32(h, 8,  d->sec[i].vsize);
            put32(h, 12, d->sec[i].va);
            put32(h, 16, d->sec[i].rawsize);
            put32(h, 20, d->sec[i].raw);
        }
    }
    FILE *g = fopen(argv[2], "wb");
    if (!g) return 1;
    fwrite(f, 1, n, g);
    fclose(g);
    free(f);
    return 0;
}
'''

# Identifies a file the way the app does: try every known build, keep the ones
# that produce sound, report what that means.
IDENTIFY = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "bst.h"

static const char *PROBES[] = { "Hello world", "Read 6- 23 PM", "The quick brown fox" };

static long sound(bst *h) {
    int any = 0;
    for (int p = 0; p < 3; p++) {
        long n = bst_length(h, PROBES[p]);
        if (n <= 0) continue;
        short *pcm = calloc((size_t)n, sizeof(short));
        if (!pcm) continue;
        long got = bst_say(h, PROBES[p], pcm, n);
        for (long i = 0; i < got; i++) if (pcm[i]) { any = 1; break; }
        free(pcm);
    }
    return any;
}

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    FILE *f = fopen(argv[1], "rb");
    if (!f) { printf("unreadable\n"); return 2; }
    fseek(f, 0, SEEK_END); long len = ftell(f); fseek(f, 0, SEEK_SET);
    unsigned char *img = malloc((size_t)len);
    if (!img || fread(img, 1, (size_t)len, f) != (size_t)len) { printf("unreadable\n"); return 2; }
    fclose(f);

    const char *names[64];
    int n = bst_builds(names, 64);
    int spoken = 0; const char *win = "NONE";
    for (int i = 0; i < n; i++) {
        bst *h = bst_open_image(names[i], img, (size_t)len);
        if (!h) continue;
        if (sound(h)) { spoken++; win = names[i]; }
        bst_close(h);
    }
    printf("%s %d %s\n", spoken == 1 ? "one" : (spoken ? "many" : "none"), spoken, win);
    free(img);
    return 0;
}
'''

# Whether the bytes are a 16-bit module, same field bst_image_init_ne reads.
ISNE = r'''
#include <stdio.h>
#include <stdint.h>
int main(int argc, char **argv) {
    if (argc < 2) return 2;
    FILE *f = fopen(argv[1], "rb");
    if (!f) return 2;
    unsigned char b[0x40];
    if (fread(b, 1, sizeof b, f) != sizeof b) { fclose(f); printf("no\n"); return 0; }
    uint32_t o = (uint32_t)b[0x3C] | ((uint32_t)b[0x3D]<<8)
               | ((uint32_t)b[0x3E]<<16) | ((uint32_t)b[0x3F]<<24);
    unsigned char sig[2] = {0, 0};
    /* One open: the first version of this closed the file and then seeked in it,
       which is undefined behaviour and read whatever was there. */
    if (o && fseek(f, (long)o, SEEK_SET) == 0) fread(sig, 1, 2, f);
    fclose(f);
    printf("%s\n", (sig[0] == 'N' && sig[1] == 'E') ? "yes" : "no");
    return 0;
}
'''


# Stand-in for the generated table index, matching iOSProject/Engine/no-tables.c.
# Returning NULL is what makes bst_open() unavailable while leaving
# bst_open_image() -- which reads the caller's own file -- working.
NO_TABLES = r'''
#include <stddef.h>
#include "bst_text.h"
const bst_lifted *bst_lifted_for(const char *build) {
    (void)build;
    return NULL;
}
'''

# The build names, straight from the library. Asking bstspeak instead would
# require a built tool, which a fresh clone does not have.
LIST = r'''
#include <stdio.h>
#include <string.h>
#include "bst.h"
int main(void) {
    const char *names[64];
    int n = bst_builds(names, 64);
    for (int i = 0; i < n; i++) printf("%s%s", i ? " " : "", names[i]);
    printf("\n");
    return 0;
}
'''


def engine_sources(upstream):
    """Every C source of the engine except the lifted table modules.

    Compiled directly rather than linking build/libbst.a, for two reasons: a
    fresh clone has no archive built, and the tables must be left OUT -- this
    test is about a build that ships no voice data, and linking the tables in
    would make identification pass for the wrong reason.
    """
    src_root = os.path.join(upstream, "src")
    table_dir = os.path.join(src_root, "data") + os.sep
    sources = sorted(glob.glob(os.path.join(src_root, "**", "*.c"), recursive=True))
    return [s for s in sources if not s.startswith(table_dir)]


def build(tmp, upstream, name, source, extra_src=None, engine=None, stub=True):
    path = os.path.join(tmp, name + ".c")
    with open(path, "w") as fh:
        fh.write(source)
    srcs = [path] + (extra_src or [])
    out = os.path.join(tmp, name)
    # The stub stands in for the table index, exactly as the public build does.
    # It must NOT be linked when the tables are present -- src/data/lifted.c
    # already defines bst_lifted_for, and two definitions will not link.
    tail = [STUB] if stub else []
    cmd = ["clang", "-O2", "-I", os.path.join(upstream, "include"),
           *srcs, *(engine or []), *tail, "-o", out, "-lm"]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        sys.exit(f"could not build {name}:\n{proc.stderr[:2000]}")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--upstream", default=DEFAULT_UPSTREAM)
    opts = ap.parse_args()
    upstream = os.path.abspath(os.path.expanduser(opts.upstream))

    # Compile the engine from source, without its tables. A prebuilt archive is
    # not required and must not be used: it may have been built with tables, and
    # it may not exist at all on a fresh checkout.
    engine = engine_sources(upstream)
    if not engine:
        sys.exit(f"no sources under {upstream}/src")
    print(f"compiling the engine without tables ({len(engine)} sources)")

    failures = []
    with tempfile.TemporaryDirectory() as tmp:
        # The stub, written once and linked into every probe.
        global STUB
        STUB = os.path.join(tmp, "no-tables.c")
        with open(STUB, "w") as fh:
            fh.write(NO_TABLES)

        # mkimage rebuilds an image from a build's lifted tables, so it needs the
        # tables; the identification probes must NOT have them, or every build
        # would speak from its own compiled-in data and the test would prove
        # nothing. Two separate configurations, deliberately.
        with_tables = sorted(glob.glob(os.path.join(upstream, "src", "**", "*.c"),
                                       recursive=True))
        mkimage = build(tmp, upstream, "mkimage_import", MKIMAGE,
                        engine=with_tables, stub=False)
        identify = build(tmp, upstream, "identify_import", IDENTIFY, engine=engine)
        isne = build(tmp, upstream, "isne_import", ISNE, engine=engine)
        listb = build(tmp, upstream, "list_import", LIST, engine=engine)

        def run(cmd):
            return subprocess.run(cmd, capture_output=True, text=True).stdout.strip()

        # bst_builds(), not `bstspeak --list`: a fresh clone has no built tools.
        builds = run([listb]).split()
        if len(builds) != 20:
            failures.append(f"expected 20 builds, got {len(builds)}")

        print(f"reconstructing an image for each of {len(builds)} builds")
        images = {}
        for b in builds:
            img = os.path.join(tmp, f"{b}.bin")
            if subprocess.run([mkimage, b, img]).returncode != 0:
                failures.append(f"{b}: could not reconstruct an image")
                continue
            images[b] = img

        correct = 0
        needs_core = []
        for b in builds:
            if b not in images:
                continue
            verdict = run([identify, images[b]])
            if not verdict:
                failures.append(f"{b}: identifier printed nothing")
                continue
            kind, count, win = verdict.split()
            is_ne = run([isne, images[b]]) == "yes"

            if is_ne:
                # The 1998 modules cannot speak without their core file. Every
                # one of them is 16-bit and every 16-bit one is a 1998 module,
                # so this is the expected outcome, not a miss.
                if kind == "none":
                    needs_core.append(b)
                else:
                    failures.append(f"{b}: a 16-bit module should not speak alone (got {kind} {win})")
                if not b.startswith("1998"):
                    failures.append(f"{b}: is 16-bit but is not a 1998 build")
            else:
                if kind == "one" and win == b:
                    correct += 1
                elif kind == "none":
                    failures.append(f"{b}: nothing spoke from its own image")
                else:
                    failures.append(f"{b}: resolved to {win} ({kind}), not itself")

        print(f"identified exactly: {correct}")
        print(f"needing their core file: {len(needs_core)} ({', '.join(needs_core) or 'none'})")
        if correct != 14:
            failures.append(f"expected 14 builds to identify exactly, got {correct}")
        if len(needs_core) != 6:
            failures.append(f"expected 6 modules to need their core, got {len(needs_core)}")

        # Junk must resolve to nothing at all. A file the engine cannot use must
        # not be offered as a voice.
        junk = os.path.join(tmp, "junk.bin")
        with open(junk, "wb") as fh:
            fh.write(b"\0" * (1 << 20))
        verdict = run([identify, junk])
        print(f"1 MB of zeros -> {verdict}")
        if not verdict.startswith("none"):
            failures.append("an empty file was identified as an engine file")

        random_file = os.path.join(tmp, "random.bin")
        with open(random_file, "wb") as fh:
            fh.write(os.urandom(400_000))
        verdict = run([identify, random_file])
        print(f"400 KB of random bytes -> {verdict}")
        if not verdict.startswith("none"):
            failures.append("random bytes were identified as an engine file")

        text_file = os.path.join(tmp, "notes.txt")
        with open(text_file, "w") as fh:
            fh.write("This is an ordinary text file, not a speech engine.\n" * 500)
        verdict = run([identify, text_file])
        print(f"a text file -> {verdict}")
        if not verdict.startswith("none"):
            failures.append("a text file was identified as an engine file")

    if failures:
        print()
        for f in failures:
            print(f"FAIL: {f}")
        print(f"\nimport_tests: {len(failures)} failure(s)")
        return 1

    print("\nimport_tests: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
