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
/// ## Pitch is the same way round, but its floor is not usable
///
/// Measured fundamental frequency for `2006ENG` at engine rate 0:
///
///     engine pitch    25     50     75    100
///     F0            68 Hz  89 Hz  109 Hz  132 Hz
///
/// So a larger value is already a higher pitch and needs no inversion. Pitch 0,
/// however, is not a lower pitch — it drops out of the voiced range altogether
/// and the output becomes a buzz. The mapping compresses the lower half so the
/// floor arrives at 25 instead of 0, while pinning VoiceOver's neutral 50 to the
/// engine's 50 so the default is unchanged.
public enum EngineParameters {

    /// Below this the engine leaves the voiced range and buzzes.
    static let minimumPitch = 25
    static let maximumPitch = 100

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
    /// pitch range is not centered: it runs 25 to 100 with the natural value at
    /// 50, so the lower half of VoiceOver's travel has to be compressed onto
    /// 25-50 while the upper half passes onto 50-100.
    public static func enginePitch(forVoiceOver pitch: Double) -> Int {
        let fraction = pitchValue(from: pitch)
        let engine = fraction <= 0.5
            ? Double(minimumPitch) + fraction * (50.0 - Double(minimumPitch)) * 2.0
            : 50.0 + (fraction - 0.5) * (Double(maximumPitch) - 50.0) * 2.0
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
