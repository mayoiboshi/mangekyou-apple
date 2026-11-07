import Foundation
import CoreGraphics
import ImageIO
import MangekyouCore

public struct ResourceImage {
    public let image: CGImage
    public let format: String
    public let notes: [String]
    public let originalRendererEquivalence: EvidenceStatus = .notTested

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 16 * 1024 * 1024 else { throw ResourceError.rejected("image_source_limit") }
        let format = InventoryScanner.signature(data)
        if format == "DPNG" { return try decodeDPNG(data) }
        guard ["PNG", "JPEG"].contains(format) else { throw ResourceError.rejected("unsupported_image_format") }
        return Self(image: try decodeStandard(data, format: format), format: format, notes: [])
    }

    private static func decodeStandard(_ data: Data, format: String) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.int64Value > 0, height.int64Value > 0,
              width.int64Value <= 16_000, height.int64Value <= 16_000,
              width.int64Value * height.int64Value <= 16_000_000,
              let type = CGImageSourceGetType(source) as String?,
              type == (format == "PNG" ? "public.png" : "public.jpeg")
        else { throw ResourceError.rejected("image_metadata_or_pixel_limit") }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0,
            [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              image.width == width.intValue, image.height == height.intValue
        else { throw ResourceError.rejected("image_decode_failed") }
        return image
    }

    private static func decodeDPNG(_ data: Data) throws -> Self {
        let descriptor = try DPNGDescriptor.parse(data)
        guard let context = CGContext(data: nil, width: descriptor.width, height: descriptor.height,
            bitsPerComponent: 8, bytesPerRow: descriptor.width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ResourceError.rejected("image_allocation_failed") }
        context.clear(CGRect(x: 0, y: 0, width: descriptor.width, height: descriptor.height))
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        // Source coordinates are top-down. Quartz's bitmap drawing coordinates are bottom-up.
        for tile in descriptor.tiles {
            if tile.flags[0] == 1, tile.height > 0 {
                context.setFillColor(CGColor(red: 136.0/255, green: 136.0/255, blue: 136.0/255, alpha: 0))
                context.fill(CGRect(x: 0, y: descriptor.height - tile.y - tile.height,
                    width: descriptor.width, height: tile.height))
            }
            if !tile.payload.isEmpty {
                let image = try decodeStandard(data.subdata(in: tile.payload), format: "PNG")
                guard image.width == tile.width, image.height == tile.height else { throw ResourceError.rejected("dpng_decoded_tile_shape") }
                context.draw(image, in: CGRect(x: tile.x, y: descriptor.height - tile.y - tile.height,
                    width: tile.width, height: tile.height))
            }
        }
        guard let image = context.makeImage() else { throw ResourceError.rejected("image_creation_failed") }
        return Self(image: image, format: "DPNG", notes: [
            "研究性图片预览，尚未通过原引擎画面对照。",
            "显示缓冲使用预乘透明度；不保留 alpha 为零处的原始 RGB。",
            "拼片按文件顺序替换；重叠和原程序并行时序尚未验证。"
        ])
    }
}
