import Foundation

/// Works out which language a piece of text is in, so a voice can be picked for
/// it rather than for the device's setting.
///
/// Two stages, because they have very different reliability:
///
/// 1. **Script.** Cyrillic, Greek, Arabic, Hebrew and kana belong to exactly one
///    of the thirteen languages the engine carries, so a single such character
///    settles it. This is exact and needs no guessing.
/// 2. **Function words, for the Latin-script languages.** English, German,
///    French, Spanish, Italian, Dutch, Portuguese and Polish share an alphabet,
///    so the only cheap signal is the words that carry no meaning: "the", "der",
///    "le", "el". A text is scored against each language's list, as whole words
///    and case-insensitively, and the best score wins -- but only if it beats a
///    floor and clearly beats the runner-up. Otherwise nothing is claimed.
///
/// Returning `nil` is a real answer and the common one for short text: a single
/// word like "Hallo" is in several of these languages, and guessing there would
/// switch a voice on no evidence. The caller keeps what it was asked for.
///
/// This deliberately does not use `NLLanguageRecognizer`. That framework is
/// better at this than a function-word list could ever be, but it is only
/// available on Apple platforms, so nothing about this file could be tested
/// off-device -- and an untestable language guess is exactly the kind of thing
/// that sounds fine here and is wrong on a phone.
public enum LanguageDetector {

    /// The languages the engine carries, and the build to use for each.
    ///
    /// The newest generation is preferred: where two builds share a language
    /// (1998DUT and 2006DUT) the 2006 one is the fuller lexicon.
    public static let preferredBuilds: [String: String] = [
        "en": "2006ENG", "nl": "2006DUT", "fr": "2006FRE", "de": "2006GER",
        "it": "2006ITA", "es": "2006SPA", "pt": "2006POR", "pl": "2006POL",
        "ru": "2006RUS", "ar": "2006ARA", "he": "2006HEB", "el": "2006GRE",
        "ja": "2006JPN",
    ]

    /// The build to speak `text` with, or nil to keep the voice that was asked
    /// for.
    ///
    /// - Parameter current: the language the requested voice already speaks. A
    ///   detection that agrees with it is not a switch, and returning nil there
    ///   keeps this from doing work for nothing.
    public static func buildToSpeak(_ text: String, insteadOf current: String) -> String? {
        guard let detected = language(of: text) else { return nil }
        let currentBase = base(current)
        guard detected != currentBase else { return nil }
        return preferredBuilds[detected]
    }

    /// The language of `text`, or nil when nothing can be said with confidence.
    public static func language(of text: String) -> String? {
        // Script first: decisive where it applies, and it also skips the
        // function-word stage for text that is not Latin at all.
        let scripts = scriptCounts(in: text)
        let letters = scripts.values.reduce(0, +)
        guard letters > 0 else { return nil }

        // A single character of a unique script is enough -- but only when that
        // script is what the text is mostly made of, or a Russian name inside an
        // English sentence would flip the whole utterance.
        for (script, language) in uniqueScripts {
            if let count = scripts[script], count * 2 >= letters, count > 0 {
                return language
            }
        }

        // Kana is the marker for Japanese, which also writes kanji.
        if let kana = scripts[.kana], kana > 0 { return "ja" }

        // Latin, and only Latin: a mixed-script text is not a job for a
        // function-word list.
        if scripts.count > 1, scripts[.latin] == nil { return nil }
        guard let latin = scripts[.latin], latin * 2 >= letters else { return nil }

        return latinLanguage(of: text)
    }

    // MARK: - Scripts

    private enum Script: Hashable {
        case latin, cyrillic, greek, arabic, hebrew, kana, other
    }

    /// Scripts that belong to exactly one of the engine's languages.
    private static let uniqueScripts: [(Script, String)] = [
        (.cyrillic, "ru"), (.greek, "el"), (.arabic, "ar"), (.hebrew, "he"),
    ]

    /// Which script a character is written in.
    ///
    /// Classified by Unicode block, not by `scalar.properties.script` -- the
    /// standard library's scalar properties do not carry a script member, and
    /// the blocks that matter here (Cyrillic, Greek, Arabic, Hebrew, kana) each
    /// belong to exactly one of the engine's languages.
    private static func script(of scalar: Unicode.Scalar) -> Script? {
        // Only letters count. A digit or a punctuation mark says nothing about
        // the language; the function-word lists below see words regardless.
        guard CharacterSet.letters.contains(scalar) else { return nil }

        switch scalar.value {
        case 0x0041...0x024F, 0x1E00...0x1EFF, 0x2C60...0x2C7F, 0xA720...0xA7FF:
            return .latin
        case 0x0400...0x04FF, 0x0500...0x052F, 0x2DE0...0x2DFF, 0xA640...0xA69F:
            return .cyrillic
        case 0x0370...0x03FF, 0x1F00...0x1FFF:
            return .greek
        case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF,
             0xFB50...0xFDFF, 0xFE70...0xFEFF:
            return .arabic
        case 0x0590...0x05FF, 0xFB1D...0xFB4F:
            return .hebrew
        case 0x3040...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF,
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
             0xFF66...0xFF9D:
            return .kana
        default:
            return .other
        }
    }

