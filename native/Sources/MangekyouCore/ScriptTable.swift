import Foundation

public struct ScriptTableLine: Encodable, Sendable {
    public let location: ScriptLocation
    public let action: String
    public let keySHA256: String?
    public let selectedValueSHA256: String?
    public let status: EvidenceStatus = .inferred
}

public struct ScriptTableSummary: Encodable, Sendable {
    public let status: EvidenceStatus = .inferred
    public let scope = "Candidate first ASCII-key value/filter load; Windows NLS and original codepage selection not emulated"
    public let source: ScriptLocation
    public let entryCount: Int
    public let emptyValueCount: Int
    public let lines: [ScriptTableLine]
}

public struct ScriptTableFailure: Error, CustomStringConvertible, Sendable {
    public let code: String
    public let location: ScriptLocation
    public var description: String { code }
}

/// Independently implemented from the selected name/value/admission paths; no native object ABI.
public struct ScriptTable: Sendable {
    private var values: [Data: String] = [:]
    public private(set) var summary: ScriptTableSummary?
    public var count: Int { values.count }
    public init() {}
    public func value(for name: String) throws -> String? {
        guard name.unicodeScalars.allSatisfy({ $0.value < 128 }) else { throw ResourceError.rejected("table_non_ascii_key_comparison_unverified") }
        guard let result = values[Data(asciiLower(name).utf8)], !result.isEmpty else { return nil }
        return result
    }

    public init(data: Data, relativePath: String) throws {
        guard data.count <= 1024*1024 else { throw ResourceError.rejected("table_source_size_limit") }
        let source = try ScriptSource(data: data,relativePath: relativePath)
        struct Row { let key: String?; let value: String?; let location: ScriptLocation }
        var rows: [Row] = [], start = 0, i = 0, number = 0
        let scalars = source.scalars, clock = ContinuousClock(), started = ContinuousClock.now
        while i < scalars.count {
            if i % 1024 == 0, Task.isCancelled || clock.now - started >= .seconds(10) {
                throw ResourceError.rejected("table_parse_time_or_cancel_limit")
            }
            if scalars[i].value == "\r" || scalars[i].value == "\n" {
                let end = i
                if scalars[i].value == "\r", i+1 < scalars.count, scalars[i+1].value == "\n" { i += 1 }
                i += 1; number += 1
                let text = source.string(start..<end), a = scalars[start].bytes.lowerBound, b = scalars[i-1].bytes.upperBound
                let split = text.firstIndex(of: "=")
                rows.append(Row(key: split.map { String(text[..<$0]) },value: split.map { String(text[text.index(after: $0)...]) },location: source.location(a..<b,line: number)))
                start = i
                guard rows.count <= 10_000 else { throw ResourceError.rejected("table_line_limit") }
            } else { i += 1 }
        }
        if start < scalars.count {
            guard rows.count < 10_000 else { throw ResourceError.rejected("table_line_limit") }
            number += 1; let text = source.string(start..<scalars.count), split = text.firstIndex(of: "=")
            rows.append(Row(key: split.map { String(text[..<$0]) },value: split.map { String(text[text.index(after: $0)...]) },
                location: source.location(scalars[start].bytes.lowerBound..<data.count,line: number)))
        }
        var firstValues: [Data: String] = [:]
        for row in rows {
            guard let key = row.key, !key.isEmpty, let value = row.value else { continue }
            guard key.unicodeScalars.allSatisfy({ $0.value < 128 }) else { throw ScriptTableFailure(code: "table_non_ascii_key_comparison_unverified",location: row.location) }
            guard key.utf8.count <= 8192, value.utf8.count <= 8192 else { throw ScriptTableFailure(code: "table_entry_length_limit",location: row.location) }
            let id = Data(asciiLower(key).utf8)
            if firstValues[id] == nil { firstValues[id] = value }
        }
        var records: [ScriptTableLine] = [], seen = Set<Data>(), bytes = 0
        for row in rows {
            guard !Task.isCancelled, clock.now - started < .seconds(10) else { throw ResourceError.rejected("table_parse_time_or_cancel_limit") }
            guard let key = row.key, !key.isEmpty else {
                records.append(ScriptTableLine(location: row.location,action: row.key == nil ? "no_name_separator" : "empty_name",keySHA256: nil,selectedValueSHA256: nil)); continue
            }
            let id = Data(asciiLower(key).utf8), selected = firstValues[id]!
            let keySHA = Data(key.utf8).sha256Hex, valueSHA = Data(selected.utf8).sha256Hex
            if key.contains("//") || selected.contains("//") {
                records.append(ScriptTableLine(location: row.location,action: "filtered_double_slash",keySHA256: keySHA,selectedValueSHA256: valueSHA)); continue
            }
            let duplicate = !seen.insert(id).inserted
            let value = selected == "%%none%%" ? "" : selected
            if !duplicate { bytes += id.count + value.utf8.count }
            guard values.count < 50_000 || duplicate, bytes <= 8*1024*1024 else { throw ScriptTableFailure(code: "table_entry_budget",location: row.location) }
            values[id] = value
            records.append(ScriptTableLine(location: row.location,action: duplicate ? "first_name_value_reused" : value.isEmpty ? "stored_empty" : "stored",keySHA256: keySHA,selectedValueSHA256: valueSHA))
        }
        summary = ScriptTableSummary(source: source.location(0..<data.count,line: 1),entryCount: values.count,
            emptyValueCount: values.values.filter(\.isEmpty).count,lines: records)
    }
}

public extension ScriptExpression {
    /// Candidate for the selected RTL conversion helper. Failure is explicit nil; callers select defaults.
    static func integerTextCache(_ text: String) -> Int32? {
        guard text.unicodeScalars.count <= 8192, !text.contains("\0") else { return nil }
        var raw = text[...]
        while raw.first == " " { raw.removeFirst() }
        var sign = ""
        if raw.first == "-" || raw.first == "+" { sign = String(raw.removeFirst()) }
        if raw.first == "x" || raw.first == "X" { raw.removeFirst(); return try? integerLiteral(sign+"$"+raw) }
        return try? integerLiteral(sign+raw)
    }
}
