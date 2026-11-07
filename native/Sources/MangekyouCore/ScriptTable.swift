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
    public let scope: String
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
    private var allowWideKeys = false
    private var keySpellings: [Data: String] = [:]
    private var orderedKeys: [Data] = []
    private var values: [Data: String] = [:]
    public private(set) var summary: ScriptTableSummary?
    public var count: Int { values.count }
    var storedBytes: Int { values.reduce(0) { $0 + $1.key.count + $1.value.utf8.count } }

    mutating func overlayNonemptyValues(from source: ScriptTable) throws {
        for key in source.orderedKeys {
            if let value = source.values[key], !value.isEmpty {
                store(value, key: key, spelling: source.keySpellings[key]!)
            }
        }
        guard count <= 50_000, storedBytes <= 8 * 1024 * 1024 else {
            throw ResourceError.rejected("table_overlay_budget")
        }
    }
    mutating func setValue(_ value: String, for name: String) throws {
        guard !name.isEmpty, name.utf8.count <= 8192, (allowWideKeys || name.utf8.allSatisfy({ $0 < 128 })),
              value.utf8.count <= 8192 else {
            throw ResourceError.rejected("table_write_key_or_value_outside_profile")
        }
        let key = Data(asciiLower(name).utf8)
        guard values[key] != nil || count < 50_000 else {
            throw ResourceError.rejected("table_write_entry_limit")
        }
        store(value, key: key, spelling: name)
    }

    private mutating func store(_ value: String, key: Data, spelling: String) {
        if values[key] == nil {
            orderedKeys.append(key)
            keySpellings[key] = spelling
        }
        values[key] = value
    }

    func replacingLiteralKeys(in input: String) throws -> String {
        // 0x563d7c walks table entries from last to first, applying the
        // same flag selection as the mode-zero literal replacement helper.
        var text = input
        for key in orderedKeys.reversed() {
            guard let name = keySpellings[key], let value = values[key] else {
                throw ResourceError.rejected("table_replacement_entry_missing")
            }
            text = try scriptLiteralReplace(text, needle: name, replacement: value)
        }
        return text
    }

    func lastLiteralMatch(in text: String) throws -> (index: Int32, name: String, value: String)? {
        let folded = asciiLower(text)
        for index in orderedKeys.indices.reversed() {
            let key = orderedKeys[index]
            let needle = String(decoding: key, as: UTF8.self)
            guard !needle.contains(",") else {
                throw ResourceError.rejected("table_compound_position_key_outside_profile")
            }
            if folded.range(of: needle, options: .literal) != nil {
                return (Int32(index),keySpellings[key]!,values[key]!)
            }
        }
        return nil
    }

    func name(at index: Int32) throws -> String {
        guard index >= 0, Int(index) < orderedKeys.count,
              let name = keySpellings[orderedKeys[Int(index)]] else {
            throw ResourceError.rejected("table_name_index_out_of_range")
        }
        return name
    }

    mutating func sortKeys() {
        // 0x5646a4 calls the ordinal ASCII-folding comparison at 0x414b08.
        func upper(_ word: UInt16) -> UInt16 { (97...122).contains(word) ? word - 32 : word }
        let keys = orderedKeys.map { key in
            (key, String(decoding: key, as: UTF8.self).utf16.map(upper))
        }
        orderedKeys = keys.sorted { $0.1.lexicographicallyPrecedes($1.1) }.map { $0.0 }
    }

    public init() {}
    init(allowWideKeys: Bool) { self.allowWideKeys = allowWideKeys }

    mutating func clear() {
        values.removeAll()
        orderedKeys.removeAll()
        keySpellings.removeAll()
        summary = nil
    }
    public func value(for name: String) throws -> String? {
        guard allowWideKeys || name.unicodeScalars.allSatisfy({ $0.value < 128 }) else { throw ResourceError.rejected("table_non_ascii_key_comparison_unverified") }
        guard let result = values[Data(asciiLower(name).utf8)], !result.isEmpty else { return nil }
        return result
    }

    public init(data: Data, relativePath: String) throws {
        try self.init(data: data, relativePath: relativePath, allowWideKeys: false)
    }

    init(data: Data, relativePath: String, allowWideKeys: Bool) throws {
        self.allowWideKeys = allowWideKeys
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
            guard allowWideKeys || key.unicodeScalars.allSatisfy({ $0.value < 128 }) else { throw ScriptTableFailure(code: "table_non_ascii_key_comparison_unverified",location: row.location) }
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
            store(value, key: id, spelling: key)
            records.append(ScriptTableLine(location: row.location,action: duplicate ? "first_name_value_reused" : value.isEmpty ? "stored_empty" : "stored",keySHA256: keySHA,selectedValueSHA256: valueSHA))
        }
        let scope = allowWideKeys
            ? "Candidate wide-key ordinal load with ASCII case folding; Windows NLS not emulated"
            : "Candidate first ASCII-key value/filter load; Windows NLS and original codepage selection not emulated"
        summary = ScriptTableSummary(scope: scope,source: source.location(0..<data.count,line: 1),entryCount: values.count,
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
