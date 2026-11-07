import Foundation

/// Models ASCII folding and uncased literals in the original UTF-16 replacement.
func scriptLiteralReplace(_ input: String, needle: String, replacement: String) throws -> String {
    guard !needle.isEmpty, needle.utf8.count <= 256, needle.unicodeScalars.allSatisfy({ scalar in
              scalar.isASCII || (!scalar.properties.changesWhenUppercased && !scalar.properties.changesWhenLowercased)
          }),
          input.utf8.count <= 8192, replacement.utf8.count <= 8192 else {
        throw ResourceError.rejected("literal_replace_outside_profile")
    }
    let pattern = Array(asciiLower(needle).utf8)
    let source = Array(input.utf8), insert = Array(replacement.utf8)
    let firstOnly = asciiLower(replacement).range(of: asciiLower(needle), options: .literal) != nil
    func fold(_ byte: UInt8) -> UInt8 { (65...90).contains(byte) ? byte + 32 : byte }

    var output: [UInt8] = [], index = 0
    while index < source.count {
        if source.count-index >= pattern.count,
           pattern.indices.allSatisfy({ fold(source[index+$0]) == pattern[$0] }) {
            output.append(contentsOf: insert)
            index += pattern.count
            if firstOnly {
                output.append(contentsOf: source[index...])
                index = source.count
            }
        } else {
            output.append(source[index])
            index += 1
        }
        guard output.count <= 8192 else { throw ResourceError.rejected("literal_replace_output_limit") }
    }
    return String(decoding: output, as: UTF8.self)
}
