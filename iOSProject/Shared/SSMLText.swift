import Foundation

/// Turns the SSML a speech provider is handed into the pieces the engine can
/// actually render.
///
/// The system sends SSML, not text — Apple's own headers cite the reference at
/// https://www.w3.org/TR/speech-synthesis11/. Everything the engine cannot act on
/// has to be resolved here, and every way of getting it wrong is **silent**:
/// nothing errors, the voice still speaks, it just says the wrong thing or
/// nothing at all.
///
/// Two failures this exists to prevent, both observed:
///
/// - Deleting a tag rather than replacing it with a space joins the words it sat
///   between. `iBestSpeech<break time="100ms"/>recently` became
///   "iBestSpeechrecently", one nonsense word. A tag must become whitespace.
/// - Two numbers in a row with only a space between them make the engine produce
///   **no samples at all**. Measured on build 2006ENG: "555 1234", "10 20 30",
///   "3 4 5" and "Room 101 202" are all completely silent, while "555" and
///   "1234" alone are fine, and "555-1234" or "3, 4, 5" are fine. The engine's
///   number parser fails when the next token begins with a number, and its own
///   test corpus never covers the case. `separateAdjacentNumbers` inserts the
///   comma that keeps it working; a short pause between numbers is natural speech
///   anyway, and the alternative is silence.
///
/// This is in `Shared/` so both targets see it, and so the tests can compile this
/// exact file rather than a copy that drifts.
public enum SSMLText {

    // MARK: - Result

    /// One thing to render, in order.
    public enum Piece: Equatable {
        /// Text, with the speech parameters in force over it. `pitch`, `rate` and
        /// `volume` are on VoiceOver's 0-100 scales; nil means the voice's normal
        /// setting.
        case speech(text: String, pitch: Int?, rate: Int?, volume: Int?)
        /// A pause the markup asked for.
        case pause(seconds: Double)
        /// A `mark` the markup placed, to be reported back as a marker.
        case bookmark(name: String)
    }

    public struct Parsed: Equatable {
        public var pieces: [Piece]

        /// All spoken text joined with single spaces.
        public var text: String {
            pieces.compactMap {
                if case .speech(let text, _, _, _) = $0 { return text }
                return nil
            }.joined(separator: " ")
        }

        /// VoiceOver-scale pitch from the first spoken piece.
        public var firstPitch: Int? {
            pieces.compactMap {
                if case .speech(_, let pitch, _, _) = $0 { return pitch }
                return nil
            }.first
        }

        /// VoiceOver-scale rate from the first spoken piece.
        public var firstRate: Int? {
            pieces.compactMap {
                if case .speech(_, _, let rate, _) = $0 { return rate }
                return nil
            }.first
        }

        /// Total silence the markup asked for, in seconds.
        public var totalPause: Double {
            pieces.reduce(0) {
                if case .pause(let seconds) = $1 { return $0 + seconds }
                return $0
            }
        }

        /// `mark` names in the order they appear.
        public var bookmarks: [String] {
            pieces.compactMap {
                if case .bookmark(let name) = $0 { return name }
                return nil
            }
        }
    }

    // MARK: - Parsing

