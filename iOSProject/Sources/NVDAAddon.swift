import Foundation

/// Reads a whole NVDA addon and pulls the speech engines out of it.
///
/// An NVDA addon (`*.nvda-addon`) is an ordinary ZIP holding an NVDA driver
/// package: `manifest.ini`, some Python, and -- in the ones that carry a
/// synthesiser -- the engine's DLLs under `synthDrivers/`.
///
/// ⛔ **Nothing here decides by filename or size.** The twelve addons measured on
/// this machine disagree about where a DLL lives (depth 1 to 6), about
/// separators (some are Windows-built, with `\` where the zip spec wants `/`),
/// and about what counts as the engine's folder: `synthDrivers/` most of the
/// time, but `lib/stspeech/` in one and `lib/x86/pymupdf/` in another. Four of
/// the twelve contain no DLL at all, and the single largest DLL across all of
/// them belongs to a PDF library bundled with a screen-reading assistant. Every
/// one of those would mislead a rule based on names, paths or sizes.
///
/// So the archive is *searched*, and each candidate is offered to the engine.
/// `Identify` then answers by whether the file actually speaks, which is the
/// same test a hand-picked DLL gets -- an addon is just a box that may hold
/// several engines, so the import can return more than one.
enum NVDAAddon {

    /// A single engine module no larger than this is worth handing to the
    /// engine. Measured: the real Keynote Gold modules are 604 KB at most, and
    /// the largest module that is genuinely an engine is just under 4 MB. The
    /// files above this are dependencies -- a 25 MB PDF renderer, a 9.5 MB CPU
    /// emulator -- which the engine would reject anyway, so refusing them early
    /// only saves the cost of decompressing them.
    static let maxEngineModuleSize = 16 << 20

    /// The total that will be decompressed from one archive. A guard against a
    /// pathological file, not a real limit: the addons here peak at about 10 MB
    /// of modules actually worth trying.
    static let extractionBudget = 192 << 20

    /// An engine found inside the archive, with the bytes needed to store it.
    struct Engine {
        let word: ImportedWord
        /// The module itself -- the file the app would have been handed directly.
        let module: Data
        /// The shared core module, for the 1998 voices that need one.
        let core: Data?
    }

    /// What importing an addon did.
    enum Outcome {
        /// One or more engines were found. Usually one; an addon may carry several.
        case loaded([ImportedWord])
        /// A readable archive with nothing the engine can speak with. A real and
        /// common shape -- four of the twelve addons here contain no DLL at all.
        case noEngines(addonName: String, dllCount: Int)
        /// Not a zip, so not an addon.
        case notAnAddon
    }

    /// Whether these bytes look like an addon worth opening.
    ///
    /// Deliberately loose -- the extension is a hint, not a promise -- but the
    /// zip signature check saves handing a large non-zip to the reader.
    static func looksLikeAddon(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let bytes = [UInt8](data.prefix(4))
        if bytes == [0x50, 0x4b, 0x03, 0x04] || bytes == [0x50, 0x4b, 0x05, 0x06] {
            return true
        }
        // A zip may also start with a self-extracting stub, so fall back to the
        // same backwards scan the reader uses.
        return (try? Zip.entries(data))?.isEmpty == false
    }

    /// The name the addon gives itself, for the message shown after an import.
    ///
    /// Purely cosmetic and never used to decide anything, so a missing or
    /// unparseable manifest just means the caller falls back to the filename.
    static func manifestName(_ data: Data) -> String? {
        guard let entries = try? Zip.entries(data) else { return nil }
        guard let manifest = entries.first(where: {
            $0.name.lowercased() == "manifest.ini" && !$0.isDirectory
        }) else { return nil }
        guard let raw = try? Zip.data(data, entry: manifest) else { return nil }
        let text = String(decoding: raw, as: UTF8.self)
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("summary") else { continue }
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            var value = String(trimmed[trimmed.index(after: equals)...])
                .trimmingCharacters(in: .whitespaces)
            // NVDA manifests are read by configparser, where a value may be
            // quoted; strip that rather than showing the quotes.
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !value.isEmpty { return value }
        }
        return nil
    }

    /// Every engine the archive contains, in build order.
    static func engines(in data: Data, fileName: String) -> [Engine] {
        guard let entries = try? Zip.entries(data) else { return [] }

        // Candidates: any DLL, at any depth. Not just those under
        // `synthDrivers/`, because that is not where all of them live.
        let candidates = entries.filter {
            !$0.isDirectory
                && $0.name.lowercased().hasSuffix(".dll")
                && $0.uncompressedSize > 0
                && $0.uncompressedSize <= maxEngineModuleSize
        }
        guard !candidates.isEmpty else { return [] }

        // Largest first: an engine module is usually the biggest thing in the
        // driver, so this finds the answer sooner when the budget is reached.
        // It decides nothing -- only the order things are tried in.
        let ordered = candidates.sorted { $0.uncompressedSize > $1.uncompressedSize }

        var found: [Engine] = []
        var foundBuilds = Set<String>()
        // 1998 language modules whose shared core is somewhere in this archive.
        var waitingForCore: [(name: String, bytes: Data)] = []
        var spent = 0

        func add(_ word: ImportedWord, module: Data, core: Data?) {
            guard foundBuilds.insert(word.build).inserted else { return }
            found.append(Engine(word: word, module: module, core: core))
        }

        for entry in ordered {
            guard spent + entry.uncompressedSize <= extractionBudget else { break }
            guard let bytes = try? Zip.data(data, entry: entry) else { continue }
            spent += bytes.count

            switch Identify.file(bytes, fileName: entry.name) {
            case .identified(let word):
                add(word, module: bytes, core: nil)
            case .needsCore:
                waitingForCore.append((entry.name, bytes))
            case .ambiguous(let options):
                // A module that speaks as several builds is still usable; take
                // them all rather than guessing between them.
                for word in options { add(word, module: bytes, core: nil) }
            case .notEngineFile:
                continue
            }
        }

        // The 1998 voices need a second file beside them. Any other DLL in the
        // archive is tried in that role, which is how the engine's own `pairing`
        // works for hand-picked files.
        if !waitingForCore.isEmpty {
            let waitingNames = Set(waitingForCore.map(\.name))
            let others = ordered.filter { !waitingNames.contains($0.name) }
                .compactMap { entry -> (String, Data)? in
                    guard let bytes = try? Zip.data(data, entry: entry) else { return nil }
                    return (entry.name, bytes)
                }
            for waiting in waitingForCore {
                for (otherName, otherBytes) in others {
                    guard case .identified(let word) =
                        Identify.pairing(waiting.bytes, otherBytes,
                                         fileNameA: waiting.name, fileNameB: otherName)
                    else { continue }
                    add(word, module: waiting.bytes, core: otherBytes)
                    break
                }
            }
        }

        return found.sorted { $0.word.build < $1.word.build }
    }
}
