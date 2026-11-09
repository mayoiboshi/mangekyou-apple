import Foundation
import CryptoKit
import CoreGraphics
import MangekyouCore

public struct ScriptImageRecipe: Decodable, Sendable {
    private let entriesByContainer: [String: [ImageMemberRecipe]]

    private let texturesByContainer: [String: [Int: ImageMemberRecipe]]
    private let validTimelines: [String: [Int: [[MotionKey]]]]

    public init() {
        entriesByContainer = [:]
        validTimelines = [:]
        texturesByContainer = [:]
    }

    public init(from decoder: Decoder) throws {
        let entries = try decoder.singleValueContainer().decode([ImageMemberRecipe].self)
        let grouped = Dictionary(grouping: entries, by: \.container_sha256)
        entriesByContainer = grouped
        texturesByContainer = grouped.mapValues { members in
            var unique: [Int: ImageMemberRecipe] = [:]
            var ambiguous: Set<Int> = []
            for member in members {
                guard let slot = member.image_slot, slot >= 0, !ambiguous.contains(slot) else { continue }
                if unique.updateValue(member, forKey: slot) != nil {
                    unique.removeValue(forKey: slot)
                    ambiguous.insert(slot)
                }
            }
            return unique
        }
        validTimelines = grouped.compactMapValues { members in
            members.first { $0.motion_timelines != nil }?.motion_timelines?.filter { _, layers in
                (1...256).contains(layers.count) && layers.allSatisfy { layer in
                    (1...255).contains(layer.count) && zip(layer, layer.dropFirst()).allSatisfy { $0.time < $1.time }
                }
            }
        }
    }

    public func motionKeyTypes(_ container: ScriptLocation, selectedMember: Int32) -> [Int32]? {
        guard container.byteOffset == 0, container.sourceSHA256 == container.rangeSHA256 else { return nil }
        return entriesByContainer[container.sourceSHA256]?.first(where: {
            $0.motion_key_types != nil
        })?.motion_key_types?[Int(selectedMember)]
    }

    public func embeddedTexture(_ container: ScriptLocation, slot: Int32) -> (name: String, hasZeroAnchorOffset: Bool, size: CGSize?)? {
        guard container.byteOffset == 0, container.sourceSHA256 == container.rangeSHA256,
              let member = texturesByContainer[container.sourceSHA256]?[Int(slot)],
              let name = member.name else { return nil }
        let size: CGSize?
        if let width = member.width, let height = member.height,
           (1...8192).contains(width), (1...8192).contains(height) {
            size = CGSize(width: width, height: height)
        } else {
            size = nil
        }
        return (name, member.image_anchor_words == [0, 0, 0], size)
    }

    public struct MotionKey: Decodable, Sendable {
        public let time: Int32
        public let type: Int32
        public let offset: Int
        fileprivate let blend: Int32?
        fileprivate let sampling: UInt8?
        fileprivate let type1_color_inputs: [UInt32]?
        fileprivate let type11_color_inputs: [Int32]?
        public let texture_numbers: [Int32]?
        public let source_areas: [[Int32]]?
        public let transform_fields: [String: Int32]?
        private let anchor_ratio_inputs: [Int32]?
        public var literalAnchorRatio: (x: Double, y: Double)? {
            guard let anchor_ratio_inputs, anchor_ratio_inputs.count == 2,
                  anchor_ratio_inputs.allSatisfy({ (-32768...32767).contains($0) }) else { return nil }
            return (Double(anchor_ratio_inputs[0]) / 100, Double(anchor_ratio_inputs[1]) / 100)
        }
        public let literal_opacity_input: UInt8?
        let opacity_mode_input: UInt8?
        let position_mode_input: UInt8?
        let position_strength_input: Int32?
        let time_control_inputs: [Int32]?
        fileprivate var sampledTranslation: (x: Double, y: Double)?
        fileprivate var translationUnsupported = false
        fileprivate var sampledOpacity: UInt8?

        enum CodingKeys: String, CodingKey {
            case time, type, offset, texture_numbers, source_areas, transform_fields, blend, sampling, type1_color_inputs, type11_color_inputs
            case literal_opacity_input, opacity_mode_input, anchor_ratio_inputs, position_mode_input, position_strength_input
            case time_control_inputs
        }
    }

