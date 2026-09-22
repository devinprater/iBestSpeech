import Foundation

/// Translates the pitch and rate VoiceOver asks for into the parameters the
/// engine understands.
///
/// The two vocabularies do not line up, and neither mismatch is loud — speech
/// still comes out, just at the wrong pace or pitch.
///
/// ## Rate runs the opposite way
///
/// The engine's `rate` scales utterance *duration* as `(rate + 100) / 100`
/// (`bst_duration_scale` in the engine's `src/interp.c`), so a larger value
/// produces a longer utterance and therefore slower speech. Measured on the
/// built library with a fixed sentence, build `2006ENG`:
///
///     engine rate   -100      0     100     300
///     duration      0.37x   1.00x   1.88x   3.62x
///
/// VoiceOver runs the other way: 0 is slowest, 1 is fastest. Passing its value
/// straight through therefore inverted the control — 0% came out at a normal
/// pace and 100% came out very slow.
///
/// VoiceOver's neutral 0.5 is mapped to the engine's nominal 0, so the default
/// sounds like the engine's own voice rather than an altered one.
///
/// ## Pitch is the same way round, but its neutral is not where I assumed
///
/// A larger engine value is a higher F0, so no inversion is needed. The mistake
/// was where to put neutral. Measured on build `1995`, rate 0, top left at the
/// engine's own default of 160:
///
///     engine pitch    50     60     70     80    100    120    140
///     F0           56 Hz  69 Hz  79 Hz  97 Hz  114 Hz  139 Hz  159 Hz
///
/// The engine's **default is 80**, not 50. Mapping VoiceOver's neutral onto 50
/// therefore dropped the voice from 97 Hz to 56 Hz — most of an octave below
/// where it was designed to sit. That is what made it sound low and strained;
/// the exaggerated inflection was collateral, since a contour of the same size
/// sitting on a lower fundamental is a much larger proportion of it. `top`, the
/// parameter that looks like it should control the excursion, moves F0 not at
/// all, so it is left alone at the engine's default.
///
/// The floor is 50: below it the output leaves the voiced range. The ceiling of
/// 140 is where F0 stops being useful for speech. Neutral maps to the engine's
/// own default so an untouched voice sounds like the voice.
public enum EngineParameters {

    /// The engine's own default, and therefore what VoiceOver's neutral maps to.
    /// Pitch 0 is not the lowest pitch, it is unvoiced buzz.
    static let defaultPitch = 80
    /// Below this the engine leaves the voiced range and buzzes.
    static let minimumPitch = 50
    /// Above this F0 is no longer useful for speech.
    static let maximumPitch = 140

    /// The engine's fastest setting; it saturates here (values below -100 give
    /// the same result).
    static let fastestRate = -100
    /// About 3.6x the nominal duration. Beyond this speech stops being usable.
    static let slowestRate = 300

    /// VoiceOver's rate as a fraction of its full range: 0 slowest, 1 fastest.
    public static func rateFraction(from value: Double) -> Double {
        normalise(value)
    }

    /// VoiceOver's pitch on its 0-100 scale.
    public static func pitchValue(from value: Double) -> Double {
        normalise(value)
    }

    /// The engine's `rate` for a VoiceOver rate.
    ///
    /// Two straight segments meeting at VoiceOver's neutral, so that 0, 0.5 and
    /// 1 land exactly on the engine's slowest, nominal and fastest settings. A
    /// single curve through those three points overshoots: the reciprocal that
    /// would fit them asymptotes towards the fast end and only reaches half the
    /// engine's speed range, so "fastest" would not actually have been fastest.
    public static func engineRate(forVoiceOver rate: Double) -> Int {
        let fraction = rateFraction(from: rate)
        let engine: Double
        if fraction <= 0.5 {
            engine = ((0.5 - fraction) / 0.5) * Double(slowestRate)
        } else {
            engine = ((fraction - 0.5) / 0.5) * Double(fastestRate)
        }
        return min(max(Int(engine.rounded()), fastestRate), slowestRate)
    }

    /// The engine's `pitch` for a VoiceOver pitch.
    ///
    /// Two segments meeting at VoiceOver's neutral, because the engine's usable
    /// range is not centred on it: 50 to 140 with the default at 80, so the lower
    /// half of VoiceOver's travel maps onto 50-80 and the upper half onto 80-140.
    /// Neutral therefore lands on the engine's own default rather than shifting
    /// the voice, which is the whole point — an untouched voice must sound
    /// untouched.
    public static func enginePitch(forVoiceOver pitch: Double) -> Int {
        let fraction = pitchValue(from: pitch)
        let engine = fraction <= 0.5
            ? Double(minimumPitch)
                + fraction * 2.0 * (Double(defaultPitch) - Double(minimumPitch))
            : Double(defaultPitch)
                + (fraction - 0.5) * 2.0 * (Double(maximumPitch) - Double(defaultPitch))
        return min(max(Int(engine.rounded()), minimumPitch), maximumPitch)
    }

    /// VoiceOver states these values either as a fraction of the range (0-1) or
    /// as a percentage (0-100), depending on the property. Anything above 1.5 can
    /// only be the latter, so scale it down; the two ranges do not otherwise
    /// overlap in a way that matters. Clamped to 0-1, so an out-of-range value
    /// saturates rather than wrapping.
    private static func normalise(_ value: Double) -> Double {
        let scaled = value > 1.5 ? value / 100.0 : value
        return min(max(scaled, 0), 1)
    }
}
