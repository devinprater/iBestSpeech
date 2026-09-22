import OpenBST

import Foundation

print("Checking available builds...")
let builds = OpenBST.availableBuilds()
print("Builds: \(builds)")

guard let bst = OpenBST(build: "2006ENG") else {
    print("Failed to open 2006ENG")
    exit(1)
}

print("Sample Rate: \(bst.sampleRate) Hz")

let text = "Hello from iOS Swift bridge."
if let samples = bst.synthesize(text) {
    print("Successfully synthesized '\(text)'")
    print("Sample count: \(samples.count)")
} else {
    print("Synthesis failed")
    exit(1)
}

print("POC compilation and basic synthesis link verified.")
