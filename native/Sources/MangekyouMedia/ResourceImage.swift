import Foundation
import CoreGraphics
import CoreText
import ImageIO
import MangekyouCore

public struct ResourceImage: Sendable {
    public let image: CGImage
    public let format: String
    public let notes: [String]
    public let originalRendererEquivalence: EvidenceStatus = .notTested

    package init(image: CGImage, format: String, notes: [String]) {
        self.image = image
        self.format = format
        self.notes = notes
    }

    package static func savedDisplayRectPreview(_ rect: SaveStatePrefix.DisplaySummary.ProceduralRect,
                                                width: Int, height: Int) throws -> CGImage {
        guard (1...4096).contains(width), (1...4096).contains(height),
              let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ResourceError.rejected("saved_display_preview_canvas_limit")
        }
        func component(_ shift: Int) -> CGFloat {
            CGFloat((rect.colorARGB >> shift) & 255) / 255
        }
        canvas.setFillColor(red: component(16), green: component(8), blue: component(0), alpha: component(24))
        canvas.fill(CGRect(x: CGFloat(rect.left), y: CGFloat(height) - CGFloat(rect.bottom),
                           width: CGFloat(rect.right) - CGFloat(rect.left),
                           height: CGFloat(rect.bottom) - CGFloat(rect.top)))
        guard let result = canvas.makeImage() else {
            throw ResourceError.rejected("saved_display_preview_image_failed")
        }
        return result
    }

    package func savedDisplayPreview(transform: SaveStatePrefix.DisplaySummary.Reload.Transform,
                                     width: Int, height: Int) throws -> CGImage {
        guard (1...4096).contains(width), (1...4096).contains(height),
              let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw ResourceError.rejected("saved_display_preview_canvas_limit")
        }
        let w = CGFloat(width), h = CGFloat(height)
        // Native vertices are in top-left coordinates. Draw CGImage in its
        // usual bottom-left convention and convert translation and rotation.
        canvas.translateBy(x: w / 2 + CGFloat(transform.translationX),
                           y: h / 2 - CGFloat(transform.translationY))
        canvas.rotate(by: -CGFloat(transform.rotationTurns) * 2 * .pi)
        canvas.scaleBy(x: transform.scaleX, y: transform.scaleY)
        // The restore call selects the filtered scanner family at 0x5344ab.
        // Core Graphics approximates its fixed-point weights for the preview.
        canvas.interpolationQuality = .low
        canvas.setBlendMode(.copy)
        for row in -2...2 {
            for column in -2...2 {
                canvas.draw(image, in: CGRect(x: (CGFloat(column) - 0.5) * w,
                                              y: (CGFloat(row) - 0.5) * h, width: w, height: h))
            }
        }
        // 0x536968 scans alpha extrema. 0x5369f0 normalizes nontrivial
        // ranges in fixed point while keeping straight RGB unchanged.
        if let bytes = canvas.data?.assumingMemoryBound(to: UInt8.self) {
            let count = width * height * 4
            var minimum = 255, maximum = 0
            for offset in stride(from: 3, to: count, by: 4) {
                let alpha = Int(bytes[offset])
                minimum = min(minimum, alpha)
                maximum = max(maximum, alpha)
            }
            let range = maximum - minimum
            if range > 1, range != 255 {
                let multiplier = 0xff00 / range
                for offset in stride(from: 0, to: count, by: 4) {
                    let original = Int(bytes[offset + 3])
                    let alpha = (original - minimum) * multiplier / 256
                    for channel in offset..<(offset + 3) {
                        bytes[channel] = original == 0 ? 0 : UInt8((Int(bytes[channel]) * alpha + original / 2) / original)
                    }
                    bytes[offset + 3] = UInt8(alpha)
                }
            }
        }
        guard let result = canvas.makeImage() else {
            throw ResourceError.rejected("saved_display_preview_image_failed")
        }
        return result
    }

    package static func choiceLabelPreview(_ label: String, style: ScriptMachine.ChoiceTextStyle,
                                           width: Int, height: Int) throws -> Self {
        guard (1...4096).contains(width), (1...4096).contains(height),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ResourceError.rejected("unsupported_choice_label_surface")
        }
        let font = CTFontCreateWithName((style.fontName ?? "Hiragino Sans") as CFString, CGFloat(style.height), nil)
        func component(_ shift: Int) -> CGFloat { CGFloat((style.colorARGB >> shift) & 255) / 255 }
        let color = CGColor(red: component(16), green: component(8), blue: component(0), alpha: component(24))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): color
        ]))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let advance = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.textPosition = CGPoint(x: (CGFloat(width) - advance) / 2,
                                       y: (CGFloat(height) - ascent + descent) / 2)
        CTLineDraw(line, context)
        guard let image = context.makeImage() else { throw ResourceError.rejected("choice_label_preview_image") }
        return Self(image: image, format: "CoreText", notes: ["native_font_metrics"])
    }

    package static func textPreview(_ layer: ScriptMachine.MessageTextLayer, width: Int, height: Int) throws -> Self {
        let scaleX = CGFloat(layer.scaleXPercent) / 100
        let scaleY = CGFloat(layer.scaleYPercent) / 100
        let scaledWidth = CGFloat(width) * abs(scaleX)
        let scaledHeight = CGFloat(height) * abs(scaleY)
        let outputWidth = Int(ceil(scaledWidth))
        let outputHeight = Int(ceil(scaledHeight))
        guard (1...4096).contains(width), (1...4096).contains(height),
              (1...4096).contains(outputWidth), (1...4096).contains(outputHeight),
              let context = CGContext(data: nil, width: outputWidth, height: outputHeight, bitsPerComponent: 8,
                bytesPerRow: outputWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ResourceError.rejected("unsupported_text_preview_surface")
        }
        let text = NSMutableAttributedString()
        // Core Text metrics, ruby placement and line placement remain
        // approximations; the caller retains the unresolved-layout issue.
        let candidate = layer.runs.allSatisfy {
            Int64($0.width) + Int64($0.estimatedTracking) > 0 &&
            ($0.horizontalAdvance ?? 0) >= 0 &&
            ($0.ruby == nil || $0.text.rangeOfCharacter(from: .newlines) == nil)
        } && layer.runs.reduce(0, { $0 + $1.text.utf16.count }) <= 8192 ? layer.lineBreakCandidate : nil
        let lineStart = candidate.map { Array($0.prohibitedLineStart.utf16) } ?? []
        let lineEnd = candidate.map { Array($0.prohibitedLineEnd.utf16) } ?? []
        var candidatePen = 0.0
        var candidateBreaks = 0
        var candidateRubyRuns = 0
        var candidateIndentRuns = 0
        func containsToken(_ token: [UInt16], in units: [UInt16]) -> Bool {
            guard !token.isEmpty, token.count <= units.count else { return false }
            return (0...(units.count - token.count)).contains { start in
                units[start..<(start + token.count)].elementsEqual(token)
            }
        }
        for run in layer.runs {
            if let advance = run.horizontalAdvance {
                var callbacks = CTRunDelegateCallbacks(version: kCTRunDelegateVersion1,
                    dealloc: { $0.deallocate() }, getAscent: { _ in 0 }, getDescent: { _ in 0 },
                    getWidth: { $0.load(as: CGFloat.self) })
                let width = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<CGFloat>.size,
                                                             alignment: MemoryLayout<CGFloat>.alignment)
                width.storeBytes(of: CGFloat(advance), as: CGFloat.self)
                guard let delegate = CTRunDelegateCreate(&callbacks, width) else {
                    width.deallocate()
                    throw ResourceError.rejected("text_preview_advance")
                }
                text.append(NSAttributedString(string: "\u{fffc}", attributes: [
                    .init(kCTRunDelegateAttributeName as String): delegate
                ]))
                if candidate != nil {
                    candidatePen += Double(advance)
                    candidateIndentRuns += 1
                }
                continue
            }
            let size = CGFloat(run.height)
            var matrix = CGAffineTransform(scaleX: CGFloat(run.width) / size, y: 1)
            let font = CTFontCreateWithName((run.fontName ?? "Hiragino Sans") as CFString, size, &matrix)
            func color(_ argb: UInt32) -> CGColor {
                func component(_ shift: Int) -> CGFloat { CGFloat((argb >> shift) & 255) / 255 }
                return CGColor(red: component(16), green: component(8), blue: component(0), alpha: component(24))
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .init(kCTFontAttributeName as String): font,
                .init(kCTForegroundColorAttributeName as String): color(run.colorARGB)
            ]
            if run.estimatedTracking != 0 {
                attributes[.init(kCTKernAttributeName as String)] = CGFloat(run.estimatedTracking)
            }
            if let ruby = run.ruby, !ruby.text.isEmpty {
                let rubySize = ruby.height.map { CGFloat($0) } ?? size / 2
                let ratio = ruby.width.flatMap { width in ruby.height.map { CGFloat(width) / CGFloat($0) } } ?? 1
                var rubyMatrix = CGAffineTransform(scaleX: ratio, y: 1)
                let rubyFont = CTFontCreateWithName(
                    (ruby.fontName ?? run.fontName ?? "Hiragino Sans") as CFString, rubySize, &rubyMatrix)
                attributes[.init(kCTRubyAnnotationAttributeName as String)] = CTRubyAnnotationCreateWithAttributes(
                    .center, .auto, .before, ruby.text as CFString,
                    [kCTFontAttributeName: rubyFont,
                     kCTForegroundColorAttributeName: color(ruby.colorARGB ?? run.colorARGB)] as CFDictionary)
            }
            if let candidate {
                if run.ruby != nil {
                    candidateRubyRuns += 1
                    // The audited ruby entry passes the force class to the
                    // native break check. Its width remains a Core Text estimate.
                    let available = Int64((Double(width) - candidatePen) /
                        Double(Int64(run.width) + Int64(run.estimatedTracking)))
                    if available < 1 {
                        text.append(NSAttributedString(string: "\n", attributes: attributes))
                        candidatePen = 0
                        candidateBreaks += 1
                    }
                    let token = NSAttributedString(string: run.text, attributes: attributes)
                    candidatePen += CTLineGetTypographicBounds(CTLineCreateWithAttributedString(token), nil, nil, nil)
                    text.append(token)
                    continue
                }
                for character in run.text {
                    let value = String(character)
                    if character.isNewline {
                        text.append(NSAttributedString(string: value, attributes: attributes))
                        candidatePen = 0
                        continue
                    }
                    let units = Array(value.utf16)
                    let available = Int64((Double(width) - candidatePen) /
                        Double(Int64(run.width) + Int64(run.estimatedTracking)))
                    let atStart = candidate.reserve != 0 && containsToken(units, in: lineStart)
                    let atEnd = candidate.reserve != 0 && containsToken(units, in: lineEnd)
                    let remaining = available - Int64(candidate.reserve)
                    if available < 1 || (!atStart && (atEnd ? remaining < 2 : remaining < 1)) {
                        text.append(NSAttributedString(string: "\n", attributes: attributes))
                        candidatePen = 0
                        candidateBreaks += 1
                    }
                    let token = NSAttributedString(string: value, attributes: attributes)
                    candidatePen += CTLineGetTypographicBounds(CTLineCreateWithAttributedString(token), nil, nil, nil)
                    text.append(token)
                }
            } else {
                text.append(NSAttributedString(string: run.text, attributes: attributes))
            }
        }
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil)
        context.clear(CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
        // Keep ceil padding on the bottom and right in the top-left canvas.
        context.translateBy(x: scaleX < 0 ? scaledWidth : 0,
                            y: scaleY < 0 ? CGFloat(outputHeight) : CGFloat(outputHeight) - scaledHeight)
        context.scaleBy(x: scaleX, y: scaleY)
        context.textMatrix = .identity
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(text), CFRange(), path, nil)
        var missingGlyphCount = 0
        var textTruncated = false
        func inspectGlyphs(_ line: CTLine) {
            let runs = CTLineGetGlyphRuns(line) as NSArray
            for index in 0..<runs.count {
                let run = runs[index] as! CTRun
                let attributes = CTRunGetAttributes(run) as NSDictionary
                if attributes[kCTRunDelegateAttributeName] != nil { continue }
                let count = CTRunGetGlyphCount(run)
                guard count > 0 else { continue }
                if let font = attributes[kCTFontAttributeName] as! CTFont?,
                   (CTFontCopyPostScriptName(font) as String).lowercased().contains("lastresort") {
                    missingGlyphCount += count
                    continue
                }
                var glyphs = [CGGlyph](repeating: 0, count: count)
                glyphs.withUnsafeMutableBufferPointer { buffer in
                    CTRunGetGlyphs(run, CFRange(location: 0, length: 0), buffer.baseAddress!)
                }
                missingGlyphCount += glyphs.count { $0 == 0 }
            }
        }
        if CFArrayGetCount(CTFrameGetLines(frame)) == 0, text.length > 0,
           text.string.rangeOfCharacter(from: .newlines) == nil {
            // A short surface can fit the glyphs while rejecting the font's
            // full line metrics. Draw one line within the original clip.
            let line = CTLineCreateWithAttributedString(text)
            inspectGlyphs(line)
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            let advance = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
            textTruncated = advance > Double(width)
            context.clip(to: CGRect(x: 0, y: 0, width: width, height: height))
            context.textPosition = CGPoint(x: 0, y: (CGFloat(height) - ascent + descent) / 2)
            CTLineDraw(line, context)
        } else {
            let lines = CTFrameGetLines(frame) as NSArray
            for index in 0..<lines.count { inspectGlyphs(lines[index] as! CTLine) }
            let visible = CTFrameGetVisibleStringRange(frame)
            textTruncated = visible.location < 0 || visible.length < 0 ||
                visible.location > text.length || visible.length < text.length - visible.location
            CTFrameDraw(frame, context)
        }
        guard let image = context.makeImage() else { throw ResourceError.rejected("text_preview_image") }
        var notes = ["native_font_metrics", "missing_glyphs:\(missingGlyphCount)",
                     textTruncated ? "text_truncated" : "text_complete"]
        if candidate != nil { notes.append("line_break_candidate:\(candidateBreaks)") }
        if candidateRubyRuns > 0 { notes.append("line_break_candidate_ruby:\(candidateRubyRuns)") }
        if candidateIndentRuns > 0 { notes.append("line_break_candidate_indent:\(candidateIndentRuns)") }
        return Self(image: image, format: "CoreText", notes: notes)
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 16 * 1024 * 1024 else { throw ResourceError.rejected("image_source_limit") }
        let format = InventoryScanner.signature(data)
        if format == "DPNG" { return try decodeDPNG(data) }
        if format == "ARGB" {
            let header = try SaveStatePrefix.ARGBHeader(data)
            if (2...4).contains(header.mode) {
                let split = data.startIndex + 25 + header.firstPayloadLength
                let first = Data(data[(data.startIndex + 25)..<split])
                let second = Data(data[split...])
                return try decodeARGBPlanes(color: header.mode == 4 ? second : first,
                                            mask: header.mode == 4 ? first : second, mode: header.mode)
            }
            guard header.mode == 1, header.secondPayloadLength == 0,
                  header.firstPayloadLength >= 33 else {
                throw ResourceError.rejected("saved_argb_mode_outside_profile")
            }
            let png = Data(data.dropFirst(25))
            guard InventoryScanner.signature(png) == "PNG",
                  png[12..<16].elementsEqual("IHDR".utf8), png[24] == 8, png[25] == 6 else {
                throw ResourceError.rejected("saved_argb_mode_one_requires_rgba_png")
            }
            return Self(image: try decodeStandard(png, identifier: "public.png"), format: "ARGB",
                        notes: ["argb_mode_one_rgba_png"])
        }

        let identifiers = ["PNG": "public.png", "JPEG": "public.jpeg", "BMP": "com.microsoft.bmp"]
        guard let identifier = identifiers[format] else { throw ResourceError.rejected("unsupported_image_format") }
        return Self(image: try decodeStandard(data, identifier: identifier), format: format, notes: [])
    }

    /// Read straight BGRA for CPU texture sampling. Drawing into a premultiplied
    /// CGContext would erase RGB in fully transparent mask pixels.
    package static func straightPNGPixels(_ data: Data) throws -> [[SIMD4<UInt8>]] {
        guard data.count <= 16 * 1024 * 1024 else { throw ResourceError.rejected("image_source_limit") }
        guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else {
            throw ResourceError.rejected("straight_texture_requires_png")
        }
        let image = try decodeStandard(data, identifier: "public.png")
        let width = image.width
        let height = image.height
        let alpha = image.alphaInfo
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 32,
              image.bitmapInfo.rawValue == alpha.rawValue,
              alpha == .last || alpha == .noneSkipLast,
              width > 0, height <= 16_777_216 / width,
              image.bytesPerRow >= width * 4,
              let provider = image.dataProvider?.data else {
            throw ResourceError.rejected("unsupported_straight_texture_layout")
        }
        let stride = image.bytesPerRow
        guard height <= CFDataGetLength(provider) / stride, let bytes = CFDataGetBytePtr(provider) else {
            throw ResourceError.rejected("truncated_straight_texture")
        }
        return (0..<height).map { y in
            (0..<width).map { x in
                let index = y * stride + x * 4
                return SIMD4(bytes[index + 2], bytes[index + 1], bytes[index],
                             alpha == .last ? bytes[index + 3] : 255)
            }
        }
    }

    /// Return an opaque PNG in the scene canvas's top-down BGRA lane order without drawing through a color-managed context.
    package static func opaquePNGCanvasPixels(_ data: Data, width: Int, height: Int) throws -> [[SIMD4<UInt8>]] {
        guard (1...4096).contains(width), (1...4096).contains(height), height <= 16_777_216 / width else {
            throw ResourceError.rejected("opaque_png_canvas_dimensions")
        }
        let bgra = try straightPNGPixels(data)
        guard bgra.count == height, bgra.allSatisfy({ $0.count == width }),
              bgra.allSatisfy({ row in row.allSatisfy { $0.w == 255 } }) else {
            throw ResourceError.rejected("opaque_png_canvas_requires_full_opaque_raster")
        }
        return bgra
    }

    /// Build an opaque CPU destination from an already decoded background image.
    package func opaqueCanvas(over background: CGColor) throws -> [[SIMD4<UInt8>]] {
        let width = image.width
        let height = image.height
        guard background.alpha == 1, width > 0, height <= 16_777_216 / width,
              let context = CGContext(data: nil, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let storage = context.data else {
            throw ResourceError.rejected("unsupported_opaque_canvas")
        }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(background)
        context.fill(bounds)
        context.interpolationQuality = .none
        context.draw(image, in: bounds)
        let bytes = storage.assumingMemoryBound(to: UInt8.self)
        return (0..<height).map { y in
            (0..<width).map { x in
                let index = (y * width + x) * 4
                return SIMD4(bytes[index + 2], bytes[index + 1], bytes[index], 255)
            }
        }
    }

    /// Composite a translated raster with normal premultiplied source-over.
    @discardableResult
    package func drawRasterPreview(origin: SIMD2<Int>, opacity: UInt8,
                                   size: SIMD2<Int>? = nil, flipX: Bool = false, flipY: Bool = false,
                                   interpolation: CGInterpolationQuality = .none, canvas: inout [[SIMD4<UInt8>]]) throws -> Bool {
        try drawRasterPreview(bounds: CGRect(x: origin.x, y: origin.y,
            width: size?.x ?? image.width, height: size?.y ?? image.height),
            opacity: opacity, flipX: flipX, flipY: flipY, interpolation: interpolation, canvas: &canvas)
    }

    package func drawRasterPreview(bounds: CGRect, opacity: UInt8,
                                   flipX: Bool = false, flipY: Bool = false,
                                   interpolation: CGInterpolationQuality = .none, canvas: inout [[SIMD4<UInt8>]]) throws -> Bool {
        let width = bounds.size.width
        let height = bounds.size.height
        guard width > 0, width <= 65_536, height > 0, height <= 65_536,
              bounds.origin.x.isFinite, bounds.origin.y.isFinite else {
            throw ResourceError.rejected("raster_preview_size_outside_profile")
        }
        let clipped = bounds.intersection(CGRect(x: 0, y: 0, width: canvas.first?.count ?? 0, height: canvas.count))
        guard opacity > 0, !clipped.isEmpty else { return false }
        let pixels = clipped.integral
        let left = Int(pixels.minX)
        let top = Int(pixels.minY)
        let right = Int(pixels.maxX)
        let bottom = Int(pixels.maxY)
        let stride = (right - left) * 4
        guard let context = CGContext(data: nil, width: right - left, height: bottom - top,
            bitsPerComponent: 8, bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let data = context.data else { throw ResourceError.rejected("raster_preview_context") }
        context.clear(CGRect(x: 0, y: 0, width: right - left, height: bottom - top))
        context.interpolationQuality = interpolation
        context.setAlpha(CGFloat(opacity) / 255)
        let x = bounds.minX - CGFloat(left)
        let y = CGFloat(bottom) - bounds.maxY
        context.translateBy(x: CGFloat(x + (flipX ? width : 0)), y: CGFloat(y + (flipY ? height : 0)))
        context.scaleBy(x: flipX ? -1 : 1, y: flipY ? -1 : 1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var coveredPixels = false
        for y in top..<bottom {
            for x in left..<right {
                let i = (y - top) * stride + (x - left) * 4
                let alpha = Int(bytes[i + 3])
                guard alpha != 0 else { continue }
                coveredPixels = true
                let target = canvas[y][x]
                func channel(_ source: UInt8, _ destination: UInt8) -> UInt8 {
                    UInt8(clamping: Int(source) + (Int(destination) * (255 - alpha) + 127) / 255)
                }
                canvas[y][x] = SIMD4(channel(bytes[i + 2], target.x), channel(bytes[i + 1], target.y),
                                     channel(bytes[i], target.z), 255)
            }
        }
        return coveredPixels
    }

    private static func decodeARGBPlanes(color: Data, mask: Data, mode: UInt8) throws -> Self {
        let colorImage = try decodeStandard(color, identifier: "public.jpeg")
        let usesPNGMask = mode != 2
        let alphaImage = try decodeStandard(mask, identifier: usesPNGMask ? "public.png" : "public.jpeg")
        if usesPNGMask {
            guard alphaImage.alphaInfo == .first || alphaImage.alphaInfo == .last ||
                  alphaImage.alphaInfo == .premultipliedFirst || alphaImage.alphaInfo == .premultipliedLast else {
                throw ResourceError.rejected("saved_argb_png_mask_requires_alpha")
            }
        }
        let width = colorImage.width, height = colorImage.height
        guard alphaImage.width == width, alphaImage.height == height else {
            throw ResourceError.rejected("saved_argb_jpeg_size_mismatch")
        }
        let space = CGColorSpaceCreateDeviceRGB()
        let rowBytes = width * 4
        func raster(_ image: CGImage, preserveAlpha: Bool = false) throws -> Data {
            var pixels = Data(count: rowBytes * height)
            try pixels.withUnsafeMutableBytes { bytes in
                guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: rowBytes, space: space,
                    bitmapInfo: (preserveAlpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue |
                        CGBitmapInfo.byteOrder32Big.rawValue) else {
                    throw ResourceError.rejected("saved_argb_plane_context_failed")
                }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            return pixels
        }
        var pixels = try raster(colorImage)
        let maskPixels = try raster(alphaImage, preserveAlpha: usesPNGMask)
        let maskChannel = usesPNGMask ? 3 : 2
        pixels.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
            maskPixels.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
                for offset in stride(from: 0, to: out.count, by: 4) {
                    // The JPEG path uses BGR's first byte. PNG supplies its alpha plane.
                    let a = Int(input[offset + maskChannel])
                    for channel in offset..<(offset + 3) {
                        out[channel] = UInt8((Int(out[channel]) * a + 127) / 255)
                    }
                    out[offset + 3] = UInt8(a)
                }
            }
        }
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                 bytesPerRow: rowBytes, space: space,
                 bitmapInfo: [.byteOrder32Big, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)],
                 provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw ResourceError.rejected("saved_argb_jpeg_image_failed")
        }
        return Self(image: image, format: "ARGB", notes: ["argb_mode_\(mode)_color_and_alpha"])
    }

    private static func decodeStandard(_ data: Data, identifier: String) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.int64Value > 0, height.int64Value > 0,
              width.int64Value <= 16_000, height.int64Value <= 16_000,
              width.int64Value * height.int64Value <= 16_000_000,
              let type = CGImageSourceGetType(source) as String?,
              type == identifier
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
                let image = try decodeStandard(data.subdata(in: tile.payload), identifier: "public.png")
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

extension ResourceImage {
    /// Decode the optional JPEG carried by a validated original save slot.
    public static func decodeSaveThumbnail(_ data: Data) throws -> Self? {
        guard let slot = try SaveEnvelope(data).slot else {
            throw ResourceError.rejected("save_slot_required")
        }
        let section = slot.thumbnail
        guard section.length > 0 else { return nil }
        let start = data.startIndex + section.offset
        let jpeg = Data(data[start..<(start + section.length)])
        guard InventoryScanner.signature(jpeg) == "JPEG" else {
            throw ResourceError.rejected("save_thumbnail_requires_jpeg")
        }
        return try decode(jpeg)
    }
}