    /// Walks the markup, tracking the parameters in force where it stands.
    ///
    /// A stack rather than a flat scan because elements nest: `prosody` inside
    /// `voice` inside `speak` all apply at once, and the innermost wins.
    public static func parse(_ ssml: String) -> Parsed {
        struct Context {
            var pitch: Int?
            var rate: Int?
            var volume: Int?
            var sayAs: String?
        }

        // `<sub>` is resolved over the whole document before the walk, because the
        // walk consumes tags: once `<sub alias="...">` has been seen, the alias is
        // gone and the enclosed text would be spoken as the abbreviation instead.
        let document = resolveSubstitutions(ssml)

        var pieces: [Piece] = []
        var context = Context()
        var stack: [Context] = []
        var buffer = ""

        func flush() {
            let raw = buffer
            buffer = ""
            let text = finish(raw, sayAs: context.sayAs)
            guard !text.isEmpty else { return }
            pieces.append(.speech(text: text,
                                  pitch: context.pitch,
                                  rate: context.rate,
                                  volume: context.volume))
        }

        var index = document.startIndex
        while index < document.endIndex {
            guard let tagStart = document[index...].firstIndex(of: "<") else {
                buffer += document[index...]
                break
            }
            buffer += document[index..<tagStart]

            // Comments are removed before anything else: one containing ">" would
            // otherwise end a tag match early and leave fragments as text.
            if document[tagStart...].hasPrefix("<!--") {
                guard let end = document.range(of: "-->", range: tagStart..<document.endIndex) else {
                    break   // unterminated comment: drop the remainder
                }
                index = end.upperBound
                continue
            }

            guard let tagEnd = document[tagStart...].firstIndex(of: ">") else {
                break   // unterminated tag: drop the remainder
            }
            let tag = String(document[document.index(after: tagStart)..<tagEnd])
            index = document.index(after: tagEnd)

            let isClosing = tag.hasPrefix("/")
            let body = isClosing ? String(tag.dropFirst()) : tag
            let name = body.prefix { !$0.isWhitespace && $0 != "/" }.lowercased()

            switch name {
            case "speak", "p", "s", "w", "voice", "emphasis", "lang", "desc":
                // Structure and emphasis carry nothing the engine can act on, but
                // each is still a word boundary.
                if isClosing {
                    flush()
                    context = stack.popLast() ?? context
                } else {
                    flush()
                    stack.append(context)
                }

            case "prosody":
                if isClosing {
                    flush()
                    context = stack.popLast() ?? context
                } else {
                    flush()
                    stack.append(context)
                    if let value = attribute("pitch", in: body), let pitch = pitchValue(from: value) {
                        context.pitch = pitch
                    }
                    if let value = attribute("rate", in: body), let rate = rateValue(from: value) {
                        context.rate = rate
                    }
                    if let value = attribute("volume", in: body), let volume = volumeValue(from: value) {
                        context.volume = volume
                    }
                    // `contour` describes a pitch curve over time. An engine with
                    // one pitch setting per utterance cannot follow it, so the
                    // baseline is used and the curve ignored.
                }

            case "say-as":
                if isClosing {
                    flush()
                    context = stack.popLast() ?? context
                } else {
                    flush()
                    stack.append(context)
                    context.sayAs = attribute("interpret-as", in: body)?.lowercased()
                }

            case "sub":
                if isClosing {
                    flush()
                    context = stack.popLast() ?? context
                } else {
                    // Resolved as a whole before the walk, so the alias replaces
                    // the enclosed text rather than being spoken as itself.
                    flush()
                    stack.append(context)
                }

            case "phoneme":
                // The engine takes no phoneme input, so the enclosed text is
                // spoken with its ordinary pronunciation. `alphabet` and `ph` are
                // ignored rather than approximated: a wrong pronunciation is worse
                // than the normal one.
                if isClosing { flush() }

            case "lexicon", "lookup", "meta", "metadata":
                // Pronunciation dictionaries and document metadata. Nothing here
                // is for speaking.
                break

            case "break":
                flush()
                pieces.append(.pause(seconds: breakSeconds(body)))

            case "mark":
                flush()
                if let name = attribute("name", in: body) {
                    pieces.append(.bookmark(name: name))
                }

            case "audio":
                // An audio file the system would play itself. The engine cannot
                // load it; the element's text content is the fallback, and is what
                // ends up spoken.
                if isClosing { flush() }

            default:
                // Unknown element: treated as a boundary, so its text is still
                // spoken — the best available guess.
                if isClosing {
                    flush()
                    context = stack.popLast() ?? context
                } else {
                    flush()
                    stack.append(context)
                }
            }
        }

        flush()
        return Parsed(pieces: pieces)
    }

    // MARK: - Element values

    /// Seconds for a `break`, from `time` if given and `strength` otherwise.
    static func breakSeconds(_ body: String) -> Double {
        if let time = attribute("time", in: body), let seconds = seconds(from: time) {
            // Capped: a malformed value should not stall the speech queue.
            return min(max(seconds, 0), 10)
        }
        switch attribute("strength", in: body)?.lowercased() {
        case "none":     return 0
        case "x-weak":   return 0.05
        case "weak":     return 0.1
        case "medium":   return 0.25
        case "strong":   return 0.5
        case "x-strong": return 1.0
        default:         return 0.25   // the SSML default is a medium break
        }
    }