    private static func scriptCounts(in text: String) -> [Script: Int] {
        var counts: [Script: Int] = [:]
        for scalar in text.unicodeScalars {
            if let s = script(of: scalar) { counts[s, default: 0] += 1 }
        }
        return counts
    }

    // MARK: - Latin languages by function word

    /// The words that give a Latin-script language away.
    ///
    /// Only function words: they are the most frequent words in any text and the
    /// ones a language cannot do without, so a sentence of any length contains
    /// several. Content words would need a much longer list and would still be
    /// defeated by a loan word.
    private static let functionWords: [String: Set<String>] = [
        "en": ["the", "and", "is", "are", "you", "of", "to", "in", "it", "that",
               "was", "for", "on", "with", "as", "at", "be", "this", "have",
               "from", "not", "but", "they", "we", "what", "there", "when"],
        "de": ["der", "die", "das", "und", "ist", "nicht", "ein", "eine", "mit",
               "sich", "auf", "für", "von", "dem", "den", "zu", "im", "auch",
               "als", "aber", "wenn", "wir", "sie", "noch", "nur"],
        "fr": ["le", "la", "les", "des", "est", "et", "un", "une", "que", "qui",
               "dans", "pour", "pas", "vous", "avec", "sur", "ce", "il", "elle",
               "nous", "mais", "plus", "au", "aux", "je"],
        "es": ["el", "la", "los", "las", "de", "que", "y", "en", "un", "una",
               "es", "por", "con", "para", "no", "se", "su", "al", "del", "lo",
               "como", "más", "pero", "yo", "este"],
        "it": ["il", "la", "le", "di", "che", "e", "un", "una", "per", "con",
               "non", "si", "del", "al", "sono", "questo", "come", "più", "ma",
               "io", "gli", "della", "anche"],
        "nl": ["de", "het", "een", "en", "van", "is", "dat", "op", "te", "voor",
               "met", "zijn", "niet", "aan", "er", "ook", "als", "maar", "wij",
               "ze", "nog", "naar"],
        "pt": ["o", "a", "os", "as", "de", "que", "e", "do", "da", "em", "um",
               "uma", "é", "para", "com", "não", "se", "por", "como", "mais",
               "mas", "eu", "este", "são"],
        "pl": ["i", "w", "na", "z", "do", "że", "się", "nie", "jest", "to", "o",
               "a", "jak", "po", "tak", "ale", "dla", "od", "czy", "ja", "ze",
               "oraz", "przez"],
    ]

    /// How much evidence a language needs before it is claimed.
    ///
    /// A score is `matches / words`, so a two-word text can score 1.0 by
    /// accident. Two things are required: an absolute floor, and a clear win
    /// over the runner-up, because the lists overlap ("de" is a French, Spanish
    /// and Dutch word; "a" is Portuguese and Polish).
    private static let minimumScore = 0.08

    /// Short text needs more than one match before anything is claimed.
    ///
    /// A single word gives a score of 1.0 off one lucky hit -- "the" would be
    /// English on that basis, and so would several words that two languages
    /// share. Below this many words, two hits are required instead of one, which
    /// no one-word text can reach, so a single word never moves a voice.
    private static let minimumWordsForOneHit = 3

    private static func latinLanguage(of text: String) -> String? {
        let words = text.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
        guard !words.isEmpty else { return nil }

        let requiredHits = words.count < minimumWordsForOneHit ? 2 : 1

        var scores: [(language: String, score: Double, hits: Int)] = []
        for (language, list) in functionWords {
            let hits = words.reduce(0) { $0 + (list.contains($1) ? 1 : 0) }
            scores.append((language, Double(hits) / Double(words.count), hits))
        }
        scores.sort { $0.score > $1.score }

        guard let best = scores.first, best.hits >= requiredHits,
              best.score >= minimumScore
        else { return nil }

        // A tie between two languages is no evidence for either.
        if scores.count > 1, scores[1].hits == best.hits { return nil }
        return best.language
    }

    private static func base(_ language: String) -> String {
        language.split(separator: "-").first.map(String.init) ?? language
    }
}
