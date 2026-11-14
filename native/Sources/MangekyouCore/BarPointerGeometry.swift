import Foundation

/// Numeric portion of the slider pointer path, without hit testing or callback dispatch.
public struct BarPointerGeometry: Sendable {
    public enum Rounding: String, Sendable {
        case nearestEven, towardZero, down, up

        fileprivate var rule: FloatingPointRoundingRule {
            switch self {
            case .nearestEven: return .toNearestOrEven
            case .towardZero: return .towardZero
            case .down: return .down
            case .up: return .up
            }
        }
    }

    public let start: Int32
    public let end: Int32
    public let maximum: Int32

    public init?(knobLength: Int32, trackLength: Int32, maximum: Int32) {
        guard (0...8192).contains(knobLength), (0...8192).contains(trackLength), maximum >= 0 else { return nil }
        let half = knobLength / 2
        self.start = half
        self.end = max(half + 1, trackLength - half)
        self.maximum = maximum
    }

    /// The caller supplies the x87 rounding mode; actual engine state is not inferred.
    public func value(pointer: Int32, origin: Int32, rounding: Rounding) -> Int32? {
        // 0x67e386–0x67e3a9 uses the low 32 bits of the signed product,
        // converts the quotient to Float32, then uses x87 FISTP.
        let relative = pointer &- origin &- start
        let product = relative &* maximum
        let quotient = Float(Double(product) / Double(end - start))
        guard quotient.isFinite, let integer = Int32(exactly: quotient.rounded(rounding.rule)) else { return nil }
        return min(max(integer, 0), maximum)
    }
}
