import Foundation
import MangekyouCore

/// Bounded candidate for the native chroma operation at parameter -100.
/// Pixel format, subsequent filters and original rendering remain unverified.
package enum ChromaFilterCandidate {
    package static func desaturate(_ data: Data, width: Int, height: Int) throws -> Data {
        guard width > 0, height > 0, width <= 4096, height <= 4096,
              width <= 4_194_304 / height, data.count == width * height * 4 else {
            throw ResourceError.rejected("chroma_candidate_bounds")
        }
        var result = [UInt8](data)
        for offset in stride(from: 0, to: result.count, by: 4) {
            let total = Int(result[offset]) + Int(result[offset + 1]) + Int(result[offset + 2])
            let value = UInt8(total * 85 / 256)
            result[offset] = value
            result[offset + 1] = value
            result[offset + 2] = value
        }
        return Data(result)
    }

    /// Candidate for numeric colorfill mode 2, on straight BGRA bytes.
    /// The caller must verify the source pixel representation and filter order.
    package static func screenFill(_ data: Data, width: Int, height: Int, color: UInt32) throws -> Data {
        guard width > 0, height > 0, width <= 4096, height <= 4096,
              width <= 4_194_304 / height, data.count == width * height * 4 else {
            throw ResourceError.rejected("colorfill_candidate_bounds")
        }
        let alpha = Int(color >> 24)
        if alpha == 0 { return data }
        let factor = alpha + (alpha >> 7)
        let components = [Int(color & 255), Int((color >> 8) & 255), Int((color >> 16) & 255)]
        var result = [UInt8](data)
        for offset in stride(from: 0, to: result.count, by: 4) {
            for channel in 0..<3 {
                let fill = (components[channel] * factor) >> 8
                let original = Int(result[offset + channel])
                result[offset + channel] = UInt8(clamping: original + fill - ((original * fill) >> 8))
            }
        }
        return Data(result)
    }
}
