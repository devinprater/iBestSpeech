import Foundation

/// Checks EngineParameters against the engine's measured behaviour.
///
/// Compiled together with `Shared/EngineParameters.swift` so this exercises the
/// shipping code rather than a copy.
///
/// Run:
///   swiftc -parse-as-library \
///     iOSProject/Shared/EngineParameters.swift \
///     iOSProject/Tests/EngineParameterTests.swift \
///     -o /tmp/paramtests && /tmp/paramtests
///
/// The reference numbers come from measuring the built library, not from reading
/// it: `bst_duration_scale` in the engine's `src/interp.c` makes duration
/// `(rate + 100) / 100`, and F0 was measured by autocorrelation on the output of
/// build 2006ENG. Both mismatches are silent when wrong — the voice speaks, at
/// the wrong pace or pitch — so the direction is pinned here.

@main
struct EngineParameterTests {

    static var failures: [String] = []
    static var checks = 0

    static func expect(_ got: Int, _ expected: Int, _ label: String) {
        checks += 1
        if got != expected {
            failures.append("\(label): got \(got), expected \(expected)")
            print("FAIL  \(label)  (got \(got), expected \(expected))")
        } else {
            print("PASS  \(label)")
        }
    }

    static func expectRange(_ got: Int, _ low: Int, _ high: Int, _ label: String) {
        checks += 1
        if got < low || got > high {
            failures.append("\(label): got \(got), expected \(low)...\(high)")
            print("FAIL  \(label)  (got \(got), expected \(low)...\(high))")
        } else {
            print("PASS  \(label)  (\(got))")
        }
    }

    static func main() {
        print("-- rate must go the opposite way to VoiceOver's --")
        // VoiceOver 0 is slowest. The engine slows down by going positive.
        expectRange(EngineParameters.engineRate(forVoiceOver: 0), 290, 300,
                    "VoiceOver 0 (slowest) is engine near-maximum")
        expect(EngineParameters.engineRate(forVoiceOver: 0.5), 0,
               "VoiceOver 0.5 (neutral) is engine nominal 0")
        expectRange(EngineParameters.engineRate(forVoiceOver: 1.0), -100, -99,
                    "VoiceOver 1.0 (fastest) is engine minimum")

        // The reported bug: 0 came out normal and 1.0 came out very slow, which
        // is what passing the value straight through did.
        checks += 1
        let atSlowest = EngineParameters.engineRate(forVoiceOver: 0)
        let atFastest = EngineParameters.engineRate(forVoiceOver: 1.0)
        if atSlowest > atFastest {
            print("PASS  slowest request yields the larger engine rate (was inverted)")
        } else {
            failures.append("rate direction: slowest=\(atSlowest) fastest=\(atFastest)")
            print("FAIL  slowest request yields the larger engine rate")
        }

        print("\n-- rate is monotonic, and always inside the usable band --")
        var previous = Int.max
        var monotonic = true
        for step in 0...20 {
            let rate = EngineParameters.engineRate(forVoiceOver: Double(step) / 20.0)
            if rate > previous { monotonic = false }
            if rate < -100 || rate > 300 {
                failures.append("rate out of band at \(step)/20: \(rate)")
                monotonic = false
            }
            previous = rate
        }
        checks += 1
        if monotonic {
            print("PASS  rate falls monotonically as VoiceOver rises, within -100...300")
        } else {
            print("FAIL  rate is not monotonic or left the usable band")
        }

        print("\n-- both scales are accepted --")
        expect(EngineParameters.engineRate(forVoiceOver: 50),
               EngineParameters.engineRate(forVoiceOver: 0.5),
               "50 and 0.5 are the same point")
        expect(EngineParameters.engineRate(forVoiceOver: 100),
               EngineParameters.engineRate(forVoiceOver: 1.0),
               "100 and 1.0 are the same point")

        print("\n-- pitch stays the same way round, above the voiced floor --")
        expect(EngineParameters.enginePitch(forVoiceOver: 0), 25,
               "VoiceOver 0 is the engine's voiced floor, not 0")
        expect(EngineParameters.enginePitch(forVoiceOver: 50), 50,
               "VoiceOver 50 is unchanged")
        expect(EngineParameters.enginePitch(forVoiceOver: 100), 100,
               "VoiceOver 100 is unchanged")

        checks += 1
        let low = EngineParameters.enginePitch(forVoiceOver: 0)
        let mid = EngineParameters.enginePitch(forVoiceOver: 50)
        let high = EngineParameters.enginePitch(forVoiceOver: 100)
        if low < mid && mid < high {
            print("PASS  pitch rises with the request (\(low) < \(mid) < \(high))")
        } else {
            failures.append("pitch not monotonic: \(low), \(mid), \(high)")
            print("FAIL  pitch rises with the request")
        }

        print("\n-- out-of-range input is clamped, not wrapped --")
        expect(EngineParameters.enginePitch(forVoiceOver: -50), 25, "negative pitch clamps")
        expect(EngineParameters.enginePitch(forVoiceOver: 500), 100, "excess pitch clamps")
        expect(EngineParameters.engineRate(forVoiceOver: -1), 300, "negative rate clamps slow")
        expect(EngineParameters.engineRate(forVoiceOver: 200), -100, "excess rate clamps fast")

        print("\n\(checks - failures.count)/\(checks) passed")
        if failures.isEmpty { exit(0) }
        print("\nFAILURES:")
        for failure in failures { print("  \(failure)") }
        exit(1)
    }
}
