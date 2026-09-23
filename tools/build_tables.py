#!/usr/bin/env python3
"""Generate the Swift substitution tables for the iBestSpeech text layer.

Two tables, both checked in as Swift so the extension has no runtime file
dependency and nothing to bundle:

  CLDRText.swift       the CLDR emoji/character annotations, per language
  Pronunciations.swift the hand-checked modern-term dictionary

The CLDR half mirrors what NVDA does (PR #8758): take the Unicode Common Locale
Data Repository `annotations` + `annotationsDerived` files and speak the `tts`
annotation for each character. NVDA builds `cldr.dic` per locale with scons;
this generates Swift source per language instead, for the same reason.

Two things the raw CLDR data cannot be used for as-is, both measured against the
built engine:

  * **The descriptions carry `:` and `,`.** A colon is safe (it becomes a pause);
    a comma **ends the text on every 2006 build**, and it is the *description*
    that gets spoken, so "family: man, woman, girl" would say "family" and
    stop. Both are stripped here.
  * **The engine is single-byte.** Anything outside ASCII reaches it as a code
    page glyph and is spliced onto the word before it. Only the ASCII of a
    description is kept.

Usage:
    python3 tools/build_tables.py            # regenerate the Swift tables
    python3 tools/build_tables.py --check    # report entries the engine already
                                             # says correctly, i.e. wasted ones
"""

import argparse
import re
import sys
import unicodedata
import urllib.request
from pathlib import Path

# The locales each build maps to. VoiceCatalog.swift owns this mapping; keep the
# two in step. The key is what appears in the generated Swift.
LOCALES = {
    "en": "en",   # 1995, 1998ENG, 2006ENG
    "de": "de",   # 1998GRM, 2006GER
    "fr": "fr",   # 1998FRN, 2006FRE
    "es": "es",   # 1998SPN, 2006SPA
    "it": "it",   # 1998ITL, 2006ITA
    "nl": "nl",   # 1998DUT, 2006DUT
    "pt": "pt",   # 2006POR
    "pl": "pl",   # 2006POL
    "ru": "ru",   # 2006RUS
    "ar": "ar",   # 2006ARA
    "he": "he",   # 2006HEB
    "el": "el",   # 2006GRE
    "ja": "ja",   # 2006JPN
}

CLDR_BASE = ("https://raw.githubusercontent.com/fujiwarat/"
             "cldr-emoji-annotation/master")
CACHE = Path.home() / "cldr"

REPO = Path(__file__).resolve().parent.parent
SWIFT_OUT = REPO / "iOSProject" / "Shared"


# ---------------------------------------------------------------- CLDR

ANNOTATION = re.compile(r'<annotation cp="([^"]*)"([^>]*)>([^<]*)</annotation>')
IS_TTS = re.compile(r'type="tts"')


def fetch(locale, kind):
    """The annotations file for a locale, cached under ~/cldr."""
    CACHE.mkdir(exist_ok=True)
    dest = CACHE / ("%s_%s.xml" % (kind, locale))
    if not dest.exists():
        url = "%s/%s/%s.xml" % (CLDR_BASE, kind, locale)
        with urllib.request.urlopen(url, timeout=60) as r:
            dest.write_bytes(r.read())
    return dest.read_text(encoding="utf-8")


# The cp attribute is XML-escaped in the source, so "&lt;" arrives as that
# name. Only a handful are affected and all are ASCII, but decoding them keeps
# the table honest about what it holds.
XML_ENTITIES = {
    "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": '"', "&apos;": "'",
}


def unescape_cp(cp):
    for name, ch in XML_ENTITIES.items():
        cp = cp.replace(name, ch)
    return cp


def annotations(locale):
    """cp -> the tts description, derived winning over base.

    The base file carries the short form and the derived file the more specific
    one for the same character, so loading base first and letting derived
    overwrite is what produces "thumbs up: medium skin tone" rather than
    "thumbs up".

    A cp that is entirely ASCII is dropped. CLDR annotates 30 punctuation
    characters as well -- `!`, `,`, `.`, `:`, `~` and so on -- and those are
    characters the engine already reads. Substituting them would rewrite the
    punctuation of ordinary text ("hello, world" -> "hello comma world"). NVDA
    draws the same line: its punctuation symbols are spoken only at the highest
    symbol level, while emoji speak at every level (#9707). What is left here is
    exactly the set the engine cannot read at all.
    """
    out = {}
    for kind in ("annotations", "annotationsDerived"):
        for m in ANNOTATION.finditer(fetch(locale, kind)):
            cp, attrs, text = m.group(1), m.group(2), m.group(3)
            if not IS_TTS.search(attrs) or not cp or not text:
                continue
            cp = unescape_cp(cp)
            if cp.isascii():
                continue
            out[cp] = text
    return out


