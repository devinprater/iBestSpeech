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

    public func synthesize(_ text: String) -> [Int16]? {
        guard let h = handle else { return nil }
        
        let cText = (text as NSString).utf8String
        let length = bst_length(h, cText)
        
        if length <= 0 { return nil }
        
        var pcm = [Int16](repeating: 0, count: Int(length))
        bst_say(h, cText, &pcm, length)
        
        return pcm
    }

    public static func availableBuilds() -> [String] {
        let count = bst_builds(nil, 0)
        if count <= 0 { return [] }
        
        var result = [String]()
        var names = [UnsafePointer<CChar>?](repeating: nil, count: Int(count))
        let actualCount = bst_builds(&names, count)
        
        for i in 0..<Int(actualCount) {
            if let name = names[i] {
                result.append(String(cString: name))
            }
        }
        return result
    }
}
