#!/usr/bin/env swift
//
// Verifies OpenBSTSpeechProvider.buildName(from:), which maps a voice
// identifier back to an engine build.
//
// Worth a permanent check because getting it wrong does not fail loudly: the
// build name simply does not open, synthesizeSpeechRequest returns without
// producing anything, and the voice is silent. A silent voice is
// indistinguishable from a voice with nothing to say, so the bug hides.
//
// Run: swift iOSProject/Tests/VoiceIdentifierTests.swift
//
// The identifier logic is mirrored here rather than imported, because the real
// one lives in the extension target which cannot be linked into a script. Keep
// the two in step; the shapes below are the contract.

import Foundation

let prefix = "com.devin.ibestspeech."

// Mirrors OpenBSTSpeechProvider.buildName(from:)
func buildName(from identifier: String, known: Set<String>) -> String? {
    guard let range = identifier.range(of: prefix, options: .backwards) else { return nil }
    let build = String(identifier[range.upperBound...])
    guard !build.isEmpty, known.contains(build) else { return nil }
    return build
}

let known: Set<String> = ["1995", "1998ENG", "2006ENG", "2006RUS", "2006JPN"]

var failures: [String] = []

func check(_ identifier: String, expect expected: String?, note: String = "") {
    let got = buildName(from: identifier, known: known)
    let ok = got == expected
    if !ok { failures.append("\(identifier): got \(got ?? "nil"), expected \(expected ?? "nil")") }
    let label = note.isEmpty ? "" : "  (\(note))"
    print("\(ok ? "PASS" : "FAIL")  \(identifier)\(label)")
}

// As registered with the system.
check("com.devin.ibestspeech.2006ENG", expect: "2006ENG", note: "as registered")

// How the system actually hands it back: re-prefixed with the extension's
// bundle ID. This is the case the old hasPrefix + dropFirst parse got wrong,
// yielding "provider.com.devin.ibestspeech.2006ENG" and therefore silence.
check("com.devin.ibestspeech.provider.com.devin.ibestspeech.2006ENG",
      expect: "2006ENG", note: "re-prefixed, observed on device")
check("com.devin.ibestspeech.provider.com.devin.ibestspeech.2006RUS",
      expect: "2006RUS", note: "re-prefixed")
check("com.devin.ibestspeech.provider.com.devin.ibestspeech.1995",
      expect: "1995", note: "re-prefixed")

// Must refuse rather than guess: a wrong guess is silence or the wrong language.
check("com.apple.speech.voice.Alex", expect: nil, note: "foreign voice")
check("com.devin.ibestspeech.provider.com.devin.ibestspeech.", expect: nil, note: "empty build")
check("com.devin.ibestspeech.provider.com.devin.ibestspeech.2099", expect: nil, note: "unknown build")
check("", expect: nil, note: "empty identifier")
check("2006ENG", expect: nil, note: "no prefix at all")

print("")
if failures.isEmpty {
    print("all checks passed")
    exit(0)
} else {
    print("\(failures.count) FAILED:")
    for f in failures { print("  \(f)") }
    exit(1)
}
