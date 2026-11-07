import Foundation
import CryptoKit

private struct FingerprintStream {
    var hash = SHA256()
    var bytes = Data()
    mutating func u32(_ value: UInt32) {
        for shift in 0..<4 { bytes.append(UInt8(truncatingIfNeeded: value >> (shift*8))) }
        if bytes.count >= 65536 { hash.update(data: bytes); bytes.removeAll(keepingCapacity: true) }
    }
    mutating func text(_ string: String?) {
        guard let string else { u32(.max); return }
        let data = Data(string.utf8); u32(UInt32(data.count)); hash.update(data: bytes); bytes.removeAll(keepingCapacity: true)
        hash.update(data: data)
    }
    mutating func finish() -> String {
        hash.update(data: bytes)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public extension ScriptDocument {
    /// Digest of lexical metadata and in-memory decoded fields; no field content is emitted.
    var lexicalFingerprint: String {
        var out = FingerprintStream()
        for record in records {
            out.text(record.kind.rawValue); out.u32(UInt32(record.location.byteOffset)); out.u32(UInt32(record.location.byteLength))
            out.text(record.command); out.u32(UInt32(record.lineCount)); out.u32(UInt32(record.fields.count)); out.text(record.identifier)
            for field in record.fields {
                out.text(field.raw); out.text(field.key); out.text(field.value)
                out.u32(UInt32(field.location.byteOffset)); out.u32(UInt32(field.location.byteLength))
            }
        }
        return out.finish()
    }
    var scalarFingerprint: String {
        var out = FingerprintStream()
        for scalar in source.scalars {
            out.u32(scalar.value.value); out.u32(UInt32(scalar.bytes.lowerBound)); out.u32(UInt32(scalar.bytes.count))
        }
        return out.finish()
    }
}

public struct ScriptLexicalSummary: Encodable, Sendable {
    public let status: EvidenceStatus
    public let sourceFile: String
    public let sourceSHA256: String
    public let byteCount: Int
    public let encoding: String
    public let encodingStatus: EvidenceStatus
    public let decodedUTF8SHA256: String
    public let scalarFingerprint: String
    public let lexicalFingerprint: String
    public let recordCount: Int
    public let recordTypes: [String: Int]
    public let commandCounts: [String: Int]
    public let unsupportedCommandIdentifierCount: Int
    public let executionSemantics: EvidenceStatus = .notTested
    public init(_ document: ScriptDocument) {
        status = .inferred; sourceFile = document.source.relativePath; sourceSHA256 = document.source.sha256
        byteCount = document.source.data.count; encoding = document.source.encoding; encodingStatus = document.source.encodingStatus
        decodedUTF8SHA256 = Data(document.source.decodedText.utf8).sha256Hex
        scalarFingerprint = document.scalarFingerprint; lexicalFingerprint = document.lexicalFingerprint
        recordCount = document.records.count
        var types: [String: Int] = [:], commands: [String: Int] = [:], bad = 0
        for record in document.records {
            types[record.kind.rawValue,default: 0] += 1
            if record.kind == .command, let name = record.command {
                if name.range(of: #"^[A-Za-z?][A-Za-z_0-9?]{0,15}$"#, options: .regularExpression) != nil { commands[name,default: 0] += 1 }
                else { bad += 1 }
            }
        }
        recordTypes = types; commandCounts = commands; unsupportedCommandIdentifierCount = bad
    }
}
