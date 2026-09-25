import Foundation

/// Raw DEFLATE (RFC 1951) decompression.
///
/// Hand-rolled on purpose. A zip entry's payload is a *raw* deflate stream, and
/// neither Foundation nor the Swift toolchain offers raw inflate here:
/// `import zlib` is not available in the Linux Swift toolchain, and Foundation's
/// decompression API has no raw-deflate case (it wants a zlib or gzip header).
/// Wrapping the system zlib instead would also give the host and the device
/// different implementations, and this project's whole verification story is
/// that the shipping file is exercised on Linux before it ships. So this is pure
/// Swift, identical in both places, and testable against `zlib` from Python.
///
/// The decoder follows the structure of Mark Adler's `puff.c` -- canonical
/// Huffman codes decoded bit by bit, no lookup tables. Slower than a table-driven
/// inflate, which does not matter for archives of a few megabytes, and easier to
/// check by reading.
public enum InflateError: Error, Equatable {
    case truncated
    case badBlockType(Int)
    case storedLengthMismatch
    case invalidCode
    case incompleteCode
    case outputLimitExceeded
}

public enum Deflate {

    /// Decompresses a raw deflate stream.
    ///
    /// `limit` guards against a hostile or corrupt archive that declares a tiny
    /// compressed size and expands without bound. Exceeding it is an error, not
    /// a truncation, so a bomb is refused rather than half-produced.
    public static func inflate(_ input: [UInt8], limit: Int = 256 << 20) throws -> [UInt8] {
        var state = Inflate(input: input, limit: limit)
        return try state.run()
    }

    /// Convenience for the common case.
    public static func inflate(_ data: Data, limit: Int = 256 << 20) throws -> Data {
        Data(try inflate([UInt8](data), limit: limit))
    }

    // MARK: - The decoder

    private struct Inflate {
        let input: [UInt8]
        let limit: Int

        /// Byte cursor, and how far into that byte the next bit sits (LSB first).
        var byteIndex = 0
        var bitIndex = 0

        var output: [UInt8] = []

        init(input: [UInt8], limit: Int) {
            self.input = input
            self.limit = limit
            self.output.reserveCapacity(min(input.count * 4, 1 << 20))
        }

        // MARK: Bits

        /// Reads `count` bits, least significant first, as DEFLATE stores them.
        mutating func bits(_ count: Int) throws -> Int {
            guard count > 0 else { return 0 }
            var value = 0
            for i in 0..<count {
                guard byteIndex < input.count else { throw InflateError.truncated }
                let bit = (input[byteIndex] >> UInt8(bitIndex)) & 1
                value |= Int(bit) << i
                bitIndex += 1
                if bitIndex == 8 {
                    bitIndex = 0
                    byteIndex += 1
                }
            }
            return value
        }

        /// Discards the rest of the current byte. Stored blocks begin on a byte
        /// boundary, so this is required before reading one.
        mutating func alignToByte() {
            if bitIndex != 0 {
                bitIndex = 0
                byteIndex += 1
            }
        }

        mutating func byte() throws -> UInt8 {
            guard byteIndex < input.count else { throw InflateError.truncated }
            let b = input[byteIndex]
            byteIndex += 1
            return b
        }

        // MARK: Output

        mutating func emit(_ value: UInt8) throws {
            guard output.count < limit else { throw InflateError.outputLimitExceeded }
            output.append(value)
        }

        /// Back-references may overlap the bytes they are producing, which is how
        /// DEFLATE encodes a run: copy one byte at a time, not in a block.
        mutating func copyBack(distance: Int, length: Int) throws {
            guard distance >= 1, distance <= output.count else { throw InflateError.invalidCode }
            guard output.count + length <= limit else { throw InflateError.outputLimitExceeded }
            let start = output.count - distance
            for i in 0..<length {
                output.append(output[start + i])
            }
        }

        // MARK: Blocks

        mutating func run() throws -> [UInt8] {
            while true {
                let final = try bits(1)
                let type = try bits(2)
                switch type {
                case 0:
                    try storedBlock()
                case 1:
                    try huffmanBlock(literalLengths: Deflate.fixedLiteralLengths,
                                     distanceLengths: Deflate.fixedDistanceLengths)
                case 2:
                    let (ll, dist) = try dynamicTables()
                    try huffmanBlock(literalLengths: ll, distanceLengths: dist)
                default:
                    throw InflateError.badBlockType(type)
                }
                if final == 1 { break }
            }
            return output
        }

        /// An uncompressed block: a length and its complement, then the bytes.
        mutating func storedBlock() throws {
            alignToByte()
            let lenLow = Int(try byte())
            let lenHigh = Int(try byte())
            let length = lenLow | (lenHigh << 8)
            let nLow = Int(try byte())
            let nHigh = Int(try byte())
            let complement = nLow | (nHigh << 8)

            // The complement is the spec's own integrity check; a mismatch means
            // the stream is corrupt or we are misaligned.
            guard (length ^ 0xFFFF) == complement else { throw InflateError.storedLengthMismatch }
            guard byteIndex + length <= input.count else { throw InflateError.truncated }

            for _ in 0..<length {
                try emit(input[byteIndex])
                byteIndex += 1
            }
        }

