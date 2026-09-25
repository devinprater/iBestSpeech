import Foundation

/// The engine, as a Swift object.
///
/// One handle holds one build: one language, one set of tables. Opening one is
/// cheap — measured at 0.05 ms including closing — but it is not free, so a
/// caller synthesizing several parts of one utterance should keep it open rather
/// than reopening per part.
///
/// A handle can be opened two ways: from the tables compiled into the library
/// (`init?(build:)`), or from a file the caller supplies (`init?(build:image:)`).
/// The second is what lets a shipped build carry no third-party table data at
/// all — see `Identify` below.
public class OpenBST {
    private var handle: OpaquePointer?

    /// Memory the engine reads the tables out of, when they came from a file.
    ///
    /// ⛔ The engine does **not** copy the image; `bst_image_init_map` stores the
    /// pointer it was handed (`img->image = d`) and every table read afterwards
    /// goes through it. A Swift `Data` passed to `withUnsafeBytes` is only
    /// guaranteed for the duration of that call, so handing the engine a `Data`
    /// directly would leave it reading memory that may have moved or been freed —
    /// which faults at an unpredictable later moment, not at the call. The bytes
    /// are therefore copied into an allocation this object owns and frees only
    /// after `bst_close`.
    private var owned: UnsafeMutableRawPointer?

    /// The paired core file, for the six 1998 modules. Same ownership rule.
    private var ownedCore: UnsafeMutableRawPointer?

    public enum Parameter: String {
        case pitch, top, level, voice, rate
    }

    public init?(build: String) {
        self.handle = bst_open(build)
        if self.handle == nil { return nil }
    }

    /// Opens `build` against tables read out of the caller's own file.
    ///
    /// `core` is the shared core module the six 1998 builds keep their excitation
    /// and gain tables in; those builds are rejected by the engine without it.
    /// Every other build ignores it.
    public init?(build: String, image: Data, core: Data? = nil) {
        guard !image.isEmpty else { return nil }

        let imagePtr = Self.copy(image)
        guard let imagePtr else { return nil }

        var corePtr: UnsafeMutableRawPointer?
        if let core, !core.isEmpty {
            corePtr = Self.copy(core)
            if corePtr == nil { imagePtr.deallocate(); return nil }
        }

        let opened: OpaquePointer? = imagePtr.withMemoryRebound(to: UInt8.self, capacity: image.count) { raw -> OpaquePointer? in
            if let corePtr {
                return corePtr.withMemoryRebound(to: UInt8.self, capacity: core?.count ?? 0) { rawCore in
                    bst_open_images(build, raw, image.count, rawCore, core?.count ?? 0)
                }
            }
            return bst_open_images(build, raw, image.count, nil, 0)
        }
        guard let opened else {
            imagePtr.deallocate()
            corePtr?.deallocate()
            return nil
        }

        self.owned = imagePtr
        self.ownedCore = corePtr
        self.handle = opened
    }

    deinit {
        if let h = handle { bst_close(h) }
        // Freed after the close, never before: the handle is still reading them.
        owned?.deallocate()
        ownedCore?.deallocate()
    }

    /// Copies bytes into an allocation that will not move.
    private static func copy(_ data: Data) -> UnsafeMutableRawPointer? {
        guard let ptr = UnsafeMutableRawPointer.allocate(byteCount: data.count,
                                                         alignment: 16) as UnsafeMutableRawPointer?
        else { return nil }
        data.withUnsafeBytes { src in
            if let base = src.baseAddress { ptr.copyMemory(from: base, byteCount: data.count) }
        }
        return ptr
    }

    public var sampleRate: Int {
        guard let h = handle else { return 0 }
        return Int(bst_rate(h))
    }

    public func set(_ param: Parameter, _ value: Int) {
        guard let h = handle else { return }
        bst_set(h, param.rawValue, Int32(value))
    }

    public func get(_ param: Parameter) -> Int {
        guard let h = handle else { return 0 }
        return Int(bst_get(h, param.rawValue))
    }

    // MARK: - Synthesis

    /// Synthesizes `text`, which the engine reads as UTF-8.
    ///
    /// `withCString` hands over a NUL-terminated UTF-8 buffer directly, so this
    /// copies nothing — the obvious `Array(text.utf8)` followed by an allocation
    /// into `CChar` made two copies of every utterance for no benefit.
    ///
    /// An embedded NUL would truncate silently at the C boundary, so it is
    /// rejected rather than half-spoken; comparing `strlen` against the UTF-8
    /// length detects one during the same pass that already walks the buffer.
    public func synthesize(_ text: String) -> [Int16]? {
        guard !text.isEmpty else { return nil }
        return text.withCString { cString -> [Int16]? in
            guard strlen(cString) == text.utf8.count else { return nil }
            return synthesize(terminated: cString)
        }
    }

    /// Synthesizes text supplied as raw bytes.
    ///
    /// Several builds read a legacy single-byte code page, so the caller encodes
    /// into that page and hands over bytes rather than a String: a String would go
    /// through UTF-8 and the engine would read it as silence.
    public func synthesize(bytes: UnsafeBufferPointer<UInt8>) -> [Int16]? {
        // The handle is re-checked in the shared tail; here it only decides
        // whether to bother building the buffer.
        guard handle != nil, !bytes.isEmpty, !bytes.contains(0) else { return nil }

        var terminated = bytes.map { CChar(bitPattern: $0) }
        terminated.append(0)
        return terminated.withUnsafeBufferPointer { synthesize(terminated: $0.baseAddress!) }
    }

    /// The shared tail of both paths.
    ///
    /// `bst_length` is asked first because `bst_say` drops whatever does not fit,
    /// and the result is trimmed to the count actually written so a caller never
    /// sees a tail of silence presented as speech. Asking for the length costs one
    /// extra pass — about 2 ms for a long paragraph — which is worth paying to
    /// keep from losing the end of an utterance.
    private func synthesize(terminated: UnsafePointer<CChar>) -> [Int16]? {
        guard let h = handle else { return nil }

        let length = bst_length(h, terminated)
        guard length > 0 else { return nil }

        var pcm = [Int16](repeating: 0, count: Int(length))
        let written = pcm.withUnsafeMutableBufferPointer { out in
            bst_say(h, terminated, out.baseAddress, length)
        }
        guard written > 0 else { return nil }

        if Int(written) < pcm.count {
            pcm.removeSubrange(Int(written)..<pcm.count)
        }
        return pcm
    }

    /// True when this build produces speech for `bytes`.
    ///
    /// Used to decide whether a code-page encoding is usable before committing to
    /// it: a build handed a script it does not read returns a sample count and then
    /// all zeros, so a length check alone is not enough.
    public func producesSpeech(for bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard let samples = synthesize(bytes: bytes), !samples.isEmpty else { return false }
        return samples.contains { $0 != 0 }
    }

    /// True when this build produces speech for `text`.
    public func producesSpeech(for text: String) -> Bool {
        guard let samples = synthesize(text), !samples.isEmpty else { return false }
        return samples.contains { $0 != 0 }
    }

    // MARK: - Library

    /// The builds this library carries, newest generation first.
    public static func availableBuilds() -> [String] {
        let count = bst_builds(nil, 0)
        guard count > 0 else { return [] }

        var names = [UnsafePointer<CChar>?](repeating: nil, count: Int(count))
        let actualCount = names.withUnsafeMutableBufferPointer { buf in
            bst_builds(buf.baseAddress, count)
        }
        guard actualCount > 0 else { return [] }

        return (0..<Int(min(actualCount, count))).compactMap { i in
            names[i].map { String(cString: $0) }
        }
    }
}
