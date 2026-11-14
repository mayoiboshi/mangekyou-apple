/// Candidate for the signed 32-bit comparison at 0x59fada–0x59fae0.
/// The caller supplies the native-style millisecond clock and configured lock
/// interval; script ticks and host decoding time are not substitutes.
enum DirectSoundTiming {
    static func permitsPlayback(now: UInt32, previous: UInt32, lockMilliseconds: Int32) -> Bool {
        Int32(bitPattern: now &- previous) >= lockMilliseconds
    }
}
