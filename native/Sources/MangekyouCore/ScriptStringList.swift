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
    private(set) var rawLines: [String] = []
    private var firstValues: [Data: String] = [:]
    private var entries: [(String,String,ScriptLocation)] = []
    private(set) var summary: ScriptStringListSummary?
    var lineCount: Int { rawLines.count }
    var generatedBytes = 0

    mutating func append(_ text: String, at location: ScriptLocation) throws {
        let bytes = text.utf8.count
        guard rawLines.count < 10_000, bytes <= 8192,
              !text.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" || $0.value == 0 }) else {
            throw ResourceError.rejected("list_append_line_outside_profile")
        }
        if let equal = text.firstIndex(of: "=") {
            entries.append((String(text[..<equal]),String(text[text.index(after: equal)...]),location))
        }
        rawLines.append(text)
        generatedBytes += bytes
    }
    mutating func setValue(_ value: String, for name: String, at location: ScriptLocation) throws {
        guard !name.isEmpty, !name.contains("="), name.unicodeScalars.allSatisfy(\.isASCII) else {
            throw ResourceError.rejected("list_write_name_outside_profile")
        }
        let text = name + "=" + value
        guard text.utf8.count <= 8192,
              !text.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" || $0.value == 0 }) else {
            throw ResourceError.rejected("list_write_line_outside_profile")
        }
        let key = asciiLower(name)
        if let index = rawLines.firstIndex(where: { line in
            line.firstIndex(of: "=").map { asciiLower(String(line[..<$0])) == key } ?? false
        }), let entry = entries.firstIndex(where: { asciiLower($0.0) == key }) {
            generatedBytes += max(0, text.utf8.count - rawLines[index].utf8.count)
            rawLines[index] = text
            entries[entry] = (name, value, location)
        } else {
            try append(text, at: location)
        }
    }

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
            rawLines.append(text)
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

    func line(at index: Int32) throws -> String {
        guard index >= 0, Int(index) < rawLines.count else {
            throw ResourceError.rejected("list_line_index_out_of_range")
        }
        return rawLines[Int(index)]
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

    // The native helper at 0x4e281c counts brackets even with quote parsing off.
    static func splitUnquoted(_ input: String, separator: Character, stripSpacing: Bool = false) -> [String] {
        var fields: [String] = []
        var depth = 0
        var field = ""
        let delimiter = separator.unicodeScalars.first
        for scalar in input.unicodeScalars {
            if stripSpacing, scalar == " " || scalar == "\t" || scalar.value == 0xa0 { continue }
            switch scalar {
            case "(", "[", "{": depth += 1
            case ")", "]", "}": depth -= 1
            default: break
            }
            if depth == 0, scalar == delimiter {
                fields.append(field)
                field = ""
            } else {
                field.unicodeScalars.append(scalar)
            }
        }
        if !field.isEmpty { fields.append(field) }
        return fields
    }

    static func integerCache(_ value: String) throws -> Int32 {
        if let number = ScriptExpression.integerTextCache(value) { return number }
        // 0x408c34 rejects a non-NUL suffix, and 0x415b26 returns the
        // supplied zero default. Successful conversions pass EAX to ResultInt.
        guard !value.contains("\0") else {
            throw ResourceError.rejected("list_integer_cache_outside_reviewed_range")
        }
        let trimmed = value.drop(while: { $0 == " " })
        var digits = trimmed
        let negative = digits.first == "-"
        if negative || digits.first == "+" { digits = digits.dropFirst() }
        if digits.hasPrefix("0x") || digits.hasPrefix("0X") {
            digits = digits.dropFirst(2)
        } else if let first = digits.first, "$xX".contains(first) {
            digits = digits.dropFirst()
        } else {
            return Int64(trimmed).map { Int32(truncatingIfNeeded: $0) } ?? 0
        }
        guard let number = UInt64(digits, radix: 16), digits.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }) else { return 0 }
        return Int32(truncatingIfNeeded: negative ? 0 &- number : number)
    }
}
