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

    /// Synthesizes `text` and returns the samples, or nil if the build produced none.
    ///
    /// bst_say drops whatever does not fit, so the length is taken first and the
    /// buffer sized to match. The C side may still write fewer samples than
    /// bst_length predicted; the returned array is trimmed to that count so
    /// callers never see a tail of silence presented as speech.
    public func synthesize(_ text: String) -> [Int16]? {
        guard let h = handle else { return nil }
        guard !text.isEmpty else { return nil }

        return text.withCString { cText in
            let length = bst_length(h, cText)
            guard length > 0 else { return nil }

            var pcm = [Int16](repeating: 0, count: Int(length))
            let written = pcm.withUnsafeMutableBufferPointer { buf in
                bst_say(h, cText, buf.baseAddress, length)
            }
            guard written > 0 else { return nil }

            if Int(written) < pcm.count {
                pcm.removeSubrange(Int(written)..<pcm.count)
            }
            return pcm
        }
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
