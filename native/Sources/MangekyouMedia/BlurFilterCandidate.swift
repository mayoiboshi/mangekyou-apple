import Foundation
import MangekyouCore

/// Bounded, straight-channel candidate for the two native blur passes.
/// Source pixel representation and native rendering equivalence remain unverified.
package enum BlurFilterCandidate {
    package static func parameters(_ descriptor: String) -> (horizontal: Int, vertical: Int)? {
        let parts = descriptor.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "blur",
              parts[1...2].allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              let horizontal = Int(parts[1]), let vertical = Int(parts[2]),
              (0...128).contains(horizontal), (0...128).contains(vertical) else { return nil }
        return (horizontal, vertical)
    }

    package static func apply(_ data: Data, width: Int, height: Int,
                              horizontal: Int, vertical: Int) throws -> Data {
        guard width > 0, height > 0, width <= 4096, height <= 4096,
              width <= 4_194_304 / height, (0...128).contains(horizontal),
              (0...128).contains(vertical), data.count == width * height * 4 else {
            throw ResourceError.rejected("blur_candidate_bounds")
        }
        if width < 2 && height < 2 { return data }
        let rx = horizontal / 2, ry = vertical / 2
        let divisor = Int32((rx * 2 + 1) * (ry * 2 + 1))
        let count = width * height * 4
        var source = [UInt8](data)
        var result = [UInt8](repeating: 0, count: count)
        var columnSums = [Int32](repeating: 0, count: count)
        func clamp(_ value: Int, _ maximum: Int) -> Int { min(maximum - 1, max(0, value)) }
        for _ in 0..<2 {
            for x in 0..<width {
                var sums = [Int32](repeating: 0, count: 4)
                for dy in -ry...ry {
                    let offset = (clamp(dy, height) * width + x) * 4
                    for c in 0..<4 { sums[c] += Int32(source[offset + c]) }
                }
                for y in 0..<height {
                    let offset = (y * width + x) * 4
                    for c in 0..<4 { columnSums[offset + c] = sums[c] }
                    let outgoing = (clamp(y - ry, height) * width + x) * 4
                    let incoming = (clamp(y + ry + 1, height) * width + x) * 4
                    for c in 0..<4 { sums[c] += Int32(source[incoming + c]) - Int32(source[outgoing + c]) }
                }
            }
            for y in 0..<height {
                var sums = [Int32](repeating: 0, count: 4)
                for dx in -rx...rx {
                    let offset = (y * width + clamp(dx, width)) * 4
                    for c in 0..<4 { sums[c] += columnSums[offset + c] }
                }
                for x in 0..<width {
                    let offset = (y * width + x) * 4
                    for c in 0..<4 { result[offset + c] = UInt8(sums[c] / divisor) }
                    let outgoing = (y * width + clamp(x - rx, width)) * 4
                    let incoming = (y * width + clamp(x + rx + 1, width)) * 4
                    for c in 0..<4 { sums[c] += columnSums[incoming + c] - columnSums[outgoing + c] }
                }
            }
            swap(&source, &result)
        }
        return Data(source)
    }
}
