import Foundation
import CoreFoundation
import CryptoKit

private enum LowercaseHex {
    static let digits = Array("0123456789abcdef".utf8)
}

public extension Data {
    var sha256Hex: String {
        var output = [UInt8]()
        output.reserveCapacity(64)
        for byte in SHA256.hash(data: self) {
            output.append(LowercaseHex.digits[Int(byte >> 4)])
            output.append(LowercaseHex.digits[Int(byte & 15)])
        }
        return String(decoding: output, as: UTF8.self)
    }
}

public struct ScriptLocation: Encodable, Sendable, Hashable {
    public let sourceFile: String
    public let sourceSHA256: String
    public let byteOffset: Int
    public let byteLength: Int
    public let rangeSHA256: String
    public let lineNumber: Int

    package init(sourceFile: String, sourceSHA256: String, byteOffset: Int, byteLength: Int,
                 rangeSHA256: String, lineNumber: Int) {
        self.sourceFile = sourceFile
        self.sourceSHA256 = sourceSHA256
        self.byteOffset = byteOffset
        self.byteLength = byteLength
        self.rangeSHA256 = rangeSHA256
        self.lineNumber = lineNumber
    }
}

public struct ScriptScalar: Sendable {
    public let value: Unicode.Scalar
    public let bytes: Range<Int>
}

/// Original scalar-to-byte boundaries, never obtained by re-encoding CP932 text.
public struct ScriptSource: Sendable {
    public let relativePath: String
    public let data: Data
    public let sha256: String
    public let encoding: String
    public let encodingStatus: EvidenceStatus
    public let bomBytes: Int
    public let scalars: [ScriptScalar]
    public var decodedText: String { String(String.UnicodeScalarView(scalars.map(\.value))) }

    public init(data: Data, relativePath: String) throws {
        _ = try SafeDirectory.components(relativePath)
        guard data.count <= 16 * 1024 * 1024 else { throw ResourceError.rejected("script_source_byte_limit") }
        self.data = data; self.relativePath = relativePath; sha256 = data.sha256Hex
        let bytes = Array(data)
        if data.starts(with: [0xff,0xfe]) { encoding = "utf-16-le"; bomBytes = 2 }
        else if data.starts(with: [0xfe,0xff]) { encoding = "utf-16-be"; bomBytes = 2 }
        else if data.starts(with: [0xef,0xbb,0xbf]) { encoding = "utf-8"; bomBytes = 3 }
        else { encoding = "cp932"; bomBytes = 0 }
        encodingStatus = bomBytes == 0 ? .inferred : .verified
        var output: [ScriptScalar] = [], offset = bomBytes
        let clock = ContinuousClock(), started = ContinuousClock.now
        let dosJapanese = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(0x0420))
        let littleEndian = data.starts(with: [0xff,0xfe])
        var cache: [UInt16: Unicode.Scalar] = [:]
        while offset < bytes.count {
            if output.count % 4096 == 0 {
                guard !Task.isCancelled else { throw ResourceError.rejected("script_decode_cancelled") }
                guard clock.now - started < .seconds(10) else { throw ResourceError.rejected("script_decode_time_limit") }
            }
            let start = offset
            let scalar: Unicode.Scalar
            if encoding.hasPrefix("utf-16") {
                func unit(_ at: Int) throws -> UInt16 {
                    guard at < bytes.count - 1 else { throw ResourceError.rejected("odd_utf16_length") }
                    return littleEndian ? UInt16(bytes[at]) | UInt16(bytes[at+1]) << 8 : UInt16(bytes[at]) << 8 | UInt16(bytes[at+1])
                }
                let first = try unit(offset); offset += 2
                var value = UInt32(first)
                if (0xd800...0xdbff).contains(first) {
                    let second = try unit(offset)
                    guard (0xdc00...0xdfff).contains(second) else { throw ResourceError.rejected("invalid_utf16_surrogate") }
                    value = 0x10000 + (UInt32(first) - 0xd800) * 1024 + UInt32(second) - 0xdc00; offset += 2
                } else if (0xdc00...0xdfff).contains(first) { throw ResourceError.rejected("unpaired_utf16_surrogate") }
                guard let converted = Unicode.Scalar(value) else { throw ResourceError.rejected("invalid_unicode_scalar") }
                scalar = converted
            } else if encoding == "utf-8" {
                let first = bytes[offset]
                let length = first < 0x80 ? 1 : (0xc2...0xdf).contains(first) ? 2 : (0xe0...0xef).contains(first) ? 3 : (0xf0...0xf4).contains(first) ? 4 : 0
                guard length > 0, length <= bytes.count - offset,
                      let string = String(data: Data(bytes[offset..<offset+length]), encoding: .utf8), string.unicodeScalars.count == 1,
                      let converted = string.unicodeScalars.first else { throw ResourceError.rejected("invalid_utf8_sequence") }
                scalar = converted; offset += length
            } else {
                let first = bytes[offset]
                let length = (0x81...0x9f).contains(first) || (0xe0...0xfc).contains(first) ? 2 : 1
                guard length <= bytes.count - offset else { throw ResourceError.rejected("incomplete_cp932_character") }
                if length == 2 {
                    let last = bytes[offset+1]
                    guard (0x40...0x7e).contains(last) || (0x80...0xfc).contains(last) else { throw ResourceError.rejected("invalid_cp932_trail_byte") }
                }
                let key = length == 1 ? UInt16(first) : UInt16(first) << 8 | UInt16(bytes[offset+1])
                if let known = cache[key] { scalar = known }
                else {
                    let value: Unicode.Scalar
                    // CP932's five single-byte extensions are absent from Apple's converter.
                    // They are byte-decoding mappings only, not QLIE execution semantics.
                    if length == 1, first == 0x80 { value = Unicode.Scalar(0x80)! }
                    else if length == 1, first == 0xa0 { value = Unicode.Scalar(0xf8f0)! }
                    else if length == 1, first >= 0xfd { value = Unicode.Scalar(0xf8f1 + UInt32(first - 0xfd))! }
                    else {
                        guard let string = String(data: Data(bytes[offset..<offset+length]), encoding: dosJapanese),
                              string.unicodeScalars.count == 1, let converted = string.unicodeScalars.first
                        else { throw ResourceError.rejected("undecodable_cp932_character") }
                        value = converted
                    }
                    cache[key] = value; scalar = value
                }
                offset += length
            }
            guard scalar.value >= 32 || [9,10,13].contains(scalar.value) else { throw ResourceError.rejected("binary_control_in_script") }
            output.append(ScriptScalar(value: scalar, bytes: start..<offset))
            guard output.count <= 4_000_000 else { throw ResourceError.rejected("script_scalar_limit") }
        }
        scalars = output
    }

    public func location(_ bytes: Range<Int>, line: Int) -> ScriptLocation {
        ScriptLocation(sourceFile: relativePath, sourceSHA256: sha256, byteOffset: bytes.lowerBound,
            byteLength: bytes.count, rangeSHA256: data.subdata(in: bytes).sha256Hex, lineNumber: line)
    }

    public func string(_ range: Range<Int>) -> String {
        String(String.UnicodeScalarView(scalars[range].map(\.value)))
    }
}

public func asciiLower(_ text: String) -> String {
    let bytes = text.utf8
    guard bytes.contains(where: { (65...90).contains($0) }) else { return text }
    // ASCII bytes cannot occur inside a multibyte UTF-8 scalar.
    return String(decoding: bytes.map { (65...90).contains($0) ? $0 + 32 : $0 }, as: UTF8.self)
}
