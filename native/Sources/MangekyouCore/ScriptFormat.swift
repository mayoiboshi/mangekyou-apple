import Foundation

/// Deliberately bounded candidate for the observed one-argument formatting calls.
enum ScriptFormat {
    static func pair(_ format: String, _ value: ScriptValue) throws -> String {
        guard format.utf8.count <= 8192 else { throw ResourceError.rejected("format_source_limit") }
        let chars = Array(format.unicodeScalars)
        var output = String.UnicodeScalarView(), index = 0, consumed = false
        while index < chars.count {
            if chars[index] != "%" { output.append(chars[index]); index += 1; continue }
            index += 1
            guard index < chars.count else { throw ResourceError.rejected("format_missing_specifier") }
            var precision: Int?
            if chars[index] == "." {
                index += 1
                let start = index
                var digits = 0
                while index < chars.count, (48...57).contains(chars[index].value) {
                    digits = digits * 10 + Int(chars[index].value - 48)
                    guard digits <= 8192 else { throw ResourceError.rejected("format_output_limit") }
                    index += 1
                }
                guard index > start, index < chars.count, chars[index] == "d" else {
                    throw ResourceError.rejected("format_precision_outside_profile")
                }
                precision = digits
            }
            let specifier = chars[index]; index += 1
            if specifier == "%" { output.append("%"); continue }
            guard !consumed else { throw ResourceError.rejected("format_multiple_arguments_outside_profile") }
            let text: String
            switch (specifier,value) {
            case ("d",.integer(let number)):
                let digits = String(number.magnitude)
                let padding = String(repeating: "0", count: max(0, (precision ?? 0) - digits.count))
                text = (number < 0 ? "-" : "") + padding + digits
            case ("x",.integer(let number)), ("X",.integer(let number)):
                text = String(UInt32(bitPattern: number), radix: 16, uppercase: true)
            case ("s",.string(let string)): text = string
            default: throw ResourceError.rejected("format_specifier_or_type_outside_profile")
            }
            output.append(contentsOf: text.unicodeScalars); consumed = true
        }
        let text = String(output)
        guard text.utf8.count <= 8192 else { throw ResourceError.rejected("format_output_limit") }
        return text
    }
}
