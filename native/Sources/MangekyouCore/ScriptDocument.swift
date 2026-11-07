import Foundation

public enum ScriptRecordKind: String, Encodable, Sendable {
    case bom, layout = "layout_span", empty = "empty_span", command, include, label
    case lineTag = "line_tag", comment = "comment_candidate", sound = "sound_identifier"
    case macro = "macro_assignment_candidate", setting = "setting_assignment_candidate", text = "opaque_text"
}

public struct ScriptField: Sendable {
    public let raw: String
    public let key: String?
    public let value: String
    public let location: ScriptLocation
}

/// Deliberately not Codable: source text and operands cannot be serialized accidentally.
public struct ScriptRecord: Sendable {
    public let kind: ScriptRecordKind
    public let command: String?
    public let identifier: String?
    public let fields: [ScriptField]
    public let location: ScriptLocation
    public let lineCount: Int
}

public struct ScriptDocument: Sendable {
    public let source: ScriptSource
    public let records: [ScriptRecord]
    init(expandedSource: ScriptSource, records: [ScriptRecord]) {
        source = expandedSource; self.records = records
    }

    public init(data: Data, relativePath: String) throws {
        let source = try ScriptSource(data: data, relativePath: relativePath)
        self.source = source
        let units = source.scalars
        var semantic: [ScriptRecord] = [], begin = 0, line = 0
        let clock = ContinuousClock(), started = ContinuousClock.now
        var pendingBlank: (start: Int, end: Int, line: Int, count: Int)?
        func make(_ kind: ScriptRecordKind, bytes: Range<Int>, number: Int, count: Int = 1,
                  command: String? = nil, identifier: String? = nil, fields: [ScriptField] = []) -> ScriptRecord {
            ScriptRecord(kind: kind, command: command, identifier: identifier, fields: fields,
                location: source.location(bytes, line: number), lineCount: count)
        }
        func flushBlank() {
            if let blank = pendingBlank {
                semantic.append(make(.empty, bytes: blank.start..<blank.end, number: blank.line, count: blank.count)); pendingBlank = nil
            }
        }
        func whitespace(_ i: Int) -> Bool { units[i].value.properties.isWhitespace }
        func process(_ range: Range<Int>) throws {
            line += 1
            if line % 256 == 0 {
                guard !Task.isCancelled else { throw ResourceError.rejected("script_parse_cancelled") }
                guard clock.now - started < .seconds(15) else { throw ResourceError.rejected("script_parse_time_limit") }
            }
            guard line <= 100_000 else { throw ResourceError.rejected("script_line_limit") }
            var end = range.upperBound
            while end > range.lowerBound && [10,13].contains(units[end-1].value.value) { end -= 1 }
            var start = range.lowerBound
            while start < end && whitespace(start) { start += 1 }
            if start == end {
                let a = units[range.lowerBound].bytes.lowerBound, b = units[range.upperBound-1].bytes.upperBound
                if var blank = pendingBlank { blank.end = b; blank.count += 1; pendingBlank = blank }
                else { pendingBlank = (a,b,line,1) }
                return
            }
            flushBlank()
            guard semantic.count <= 200_000 else { throw ResourceError.rejected("script_record_limit") }
            let content = source.string(start..<end)
            let kind: ScriptRecordKind
            if content.hasPrefix("@@@") { kind = .include }
            else if content.hasPrefix("@@") { kind = .label }
            else if content.hasPrefix("\\") { kind = .command }
            else if content.hasPrefix("^") { kind = .lineTag }
            else if content.hasPrefix("//") { kind = .comment }
            else if content.hasPrefix("％") { kind = .sound }
            else if content.range(of: #"^\$[A-Za-z_][A-Za-z_0-9]*="#, options: .regularExpression) != nil { kind = .macro }
            else if content.range(of: #"^[A-Za-z_][A-Za-z_0-9]*="#, options: .regularExpression) != nil { kind = .setting }
            else { kind = .text }
            var fragments: [(Int,Int)] = []
            if kind == .command {
                var quoted = false, starts: [Int] = []
                for i in start..<end {
                    if units[i].value == "\"" { quoted.toggle() }
                    else if units[i].value == "\\" && !quoted {
                        starts.append(i)
                        guard starts.count <= 200_000 else { throw ResourceError.rejected("script_fragment_limit") }
                    }
                }
                guard !quoted else { throw ResourceError.rejected("script_unclosed_quote_at_byte_\(units[start].bytes.lowerBound)") }
                for (index,a) in starts.enumerated() {
                    var b = index + 1 < starts.count ? starts[index+1] : end
                    while b > a && whitespace(b-1) { b -= 1 }
                    if b > a { fragments.append((a,b)) }
                }
            } else { fragments = [(start,end)] }
            for (a,b) in fragments {
                if semantic.count % 256 == 0 {
                    guard !Task.isCancelled, clock.now - started < .seconds(15) else { throw ResourceError.rejected("script_parse_time_or_cancel_limit") }
                }
                let bytes = units[a].bytes.lowerBound..<units[b-1].bytes.upperBound
                var command: String?, identifier: String?, fields: [ScriptField] = []
                if kind == .command || kind == .lineTag {
                    let pieces = try Self.split(source, a+1..<b, grouping: kind == .command, line: line)
                    command = pieces.first?.value; fields = Array(pieces.dropFirst())
                } else if kind == .include || kind == .label || kind == .sound {
                    identifier = source.string((a + (kind == .include ? 3 : kind == .label ? 2 : 1))..<b)
                }
                semantic.append(make(kind, bytes: bytes, number: line, command: command, identifier: identifier, fields: fields))
                guard semantic.count <= 200_000 else { throw ResourceError.rejected("script_record_limit") }
            }
        }
        for i in units.indices where units[i].value == "\n" { try process(begin..<i+1); begin = i+1 }
        if begin < units.count { try process(begin..<units.count) }
        flushBlank()
        var result: [ScriptRecord] = [], cursor = 0
        for record in semantic {
            let start = record.location.byteOffset
            if cursor < start {
                result.append(make(cursor == 0 && start == source.bomBytes && source.bomBytes > 0 ? .bom : .layout,
                    bytes: cursor..<start, number: record.location.lineNumber))
            }
            result.append(record); cursor = start + record.location.byteLength
            guard result.count <= 200_000 else { throw ResourceError.rejected("script_record_limit") }
        }
        if cursor < data.count { result.append(make(cursor == 0 && data.count == source.bomBytes ? .bom : .layout, bytes: cursor..<data.count, number: max(line,1))) }
        guard result.count <= 200_000 else { throw ResourceError.rejected("script_record_limit") }
        records = result
    }

    private static func split(_ source: ScriptSource, _ range: Range<Int>, grouping: Bool, line: Int) throws -> [ScriptField] {
        var start = range.lowerBound, quoted = false, depth = 0, ranges: [Range<Int>] = []
        for i in range {
            let value = source.scalars[i].value
            if value == "\"" { quoted.toggle() }
            else if !quoted {
                if grouping {
                    if value == "[" || value == "(" { depth += 1 }
                    else if value == "]" || value == ")" { depth -= 1 }
                    guard abs(depth) <= 64 else { throw ResourceError.rejected("script_field_group_limit") }
                }
                if value == "," && (!grouping || depth < 1) {
                    ranges.append(start..<i); start = i+1
                    guard ranges.count < 4096 else { throw ResourceError.rejected("script_field_count_limit") }
                }
            }
        }
        guard !quoted else { throw ResourceError.rejected("script_unclosed_field_quote") }
        ranges.append(start..<range.upperBound)
        return ranges.map { r in
            let raw = source.string(r)
            var quoted = false, colon: Int?
            for i in r {
                let value = source.scalars[i].value
                if value == "\"" { quoted.toggle() }
                else if value == ":" && !quoted && colon == nil { colon = i }
            }
            let a = r.lowerBound < source.scalars.count ? source.scalars[r.lowerBound].bytes.lowerBound : source.data.count
            let b = r.isEmpty ? a : source.scalars[r.upperBound-1].bytes.upperBound
            let value = source.string((colon.map { $0+1 } ?? r.lowerBound)..<r.upperBound).replacingOccurrences(of: "\"", with: "")
            return ScriptField(raw: raw, key: colon.map { source.string(r.lowerBound..<$0) }, value: value,
                location: source.location(a..<b, line: line))
        }
    }
}
