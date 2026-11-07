import Foundation

enum ScriptMovieHeader {
    static func validateTheora(_ data: Data) throws {
        try validate(data, identification: Data([0x80]) + Data("theora".utf8), minimumPacket: 42,
                     failure: "ogg_theora_identification_missing")
    }

    static func validateVorbis(_ data: Data) throws {
        try validate(data, identification: Data([0x01]) + Data("vorbis".utf8), minimumPacket: 30,
                     failure: "ogg_vorbis_identification_missing")
    }

    private static func validate(_ data: Data, identification: Data, minimumPacket: Int, failure: String) throws {
        let magic = Data("OggS".utf8)
        var start = 0
        for _ in 0..<16 {
            guard data.count-start >= 27, data[start..<start+4].elementsEqual(magic),
                  data[start+4] == 0, data[start+5] & 2 != 0 else { break }
            let count = Int(data[start+26])
            let body = start+27+count
            guard body <= data.count, count > 0 else { break }
            let size = data[start+27..<body].reduce(0) { $0+Int($1) }
            guard size <= data.count-body else { break }
            if Int(data[start+27]) >= minimumPacket,
               data[body..<body+identification.count].elementsEqual(identification) { return }
            start = body+size
        }
        throw ResourceError.rejected(failure)
    }
}