    /// "1s", "500ms", "1.5s", or a bare number, which SSML reads as milliseconds.
    static func seconds(from text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed.hasSuffix("ms") { return Double(trimmed.dropLast(2)).map { $0 / 1000.0 } }
        if trimmed.hasSuffix("s")  { return Double(trimmed.dropLast()) }
        return Double(trimmed).map { $0 / 1000.0 }
    }

    /// A `prosody` pitch onto VoiceOver's 0-100 scale, where 50 is neutral.
    static func pitchValue(from text: String) -> Int? {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        switch value {
        case "x-low":   return 15
        case "low":     return 25
        case "medium":  return 50
        case "high":    return 75
        case "x-high":  return 90
        default: break
        }
        // A percentage is relative to the voice's own pitch, so it shifts from
        // neutral. Values in hertz are absolute and cannot be mapped without
        // knowing the voice's range, so they are ignored rather than guessed at.
        if value.hasSuffix("%"), let percent = Double(value.dropLast()) {
            return clamp(Int((50.0 + percent).rounded()))
        }
        if let mark = value.range(of: "st") {
            return Double(value[..<mark.lowerBound])
                .map { clamp(Int((50.0 + $0 * 6.0).rounded())) }
        }
        return nil
    }

    /// A `prosody` rate onto VoiceOver's 0-100 scale, where 50 is neutral.
    static func rateValue(from text: String) -> Int? {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        switch value {
        case "x-slow":  return 10
        case "slow":    return 25
        case "medium":  return 50
        case "fast":    return 75
        case "x-fast":  return 90
        default: break
        }
        // 100% is the voice's normal rate, so it sits at neutral and the
        // adjustment spreads either side. Halved because VoiceOver's own range is
        // much narrower than SSML's: 200% must stay inside the engine's usable
        // band rather than running to its extreme.
        if value.hasSuffix("%"), let percent = Double(value.dropLast()) {
            return clamp(Int((50.0 + (percent - 100.0) * 0.5).rounded()))
        }
        return nil
    }

    /// A `prosody` volume onto VoiceOver's 0-100 scale.
    static func volumeValue(from text: String) -> Int? {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        switch value {
        case "silent", "none": return 0
        case "x-soft":         return 20
        case "soft":           return 40
        case "medium":         return 60
        case "loud":           return 80
        case "x-loud":         return 100
        default: break
        }
        if value.hasSuffix("%"), let percent = Double(value.dropLast()) {
            return clamp(Int(percent.rounded()))
        }
        // Decibels are relative to full scale; +6 dB is about double.
        if value.hasSuffix("db"), let decibels = Double(value.dropLast(2)) {
            return clamp(Int((pow(10.0, decibels / 20.0) * 60.0).rounded()))
        }
        if let fraction = Double(value), fraction <= 1.0 {
            return clamp(Int((fraction * 100).rounded()))
        }
        return nil
    }

    private static func clamp(_ value: Int) -> Int { min(max(value, 0), 100) }

    /// Reads an attribute out of a tag body, decoding entities in its value.
    static func attribute(_ name: String, in body: String) -> String? {
        let quoted = "\(name)\\s*=\\s*\"([^\"]*)\""
        let bare = "\(name)\\s*=\\s*'([^']*)'"
        for pattern in [quoted, bare] {
            guard let match = body.range(of: pattern,
                                         options: [.regularExpression, .caseInsensitive])
            else { continue }
            let raw = body[match]
            guard let first = raw.firstIndex(where: { $0 == "\"" || $0 == "'" }),
                  let last = raw.lastIndex(where: { $0 == "\"" || $0 == "'" }),
                  first < last
            else { continue }
            return decodeEntities(String(raw[raw.index(after: first)..<last]))
        }
        return nil
    }

    // MARK: - Text preparation

