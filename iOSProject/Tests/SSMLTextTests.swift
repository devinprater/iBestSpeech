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
/// still speaks, it just says the wrong thing or nothing at all.

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

    static func expectInt(_ got: Int?, _ expected: Int?, _ label: String) {
        checks += 1
        if got == expected {
            print("PASS  \(label)")
        } else {
            failures.append("\(label): got \(got.map(String.init) ?? "nil"), expected \(expected.map(String.init) ?? "nil")")
            print("FAIL  \(label)  (got \(got.map(String.init) ?? "nil"), expected \(expected.map(String.init) ?? "nil"))")
        }
    }

    static func expectPause(_ ssml: String, _ expected: Double, _ label: String) {
        checks += 1
        let got = SSMLText.parse(ssml).totalPause
        if abs(got - expected) < 0.001 {
            print("PASS  \(label)")
        } else {
            failures.append("\(label): got \(got), expected \(expected)")
            print("FAIL  \(label)  (got \(got), expected \(expected))")
        }
    }

    static func main() {
        print("-- the reported bug: a tag between two words must leave a space --")
        expect(#"<speak>iBestSpeech<break time="100ms"/>recently updated</speak>"#,
               "iBestSpeech recently updated",
               "break between words keeps them separate")
        expect(#"<speak>iBestSpeech<break time="100ms"/>recently</speak>"#,
               "iBestSpeech recently",
               "the exact failing case")

        print("\n-- the silence bug: adjacent numbers produce no audio at all --")
        // A colon, not a comma: a comma ends the text on every 2006 build, so
        // the words after the number were never spoken.
        expect("<speak>555 1234</speak>", "555: 1234", "two numbers are separated")
        expect("<speak>10 20 30</speak>", "10: 20: 30", "a run of numbers is separated")
        expect("<speak>The score was 3 4 5.</speak>", "The score was 3: 4: 5.",
               "numbers inside a sentence")
        expect("<speak>Room 101 202</speak>", "Room 101: 202", "numbers after a word")
        expect("<speak>Version 2 0 2 6</speak>", "Version 2: 0: 2: 6", "version digits")
        expect("<speak>Call 555.</speak>", "Call 555.", "a lone number is untouched")
        expect("<speak>555-1234</speak>", "555-1234", "a hyphenated number is untouched")
        expect("<speak>The year 1995 was a long time ago.</speak>",
               "The year 1995 was a long time ago.", "an isolated year is untouched")

        print("\n-- elements Apple and the W3C reference define --")
        expect(#"<speak><prosody rate="50%">Hello</prosody> <prosody pitch="+10%">world</prosody></speak>"#,
               "Hello world", "prosody elements")
        expect(#"<speak>Hello<mark name="x"/> world</speak>"#, "Hello world", "mark element")
        expect("<speak>Normal <emphasis level=\"strong\">bold</emphasis> text</speak>",
               "Normal bold text", "emphasis element")
        expect(#"<speak><voice name="x">Words</voice></speak>"#, "Words", "voice element")
        expect("<speak><p>First</p><s>Second</s></speak>", "First Second", "p and s elements")
        expect("<speak><lang xml:lang=\"fr\">Bonjour</lang></speak>", "Bonjour", "lang element")
        expect("<speak>Hi <w>there</w> you</speak>", "Hi there you", "w element")
        expect("<speak><prosody rate=\"80%\">A sentence.</prosody></speak>",
               "A sentence.", "rate attribute")

        print("\n-- pause elements become silence, not text --")
        expectPause(#"<speak>a<break time="1s"/>b</speak>"#, 1.0, "time in seconds")
        expectPause(#"<speak>a<break time="500ms"/>b</speak>"#, 0.5, "time in milliseconds")
        expectPause(#"<speak>a<break time="1.5s"/>b</speak>"#, 1.5, "fractional seconds")
        expectPause(#"<speak>a<break time="250"/>b</speak>"#, 0.25, "bare number is milliseconds")
        expectPause(#"<speak>a<break strength="strong"/>b</speak>"#, 0.5, "strength strong")
        expectPause(#"<speak>a<break strength="none"/>b</speak>"#, 0.0, "strength none")
        expectPause(#"<speak>a<break strength="x-weak"/>b</speak>"#, 0.05, "strength x-weak")
        expectPause(#"<speak>a<break/>b</speak>"#, 0.25, "no attribute uses the SSML default")
        // A malformed time must not stall the speech queue.
        checks += 1
        let huge = SSMLText.parse(#"<speak><break time="9999s"/>x</speak>"#).totalPause
        if huge <= 10 { print("PASS  an absurd break time is capped  (\(huge)s)") }
        else { failures.append("break cap: got \(huge)"); print("FAIL  an absurd break time is capped") }

        print("\n-- markers come back in order --")
        checks += 1
        let marked = SSMLText.parse(#"<speak>a<mark name="one"/>b<mark name="two"/>c</speak>"#)
        if marked.bookmarks == ["one", "two"] { print("PASS  bookmarks in order") }
        else {
            failures.append("bookmarks: got \(marked.bookmarks)")
            print("FAIL  bookmarks in order  (got \(marked.bookmarks))")
        }

        print("\n-- per-piece prosody: one value cannot describe a whole utterance --")
        checks += 1
        let twoPieces = SSMLText.parse(
            #"<speak><prosody rate="25%">slow</prosody> then <prosody rate="75%">quick</prosody></speak>"#)
        let rates: [Int] = twoPieces.pieces.compactMap { piece in
            if case .speech(_, _, let rate, _) = piece { return rate }
            return nil
        }
        // 25% and 75% of normal sit either side of neutral 50, spread by the half
        // factor that keeps SSML's wider range inside the engine's usable band.
        if rates == [13, 38] { print("PASS  each piece keeps its own rate  (\(rates))") }
        else {
            failures.append("per-piece rate: got \(rates), expected [13, 38]")
            print("FAIL  each piece keeps its own rate  (got \(rates), expected [13, 38])")
        }

        print("\n-- prosody values map onto VoiceOver's scale --")
        expectInt(SSMLText.parse(#"<speak><prosody pitch="x-low">a</prosody></speak>"#).firstPitch,
                  15, "pitch x-low")
        expectInt(SSMLText.parse(#"<speak><prosody pitch="high">a</prosody></speak>"#).firstPitch,
                  75, "pitch high")
        expectInt(SSMLText.parse(#"<speak><prosody pitch="+20%">a</prosody></speak>"#).firstPitch,
                  70, "relative pitch")
        expectInt(SSMLText.parse(#"<speak><prosody rate="x-slow">a</prosody></speak>"#).firstRate,
                  10, "rate x-slow")
        expectInt(SSMLText.parse(#"<speak><prosody rate="100%">a</prosody></speak>"#).firstRate,
                  50, "rate 100% is neutral")
        expectInt(SSMLText.parse(#"<speak><prosody rate="200%">a</prosody></speak>"#).firstRate,
                  100, "rate 200% is faster")
        expectInt(SSMLText.parse(#"<speak><prosody rate="50%">a</prosody></speak>"#).firstRate,
                  25, "rate 50% is slower")
        // Volume is read, and an absent one stays nil rather than defaulting to 0.
        expectInt(SSMLText.parse(#"<speak>plain</speak>"#).firstRate, nil, "absent rate stays nil")

        print("\n-- say-as --")
        // Letters already read as names when space separated, so they stay that
        // way — measured at 1.6s for "H E L L O" against 1.0s for "Hello".
        expect(#"<speak><say-as interpret-as="characters">HELLO</say-as></speak>"#,
               "H E L L O", "characters are separated so the engine spells them")
        // Digits are different: space separated they produce no audio at all, so
        // the comma that separates adjacent numbers is what makes them speakable.
        expect(#"<speak><say-as interpret-as="digits">123</say-as></speak>"#,
               "1: 2: 3", "digits are separated")
        // The engine normalizes numbers, dates and currency itself, so these pass
        // through unchanged rather than being mangled by an approximation.
        expect(#"<speak><say-as interpret-as="date">2026-09-22</say-as></speak>"#,
               "2026-09-22", "date is left to the engine")
        expect(#"<speak><say-as interpret-as="number">42</say-as></speak>"#,
               "42", "number is left to the engine")

        print("\n-- phoneme and lexicon --")
        expect(#"<speak><phoneme alphabet="ipa" ph="təˈmeɪtoʊ">tomato</phoneme></speak>"#,
               "tomato", "phoneme speaks its text content, not the phonemes")
        expect(#"<speak><lexicon uri="x.lex"/>Hello</speak>"#, "Hello", "lexicon is skipped")

        print("\n-- entities must be resolved, not passed through --")
        expect("Hello&#160;world", "Hello world", "non-breaking space (decimal)")
        expect("Hello&#xA0;world", "Hello world", "non-breaking space (hex)")
        expect("Hello&nbsp;world", "Hello world", "&nbsp;")
        expect("Tom &amp; Jerry", "Tom & Jerry", "&amp;")
        expect("1 &lt; 2", "1 < 2", "&lt;")
        expect("3 &gt; 2", "3 > 2", "&gt;")
        expect("&#x41;&#x42;", "AB", "hex character references")
        expect("&#65;&#66;", "AB", "decimal character references")
        // A code point above the BMP must survive the entity decode as one
        // character rather than being split into surrogate halves. What comes
        // out is its description: the engine cannot read the character itself.
        expect("&#x1F600;", "grinning face", "code point above the BMP is described")

        print("\n-- typographic characters folded for a single-byte engine --")
        expect("&ldquo;quoted&rdquo;", "\"quoted\"", "curly double quotes")
        expect("&lsquo;single&rsquo;", "'single'", "curly single quotes")
        expect("a&mdash;b", "a-b", "em dash")
        expect("a&ndash;b", "a-b", "en dash")

        print("\n-- invisible characters the system wraps values in --")
        // iOS wraps an accessibility value in bidi marks. To the engine those
        // are code-page glyphs, so one of them turns "Read" into "Read" plus a
        // stray sound — the "oz" heard in Messages — and a soft hyphen or a
        // byte order mark makes the whole utterance silent.
        expect("<speak>\u{200e}Read 6:23 PM</speak>", "Read 6- 23 PM",
               "left-to-right mark before a word")
        expect("<speak>\u{200f}Read 6:23 PM</speak>", "Read 6- 23 PM",
               "right-to-left mark before a word")
        expect("<speak>\u{2068}Read 6:23 PM</speak>", "Read 6- 23 PM",
               "first-strong isolate, which is what iOS prefers")
        expect("<speak>\u{2068}Read 6:23 PM\u{2069}</speak>", "Read 6- 23 PM",
               "a matched isolate pair")
        expect("<speak>\u{202a}Read 6:23 PM\u{202c}</speak>", "Read 6- 23 PM",
               "an embedding control")
        expect("<speak>Read\u{200b} 6:23 PM</speak>", "Read 6- 23 PM",
               "zero width space")
        expect("<speak>\u{feff}Read 6:23 PM</speak>", "Read 6- 23 PM",
               "byte order mark")
        expect("<speak>Read\u{00ad} 6:23 PM</speak>", "Read 6- 23 PM",
               "soft hyphen")
        expect("<speak>Read\u{2060} 6:23 PM</speak>", "Read 6- 23 PM",
               "word joiner")
        expect("<speak>\u{201c}Read 6:23 PM\u{201d}</speak>", "\"Read 6- 23 PM\"",
               "literal curly double quotes")
        expect("<speak>\u{2019}Read 6:23 PM</speak>", "'Read 6- 23 PM",
               "literal curly apostrophe, as autocorrect writes it")
        expect("<speak>Read\u{2014}6:23 PM</speak>", "Read-6- 23 PM",
               "literal em dash")
        expect("<speak>Read\u{2026}6:23 PM</speak>", "Read...6- 23 PM",
               "literal ellipsis")

        print("\n-- the engine's lead-in character must not arrive from text --")
        // '~' introduces the engine's own commands. A literal one in text is
        // obeyed rather than read, so "~x]" switches the parser into dictionary
        // mode for the rest of the utterance. Replaced with a space, not deleted,
        // so a lead-in between two words cannot join them.
        expect("<speak>Read ~x] 6:23 PM</speak>", "Read x] 6- 23 PM",
               "dictionary mode cannot be entered from text")
        expect("<speak>Read ~p] 6:23 PM</speak>", "Read p] 6- 23 PM",
               "phoneme mode cannot be entered from text")
        expect("<speak>Approximately ~5 items</speak>", "Approximately 5 items",
               "a stray tilde is neutralised")
        expect("<speak>a~b</speak>", "a b", "a lead-in between words does not join them")

        print("\n-- accented text, which the engine cannot read at all --")
        // 1995 goes silent on "café"; the accented character is dropped rather
        // than passed on as a glyph the engine would say a sound for.
        expect("<speak>caf\u{00e9} at 5:19 PM</speak>", "cafe at 5- 19 PM",
               "e-acute is folded")
        expect("<speak>\u{00fc}ber</speak>", "uber", "u-umlaut is folded")
        expect("<speak>caf\u{0065}\u{0301}</speak>", "cafe",
               "a combining accent does not become a stray character")

        print("\n-- markup that is not text --")
        expect("<!-- a comment -->Hello", "Hello", "comment")
        expect("<!-- a > b -->Hello", "Hello", "comment containing an angle bracket")
        expect(#"<sub alias="World Health Organization">WHO</sub>"#,
               "World Health Organization", "sub speaks the alias, not the abbreviation")
        expect("<speak>  spaced   out  </speak>", "spaced out", "whitespace collapsed")
        expect("Hello , world", "Hello, world", "no gap before punctuation")

        print("\n-- a clock time: the colon makes it silent, so it is rewritten --")
        // A hyphen takes the engine's number-group separator path. A full stop
        // does not: it routes "5.19" through the decimal rule, which says
        // "five point one nine" — an hour and minutes read as a fraction.
        expect("<speak>It is 5:19 PM.</speak>", "It is 5- 19 PM.", "5:19 PM")
        expect("<speak>3:20 PM</speak>", "3- 20 PM", "3:20 PM")
        expect("<speak>12:00</speak>", "12- 00", "12:00")
        expect("<speak>14:30</speak>", "14- 30", "24-hour time")
        // The space matters on its own: without it "5-19" is one two-group
        // number, and 1998ENG truncates the second group to silence.
        expect("<speak>5:19</speak>", "5- 19", "no meridiem")
        expect("<speak>17:19</speak>", "17- 19", "17:19")
        // A second colon is a second separator, not a decimal point: the old
        // rewrite made "3.20.45", which the engine read as a decimal and then
        // abandoned part way through the utterance.
        expect("<speak>3:20:45</speak>", "3- 20- 45", "seconds too")
        // Colons that are not clock times must be left alone — these already work
        // in the engine, and rewriting them would be vandalism.
        expect("<speak>Note: hello</speak>", "Note: hello", "a colon after a word")
        expect("<speak>Chapter 3: page 5.</speak>", "Chapter 3: page 5.",
               "a colon after a number but not between two")
        expect("<speak>http://x.com</speak>", "http://x.com", "a URL")

        print("\n-- plain text must pass through untouched --")
        expect("Just words.", "Just words.", "no markup at all")
        expect("", "", "empty")
        expect("The quick brown fox jumps over the lazy dog.",
               "The quick brown fox jumps over the lazy dog.", "a plain sentence")
        expect("<speak>The quick brown fox jumps over the lazy dog.</speak>",
               "The quick brown fox jumps over the lazy dog.", "the usual speak wrapper")

        print("\n-- malformed markup must not crash or hang --")
        expect("<speak>unterminated", "unterminated", "unterminated tag")
        expect("<!-- unterminated comment", "", "unterminated comment")
        expect("<speak><prosody rate=\"50%\">unclosed</speak>", "unclosed", "unclosed element")
        expect("<><>", "", "empty tags")

        print("\n-- characters the engine cannot read --")
        // The engine reads one byte per character, so an emoji is a code-page
        // glyph and the result is nonsense: measured on 2006ENG, "\u{2713}" alone
        // is 37,691 samples and six word tokens, and "\u{00A9}" produces a sample
        // count with no word tokens at all.
        expect("<speak>\u{1F600}</speak>", "grinning face", "a smiley")
        expect("<speak>\u{1F44D}</speak>", "thumbs up", "thumbs up")
        expect("<speak>\u{2764}\u{FE0F}</speak>", "red heart",
               "a heart and its variation selector")
        expect("<speak>\u{00A9}</speak>", "copyright", "a copyright sign")
        expect("<speak>\u{00AE}</speak>", "registered", "a registered sign")
        expect("<speak>hello \u{1F600} world</speak>", "hello grinning face world",
               "a smiley inside a sentence")
        // CLDR writes descriptions with ':' and ','; a comma ends the text on
        // every 2006 build and the description is what gets spoken.
        expect("<speak>\u{1F1FA}\u{1F1F8}</speak>", "flag United States",
               "a flag's description loses its colon")
        expect("<speak>\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}</speak>",
               "family man woman girl", "a joined family loses its commas")
        // ASCII is the engine's own business, and CLDR annotates punctuation
        // too -- replacing that would rewrite the punctuation of ordinary text.
        expect("<speak>hello, world!</speak>", "hello, world!",
               "punctuation is not described")

        print("\n-- the language the voice speaks --")
        expect("<speak>\u{1F600}</speak>", "grinning face", "English, by default")
        let inGerman = SSMLText.parse("<speak>\u{1F600}</speak>", language: "de-DE")
        if case .speech(let text, _, _, _)? = inGerman.pieces.first, !text.isEmpty {
            print("PASS  German description: \(text)")
        } else {
            failures.append("no German description was produced")
            print("FAIL  no German description was produced")
        }

        print("\n-- the pronunciation dictionary --")
        // The engine reads an unknown compound as one word: "FaceTime"'s token
        // stream is identical to "facetime", so it is one odd word rather than
        // "face time".
        expect("<speak>FaceTime</speak>", "Face Time", "FaceTime is split")
        expect("<speak>iPhone</speak>", "eye phone", "iPhone")
        expect("<speak>AirDrop</speak>", "air drop", "AirDrop")
        expect("<speak>WiFi</speak>", "why fye", "WiFi")
        expect("<speak>SQL</speak>", "ess cue ell", "SQL")
        expect("<speak>iPadOS</speak>", "eye pad oh ess", "iPadOS beats iPad")
        expect("<speak>Send it over FaceTime now</speak>",
               "Send it over Face Time now", "a term inside a sentence")
        // Case-sensitive and whole-word, or these would be rewritten.
        expect("<speak>facetiming</speak>", "facetiming", "a longer word is left alone")
        expect("<speak>mai</speak>", "mai", "a substring is left alone")
        expect("<speak>hello world</speak>", "hello world", "plain text is untouched")

        print("\n\(checks - failures.count)/\(checks) passed")
        if failures.isEmpty { exit(0) }
        print("\nFAILURES:")
        for failure in failures { print("  \(failure)") }
        exit(1)
    }
}
