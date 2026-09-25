import Foundation

/// A word the user loaded from their own copy of the engine.
///
/// A build is one file, except the six 1998 modules, which keep their excitation
/// and gain tables in a shared core file and therefore need two. Both cases are
/// the same shape here: a primary file, and optionally the core beside it.
struct ImportedWord: Identifiable, Hashable {
    /// The build name the file resolved to, e.g. `2006ENG`.
    let build: String
    /// The name the file had where the user got it, for display.
    let fileName: String
    /// Byte count, shown so the user can tell two copies apart.
    let byteCount: Int
    /// The paired core file, for the 1998 modules only.
    var coreFileName: String?
    var coreByteCount: Int?

    var id: String { build }

    var displayName: String {
        VoiceCatalog.displayName(for: build)
    }

    /// One line describing the import, used in the list and in VoiceOver.
    var summary: String {
        var text = "\(displayName), \(byteCount) bytes, from \(fileName)"
        if let coreFileName {
            text += ", with \(coreFileName)"
        }
        return text
    }
}

/// What happened when the user picked a file.
///
/// The user's file is not trusted to be what its name says, so the outcome is
/// stated plainly rather than folded into an optional: "this is not a Keynote
/// Gold file" and "this is a Keynote Gold file, but it is one of the six that
/// need a second file" are different problems with different fixes.
enum ImportOutcome {
    /// Exactly one build spoke from this file.
    case identified(ImportedWord)
    /// More than one build spoke. Kept because it can genuinely happen; the
    /// caller decides which to prefer rather than the import guessing.
    case ambiguous([ImportedWord])
    /// A 1998 language module, whose core file is still missing.
    case needsCore(build: String, fileName: String, byteCount: Int)
    /// Nothing spoke from these bytes.
    case notEngineFile(fileName: String, byteCount: Int)

    var word: ImportedWord? {
        if case .identified(let w) = self { return w }
        return nil
    }
}
