import Foundation

public enum ScriptMovieHeader {
    static func validateVorbis(_ data: Data) throws {
        _ = try packetOffset(data, identification: Data([0x01]) + Data("vorbis".utf8), minimumPacket: 30,
                     failure: "ogg_vorbis_identification_missing")
    }

    public static func theoraDimensions(_ data: Data) throws -> (Int, Int) {
        let start = try packetOffset(data, identification: Data([0x80]) + Data("theora".utf8),
            minimumPacket: 42, failure: "ogg_theora_identification_missing")
        func dimension(_ offset: Int) -> Int {
            let i = start + offset
            return (Int(data[i]) << 16) | (Int(data[i+1]) << 8) | Int(data[i+2])
        }
        return (dimension(14), dimension(17))
    }

    /// The frame-rate ratio in the bounded Theora identification packet.
    public static func theoraFrameRate(_ data: Data) throws -> (numerator: UInt32, denominator: UInt32) {
        let start = try packetOffset(data, identification: Data([0x80]) + Data("theora".utf8),
            minimumPacket: 42, failure: "ogg_theora_identification_missing")
        func word(_ offset: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(data[start + offset + $1]) }
        }
        let numerator = word(22), denominator = word(26)
        guard numerator > 0, denominator > 0 else {
            throw ResourceError.rejected("ogg_theora_frame_rate_invalid")
        }
        return (numerator, denominator)
    }

    /// A bounded loop period for complete, single-stream Theora 3.2.1.
    /// Count frame packets and cross-check their page granules (Theora I, A.2).
    package static func standaloneTheoraDuration(_ data: Data) throws -> Int32 {
        let failure = ResourceError.rejected("standalone_theora_timing_outside_profile")
        guard data.count <= 16 * 1024 * 1024 else { throw failure }
        let identification = try packetOffset(data, identification: Data([0x80]) + Data("theora".utf8),
                                              minimumPacket: 42, failure: "ogg_theora_identification_missing")
        let (width, height) = try theoraDimensions(data)
        let rate = try theoraFrameRate(data)
        guard identification == data.startIndex + 28,
              data[identification + 7..<identification + 10].elementsEqual([3, 2, 1]),
              rate.numerator == 30, rate.denominator == 1,
              (1...4096).contains(width), (1...4096).contains(height), width * height <= 4_194_304 else {
            throw failure
        }
        let shift = Int(data[identification + 40] & 3) * 8 + Int(data[identification + 41] >> 5)
        let mask = (UInt64(1) << shift) - 1
        return try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            let serial = bytes.loadUnaligned(fromByteOffset: 14, as: UInt32.self)
            var offset = 0
            var sequence: UInt32 = 0
            var packets = 0
            var continued = false
            var ended = false
            while offset < bytes.count {
                guard bytes.count - offset >= 27, sequence < 4096,
                      bytes[offset..<offset+4].elementsEqual([79, 103, 103, 83]), bytes[offset+4] == 0,
                      bytes.loadUnaligned(fromByteOffset: offset+14, as: UInt32.self) == serial,
                      UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset+18, as: UInt32.self)) == sequence else {
                    throw failure
                }
                let flags = bytes[offset+5]
                let count = Int(bytes[offset+26])
                let table = offset + 27
                guard !ended, flags & ~7 == 0, (flags & 1 != 0) == continued,
                      (flags & 2 != 0) == (sequence == 0), count > 0, count <= bytes.count - table else {
                    throw failure
                }
                let sizes = bytes[table..<table+count]
                let bodyLength = sizes.reduce(0) { $0 + Int($1) }
                let body = table + count
                guard bodyLength <= bytes.count - body,
                      sequence != 0 || (count == 1 && bodyLength == 42) else { throw failure }
                let completed = sizes.reduce(0) { $0 + ($1 < 255 ? 1 : 0) }
                packets += completed
                continued = bytes[body - 1] == 255
                let granule = UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset+6, as: UInt64.self))
                guard packets <= 303 else { throw failure }
                if completed == 0 {
                    guard granule == UInt64.max else { throw failure }
                } else if packets <= 3 {
                    guard granule == 0 else { throw failure }
                } else {
                    guard granule != UInt64.max, granule >> shift > 0,
                          (granule >> shift) + (granule & mask) == UInt64(packets - 3) else { throw failure }
                }
                ended = flags & 4 != 0
                offset = body + bodyLength
                sequence += 1
            }
            let frames = packets - 3
            guard ended, !continued, (30...300).contains(frames), frames % 3 == 0 else { throw failure }
            return Int32(frames * 1000 / 30)
        }
    }

    private static func packetOffset(_ data: Data, identification: Data, minimumPacket: Int, failure: String) throws -> Int {
        let magic = Data("OggS".utf8)
        var start = data.startIndex
        let end = data.endIndex
        for _ in 0..<16 {
            guard end-start >= 27, data[start..<start+4].elementsEqual(magic),
                  data[start+4] == 0, data[start+5] & 2 != 0 else { break }
            let count = Int(data[start+26])
            let body = start+27+count
            guard body <= end, count > 0 else { break }
            let size = data[start+27..<body].reduce(0) { $0+Int($1) }
            guard size <= end-body else { break }
            if Int(data[start+27]) >= minimumPacket,
               data[body..<body+identification.count].elementsEqual(identification) { return body }
            start = body+size
        }
        throw ResourceError.rejected(failure)
    }
}
