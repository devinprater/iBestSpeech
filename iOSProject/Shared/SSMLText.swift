import Foundation

/// Turns the SSML the system hands a speech provider into plain text the engine
/// can read, plus the pitch and rate it asked for.
///
/// This is in `Shared/` so both targets see it, and so the test in `Tests/` can
/// compile this exact file rather than a copy of it.
///
/// The engine predates markup: it takes a plain string of bytes. Whatever the
/// SSML contains beyond the words themselves therefore has to be removed, and
/// how it is removed decides whether the speech is intelligible. Two mistakes
/// are easy to make and both are silent — nothing errors, the words just come
/// out wrong:
///
/// - Deleting a tag rather than replacing it with a space joins the words it sat
///   between. `iBestSpeech<break time="100ms"/>recently` becomes
///   "iBestSpeechrecently", one nonsense word.
/// - Leaving an entity undecoded passes literal markup to the engine. `&#160;`
///   is a non-breaking space; as text the engine ignores it, which joins words
///   just as effectively. Curly quotes and dashes come through as bytes that are
///   not valid in the engine's single-byte code page and are dropped or mangled.
public enum SSMLText {

    /// Named entities worth handling. Typographic characters are folded to their
    /// ASCII equivalents rather than kept, because the engine reads a single-byte
    /// code page: a curly quote or an em dash has no representation there and
    /// would come out as noise.
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

    /// The words to speak, with markup and entities resolved.
    public static func plainText(from ssml: String) -> String {
        var text = ssml

        // A substitution that reads the text content of <sub> instead of its
        // alias would speak the abbreviation rather than the words it stands for.
        text = replacing(text, pattern: #"<sub\s+alias="([^"]*)"\s*>[^<]*</sub>"#) { $0[1] }

        // Comments first: one containing ">" would otherwise end a tag match
        // early and leave fragments in the text.
        text = text.replacingOccurrences(of: "<!--.*?-->", with: " ",
                                         options: [.regularExpression])

        // Tags become a space, never nothing. This is the whole point: the
        // whitespace a tag stood in for has to be given back.
        text = text.replacingOccurrences(of: "<[^>]*>", with: " ",
                                         options: [.regularExpression])

        text = decodeEntities(text)

        // Collapse everything the substitutions introduced. `\s` in ICU covers
        // the Unicode spaces, so a decoded non-breaking space is folded here too.
        text = text.replacingOccurrences(of: "\\s+", with: " ",
                                         options: [.regularExpression])

        // Close gaps opened before punctuation, which reads as an odd pause:
        // "Hello , world" becomes "Hello, world".
        text = text.replacingOccurrences(of: "\\s+([,.!?;:])", with: "$1",
                                         options: [.regularExpression])

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The words to speak together with the pitch and rate that came with them.
    public static func textAndParameters(from ssml: String) -> (text: String, pitch: Int?, rate: Int?) {
        let parameters = speechParameters(from: ssml)
        return (plainText(from: ssml), parameters.pitch, parameters.rate)
    }

    /// Pitch and rate from the markup, as VoiceOver states them.
    ///
    /// On the same 0-100 scale. The engine needs them converted before use —
    /// see `EngineParameters`; the raw values are meaningless to it.
    public static func speechParameters(from ssml: String) -> (pitch: Int?, rate: Int?) {
        func percentage(_ attribute: String) -> Int? {
            // The value may carry a sign and a decimal — a relative adjustment
            // arrives as `pitch="+15%"`, which a digits-only pattern misses
            // entirely, silently dropping the adjustment.
            let pattern = "\(attribute)=\"([+-]?[0-9]*\\.?[0-9]+)%?\""
            guard let match = ssml.range(of: pattern, options: .regularExpression) else {
                return nil
            }
            let value = ssml[match]
                .replacingOccurrences(of: "\(attribute)=\"", with: "")
                .replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: "%", with: "")
            return Double(value).map { Int($0.rounded()) }
        }
        return (percentage("pitch"), percentage("rate"))
    }

    // MARK: - Entities

    static func decodeEntities(_ input: String) -> String {
        var text = input

        // Numeric references, decimal and hexadecimal.
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

        let matches = regex.matches(in: input,
                                    range: NSRange(input.startIndex..., in: input))
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
}