    /// Turns accumulated raw text into what the engine should be given.
    static func finish(_ raw: String, sayAs: String?) -> String {
        var text = decodeEntities(raw)
        text = collapseWhitespace(text)
        text = closeGapsBeforePunctuation(text)
        text = fixTimes(text)
        // `say-as` before the number separation: spelling a word out inserts
        // spaces that would otherwise look like adjacent numbers.
        text = applySayAs(text, mode: sayAs)
        text = separateAdjacentNumbers(text)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Rewrites a clock time's colon so the engine reads the time instead of
    /// choking on it.
    ///
    /// A colon between two digits makes the engine produce **no audio at all**,
    /// on every build. Measured on 1995, 1998ENG and 2006ENG: "5:19 PM",
    /// "3:20 PM", "12:00", "14:30", "3:20:45" and "It is 3:20 PM." are all
    /// silent, while a hyphen in the colon's place speaks on all three.
    ///
    /// The replacement is a hyphen **and a space**, and both parts are
    /// load-bearing:
    ///
    /// - The **hyphen** takes the engine's number-group separator path, which
    ///   is its only route for two runs of digits. A full stop instead, which
    ///   is what this used to write, sends "5.19" down the decimal rule: it
    ///   reads "five point one nine", an hour and minutes announced as a
    ///   decimal fraction. That is the mispronunciation this fixes.
    /// - The **space** keeps the runs apart. Without it "5-19" is a single
    ///   two-group number, and 1998ENG truncates the second group: "5-19 PM"
    ///   says "five" and stops. With it the reading is **byte-identical** to
    ///   writing the words out — verified for "5- 19 PM" against "five
    ///   nineteen PM" on 1995 and 2006ENG, across every sample.
    ///
    /// Only a colon with a digit immediately either side is touched, so
    /// "Note: hello", "Chapter 3: page 5" and "http://x.com" are unaffected —
    /// and those already work. A second colon is a group separator now:
    /// "3:20:45" becomes "3- 20- 45", which speaks as a three-group number
    /// rather than as a time, where the old rewrite "3.20.45" was read as a
    /// decimal and then abandoned mid-utterance.
    static func fixTimes(_ text: String) -> String {
        let characters = Array(text)
        var output: [Character] = []
        output.reserveCapacity(characters.count + 8)

        for (index, character) in characters.enumerated() {
            let flankedByDigits = index > 0 && index + 1 < characters.count
                && characters[index - 1].isNumber && characters[index + 1].isNumber
            if character == ":" && flankedByDigits {
                output.append("-")
                output.append(" ")
            } else {
                output.append(character)
            }
        }
        return String(output)
    }

    /// `say-as` handling.
    ///
    /// Two modes change the text, and both are approximations of what the element
    /// asks for. `characters` wants a word spelled out letter by letter, and
    /// `digits` wants each digit named: the engine already reads space-separated
    /// letters as their names, measured at 1.6 s for "H E L L O" against 1.0 s
    /// for "Hello", so separating them is what does it.
    ///
    /// The rest are left alone. The engine normalizes numbers, currency, dates
    /// and times itself — its own corpus is full of "$1,234.56" and "3rd Feb",
    /// read correctly — so passing them through is not a gap. Only spelling a word
    /// out cannot be inferred from the text.
    static func applySayAs(_ text: String, mode: String?) -> String {
        switch mode {
        case "characters", "character", "char", "digits":
            return text
                .filter { !$0.isWhitespace }
                .map(String.init)
                .joined(separator: " ")
        default:
            return text
        }
    }

    /// Resolves `<sub alias="...">` to its alias.
    static func resolveSubstitutions(_ text: String) -> String {
        replacing(text, pattern: #"<sub\s+alias\s*=\s*["']([^"']*)["'][^>]*>[^<]*</sub>"#) { $0[1] }
    }

    /// Splits a number token from the one after it.
    ///
    /// Two numbers separated only by whitespace make the engine produce no audio
    /// at all — the whole utterance, not just the numbers. Separating them with a
    /// comma, which the engine reads as a short pause, restores it: measured
    /// silent-to-spoken on "555 1234", "10 20 30", "Version 2 0 2 6" and
    /// "Room 101 202" across the 1995, 2006ENG, 2006GER, 2006SPA and 2006FRE
    /// builds, with no case left silent.
    static func separateAdjacentNumbers(_ text: String) -> String {
        let characters = Array(text)
        var output: [Character] = []
        output.reserveCapacity(characters.count + 8)

        for (index, character) in characters.enumerated() {
            // The comma goes before the space, not after it: appending the space
            // first produced "555 ,1234", which reads as a odd pause mid-word
            // rather than a pause between two numbers.
            if character == " ",
               index > 0, index + 1 < characters.count,
               characters[index - 1].isNumber,
               characters[index + 1].isNumber {
                output.append(",")
            }
            output.append(character)
        }
        return String(output)
    }

    static func collapseWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    static func closeGapsBeforePunctuation(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+([,.!?;:])", with: "$1", options: .regularExpression)
    }

    // MARK: - Entities

    /// Named entities worth handling. Typographic characters are folded to their
    /// ASCII equivalents rather than kept, because the engine reads a single-byte
    /// code page: a curly quote or an em dash has no representation there.
    private static let namedEntities: [(String, String)] = [
        ("&nbsp;", " "),
        ("&ensp;", " "),
        ("&emsp;", " "),
        ("&thinsp;", " "),
        ("&lt;", "<"),
        ("&gt;", ">"),
        ("&quot;", "\""),
        ("&apos;", "'"),
        ("&ldquo;", "\""), ("&rdquo;", "\""),
        ("&lsquo;", "'"), ("&rsquo;", "'"),
        ("&mdash;", "-"), ("&ndash;", "-"),
        ("&hellip;", "..."),
        // Decoded last: doing it earlier would let "&amp;lt;" become "<".
        ("&amp;", "&"),
    ]

    static func decodeEntities(_ input: String) -> String {
        var text = input

        text = replacing(text, pattern: "&#[xX]([0-9A-Fa-f]+);") { groups in
            UInt32(groups[1], radix: 16).flatMap { Unicode.Scalar($0) }.map(String.init)
        }
        text = replacing(text, pattern: "&#([0-9]+);") { groups in
            UInt32(groups[1]).flatMap { Unicode.Scalar($0) }.map(String.init)
        }

        for (entity, replacement) in namedEntities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        return text
    }

    /// Replaces every match of `pattern` using `transform`, which receives the
    /// capture groups (index 0 is the whole match).
    ///
    /// Written because `replacingOccurrences(of:with:options:)` can only insert a
    /// fixed template, and these replacements need to reinterpret the match.
    private static func replacing(_ input: String,
                                  pattern: String,
                                  transform: ([String]) -> String?) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.dotMatchesLineSeparators])
        else { return input }

