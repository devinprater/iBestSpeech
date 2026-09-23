// Tests for `LanguageDetector`.
//
// The detector is a guess by construction, so the assertions here are of two
// kinds: where the evidence is unambiguous it must be right, and where it is
// not, it must decline. A wrong switch changes the voice the user hears, which
// is worse than no switch -- so most of these check that nothing is claimed.

import Foundation

enum LanguageDetectorTests {
    static var checks = 0
    static var failures: [String] = []

    /// The string must not be read as some OTHER language. English or nothing
    /// are both acceptable; "es" is not, and that is the bug this encodes.
    static func expectNotForeign(_ text: String, _ label: String) {
        checks += 1
        let got = LanguageDetector.language(of: text)
        if got == nil || got == "en" {
            print("PASS  \(label)")
        } else {
            let failure = "\(label): \(text.prefix(40)) was read as \(got!)"
            failures.append(failure)
            print("FAIL  \(failure)")
        }
    }

    static func expect(_ text: String, _ expected: String?, _ label: String) {
        checks += 1
        let got = LanguageDetector.language(of: text)
        if got == expected {
            print("PASS  \(label)")
        } else {
            let failure = "\(label): got \(got ?? "nil") for \(text.prefix(48))"
            failures.append(failure)
            print("FAIL  \(failure)")
        }
    }

