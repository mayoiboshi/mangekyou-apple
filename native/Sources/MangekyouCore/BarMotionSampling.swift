import Foundation

/// Candidate for the numeric part of 0x67eb0c; no rendering or input is implied.
public enum BarMotionSampling {
    /// The fixed executable initializes DAT_006f7390 to zero, selecting power by default.
    /// Quartic remains as the alternate if runtime state changes that global.
    public enum Easing: String, Sendable {
        case power, quartic
    }

    public static func animationTime(start: Int32, target: Int32, maximum: Int32,
                                     duration: Int32, remaining: Int32,
                                     animationDuration: Int32, easing: Easing) -> Float? {
        guard maximum >= 0, duration >= 0, remaining >= 0, remaining <= duration,
              animationDuration >= 0 else { return nil }
        guard maximum > 0 else { return 0 }
        let progress: Float = duration < 1 ? 1 : 1 - Float(remaining) / Float(duration)
        let weight: Float
        switch easing {
        case .power:
            // 0x50ba53 selects exponent 2*1.4+1 for the caller's mode 2.
            weight = Float(1 - pow(Double(1 - progress), 3.8))
        case .quartic:
            // 0x50c35c evaluates the fourth power for the same mode.
            let left = 1 - progress
            let squared = left * left
            weight = 1 - squared * squared
        }
        let value = Float(start) * (1 - weight) + Float(target) * weight
        return Float(animationDuration) * (value / Float(maximum))
    }
}
