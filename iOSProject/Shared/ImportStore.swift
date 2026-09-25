import Foundation
import os

/// The user's imported engine files, kept where the extension can read them too.
///
/// The extension is a separate process from the app, so a file the user picks in
/// the app is invisible to the voice VoiceOver actually uses unless it is handed
/// over. An App Group container is the shared place both can open; the project
/// already declares `group.com.devin.ibestspeech` for exactly this kind of
/// hand-off.
///
/// ⛔ **This is why the App Group is load-bearing now.** Before this feature
/// nothing in the Swift read it — `make_sideload_ipa.py` strips it for free-account
/// sideloading and noted that the app had never been run without it. That is no
/// longer true: the App Group IS the channel between the app and the extension.
/// Without it the app can still import and preview a file from its own container,
/// but VoiceOver's copy of the voice cannot see it, so the voice does not appear
/// in Settings. A build meant for other people therefore needs the entitlement,
/// which means a paid account — which is the account TestFlight requires anyway.
///
/// Files are stored under the build name they resolved to, not their original
/// name: the build name is what the engine is asked for at synthesis time, and
/// it is derived from the file's own contents rather than from what the user
/// called it.
enum ImportStore {
    static let groupIdentifier = "group.com.devin.ibestspeech"

    /// Extensionless by design: the engine reads bytes, not names, and a name it
    /// recognises is one more thing that could disagree with the contents.
    static func fileName(for build: String) -> String { "\(build).bst" }
    static func coreFileName(for build: String) -> String { "\(build).core.bst" }

    /// The shared container, or nil when the build carries no App Group.
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)
    }

    /// True when app and extension can actually see the same files.
    ///
    /// False for a sideloaded build whose App Group was stripped, and that is the
    /// difference between "the voice works everywhere" and "the voice only works
    /// inside this app" — so it is surfaced rather than guessed at.
    static var isShared: Bool { containerURL != nil }

    /// Where imported engine files live.
    ///
    /// Inside the shared container when there is one, and in the app's own
    /// Documents directory when there is not, so that a build without the
    /// entitlement still imports and previews instead of failing outright. The
    /// extension resolves the same path, finds no shared container, and reads its
    /// own empty directory — which is why the UI has to say so.
    static func directory() -> URL? {
        let base: URL
        if let shared = containerURL {
            base = shared
        } else {
            guard let own = try? FileManager.default.url(for: .documentDirectory,
                                                         in: .userDomainMask,
                                                         appropriateFor: nil,
                                                         create: true) else { return nil }
            base = own
        }
        let dir = base.appendingPathComponent("EngineFiles", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func url(for build: String, core: Bool = false) -> URL? {
        guard let dir = directory() else { return nil }
        return dir.appendingPathComponent(core ? coreFileName(for: build) : fileName(for: build))
    }

    /// Copies a user-picked file into the shared container.
    ///
    /// A file handed over by the document picker lives outside the app's
    /// container and may be reclaimed, so it is copied rather than referenced.
    @discardableResult
    static func store(data: Data, build: String, core: Bool = false) -> Bool {
        guard let dest = url(for: build, core: core) else { return false }
        do {
            try data.write(to: dest, options: .atomic)
            return true
        } catch {
            Logger(subsystem: "com.devin.ibestspeech", category: "import")
                .error("could not store \(build, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    static func data(for build: String, core: Bool = false) -> Data? {
        guard let url = url(for: build, core: core) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func remove(build: String) {
        for core in [false, true] {
            if let url = url(for: build, core: core) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Every build the user has stored.
    ///
    /// Read from disk rather than remembered, so a file arriving by another route
    /// (a restore, a future share-sheet import) is not invisible here.
    static func storedBuilds() -> [String] {
        guard let dir = directory(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return [] }
        return names
            .filter { $0.hasSuffix(".bst") && !$0.hasSuffix(".core.bst") }
            .map { String($0.dropLast(4)) }
            .sorted()
    }

    static func hasCore(for build: String) -> Bool {
        guard let url = url(for: build, core: true) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }
}
