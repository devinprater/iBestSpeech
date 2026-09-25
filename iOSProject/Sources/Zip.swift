import Foundation

/// A minimal ZIP reader, sufficient for an NVDA addon.
///
/// NVDA addons are ordinary ZIP archives -- verified across the ten on this
/// machine: every entry is either stored or deflated, nothing exotic -- so this
/// reads the central directory rather than scanning for local headers, and hands
/// back the bytes of the entries it wants.
///
/// Two things about real addons that a naive reader gets wrong:
///
/// - Windows-built archives store **backslash** separators (`synthDrivers\x\dll`),
///   which the spec says must be forward slashes. Names are normalised here, so
///   the caller can match on `synthDrivers/` and be right either way.
/// - A zip may be preceded by a self-extracting stub, so the end-of-central-
///   directory record is found by scanning backwards, not assumed to be at the
///   end of the file.
public enum ZipError: Error, Equatable {
    case notAZip
    case malformed(String)
    case unsupportedCompression(Int)
    case entryTooLarge
}

public struct ZipEntry {
    /// Normalised to forward slashes.
    public let name: String
    public let uncompressedSize: Int
    public let compressedSize: Int
    public let compressionMethod: Int
    /// Byte offset of the entry's local header, straight from the directory.
    let localHeaderOffset: Int
    public var isDirectory: Bool { name.hasSuffix("/") }
}

public enum Zip {

    private static let endOfCentralDirectory: UInt32 = 0x0605_4b50
    private static let centralFileHeader: UInt32 = 0x0201_4b50
    private static let localFileHeader: UInt32 = 0x0403_4b50

    static let methodStored = 0
    static let methodDeflated = 8

    /// Refuses to expand a single entry past this, so a zip bomb is an error
    /// rather than a memory exhaustion. Generous: the largest binary in the
    /// addons here is under 2 MB.
    public static let maxEntrySize = 128 << 20

    /// Every entry in the archive, in directory order.
    public static func entries(_ data: Data) throws -> [ZipEntry] {
        let bytes = [UInt8](data)
        guard bytes.count >= 22 else { throw ZipError.notAZip }

        // The end-of-central-directory record is up to 22 bytes plus a comment
        // of up to 65535, so search that window backwards for the signature.
        guard let eocd = findEndRecord(bytes) else { throw ZipError.notAZip }

        let entryCount = Int(u16(bytes, eocd + 10))
        let directoryOffset = Int(u32(bytes, eocd + 16))

        guard directoryOffset <= bytes.count else {
            throw ZipError.malformed("central directory starts past the end")
        }

        var entries: [ZipEntry] = []
        var cursor = directoryOffset

        for _ in 0..<entryCount {
            guard cursor + 46 <= bytes.count, u32(bytes, cursor) == centralFileHeader else {
                throw ZipError.malformed("central directory entry \(entries.count) is not a header")
            }

            let method = Int(u16(bytes, cursor + 10))
            let compressedSize = Int(u32(bytes, cursor + 20))
            let uncompressedSize = Int(u32(bytes, cursor + 24))
            let nameLength = Int(u16(bytes, cursor + 28))
            let extraLength = Int(u16(bytes, cursor + 30))
            let commentLength = Int(u16(bytes, cursor + 32))
            let localOffset = Int(u32(bytes, cursor + 42))

            guard cursor + 46 + nameLength <= bytes.count else {
                throw ZipError.malformed("entry name runs past the end")
            }
            let rawName = String(decoding: bytes[(cursor + 46)..<(cursor + 46 + nameLength)],
                                 as: UTF8.self)

            entries.append(ZipEntry(name: normalise(rawName),
                                    uncompressedSize: uncompressedSize,
                                    compressedSize: compressedSize,
                                    compressionMethod: method,
                                    localHeaderOffset: localOffset))

            cursor += 46 + nameLength + extraLength + commentLength
        }

        return entries
    }

    /// The decompressed bytes of `entry`.
    ///
    /// The local header is re-read rather than trusted from the directory: its
    /// name and extra-field lengths are what locate the payload, and some writers
    /// store a different extra field in the two headers.
    public static func data(_ data: Data, entry: ZipEntry) throws -> Data {
        let bytes = [UInt8](data)

        guard entry.uncompressedSize <= maxEntrySize else { throw ZipError.entryTooLarge }

        let offset = entry.localHeaderOffset
        guard offset + 30 <= bytes.count, u32(bytes, offset) == localFileHeader else {
            throw ZipError.malformed("\(entry.name): no local header at \(offset)")
        }

        let nameLength = Int(u16(bytes, offset + 26))
        let extraLength = Int(u16(bytes, offset + 28))
        let start = offset + 30 + nameLength + extraLength

        switch entry.compressionMethod {
        case methodStored:
            guard start + entry.uncompressedSize <= bytes.count else {
                throw ZipError.malformed("\(entry.name): stored payload runs past the end")
            }
            return Data(bytes[start..<(start + entry.uncompressedSize)])

        case methodDeflated:
            // The compressed size comes from the DIRECTORY, which is the only
            // place it is reliable: a local header with a data descriptor has
            // zeros there. This is why the directory is read first.
            let length = entry.compressedSize
            guard start + length <= bytes.count else {
                throw ZipError.malformed("\(entry.name): deflated payload runs past the end")
            }
            // A stream of zero bytes is legal for an empty entry; inflate handles it.
            let compressed = Array(bytes[start..<(start + length)])
            let plain = try Deflate.inflate(compressed, limit: min(maxEntrySize, max(entry.uncompressedSize, 1)))
            guard plain.count == entry.uncompressedSize else {
                throw ZipError.malformed(
                    "\(entry.name): inflated to \(plain.count) bytes, directory says \(entry.uncompressedSize)")
            }
            return Data(plain)

        default:
            throw ZipError.unsupportedCompression(entry.compressionMethod)
        }
    }

    // MARK: - Helpers

    /// Backslashes become slashes, so a Windows-built archive and a well-formed
    /// one look the same to the caller.
    static func normalise(_ name: String) -> String {
        name.replacingOccurrences(of: "\\", with: "/")
    }

    static func findEndRecord(_ bytes: [UInt8]) -> Int? {
        let minimum = 22
        guard bytes.count >= minimum else { return nil }
        let earliest = max(0, bytes.count - minimum - 65535)
        var i = bytes.count - minimum
        while i >= earliest {
            if u32(bytes, i) == endOfCentralDirectory { return i }
            i -= 1
        }
        return nil
    }

    static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}
