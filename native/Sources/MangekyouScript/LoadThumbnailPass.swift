import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import MangekyouCore
import MangekyouMedia

struct LoadThumbnailPass: Encodable {
    struct OmittedLayer: Encodable {
        struct SampledKey: Encodable {
            let type: Int32
            let byteOffset: Int
        }

        let id: UInt64
        let resource: ScriptLocation
        let priority: Int32
        let reason: String
        let selectedMember: Int32?
        let motionElapsedTicks: Int32?
        let sampledKeys: [SampledKey]?
        let status: EvidenceStatus = .unsupported
    }

    let status: EvidenceStatus = .inferred
    let borderBlend = "default_fixed_point_preview"
    let layerCount: Int
    struct CompositedMotionLayer: Encodable {
        let id: UInt64
        let resource: ScriptLocation
        let selectedMember: Int32
        let motionElapsedTicks: Int32
        let drawKeyOffsets: [Int]
        let boundSlotZero: ScriptLocation?
    }

    let staticRasterCount: Int
    let compositedMotionLayers: [CompositedMotionLayer]
    let interfaceBackgroundPreviewCount: Int
    let textPreviewCount: Int
    let textPreviewWithoutCoverageCount: Int
    let textPreviewIssues: [UInt64: String]
    let choiceLabelPreviewCount: Int
    let hoveredChoicePreview: Int32?
    let uncoveredMotions: [ScriptMachine.SavedDisplayDraw.UncoveredMotion]
    let clippedRasters: [ScriptMachine.SavedDisplayDraw.ClippedRaster]
    let nonDrawingReasons: [String: Int]
    let nonDrawingLayerCount: Int
    let captureDrawChangedPixels: Int?
    let omittedLayers: [OmittedLayer]
    var isIncomplete: Bool {
        !omittedLayers.isEmpty || !textPreviewIssues.isEmpty || interfaceBackgroundPreviewCount > 0
    }
    let changedPixels: Int
    let canvasSHA256: String
    let transitionMidpointSHA256: String?
    let originalRendererEquivalence: EvidenceStatus = .notTested

