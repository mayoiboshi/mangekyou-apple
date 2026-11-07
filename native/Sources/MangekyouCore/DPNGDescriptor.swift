import Foundation

public struct DPNGDescriptor: Sendable {
    public struct Tile: Sendable {
        public let index: Int
        public let x: Int
        public let y: Int
        public let width: Int
        public let height: Int
        public let payload: Range<Int>
        public let flags: [UInt32]
    }
    public let width: Int
    public let height: Int
    public let headerField: UInt32
    public let tiles: [Tile]
    public static func parse(_ data: Data) throws -> Self {
        guard data.count >= 20, data.count <= 16 * 1024 * 1024,
              data.starts(with: Data("DPNG".utf8)) else { throw ResourceError.rejected("invalid_dpng_header") }
        let field = try data.u32(4), count = Int(try data.u32(8))
        let width = Int(try data.u32(12)), height = Int(try data.u32(16))
        guard field <= 1 else { throw ResourceError.rejected("unreviewed_dpng_header_field") }
        guard width > 0, height > 0, width <= 16_000, height <= 16_000,
              Int64(width) * Int64(height) <= 16_000_000, count <= 32,
              count <= (data.count - 20) / 28 else { throw ResourceError.rejected("dpng_canvas_or_tile_limit") }
        var offset = 20, tilePixels: Int64 = 0, tiles: [Tile] = []
        for index in 0..<count {
            guard offset <= data.count - 28 else { throw ResourceError.rejected("truncated_dpng_tile") }
            let values = try (0..<7).map { try data.u32(offset + $0 * 4) }
            let x = Int(values[0]), y = Int(values[1]), w = Int(values[2]), h = Int(values[3]), length = Int(values[4])
            offset += 28
            guard x <= width, y <= height, w <= width - x, h <= height - y,
                  length <= data.count - offset else { throw ResourceError.rejected("dpng_tile_bounds") }
            guard values[5] <= 1, values[6] == 0 else { throw ResourceError.rejected("unreviewed_dpng_tile_flags") }
            tilePixels += Int64(w) * Int64(h)
            guard tilePixels <= 32_000_000 else { throw ResourceError.rejected("dpng_tile_pixel_limit") }
            if length > 0 {
                guard w > 0, h > 0, length >= 33 else { throw ResourceError.rejected("invalid_dpng_png_size") }
                let png = data.subdata(in: offset..<offset + 33)
                guard InventoryScanner.signature(png) == "PNG", png.subdata(in: 12..<16) == Data("IHDR".utf8),
                      png[8..<12] == Data([0,0,0,13]), png[24] == 8, [2,6].contains(png[25])
                else { throw ResourceError.rejected("unreviewed_dpng_png_layout") }
                let pw = png[16..<20].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                let ph = png[20..<24].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                guard Int(pw) == w, Int(ph) == h else { throw ResourceError.rejected("dpng_png_dimension_mismatch") }
            }
            tiles.append(Tile(index: index, x: x, y: y, width: w, height: h,
                payload: offset..<offset + length, flags: [values[5],values[6]]))
            offset += length
        }
        guard offset == data.count else { throw ResourceError.rejected("dpng_trailing_bytes") }
        return Self(width: width, height: height, headerField: field, tiles: tiles)
    }
}