        let matches = regex.matches(in: input, range: NSRange(input.startIndex..., in: input))
        guard !matches.isEmpty else { return input }

        var output = ""
        var cursor = input.startIndex
        for match in matches {
            guard let range = Range(match.range, in: input) else { continue }
            output += input[cursor..<range.lowerBound]

            var groups: [String] = []
            for index in 0..<match.numberOfRanges {
                if let groupRange = Range(match.range(at: index), in: input) {
                    groups.append(String(input[groupRange]))
                } else {
                    groups.append("")
                }
            }
            output += transform(groups) ?? String(input[range])
            cursor = range.upperBound
        }
        output += input[cursor...]
        return output
    }

    // MARK: - Convenience

    /// The words to speak, with markup resolved.
    public static func plainText(from ssml: String) -> String {
        parse(ssml).text
    }

    /// VoiceOver-scale pitch and rate from the first spoken piece.
    public static func speechParameters(from ssml: String) -> (pitch: Int?, rate: Int?) {
        let parsed = parse(ssml)
        return (parsed.firstPitch, parsed.firstRate)
    }

    /// The words to speak together with the pitch and rate that came with them.
    public static func textAndParameters(from ssml: String) -> (text: String, pitch: Int?, rate: Int?) {
        let parsed = parse(ssml)
        return (parsed.text, parsed.firstPitch, parsed.firstRate)
    }
}
