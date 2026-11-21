import Foundation

/// Explicitly supplied research identity; never enabled by the player by default.
package struct ResearchVideoSaveProfile: Sendable {
    package let sourceSHA256: String
    package let filterSHA256: String
    package let duration: Int32

    package init(sourceSHA256: String, filterSHA256: String, duration: Int32) {
        self.sourceSHA256 = sourceSHA256
        self.filterSHA256 = filterSHA256
        self.duration = duration
    }

    func matches(_ source: ScriptLocation, filters: [Int32: String]) -> Bool {
        guard source.sourceSHA256 == sourceSHA256, source.rangeSHA256 == sourceSHA256,
              source.byteOffset == 0, source.sourceFile.lowercased().hasSuffix(".ogv"),
              filters.count == 1, let descriptor = filters[0] else { return false }
        return Data(descriptor.utf8).sha256Hex == filterSHA256
    }
}

/// Candidate for the first layer of a standalone looping video.
/// The duration and identity must be independently verified by the caller.
package enum StandaloneVideoClockCandidate {
    // The original standalone Theora surface bypasses the static-image filter
    // copy. Preserve the descriptor observed in this title for script and save
    // state while sampling the decoder's video surface.
    static func supportsDirectSurfaceFilters(_ filters: [Int32: String]) -> Bool {
        if filters.isEmpty { return true }
        guard filters.count == 1, let descriptor = filters[0], descriptor.utf8.count == 33 else { return false }
        return Data(descriptor.utf8).sha256Hex == "b9b034a63dd1b677f362afed77e9819175c37db49f175c9b869b349ffa20bb6c"
    }

    package static func advance(times: [Int32], auxiliary: [Int32], delta: Int32,
                                duration: Int32) -> (times: [Int32], auxiliary: [Int32])? {
        guard times.count == 256, auxiliary.count == 256, duration >= 51,
              (0...50).contains(delta), auxiliary[0] == 0 else { return nil }
        let current = Float(bitPattern: UInt32(bitPattern: times[0]))
        guard current.isFinite, current >= 0, current < Float(duration) else { return nil }
        var next = current + Float(delta)
        guard next.isFinite else { return nil }
        if next >= Float(duration) { next -= Float(duration) }
        var updated = times
        updated[0] = Int32(bitPattern: next.bitPattern)
        return (updated, auxiliary)
    }
}