    init(task: ScriptMachine, assets: SafeDirectory, recipe: ScriptImageRecipe, backgroundPath: String,
         suppliedCapture: Data?, saveDirectory: SafeDirectory?, choicePointer: CGPoint? = nil,
         atDrawRequest: Bool = false, capturePriority: Int32? = nil, overlapProgress: (elapsed: UInt32, duration: UInt32)? = nil,
         exportPNG: ((Data) -> Void)? = nil) throws {
        let sceneLayers = task.staticImageLayers.filter { layer in
            overlapProgress != nil || (capturePriority.map { layer.priority <= $0 } ?? true)
        }
        let messages = task.messageTextLayers.filter { message in
            message.isVisible && (overlapProgress != nil || (capturePriority.map { (message.priority ?? .max) <= $0 } ?? true))
        }.sorted {
            ($0.priority ?? .max, $0.id) < ($1.priority ?? .max, $1.id)
        }
        func isThumbnail(_ layer: ScriptMachine.StaticImageLayer) -> Bool {
            layer.resource.sourceFile.lowercased().hasSuffix("/saveload/thumimage.b")
        }
        let thumbnails = sceneLayers.count(where: isThumbnail)
        guard (task.phase == .waiting || task.phase == .waitingForEvent || (atDrawRequest && task.phase == .ready)),
              !sceneLayers.isEmpty || !messages.isEmpty,
              thumbnails <= 32, sceneLayers.count <= 128 else {
            throw ResourceError.rejected("load_thumbnail_layers_unavailable")
        }
        var verifiedPayloads: [ScriptLocation: Data] = [:]
        func read(_ source: ScriptLocation) throws -> Data {
            if let payload = verifiedPayloads[source] { return payload }
            let data: Data
            if source.sourceFile == "system-capture.png", let suppliedCapture {
                data = suppliedCapture
            } else if source.sourceFile.hasPrefix("save-slot/") {
                guard let saveDirectory else { throw ResourceError.rejected("save_thumbnail_directory_unavailable") }
                data = try saveDirectory.read(String(source.sourceFile.dropFirst("save-slot/".count)),
                                              limit: SaveEnvelope.maxFileBytes)
            } else {
                data = try assets.read(source.sourceFile)
            }
            guard data.sha256Hex == source.sourceSHA256, source.byteOffset >= 0,
                  source.byteOffset <= data.count, source.byteLength > 0,
                  source.byteLength <= data.count - source.byteOffset else {
                throw ResourceError.rejected("load_thumbnail_resource_identity")
            }
            let payload = data.subdata(in: source.byteOffset..<(source.byteOffset + source.byteLength))
            guard payload.sha256Hex == source.rangeSHA256 else {
                throw ResourceError.rejected("load_thumbnail_range_identity")
            }
            verifiedPayloads[source] = payload
            return payload
        }
        let background = try ResourceImage.decode(assets.read(backgroundPath)).opaqueCanvas(over: CGColor(gray: 0, alpha: 1))
        // The menu background is a script layer. The explicit image above
        // supplies canvas dimensions and the report's comparison baseline.
        let blankRow = Array(repeating: SIMD4<UInt8>(0, 0, 0, 255), count: background.first?.count ?? 0)
        var canvas = Array(repeating: blankRow, count: background.count)
        var omitted: [OmittedLayer] = []
        var rasters = 0
        var compositedMotions: [CompositedMotionLayer] = []
        var interfacePreviews = 0
        var uncovered: [ScriptMachine.SavedDisplayDraw.UncoveredMotion] = []
        var clipped: [ScriptMachine.SavedDisplayDraw.ClippedRaster] = []
        var nonDrawing: [String: Int] = [:]
        var captureChanges: Int?
        var textCount = 0
        var uncoveredTextCount = 0
        var textIssues: [UInt64: String] = [:]
        var drawnChoiceLabels: Set<UInt64> = []
        let visibleChoices = task.visibleStoryChoiceButtons
        let interactiveChoices = task.storyChoiceButtons
        let hoveredButton = choicePointer.flatMap { point in
            sceneLayers.last { layer in
                guard interactiveChoices[layer.id] != nil, layer.opacity > 0, !layer.unappliedTransform,
                      layer.scaleXPercent != 0, layer.scaleYPercent != 0,
                      let source = try? read(layer.resource),
                      let payload = try? recipe.choiceButtonPayload(source, hovered: false),
                      let raster = try? ResourceImage.decode(payload) else { return false }
                let width = Int64(raster.image.width) * abs(Int64(layer.scaleXPercent)) / 100
                let height = Int64(raster.image.height) * abs(Int64(layer.scaleYPercent)) / 100
                guard (1...65_536).contains(width), (1...65_536).contains(height) else { return false }
                let x = Int64(layer.x) - width * Int64(layer.alignmentXPercent) / 100
                let y = Int64(layer.y) - height * Int64(layer.alignmentYPercent) / 100
                return CGRect(x: Int(x), y: Int(y), width: Int(width), height: Int(height)).contains(point)
            }?.id
        }
        var hoveredChoice: Int32?
        var textBackgrounds: [UInt64: CGRect] = [:]
        var messageIndex = 0
        func drawMessages(before priority: Int32, id: UInt64) {
            while messageIndex < messages.count {
                let message = messages[messageIndex]
                guard (message.priority ?? .max, message.id) < (priority, id) else { break }
                messageIndex += 1
                do {
                    guard let bounds = message.canvasBounds else {
                        throw ResourceError.rejected("missing_text_preview_bounds")
                    }
                    let background = textBackgrounds[message.id] ??
                        CGRect(x: Int(message.x), y: Int(message.y), width: 0, height: 0)
                    func position(_ start: Int64, _ end: Int64, placement: Int32,
                                  near: CGFloat, far: CGFloat, percent: Int32) -> Int {
                        let edge = percent < 0 ? end : start
                        let anchor = percent < 0 ? far : near
                        return Int(floor(anchor + CGFloat(edge - Int64(placement)) * CGFloat(percent) / 100))
                    }
                    let raster = try ResourceImage.textPreview(message,
                        width: Int(bounds[2] - bounds[0]), height: Int(bounds[3] - bounds[1]))
                    let x = position(bounds[0], bounds[2], placement: message.x,
                                     near: background.minX, far: background.maxX, percent: message.scaleXPercent)
                    let y = position(bounds[1], bounds[3], placement: message.y,
                                     near: background.minY, far: background.maxY, percent: message.scaleYPercent)
                    let width = CGFloat(raster.image.width) * abs(CGFloat(message.scaleXPercent)) / 100
                    let height = CGFloat(raster.image.height) * abs(CGFloat(message.scaleYPercent)) / 100
                    guard width > 0, height > 0 else {
                        textCount += 1
                        uncoveredTextCount += 1
                        continue
                    }
                    let target = CGRect(x: CGFloat(x), y: CGFloat(y), width: width, height: height)
                    let covered = try raster.drawRasterPreview(bounds: target, opacity: 255,
                        flipX: message.scaleXPercent < 0, flipY: message.scaleYPercent < 0, canvas: &canvas)
                    if !covered {
                        uncoveredTextCount += 1
                        let canvasBounds = CGRect(x: 0, y: 0, width: canvas.first?.count ?? 0, height: canvas.count)
                        let fullyInside = canvasBounds.contains(target)
                        let hasVisibleText = message.runs.contains { run in
                            guard run.horizontalAdvance == nil else { return false }
                            if run.colorARGB >> 24 != 0, run.text.contains(where: { !$0.isWhitespace }) { return true }
                            guard let ruby = run.ruby, (ruby.colorARGB ?? run.colorARGB) >> 24 != 0 else { return false }
                            return ruby.text.contains { !$0.isWhitespace }
                        }
                        if fullyInside && hasVisibleText {
                            textIssues[message.id] = "text_preview_without_coverage"
                        }
                    }
                    textCount += 1
                } catch {
                    textIssues[message.id] = String(describing: error)
                }
            }
        }
        var midpointPending = overlapProgress != nil
        func applyMidpoint() throws {
            guard let progress = overlapProgress, (1...60_000).contains(progress.duration),
                  progress.elapsed <= progress.duration, let cutoff = capturePriority, let surface = task.savedOverlapPreviewSurface else {
                throw ResourceError.rejected("saved_overlap_surface_unavailable")
            }
            drawMessages(before: cutoff, id: .max)
            let previous = try ResourceImage.decode(surface).opaqueCanvas(over: CGColor(gray: 0, alpha: 1))
            guard previous.count == canvas.count, previous.first?.count == blankRow.count else {
                throw ResourceError.rejected("saved_overlap_canvas_size_mismatch")
            }
            for y in canvas.indices {
                canvas[y] = zip(previous[y], canvas[y]).map { old, new in
                    let before = SIMD4<UInt32>(truncatingIfNeeded: old) &* (progress.duration - progress.elapsed)
                    let after = SIMD4<UInt32>(truncatingIfNeeded: new) &* progress.elapsed
                    return SIMD4<UInt8>(truncatingIfNeeded: (before &+ after) / progress.duration)
                }
            }
            midpointPending = false
        }
        for layer in sceneLayers {
            if midpointPending, let cutoff = capturePriority, layer.priority > cutoff {
                try applyMidpoint()
            }
            drawMessages(before: layer.priority, id: layer.id)
            if !isThumbnail(layer) {
                let choice = visibleChoices[layer.id]
                if choice == nil, recipe.isNonDrawingMotion(layer.resource, selectedMember: layer.selectedMember) {
                    nonDrawing["motion_disabled", default: 0] += 1
                    continue
                }
                do {
                    if layer.opacity == 0 || layer.scaleXPercent == 0 || layer.scaleYPercent == 0 {
                        _ = try read(layer.resource)
                        nonDrawing["zero_opacity_or_scale", default: 0] += 1
                        continue
                    }
                    if layer.resource.sourceFile.lowercased().hasSuffix("/avg/window/click.b"),
                       let action = layer.selectedMember, let names = recipe.motionNames(layer.resource),
                       names.indices.contains(Int(action)), names[Int(action)] == "None" {
                        _ = try read(layer.resource)
                        nonDrawing["cursor_hidden", default: 0] += 1
                        continue
                    }
                    if choice == nil, layer.boundRasterPreview == nil, let member = layer.selectedMember,
                       let time = layer.motionElapsedTicks,
                       let keys = recipe.motionKeys(layer.resource, selectedMember: member, time: time),
                       keys.allSatisfy({ $0.type == 0 }) {
                        // A known timeline can also emit nothing before its first key.
                        _ = try read(layer.resource)
                        nonDrawing["no_active_draw_key", default: 0] += 1
                        continue
                    }
                    guard !layer.unappliedTransform else { throw ResourceError.rejected("unsupported_static_layer_3d_transform") }
                    // The dc field feeds the ABMP sound callback at 0x580283.
                    // It does not select a destination for this raster preview.
                    if choice == nil, let member = layer.selectedMember, let time = layer.motionElapsedTicks,
                       let keys = recipe.motionKeys(layer.resource, selectedMember: member, time: time) {
                        let draws = keys.filter { $0.type != 0 }
                        let payload = try read(layer.resource)
                        let origin = SIMD2(Int(layer.x), Int(layer.y))
                        if let scoped = recipe.scopedTextureKeys(keys), !scoped.isEmpty {
                            guard layer.boundRasterPreview != nil || !layer.hasExplicitAlignment ||
                                  (layer.alignmentXPercent == 0 && layer.alignmentYPercent == 0) else {
                                throw ResourceError.rejected("unsupported_static_layer_motion_keys")
                            }
                            let anchor = layer.hasExplicitAlignment && layer.boundRasterPreview != nil
                                ? SIMD2(Double(layer.alignmentXPercent) / 100, Double(layer.alignmentYPercent) / 100)
                                : nil
                            let scale = SIMD2(Double(layer.scaleXPercent) / 100, Double(layer.scaleYPercent) / 100)
                            let covered = try recipe.drawScopedTexturePreview(scoped, container: payload,
                                boundSlotZero: try layer.boundRasterPreview.map(read), origin: origin,
                                hostScale: scale, anchorOverride: anchor, layerOpacity: layer.opacity, canvas: &canvas)
                            if !covered {
                                nonDrawing["texture_no_coverage", default: 0] += 1
                                uncovered.append(.init(resource: layer.resource, member: member,
                                                       ticks: time, drawOffsets: draws.map(\.offset)))
                                continue
                            }
                            if messages.contains(where: { $0.id == layer.id }),
                               layer.boundRasterPreview == nil, anchor == nil,
                               let background = scoped.first(where: { $0.texture.texture_numbers?.first == 0 }),
                               let texture = recipe.embeddedTexture(layer.resource, slot: 0),
                               let size = texture.size {
                                let host = CGAffineTransform(translationX: CGFloat(layer.x), y: CGFloat(layer.y))
                                    .scaledBy(x: scale.x, y: scale.y)
                                if let bounds = recipe.fullTextureRectangle(background.texture, size: size, host: host) {
                                    textBackgrounds[layer.id] = recipe.applyingAxisAlignedState(background.states,
                                        to: bounds, target: CGSize(width: canvas.first?.count ?? 0, height: canvas.count))
                                }
                            }
                        } else if draws.count == 1, let key = draws.first, key.type == 11,
                                  layer.opacity == 255, layer.scaleXPercent == 100, layer.scaleYPercent == 100,
                                  layer.alignmentXPercent == 0, layer.alignmentYPercent == 0 {
                            // Reuse the bounded type-11 scanner profile from the thumbnail pass.
                            let bound = try layer.boundRasterPreview.map { (try read($0), $0) }
                            guard try recipe.drawFullTwoTextureKey(key, container: payload,
                                boundFirst: bound, origin: origin, canvas: &canvas) else {
                                nonDrawing["two_texture_no_coverage", default: 0] += 1
                                uncovered.append(.init(resource: layer.resource, member: member,
                                                       ticks: time, drawOffsets: draws.map(\.offset)))
                                continue
                            }
                        } else if draws.count == 1, let key = draws.first, member == 0,
                                  let size = recipe.whiteFlashPreviewSize(key, container: layer.resource) {
                            guard layer.opacity == 255, layer.scaleXPercent == 100, layer.scaleYPercent == 100,
                                  layer.boundRasterPreview == nil,
                                  layer.alignmentXPercent == 50, layer.alignmentYPercent == 50 else {
                                throw ResourceError.rejected("white_flash_host_state_outside_profile")
                            }
                            let x = origin.x - size.x / 2
                            let y = origin.y - size.y / 2
                            let left = max(0, x)
                            let top = max(0, y)
                            let right = min(canvas.first?.count ?? 0, x + size.x)
                            let bottom = min(canvas.count, y + size.y)
                            guard left < right, top < bottom else {
                                nonDrawing["outside_canvas", default: 0] += 1
                                continue
                            }
                            let white = SIMD4<UInt8>(255, 255, 255, 255)
                            for y in top..<bottom {
                                for x in left..<right { canvas[y][x] = white }
                            }
                        } else if draws.count == 1, let key = draws.first, key.type == 1,
                                  layer.scaleXPercent == 100, layer.scaleYPercent == 100,
                                  layer.resource.rangeSHA256 == "19e2101c218c9be4f0b459d8b58ff5acb38a0151a66c2bced8de3304bdc6f6f6",
                                  let keyOpacity = recipe.composedOpacity(texture: key, states: []) {
                            // Use the same host-opacity modulation as the scoped texture preview.
                            let alpha = (Int(keyOpacity) * Int(layer.opacity) + 127) / 255
                            let remaining = 255 - alpha
                            let left = max(0, origin.x)
                            let top = max(0, origin.y)
                            let right = min(canvas.first?.count ?? 0, origin.x + 1280)
                            let bottom = min(canvas.count, origin.y + 720)
                            guard alpha > 0, left < right, top < bottom else {
                                nonDrawing["transparent_or_outside_canvas", default: 0] += 1
                                continue
                            }
                            for y in top..<bottom {
                                for x in left..<right {
                                    let pixel = canvas[y][x]
                                    canvas[y][x] = SIMD4(
                                        UInt8((Int(pixel.x) * remaining + 127) / 255),
                                        UInt8((Int(pixel.y) * remaining + 127) / 255),
                                        UInt8((Int(pixel.z) * remaining + 127) / 255), 255)
                                }
                            }
                        } else {
                            throw ResourceError.rejected("unsupported_static_layer_motion_keys")
                        }
                        compositedMotions.append(.init(id: layer.id, resource: layer.resource,
                            selectedMember: member, motionElapsedTicks: time, drawKeyOffsets: draws.map(\.offset),
                            boundSlotZero: draws.contains { ($0.type == 4 || $0.type == 11) && $0.texture_numbers?.first == 0 }
                                ? layer.boundRasterPreview : nil))
                        rasters += 1
                        continue
                    }
                    let source = try read(layer.resource)
                    let plainRaster = ["PNG", "JPEG", "BMP", "DPNG", "ARGB"].contains(InventoryScanner.signature(source))
                    let path = layer.resource.sourceFile.lowercased()
                    let dialog = path.hasSuffix("/script/dialog/message.b")
                    let auditedFrame = [
                        "4cc07581ee78126b0bbbafb7dfd9dbbcdb78d025ec687f0d910e22f79fea9b5b",
                        "7fe70fef6d1b9d8ef72b855ad89c21c3db087b5c511a134863bfbb9e762924c7"
                    ].contains(layer.resource.rangeSHA256)
                    let volumeDisplay = path.hasSuffix("/avg/window/volumedisp.b")
                    let preview = dialog || auditedFrame || volumeDisplay
                        ? try recipe.interfaceBackgroundPreview(source, sourceFile: layer.resource.sourceFile)
                        : nil
                    let staticClick = path.hasSuffix("/avg/window/click.b") && layer.selectedMember != nil
                    guard choice != nil || preview != nil || staticClick || (layer.motionElapsedTicks == nil &&
                          (layer.selectedMember == nil || (layer.selectedMember == 0 && plainRaster))) else {
                        if layer.selectedMember != nil, layer.motionElapsedTicks != nil {
                            throw ResourceError.rejected("scene_motion_timeline_unavailable")
                        }
                        throw ResourceError.rejected("unsupported_static_layer_transform_or_motion")
                    }
                    let payload: Data
                    if choice != nil {
                        payload = try recipe.choiceButtonPayload(source, hovered: layer.id == hoveredButton)
                    } else {
                        payload = try preview ?? recipe.staticRasterPayload(source,
                            sourceFile: layer.resource.sourceFile, selectedMember: layer.selectedMember)
                    }
                    let raster = try ResourceImage.decode(payload)
                    let width = CGFloat(raster.image.width) * abs(CGFloat(layer.scaleXPercent)) / 100
                    let height = CGFloat(raster.image.height) * abs(CGFloat(layer.scaleYPercent)) / 100
                    guard width <= 65_536, height <= 65_536 else {
                        throw ResourceError.rejected("unsupported_static_layer_scale")
                    }
                    var alignmentX = layer.alignmentXPercent
                    var alignmentY = layer.alignmentYPercent
                    if preview != nil, dialog, !layer.hasExplicitAlignment {
                        alignmentX = 50
                        alignmentY = 50
                    }
                    if preview != nil, auditedFrame {
                        if let action = layer.selectedMember,
                           let keys = recipe.motionKeys(layer.resource, selectedMember: action, time: 0),
                           let ratio = keys.first(where: { $0.type == 4 && $0.texture_numbers?.first == 0 })?.literalAnchorRatio {
                            if alignmentX == 0 { alignmentX = Int32((ratio.x * 100).rounded()) }
                            if alignmentY == 0 { alignmentY = Int32((ratio.y * 100).rounded()) }
                        } else if alignmentY == 0 {
                            alignmentY = 100
                        }
                    }
                    let bounds = CGRect(
                        x: CGFloat(layer.x) - (width * CGFloat(alignmentX) / 100).rounded(),
                        y: CGFloat(layer.y) - (height * CGFloat(alignmentY) / 100).rounded(),
                        width: width, height: height)
                    textBackgrounds[layer.id] = bounds
                    let beforeCapture = layer.resource.sourceFile == "system-capture.png" ? canvas : nil
                    let covered = try raster.drawRasterPreview(bounds: bounds, opacity: layer.opacity,
                        flipX: layer.scaleXPercent < 0, flipY: layer.scaleYPercent < 0,
                        // Like the window preview, filter 2 approximates fractional sampling.
                        interpolation: layer.textureFilter == 2 ? .low : .none, canvas: &canvas)
                    if preview != nil { interfacePreviews += 1 }
                    if let beforeCapture {
                        captureChanges = zip(beforeCapture, canvas).reduce(0) { count, rows in
                            count + zip(rows.0, rows.1).count { $0 != $1 }
                        }
                    }
                    if covered {
                        rasters += 1
                    } else {
                        let canvasBounds = CGRect(x: 0, y: 0, width: canvas.first?.count ?? 0, height: canvas.count)
                        let reason = canvasBounds.intersection(bounds).isEmpty
                            ? "raster_outside_canvas" : "raster_transparent_in_canvas"
                        nonDrawing[reason, default: 0] += 1
                        if reason == "raster_outside_canvas" {
                            clipped.append(.init(layer: layer, alignmentPercent: SIMD2(alignmentX, alignmentY),
                                                 origin: SIMD2(Double(bounds.minX), Double(bounds.minY)),
                                                 size: SIMD2(Double(width), Double(height))))
                        }
                    }
                    if let choice {
                        if layer.id == hoveredButton { hoveredChoice = choice }
                        do {
                            guard let label = task.storyChoiceText(choice) else {
                                throw ResourceError.rejected("missing_choice_label")
                            }
                            let size = task.storyChoiceTextSize(layer.id)
                            let w = min(Int(width), size.map { Int($0.width) } ?? Int(width))
                            let h = min(Int(height), size.map { Int($0.height) } ?? Int(height))
                            let text = try ResourceImage.choiceLabelPreview(label,
                                style: task.storyChoiceTextStyle(layer.id), width: w, height: h)
                            let textOrigin = SIMD2(Int(bounds.minX) + (Int(width) - w) / 2,
                                                   Int(bounds.minY) + (Int(height) - h) / 2)
                            if try text.drawRasterPreview(origin: textOrigin, opacity: layer.opacity, canvas: &canvas) {
                                drawnChoiceLabels.insert(layer.id)
                            } else {
                                textIssues[layer.id] = "choice_label_without_coverage"
                            }
                        } catch {
                            textIssues[layer.id] = String(describing: error)
                        }
                    }
                } catch {
                    let sampledKeys: [OmittedLayer.SampledKey]?
                    if let member = layer.selectedMember, let time = layer.motionElapsedTicks {
                        sampledKeys = recipe.motionKeys(layer.resource, selectedMember: member, time: time)?
                            .map { .init(type: $0.type, byteOffset: $0.offset) }
                    } else {
                        sampledKeys = nil
                    }
                    omitted.append(OmittedLayer(id: layer.id, resource: layer.resource,
                                               priority: layer.priority, reason: String(describing: error),
                                               selectedMember: layer.selectedMember,
                                               motionElapsedTicks: layer.motionElapsedTicks, sampledKeys: sampledKeys))
                }
                continue
            }
            guard layer.opacity == 255, layer.scaleXPercent == 100, layer.scaleYPercent == 100,
                  layer.alignmentXPercent == 0, layer.alignmentYPercent == 0, !layer.unappliedTransform,
                  let action = layer.selectedMember, let time = layer.motionElapsedTicks,
                  let keys = recipe.motionKeys(layer.resource, selectedMember: action, time: time),
                  let bound = layer.boundRasterPreview else {
                throw ResourceError.rejected("unsupported_load_thumbnail_layer")
            }
            let draws = keys.filter { $0.type != 0 }
            guard draws.map(\.type) == [4, 11] else { throw ResourceError.rejected("unsupported_thumbnail_draw_order") }
            let container = try read(layer.resource)
            let origin = SIMD2(Int(layer.x), Int(layer.y))
            try recipe.drawFullTexturePreview(draws[0], container: container, origin: origin, canvas: &canvas)
            try recipe.drawFullTwoTextureKey(draws[1], container: container,
                boundFirst: (read(bound), bound), origin: origin, canvas: &canvas)
        }
        if midpointPending { try applyMidpoint() }
        drawMessages(before: .max, id: .max)
        textPreviewCount = textCount
        textPreviewWithoutCoverageCount = uncoveredTextCount
        for id in visibleChoices.keys where !drawnChoiceLabels.contains(id) && textIssues[id] == nil {
            textIssues[id] = "visible_choice_label_unrendered"
        }
        textPreviewIssues = textIssues
        layerCount = thumbnails
        staticRasterCount = rasters
        compositedMotionLayers = compositedMotions
        choiceLabelPreviewCount = drawnChoiceLabels.count
        hoveredChoicePreview = hoveredChoice
        interfaceBackgroundPreviewCount = interfacePreviews
        uncoveredMotions = uncovered
        clippedRasters = clipped
        nonDrawingReasons = nonDrawing
        nonDrawingLayerCount = nonDrawing.values.reduce(0, +)
        captureDrawChangedPixels = captureChanges
        omittedLayers = omitted
        var hash = SHA256()
        var changes = 0
        for (before, after) in zip(background, canvas) {
            changes += zip(before, after).count { $0 != $1 }
            after.withUnsafeBytes { hash.update(bufferPointer: $0) }
        }
        changedPixels = changes
        canvasSHA256 = hash.finalize().map { String(format: "%02x", $0) }.joined()
        transitionMidpointSHA256 = overlapProgress != nil ? canvasSHA256 : nil
        if let exportPNG {
            let width = blankRow.count
            let height = canvas.count
            var pixels = Data(capacity: width * height * 4)
            for row in canvas { row.withUnsafeBytes { pixels.append(contentsOf: $0) } }
            let format = CGBitmapInfo.byteOrder32Little.union(
                CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue))
            let png = NSMutableData()
            guard let provider = CGDataProvider(data: pixels as CFData),
                  let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                    bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: format, provider: provider, decode: nil, shouldInterpolate: false,
                    intent: .defaultIntent),
                  let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil) else {
                throw ResourceError.rejected("scene_preview_png_initialization")
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw ResourceError.rejected("scene_preview_png_encoding")
            }
            exportPNG(png as Data)
        }
    }
}
