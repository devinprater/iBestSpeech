import Foundation

/// Works out what a file the user picked actually is.
///
/// The user's file is trusted to be *some* copy of the engine, not to be the one
/// its name claims. Everything here is decided by what the engine can do with the
/// bytes, never by the filename.
///
/// ⛔ Opening the file is not identifying it. Measured on the built library: a
/// 2006 English module's image is accepted by `bst_open_image` for all thirteen
/// 2006 builds and for 1995 as well, because `bst_image_init_map` only parses the
/// section header and every one of those modules shares its shape. What separates
/// them is whether any **sound** comes out — and sound means non-zero samples,
/// because a build handed the wrong tables returns a plausible sample count over
/// an all-zero buffer. Both facts are measured, not assumed.
///
/// Measured outcome on all twenty builds, using an image reconstructed from each
/// build's own tables:
///
/// - 14 builds resolve to exactly one speaking build, and it is the right one.
/// - The six 1998 modules speak from nothing until their shared core file is
///   supplied as well (the engine rejects them outright without it, which is the
///   `needsCore` case, not a failure).
/// - 1 MB of zeros, 500 KB of random bytes, and a markdown file all resolve to
///   nothing — `notEngineFile`.
enum Identify {
    /// The phrases a build is asked to say while being identified.
    ///
    /// Three rather than one because a single phrase can be silent on a build for
    /// reasons of its own — a 2006 module truncates at a comma, and the 1998
    /// English build mis-reads some bare digits — and those builds are still
    /// perfectly good. Any one of the three producing sound is enough, so a single
    /// quirk cannot make a valid file look like junk.
    static let probes = [
        "Hello world",
        "Read 6- 23 PM",
        "The quick brown fox",
    ]

    /// What a file resolved to.
    static func file(_ data: Data, fileName: String = "file") -> ImportOutcome {
        guard !data.isEmpty else {
            return .notEngineFile(fileName: fileName, byteCount: 0)
        }

        var speakers: [ImportedWord] = []
        var neModules: [String] = []

        for build in OpenBST.availableBuilds() {
            guard let handle = OpenBST(build: build, image: data) else {
                // The engine refused the image. For a 1998 module that is the
                // expected answer when the core file is missing, so the shape is
                // checked separately below rather than treated as junk here.
                continue
            }
            if speaks(handle) {
                speakers.append(ImportedWord(build: build,
                                            fileName: fileName,
                                            byteCount: data.count))
            }
            if IsSixteenBitModule(data) { neModules.append(build) }
        }

        if speakers.count == 1 {
            return .identified(speakers[0])
        }
        if speakers.count > 1 {
            return .ambiguous(speakers)
        }

        // Nothing spoke. If the file is a 16-bit module then it is a 1998
        // language module whose shared core file has not been supplied yet,
        // which is a fixable problem rather than a wrong file.
        if IsSixteenBitModule(data) {
            return .needsCore(build: "", fileName: fileName, byteCount: data.count)
        }

        return .notEngineFile(fileName: fileName, byteCount: data.count)
    }

    /// Completes an import once the core file has been supplied too.
    ///
    /// Both files are tried in both roles, because the user picks them in
    /// whatever order they were found and the engine does not care which is
    /// which — the core tables are looked up by offset in whichever file is
    /// passed as the core.
    static func pairing(_ a: Data, _ b: Data,
                        fileNameA: String, fileNameB: String) -> ImportOutcome {
        for build in OpenBST.availableBuilds() {
            for (image, core) in [(a, b), (b, a)] {
                guard let handle = OpenBST(build: build, image: image, core: core) else { continue }
                if speaks(handle) {
                    return .identified(ImportedWord(build: build,
                                                    fileName: fileNameA,
                                                    byteCount: image.count,
                                                    coreFileName: fileNameB,
                                                    coreByteCount: core.count))
                }
            }
        }
        return .notEngineFile(fileName: fileNameA, byteCount: a.count + b.count)
    }

    /// Whether a build actually produces sound.
    ///
    /// Non-zero samples, not a sample count: the engine reports a length for an
    /// utterance it renders as silence, so a length check would call a wrong
    /// pairing a working one.
    static func speaks(_ handle: OpenBST) -> Bool {
        for probe in probes {
            guard let samples = handle.synthesize(probe), !samples.isEmpty else { continue }
            if samples.contains(where: { $0 != 0 }) { return true }
        }
        return false
    }

    /// True when the bytes are a 16-bit (NE) module.
    ///
    /// The 1998 modules are 16-bit and everything else is 32-bit, which is what
    /// makes this a useful signal: it identifies the generation of a file that
    /// cannot be opened yet. Reads the same header field `bst_image_init_ne` does
    /// — the offset at 0x3C, then the signature there.
    static func IsSixteenBitModule(_ data: Data) -> Bool {
        guard data.count > 0x40 else { return false }
        let bytes = [UInt8](data.prefix(0x40))
        let offset = Int(bytes[0x3C]) | (Int(bytes[0x3D]) << 8)
            | (Int(bytes[0x3E]) << 16) | (Int(bytes[0x3F]) << 24)
        guard offset > 0, offset + 2 <= data.count else { return false }
        let signature = [UInt8](data[offset..<(offset + 2)])
        return signature[0] == UInt8(ascii: "N") && signature[1] == UInt8(ascii: "E")
    }
}