def sanitise(text):
    """What the engine can actually be handed.

    Strip the punctuation the engine mishandles, keep ASCII, and collapse the
    spaces that leaves. Returns "" when nothing usable remains, which is the
    signal to skip the entry rather than emit an empty substitution.
    """
    # A colon is a safe pause and reads well ("flag: United States"), but a
    # comma ends the text on the 2006 builds -- and this text is the utterance.
    text = text.replace(",", "").replace(";", "")
    text = text.replace(":", "").replace("(", "").replace(")", "")
    text = text.replace("&", "and").replace("’", "'").replace("“", '"')
    text = text.replace("”", '"').replace("!", "")
    # Keep only what the single-byte engine can read.
    text = "".join(ch for ch in text if ch.isascii())
    text = re.sub(r"\s+", " ", text).strip()
    return text


def build_cldr():
    """cp -> description, for every locale, sanitised."""
    tables = {}
    for locale in LOCALES:
        entries = {}
        for cp, text in annotations(locale).items():
            clean = sanitise(text)
            if clean:
                entries[cp] = clean
        tables[locale] = entries
        print("  %-4s %5d entries" % (locale, len(entries)))
    return tables


# ---------------------------------------------------------------- Swift

def swift_literal(s):
    """A Swift string literal that survives every character we emit."""
    out = []
    for ch in s:
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\t":
            out.append("\\t")
        elif 0x20 <= ord(ch) < 0x7F:
            out.append(ch)
        else:
            # Anything non-ASCII: escape as \u{...} so the source stays ASCII and
            # the generated file is diffable.
            out.append("\\u{%X}" % ord(ch))
    return '"' + "".join(out) + '"'


def emit_cldr(tables, path):
    lines = []
    lines.append("// Generated by tools/build_tables.py -- do not edit by hand.")
    lines.append("//")
    lines.append("// Emoji and character descriptions from the Unicode Common Locale")
    lines.append("// Data Repository, the same source and the same `tts` annotation NVDA")
    lines.append("// turns into its cldr.dic symbol dictionaries (nvaccess/nvda#8758).")
    lines.append("//")
    lines.append("// Regenerate with `python3 tools/build_tables.py`. The data is the")
    lines.append("// fujiwarat/cldr-emoji-annotation mirror, which is what NVDA vendors.")
    lines.append("//")
    lines.append("// The descriptions are sanitised for this engine: CLDR writes them with")
    lines.append("// ':' and ',' (2,784 of the entries carry one), a comma ends the text")
    lines.append("// on every 2006 build, and this string is what gets spoken. Non-ASCII is")
    lines.append("// dropped for the same reason -- the engine reads one byte per")
    lines.append("// character, so a multi-byte character is spliced onto the word before")
    lines.append("// it.")
    lines.append("")
    lines.append("import Foundation")
    lines.append("")
    lines.append("/// Character and emoji descriptions, by language.")
    lines.append("enum CLDRText {")
    lines.append("    /// The description for `character` in `language`.")
    lines.append("    ///")
    lines.append("    /// Falls back to English **per character**, not per table. The engine")
    lines.append("    /// reads one byte per character, so a locale whose descriptions are")
    lines.append("    /// written in its own script keeps only the few entries that happen to")
    lines.append("    /// be ASCII -- Arabic keeps 49 of 3900. A whole-table fallback would")
    lines.append("    /// discard that locale's own entries; this keeps them and fills only")
    lines.append("    /// the gaps from English, so every character has a description.")
    lines.append("    static func description(for character: Character,")
    lines.append("                            language: String) -> String? {")
    lines.append("        // Only the language subtag is used: a build declares \"pt-PT\" and")
    lines.append("        // the data has no per-region split worth carrying.")
    lines.append("        let base = language.split(separator: \"-\").first.map(String.init)")
    lines.append("            ?? language")
    lines.append("        if base != \"en\", let localized = tables[base]?[character] {")
    lines.append("            return localized")
    lines.append("        }")
    lines.append("        return tables[\"en\"]?[character]")
    lines.append("    }")
    lines.append("")
    lines.append("    private static let tables: [String: [Character: String]] = [")
    for locale in sorted(tables):
        entries = tables[locale]
        lines.append("        %s: [" % swift_literal(locale))
        for cp in sorted(entries):
            key = swift_literal(cp)
            val = swift_literal(entries[cp])
            lines.append("            %s: %s," % (key, val))
        lines.append("        ],")
    lines.append("    ]")
    lines.append("}")
    lines.append("")
    path.write_text("\n".join(lines), encoding="utf-8")
    print("  wrote %s (%d lines, %d locales)"
          % (path.name, len(lines), len(tables)))


