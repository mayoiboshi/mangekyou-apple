import Foundation

public enum ScriptValue: Sendable, Equatable {
    case integer(Int32)
    case string(String)
    case object(UInt64)
    public var typeName: String { switch self { case .integer: return "integer"; case .string: return "string"; case .object: return "object" } }
    public var integer: Int32? { if case .integer(let value) = self { return value }; return nil }
}

/// Experimental expression model with explicit indexed storage. No host eval, object coercions or update operators.
public indirect enum ScriptExpression: Sendable {
    case literal(String)
    case string(String)
    case name(String)
    case indexed(String, ScriptExpression)
    case unary(String, ScriptExpression)
    case binary(String, ScriptExpression, ScriptExpression)

    public static func parse(_ text: String) throws -> Self {
        var parser = try ExpressionParser(text)
        let value = try parser.expression(0, depth: 0)
        guard parser.index == parser.tokens.count else { throw ResourceError.rejected("unsupported_expression_tail") }
        try value.validate(root: true, depth: 0)
        return value
    }

    private func validate(root: Bool, depth: Int) throws {
        guard depth <= 64 else { throw ResourceError.rejected("expression_tree_depth_limit") }
        switch self {
        case .binary("=", let target, let value):
            guard root else { throw ResourceError.rejected("nested_assignment_or_non_scalar_target") }
            switch target {
            case .name: break
            case .indexed(_, let index): try index.validate(root: false, depth: depth+1)
            default: throw ResourceError.rejected("nested_assignment_or_non_scalar_target")
            }
            try value.validate(root: false, depth: depth+1)
        case .indexed(_, let index): try index.validate(root: false, depth: depth+1)
        case .binary(_, let a, let b): try a.validate(root: false, depth: depth+1); try b.validate(root: false, depth: depth+1)
        case .unary(_, let a): try a.validate(root: false, depth: depth+1)
        default: break
        }
    }

    public func evaluate(read: (String) throws -> ScriptValue, write: (String, ScriptValue) throws -> Void,
                         readIndexed: ((String, Int32) throws -> ScriptValue)? = nil,
                         writeIndexed: ((String, Int32, ScriptValue) throws -> Void)? = nil) throws -> ScriptValue {
        func evaluateChild(_ expression: ScriptExpression) throws -> ScriptValue {
            try expression.evaluate(read: read, write: write, readIndexed: readIndexed, writeIndexed: writeIndexed)
        }
        func indexValue(_ expression: ScriptExpression) throws -> Int32 {
            let value = try evaluateChild(expression)
            switch value {
            case .integer(let index): return index
            case .string(let text):
                if let index = Self.integerTextCache(text) { return index }
            case .object: break
            }
            throw ResourceError.rejected("index_requires_integer")
        }
        switch self {
        case .literal(let raw): return .integer(try Self.integerLiteral(raw))
        case .string(let value): return .string(value)
        case .name(let name): return try read(name)
        case .indexed(let name, let index):
            guard let readIndexed else { throw ResourceError.rejected("indexed_storage_required") }
            return try readIndexed(name,indexValue(index))
        case .unary(let op, let child):
            // The helper accepts the signed decimal boundary; parsing the positive child alone would reject it.
            if op == "-", case .literal(let raw) = child, raw == "2147483648" { return .integer(.min) }
            guard let value = try evaluateChild(child).integer else { throw ResourceError.rejected("unary_non_integer") }
            if op == "+" { return .integer(value) }
            guard op == "-", value != .min else { throw ResourceError.rejected("unverified_unary_or_overflow") }
            return .integer(-value)
        case .binary("=", let left, let right):
            let value = try evaluateChild(right)
            switch left {
            case .name(let target): try write(target, value)
            case .indexed(let target, let index):
                guard let writeIndexed else { throw ResourceError.rejected("indexed_storage_required") }
                try writeIndexed(target,indexValue(index),value)
            default: throw ResourceError.rejected("non_scalar_assignment")
            }
            return .integer(1) // Inferred contract, docs/18; not native execution equivalence.
        case .binary(let op, let a, let b):
            // The reviewed logical path resolves both sides. Never use Swift short-circuit operators to evaluate operands.
            let av = try evaluateChild(a), bv = try evaluateChild(b)
            if op == "+", case .string(let left) = av {
                let right: String
                switch bv {
                case .string(let text): right = text
                case .integer(let number): right = String(number)
                case .object: throw ResourceError.rejected("unverified_string_or_object_operator")
                }
                guard left.utf8.count + right.utf8.count <= 8192 else {
                    throw ResourceError.rejected("string_value_limit")
                }
                return .string(left + right)
            }
            if op == "==" || op == "!=", case .string(let left) = av, case .string(let right) = bv {
                let equal = asciiLower(left).utf8.elementsEqual(asciiLower(right).utf8)
                return .integer((op == "==" ? equal : !equal) ? 1 : 0)
            }
            if case .object(let left) = av, case .object(let right) = bv, op == "==" || op == "!=" {
                return .integer((op == "==" ? left == right : left != right) ? 1 : 0)
            }
            guard let left = av.integer, let right = bv.integer else { throw ResourceError.rejected("unverified_string_or_object_operator") }
            let value: Int32
            switch op {
            case "+", "-", "*":
                let calculated = op == "+" ? left.addingReportingOverflow(right) : op == "-" ? left.subtractingReportingOverflow(right) : left.multipliedReportingOverflow(by: right)
                guard !calculated.overflow else { throw ResourceError.rejected("integer_overflow_outside_profile") }
                value = calculated.partialValue
            case "/", "%":
                guard right != 0, !(left == .min && right == -1) else { throw ResourceError.rejected("invalid_integer_division") }
                value = op == "/" ? left / right : left % right
            case "&": value = left & right
            case "|": value = left | right
            case "^": value = left ^ right
            case "<<": value = left << (right & 31) // 0x69af1e, x86 32-bit SHL.

            case "==": value = left == right ? 1 : 0
            case "!=": value = left != right ? 1 : 0
            case "<": value = left < right ? 1 : 0
            case ">": value = left > right ? 1 : 0
            case "<=": value = left <= right ? 1 : 0
            case ">=": value = left >= right ? 1 : 0
            case "&&": value = left == 1 && right == 1 ? 1 : 0
            case "||": value = left == 1 || right == 1 ? 1 : 0
            default: throw ResourceError.rejected("operator_outside_reviewed_subset")
            }
            return .integer(value)
        }
    }

    public static func integerLiteral(_ text: String) throws -> Int32 {
        guard !text.isEmpty, text.count <= 8192 else { throw ResourceError.rejected("integer_literal_limit") }
        var raw = text[...], negative = false
        if raw.first == "-" || raw.first == "+" { negative = raw.first == "-"; raw.removeFirst() }
        var base: UInt64 = 10
        if raw.hasPrefix("$") { base = 16; raw.removeFirst() }
        else if raw.hasPrefix("0x") || raw.hasPrefix("0X") { base = 16; raw.removeFirst(2) }
        guard !raw.isEmpty else { throw ResourceError.rejected("integer_missing_digits") }
        var value: UInt64 = 0
        for character in raw.unicodeScalars {
            let code = character.value
            let digit = (48...57).contains(code) ? UInt64(code-48) : (65...70).contains(code) ? UInt64(code-55) : (97...102).contains(code) ? UInt64(code-87) : 99
            guard digit < base, value <= (base == 16 ? 0x0fffffff : 0x0ccccccc) else { throw ResourceError.rejected("invalid_integer_digits_or_range") }
            value = value * base + digit
        }
        if base == 10, value > (negative ? 0x80000000 : 0x7fffffff) { throw ResourceError.rejected("decimal_signed_range") }
        let bits = UInt32(truncatingIfNeeded: value)
        return Int32(bitPattern: negative ? 0 &- bits : bits)
    }
}

