import Foundation

public struct ScriptStringListLine: Encodable, Sendable {
    public let location: ScriptLocation
    public let textSHA256: String
    public let nameSHA256: String?
    public let valueSHA256: String?
    public let comparisonStatus: EvidenceStatus
}

public struct ScriptStringListSummary: Encodable, Sendable {
    public let status: EvidenceStatus = .inferred
    public let source: ScriptLocation
    public let lineCount: Int
    public let nameCount: Int
    public let unresolvedNameCount: Int
    public let lines: [ScriptStringListLine]
    public let scope = "Candidate ASCII-insensitive first-name lookup; Windows locale/codepage equivalence not_tested"
}

/// Distinct from the table component: no comment filter or empty-marker conversion.
struct ScriptStringList: Sendable {
    private var firstValues: [Data: String] = [:]
    private var entries: [(String,String,ScriptLocation)] = []
    private(set) var summary: ScriptStringListSummary?
    var lineCount: Int { summary?.lineCount ?? 0 }
    init() {}

    init(data: Data, relativePath: String) throws {
        guard data.count <= 1024*1024 else { throw ResourceError.rejected("list_source_size_limit") }
        let source = try ScriptSource(data: data,relativePath: relativePath)
        var lines: [ScriptStringListLine] = [], cursor = 0, start = 0, number = 0
        let clock = ContinuousClock(), started = ContinuousClock.now
        func checkedTime() throws {
            guard !Task.isCancelled, clock.now - started < .seconds(10) else { throw ResourceError.rejected("list_parse_time_or_cancel_limit") }
        }
        func append(_ end: Int, _ next: Int) throws {
            guard lines.count < 10_000 else { throw ResourceError.rejected("list_line_limit") }
            let text = source.string(start..<end)
            number += 1
            let a = source.scalars[start].bytes.lowerBound
            let b = source.scalars[next-1].bytes.upperBound
            let location = source.location(a..<b,line: number)
            guard text.utf8.count <= 8192 else { throw ScriptTableFailure(code: "list_line_length_limit",location: location) }
            var nameSHA: String?, valueSHA: String?, comparison: EvidenceStatus = .notTested
            if let equal = text.firstIndex(of: "=") {
                let name = String(text[..<equal]), value = String(text[text.index(after: equal)...])
                nameSHA = Data(name.utf8).sha256Hex; valueSHA = Data(value.utf8).sha256Hex
                comparison = name.unicodeScalars.allSatisfy({ $0.value < 128 }) ? .inferred : .unsupported
                entries.append((name,value,location))
                if comparison == .inferred {
                    let key = Data(asciiLower(name).utf8)
                    if firstValues[key] == nil { firstValues[key] = value }
                }
            }
            lines.append(ScriptStringListLine(location: location,textSHA256: Data(text.utf8).sha256Hex,nameSHA256: nameSHA,valueSHA256: valueSHA,comparisonStatus: comparison))
        }
        while cursor < source.scalars.count {
            if cursor % 1024 == 0 { try checkedTime() }
            let scalar = source.scalars[cursor].value
            if scalar == "\r" || scalar == "\n" {
                let end = cursor
                if scalar == "\r", cursor+1 < source.scalars.count, source.scalars[cursor+1].value == "\n" { cursor += 1 }
                cursor += 1; try append(end,cursor); start = cursor
            } else { cursor += 1 }
        }
        if start < cursor { try append(cursor,cursor) }
        try checkedTime()
        summary = ScriptStringListSummary(source: source.location(0..<data.count,line: 1),lineCount: lines.count,nameCount: firstValues.count,
            unresolvedNameCount: lines.filter { $0.comparisonStatus == .unsupported }.count,lines: lines)
    }

    func value(for name: String) throws -> String? {
        guard name.unicodeScalars.allSatisfy({ $0.value < 128 }) else { throw ResourceError.rejected("list_non_ascii_name_comparison_unverified") }
        let key = Data(asciiLower(name).utf8)
        for (candidate,value,location) in entries {
            guard candidate.unicodeScalars.allSatisfy({ $0.value < 128 }) else {
                throw ScriptTableFailure(code: "list_name_locale_comparison_required",location: location)
            }
            if Data(asciiLower(candidate).utf8) == key { return value.isEmpty ? nil : value }
        }
        return nil
    }

    static func integerCache(_ value: String) throws -> Int32 {
        if let number = ScriptExpression.integerTextCache(value) { return number }
        // The native list uses a different, 64-bit conversion helper with zero default.
        // Do not silently reuse the table's numeric-default contract for a found value.
        let trimmed = value.drop(while: { $0 == " " })
        if let first = trimmed.first, "0123456789+-$xX".contains(first) {
            throw ResourceError.rejected("list_integer_cache_outside_reviewed_range")
        }
        return 0
    }
}