def load_dictionary():
    """The hand-checked dictionary: a list of (term, replacement)."""
    src = REPO / "tools" / "dictionary.txt"
    entries = []
    for line in src.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "\t" not in line:
            sys.exit("dictionary.txt: no tab in %r" % line)
        term, replacement = line.split("\t", 1)
        entries.append((term.strip(), replacement.strip()))
    return entries


def emit_pronunciations(entries, path):
    lines = []
    lines.append("// Generated by tools/build_tables.py -- do not edit by hand.")
    lines.append("//")
    lines.append("// The source is tools/dictionary.txt; edit that and regenerate.")
    lines.append("//")
    lines.append("// Every entry is here because the engine gets the term wrong. It reads")
    lines.append("// an unknown compound as one word, so \"FaceTime\" comes out as")
    lines.append("// \"facetime\" -- its token stream is identical to the lowercase form --")
    lines.append("// rather than \"face time\". Measured against the built library, not")
    lines.append("// assumed; `python3 tools/build_tables.py --check` lists entries the")
    lines.append("// engine already says correctly.")
    lines.append("//")
    lines.append("// Matching is case-sensitive and whole-word on purpose. A case-blind")
    lines.append("// match would rewrite the \"ai\" inside a French word to \"ay eye\";")
    lines.append("// whole-word keeps \"AI\" fixed and leaves the French alone.")
    lines.append("")
    lines.append("import Foundation")
    lines.append("")
    lines.append("/// Replacements for terms the engine mispronounces.")
    lines.append("enum Pronunciations {")
    lines.append("    /// Longest first, so \"iPadOS\" is matched before \"iPad\".")
    lines.append("    static let ordered: [(String, String)] = [")
    for term, replacement in sorted(entries, key=lambda kv: -len(kv[0])):
        lines.append("        (%s, %s)," % (swift_literal(term), swift_literal(replacement)))
    lines.append("    ]")
    lines.append("}")
    lines.append("")
    path.write_text("\n".join(lines), encoding="utf-8")
    print("  wrote %s (%d entries)" % (path.name, len(entries)))


# ---------------------------------------------------------------- check

def check(entries):
    """Report dictionary entries that are not doing anything.

    An entry whose term the engine already reads as its replacement is wasted --
    the point of the dictionary is terms the engine gets WRONG, and every entry
    costs a lookup on every utterance. An entry whose replacement is silent is
    worse than useless: it trades a mispronunciation for no sound at all.

    Every English build is checked, not just one. 1995, 1998ENG and 2006ENG have
    their own lexicons, so an entry can be wasted on one and doing real work on
    another; only an entry wasted on all of them is removed.
    """
    import subprocess
    tree = Path.home() / "fixv4"
    if not (tree / "readlines").exists():
        sys.exit("no harness at %s/readlines; build it first" % tree)

    builds = ["1995", "1998ENG", "2006ENG"]

    def stream(build, text):
        out = subprocess.run(["./readlines", build], input=text + "\n",
                             cwd=tree, capture_output=True, text=True).stdout
        return [ln.strip() for ln in out.splitlines() if "tok 3:" in ln]

    wasted_all, wasted_some, broken, ok = [], [], [], 0
    for term, replacement in entries:
        same = {b: stream(b, term) == stream(b, replacement) for b in builds}
        silent = [b for b in builds if not stream(b, replacement)]
        if silent:
            broken.append((term, replacement, silent))
        elif all(same.values()):
            wasted_all.append((term, replacement))
        elif any(same.values()):
            wasted_some.append((term, replacement,
                                [b for b in builds if same[b]]))
        else:
            ok += 1

    print()
    print("dictionary check (%s):" % ", ".join(builds))
    print("  %d entries change the reading on every build" % ok)
    print("  %d wasted on every build -- remove these" % len(wasted_all))
    for term, repl in wasted_all:
        print("      %-16s already reads as %r" % (term, repl))
    print("  %d wasted on some build, working on another -- keep" % len(wasted_some))
    for term, repl, on in wasted_some:
        print("      %-16s -> %-18r already right on %s" % (term, repl, ", ".join(on)))
    print("  %d replacements are silent -- broken" % len(broken))
    for term, repl, on in broken:
        print("      %-16s -> %-18r SILENT on %s" % (term, repl, ", ".join(on)))
    return 1 if broken else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="report dictionary entries the engine already says right")
    o = ap.parse_args()

    entries = load_dictionary()
    if o.check:
        return check(entries)

    print("CLDR annotations:")
    tables = build_cldr()
    if "en" not in tables or not tables["en"]:
        sys.exit("no English CLDR data; nothing to write")

    print("Swift:")
    emit_cldr(tables, SWIFT_OUT / "CLDRText.swift")
    emit_pronunciations(entries, SWIFT_OUT / "Pronunciations.swift")

    total = sum(len(v) for v in tables.values())
    print()
    print("  %d entries across %d locales; %d dictionary terms"
          % (total, len(tables), len(entries)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
