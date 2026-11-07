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
            let specifier = chars[index]; index += 1
            if specifier == "%" { output.append("%"); continue }
            guard !consumed else { throw ResourceError.rejected("format_multiple_arguments_outside_profile") }
            let text: String
            switch (specifier,value) {
            case ("d",.integer(let number)): text = String(number)
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