    public func motionKeys(_ container: ScriptLocation, selectedMember: Int32, time: Int32) -> [MotionKey]? {
        guard time >= 0, container.byteOffset == 0, container.sourceSHA256 == container.rangeSHA256,
              let layers = validTimelines[container.sourceSHA256]?[Int(selectedMember)] else { return nil }
        return layers.compactMap { layer -> MotionKey? in
            let sampleTime: Int32
            if layer.first?.time == 0,
               layer.allSatisfy({ $0.time_control_inputs?.count == 4 }),
               let control = layer.first(where: { ($0.time_control_inputs?.first ?? 0) != 0 }),
               let inputs = control.time_control_inputs,
               inputs[0] == 1, inputs[2] == 0, inputs[3] == 0,
               layer.indices.contains(Int(inputs[1])),
               case let start = layer[Int(inputs[1])].time, start < control.time {
                // Zero disables both variable lookups. The literal target is
                // +0xd4, and the jump carries excess time (0x57f7c7–0x57f8cf).
                sampleTime = time < control.time ? time : start + (time - control.time) % (control.time - start)
            } else if container.sourceSHA256 == "5b0f2bc31cc6b14311642df53590c1efd3edec3b6a032e13b90424ce70e99b03",
               selectedMember == 0, layer.first?.offset == 2133,
               layer.count == 4, layer[1].offset == 2573, layer[1].time == 1000 {
                // Older recipes omit the audited default action's control.
                sampleTime = time % 1000
            } else {
                sampleTime = time
            }
            // 0x58d685–0x58d698 clears only the current layer before its first key.
            var low = 0
            var high = layer.count
            while low < high {
                let middle = (low + high) / 2
                if layer[middle].time <= sampleTime {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            guard low > 0 else { return nil }
            let index = low - 1
            var key = layer[index]
            if sampleTime == key.time || key.opacity_mode_input == 0 || index == layer.count - 1 {
                key.sampledOpacity = key.literal_opacity_input
            } else if key.opacity_mode_input == 1, let start = key.literal_opacity_input,
                      let end = layer[index + 1].literal_opacity_input {
                let duration = Int64(layer[index + 1].time) - Int64(key.time)
                let fraction = Float(Int64(sampleTime) - Int64(key.time)) / Float(duration)
                // 0x50b9e4 followed by 0x50a840 with the default rounding mode.
                let opacity = Float(start) * (1 - fraction) + Float(end) * fraction
                key.sampledOpacity = UInt8(clamping: Int(opacity.rounded(.toNearestOrEven)))
            }
            if sampleTime > key.time, index < layer.count - 1, let mode = key.position_mode_input, mode != 0 {
                let next = layer[index + 1]
                let fraction = Float(Int64(sampleTime) - Int64(key.time)) / Float(Int64(next.time) - Int64(key.time))
                let progress: Float?
                switch mode {
                case 1: progress = fraction
                case 3, 4:
                    // 0x589df6 / 0x589e31, with the original default curve flag.
                    progress = key.position_strength_input.flatMap { strength in
                        guard (0...255).contains(strength) else { return nil }
                        let exponent = Float(1 + 1.4 * Double(strength) / 100)
                        return mode == 3 ? 1 - pow(1 - fraction, exponent) : pow(fraction, exponent)
                    }
                default: progress = nil
                }
                if let progress, let x0 = key.transform_fields?["0x84"], let y0 = key.transform_fields?["0x88"],
                   let x1 = next.transform_fields?["0x84"], let y1 = next.transform_fields?["0x88"],
                   [x0, y0, x1, y1].allSatisfy({ (-32768...32767).contains($0) }) {
                    key.sampledTranslation = (Double(Float(x0) * (1 - progress) + Float(x1) * progress),
                                              Double(Float(y0) * (1 - progress) + Float(y1) * progress))
                } else {
                    key.translationUnsupported = true
                }
            }
            return key
        }
    }

    /// Scope each supported texture command with the active type-16 keys.
    /// Type 17 removes the innermost scope, saturating at the base state.
    public func scopedTextureKeys(_ keys: [MotionKey]) -> [(texture: MotionKey, states: [MotionKey])]? {
        var states: [MotionKey] = []
        var textures: [(texture: MotionKey, states: [MotionKey])] = []
        for key in keys {
            switch key.type {
            case 0: continue
            case 4: textures.append((key, states))
            case 15: states.removeAll(keepingCapacity: true) // 0x586488 → backend command 13.
            case 16:
                // 0x55b8cb allocates 64 entries including the base state.
                // The overflow behavior is outside the preview profile.
                guard states.count < 63 else { return nil }
                states.append(key)
            case 17: _ = states.popLast()
            default: return nil
            }
        }
        return textures
    }

    public func composedRasterModes(texture: MotionKey, states: [MotionKey]) -> (blend: Int32, sampling: UInt8)? {
        guard let rawBlend = texture.blend, let rawSampling = texture.sampling else { return nil }
        func backendBlend(_ raw: Int32) -> Int32 {
            // 0x57e299 uses a lookup table rather than a linear numbering scheme.
            let modes: [Int32] = [1, 3, 4, 5, 6, 7, 8, 9, 10, 11, 14, 12, 13, 15, 16]
            let code = Int(raw & 0x7f)
            return code < modes.count ? modes[code] : 3
        }
        func backendSampling(_ raw: UInt8) -> UInt8 { (1...4).contains(raw) ? raw : 0 }
        var blend = backendBlend(rawBlend)
        var sampling = backendSampling(rawSampling)
        for state in states {
            guard let rawBlend = state.blend, let rawSampling = state.sampling else { return nil }
            let stateBlend = backendBlend(rawBlend)
            let stateSampling = backendSampling(rawSampling)
            if stateBlend != 1 { blend = stateBlend }
            if stateSampling != 0 { sampling = stateSampling }
        }
        return (blend, sampling)
    }

    public func composedOpacity(texture: MotionKey, states: [MotionKey]) -> UInt8? {
        guard let alpha = texture.sampledOpacity else { return nil }
        var parent = 255
        for state in states {
            guard let opacity = state.sampledOpacity else { return nil }
            parent = parent * Int(opacity) / 255
        }
        return UInt8(Int(alpha) * parent / 255)
    }

    /// Axis-aligned state only. Keep references and nonzero angles outside this profile.
    public func axisAlignedState(_ states: [MotionKey]) -> (x: Double, y: Double, scaleX: Double, scaleY: Double)? {
        var result = (x: 0.0, y: 0.0, scaleX: 1.0, scaleY: 1.0)
        for state in states {
            guard !state.translationUnsupported, let fields = state.transform_fields,
                  fields["0x8c"] == 0, fields["0x98"] == 100,
                  fields["0x9c"] == 0, fields["0xa0"] == 0,
                  fields["0xa4"] == 0, let order = fields["0xa8"],
                  // Type 4 submits this field with the host depth at 0x58573d–0x585749.
                  (order == 0 || state.type == 4),
                  let x = fields["0x84"], let y = fields["0x88"],
                  let scaleX = fields["0x90"], let scaleY = fields["0x94"],
                  [x, y, scaleX, scaleY].allSatisfy({ (-32768...32767).contains($0) }) else { return nil }
            result.x += state.sampledTranslation?.x ?? Double(x)
            result.y += state.sampledTranslation?.y ?? Double(y)
            result.scaleX *= Double(scaleX) / 100
            result.scaleY *= Double(scaleY) / 100
        }
        return result.scaleX.isFinite && result.scaleY.isFinite ? result : nil
    }

    /// Apply the backend's axis-aligned stack after the caller computes the host-space rectangle.
    public func applyingAxisAlignedState(_ states: [MotionKey], to rect: CGRect, target: CGSize) -> CGRect? {
        guard let state = axisAlignedState(states) else { return nil }
        let centerX = target.width / 2
        let centerY = target.height / 2
        let transform = CGAffineTransform(a: state.scaleX, b: 0, c: 0, d: state.scaleY,
            tx: centerX + (state.x - centerX) * state.scaleX,
            ty: centerY + (state.y - centerY) * state.scaleY)
        let result = rect.applying(transform)
        guard [result.minX, result.minY, result.width, result.height].allSatisfy(\.isFinite) else { return nil }
        return result
    }

    /// Geometry candidate for a literal, full-raster key with no additional texture offset.
    /// The caller supplies the host transform. Interpolated local geometry is separate.
    public func fullTextureRectangle(_ key: MotionKey, size: CGSize, host: CGAffineTransform) -> CGRect? {
        fullTextureRectangle(key, size: size, host: host, anchorOverride: nil)
    }

    private func fullTextureRectangle(_ key: MotionKey, size: CGSize, host: CGAffineTransform,
                                      anchorOverride: SIMD2<Double>?) -> CGRect? {
        guard key.type == 4, key.source_areas?.first == [0, 0, 0, 0],
              let anchor = key.literalAnchorRatio, let local = axisAlignedState([key]),
              local.scaleX > 0, local.scaleY > 0 else { return nil }
        // 0x584b75–0x584bc5 applies anchor translation, scale, then position.
        let width = size.width * local.scaleX
        let height = size.height * local.scaleY
        return CGRect(x: local.x - (anchorOverride?.x ?? anchor.x) * width,
                      y: local.y - (anchorOverride?.y ?? anchor.y) * height,
                      width: width, height: height).applying(host)
    }

    /// Geometry for an unscaled, unrotated type-11 key with two full textures.
    /// The caller supplies the sizes of the resolved images and the target origin.
    package func fullTwoTextureGeometry(_ key: MotionKey, first: CGSize, second: CGSize,
                                        origin: CGPoint) -> (target: CGRect, scanSelector: Int)? {
        guard key.type == 11, key.source_areas == [[0, 0, 0, 0], [0, 0, 0, 0]],
              let anchor = key.literalAnchorRatio, anchor.x == 0, anchor.y == 0,
              let local = axisAlignedState([key]), local.x == 0, local.y == 0,
              local.scaleX == 1, local.scaleY == 1,
              [first.width, first.height, second.width, second.height].allSatisfy({ (1...8192).contains($0) }),
              origin.x.isFinite, origin.y.isFinite else { return nil }
        // 0x584164 expands each zero rectangle using its own image handle.
        // 0x585ea9 uses the first rectangle's dimensions for the target.
        func quad(_ rect: CGRect) -> TwoTextureScanQuad {
            TwoTextureScanQuad(x: SIMD4(Float(rect.minX), Float(rect.maxX), Float(rect.maxX), Float(rect.minX)),
                               y: SIMD4(Float(rect.minY), Float(rect.minY), Float(rect.maxY), Float(rect.maxY)))
        }
        let target = CGRect(origin: origin, size: first)
        let selector = TwoTextureScanQuad.selector(target: quad(target),
            first: quad(CGRect(origin: .zero, size: first)), second: quad(CGRect(origin: .zero, size: second)))
        return (target, selector)
    }

    /// Default-blend preview for a literal, untranslated-in-Z type-4 raster key.
    /// Returns whether a nontransparent sample reached the canvas.
    /// Actual scanner selection and color preparation remain unverified.
    @discardableResult
    package func drawScopedTexturePreview(_ entries: [(texture: MotionKey, states: [MotionKey])],
                                          container: Data, boundSlotZero: Data?, origin: SIMD2<Int>,
                                          hostScale: SIMD2<Double>, anchorOverride: SIMD2<Double>?,
                                          layerOpacity: UInt8, canvas: inout [[SIMD4<UInt8>]]) throws -> Bool {
        guard (1...64).contains(entries.count) else {
            throw ResourceError.rejected("texture_preview_draw_limit")
        }
        // Unscoped textures share a host depth. For scoped commands the
        // ordering of state changes must be resolved together with draw order.
        let ordered = entries.allSatisfy { $0.states.isEmpty }
            ? entries.enumerated().sorted {
                ($0.element.texture.transform_fields?["0xa8"] ?? 0, $0.offset) <
                    ($1.element.texture.transform_fields?["0xa8"] ?? 0, $1.offset)
            }.map(\.element)
            : entries
        var staged = canvas
        var covered = false
        for entry in ordered {
            let drew = try drawFullTexturePreview(entry.texture, container: container,
                boundSlotZero: boundSlotZero, origin: origin, hostScale: hostScale,
                anchorOverride: anchorOverride, layerOpacity: layerOpacity, states: entry.states, canvas: &staged)
            covered = covered || drew
        }
        if covered { canvas = staged }
        return covered
    }

    package func drawFullTexturePreview(_ key: MotionKey, container data: Data,
                                        boundSlotZero: Data? = nil,
                                        origin: SIMD2<Int>, hostScale: SIMD2<Double> = SIMD2(1, 1),
                                        anchorOverride: SIMD2<Double>? = nil,
                                        layerOpacity: UInt8 = 255,
                                        states: [MotionKey] = [],
                                        canvas: inout [[SIMD4<UInt8>]]) throws -> Bool {
        guard key.type == 4 else { throw ResourceError.rejected("unsupported_texture_preview_key") }
        guard key.blend != nil, key.sampling != nil,
              states.allSatisfy({ $0.blend != nil && $0.sampling != nil }) else {
            throw ResourceError.rejected("texture_preview_recipe_missing_raster_modes")
        }
        guard let modes = composedRasterModes(texture: key, states: states),
              modes.blend == 1, modes.sampling == 0 else {
            throw ResourceError.rejected("unsupported_texture_preview_raster_modes")
        }
        guard let keyOpacity = composedOpacity(texture: key, states: states) else {
            throw ResourceError.rejected("unsupported_texture_preview_opacity")
        }
        let payload: Data
        var decodedRaster: ResourceImage?
        if let boundSlotZero, key.texture_numbers?.first == 0 {
            payload = boundSlotZero
            decodedRaster = try ResourceImage.decode(payload)
        } else {
            guard let slot = key.texture_numbers?.first,
                  let member = texturesByContainer[ImageMemberRecipe.digest(data)]?[Int(slot)],
                  member.image_anchor_words == [0, 0, 0] else {
                throw ResourceError.rejected("unsupported_texture_preview_member_or_anchor")
            }
            payload = try member.payload(data)
            // Keep the existing straight-PNG and opaque-JPEG sampling paths.
            let signature = InventoryScanner.signature(payload)
            decodedRaster = ["DPNG", "BMP", "ARGB"].contains(signature)
                ? try ResourceImage.decode(payload) : nil
        }
        guard
              let width = canvas.first?.count, canvas.allSatisfy({ $0.count == width }),
              (-32768...32767).contains(origin.x), (-32768...32767).contains(origin.y) else {
            throw ResourceError.rejected("unsupported_texture_preview_key")
        }
        let pixels: [[SIMD4<UInt8>]]
        let size: CGSize
        if let decodedRaster {
            pixels = []
            size = CGSize(width: decodedRaster.image.width, height: decodedRaster.image.height)
        } else if InventoryScanner.signature(payload) == "JPEG" {
            pixels = try ResourceImage.decode(payload).opaqueCanvas(over: CGColor(gray: 0, alpha: 1))
            size = CGSize(width: pixels[0].count, height: pixels.count)
        } else {
            do {
                let straight = try ResourceImage.straightPNGPixels(payload)
                pixels = straight
                size = CGSize(width: straight[0].count, height: straight.count)
            } catch ResourceError.rejected("unsupported_straight_texture_layout") {
                // RGB and grayscale PNGs can decode successfully without exposing
                // the RGBA byte layout required by the straight-pixel scanner.
                let raster = try ResourceImage.decode(payload)
                decodedRaster = raster
                pixels = []
                size = CGSize(width: raster.image.width, height: raster.image.height)
            }
        }
        let host = CGAffineTransform(translationX: CGFloat(origin.x), y: CGFloat(origin.y))
            .scaledBy(x: hostScale.x, y: hostScale.y)
        guard let localRect = fullTextureRectangle(key, size: size, host: host, anchorOverride: anchorOverride),
              let rect = applyingAxisAlignedState(states, to: localRect,
                                                  target: CGSize(width: width, height: canvas.count)),
              hostScale.x != 0, hostScale.y != 0,
              let state = axisAlignedState(states), state.scaleX > 0, state.scaleY > 0,
              let left = Int(exactly: rect.minX.rounded()), let top = Int(exactly: rect.minY.rounded()),
              let rasterWidth = Int(exactly: rect.width.rounded()), (1...65536).contains(rasterWidth),
              let rasterHeight = Int(exactly: rect.height.rounded()), (1...65536).contains(rasterHeight),
              (-65536...65536).contains(left), (-65536...65536).contains(top) else {
            throw ResourceError.rejected("unsupported_texture_preview_geometry")
        }
        let xStart = max(0, -left)
        let yStart = max(0, -top)
        let xEnd = min(rasterWidth, width - left)
        let yEnd = min(rasterHeight, canvas.count - top)
        guard xStart < xEnd, yStart < yEnd else { return false }
        // Preview modulation. Original scanner color preparation is unverified.
        let opacity = (Int(keyOpacity) * Int(layerOpacity) + 127) / 255
        guard opacity > 0 else { return false }
        if let decodedRaster {
            return try decodedRaster.drawRasterPreview(origin: SIMD2(left, top), opacity: UInt8(opacity),
                size: SIMD2(rasterWidth, rasterHeight), flipX: hostScale.x < 0, flipY: hostScale.y < 0,
                canvas: &canvas)
        }
        var coveredPixels = false
        for y in yStart..<yEnd {
            let sampleY = hostScale.y < 0 ? rasterHeight - 1 - y : y
            let row = pixels[sampleY * pixels.count / rasterHeight]
            for x in xStart..<xEnd {
                let sampleX = hostScale.x < 0 ? rasterWidth - 1 - x : x
                let source = row[sampleX * row.count / rasterWidth]
                let alpha = (Int(source.w) * opacity + 127) / 255
                guard alpha != 0 else { continue }
                coveredPixels = true
                canvas[top + y][left + x] = TwoTexturePixel.blendOntoTarget(
                    source: SIMD4(Int16(source.x), Int16(source.y), Int16(source.z), Int16(alpha)),
                    target: canvas[top + y][left + x])
            }
        }
        return coveredPixels
    }

    /// Draw a full type-11 PNG pair over the existing pixels of a clipped canvas.
    @discardableResult
    package func drawFullTwoTextureKey(_ key: MotionKey, container data: Data,
                                      boundFirst: (data: Data, location: ScriptLocation)? = nil,
                                      origin: SIMD2<Int>,
                                      canvas: inout [[SIMD4<UInt8>]]) throws -> Bool {
        guard let canvasWidth = canvas.first?.count, (1...8192).contains(canvasWidth),
              (1...8192).contains(canvas.count), canvas.count <= 16_777_216 / canvasWidth,
              canvas.allSatisfy({ $0.count == canvasWidth }),
              (-32768...32767).contains(origin.x), (-32768...32767).contains(origin.y) else {
            throw ResourceError.rejected("unsupported_two_texture_canvas")
        }
        guard key.type == 11, key.sampling == 0, key.blend == 0,
              key.opacity_mode_input == 0, let multiplierAlpha = key.sampledOpacity,
              let inputs = key.type11_color_inputs, inputs.count == 3,
              (0...0xffffff).contains(inputs[0]), (0...0xffffff).contains(inputs[1]),
              let rawWeight = UInt8(exactly: inputs[2]),
              let slots = key.texture_numbers, slots.count == 2,
              let textures = texturesByContainer[ImageMemberRecipe.digest(data)],
              let firstMember = textures[Int(slots[0])], let secondMember = textures[Int(slots[1])],
              firstMember.image_anchor_words == [0, 0, 0],
              secondMember.image_anchor_words == [0, 0, 0] else {
            throw ResourceError.rejected("unsupported_two_texture_key")
        }
        let firstPayload: Data
        if let boundFirst {
            guard slots[0] == 0,
                  boundFirst.data.count <= 16 * 1024 * 1024,
                  boundFirst.data.count == boundFirst.location.byteLength,
                  ImageMemberRecipe.digest(boundFirst.data) == boundFirst.location.rangeSHA256 else {
                throw ResourceError.rejected("two_texture_bound_member_identity")
            }
            firstPayload = boundFirst.data
        } else {
            firstPayload = try firstMember.payload(data)
        }
        let first: [[SIMD4<UInt8>]]
        if boundFirst?.location.sourceFile.hasPrefix("save-slot/") == true,
           InventoryScanner.signature(firstPayload) == "JPEG" {
            first = try ResourceImage.decode(firstPayload).opaqueCanvas(over: CGColor(gray: 0, alpha: 1))
        } else {
            first = try ResourceImage.straightPNGPixels(firstPayload)
        }
        let second = try ResourceImage.straightPNGPixels(secondMember.payload(data))
        let colors = TwoTexturePixel.scannerColors(additiveRGB: UInt32(inputs[0]),
            multiplierRGB: UInt32(inputs[1]), multiplierAlpha: multiplierAlpha)
        guard let firstRow = first.first, let secondRow = second.first,
              let geometry = fullTwoTextureGeometry(key,
                  first: CGSize(width: firstRow.count, height: first.count),
                  second: CGSize(width: secondRow.count, height: second.count), origin: .zero),
              geometry.scanSelector == 1 else {
            throw ResourceError.rejected("unsupported_two_texture_geometry")
        }
        let size = SIMD2(Int(geometry.target.width), Int(geometry.target.height))
        let left = max(0, origin.x), top = max(0, origin.y)
        let right = min(canvasWidth, origin.x + size.x), bottom = min(canvas.count, origin.y + size.y)
        guard left < right, top < bottom else { return false }
        let columns = left..<right
        let rows = top..<bottom
        var target = rows.map { Array(canvas[$0][columns]) }
        guard TwoTexturePixel.drawFullTextures(first: first, second: second, fullSize: size,
                  clippedOrigin: SIMD2(left - origin.x, top - origin.y),
                  packedWeights: TwoTexturePixel.command4Weights(UInt32(rawWeight)),
                  multiplier: colors.multiplier, additive: colors.additive, target: &target) else {
            throw ResourceError.rejected("unsupported_two_texture_geometry")
        }
        for (index, row) in rows.enumerated() {
            canvas[row].replaceSubrange(columns, with: target[index])
        }
        return true
    }

    /// Candidate for the audited untextured white flash at its default dimension inputs.
    package func whiteFlashPreviewSize(_ key: MotionKey, container: ScriptLocation) -> SIMD2<Int>? {
        guard container.rangeSHA256 == "dea47b18a5dac17a733523ca0a8c00167bf24217b168bf5330e8f11097f0d354",
              container.byteOffset == 0, container.sourceSHA256 == container.rangeSHA256,
              key.type == 1, key.offset == 5649, key.blend == 1, key.sampling == 0,
              key.opacity_mode_input == 0, key.sampledOpacity == 255,
              key.type1_color_inputs == [0xffffff, 0xffffff],
              key.transform_fields?["0x90"] == 0x10000107,
              key.transform_fields?["0x94"] == 0x10000108,
              let size = entriesByContainer[container.sourceSHA256]?.compactMap(\.motion_canvas_inputs).first,
              size.width == 1280, size.height == 720 else { return nil }
        return SIMD2(size.width, size.height)
    }

    public func isNonDrawingMotion(_ container: ScriptLocation, selectedMember: Int32?) -> Bool {
        guard let selectedMember, selectedMember >= 0, container.byteOffset == 0,
              container.sourceSHA256 == container.rangeSHA256 else { return false }
        if let tracks = validTimelines[container.sourceSHA256]?[Int(selectedMember)] {
            // A temporary type-0 interval does not disable the whole action.
            return tracks.allSatisfy { $0.allSatisfy { $0.type == 0 } }
        }
        if let indices = entriesByContainer[container.sourceSHA256]?.first(where: {
            $0.non_drawing_motion_indices != nil
        })?.non_drawing_motion_indices {
            return indices.contains(selectedMember)
        }
        // Compatibility with older recipes. Both reviewed def actions have one
        // layer with four type-0 keys, skipped by the draw loop at 0x587a32.
        return selectedMember == 0 && [
            "1e24b54a80240c3a8727c9ea7185fb0ceb6f04fd1ef38aab8c9b0788d59a8c86",
            "bc57a36db245b73d43dd71bbb7ee41ca3fa79c2f68eefd70b121f51cd3399cdf"
        ].contains(container.sourceSHA256)
    }

    public func staticRasterPayload(_ data: Data, sourceFile: String, selectedMember: Int32?) throws -> Data {
        guard data.starts(with: Data("abmp12".utf8)) else { return data }
        let digest = ImageMemberRecipe.digest(data)
        let members = entriesByContainer[digest] ?? []
        // The audited text effect's def action holds one full-size opaque
        // raster at the host origin until its type-0 keys at tick 1000.
        if digest == "cd20f60e0984abd828a5f8c8567335a385339372dd99c2731def35ac4b4e972b",
           selectedMember == 0, let member = texturesByContainer[digest]?[0],
           member.motion_timelines?[0]?.map({ $0.first?.type }) == [16, 4, 17],
           member.format == "JPEG" {
            return try member.payload(data)
        }
        // The title host can display audited static members while animated
        // composition and cursor state transitions remain unavailable.
        let staticMember: String?
        switch sourceFile.lowercased().split(separator: "/").suffix(3).joined(separator: "/") {
        case "script/title/back01.b": staticMember = "bg01.jpg"
        case "script/title/back02.b": staticMember = "bg.png"
        case "script/title/cursor.b": staticMember = "cursor01.png"
        case "script/saveload/button_l.b": staticMember = "戻る_off.png"
        case "script/saveload/button_data.b": staticMember = "セーブファイル_off.png"
        default: staticMember = nil
        }
        if let staticMember {
            let bases = members.filter { $0.name == staticMember && ($0.format == "PNG" || $0.format == "JPEG") }
            if bases.count == 1, let base = bases.first { return try base.payload(data) }
        }
        // The game's Click motion uses a single audited raster payload,
        // duplicated across the container's two PNG entries.
        if sourceFile.lowercased().hasSuffix("/avg/window/click.b"),
           let selectedMember, selectedMember >= 0,
           let names = members.first(where: { $0.motion_name_candidates != nil })?.motion_name_candidates,
           Int(selectedMember) < names.count, names[Int(selectedMember)] == "Click",
           let first = members.first, first.format == "PNG",
           members.allSatisfy({ $0.format == "PNG" && $0.sha256 == first.sha256 }) {
            return try first.payload(data)
        }
        guard !members.isEmpty else {
            throw ResourceError.rejected("abmp_raster_recipe_missing")
        }
        guard !members.contains(where: { $0.motion_name_candidates != nil }) else {
            throw ResourceError.rejected("abmp_raster_requires_motion")
        }
        guard members.count == 1, let member = members.first else {
            throw ResourceError.rejected("abmp_raster_requires_composition")
        }
        guard ["PNG", "JPEG", "BMP", "DPNG", "ARGB"].contains(member.format ?? "") else {
            throw ResourceError.rejected("abmp_raster_member_format_unsupported")
        }
        return try member.payload(data)
    }

    public func choiceButtonPayload(_ data: Data, hovered: Bool) throws -> Data {
        let members = entriesByContainer[ImageMemberRecipe.digest(data)] ?? []
        let name = hovered ? "選択肢_on.png" : "選択肢_off.png"
        let matches = members.filter { $0.name == name && $0.format == "PNG" }
        guard matches.count == 1, let member = matches.first else {
            throw ResourceError.rejected("choice_button_raster_recipe_missing")
        }
        return try member.payload(data)
    }

    /// Displays an audited background bitmap while the ABMP composition is unresolved.
    public func interfaceBackgroundPreview(_ data: Data, sourceFile: String) throws -> Data? {
        let path = sourceFile.lowercased().split(separator: "/").suffix(3).joined(separator: "/")
        let backgroundName: String
        switch path {
        case "avg/window/windowframe_window.b", "avg/window/windowframe_window02.b":
            backgroundName = "*MesAlpha.png"
        case "avg/window/volumedisp.b":
            backgroundName = "VolumeBack.png"
        case "script/dialog/message.b":
            backgroundName = "確認_フレーム.png"
        default:
            return nil
        }
        guard data.starts(with: Data("abmp12".utf8)) else { return nil }
        let digest = ImageMemberRecipe.digest(data)
        let members = entriesByContainer[digest] ?? []
        guard members.count == 2, members.allSatisfy({ $0.format == "PNG" }),
              let background = members.first(where: { $0.name == backgroundName }),
              let surface = members.first(where: { $0.name == "*MesSurface.png" }) else { return nil }
        if backgroundName == "*MesAlpha.png", members.contains(where: { $0.image_slot != nil }) {
            guard let slotZero = texturesByContainer[digest]?[0], slotZero.name == background.name,
                  texturesByContainer[digest]?[1]?.name == surface.name else {
                throw ResourceError.rejected("abmp_interface_texture_slot_mismatch")
            }
            return try slotZero.payload(data)
        }
        return try background.payload(data)
    }

    public func dimensions(_ data: Data) throws -> (Int, Int, Int) {
        if data.starts(with: Data("abmp12".utf8)) {
            let digest = ImageMemberRecipe.digest(data)
            let members = entriesByContainer[digest] ?? []
            guard (1...128).contains(members.count) else {
                throw ResourceError.rejected("abmp_image_recipe_required")
            }
            if members.count == 1, let member = members.first, member.format == "MotionOnly" {
                let payload = try member.payload(data)
                guard payload.starts(with: Data([0x31, 0x50, 0x43, 0xff])),
                      let names = member.motion_name_candidates, !names.isEmpty else {
                    throw ResourceError.rejected("abmp_motion_recipe_required")
                }
                return (0,0,0)
            }
            var width = 0, height = 0, pixels = 0
            for member in members {
                let payload = try member.payload(data)
                let dimensions: (Int, Int)
                if member.format == "Ogg" {
                    dimensions = try ScriptMovieHeader.theoraDimensions(payload)
                } else if member.format == "IMOAVI" {
                    guard payload.starts(with: Data("IMOAVI".utf8)),
                          let width = member.width, let height = member.height,
                          (1...8192).contains(width), (1...8192).contains(height) else {
                        throw ResourceError.rejected("imoavi_image_recipe_required")
                    }
                    dimensions = (width, height)
                } else {
                    let decoded = try ResourceImage.decode(payload)
                    dimensions = (decoded.image.width, decoded.image.height)
                }
                width = max(width, dimensions.0)
                height = max(height, dimensions.1)
                pixels += dimensions.0 * dimensions.1
                guard pixels <= 64*1024*1024 else { throw ResourceError.rejected("abmp_image_pixel_budget") }
            }
            return (width,height,members.count)
        }
        if data.starts(with: Data("OggS".utf8)) {
            let (width, height) = try ScriptMovieHeader.theoraDimensions(data)
            guard (1...8192).contains(width), (1...8192).contains(height) else {
                throw ResourceError.rejected("theora_image_dimensions")
            }
            return (width, height, 1)
        }
        let decoded = try ResourceImage.decode(data)
        return (decoded.image.width, decoded.image.height, 1)
    }

    public func member(_ container: ScriptLocation, _ name: String) throws -> (offset: Int, length: Int, sha256: String)? {
        let matches = entriesByContainer[container.sourceSHA256]?.filter { $0.name == name } ?? []
        guard !matches.isEmpty else { return nil }
        guard matches.count == 1, let member = matches.first,
              member.offset >= 0, member.length > 0,
              member.offset <= container.byteLength,
              member.length <= container.byteLength - member.offset else {
            throw ResourceError.rejected("ambiguous_or_invalid_image_member")
        }
        return (member.offset, member.length, member.sha256)
    }

    public func extendedValues(_ container: ScriptLocation) -> [Int: Int32]? {
        entriesByContainer[container.sourceSHA256]?.first { $0.extended_scalar_values != nil }?.extended_scalar_values
    }

    public func motionNames(_ container: ScriptLocation) -> [String]? {
        entriesByContainer[container.sourceSHA256]?.first { $0.motion_name_candidates != nil }?.motion_name_candidates
    }
}

private struct ImageMemberRecipe: Decodable, Sendable {
    struct MotionCanvasInputs: Decodable, Sendable {
        let width: Int
        let height: Int
    }
    let motion_canvas_inputs: MotionCanvasInputs?
    let name: String?
    let format: String?
    let width: Int?
    let height: Int?
    let motion_name_candidates: [String]?
    let non_drawing_motion_indices: [Int32]?
    let motion_key_types: [Int: [Int32]]?
    let image_slot: Int?
    let image_anchor_words: [UInt32]?
    let motion_timelines: [Int: [[ScriptImageRecipe.MotionKey]]]?
    let extended_scalar_values: [Int: Int32]?
    let container_sha256: String
    let offset: Int
    let length: Int
    let sha256: String

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func payload(_ data: Data) throws -> Data {
        guard Self.digest(data) == container_sha256, offset >= 0, length > 0,
              offset <= data.count, length <= data.count-offset else {
            throw ResourceError.rejected("abmp_image_member_range")
        }
        let member = data.subdata(in: offset..<offset+length)
        guard Self.digest(member) == sha256 else { throw ResourceError.rejected("abmp_image_member_identity") }
        return member
    }
}
