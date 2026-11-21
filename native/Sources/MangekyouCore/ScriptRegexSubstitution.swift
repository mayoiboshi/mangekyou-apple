import Foundation

enum ScriptRegexSubstitution {
    private static let supportedPatterns: Set<String> = [
        #".*?\[([^\]]*?)\].*$"#,
        #"\[rb,([^,]+),[^,]+\]"#,
        #"\[pc,([^\]]+)\]"#,
        #"\[([^\]]*).*?\]"#
    ]

    /// The save-menu text helper uses these literal replacement expressions.
    /// REA shows bsub performs repeated global matches with capture expansion;
    /// other patterns remain unsupported until their option semantics are mapped.
    static func replace(input: String, pattern: String, with replacement: String) throws -> String {
        guard input.utf8.count <= 8192, replacement.utf8.count <= 8192,
              supportedPatterns.contains(pattern) else {
            throw ResourceError.rejected("regex_substitution_pattern_outside_profile")
        }
        let expression: NSRegularExpression
        do {
            // The fixed handler passes option mask 0x11. Ignore case and
            // single-line matching are the bounded candidate for this path.
            expression = try NSRegularExpression(pattern: pattern,
                options: [.caseInsensitive, .dotMatchesLineSeparators])
        } catch {
            throw ResourceError.rejected("regex_substitution_compile_failed")
        }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        let output = expression.stringByReplacingMatches(in: input, range: range, withTemplate: replacement)
        guard output.utf8.count <= 8192 else {
            throw ResourceError.rejected("regex_substitution_output_limit")
        }
        return output
    }
}