private struct ExpressionToken {
    let text: String
    let kind: Int // 0 atom, 1 string, 2 operator, 3 delimiter
}

private struct ExpressionParser {
    static let groups = [["*","/","%"],["+","-"],["<<",">>"],["^","&","|"],["==","!=","<=",">=",">","<"],["&&","||"],["="]]
    static let binding = Dictionary(uniqueKeysWithValues: groups.enumerated().flatMap { i, group in group.map { ($0,(groups.count-i)*10) } })
    static let operators = (groups.flatMap { $0 } + ["++","--"]).sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
    var tokens: [ExpressionToken] = []
    var index = 0
    var nodes = 0
    init(_ text: String) throws {
        guard text.unicodeScalars.count <= 8192 else { throw ResourceError.rejected("expression_character_limit") }
        let chars = Array(text.unicodeScalars); var offset = 0
        func string(_ a: Int, _ b: Int) -> String { String(String.UnicodeScalarView(chars[a..<b])) }
        while offset < chars.count {
            if chars[offset].properties.isWhitespace { offset += 1; continue }
            let start = offset
            if chars[offset] == "\"" {
                offset += 1
                while offset < chars.count && chars[offset] != "\"" { offset += 1 }
                guard offset < chars.count else { throw ResourceError.rejected("expression_unclosed_string") }
                offset += 1; tokens.append(ExpressionToken(text: string(start+1,offset-1),kind: 1))
            } else if ["(",")","[","]"].contains(String(chars[offset])) {
                offset += 1; tokens.append(ExpressionToken(text: string(start,offset),kind: 3))
            } else if let op = Self.operators.first(where: { candidate in
                let values = Array(candidate.unicodeScalars)
                return values.count <= chars.count-offset && Array(chars[offset..<offset+values.count]) == values
            }) {
                offset += op.unicodeScalars.count; tokens.append(ExpressionToken(text: op,kind: 2))
            } else {
                while offset < chars.count && !chars[offset].properties.isWhitespace && !"\"()[]+-*/%<>=!&|^,".unicodeScalars.contains(chars[offset]) { offset += 1 }
                guard offset > start else { throw ResourceError.rejected("unknown_expression_character") }
                tokens.append(ExpressionToken(text: string(start,offset),kind: 0))
            }
            guard tokens.count <= 1024 else { throw ResourceError.rejected("expression_token_limit") }
        }
    }

