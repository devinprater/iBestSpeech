import Foundation

/// What each engine build needs in order to speak.
///
/// The engine predates Unicode: several builds read text as bytes in a legacy
/// single-byte code page rather than as UTF-8. Handed UTF-8 or Latin text they
/// still return a plausible sample count and then nothing but silence, so the
/// caller has to encode the text the way that build's original expected.
///
/// Which builds those are is measured, not assumed. Against the built library:
///
/// - `2006RUS` CP1251 gives 69% non-zero samples; Latin gives 0%.
/// - `2006ARA` CP1256 gives 69%; Latin gives 49%, so it can read either.
/// - `2006GRE` CP1253 gives 55%; Latin gives 51%, so it can read either.
/// - `2006HEB` Latin gives 45%; CP1255 gives 0%. This build speaks Hebrew
///   phonetics written in Latin letters, which is how the engine's own test
///   suite drives it ("ze mivchan"), so it is treated as Latin-reading.
///
/// Where a build can read either, its own code page is preferred because the
/// output is closer to the original. Where it cannot read Latin at all, the
/// caller falls back to English rather than emitting silence.
struct VoiceInfo {
    let build: String
    /// BCP-47 tag, used for the system voice registration.
    let language: String
    /// The code page this build reads, or nil when it reads Latin text.
    let codePage: CFStringEncoding?
    /// Sample text in the script this build actually reads.
    let sample: String
}

enum VoiceCatalog {
    static let englishBuild = "2006ENG"

    /// Every build the engine carries, newest generation first within each group.
    static let all: [VoiceInfo] = [
        // 1995
        VoiceInfo(build: "1995", language: "en-US", codePage: nil,
                  sample: "Hello, this is the Keynote Gold voice."),

        // 1998 modules
        VoiceInfo(build: "1998ENG", language: "en-US", codePage: nil,
                  sample: "Hello, this is the Keynote Gold voice."),
        VoiceInfo(build: "1998DUT", language: "nl-NL", codePage: nil,
                  sample: "Dit is een test van de spraaksynthese."),
        VoiceInfo(build: "1998FRN", language: "fr-FR", codePage: nil,
                  sample: "Ceci est un test de la synthese vocale."),
        VoiceInfo(build: "1998GRM", language: "de-DE", codePage: nil,
                  sample: "Dies ist ein Test der Sprachsynthese."),
        VoiceInfo(build: "1998ITL", language: "it-IT", codePage: nil,
                  sample: "Questo e un test della sintesi vocale."),
        VoiceInfo(build: "1998SPN", language: "es-ES", codePage: nil,
                  sample: "Esto es una prueba de sintesis de voz."),

        // 2006 builds
        VoiceInfo(build: "2006ARA", language: "ar-SA",
                  codePage: CFStringEncoding(CFStringEncodings.windowsArabic.rawValue),
                  sample: "مرحبا، هذا اختبار للصوت."),
        VoiceInfo(build: "2006DUT", language: "nl-NL", codePage: nil,
                  sample: "Dit is een test van de spraaksynthese."),
        VoiceInfo(build: "2006ENG", language: "en-US", codePage: nil,
                  sample: "Hello, this is the Keynote Gold voice."),
        VoiceInfo(build: "2006FRE", language: "fr-FR", codePage: nil,
                  sample: "Ceci est un test de la synthese vocale."),
        VoiceInfo(build: "2006GER", language: "de-DE", codePage: nil,
                  sample: "Dies ist ein Test der Sprachsynthese."),
        VoiceInfo(build: "2006GRE", language: "el-GR",
                  codePage: CFStringEncoding(CFStringEncodings.windowsGreek.rawValue),
                  sample: "Γεια σου, αυτό είναι ένα τεστ."),
        VoiceInfo(build: "2006HEB", language: "he-IL", codePage: nil,
                  sample: "shalom, ze mivchan."),
        VoiceInfo(build: "2006ITA", language: "it-IT", codePage: nil,
                  sample: "Questo e un test della sintesi vocale."),
        VoiceInfo(build: "2006JPN", language: "ja-JP", codePage: nil,
                  sample: "kore wa tesuto desu."),
        VoiceInfo(build: "2006POL", language: "pl-PL", codePage: nil,
                  sample: "To jest test syntezy mowy."),
        VoiceInfo(build: "2006POR", language: "pt-PT", codePage: nil,
                  sample: "Isto e um teste de sintese de voz."),
        VoiceInfo(build: "2006RUS", language: "ru-RU",
                  codePage: CFStringEncoding(CFStringEncodings.windowsCyrillic.rawValue),
                  sample: "Привет, это тест речи."),
        VoiceInfo(build: "2006SPA", language: "es-ES", codePage: nil,
                  sample: "Esto es una prueba de sintesis de voz."),
    ]

    static func info(for build: String) -> VoiceInfo? {
        all.first { $0.build == build }
    }

    static func language(for build: String) -> String {
        info(for: build)?.language ?? "en-US"
    }

    /// The sample phrase to prefill for a build, so the preview is something the
    /// selected voice can actually say.
    static func sample(for build: String) -> String {
        info(for: build)?.sample ?? "Hello, this is the Keynote Gold voice."
    }

    /// What to call a build in the interface.
    ///
    /// The build names are the library's own (`2006ENG`, `1998FRN`), which say
    /// nothing to the person choosing a voice. This spells the same information
    /// out: the generation, which is the voice's character, and the language it
    /// speaks. The engine's generations really do sound different — that is why
    /// both are offered rather than only the newest.
    static func displayName(for build: String) -> String {
        let generation: String
        if build.hasPrefix("1995") {
            generation = "Keynote Gold 1995"
        } else if build.hasPrefix("1998") {
            generation = "Keynote Gold 1998"
        } else if build.hasPrefix("2006") {
            generation = "Keynote Gold 2006"
        } else {
            generation = "Keynote Gold"
        }

        guard let info = info(for: build) else { return generation }

        let languageName = Locale(identifier: "en-US")
            .localizedString(forIdentifier: info.language) ?? info.language
        return "\(generation) \(languageName)"
    }
}

extension String {
    /// Encodes the receiver into a legacy single-byte code page.
    ///
    /// Returns nil when the code page has no mapping for some character, which
    /// is the signal to fall back rather than feed the engine bytes it will
    /// treat as silence.
    func encoded(as codePage: CFStringEncoding) -> [UInt8]? {
        let ns = CFStringConvertEncodingToNSStringEncoding(codePage)
        guard ns != kCFStringEncodingInvalidId else { return nil }
        return data(using: String.Encoding(rawValue: ns))?.map { $0 }
    }
}
