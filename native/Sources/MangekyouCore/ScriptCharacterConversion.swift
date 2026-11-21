import Foundation

enum ScriptCharacterConversion {
    /// Reconstruct the fixed executable's zenc width map. It converts the
    /// listed printable ASCII and halfwidth-kana ranges to fullwidth forms,
    /// combines the two supported dakuten pairs, and copies every other scalar.
    static func zenc(_ input: String) throws -> String {
        guard input.utf8.count <= 8192 else {
            throw ResourceError.rejected("zenc_input_limit")
        }
        let scalars = Array(input.unicodeScalars)
        var output = String.UnicodeScalarView()
        output.reserveCapacity(scalars.count)
        var index = 0
        while index < scalars.count {
            let value = scalars[index].value
            if value == 0x20 {
                output.append(Unicode.Scalar(0x3000)!)
            } else if (0x21...0x7e).contains(value) {
                let mapped: UInt32
                switch value {
                case 0x22: mapped = 0x201d // native double-quote table entry
                case 0x27: mapped = 0x2019 // native apostrophe table entry
                case 0x2c: mapped = 0x3001 // native comma table entry
                case 0x5c: mapped = 0xffe5 // native yen-sign table entry
                case 0x60: mapped = 0x2018 // native grave-accent table entry
                default: mapped = value + 0xfee0
                }
                output.append(Unicode.Scalar(mapped)!)
            } else if isNativeHalfwidthInput(value) {
                var input = String(scalars[index])
                if index + 1 < scalars.count {
                    let next = scalars[index + 1].value
                    if isVoicedKanaBase(value) && next == 0xff9e {
                        input.unicodeScalars.append(scalars[index + 1])
                        index += 1
                    } else if isHandakutenKanaBase(value) && next == 0xff9f {
                        input.unicodeScalars.append(scalars[index + 1])
                        index += 1
                    }
                }
                guard let mapped = input.applyingTransform(.fullwidthToHalfwidth, reverse: true),
                      mapped.unicodeScalars.count == 1 else {
                    throw ResourceError.rejected("zenc_halfwidth_mapping_unavailable")
                }
                output.append(contentsOf: mapped.unicodeScalars)
            } else {
                output.append(scalars[index])
            }
            index += 1
            guard String(output).utf8.count <= 8192 else {
                throw ResourceError.rejected("zenc_output_limit")
            }
        }
        return String(output)
    }

    private static func isNativeHalfwidthInput(_ value: UInt32) -> Bool {
        (0xff66...0xff6f).contains(value) || (0xff71...0xff9d).contains(value)
    }

    private static func isVoicedKanaBase(_ value: UInt32) -> Bool {
        (0xff76...0xff84).contains(value) || (0xff8a...0xff8e).contains(value)
    }

    private static func isHandakutenKanaBase(_ value: UInt32) -> Bool {
        (0xff8a...0xff8e).contains(value)
    }
}
