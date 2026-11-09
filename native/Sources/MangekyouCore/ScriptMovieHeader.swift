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