    mutating func expression(_ minimum: Int, depth: Int) throws -> ScriptExpression {
        guard depth <= 64, index < tokens.count else { throw ResourceError.rejected("expression_depth_or_missing_operand") }
        nodes += 1; guard nodes <= 2048 else { throw ResourceError.rejected("expression_node_limit") }
        let token = tokens[index]; index += 1
        var left: ScriptExpression
        if token.kind == 1 { left = .string(token.text) }
        else if token.kind == 0 {
            if token.text.first?.isNumber == true || token.text.first == "$" { left = .literal(token.text) }
            else {
                guard token.text.range(of: #"^#?[\p{L}_][\p{L}\p{N}_]*$"#, options: .regularExpression) != nil
                else { throw ResourceError.rejected("object_or_non_scalar_identifier") }
                left = .name(token.text)
            }
        } else if token.text == "(" {
            left = try expression(0, depth: depth+1)
            guard index < tokens.count, tokens[index].text == ")" else { throw ResourceError.rejected("expression_missing_close_paren") }
            index += 1
        } else if ["+","-"].contains(token.text) {
            left = .unary(token.text,try expression(80,depth: depth+1))
        } else { throw ResourceError.rejected("unverified_prefix_or_missing_operand") }
        if index < tokens.count, tokens[index].text == "[" {
            guard case .name(let name) = left else { throw ResourceError.rejected("index_base_requires_variable") }
            index += 1
            let coordinate = try expression(0,depth: depth+1)
            guard index < tokens.count, tokens[index].text == "]" else { throw ResourceError.rejected("index_missing_close_or_multiple_coordinates") }
            index += 1; nodes += 1
            guard nodes <= 2048 else { throw ResourceError.rejected("expression_node_limit") }
            left = .indexed(name,coordinate)
            guard index == tokens.count || tokens[index].text != "[" else { throw ResourceError.rejected("nested_index_dimensions_unverified") }
        }
        while index < tokens.count, let binding = Self.binding[tokens[index].text], binding >= minimum {
            let op = tokens[index].text; index += 1
            let right = try expression(binding+1,depth: depth+1)
            left = .binary(op,left,right)
        }
        return left
    }
}
