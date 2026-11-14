import Foundation

/// Selected host elapsed-time calculation from the pinned executable.
/// This does not model frame scheduling, extra elapsed time or the zero flag.
package enum ScriptFrameClock {
    package static func elapsedMilliseconds(current: UInt32, previous: UInt32) -> Int32 {
        let difference = Int64(current) - Int64(previous)
        return Int32(min(5_000, max(1, difference)))
    }
}