    static func main() {
        print("-- script is decisive --")
        expect("Привет, как дела", "ru", "Cyrillic is Russian")
        expect("Γεια σου, τι κάνεις", "el", "Greek is Greek")
        expect("مرحبا كيف حالك", "ar", "Arabic is Arabic")
        expect("שלום מה שלומך", "he", "Hebrew is Hebrew")
        expect("これはテストです", "ja", "kana is Japanese")
        expect("こんにちは", "ja", "hiragana alone")

        print("\n-- a stray word of another script must not flip the utterance --")
        // One Russian word inside an English sentence is 1 of many letters.
        expect("The Moscow office is closed today and tomorrow for the holiday",
               "en", "an English sentence stays English")

        print("\n-- Latin languages, by function word --")
        expect("The quick brown fox jumps over the lazy dog and it is not here",
               "en", "English")
        expect("Der Hund ist nicht gross und die Katze ist auch da", "de", "German")
        expect("Le chat est dans la maison et il ne veut pas sortir", "fr", "French")
        expect("El perro está en la casa y no quiere salir con nosotros", "es", "Spanish")
        expect("Il cane è nella casa e non vuole uscire con noi", "it", "Italian")
        expect("De hond is in het huis en hij wil niet naar buiten", "nl", "Dutch")
        expect("O cachorro está em casa e não quer sair com a gente", "pt", "Portuguese")
        expect("Pies jest w domu i nie chce wyjść na zewnątrz", "pl", "Polish")

        print("\n-- English UI strings must never come out as another language --")
        // Measured bug: "No Updates Available" was read as Spanish, because
        // "No" is a Spanish word and nothing in three words outvoted it. This
        // shape -- "No <Noun> <Adjective>" -- is everywhere in an OS.
        expectNotForeign("No Updates Available", "No Updates Available")
        expectNotForeign("No updates available", "No updates available")
        expectNotForeign("No SIM Card", "No SIM Card")
        expectNotForeign("No Internet Connection", "No Internet Connection")
        expectNotForeign("No Results", "No Results")
        expectNotForeign("Not Connected", "Not Connected")
        expectNotForeign("Sign in to your account", "Sign in to your account")
        expectNotForeign("Enter your password", "Enter your password")
        expectNotForeign("Unable to load content", "Unable to load content")
        expectNotForeign("The request timed out", "The request timed out")
        expectNotForeign("This app is not available in your region",
                         "not available in your region")
        expectNotForeign("Your session has expired. Please sign in again.",
                         "session expired")
        expectNotForeign("Do Not Disturb", "Do Not Disturb")
        expectNotForeign("Screen Time", "Screen Time")
        expectNotForeign("Face ID & Passcode", "Face ID & Passcode")
        expectNotForeign("Software Update", "Software Update")
        expectNotForeign("Airplane Mode", "Airplane Mode")
        expectNotForeign("No Items", "No Items")

        // Reported: an App Store promotion line was read as another language.
        // "Buy now, pay over time, Yesterday, Version 4.98.2 * 129.2 MB" came
        // back Dutch, because "over" is a Dutch function word and it was the
        // only word in the line that matched anything. One hit in a long text
        // is a coincidence, and is no longer accepted as evidence.
        expectNotForeign("Buy now, pay over time, Yesterday, Version 4.98.2 \u{2022} 129.2 MB",
                         "an App Store line")
        expectNotForeign("Buy now, pay over time", "a purchase line is not Dutch")
        expectNotForeign("Buy now, pay later", "a purchase line is not Dutch")
        expectNotForeign("Pay over time", "a purchase line is not Dutch")
        expectNotForeign("Add to Cart", "a store button")
        expectNotForeign("Free for 30 days", "a promotion")
        expectNotForeign("Sign in with Apple", "a sign-in line")
        expectNotForeign("In-App Purchases", "a store line")
        expectNotForeign("Loading", "Loading")
        expectNotForeign("Cancel", "Cancel")
        expectNotForeign("Settings", "Settings")
        expectNotForeign("Battery", "Battery")
        expectNotForeign("Storage", "Storage")
        expectNotForeign("Share", "Share")
        expectNotForeign("Delete", "Delete")
        expectNotForeign("Retry", "Retry")

        print("\n-- and it must decline when the evidence is thin --")
        // These are exactly the cases a guess would get wrong, and a wrong
        // switch changes the voice the user hears.
        expect("Hallo", nil, "a single word is in several languages")
        expect("", nil, "empty text")
        expect("12345", nil, "digits have no language")
        expect("hello", nil, "one word of one language still proves nothing")
        // "la" is a word in French, Spanish and Italian, so the score is a
        // three-way tie and nothing is claimed.
        expect("la", nil, "a word three languages share claims nothing")
        // A word several of these languages share gives no clear winner, so a
        // text made only of it must decline rather than pick whichever list
        // happens to be longer.
        expect("als", nil, "a word several languages share claims nothing")
        expect("como", nil, "another shared word claims nothing")
        // One hit out of two words is below the short-text threshold.
        expect("hello the", nil, "one match in two words is not enough")

        print("\n-- which build to speak it with --")
        checks += 1
        if LanguageDetector.buildToSpeak("Привет, как дела", insteadOf: "en-US") == "2006RUS" {
            print("PASS  Russian text picks the Russian build")
        } else {
            failures.append("Russian text did not pick 2006RUS")
            print("FAIL  Russian text did not pick 2006RUS")
        }
        checks += 1
        if LanguageDetector.buildToSpeak("The office is closed today",
                                         insteadOf: "en-US") == nil {
            print("PASS  English text asked for an English voice is not a switch")
        } else {
            failures.append("English in an English voice was treated as a switch")
            print("FAIL  English in an English voice was treated as a switch")
        }
        // Reported: the "Photos" heading was read in a French voice, because
        // "photos" is a French word and the only one in the line. Latin-script
        // text in an English voice stays in that voice: a Latin detection is
        // a guess about shared words, never proof.
        checks += 1
        if LanguageDetector.buildToSpeak("photos", insteadOf: "en-US") == nil {
            print("PASS  Photos in an English voice is not a switch")
        } else {
            failures.append("Photos in an English voice was treated as a switch")
            print("FAIL  Photos in an English voice was treated as a switch")
        }
        // Even a genuine French sentence stays English in an English voice...
        checks += 1
        if LanguageDetector.buildToSpeak("Le chat est dans la maison et il ne veut pas sortir",
                                         insteadOf: "en-US") == nil {
            print("PASS  French in an English voice is not a switch")
        } else {
            failures.append("French in an English voice was treated as a switch")
            print("FAIL  French in an English voice was treated as a switch")
        }
        // ...while a unique script still switches: Greek and Japanese join
        // the existing Russian case.
        for (text, build, label) in [("Γεια σου, τι κάνεις", "2006GRE", "Greek"),
                                     ("これはテストです", "2006JPN", "Japanese")] {
            checks += 1
            if LanguageDetector.buildToSpeak(text, insteadOf: "en-US") == build {
                print("PASS  \(label) text picks the \(label) build")
            } else {
                failures.append("\(label) text did not pick \(build)")
                print("FAIL  \(label) text did not pick \(build)")
            }
        }
        // And switching between non-English voices still works: French text
        // asked for a German voice picks the French build.
        checks += 1
        if LanguageDetector.buildToSpeak("Le chat est dans la maison et il ne veut pas sortir",
                                         insteadOf: "de-DE") == "2006FRE" {
            print("PASS  French in a German voice still switches")
        } else {
            failures.append("French in a German voice no longer switches")
            print("FAIL  French in a German voice no longer switches")
        }

        print("\n\(checks - failures.count)/\(checks) passed")
        if failures.isEmpty { exit(0) }
        print("\nFAILURES:")
        for f in failures { print("  \(f)") }
        exit(1)
    }
}

// `swiftc` wants an entry point; the other test files in this directory declare
// one the same way.
@main
enum Runner {
    static func main() { LanguageDetectorTests.main() }
}
