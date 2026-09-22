import Foundation

/// Checks SSMLText against the shapes the system actually sends.
///
/// Compiled together with `Shared/SSMLText.swift` rather than mirroring it, so
/// this exercises the shipping code and cannot drift out of step with it.
///
/// Run:
///   swiftc -parse-as-library \
///     iOSProject/Shared/SSMLText.swift \
///     iOSProject/Tests/SSMLTextTests.swift \
///     -o /tmp/ssmltests && /tmp/ssmltests
///
/// Worth testing because every failure here is silent: nothing errors, the voice
/// still speaks, it just says the wrong thing. A tag deleted rather than
/// replaced with a space joins the words around it, and a decoded-looking entity
/// passes markup through to an engine that reads bytes.

@main
struct SSMLTextTests {

    static var failures: [String] = []
    static var checks = 0

    static func expect(_ ssml: String, _ expected: String, _ label: String) {
        checks += 1
        let got = SSMLText.plainText(from: ssml)
        if got != expected {
            failures.append("\(label)\n      ssml:     \(ssml)\n      got:      \"\(got)\"\n      expected: \"\(expected)\"")
            print("FAIL  \(label)")
        } else {
            print("PASS  \(label)")
        }
    }

    static func main() {
        print("-- the reported bug: a tag between two words must leave a space --")
        expect(#"<speak>iBestSpeech<break time="100ms"/>recently updated</speak>"#,
               "iBestSpeech recently updated",
               "break between words keeps them separate")

        // Stripping tags to "" rather than " " produced exactly this:
        // "iBestSpeechrecently" — one nonsense word.
        expect(#"<speak>iBestSpeech<break time="100ms"/>recently</speak>"#,
               "iBestSpeech recently",
               "the exact failing case")

        print("\n-- shapes the system sends --")
        expect(#"<speak><prosody rate="50%">Hello</prosody> <prosody pitch="+10%">world</prosody></speak>"#,
               "Hello world",
               "prosody elements")
        expect(#"<speak>Hello<mark name="x"/> world</speak>"#,
               "Hello world",
               "mark element")
        expect("<speak>Normal <emphasis level=\"strong\">bold</emphasis> text</speak>",
               "Normal bold text",
               "emphasis element")
        expect(#"<speak><voice name="x">Words</voice></speak>"#,
               "Words",
               "voice element")
        expect(#"<speak><prosody rate="80%">A sentence.</prosody></speak>"#,
               "A sentence.",
               "rate attribute")

        print("\n-- entities must be resolved, not passed through --")
        expect("Hello&#160;world", "Hello world", "non-breaking space (decimal)")
        expect("Hello&#xA0;world", "Hello world", "non-breaking space (hex)")
        expect("Hello&nbsp;world", "Hello world", "&nbsp;")
        expect("Tom &amp; Jerry", "Tom & Jerry", "&amp;")
        expect("1 &lt; 2", "1 < 2", "&lt;")
        expect("3 &gt; 2", "3 > 2", "&gt;")
        expect("&#x41;&#x42;", "AB", "hex character references")
        expect("&#65;&#66;", "AB", "decimal character references")
        expect("&#x1F600;", "😀", "code point above the BMP does not crash")

        print("\n-- typographic characters folded for a single-byte engine --")
        expect("&ldquo;quoted&rdquo;", "\"quoted\"", "curly double quotes")
        expect("&lsquo;single&rsquo;", "'single'", "curly single quotes")
        expect("a&mdash;b", "a-b", "em dash")
        expect("a&ndash;b", "a-b", "en dash")

        print("\n-- markup that is not text --")
        expect("<!-- a comment -->Hello", "Hello", "comment")
        expect("<!-- a > b -->Hello", "Hello", "comment containing an angle bracket")
        expect(#"<sub alias="World Health Organization">WHO</sub>"#,
               "World Health Organization",
               "sub speaks the alias, not the abbreviation")
        expect("<speak>  spaced   out  </speak>", "spaced out", "whitespace collapsed")
        expect("Hello , world", "Hello, world", "no gap before punctuation")

        print("\n-- plain text must pass through untouched --")
        expect("Just words.", "Just words.", "no markup at all")
        expect("", "", "empty")
        expect("The quick brown fox jumps over the lazy dog.",
               "The quick brown fox jumps over the lazy dog.",
               "a plain sentence")

        print("\n-- pitch and rate --")
        checks += 1
        let params = SSMLText.speechParameters(
            from: #"<speak><prosody pitch="+15%" rate="70%">x</prosody></speak>"#)
        if params.pitch == 15 && params.rate == 70 {
            print("PASS  pitch and rate read")
        } else {
            failures.append("pitch/rate: got \(params)")
            print("FAIL  pitch and rate read (got \(params))")
        }

        checks += 1
        let none = SSMLText.speechParameters(from: "<speak>plain</speak>")
        if none.pitch == nil && none.rate == nil {
            print("PASS  absent pitch and rate stay nil")
        } else {
            failures.append("absent pitch/rate: got \(none)")
            print("FAIL  absent pitch and rate stay nil")
        }

        print("\n\(checks - failures.count)/\(checks) passed")
        if failures.isEmpty {
            exit(0)
        }
        print("\nFAILURES:")
        for failure in failures { print("  \(failure)") }
        exit(1)
    }
}
