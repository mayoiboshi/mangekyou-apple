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
        var hostAlignment: [Int32]? = nil
        var hasExplicitAlignment: Bool? = nil
        var boundTextureSlots: [Int32]? = nil
        var videoScalePercent: [Double]? = nil
        var videoTransformUnsupported: Bool? = nil
        let status: EvidenceStatus = .unsupported
    }

    let status: EvidenceStatus = .inferred
    let borderBlend = "default_fixed_point_preview"
    let canvasWidth: Int
    let canvasHeight: Int
    let layerCount: Int
    let sceneLayerCount: Int
    struct CompositedMotionLayer: Encodable {
        let id: UInt64
        let resource: ScriptLocation
        let selectedMember: Int32
        let motionElapsedTicks: Int32
        let drawKeyOffsets: [Int]
        let boundSlotZero: ScriptLocation?
    }

    struct StaticRasterLayer: Encodable {
        let id: UInt64
        let resource: ScriptLocation
        let priority: Int32
        let bounds: [Double]
    }

    let staticRasterCount: Int
    let staticRasterLayers: [StaticRasterLayer]
    let fractionalScalePreviewCount: Int
    let embeddedAlignmentCandidateCount: Int
    let dynamicMessageSurfaceCount: Int
    let sampling2CandidateCount: Int
    let inactiveMessageSurfaceCount: Int
    let dualTextureCandidateCount: Int
    let cutinFrameCandidateCount: Int
    let cutinFrameCandidateTicks: Int32?
    let cutinFrameCandidateIndex: Int32?
    let sceneVideoCandidateTicks: [Int32]
    let sceneVideoFrozenFirstFrameCount: Int
    let sceneVideoExplicitSampleTicks: [Int32]
    var sceneDepthOrderCandidate: String? = nil
    let sceneOutputMaskCandidate: Bool
    let sceneOutputMaskExcludedCount: Int
    struct BarPreviewComponent: Encodable {
        let handle: UInt64
        let kind: String
        let priority: Int32
        let placementBasis: String
        let candidateTime: Float?
        let covered: Bool
    }
    let barPreviewCandidate: Bool
    let barPreviewScope: String?
    let barPreviewComponents: [BarPreviewComponent]
    struct ButtonPreviewCandidate: Encodable {
        let handle: UInt64
        let action: String
        let textSurfaceOmitted: Bool
        let pendingTextOperations: Int?
        let committedTextOperations: Int?
        let textRuns: Int?
        let parameterizedNewlines: Int?
        let textBounds: [Int32]?
        let textOperationShapes: [String]?
        let tinyAnchorOffsetCandidate: Bool
    }
    let buttonPreviewCandidates: [ButtonPreviewCandidate]
    let buttonPreviewScope: String?
    let messageBackgroundCandidateIDs: [UInt64]
    let savedLayerTimeCandidateCount: Int
    let savedLayerTimeSamples: [ScriptMachine.SavedDisplayDraw.SavedLayerTimeSample]
    let compositedMotionLayers: [CompositedMotionLayer]
    let interfaceBackgroundPreviews: [ScriptLocation]
    var interfaceBackgroundPreviewCount: Int { interfaceBackgroundPreviews.count }
    let textPreviewCount: Int
    let textPreviewLayerIDs: [UInt64]
    let textPreviewBounds: [UInt64: [Int64]]
    let textPreviewMargins: [UInt64: [Int32]]
    let textPreviewWithoutCoverageCount: Int
    let textPreviewIssues: [UInt64: String]
    let textPlaceholderScalarCounts: [UInt64: Int]
    let choiceLabelPreviewCount: Int
    let hoveredChoicePreview: Int32?
    let uncoveredMotions: [ScriptMachine.SavedDisplayDraw.UncoveredMotion]
    let clippedRasters: [ScriptMachine.SavedDisplayDraw.ClippedRaster]
    let nonDrawingReasons: [String: Int]
    let nonDrawingLayerCount: Int
    let captureDrawChangedPixels: Int?
    let omittedLayers: [OmittedLayer]
    var isIncomplete: Bool {
        barPreviewCandidate || sceneOutputMaskCandidate || sceneDepthOrderCandidate != nil || !omittedLayers.isEmpty || !textPreviewIssues.isEmpty || interfaceBackgroundPreviewCount > 0 || fractionalScalePreviewCount > 0 || embeddedAlignmentCandidateCount > 0 || dynamicMessageSurfaceCount > 0 || sampling2CandidateCount > 0 || inactiveMessageSurfaceCount > 0 || dualTextureCandidateCount > 0 || cutinFrameCandidateCount > 0 || !sceneVideoCandidateTicks.isEmpty || savedLayerTimeCandidateCount > 0
    }
    let changedPixels: Int
    let canvasSHA256: String
    let transitionMidpointSHA256: String?
    let originalRendererEquivalence: EvidenceStatus = .notTested

    init(task: ScriptMachine, assets: SafeDirectory, recipe: ScriptImageRecipe, backgroundPath: String,
         suppliedCapture: Data?, saveDirectory: SafeDirectory?, choicePointer: CGPoint? = nil,
         atDrawRequest: Bool = false, capturePriority: Int32? = nil, overlapProgress: (elapsed: UInt32, duration: UInt32)? = nil,
         canvasSize: SIMD2<Int>? = nil,
         cutinFrameTicks: Int32? = nil,
         cutinFrame: ((ScriptLocation, (offset: Int, length: Int, sha256: String)) throws -> Data)? = nil,
         sceneVideoFrame: ((ScriptLocation, Int32) throws -> Data)? = nil,
         frozenVideoFirstFrame: Bool = false,
         unclockedVideoSampleTicks: Int32? = nil,
         filterOutputMaskCandidate: Bool = false,
         sceneDepthOrderCandidate: Bool = false,
         researchBarPreview: Bool = false,
         omitResearchBarComponents: Bool = false,
         useSavedLayerTimesCandidate: Bool = false,
         savedLayerAdvanceDelta: Int32? = nil,
         exportPNG: ((Data) -> Void)? = nil, exportJPEG: ((Data) -> Void)? = nil) throws {
        let rawLayers = task.staticImageLayers.filter { layer in
            overlapProgress != nil || (capturePriority.map { layer.priority <= $0 } ?? true)
        }
        let rawMessages = task.messageTextLayers.filter { message in
            message.isVisible && (overlapProgress != nil || (capturePriority.map { (message.priority ?? .max) <= $0 } ?? true))
        }.sorted {
            ($0.priority ?? .max, $0.id) < ($1.priority ?? .max, $1.id)
        }
        func included(_ id: UInt64) throws -> Bool {
            guard filterOutputMaskCandidate else { return true }
            guard let visible = task.researchSceneOutputVisibility(id) else {
                throw ResourceError.rejected("scene_output_mask_candidate_unknown")
            }
            return visible
        }
        let includedLayers = try rawLayers.filter { try included($0.id) }
        let sceneLayers = sceneDepthOrderCandidate
            ? includedLayers.sorted {
                if $0.priority == $1.priority { return $0.id < $1.id }
                return $0.priority > $1.priority
            }
            : includedLayers
        let messages = try rawMessages.filter { try included($0.id) }
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
            if let embedded = task.savedTextureBytes(source) {
                data = embedded
            } else if source.sourceFile == "system-capture.png", let suppliedCapture {
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
        let decodedBackground = try ResourceImage.decode(assets.read(backgroundPath)).opaqueCanvas(over: CGColor(gray: 0, alpha: 1))
        let background: [[SIMD4<UInt8>]]
        if let size = canvasSize {
            guard (1...4096).contains(size.x), (1...4096).contains(size.y), size.x * size.y <= 4_194_304 else {
                throw ResourceError.rejected("scene_preview_canvas_size_outside_profile")
            }
            let black = SIMD4<UInt8>(0, 0, 0, 255)
            var padded = Array(repeating: Array(repeating: black, count: size.x), count: size.y)
            for y in 0..<min(size.y, decodedBackground.count) {
                let row = decodedBackground[y]
                for x in 0..<min(size.x, row.count) { padded[y][x] = row[x] }
            }
            background = padded
        } else {
            background = decodedBackground
        }
        canvasWidth = background.first?.count ?? 0
        canvasHeight = background.count
        // The menu background is a script layer. The explicit image above
        // supplies canvas dimensions and the report's comparison baseline.
        let blankRow = Array(repeating: SIMD4<UInt8>(0, 0, 0, 255), count: background.first?.count ?? 0)
        var canvas = Array(repeating: blankRow, count: background.count)
        var omitted: [OmittedLayer] = []
        var rasters = 0
        var cutinFrames = 0
        var sceneVideoTicks: [Int32] = []
        var sceneVideoFrozenCount = 0
        var explicitVideoSamples: [Int32] = []
        var drawnStaticRasters: [StaticRasterLayer] = []
        var fractionalScalePreviews = 0
        var embeddedAlignmentCandidates = 0
        var savedLayerTimeCandidates = 0
        var savedLayerSamples: [ScriptMachine.SavedDisplayDraw.SavedLayerTimeSample] = []
        func motionKeysForPreview(_ layer: ScriptMachine.StaticImageLayer, member: Int32, time: Int32) throws -> [ScriptImageRecipe.MotionKey]? {
            if useSavedLayerTimesCandidate, let times = layer.savedLayerTimeCandidate {
                let keys: [ScriptImageRecipe.MotionKey]
                var advancedTimeHash: String?, advancedAuxiliaryHash: String?
                if let delta = savedLayerAdvanceDelta {
                    guard let auxiliary = layer.savedLayerAuxiliaryCandidate,
                          let advanced = recipe.advanceSavedLayerTimesCandidate(layer.resource, selectedMember: member,
                              layerTimes: times, auxiliary: auxiliary, delta: delta) else {
                        throw ResourceError.rejected("saved_layer_advance_unsupported")
                    }
                    func wordHash(_ words: [Int32]) -> String {
                        var data = Data()
                        for word in words { var little = word.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
                        return data.sha256Hex
                    }
                    keys = advanced.keys
                    advancedTimeHash = wordHash(advanced.times)
                    advancedAuxiliaryHash = wordHash(advanced.auxiliary)
                } else {
                    guard let frozen = recipe.motionKeysAtSavedLayerTimesCandidate(layer.resource, selectedMember: member,
                                                                                  layerTimes: times) else {
                        throw ResourceError.rejected("saved_layer_time_sampling_unavailable")
                    }
                    keys = frozen
                }
                savedLayerTimeCandidates += 1
                savedLayerSamples.append(.init(resource: layer.resource, selectedMember: member,
                    keyOffsets: keys.map(\.offset), advanceDelta: savedLayerAdvanceDelta,
                    advancedTimeSHA256: advancedTimeHash, advancedAuxiliarySHA256: advancedAuxiliaryHash))
                return keys
            }
            return recipe.motionKeys(layer.resource, selectedMember: member, time: time)
        }
        var boundMessageSurfaceIDs: Set<UInt64> = []
        var inactiveMessageSurfaceIDs: Set<UInt64> = []
        var sampling2Candidates = 0
        var dualTextureCandidates = 0
        var compositedMotions: [CompositedMotionLayer] = []
        var interfacePreviews: [ScriptLocation] = []
        var uncovered: [ScriptMachine.SavedDisplayDraw.UncoveredMotion] = []
        var clipped: [ScriptMachine.SavedDisplayDraw.ClippedRaster] = []
        var nonDrawing: [String: Int] = [:]
        var captureChanges: Int?
        var textCount = 0
        var textLayerIDs: [UInt64] = []
        var textBounds: [UInt64: [Int64]] = [:]
        var textMargins: [UInt64: [Int32]] = [:]
        var uncoveredTextCount = 0
        var textIssues: [UInt64: String] = [:]
        func recordTextIssue(_ id: UInt64, _ issue: String) {
            if let old = textIssues[id] {
                if !old.components(separatedBy: ";").contains(issue) { textIssues[id] = old + ";" + issue }
            } else { textIssues[id] = issue }
        }
        func messageSurface(_ message: ScriptMachine.MessageTextLayer, leadingVerticalOffset: Int = 0) throws -> Data {
            guard let bounds = message.canvasBounds, bounds.count == 4,
                  message.surfaceMargins.count == 2,
                  message.surfaceMargins.allSatisfy({ (0...256).contains($0) }),
                  let width = Int(exactly: bounds[2] - bounds[0]),
                  let height = Int(exactly: bounds[3] - bounds[1]),
                  (1...4096).contains(width), (1...4096).contains(height),
                  leadingVerticalOffset >= 0, leadingVerticalOffset < height else {
                throw ResourceError.rejected("message_surface_bounds_outside_profile")
            }
            let mx = Int(message.surfaceMargins[0]), my = Int(message.surfaceMargins[1])
            let surfaceWidth = max(4, width) + 2 * mx
            let surfaceHeight = max(4, height) + 2 * my
            guard surfaceWidth <= 4096, surfaceHeight <= 4096,
                  let surface = CGContext(data: nil, width: surfaceWidth, height: surfaceHeight,
                    bitsPerComponent: 8, bytesPerRow: surfaceWidth * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw ResourceError.rejected("message_surface_allocation_outside_profile")
            }
            let raster = try ResourceImage.textPreview(message.unscaledSurface, width: width, height: height)
            if !message.unhandledDirectives.isEmpty {
                recordTextIssue(message.id, "text_preview_unhandled_directives:" + message.unhandledDirectives.joined(separator: ","))
            }
            if let note = raster.notes.first(where: { $0.hasPrefix("missing_glyphs:") && $0 != "missing_glyphs:0" }) {
                recordTextIssue(message.id, "text_preview_" + note)
            }
            if raster.notes.contains("text_truncated") { recordTextIssue(message.id, "text_preview_truncated") }
            if let note = raster.notes.first(where: { $0.hasPrefix("line_break_candidate:") }) {
                recordTextIssue(message.id, "text_preview_" + note)
            }
            for note in raster.notes where note.hasPrefix("line_break_candidate_ruby:") || note.hasPrefix("line_break_candidate_indent:") {
                recordTextIssue(message.id, "text_preview_" + note)
            }
            surface.clear(CGRect(x: 0, y: 0, width: surfaceWidth, height: surfaceHeight))
            surface.draw(raster.image, in: CGRect(x: mx, y: surfaceHeight - my - height - leadingVerticalOffset,
                                                   width: width, height: height))
            guard let image = surface.makeImage() else { throw ResourceError.rejected("message_surface_image") }
            let encoded = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil) else {
                throw ResourceError.rejected("message_surface_png")
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw ResourceError.rejected("message_surface_png") }
            return encoded as Data
        }
        var placeholderScalars: [UInt64: Int] = [:]
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
                if inactiveMessageSurfaceIDs.contains(message.id) { continue }
                textLayerIDs.append(message.id)
                textBounds[message.id] = message.canvasBounds
                textMargins[message.id] = message.surfaceMargins
                if boundMessageSurfaceIDs.contains(message.id) {
                    textCount += 1
                    continue
                }
                let placeholders = message.runs.reduce(0) { count, run in
                    count + run.text.unicodeScalars.count { [0x25a0, 0x25a1, 0x3013, 0xfffc, 0xfffd].contains($0.value) }
                }
                if placeholders > 0 { placeholderScalars[message.id] = placeholders }
                if !message.unhandledDirectives.isEmpty {
                    recordTextIssue(message.id, "text_preview_unhandled_directives:" + message.unhandledDirectives.joined(separator: ","))
                }
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
                    guard message.scaleXPercent != 0, message.scaleYPercent != 0 else {
                        textCount += 1
                        uncoveredTextCount += 1
                        continue
                    }
                    let raster = try ResourceImage.textPreview(message,
                        width: Int(bounds[2] - bounds[0]), height: Int(bounds[3] - bounds[1]))
                    if let note = raster.notes.first(where: { $0.hasPrefix("missing_glyphs:") && $0 != "missing_glyphs:0" }) {
                        recordTextIssue(message.id, "text_preview_" + note)
                    }
                    if raster.notes.contains("text_truncated") { recordTextIssue(message.id, "text_preview_truncated") }
                    if let note = raster.notes.first(where: { $0.hasPrefix("line_break_candidate:") }) {
                        recordTextIssue(message.id, "text_preview_" + note)
                    }
                    for note in raster.notes where note.hasPrefix("line_break_candidate_ruby:") || note.hasPrefix("line_break_candidate_indent:") {
                        recordTextIssue(message.id, "text_preview_" + note)
                    }
                    let x = position(bounds[0], bounds[2], placement: message.x,
                                     near: background.minX, far: background.maxX, percent: message.scaleXPercent)
                    let y = position(bounds[1], bounds[3], placement: message.y,
                                     near: background.minY, far: background.maxY, percent: message.scaleYPercent)
                    // textPreview already scales and mirrors the glyph surface.
                    let target = CGRect(x: x, y: y, width: raster.image.width, height: raster.image.height)
                    let covered = try raster.drawRasterPreview(bounds: target, opacity: 255, canvas: &canvas)
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
        let researchBars = researchBarPreview ? task.unrenderedBarSnapshots : []
        guard researchBars.count <= 4, !researchBarPreview || !researchBars.isEmpty else {
            throw ResourceError.rejected("bar_scene_preview_count_limit")
        }
        var barQueue: [(priority: Int32, bar: ScriptMachine.UnrenderedBarSnapshot, progress: Bool)] = []
        for bar in omitResearchBarComponents ? [] : researchBars {
            let usesInitializerZero = !bar.placementSet && bar.placement == [0, 0, 0]
            guard (bar.placementSet || usesInitializerZero), bar.placement.count == 3, bar.placement[2] <= Int32.max - 5,
                  bar.resources.count == 3, bar.resources[0] == nil,
                  bar.resources[1] != nil, bar.resources[2] != nil else {
                throw ResourceError.rejected("bar_scene_preview_outside_profile")
            }
            barQueue.append((bar.placement[2], bar, false))
            barQueue.append((bar.placement[2] + 5, bar, true))
        }
        barQueue.sort { ($0.priority, $0.bar.handle, $0.progress ? 1 : 0) < ($1.priority, $1.bar.handle, $1.progress ? 1 : 0) }
        var nextBar = 0
        var barComponents: [BarPreviewComponent] = []
        var buttonCandidates: [ButtonPreviewCandidate] = []
        var messageBackgroundCandidates: [UInt64] = []
        func drawBars(before priority: Int32, id: UInt64) throws {
            while nextBar < barQueue.count {
                let item = barQueue[nextBar]
                guard (item.priority, item.bar.handle) < (priority, id) else { break }
                nextBar += 1
                drawMessages(before: item.priority, id: item.bar.handle)
                let bar = item.bar
                // Native 0x67eb0c places slot +0x154 (track) at the bar origin
                // and +0x158 (progress) at z+5; slot +0x150 uses computed x/y
                // at z+10. Parent/world transforms remain unresolved.
                let origin = SIMD2(Int(bar.placement[0]), Int(bar.placement[1]))
                let resource = bar.resources[item.progress ? 2 : 1]!
                guard resource.byteOffset == 0, resource.byteLength <= 4 * 1024 * 1024,
                      resource.rangeSHA256 == resource.sourceSHA256 else {
                    throw ResourceError.rejected("bar_scene_preview_resource_outside_profile")
                }
                let data = try read(resource)
                var covered = false
                var sampledTime: Float?
                if item.progress {
                    guard recipe.motionNames(resource)?.first == "*Enable",
                          let duration = recipe.motionDurationInputs(resource),
                          let time = BarMotionSampling.animationTime(start: bar.transitionStart, target: bar.value,
                              maximum: bar.maximum, duration: bar.transitionDuration, remaining: bar.transitionRemaining,
                              animationDuration: duration.duration, easing: .power),
                          let keys = recipe.motionKeysAtFractionalTime(resource, selectedMember: 0, time: time) else {
                        throw ResourceError.rejected("bar_scene_preview_progress_unavailable")
                    }
                    let draws = keys.filter { $0.type != 0 }
                    guard draws.count <= 1, draws.allSatisfy({ $0.type == 4 }) else {
                        throw ResourceError.rejected("bar_scene_preview_progress_shape")
                    }
                    sampledTime = time
                    if let key = draws.first {
                        covered = try recipe.drawFullTexturePreview(key, container: data, origin: origin, canvas: &canvas)
                    }
                } else {
                    guard let names = recipe.motionNames(resource), names.first == "*Enable",
                          (1...16).contains(names.count), recipe.motionDurationInputs(resource)?.duration == 0 else {
                        throw ResourceError.rejected("bar_scene_preview_track_unavailable")
                    }
                    let original = canvas
                    var consensus: [[SIMD4<UInt8>]]?
                    for index in names.indices {
                        guard let keys = recipe.motionKeys(resource, selectedMember: Int32(index), time: 0),
                              keys.allSatisfy({ [0, 4, 6].contains($0.type) }),
                              keys.count(where: { $0.type == 4 }) == 1,
                              let key = keys.first(where: { $0.type == 4 }) else {
                            throw ResourceError.rejected("bar_scene_preview_action_unavailable")
                        }
                        var candidate = original
                        let didCover = try recipe.drawFullTexturePreview(key, container: data, origin: origin, canvas: &candidate)
                        if let consensus, consensus != candidate {
                            throw ResourceError.rejected("bar_scene_preview_actions_differ")
                        }
                        consensus = candidate
                        covered = covered || didCover
                    }
                    if let consensus { canvas = consensus }
                }
                barComponents.append(.init(handle: bar.handle, kind: item.progress ? "progress" : "track",
                                           priority: item.priority,
                                           placementBasis: bar.placementSet ? "explicit_script_candidate" : "native_initializer_zero_inferred_candidate",
                                           candidateTime: sampledTime, covered: covered))
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
        let dialogueWindow = task.dialogueWindowMotion.map {
            ScriptImageRecipe.sampleDialogueWindow(closing: $0.closing, ticks: $0.ticks)
        }
        for layer in sceneLayers {
            if midpointPending, let cutoff = capturePriority, layer.priority > cutoff {
                try applyMidpoint()
            }
            try drawBars(before: layer.priority, id: layer.id)
            drawMessages(before: layer.priority, id: layer.id)
            if !isThumbnail(layer) {
                let choice = visibleChoices[layer.id]
                if choice == nil, recipe.isNonDrawingMotion(layer.resource, selectedMember: layer.selectedMember) {
                    nonDrawing["motion_disabled", default: 0] += 1
                    continue
                }
                do {
                    let scaleX = layer.fractionalScalePercent.map { CGFloat($0.x) } ?? CGFloat(layer.scaleXPercent)
                    let scaleY = layer.fractionalScalePercent.map { CGFloat($0.y) } ?? CGFloat(layer.scaleYPercent)
                    if layer.opacity == 0 || scaleX == 0 || scaleY == 0 {
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
                    if choice == nil, let member = layer.selectedMember,
                       let time = layer.motionElapsedTicks,
                       recipe.hasNoActiveDrawKey(layer.resource, selectedMember: member, time: time) {
                        _ = try read(layer.resource)
                        if layer.resource.rangeSHA256 == "97bb05fa8aaaff094f9ef12978d6fca0c7af6bd3081a01bbedd7ae5c02902a68",
                           messages.contains(where: { $0.id == layer.id }) {
                            inactiveMessageSurfaceIDs.insert(layer.id)
                        }
                        nonDrawing["no_active_draw_key", default: 0] += 1
                        continue
                    }
                    if let dialogueWindow, recipe.windowTextureIsOffCanvas(layer, offsetY: dialogueWindow.y,
                                                                          canvasHeight: canvas.count) {
                        _ = try read(layer.resource)
                        nonDrawing["window_texture_outside_canvas", default: 0] += 1
                        continue
                    }
                    guard !layer.unappliedTransform || layer.fractionalScalePercent != nil else { throw ResourceError.rejected("unsupported_static_layer_3d_transform") }
                    if layer.isTheoraResource, let sceneVideoFrame {
                        let frozen = frozenVideoFirstFrame && layer.selectedMember == nil && layer.motionElapsedTicks == nil
                        let explicitTicks = layer.selectedMember == nil && layer.motionElapsedTicks == nil ? unclockedVideoSampleTicks : nil
                        guard sceneVideoTicks.count < 4,
                              (layer.selectedMember == 0 || frozen || explicitTicks != nil),
                              let ticks = explicitTicks ?? (frozen ? Int32(0) : layer.motionElapsedTicks), ticks >= 0,
                              !layer.unappliedTransform, scaleX == 100, scaleY == 100,
                              layer.fractionalScalePercent == nil else {
                            throw ResourceError.rejected("scene_video_frame_layer_outside_profile")
                        }
                        let frameData = try sceneVideoFrame(layer.resource, ticks)
                        let frame = try ResourceImage.decode(frameData)
                        let width = CGFloat(frame.image.width), height = CGFloat(frame.image.height)
                        let bounds = CGRect(x: CGFloat(layer.x) - (width * CGFloat(layer.alignmentXPercent) / 100).rounded(),
                                            y: CGFloat(layer.y) - (height * CGFloat(layer.alignmentYPercent) / 100).rounded(),
                                            width: width, height: height)
                        let directOpaqueVideoFrame = sceneDepthOrderCandidate && layer.opacity == 255 &&
                            bounds.origin == .zero && bounds.size.width == CGFloat(canvas.first?.count ?? 0) &&
                            bounds.size.height == CGFloat(canvas.count) && frame.image.width == (canvas.first?.count ?? 0) &&
                            frame.image.height == canvas.count
                        let covered: Bool
                        if directOpaqueVideoFrame,
                           let rows = try? ResourceImage.opaquePNGCanvasPixels(frameData,
                               width: canvas.first?.count ?? 0, height: canvas.count) {
                            // The full-size FFmpeg PNG is already an opaque RGBA raster. Keep
                            // its decoded channel values out of a DeviceRGB CGContext; the
                            // prior drawRasterPreview path applied a measurable channel shift.
                            for y in rows.indices { canvas[y] = rows[y] }
                            covered = true
                        } else {
                            covered = try frame.drawRasterPreview(bounds: bounds, opacity: layer.opacity,
                                flipX: false, flipY: false, interpolation: .none, canvas: &canvas)
                        }
                        sceneVideoTicks.append(ticks)
                        if frozen { sceneVideoFrozenCount += 1 }
                        if explicitTicks != nil { explicitVideoSamples.append(ticks) }
                        if covered {
                            rasters += 1
                            drawnStaticRasters.append(.init(id: layer.id, resource: layer.resource,
                                priority: layer.priority,
                                bounds: [Double(bounds.minX), Double(bounds.minY), Double(bounds.width), Double(bounds.height)]))
                        } else { nonDrawing["scene_video_frame_no_coverage", default: 0] += 1 }
                        continue
                    }
                    if let cutinFrame, layer.resource.sourceSHA256 == "06e44e46d8ba357eb49f61bfca45c320aa0f281f3ec3656e1717f648edc13050" {
                        guard layer.selectedMember == 0, !layer.unappliedTransform,
                              scaleX == 100, scaleY == 100, layer.fractionalScalePercent == nil,
                              let range = try recipe.member(layer.resource, "万華鏡.ogv") else {
                            throw ResourceError.rejected("cutin_frame_layer_outside_profile")
                        }
                        let frame = try ResourceImage.decode(cutinFrame(layer.resource, range))
                        guard frame.image.width == 1280, frame.image.height == 720 else {
                            throw ResourceError.rejected("cutin_frame_dimensions")
                        }
                        let bounds = CGRect(x: CGFloat(layer.x) - (1280 * CGFloat(layer.alignmentXPercent) / 100).rounded(),
                                            y: CGFloat(layer.y) - (720 * CGFloat(layer.alignmentYPercent) / 100).rounded(),
                                            width: 1280, height: 720)
                        let covered = try frame.drawRasterPreview(bounds: bounds, opacity: layer.opacity,
                            flipX: false, flipY: false, interpolation: .none, canvas: &canvas)
                        cutinFrames += 1
                        if covered {
                            rasters += 1
                            drawnStaticRasters.append(.init(id: layer.id, resource: layer.resource,
                                priority: layer.priority,
                                bounds: [Double(bounds.minX), Double(bounds.minY), Double(bounds.width), Double(bounds.height)]))
                        } else { nonDrawing["cutin_frame_no_coverage", default: 0] += 1 }
                        continue
                    }
                    if researchBarPreview, layer.resource.sourceSHA256 == "6bc736bafc4cd9201c690042ce31aab147a59d052a920212d6f043a4c673efc9",
                       layer.selectedMember == nil, let message = messages.first(where: { $0.id == layer.id }) {
                        guard layer.resource.byteOffset == 0, layer.resource.rangeSHA256 == layer.resource.sourceSHA256,
                              layer.opacity == 255, scaleX == 100, scaleY == 100,
                              layer.fractionalScalePercent == nil, !layer.unappliedTransform,
                              !layer.hasExplicitAlignment, layer.boundTextureLocations.isEmpty,
                              recipe.motionNames(layer.resource) == ["*Enable"],
                              recipe.motionDurationInputs(layer.resource)?.duration == 0,
                              let keys = recipe.motionKeys(layer.resource, selectedMember: 0, time: 0),
                              keys.count == 2, keys.allSatisfy({ $0.type == 4 && $0.texture_numbers?.first == 0 }),
                              recipe.embeddedTexture(layer.resource, slot: 0)?.name.lowercased().hasPrefix("*messurface") == true,
                              let scoped = recipe.scopedTextureKeys(keys), scoped.count == 2 else {
                            throw ResourceError.rejected("message_background_candidate_outside_profile")
                        }
                        let surface = try messageSurface(message)
                        let covered = try recipe.drawScopedTexturePreview(scoped, container: read(layer.resource),
                            boundTextures: [0: surface], origin: SIMD2(Int(layer.x), Int(layer.y)),
                            hostScale: SIMD2(1, 1), anchorOverride: nil, layerOpacity: 255, canvas: &canvas)
                        messageBackgroundCandidates.append(layer.id)
                        boundMessageSurfaceIDs.insert(layer.id)
                        if covered { rasters += 1 } else { nonDrawing["message_background_candidate_no_coverage", default: 0] += 1 }
                        continue
                    }
                    if researchBarPreview, let checked = layer.researchButtonChecked,
                       let locked = layer.researchButtonLocked, layer.selectedMember == nil,
                       layer.resource.sourceFile.lowercased().hasSuffix(".b") {
                        guard layer.opacity == 255, scaleX == 100, scaleY == 100,
                              layer.fractionalScalePercent == nil, !layer.unappliedTransform,
                              layer.resource.byteOffset == 0, layer.resource.byteLength <= 4 * 1024 * 1024,
                              layer.resource.rangeSHA256 == layer.resource.sourceSHA256,
                              let names = recipe.motionNames(layer.resource),
                              recipe.motionDurationInputs(layer.resource)?.duration == 0 else {
                            throw ResourceError.rejected("button_scene_candidate_outside_profile")
                        }
                        // Current button action and pointer state are not tracked.
                        // This is an explicitly reported time-zero state candidate.
                        let loopUncheckedCandidate = layer.resource.sourceSHA256 ==
                            "c623b8529af2cffe0476d24c645b8036004c0f725e3f65925d2a4aff900d3016" && !checked && !locked
                        let action = locked ? "*OnLock" : (checked ? "*OnCheck" : (loopUncheckedCandidate ? "*OffCheck" : "*Enable"))
                        guard let index = names.firstIndex(of: action),
                              let keys = recipe.motionKeys(layer.resource, selectedMember: Int32(index), time: 0),
                              keys.allSatisfy({ [0, 4, 6].contains($0.type) }),
                              let scoped = recipe.scopedTextureKeys(keys.filter { $0.type != 6 }) else {
                            throw ResourceError.rejected("button_scene_candidate_action_unavailable")
                        }
                        let textSlots = Set(scoped.compactMap { entry -> Int32? in
                            guard let slot = entry.texture.texture_numbers?.first,
                                  recipe.embeddedTexture(layer.resource, slot: slot)?.name.lowercased().hasPrefix("*messurface") == true else { return nil }
                            return slot
                        })
                        let background = scoped.filter { entry in
                            guard let slot = entry.texture.texture_numbers?.first else { return false }
                            return !textSlots.contains(slot)
                        }
                        guard !background.isEmpty else { throw ResourceError.rejected("button_scene_candidate_no_background") }
                        var bindings: [Int32: Data] = [:]
                        if textSlots.count == 1, let slot = textSlots.first,
                           let buttonText = task.researchButtonTextLayer(layer.id) {
                            bindings[slot] = try messageSurface(buttonText.layer,
                                leadingVerticalOffset: Int(buttonText.leadingVerticalOffset))
                        }
                        let drawable = bindings.isEmpty ? background : scoped
                        let tinyAnchorCandidate = drawable.contains { entry in
                            guard let slot = entry.texture.texture_numbers?.first, bindings[slot] == nil else { return false }
                            return recipe.hasTinyAnchorOffsetCandidate(layer.resource, slot: slot)
                        }
                        let covered = try recipe.drawScopedTexturePreview(drawable, container: read(layer.resource),
                            boundTextures: bindings, origin: SIMD2(Int(layer.x), Int(layer.y)),
                            hostScale: SIMD2(1, 1), anchorOverride: nil, layerOpacity: 255,
                            allowTinyAnchorCandidate: true, canvas: &canvas)
                        let textState = task.researchButtonTextOperationCounts(layer.id)
                        let textShape = task.researchButtonTextShape(layer.id)
                        let textOmitted = !textSlots.isEmpty && bindings.isEmpty
                        buttonCandidates.append(.init(handle: layer.id, action: action, textSurfaceOmitted: textOmitted,
                            pendingTextOperations: textState?.pending, committedTextOperations: textState?.committed,
                            textRuns: textState?.text, parameterizedNewlines: textState?.parameterizedNewlines,
                            textBounds: textShape?.bounds, textOperationShapes: textShape?.operations,
                            tinyAnchorOffsetCandidate: tinyAnchorCandidate))
                        if covered { rasters += 1 } else { nonDrawing["button_candidate_no_coverage", default: 0] += 1 }
                        if !bindings.isEmpty { boundMessageSurfaceIDs.insert(layer.id) }
                        if textOmitted {
                            omitted.append(.init(id: layer.id, resource: layer.resource, priority: layer.priority,
                                reason: "button_text_surface_unrendered", selectedMember: Int32(index),
                                motionElapsedTicks: 0, sampledKeys: nil))
                        } else if !bindings.isEmpty, textIssues[layer.id] != nil {
                            omitted.append(.init(id: layer.id, resource: layer.resource, priority: layer.priority,
                                reason: "button_text_surface_layout_candidate", selectedMember: Int32(index),
                                motionElapsedTicks: 0, sampledKeys: nil))
                        }
                        continue
                    }
                    if layer.fractionalScalePercent != nil {
                        guard choice == nil else {
                            throw ResourceError.rejected("unsupported_fractional_scale_resource")
                        }
                    }
                    // The dc field feeds the ABMP sound callback at 0x580283.
                    // It does not select a destination for this raster preview.
                    // Share the player's audited opaque text-effect raster for its active interval.
                    let staticTextEffect = layer.resource.rangeSHA256 ==
                        "cd20f60e0984abd828a5f8c8567335a385339372dd99c2731def35ac4b4e972b" &&
                        layer.selectedMember == 0 && layer.boundRasterPreview == nil &&
                        (0..<1000).contains(layer.motionElapsedTicks ?? -1)
                    if choice == nil, !staticTextEffect, let member = layer.selectedMember, let time = layer.motionElapsedTicks,
                       let keys = try motionKeysForPreview(layer, member: member, time: time) {
                        let draws = keys.filter { $0.type != 0 }
                        var drawnOffsets = draws.map(\.offset)
                        let payload = try read(layer.resource)
                        let origin = SIMD2(Int(layer.x), Int(layer.y))
                        if let scoped = recipe.scopedTextureKeys(keys), !scoped.isEmpty {
                            let embeddedAlignmentCandidate = layer.resource.rangeSHA256 ==
                                "5b0f2bc31cc6b14311642df53590c1efd3edec3b6a032e13b90424ce70e99b03" &&
                                layer.boundRasterPreview == nil && layer.boundTextureLocations.isEmpty &&
                                layer.hasExplicitAlignment && layer.alignmentXPercent == 50 && layer.alignmentYPercent == 100 &&
                                !layer.unappliedTransform && scoped.count == 1 && scoped[0].states.isEmpty &&
                                scoped[0].texture.offset == 2133 && scoped[0].texture.texture_numbers?.first == 0 &&
                                scoped[0].texture.literalAnchorRatio?.x == 0.5 && scoped[0].texture.literalAnchorRatio?.y == 1 &&
                                recipe.embeddedTexture(layer.resource, slot: 0) != nil
                            guard layer.boundRasterPreview != nil || !layer.hasExplicitAlignment ||
                                  (layer.alignmentXPercent == 0 && layer.alignmentYPercent == 0) || embeddedAlignmentCandidate else {
                                throw ResourceError.rejected("unsupported_static_layer_motion_keys")
                            }
                            let anchor = layer.hasExplicitAlignment && layer.boundRasterPreview != nil
                                ? SIMD2(Double(layer.alignmentXPercent) / 100, Double(layer.alignmentYPercent) / 100)
                                : nil
                            let scale = SIMD2(Double(scaleX) / 100, Double(scaleY) / 100)
                            let referencedSlots = Set(scoped.compactMap { $0.texture.texture_numbers?.first })
                            var boundTextures = try layer.boundTextureLocations.filter { referencedSlots.contains($0.key) }
                                .mapValues(read)
                            var usedMessageSurface = false
                            var usedMessageSlot: Int32?
                            let messageSlots = referencedSlots.filter { slot in
                                recipe.embeddedTexture(layer.resource, slot: slot)?.name.lowercased().hasPrefix("*messurface") == true
                            }
                            if let message = messages.first(where: { $0.id == layer.id }),
                               recipe.hasNamedMessageSurface(layer.resource),
                               messageSlots.count != 1 || messageSlots.first.flatMap({ boundTextures[$0] }) != nil {
                                textIssues[message.id] = "message_surface_binding_unresolved"
                            }
                            if messageSlots.count == 1, let messageSlot = messageSlots.first,
                               boundTextures[messageSlot] == nil,
                               let message = messages.first(where: { $0.id == layer.id }) {
                                boundTextures[messageSlot] = try messageSurface(message)
                                usedMessageSurface = true
                                usedMessageSlot = messageSlot
                            }
                            let sampling2Slot = layer.resource.rangeSHA256 ==
                                "97bb05fa8aaaff094f9ef12978d6fca0c7af6bd3081a01bbedd7ae5c02902a68" ? usedMessageSlot : nil
                            let covered = try recipe.drawScopedTexturePreview(scoped, container: payload,
                                boundTextures: boundTextures, origin: origin,
                                hostScale: scale, anchorOverride: anchor, layerOpacity: layer.opacity,
                                sampling2CandidateSlot: sampling2Slot, canvas: &canvas)
                            if embeddedAlignmentCandidate { embeddedAlignmentCandidates += 1 }
                            if !covered {
                                nonDrawing["texture_no_coverage", default: 0] += 1
                                uncovered.append(.init(resource: layer.resource, member: member,
                                                       ticks: time, drawOffsets: draws.map(\.offset)))
                                continue
                            }
                            if usedMessageSurface { boundMessageSurfaceIDs.insert(layer.id) }
                            if let sampling2Slot {
                                sampling2Candidates += scoped.count { item in
                                    item.texture.texture_numbers?.first == sampling2Slot &&
                                    recipe.composedRasterModes(texture: item.texture, states: item.states)?.sampling == 2
                                }
                            }
                            if layer.fractionalScalePercent != nil { fractionalScalePreviews += 1 }
                            if !usedMessageSurface, messages.contains(where: { $0.id == layer.id }),
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
                        } else if layer.resource.rangeSHA256 == "97bb05fa8aaaff094f9ef12978d6fca0c7af6bd3081a01bbedd7ae5c02902a68",
                                  draws.count == 1, let key = draws.first, key.type == 10,
                                  layer.opacity == 255, layer.scaleXPercent == 100, layer.scaleYPercent == 100,
                                  !layer.unappliedTransform, layer.boundTextureLocations.isEmpty,
                                  let message = messages.first(where: { $0.id == layer.id }) {
                            let surface = try messageSurface(message)
                            let covered = try recipe.drawCenterTextTransitionCandidate(key, container: payload,
                                messageSurface: surface, origin: origin, canvas: &canvas)
                            boundMessageSurfaceIDs.insert(layer.id)
                            dualTextureCandidates += 1
                            if !covered {
                                nonDrawing["dual_texture_no_coverage", default: 0] += 1
                                continue
                            }
                        } else if layer.fractionalScalePercent != nil {
                            throw ResourceError.rejected("unsupported_fractional_scale_resource")
                        } else if draws.count == 1, let key = draws.first, key.type == 11,
                                  layer.opacity == 255, layer.scaleXPercent == 100, layer.scaleYPercent == 100,
                                  layer.alignmentXPercent == 0, layer.alignmentYPercent == 0 {
                            // Reuse the bounded type-11 scanner profile from the thumbnail pass.
                            let slots = Set(key.texture_numbers ?? [])
                            let bound = try layer.boundTextureLocations.filter { slots.contains($0.key) }
                                .mapValues { (try read($0), $0) }
                            guard try recipe.drawFullTwoTextureKey(key, container: payload,
                                boundTextures: bound, origin: origin, canvas: &canvas) else {
                                nonDrawing["two_texture_no_coverage", default: 0] += 1
                                uncovered.append(.init(resource: layer.resource, member: member,
                                                       ticks: time, drawOffsets: draws.map(\.offset)))
                                continue
                            }
                        } else if let key = draws.last, member == 0,
                                  (draws.count == 1 || (draws.count == 2 && draws[0].type == 4 &&
                                   draws[0].texture_numbers?.first == 0 && layer.boundTextureLocations[0] == nil &&
                                   recipe.embeddedTexture(layer.resource, slot: 0) == nil)),
                                  let flash = recipe.whiteFlashPreview(key, container: layer.resource) {
                            guard layer.opacity == 255, layer.scaleXPercent == 100, layer.scaleYPercent == 100,
                                  layer.boundRasterPreview == nil,
                                  layer.alignmentXPercent == 50, layer.alignmentYPercent == 50 else {
                                throw ResourceError.rejected("white_flash_host_state_outside_profile")
                            }
                            let x = origin.x - flash.size.x / 2
                            let y = origin.y - flash.size.y / 2
                            let left = max(0, x)
                            let top = max(0, y)
                            let right = min(canvas.first?.count ?? 0, x + flash.size.x)
                            let bottom = min(canvas.count, y + flash.size.y)
                            guard left < right, top < bottom else {
                                nonDrawing["outside_canvas", default: 0] += 1
                                continue
                            }
                            let alpha = Int(flash.alpha)
                            func overWhite(_ value: UInt8) -> UInt8 {
                                UInt8((Int(value) * (255 - alpha) + 255 * alpha + 127) / 255)
                            }
                            for y in top..<bottom {
                                for x in left..<right {
                                    let pixel = canvas[y][x]
                                    canvas[y][x] = SIMD4(overWhite(pixel.x), overWhite(pixel.y), overWhite(pixel.z), 255)
                                }
                            }
                            if draws.count == 2 {
                                // The original submits an unbound type-4 texture;
                                // its final pixels remain unknown even when the
                                // independently audited white track can be drawn.
                                omitted.append(.init(id: layer.id, resource: layer.resource,
                                    priority: layer.priority, reason: "unbound_texture_draw_unresolved",
                                    selectedMember: member, motionElapsedTicks: time,
                                    sampledKeys: [.init(type: draws[0].type, byteOffset: draws[0].offset)]))
                                drawnOffsets = [key.offset]
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
                            selectedMember: member, motionElapsedTicks: time, drawKeyOffsets: drawnOffsets,
                            boundSlotZero: draws.contains { ($0.type == 4 || $0.type == 11) && $0.texture_numbers?.first == 0 }
                                ? layer.boundRasterPreview : nil))
                        rasters += 1
                        continue
                    }
                    let source = try read(layer.resource)
                    let plainRaster = ["PNG", "JPEG", "BMP", "DPNG", "ARGB"].contains(InventoryScanner.signature(source))
                    if layer.fractionalScalePercent != nil {
                        guard choice == nil, plainRaster, layer.selectedMember == nil,
                              layer.motionElapsedTicks == nil, layer.boundRasterPreview == nil else {
                            throw ResourceError.rejected("unsupported_fractional_scale_resource")
                        }
                    }
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
                    guard choice != nil || preview != nil || staticClick || staticTextEffect || (layer.motionElapsedTicks == nil &&
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
                    let width = CGFloat(raster.image.width) * abs(scaleX) / 100
                    let height = CGFloat(raster.image.height) * abs(scaleY) / 100
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
                        flipX: scaleX < 0, flipY: scaleY < 0,
                        // Like the window preview, filter 2 approximates fractional sampling.
                        interpolation: layer.textureFilter == 2 ? .low : .none, canvas: &canvas)
                    if preview != nil { interfacePreviews.append(layer.resource) }
                    if let beforeCapture {
                        captureChanges = zip(beforeCapture, canvas).reduce(0) { count, rows in
                            count + zip(rows.0, rows.1).count { $0 != $1 }
                        }
                    }
                    if covered {
                        rasters += 1
                        drawnStaticRasters.append(.init(id: layer.id, resource: layer.resource,
                            priority: layer.priority,
                            bounds: [Double(bounds.minX), Double(bounds.minY), Double(bounds.width), Double(bounds.height)]))
                        if layer.fractionalScalePercent != nil { fractionalScalePreviews += 1 }
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
                                               motionElapsedTicks: layer.motionElapsedTicks, sampledKeys: sampledKeys,
                                               hostAlignment: [layer.alignmentXPercent, layer.alignmentYPercent],
                                               hasExplicitAlignment: layer.hasExplicitAlignment,
                                               boundTextureSlots: layer.boundTextureLocations.keys.sorted(),
                                               videoScalePercent: layer.isTheoraResource ? [
                                                Double(layer.fractionalScalePercent?.x ?? Float(layer.scaleXPercent)),
                                                Double(layer.fractionalScalePercent?.y ?? Float(layer.scaleYPercent))] : nil,
                                               videoTransformUnsupported: layer.isTheoraResource ? layer.unappliedTransform : nil))
                }
                continue
            }
            guard layer.opacity == 255, layer.scaleXPercent == 100, layer.scaleYPercent == 100,
                  layer.alignmentXPercent == 0, layer.alignmentYPercent == 0, !layer.unappliedTransform,
                  let action = layer.selectedMember, let time = layer.motionElapsedTicks,
                  let keys = recipe.motionKeys(layer.resource, selectedMember: action, time: time),
                  layer.boundRasterPreview != nil else {
                throw ResourceError.rejected("unsupported_load_thumbnail_layer")
            }
            let draws = keys.filter { $0.type != 0 }
            guard draws.map(\.type) == [4, 11] else { throw ResourceError.rejected("unsupported_thumbnail_draw_order") }
            let container = try read(layer.resource)
            let origin = SIMD2(Int(layer.x), Int(layer.y))
            let usedSlots = Set(draws.flatMap { $0.texture_numbers ?? [] })
            let bindings = try layer.boundTextureLocations.filter { usedSlots.contains($0.key) }
                .mapValues { (try read($0), $0) }
            try recipe.drawFullTexturePreview(draws[0], container: container,
                boundTextures: bindings.mapValues { $0.0 }, origin: origin, canvas: &canvas)
            try recipe.drawFullTwoTextureKey(draws[1], container: container,
                boundTextures: bindings, origin: origin, canvas: &canvas)
        }
        if midpointPending { try applyMidpoint() }
        try drawBars(before: .max, id: .max)
        drawMessages(before: .max, id: .max)
        textPreviewCount = textCount
        textPreviewLayerIDs = textLayerIDs
        textPreviewBounds = textBounds
        textPreviewMargins = textMargins
        textPreviewWithoutCoverageCount = uncoveredTextCount
        for id in visibleChoices.keys where !drawnChoiceLabels.contains(id) && textIssues[id] == nil {
            textIssues[id] = "visible_choice_label_unrendered"
        }
        textPreviewIssues = textIssues
        textPlaceholderScalarCounts = placeholderScalars
        layerCount = thumbnails
        sceneLayerCount = sceneLayers.count
        staticRasterCount = rasters
        cutinFrameCandidateCount = cutinFrames
        cutinFrameCandidateTicks = cutinFrames > 0 ? cutinFrameTicks : nil
        cutinFrameCandidateIndex = cutinFrames > 0 ? cutinFrameTicks.map { $0 * 24 / 1000 } : nil
        sceneVideoCandidateTicks = sceneVideoTicks
        sceneVideoFrozenFirstFrameCount = sceneVideoFrozenCount
        sceneVideoExplicitSampleTicks = explicitVideoSamples
        self.sceneDepthOrderCandidate = sceneDepthOrderCandidate
            ? "placement_axis_descending_painter_order_inferred_original_depth_and_layer_order_not_tested"
            : nil
        sceneOutputMaskCandidate = filterOutputMaskCandidate
        sceneOutputMaskExcludedCount = rawLayers.count - sceneLayers.count + rawMessages.count - messages.count
        barPreviewCandidate = researchBarPreview
        barPreviewScope = researchBarPreview ? (omitResearchBarComponents
            ? "control_bar_components_omitted_unverified_output_mask_and_input"
            : "time_zero_track_pixel_consensus_power_easing_identity_transform_and_initializer_zero_placement_candidate_unverified_output_mask_and_input") : nil
        barPreviewComponents = barComponents
        buttonPreviewCandidates = buttonCandidates
        messageBackgroundCandidateIDs = messageBackgroundCandidates
        buttonPreviewScope = researchBarPreview
            ? "time_zero_action_assumed_from_local_check_and_lock_no_hover_committed_text_surface_candidate" : nil
        savedLayerTimeCandidateCount = savedLayerTimeCandidates
        savedLayerTimeSamples = savedLayerSamples
        staticRasterLayers = drawnStaticRasters
        fractionalScalePreviewCount = fractionalScalePreviews
        embeddedAlignmentCandidateCount = embeddedAlignmentCandidates
        dynamicMessageSurfaceCount = boundMessageSurfaceIDs.count
        sampling2CandidateCount = sampling2Candidates
        inactiveMessageSurfaceCount = inactiveMessageSurfaceIDs.count
        dualTextureCandidateCount = dualTextureCandidates
        compositedMotionLayers = compositedMotions
        choiceLabelPreviewCount = drawnChoiceLabels.count
        hoveredChoicePreview = hoveredChoice
        interfaceBackgroundPreviews = interfacePreviews
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
        if let export = exportPNG ?? exportJPEG {
            let width = blankRow.count
            let height = canvas.count
            var pixels = Data(capacity: width * height * 4)
            for row in canvas { row.withUnsafeBytes { pixels.append(contentsOf: $0) } }
            let format = CGBitmapInfo.byteOrder32Little.union(
                CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue))
            let encoded = NSMutableData()
            let type = exportPNG != nil ? "public.png" : "public.jpeg"
            guard let provider = CGDataProvider(data: pixels as CFData),
                  let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                    bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: format, provider: provider, decode: nil, shouldInterpolate: false,
                    intent: .defaultIntent),
                  let destination = CGImageDestinationCreateWithData(encoded, type as CFString, 1, nil) else {
                throw ResourceError.rejected("scene_preview_image_initialization")
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw ResourceError.rejected("scene_preview_image_encoding")
            }
            export(encoded as Data)
        }
    }
}