        /// Decodes literal/length and distance pairs until the end-of-block code.
        mutating func huffmanBlock(literalLengths: [Int], distanceLengths: [Int]) throws {
            let literal = try Huffman(lengths: literalLengths)
            let distance = try Huffman(lengths: distanceLengths)

            while true {
                let symbol = try literal.decode(&self)

                if symbol < 256 {
                    try emit(UInt8(symbol))
                    continue
                }
                if symbol == 256 { return }   // end of block

                let index = symbol - 257
                guard index >= 0, index < Deflate.lengthBase.count else { throw InflateError.invalidCode }
                let length = Deflate.lengthBase[index] + (try bits(Deflate.lengthExtra[index]))

                let distSymbol = try distance.decode(&self)
                guard distSymbol < Deflate.distanceBase.count else { throw InflateError.invalidCode }
                let back = Deflate.distanceBase[distSymbol] + (try bits(Deflate.distanceExtra[distSymbol]))

                try copyBack(distance: back, length: length)
            }
        }

        /// Reads the code-length code, then the literal and distance code lengths
        /// it describes. The two are interleaved in one run-length encoded stream.
        mutating func dynamicTables() throws -> ([Int], [Int]) {
            let literalCount = try bits(5) + 257
            let distanceCount = try bits(5) + 1
            let codeLengthCount = try bits(4) + 4

            guard codeLengthCount <= Deflate.codeLengthOrder.count else { throw InflateError.invalidCode }

            var codeLengths = [Int](repeating: 0, count: 19)
            for i in 0..<codeLengthCount {
                codeLengths[Deflate.codeLengthOrder[i]] = try bits(3)
            }

            let codeLengthCode = try Huffman(lengths: codeLengths)

            let total = literalCount + distanceCount
            var lengths = [Int]()
            lengths.reserveCapacity(total)

            while lengths.count < total {
                let symbol = try codeLengthCode.decode(&self)

                if symbol < 16 {
                    lengths.append(symbol)
                    continue
                }

                let repeatCount: Int
                var value = 0
                switch symbol {
                case 16:
                    // Repeat the previous length. There must be one to repeat.
                    guard let last = lengths.last else { throw InflateError.invalidCode }
                    repeatCount = 3 + (try bits(2))
                    value = last
                case 17:
                    repeatCount = 3 + (try bits(3))
                case 18:
                    repeatCount = 11 + (try bits(7))
                default:
                    throw InflateError.invalidCode
                }

                guard lengths.count + repeatCount <= total else { throw InflateError.invalidCode }
                for _ in 0..<repeatCount { lengths.append(value) }
            }

            let literal = Array(lengths[0..<literalCount])
            let distance = Array(lengths[literalCount..<total])

            // A distance code with no codes at all is legal when the block has no
            // back-references; Huffman tolerates it and any use is an error.
            return (literal, distance)
        }
    }

    // MARK: - Huffman

    /// A canonical Huffman code: how many codes of each length, and which symbol
    /// each one, in order.
    private struct Huffman {
        static let maxBits = 15
        var count = [Int](repeating: 0, count: maxBits + 1)
        var symbol: [Int] = []
        /// True when no code was defined at all (an unused distance alphabet).
        var isEmpty = false

        init(unused: Void) {}

        init(lengths: [Int]) throws {
            symbol = [Int](repeating: 0, count: lengths.count)
            for length in lengths {
                guard length >= 0, length <= Huffman.maxBits else { throw InflateError.invalidCode }
                count[length] += 1
            }

            // No codes at all: legal, and any attempt to decode is the caller's bug.
            if count[0] == lengths.count {
                isEmpty = true
                return
            }

            // `left` catches both over-subscribed (negative) and incomplete codes.
            var left = 1
            for length in 1...Huffman.maxBits {
                left <<= 1
                left -= count[length]
                if left < 0 { throw InflateError.invalidCode }
            }

            // An incomplete code is permitted only when it is a single one-bit
            // code -- which is how a block with exactly one distance code encodes
            // it. Anything else incomplete is a corrupt stream.
            if left > 0 && !(count[0] + count[1] == lengths.count && count[1] == 1) {
                throw InflateError.incompleteCode
            }

            var offsets = [Int](repeating: 0, count: Huffman.maxBits + 2)
            for length in 1...Huffman.maxBits {
                offsets[length + 1] = offsets[length] + count[length]
            }
            for (index, length) in lengths.enumerated() where length != 0 {
                symbol[offsets[length]] = index
                offsets[length] += 1
            }
        }

        /// Walks the code one bit at a time, which needs no lookup table.
        func decode(_ state: inout Inflate) throws -> Int {
            var code = 0
            var first = 0
            var index = 0

            for length in 1...Huffman.maxBits {
                code |= try state.bits(1)
                let count = self.count[length]
                if code - count < first {
                    return symbol[index + (code - first)]
                }
                index += count
                first += count
                first <<= 1
                code <<= 1
            }
            throw InflateError.invalidCode
        }
    }

    // MARK: - Tables (RFC 1951)

    static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                             35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                              3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    static let distanceBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
                               257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
                               8193, 12289, 16385, 24577]
    static let distanceExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
                                7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    static let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    /// The fixed literal/length code: 0-143 are 8 bits, 144-255 are 9, 256-279 are
    /// 7, 280-287 are 8.
    static let fixedLiteralLengths: [Int] = {
        var lengths = [Int](repeating: 0, count: 288)
        for i in 0...143 { lengths[i] = 8 }
        for i in 144...255 { lengths[i] = 9 }
        for i in 256...279 { lengths[i] = 7 }
        for i in 280...287 { lengths[i] = 8 }
        return lengths
    }()

    /// The fixed distance code: 32 codes of 5 bits.
    static let fixedDistanceLengths: [Int] = {
        [Int](repeating: 5, count: 32)
    }()
}
