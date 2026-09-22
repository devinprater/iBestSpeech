import Foundation

public class OpenBST {
    private var handle: OpaquePointer?

    public enum Parameter: String {
        case pitch, top, level, voice, rate
    }

    public init?(build: String) {
        self.handle = bst_open(build)
        if self.handle == nil {
            return nil
        }
    }

    deinit {
        if let h = handle {
            bst_close(h)
        }
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

    /// Synthesizes `text` as UTF-8.
    public func synthesize(_ text: String) -> [Int16]? {
        guard !text.isEmpty else { return nil }
        return Array(text.utf8).withUnsafeBufferPointer { synthesize(bytes: $0) }
    }

    /// Synthesizes text supplied as raw bytes.
    ///
    /// Several builds read a legacy single-byte code page, so the caller encodes
    /// into that page and hands the bytes over rather than the string: a String
    /// would go through UTF-8 and the engine would read it as silence.
    ///
    /// bst_length is taken first because bst_say drops whatever does not fit, and
    /// the result is trimmed to the count actually written so a caller never sees
    /// a tail of silence presented as speech.
    public func synthesize(bytes: UnsafeBufferPointer<UInt8>) -> [Int16]? {
        guard let h = handle, !bytes.isEmpty else { return nil }

        // The C API takes a NUL-terminated string and has no length parameter, so
        // an embedded NUL would silently truncate. Reject rather than half-speak.
        guard !bytes.contains(0) else { return nil }

        var terminated = [CChar](repeating: 0, count: bytes.count + 1)
        for (i, b) in bytes.enumerated() { terminated[i] = CChar(bitPattern: b) }

        return terminated.withUnsafeBufferPointer { buf -> [Int16]? in
            guard let base = buf.baseAddress else { return nil }

            let length = bst_length(h, base)
            guard length > 0 else { return nil }

            var pcm = [Int16](repeating: 0, count: Int(length))
            let written = pcm.withUnsafeMutableBufferPointer { out in
                bst_say(h, base, out.baseAddress, length)
            }
            guard written > 0 else { return nil }

            if Int(written) < pcm.count {
                pcm.removeSubrange(Int(written)..<pcm.count)
            }
            return pcm
        }
    }

    /// True when this build produces speech for `bytes`.
    ///
    /// Used to decide whether a code-page encoding is usable before committing to
    /// it: a build handed a script it does not read returns a sample count and
    /// then all zeros, so a length check alone is not enough.
    public func producesSpeech(for bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard let samples = synthesize(bytes: bytes), !samples.isEmpty else { return false }
        return samples.contains { $0 != 0 }
    }

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
