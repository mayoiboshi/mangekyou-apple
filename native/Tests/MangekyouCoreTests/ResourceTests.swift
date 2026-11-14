import XCTest
import Foundation
import CoreGraphics
import ImageIO
@testable import MangekyouCore
import MangekyouMedia

final class ResourceTests: XCTestCase {
    func testPitchShiftCandidateKeepsSpectralStateAcrossBlocks() throws {
        var input: [Int32] = []
        for i in 0..<6000 {
            let sample = Int32((10000 * sin(2 * Double.pi * 440 * Double(i) / 44100)).rounded(.towardZero))
            input.append(sample); input.append(sample)
        }
        var whole = input, filter = StreamPitchShiftCandidate(pitch: 150)
        try filter.apply(to: &whole)
        XCTAssertTrue(whole.prefix(512 * 2).allSatisfy { $0 == 0 })
        XCTAssertTrue(whole.dropFirst(4096 * 2).contains { $0 != 0 })
        var splitFilter = StreamPitchShiftCandidate(pitch: 150)
        var first = Array(input[..<4000]), second = Array(input[4000...])
        try splitFilter.apply(to: &first); try splitFilter.apply(to: &second)
        XCTAssertEqual(first + second, whole)
        var other = input, otherFilter = StreamPitchShiftCandidate(pitch: 200)
        try otherFilter.apply(to: &other)
        XCTAssertNotEqual(other, whole)
    }
    func testTimeScaleCandidateInterpolatesStereoAndClampsLastFrame() throws {
        XCTAssertEqual(try StreamTimeScaleCandidate.pitch(researchFilterText: "timescale,pitch:150"), 150)
        XCTAssertEqual(try StreamTimeScaleCandidate.pitch(researchFilterText: "timescale,pitch:999"), 300)
        XCTAssertThrowsError(try StreamTimeScaleCandidate.pitch(researchFilterText: "timescale,pitch:150\\volume"))
        let input: [Int16] = [0, 0, 10_000, -10_000]
        XCTAssertEqual(try StreamTimeScaleCandidate.interpolate(input, outputFrames: 4),
                       [0, 0, 5000, -5000, 10000, -10000, 10000, -10000])
        XCTAssertEqual(try StreamTimeScaleCandidate.interpolate(input, outputFrames: 2), input)
        XCTAssertThrowsError(try StreamTimeScaleCandidate.interpolate([1], outputFrames: 1))
        XCTAssertThrowsError(try StreamTimeScaleCandidate.interpolate(input, outputFrames: 4097))
        let bytes = Data(repeating: 0, count: 769 * 4)
        let result = try StreamTimeScaleCandidate.interpolateStream(bytes, pitch: 75)
        XCTAssertEqual(result.blocks, 2)
        XCTAssertEqual(result.shortReadBlocks, 1)
        XCTAssertEqual(result.outputFrames, 1025)
        XCTAssertThrowsError(try StreamTimeScaleCandidate.interpolateStream(bytes, pitch: 75, maximumOutputBytes: 4000))
    }
    func testChorusCandidateKeepsStateAcrossBlocks() throws {
        var input = [Int32](repeating: 0, count: 6000)
        input[0] = 20_000
        var whole = input, filter = StreamChorusFilterCandidate(wet: 75, dry: 75, depth: 40, stereo: true)
        try filter.apply(to: &whole)
        XCTAssertEqual(whole[0], 15_000)
        XCTAssertTrue(whole.dropFirst(2).contains { $0 != 0 })
        var splitFilter = StreamChorusFilterCandidate(wet: 75, dry: 75, depth: 40, stereo: true)
        var first = Array(input[..<2000]), second = Array(input[2000...])
        try splitFilter.apply(to: &first); try splitFilter.apply(to: &second)
        XCTAssertEqual(first + second, whole)
    }
    func testReverbCandidatePreservesDelayAndChannelStateAcrossBlocks() throws {
        var input = [Int32](repeating: 0, count: 520)
        input[0] = 20_000
        var whole = input, filter = StreamReverbFilterCandidate(wet: 70, dry: 50, delay: 5, decay: 60)
        try filter.apply(to: &whole)
        XCTAssertEqual(whole[0], 10_000)
        XCTAssertTrue(stride(from: 2, to: 442, by: 2).allSatisfy { whole[$0] == 0 })
        XCTAssertNotEqual(whole[442], 0)
        XCTAssertTrue(stride(from: 1, to: whole.count, by: 2).allSatisfy { whole[$0] == 0 })
        var splitFilter = StreamReverbFilterCandidate(wet: 70, dry: 50, delay: 5, decay: 60)
        var before = Array(input[..<300]), after = Array(input[300...])
        try splitFilter.apply(to: &before); try splitFilter.apply(to: &after)
        XCTAssertEqual(before + after, whole)
    }
    func testNoiseCandidateUsesSharedStereoSeedAcrossBlocks() throws {
        let input: [Int32] = [10_000, -10_000, 20_000, -20_000, 0, 0]
        var whole = input, filter = StreamNoiseFilterCandidate()
        try filter.apply(to: &whole)
        XCTAssertEqual(whole, [8811, -8811, 16140, -16140, 0, 0])
        var splitFilter = StreamNoiseFilterCandidate(), first = Array(input[..<2]), rest = Array(input[2...])
        try splitFilter.apply(to: &first)
        try splitFilter.apply(to: &rest)
        XCTAssertEqual(first + rest, whole)
    }
    func testDistortionCandidateClipsAndFoldsBothChannels() throws {
        var clipped: [Int32] = [10_000, -10_000, 1_000, -1_000]
        try StreamDistortionFilterCandidate(volume: 100, range: 20).apply(to: &clipped)
        XCTAssertEqual(clipped, [6553, -6553, 1000, -1000])
        var folded: [Int32] = [10_000, -10_000, 20_000, -20_000]
        try StreamDistortionFilterCandidate(volume: 100, range: 20, foldback: 1).apply(to: &folded)
        XCTAssertEqual(folded, [4830, -4830, 0, 0])
        XCTAssertThrowsError(try StreamFilterChainCandidate(researchFilterText: "distortion,range:20\\unknown"))
    }
    func testStreamFilterChainPreservesOrderAndBlockState() throws {
        let input: [Int32] = [20_000, -12_000] + Array(repeating: 0, count: 126)
        var separate = input
        var equalizer = StreamThreeBandFilterCandidate(low: 0, mid: 0, high: 100)
        try equalizer.apply(to: &separate)
        try StreamVolumeFilterCandidate(volume: 200).apply(to: &separate)
        let text = "3bandeq,low:0,mid:0,high:100\\volume,vol:200"
        var chain = try StreamFilterChainCandidate(researchFilterText: text)
        var first = Array(input[..<26]), second = Array(input[26...])
        try chain.apply(to: &first)
        try chain.apply(to: &second)
        XCTAssertEqual(first + second, separate)
        var reverse = try StreamFilterChainCandidate(researchFilterText: "volume,vol:200\\3bandeq,low:0,mid:0,high:100")
        var reversed = input
        try reverse.apply(to: &reversed)
        XCTAssertNotEqual(reversed, separate)
        var pcm = Data()
        for sample in input {
            var value = Int16(clamping: sample).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        var pcmChain = try StreamFilterChainCandidate(researchFilterText: text)
        try pcmChain.applyPCM16LittleEndian(to: &pcm)
        let expected = separate.flatMap { sample -> [UInt8] in
            let value = UInt16(bitPattern: Int16(clamping: sample))
            return [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]
        }
        XCTAssertEqual(pcm, Data(expected))
        XCTAssertThrowsError(try StreamFilterChainCandidate(researchFilterText: text + "\\unknown"))
        XCTAssertThrowsError(try StreamFilterChainCandidate(researchFilterText: "3bandeq,low:1,low:2"))
    }

    func testThreeBandCandidateKeepsIndependentChannelStateAcrossBlocks() throws {
        var input = [Int32](repeating: 0, count: 128)
        input[0] = 20_000
        var whole = input
        var filter = StreamThreeBandFilterCandidate(low: 0, mid: 0, high: 100)
        try filter.apply(to: &whole)
        XCTAssertTrue(stride(from: 0, to: whole.count, by: 2).contains { whole[$0] != 0 })
        XCTAssertTrue(stride(from: 1, to: whole.count, by: 2).allSatisfy { whole[$0] == 0 })
        var splitFilter = StreamThreeBandFilterCandidate(low: 0, mid: 0, high: 100)
        var first = Array(input[..<26]), second = Array(input[26...])
        try splitFilter.apply(to: &first)
        try splitFilter.apply(to: &second)
        XCTAssertEqual(first + second, whole)
        var odd: [Int32] = [1]
        XCTAssertThrowsError(try splitFilter.apply(to: &odd))
        XCTAssertEqual(odd, [1])
    }

    func testStreamVolumeFilterCandidateStereoClippingAndTruncation() throws {
        var samples: [Int32] = [-101, 101, 30_000, -30_000]
        try StreamVolumeFilterCandidate(volume: 150, pan: 25, range: 100).apply(to: &samples)
        XCTAssertEqual(samples, [-151, 75, 32_768, -22_500])
        var center: [Int32] = [-32_768, 32_767]
        try StreamVolumeFilterCandidate().apply(to: &center)
        XCTAssertEqual(center, [-32_768, 32_767])
        var odd: [Int32] = [1]
        XCTAssertThrowsError(try StreamVolumeFilterCandidate().apply(to: &odd))
        XCTAssertEqual(odd, [1])
        let parsed = try StreamVolumeFilterCandidate(researchFilterText: "volume,vol:150,pan:25,range:100")
        var parsedSamples: [Int32] = [-101, 101, 30_000, -30_000]
        try parsed.apply(to: &parsedSamples)
        XCTAssertEqual(parsedSamples, samples)
        let updated = try parsed.updating(researchFilterText: "volume,pan:75")
        XCTAssertEqual(updated, .init(volume: 150, pan: 75, range: 100))
        var pcm = Data([0x9b, 0xff, 0x65, 0x00, 0x30, 0x75, 0xd0, 0x8a])
        try parsed.applyPCM16LittleEndian(to: &pcm)
        XCTAssertEqual(pcm, Data([0x69, 0xff, 0x4b, 0x00, 0xff, 0x7f, 0x1c, 0xa8]))
        XCTAssertThrowsError(try StreamVolumeFilterCandidate(researchFilterText: "volume,vol:200\\reverb"))
        XCTAssertThrowsError(try StreamVolumeFilterCandidate(researchFilterText: "volume,vol:10,vol:20"))
    }

    func testTextPreviewAppliesBoundedLineBreakCandidate() throws {
        let run = ScriptMachine.MessageTextLayer.Run(text: "甲乙丙（", width: 20, height: 20,
            ruby: nil, colorARGB: 0xffff_ffff, fontName: nil)
        var layer = ScriptMachine.MessageTextLayer(id: 1, runs: [run],
            canvasBounds: [0, 0, 100, 80], surfaceMargins: [0, 0], x: 0, y: 0,
            scaleXPercent: 100, scaleYPercent: 100, isVisible: true, priority: 0)
        layer.lineBreakCandidate = .init(reserve: 1, prohibitedLineStart: "、", prohibitedLineEnd: "（")
        let constrained = try ResourceImage.textPreview(layer, width: 100, height: 80)
        XCTAssertTrue(constrained.notes.contains("line_break_candidate:1"))
        layer.lineBreakCandidate = .init(reserve: 1, prohibitedLineStart: "、", prohibitedLineEnd: "")
        let plain = try ResourceImage.textPreview(layer, width: 100, height: 80)
        XCTAssertTrue(plain.notes.contains("line_break_candidate:0"))
        let black = SIMD4<UInt8>(0, 0, 0, 255)
        var constrainedCanvas = Array(repeating: Array(repeating: black, count: 100), count: 80)
        var plainCanvas = constrainedCanvas
        try constrained.drawRasterPreview(origin: .zero, opacity: 255, canvas: &constrainedCanvas)
        try plain.drawRasterPreview(origin: .zero, opacity: 255, canvas: &plainCanvas)
        XCTAssertNotEqual(constrainedCanvas, plainCanvas)

        let prefix = ScriptMachine.MessageTextLayer.Run(text: "甲乙", width: 20, height: 20,
            ruby: nil, colorARGB: 0xffff_ffff, fontName: nil)
        let indent = ScriptMachine.MessageTextLayer.Run(text: "", width: 20, height: 20,
            ruby: nil, colorARGB: 0xffff_ffff, fontName: nil, horizontalAdvance: 20)
        let annotation = ScriptMachine.MessageTextLayer.Ruby(text: "かな", fontName: nil,
                                                             width: nil, height: nil, colorARGB: nil)
        let ruby = ScriptMachine.MessageTextLayer.Run(text: "丙丁", width: 20, height: 20,
            ruby: annotation, colorARGB: 0xffff_ffff, fontName: nil)
        layer = ScriptMachine.MessageTextLayer(id: 1, runs: [prefix, indent, ruby],
            lineBreakCandidate: .init(reserve: 1, prohibitedLineStart: "", prohibitedLineEnd: ""),
            canvasBounds: [0, 0, 65, 80], surfaceMargins: [0, 0], x: 0, y: 0,
            scaleXPercent: 100, scaleYPercent: 100, isVisible: true, priority: 0)
        let rubyRaster = try ResourceImage.textPreview(layer, width: 65, height: 80)
        XCTAssertTrue(rubyRaster.notes.contains("line_break_candidate:1"))
    }

    func testTextPreviewRendersFractionallyScaledAndMirroredSurface() throws {
        let run = ScriptMachine.MessageTextLayer.Run(text: "試", width: 24, height: 24,
            ruby: nil, colorARGB: 0xffff_ffff, fontName: nil)
        let layer = ScriptMachine.MessageTextLayer(id: 1, runs: [run],
            canvasBounds: [0, 0, 81, 41], surfaceMargins: [0, 0], x: 0, y: 0,
            scaleXPercent: -150, scaleYPercent: 75, isVisible: true, priority: 0)
        let image = try ResourceImage.textPreview(layer, width: 81, height: 41)
        XCTAssertEqual(image.image.width, 122)
        XCTAssertEqual(image.image.height, 31)
        let black = SIMD4<UInt8>(0, 0, 0, 255)
        var canvas = Array(repeating: Array(repeating: black, count: 122), count: 31)
        try image.drawRasterPreview(origin: .zero, opacity: 255, canvas: &canvas)
        XCTAssertTrue(canvas.contains { $0.suffix(60).contains { $0 != black } })
        XCTAssertFalse(canvas.contains { $0.prefix(60).contains { $0 != black } })
        let missing = ScriptMachine.MessageTextLayer.Run(text: "\u{10ffff}", width: 24, height: 24,
            ruby: nil, colorARGB: 0xffff_ffff, fontName: nil)
        let missingLayer = ScriptMachine.MessageTextLayer(id: 2, runs: [missing],
            canvasBounds: [0, 0, 81, 41], surfaceMargins: [0, 0], x: 0, y: 0,
            scaleXPercent: 100, scaleYPercent: 100, isVisible: true, priority: 0)
        let missingRaster = try ResourceImage.textPreview(missingLayer, width: 81, height: 41)
        XCTAssertTrue(missingRaster.notes.contains("missing_glyphs:1"))
        let longRun = ScriptMachine.MessageTextLayer.Run(text: String(repeating: "A", count: 80), width: 24, height: 24,
            ruby: nil, colorARGB: 0xffff_ffff, fontName: nil)
        let clipped = ScriptMachine.MessageTextLayer(id: 3, runs: [longRun],
            canvasBounds: [0, 0, 40, 24], surfaceMargins: [0, 0], x: 0, y: 0,
            scaleXPercent: 100, scaleYPercent: 100, isVisible: true, priority: 0)
        XCTAssertTrue(try ResourceImage.textPreview(clipped, width: 40, height: 24).notes.contains("text_truncated"))
        XCTAssertTrue(image.notes.contains("text_complete"))
    }

    func testTheoraHeaderAcceptsNonzeroDataSliceIndex() throws {
        var page = Data("OggS".utf8) + Data(repeating: 0, count: 23)
        page[5] = 2
        page[26] = 1
        page.append(42)
        var packet = Data([0x80]) + Data("theora".utf8) + Data(repeating: 0, count: 35)
        packet[15] = 5
        packet[18] = 2
        packet[19] = 208
        page.append(packet)
        let container = Data(repeating: 0, count: 385) + page
        let embedded = container.dropFirst(385)
        XCTAssertEqual(embedded.startIndex, 385)
        let (width, height) = try ScriptMovieHeader.theoraDimensions(embedded)
        XCTAssertEqual(width, 1280)
        XCTAssertEqual(height, 720)
        XCTAssertThrowsError(try ScriptMovieHeader.theoraDimensions(embedded.dropLast()))

        try temporary { directory in
            let reference = ScriptModuleReference(logicalPath: "ending.ogv", sourceFile: "ending.ogv",
                                                  sourceSHA256: page.sha256Hex)
            try page.write(to: directory.appendingPathComponent(reference.sourceFile))
            let root = ScriptModuleReference(logicalPath: "root.s", sourceFile: "root.s",
                                             sourceSHA256: page.sha256Hex)
            let catalog = try ScriptModuleCatalog(entries: [root], indexedResourceNames: [reference.logicalPath])
            var repository = try ScriptRepository(directory: SafeDirectory(directory), catalog: catalog) { _ in reference }
            let movie = try repository.movieLocation(reference.logicalPath)
            XCTAssertEqual(movie.location.sourceSHA256, reference.sourceSHA256)
            XCTAssertEqual(movie.size.0, 1280)
            XCTAssertEqual(movie.size.1, 720)
        }
    }

    func testSimplifiedChineseScriptMessageProducesRasterCoverage() throws {
        let text = #"""
        \gvar,msg,sample
        \scp,sample
        \ts,0,0,240,80
        \p,0,0,1
        \e
        \o,"林晓：这边走。[n]请跟上！"
        \if,1\then
        \stop,@@!Resume
        \end
        @@!Resume
        \ret
        """#
        let bytes = Data([0xff, 0xfe]) + Data(text.utf16.flatMap {
            [UInt8(truncatingIfNeeded: $0), UInt8($0 >> 8)]
        })
        let document = try ScriptDocument(data: bytes, relativePath: "synthetic.s")
        var machine = try ScriptMachine(program: ScriptProgram(document), allowExperimental: true)
        try machine.run(stepQuota: 100)
        XCTAssertTrue(try machine.commitHeadlessMessageOutput())
        let layer = try XCTUnwrap(machine.messageTextLayers.first)
        XCTAssertTrue(layer.isVisible)
        XCTAssertEqual(layer.runs.map(\.text).joined(), "林晓：这边走。\n请跟上！")
        let raster = try ResourceImage.textPreview(layer, width: 240, height: 80)
        let black = SIMD4<UInt8>(0, 0, 0, 255)
        var canvas = Array(repeating: Array(repeating: black, count: 240), count: 80)
        XCTAssertTrue(try raster.drawRasterPreview(origin: .zero, opacity: 255, canvas: &canvas))
    }

    func testTextLayerReportsUnappliedLayoutDirectives() throws {
        let text = #"""
        \gvar,msg,sample
        \scp,sample
        \ts,0,0,240,80
        \p,0,0,1
        \e
        \o,"A[pi,1,2]B[rpi,3,4]C[rp,5,6]D[i,-2]E[pi,7,8]F"
        \if,1\then
        \stop,@@!Resume
        \end
        @@!Resume
        \ret
        """#
        let bytes = Data([0xff, 0xfe]) + Data(text.utf16.flatMap {
            [UInt8(truncatingIfNeeded: $0), UInt8($0 >> 8)]
        })
        let document = try ScriptDocument(data: bytes, relativePath: "synthetic.s")
        var machine = try ScriptMachine(program: ScriptProgram(document), allowExperimental: true)
        try machine.run(stepQuota: 100)
        XCTAssertTrue(try machine.commitHeadlessMessageOutput())
        let layer = try XCTUnwrap(machine.messageTextLayers.first)
        XCTAssertEqual(layer.text, "ABCDEF")
        XCTAssertEqual(layer.runs.map(\.estimatedTracking), [0, 1, 1, 1, 1, 7])
        XCTAssertEqual(layer.unhandledDirectives, ["i", "pi", "rp", "rpi"])
        let tracked = try ResourceImage.textPreview(layer, width: 240, height: 80)
        let untracked = ScriptMachine.MessageTextLayer(id: layer.id, runs: layer.runs.map { run in
            var copy = run
            copy.estimatedTracking = 0
            return copy
        }, unhandledDirectives: layer.unhandledDirectives, canvasBounds: layer.canvasBounds,
           surfaceMargins: layer.surfaceMargins, x: layer.x, y: layer.y,
           scaleXPercent: layer.scaleXPercent, scaleYPercent: layer.scaleYPercent,
           isVisible: layer.isVisible, priority: layer.priority)
        let plain = try ResourceImage.textPreview(untracked, width: 240, height: 80)
        let black = SIMD4<UInt8>(0, 0, 0, 255)
        var trackedCanvas = Array(repeating: Array(repeating: black, count: 240), count: 80)
        var plainCanvas = trackedCanvas
        try tracked.drawRasterPreview(origin: .zero, opacity: 255, canvas: &trackedCanvas)
        try plain.drawRasterPreview(origin: .zero, opacity: 255, canvas: &plainCanvas)
        XCTAssertNotEqual(trackedCanvas, plainCanvas)
    }

    func testPositiveLineAdvanceReportsPreviewIncomplete() throws {
        let text = #"""
        \gvar,msg,sample
        \scp,sample
        \ts,0,0,240,80
        \p,0,0,1
        \e
        \o,"A[n,6]B"
        \if,1\then
        \stop,@@!Resume
        \end
        @@!Resume
        \ret
        """#
        let bytes = Data([0xff, 0xfe]) + Data(text.utf16.flatMap {
            [UInt8(truncatingIfNeeded: $0), UInt8($0 >> 8)]
        })
        let document = try ScriptDocument(data: bytes, relativePath: "synthetic.s")
        var machine = try ScriptMachine(program: ScriptProgram(document), allowExperimental: true)
        try machine.run(stepQuota: 100)
        XCTAssertTrue(try machine.commitHeadlessMessageOutput())
        let layer = try XCTUnwrap(machine.messageTextLayers.first)
        XCTAssertEqual(layer.text, "A\nB")
        XCTAssertEqual(layer.unhandledDirectives, ["n"])
    }

    func testSimplifiedChineseChoiceLabelsFitTheButton() throws {
        let style = ScriptMachine.ChoiceTextStyle(fontName: "SimHei", height: 24, colorARGB: 0xffff_ffff)
        let black = SIMD4<UInt8>(0, 0, 0, 255)
        let rasters = try ["继续调查", "返回房间"].map { label in
            let raster = try ResourceImage.choiceLabelPreview(label, style: style, width: 128, height: 40)
            var canvas = Array(repeating: Array(repeating: black, count: 128), count: 40)
            XCTAssertTrue(try raster.drawRasterPreview(origin: .zero, opacity: 255, canvas: &canvas))
            XCTAssertTrue(canvas.allSatisfy { $0.first == black && $0.last == black })
            return canvas
        }
        XCTAssertNotEqual(rasters[0], rasters[1])
    }

    func testRasterPreviewMirrorsBothAxesBeforeClipping() throws {
        let source = try ResourceImage.decode(png([
            255, 0, 0, 255, 0, 255, 0, 255,
            0, 0, 255, 255, 255, 255, 255, 255
        ], width: 2, height: 2))
        let black = SIMD4<UInt8>(0, 0, 0, 255)
        var original = Array(repeating: Array(repeating: black, count: 2), count: 2)
        try source.drawRasterPreview(origin: .zero, opacity: 255, canvas: &original)
        var clipped = Array(repeating: [black], count: 2)
        try source.drawRasterPreview(origin: SIMD2(-1, 0), opacity: 255,
                                     flipX: true, flipY: true, canvas: &clipped)
        XCTAssertEqual(clipped, [[original[1][0]], [original[0][0]]])
    }

    func testTwoTexturePixelUsesOnlyLowSecondaryByteAndWrapsWordProducts() {
        let source = SIMD4<UInt8>(1, 200, 255, 255)
        let result = TwoTexturePixel.evaluate(source: source, secondaryLowByte: 128,
            maskWords: SIMD4(255, 256, 0, 0), weights: SIMD4(128, 128, 255, 128))
        // The third lane multiplies -255 by 255 in a signed 16-bit slot,
        // wrapping to 511 before the arithmetic shift.
        XCTAssertEqual(result, SIMD4<Int16>(0, 200, 258, 127))
        XCTAssertEqual(TwoTexturePixel.nearestSample(source: SIMD4(32, 64, 128, 255),
            secondaryLowByte: 128, packedWeights: TwoTexturePixel.command4Weights(256)), SIMD4<Int16>(31, 63, 127, 127))
        XCTAssertEqual(TwoTexturePixel.command4Weights(255), 0x7f808080)
        XCTAssertEqual(TwoTexturePixel.command4Weights(512), 0x00808080)
    }

    func testCommand3ThresholdAndPackedMaskCandidate() throws {
        let start = try XCTUnwrap(TwoTexturePixel.command3Threshold(value: 0, rawMode: 0))
        let end = try XCTUnwrap(TwoTexturePixel.command3Threshold(value: 255, rawMode: 0))
        XCTAssertEqual(start.threshold, 255)
        XCTAssertEqual(end.threshold, -256)
        XCTAssertEqual(TwoTexturePixel.command3Mask(sample: 128, threshold: start.threshold, gain: start.gain, inverted: false), 0)
        XCTAssertEqual(TwoTexturePixel.command3Mask(sample: 128, threshold: end.threshold, gain: end.gain, inverted: false), 255)
        let middle = try XCTUnwrap(TwoTexturePixel.command3Threshold(value: 128, rawMode: 0x87))
        XCTAssertEqual(middle.threshold, 125)
        XCTAssertEqual(middle.gain, 128)
        XCTAssertTrue(middle.inverted)
        XCTAssertEqual(TwoTexturePixel.command3Mask(sample: 130, threshold: middle.threshold, gain: middle.gain, inverted: true), 0)
        XCTAssertNil(TwoTexturePixel.command3Threshold(value: 256, rawMode: 0))
        let json = #"{"time":0,"type":10,"offset":12,"dual_texture_raw_inputs":{"layout":"ablayer18","output_b1":2,"output_ac":3,"output_b2":4,"key_c8":-5,"key_cc":6}}"#
        let key = try JSONDecoder().decode(ScriptImageRecipe.MotionKey.self, from: Data(json.utf8))
        XCTAssertEqual(key.dual_texture_raw_inputs?.key_c8, -5)
        XCTAssertEqual(key.dual_texture_raw_inputs?.output_b2, 4)
        let container = Data("fixture".utf8)
        let recipeData = """
        [{"container_sha256":"\(container.sha256Hex)","offset":0,"length":7,"sha256":"\(container.sha256Hex)",
          "motion_timelines":{"0":[[
            {"time":0,"type":10,"offset":0,"opacity_mode_input":1,"dual_texture_raw_inputs":{"layout":"ablayer18","output_b1":0,"output_ac":0,"output_b2":0,"key_c8":0,"key_cc":4}},
            {"time":1000,"type":4,"offset":1,"opacity_mode_input":0,"dual_texture_raw_inputs":{"layout":"ablayer18","output_b1":0,"output_ac":0,"output_b2":0,"key_c8":255,"key_cc":0}}
          ]]}}]
        """
        let recipe = try JSONDecoder().decode(ScriptImageRecipe.self, from: Data(recipeData.utf8))
        let location = ScriptModuleReference(logicalPath: "fixture.b", sourceFile: "fixture.b", sourceSHA256: container.sha256Hex)
            .wholeFileLocation(byteLength: container.count)
        let sampled = try XCTUnwrap(recipe.motionKeys(location, selectedMember: 0, time: 500)?.first)
        XCTAssertEqual(sampled.sampledDualTransferValue, 128)
    }

    func testTwoTextureRowSamplesIndependentFixedPointPositions() {
        let first = Array(repeating: SIMD4<UInt8>(32, 64, 128, 255), count: 2)
        let second = [SIMD4<UInt8>(0, 255, 255, 255), SIMD4<UInt8>(255, 0, 0, 0)]
        let row = TwoTexturePixel.sampleRow(first: first, second: second,
            start: SIMD2(0, TwoTexturePixel.fixedPointCoordinate(1.5)!),
            step: SIMD2(0x10000, TwoTexturePixel.fixedPointCoordinate(-1)!),
            count: 2, packedWeights: 0x80808080)
        XCTAssertEqual(TwoTexturePixel.fixedPointCoordinate(1.1), 72_090)
        XCTAssertNil(TwoTexturePixel.fixedPointCoordinate(.infinity))
        XCTAssertEqual(row, [SIMD4<Int16>(31, 63, 127, 254), SIMD4<Int16>(31, 63, 127, 0)])
        XCTAssertNil(TwoTexturePixel.sampleRow(first: first, second: second, start: SIMD2(-1, 0),
            step: .zero, count: 1, packedWeights: 0x80808080))
    }

    func testTwoTextureDrawRowWritesOnlyAfterAllSamplesAreValid() {
        let first = [SIMD4<UInt8>(32, 64, 128, 255)]
        let second = [SIMD4<UInt8>(255, 0, 0, 0), SIMD4<UInt8>(0, 0, 0, 0)]
        var target = Array(repeating: SIMD4<UInt8>(10, 20, 30, 255), count: 2)
        let original = target
        XCTAssertFalse(TwoTexturePixel.drawRow(first: first, second: second, start: .zero,
            step: SIMD2(0x10000, 0x10000), packedWeights: 0x80808080, multiplier: SIMD4(repeating: 128),
            additive: .zero, target: &target))
        XCTAssertEqual(target, original)
        XCTAssertTrue(TwoTexturePixel.drawRow(first: first, second: second, start: .zero,
            step: SIMD2(0, 0x10000), packedWeights: 0x80808080, multiplier: SIMD4(repeating: 128),
            additive: .zero, target: &target))
        XCTAssertEqual(target, [SIMD4<UInt8>(30, 62, 126, 254), original[1]])
    }

    func testTwoTextureDrawRectangleUsesIndependentSourceRows() {
        let first = [[SIMD4<UInt8>(32, 64, 128, 255)]]
        let second = [[SIMD4<UInt8>(0, 0, 0, 0)], [SIMD4<UInt8>(255, 0, 0, 0)]]
        let original = [[SIMD4<UInt8>(10, 20, 30, 255)], [SIMD4<UInt8>(10, 20, 30, 255)]]
        var target = original
        XCTAssertFalse(TwoTexturePixel.drawRectangle(first: first, second: second, startX: .zero, stepX: .zero,
            startY: .zero, stepY: SIMD2(0x10000, 0x10000), packedWeights: 0x80808080,
            multiplier: SIMD4(repeating: 128), additive: .zero, target: &target))
        XCTAssertEqual(target, original)
        XCTAssertTrue(TwoTexturePixel.drawRectangle(first: first, second: second, startX: .zero, stepX: .zero,
            startY: .zero, stepY: SIMD2(0, 0x10000), packedWeights: 0x80808080,
            multiplier: SIMD4(repeating: 128), additive: .zero, target: &target))
        XCTAssertEqual(target, [original[0], [SIMD4(30, 62, 126, 254)]])
    }

    func testFullTwoTextureDrawResamplesDifferentSurfaceSizes() {
        let color = SIMD4<UInt8>(32, 64, 128, 255)
        let zero = SIMD4<UInt8>.zero
        let mask = SIMD4<UInt8>(255, 0, 0, 0)
        let original = SIMD4<UInt8>(10, 20, 30, 255)
        var target = Array(repeating: [original, original], count: 2)
        XCTAssertTrue(TwoTexturePixel.drawFullTextures(first: [[color]], second: [
            [mask, zero, mask, zero], [zero, zero, zero, zero],
            [zero, zero, mask, zero], [zero, zero, zero, zero],
        ], packedWeights: 0x80808080, multiplier: SIMD4(repeating: 128), additive: .zero, target: &target))
        let drawn = SIMD4<UInt8>(30, 62, 126, 254)
        XCTAssertEqual(target, [[drawn, drawn], [original, drawn]])
        var clipped = [[original]]
        XCTAssertTrue(TwoTexturePixel.drawFullTextures(first: [[color]], second: [
            [mask, zero, mask, zero], [zero, zero, zero, zero],
            [zero, zero, mask, zero], [zero, zero, zero, zero],
        ], fullSize: SIMD2(2, 2), clippedOrigin: SIMD2(1, 1), packedWeights: 0x80808080,
            multiplier: SIMD4(repeating: 128), additive: .zero, target: &clipped))
        XCTAssertEqual(clipped, [[target[1][1]]])
    }

    func testTwoTextureDefaultBlendUsesSourceHighLane() {
        let target = SIMD4<UInt8>(100, 80, 60, 40)
        let colors = TwoTexturePixel.scannerColors(additiveRGB: 0xff030201,
            multiplierRGB: 0x00ff807f, multiplierAlpha: 0x80)
        XCTAssertEqual(colors.additive, SIMD4(1, 2, 3, 0))
        XCTAssertEqual(colors.multiplier, SIMD4(63, 65, 128, 65))
        XCTAssertEqual(TwoTexturePixel.blendOntoTarget(source: SIMD4(20, 120, 60, 0), target: target), target)
        XCTAssertEqual(TwoTexturePixel.blendOntoTarget(source: SIMD4(20, 120, 60, 127), target: target),
                       SIMD4(60, 100, 60, 83))
        XCTAssertEqual(TwoTexturePixel.blendOntoTarget(source: SIMD4(20, 120, 60, 255), target: target),
                       SIMD4(20, 120, 60, 255))
        XCTAssertEqual(TwoTexturePixel.blendOntoTarget(source: SIMD4(300, 120, 60, 255), target: target,
            multiplier: SIMD4(64, 128, 128, 128), additive: SIMD4(10, 0, 0, 0)), SIMD4(160, 120, 60, 255))
    }

    func testTwoTextureGeometryDistinguishesAlignedScaledAndSkewedInputs() {
        let target = TwoTextureScanQuad(x: SIMD4(0, 160, 160, 0), y: SIMD4(0, 0, 90, 90))
        let shifted = TwoTextureScanQuad(x: SIMD4(8, 168, 168, 8), y: SIMD4(8, 8, 98, 98))
        let scaled = TwoTextureScanQuad(x: SIMD4(0, 176, 176, 0), y: SIMD4(0, 0, 106, 106))
        let skewed = TwoTextureScanQuad(x: SIMD4(0, 160, 161, 1), y: SIMD4(0, 0, 90, 90))
        XCTAssertEqual(TwoTextureScanQuad.selector(target: target, first: target, second: shifted), 0)
        XCTAssertEqual(TwoTextureScanQuad.selector(target: target, first: target, second: scaled), 1)
        XCTAssertEqual(TwoTextureScanQuad.selector(target: target, first: target, second: skewed), 2)
    }

    private func temporary(_ body: (URL) throws -> Void) throws {
        // Foundation keeps the /var alias on this host. Own fixtures use the package build tree;
        // production O_NOFOLLOW checks remain strict, including aliases in parent components.
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = base.appendingPathComponent(".build/owned-fixtures/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }
    private func le(_ values: [UInt32]) -> Data {
        Data(values.flatMap { v in (0..<4).map { UInt8(truncatingIfNeeded: v >> ($0 * 8)) } })
    }
    private func footer(_ version: String = "FilePackVer3.1", count: UInt32 = 2, offset: UInt32 = 16) -> Data {
        var result = Data(version.utf8); result.append(contentsOf: repeatElement(0, count: 16 - result.count))
        result.append(le([count,offset,0])); return result
    }
    private func png(_ rgba: [UInt8], width: Int = 1, height: Int = 1) throws -> Data {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(rgba) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination)); return output as Data
    }
    private func dpng(_ tiles: [(UInt32,UInt32,UInt32,UInt32,Data,UInt32)], width: UInt32 = 2, height: UInt32 = 1) -> Data {
        var data = Data("DPNG".utf8); data.append(le([1,UInt32(tiles.count),width,height]))
        for (x,y,w,h,payload,flag) in tiles {
            data.append(le([x,y,w,h,UInt32(payload.count),flag,0])); data.append(payload)
        }
        return data
    }
    private func rgba(_ image: CGImage) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setBlendMode(.copy); context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let memory = try XCTUnwrap(context.data)
        return Array(UnsafeBufferPointer(start: memory.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }

    func testPackFooterIsMetadataOnlyForAllSupportedVersions() throws {
        for version in ["FilePackVer1.0","FilePackVer2.0","FilePackVer3.0","FilePackVer3.1"] {
            let result = try PackFooter.probe(footer(version), fileSize: 100)
            XCTAssertEqual(result.version, version); XCTAssertEqual(result.declaredEntries, 2)
            XCTAssertEqual(result.indexStatus, .notTested)
        }
    }
    func testPackRejectsMalformedCountsOffsetsAndUnknownVersions() {
        for data in [Data(), footer("FilePackVer9.9"), footer(count: 100001), footer(offset: 72), footer(offset: .max)] {
            XCTAssertThrowsError(try PackFooter.probe(data, fileSize: 100))
        }
    }
    func testSignatureDoesNotDependOnExtensionAndNeverRunsExecutable() throws {
        try temporary { root in
            try Data("MZowned-not-a-program".utf8).write(to: root.appendingPathComponent("owned.exe"))
            try png([255,0,0,255]).write(to: root.appendingPathComponent("wrong.bin"))
            let result = try InventoryScanner().scan(SafeDirectory(root))
            XCTAssertEqual(result.files.map(\.format), ["PE-candidate","PNG"])
            XCTAssertEqual(result.gameExecution, .notTested); XCTAssertFalse(result.originalFilesWritten)
        }
    }
    func testScannerRefusesSymlinksAndRetainsIssuesAndUnknowns() throws {
        try temporary { root in
            try Data([1,2,3]).write(to: root.appendingPathComponent("owned.bin"))
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: root.appendingPathComponent("owned.bin"))
            let result = try InventoryScanner().scan(SafeDirectory(root))
            XCTAssertEqual(result.files.count, 1); XCTAssertEqual(result.files[0].status, .unsupported)
            XCTAssertEqual(result.issues, ["alias: symlink_refused"])
            XCTAssertThrowsError(try SafeDirectory(root).read("alias"))
        }
    }
    func testSymlinkParentRootAndTraversalAreRejected() throws {
        for relative in ["../x","/x","a//b","a/./b","a\\b","C:x","a\0b"] {
            XCTAssertThrowsError(try SafeDirectory.components(relative))
        }
        try temporary { root in
            let actual = root.appendingPathComponent("actual"), alias = root.appendingPathComponent("alias")
            try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
            XCTAssertThrowsError(try SafeDirectory(alias))
            XCTAssertThrowsError(try SafeDirectory(alias.appendingPathComponent("nested")))
        }
    }
    func testScannerDepthCountAndReadLimitsAreExplicit() throws {
        try temporary { root in
            try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: false)
            try Data([1,2]).write(to: root.appendingPathComponent("owned.bin"))
            let dir = try SafeDirectory(root)
            let result = try InventoryScanner(maximumDepth: 0).scan(dir)
            XCTAssertTrue(result.issues.contains("nested: directory_depth_limit"))
            XCTAssertThrowsError(try InventoryScanner(maximumFiles: 1).scan(dir))
            XCTAssertThrowsError(try dir.read("owned.bin", limit: 1))
            XCTAssertEqual(try dir.read("owned.bin"), Data([1,2]))
        }
    }
    func testAtomicResearchOutputDoesNotReplaceFilesOrLinks() throws {
        try temporary { root in
            let directory = try SafeDirectory(root)
            let contents = Data(repeating: 0x5a, count: 2 * 1024 * 1024)
            try directory.writeNewAtomically("state.json", data: contents)
            XCTAssertEqual(try directory.read("state.json"), contents)
            XCTAssertThrowsError(try directory.writeNewAtomically("state.json", data: Data([1])))
            let link = root.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("state.json"))
            XCTAssertThrowsError(try directory.writeNewAtomically("alias", data: Data([2])))
            XCTAssertEqual(try directory.read("state.json"), contents)
            XCTAssertFalse(try directory.entries().contains { $0.name.hasPrefix(".mangekyou-stage-") })
        }
    }
    func testInvalidPackIsReportedAndDoesNotDisappear() throws {
        try temporary { root in
            try Data([1,2,3]).write(to: root.appendingPathComponent("owned.pack"))
            let result = try InventoryScanner().scan(SafeDirectory(root))
            XCTAssertEqual(result.files.count, 1); XCTAssertEqual(result.files[0].status, .unsupported)
            XCTAssertEqual(result.issues.count, 1)
        }
    }
    func testMovieHashChecksCancellationBeforeReading() async {
        let cancelledBeforeRead = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try SafeDirectory.movieSHA256(fd: -1, size: 1)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }.value
        XCTAssertTrue(cancelledBeforeRead)
    }

    func testBMPDecodesPixelsBySignature() throws {
        var bmp = Data("BM".utf8)
        bmp.append(le([58, 0, 54, 40, 1, 1, 0x0018_0001, 0, 4, 0, 0, 0, 0]))
        bmp.append(contentsOf: [0, 0, 255, 0])
        let decoded = try ResourceImage.decode(bmp)
        XCTAssertEqual(decoded.format, "BMP")
        XCTAssertEqual(try rgba(decoded.image), [255, 0, 0, 255])
    }

    func testABMPScopedOpacityUsesActiveStateAtEachSample() throws {
        let data = Data("fixture".utf8)
        let location = ScriptLocation(sourceFile: "fixture.b", sourceSHA256: data.sha256Hex,
                                      byteOffset: 0, byteLength: data.count, rangeSHA256: data.sha256Hex, lineNumber: 1)
        let receipt = """
        [{"container_sha256":"\(data.sha256Hex)","offset":0,"length":\(data.count),"sha256":"\(data.sha256Hex)",
          "motion_timelines":{"0":[
            [{"time":0,"type":16,"offset":0,"literal_opacity_input":0,"opacity_mode_input":1},
             {"time":250,"type":16,"offset":1,"literal_opacity_input":255,"opacity_mode_input":0}],
            [{"time":0,"type":4,"offset":2,"literal_opacity_input":255,"opacity_mode_input":0}],
            [{"time":0,"type":17,"offset":3}],
            [{"time":250,"type":0,"offset":4}]]}}]
        """
        let recipe = try JSONDecoder().decode(ScriptImageRecipe.self, from: Data(receipt.utf8))
        for (time, expected): (Int32, UInt8) in [(0, 0), (125, 128), (250, 255), (300, 255)] {
            let keys = try XCTUnwrap(recipe.motionKeys(location, selectedMember: 0, time: time))
            XCTAssertEqual(keys.map(\.type), time < 250 ? [16, 4, 17] : [16, 4, 17, 0])
            let draws = try XCTUnwrap(recipe.scopedTextureKeys(keys))
            XCTAssertEqual(draws.count, 1)
            let draw = try XCTUnwrap(draws.first)
            XCTAssertEqual(recipe.composedOpacity(texture: draw.texture, states: draw.states), expected)
        }
        var savedTimes = [Int32](repeating: 0, count: 256)
        savedTimes[0] = 125
        savedTimes[3] = 250
        let savedKeys = try XCTUnwrap(recipe.motionKeysAtSavedLayerTimesCandidate(location, selectedMember: 0,
                                                                                 layerTimes: savedTimes))
        XCTAssertEqual(savedKeys.map(\.type), [16, 4, 17, 0])
        let savedDraw = try XCTUnwrap(recipe.scopedTextureKeys(savedKeys)?.first)
        XCTAssertEqual(recipe.composedOpacity(texture: savedDraw.texture, states: savedDraw.states), 128)
        XCTAssertNil(recipe.motionKeysAtSavedLayerTimesCandidate(location, selectedMember: 0,
                                                                 layerTimes: Array(savedTimes.dropLast())))
        savedTimes[255] = -1
        XCTAssertNil(recipe.motionKeysAtSavedLayerTimesCandidate(location, selectedMember: 0, layerTimes: savedTimes))
    }

    func testSavedLayerAdvanceCandidateStopsAtUnknownBoundaries() throws {
        let data = Data("saved layer advance fixture".utf8)
        let hash = data.sha256Hex
        let location = ScriptLocation(sourceFile: "fixture.b", sourceSHA256: hash,
            byteOffset: 0, byteLength: data.count, rangeSHA256: hash, lineNumber: 1)
        let receipt = """
        [{"container_sha256":"\(hash)","offset":0,"length":\(data.count),"sha256":"\(hash)",
          "motion_timelines":{"0":[
            [{"time":0,"type":4,"offset":10,"time_control_inputs":[0,0,0,0]},
             {"time":200,"type":4,"offset":11,"time_control_inputs":[0,0,0,0]}],
            [{"time":0,"type":4,"offset":20,"time_control_inputs":[0,0,0,0]},
             {"time":100,"type":4,"offset":21,"time_control_inputs":[0,0,0,0]},
             {"time":150,"type":4,"offset":22,"time_control_inputs":[1,0,0,0]},
             {"time":200,"type":4,"offset":23,"time_control_inputs":[0,0,0,0]}]]}}]
        """
        let recipe = try JSONDecoder().decode(ScriptImageRecipe.self, from: Data(receipt.utf8))
        var times = [Int32](repeating: 0, count: 256)
        var aux = times
        times[0] = 10; times[1] = 20; aux[0] = 80; aux[1] = 20
        let result = try XCTUnwrap(recipe.advanceSavedLayerTimesCandidate(location, selectedMember: 0,
            layerTimes: times, auxiliary: aux, delta: 50))
        XCTAssertEqual(Array(result.times.prefix(2)), [10, 50])
        XCTAssertEqual(Array(result.auxiliary.prefix(2)), [30, 0])
        XCTAssertEqual(result.keys.map(\.offset), [10, 20])
        let crossed = try XCTUnwrap(recipe.advanceSavedLayerTimesCandidate(location, selectedMember: 0,
            layerTimes: times, auxiliary: aux, delta: 100))
        XCTAssertEqual(Array(crossed.times.prefix(2)), [30, 100])
        XCTAssertEqual(crossed.keys.map(\.offset), [10, 21])
        let looped = try XCTUnwrap(recipe.advanceSavedLayerTimesCandidate(location, selectedMember: 0,
            layerTimes: times, auxiliary: aux, delta: 150))
        XCTAssertEqual(Array(looped.times.prefix(2)), [80, 0])
        XCTAssertEqual(looped.keys.map(\.offset), [10, 20])
        let excess = try XCTUnwrap(recipe.advanceSavedLayerTimesCandidate(location, selectedMember: 0,
            layerTimes: times, auxiliary: aux, delta: 160))
        XCTAssertEqual(Array(excess.times.prefix(2)), [90, 10])
        let variableReceipt = receipt.replacingOccurrences(of: "[1,0,0,0]", with: "[1,0,1,0]")
        let variableRecipe = try JSONDecoder().decode(ScriptImageRecipe.self, from: Data(variableReceipt.utf8))
        XCTAssertNil(variableRecipe.advanceSavedLayerTimesCandidate(location, selectedMember: 0,
            layerTimes: times, auxiliary: aux, delta: 150))
        XCTAssertNil(recipe.advanceSavedLayerTimesCandidate(location, selectedMember: 0,
            layerTimes: times, auxiliary: aux, delta: 250))
        aux[255] = -1
        XCTAssertNil(recipe.advanceSavedLayerTimesCandidate(location, selectedMember: 0,
            layerTimes: times, auxiliary: aux, delta: 50))
    }

    func testSourceRectangleSamplesFractionalTimeAndRejectsUnknownMode() throws {
        let digest = Data("synthetic source rectangle".utf8).sha256Hex
        let location = ScriptLocation(sourceFile: "fixture.b", sourceSHA256: digest,
                                      byteOffset: 0, byteLength: 5, rangeSHA256: digest, lineNumber: 1)
        let receipt = """
        [{"container_sha256":"\(digest)","offset":0,"length":5,"sha256":"\(digest)",
          "motion_timelines":{"0":[[
            {"time":0,"type":4,"offset":0,"source_areas":[[0,0,0,15]],
             "source_area_mode_input":1,"source_area_interpolation_flag":true},
            {"time":1000,"type":4,"offset":1,"source_areas":[[0,0,400,16]],
             "source_area_mode_input":5,"source_area_interpolation_flag":false}]]}}]
        """
        let recipe = try JSONDecoder().decode(ScriptImageRecipe.self, from: Data(receipt.utf8))
        let sampled = try XCTUnwrap(recipe.motionKeysAtFractionalTime(location, selectedMember: 0, time: 500.5)?.first)
        let area = try XCTUnwrap(sampled.sampledFirstSourceArea)
        XCTAssertEqual(area[2], 200.2, accuracy: 0.001)
        XCTAssertEqual(area[3], 15.5005, accuracy: 0.001)
        XCTAssertNil(recipe.motionKeysAtFractionalTime(location, selectedMember: 0, time: 1000)?.first?.sampledFirstSourceArea)
        XCTAssertNil(recipe.motionKeysAtFractionalTime(location, selectedMember: 0, time: .infinity))
    }

    func testScreenTexturePreviewSamplesUnscaledSourceArea() throws {
        let payload = try png([255, 0, 0, 128, 0, 255, 0, 255], width: 2, height: 1)
        let container = Data("abmp12".utf8) + payload, digest = container.sha256Hex
        let receipt = """
        [{"container_sha256":"\(digest)","offset":6,"length":\(payload.count),"sha256":"\(payload.sha256Hex)",
          "format":"PNG","image_slot":0,"image_anchor_words":[0,0,0],"motion_timelines":{"0":[[
          {"time":0,"type":4,"offset":0,"texture_numbers":[0],"source_areas":[[0,0,0,1]],
           "source_area_mode_input":1,"source_area_interpolation_flag":true,"blend":2,"sampling":0,
           "literal_opacity_input":255,"opacity_mode_input":0,"anchor_ratio_inputs":[0,0],
           "transform_fields":{"0x84":0,"0x88":0,"0x8c":0,"0x90":100,"0x94":100,"0x98":100,
                               "0x9c":0,"0xa0":0,"0xa4":0,"0xa8":0}},
          {"time":1000,"type":4,"offset":1,"source_areas":[[0,0,2,1]]}]]}}]
        """
        let recipe = try JSONDecoder().decode(ScriptImageRecipe.self, from: Data(receipt.utf8))
        let location = ScriptLocation(sourceFile: "fixture.b", sourceSHA256: digest,
            byteOffset: 0, byteLength: container.count, rangeSHA256: digest, lineNumber: 1)
        let background = SIMD4<UInt8>(30, 40, 50, 255)
        var canvas = [[background, background]]
        let key = try XCTUnwrap(recipe.motionKeys(location, selectedMember: 0, time: 500)?.first)
        XCTAssertTrue(try recipe.drawFullTexturePreview(key, container: container, origin: .zero, canvas: &canvas))
        XCTAssertEqual(canvas[0][0], SIMD4<UInt8>(30, 40, 153, 255))
        XCTAssertEqual(canvas[0][1], background)
        let fractional = try XCTUnwrap(recipe.motionKeys(location, selectedMember: 0, time: 250)?.first)
        canvas = [[background, background]]
        XCTAssertTrue(try recipe.drawFullTexturePreview(fractional, container: container, origin: .zero, canvas: &canvas))
        XCTAssertEqual(canvas[0][0], SIMD4<UInt8>(30, 40, 153, 255))
        XCTAssertEqual(canvas[0][1], background)
    }

    func testFractionalScanBoundsQuantizeBeforeClipping() throws {
        XCTAssertEqual(SingleTextureScanBounds.quantized(15.5005), 15.5009765625)
        XCTAssertEqual(SingleTextureScanBounds.inclusiveRange(start: 2, end: 17.5005, limit: 128), 2...17)
        XCTAssertEqual(SingleTextureScanBounds.inclusiveRange(start: 0.25, end: 200.25, limit: 128), 1...127)
        XCTAssertNil(SingleTextureScanBounds.inclusiveRange(start: 0, end: 0, limit: 128))
        XCTAssertNil(SingleTextureScanBounds.inclusiveRange(start: -.infinity, end: 1, limit: 128))
        let span = try XCTUnwrap(SingleTextureScanBounds.coordinateSpan(start: 0.25, end: 2.25,
            sourceStart: 0, sourceEnd: 2, limit: 8))
        XCTAssertEqual(span.pixels, 1...2)
        XCTAssertEqual(span.firstFixed, 49152)
        XCTAssertEqual(span.stepFixed, 65536)
        let subpixel = try XCTUnwrap(SingleTextureScanBounds.coordinateSpan(start: 0.75, end: 1.25,
            sourceStart: 2, sourceEnd: 4, limit: 8))
        XCTAssertEqual(subpixel.pixels, 1...1)
        XCTAssertEqual(subpixel.firstFixed, 163840)
        XCTAssertEqual(subpixel.stepFixed, 131072)
        XCTAssertNil(SingleTextureScanBounds.coordinateSpan(start: 0, end: 2,
            sourceStart: .infinity, sourceEnd: 2, limit: 8))
    }

    func testFractionalScreenTextureDrawsOnlyBoundedDirectSpan() throws {
        let rgba = Array(repeating: [UInt8](arrayLiteral: 255, 0, 0, 128), count: 8).flatMap { $0 }
        let payload = try png(rgba, width: 4, height: 2)
        let container = Data("abmp12".utf8) + payload, digest = container.sha256Hex
        let receipt = """
        [{"container_sha256":"\(digest)","offset":6,"length":\(payload.count),"sha256":"\(payload.sha256Hex)",
          "format":"PNG","image_slot":0,"image_anchor_words":[0,0,0],"motion_timelines":{"0":[[
          {"time":0,"type":4,"offset":0,"texture_numbers":[0],"source_areas":[[0,0,0,1]],
           "source_area_mode_input":1,"source_area_interpolation_flag":true,"blend":2,"sampling":0,
           "literal_opacity_input":255,"opacity_mode_input":0,"anchor_ratio_inputs":[0,0],
           "transform_fields":{"0x84":0,"0x88":0,"0x8c":0,"0x90":100,"0x94":100,"0x98":100,
                               "0x9c":0,"0xa0":0,"0xa4":0,"0xa8":0}},
          {"time":1000,"type":4,"offset":1,"source_areas":[[0,0,3,2]]}]]}}]
        """
        let recipe = try JSONDecoder().decode(ScriptImageRecipe.self, from: Data(receipt.utf8))
        let location = ScriptLocation(sourceFile: "fixture.b", sourceSHA256: digest,
            byteOffset: 0, byteLength: container.count, rangeSHA256: digest, lineNumber: 1)
        let key = try XCTUnwrap(recipe.motionKeys(location, selectedMember: 0, time: 500)?.first)
        let background = SIMD4<UInt8>(30, 40, 50, 255)
        var canvas = Array(repeating: Array(repeating: background, count: 4), count: 3)
        XCTAssertTrue(try recipe.drawFullTexturePreview(key, container: container, origin: .zero, canvas: &canvas))
        for y in 0..<3 {
            for x in 0..<4 {
                XCTAssertEqual(canvas[y][x], x < 2 && y < 2 ? SIMD4<UInt8>(30, 40, 153, 255) : background)
            }
        }
        let outOfBounds = try JSONDecoder().decode(ScriptImageRecipe.self,
            from: Data(receipt.replacingOccurrences(of: "[0,0,3,2]", with: "[0,0,3,3]").utf8))
        let rejected = try XCTUnwrap(outOfBounds.motionKeys(location, selectedMember: 0, time: 500)?.first)
        let before = canvas
        XCTAssertThrowsError(try outOfBounds.drawFullTexturePreview(rejected, container: container, origin: .zero, canvas: &canvas))
        XCTAssertEqual(canvas, before)
    }

    func testLiteralMotionLoopRetainsIntroAndCarriesOvershoot() throws {
        let digest = Data("synthetic animation fixture".utf8).sha256Hex
        let location = ScriptLocation(sourceFile: "fixture.b", sourceSHA256: digest,
                                      byteOffset: 0, byteLength: 5, rangeSHA256: digest, lineNumber: 1)
        let receipt = """
        [{"container_sha256":"\(digest)","offset":0,"length":5,"sha256":"\(digest)",
          "motion_timelines":{"1":[[
            {"time":100,"type":4,"offset":0,"time_control_inputs":[0,0,0,0]},
            {"time":300,"type":4,"offset":1,"time_control_inputs":[0,0,0,0]},
            {"time":700,"type":4,"offset":2,"time_control_inputs":[0,0,0,0]},
            {"time":1800,"type":0,"offset":3,"time_control_inputs":[1,1,0,0]},
            {"time":2800,"type":0,"offset":4,"time_control_inputs":[0,0,0,0]}]]}}]
        """
        let recipe = try JSONDecoder().decode(ScriptImageRecipe.self, from: Data(receipt.utf8))
        XCTAssertEqual(recipe.motionKeys(location, selectedMember: 1, time: 99)?.count, 0)
        for (time, offset): (Int32, Int) in [(299, 0), (1799, 2), (1800, 1), (3700, 2)] {
            XCTAssertEqual(recipe.motionKeys(location, selectedMember: 1, time: time)?.first?.offset, offset)
        }
    }

    func testARGBDualStreamsUseTheModeSpecificAlphaChannel() throws {
        func jpeg(_ pixel: [UInt8]) throws -> Data {
            let image = try ResourceImage.decode(png(pixel)).image
            let output = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return output as Data
        }
        let color = try jpeg([255, 0, 0, 255])
        let jpegMask = try jpeg([0, 0, 128, 255])
        let pngMask = try png([0, 0, 0, 128])
        let modes: [(UInt8, Data, Data)] = [(2, color, jpegMask), (3, color, pngMask), (4, pngMask, color)]
        for (mode, first, second) in modes {
            let data = Data("ARGBSaveData1".utf8) + Data([0, 0, 0, mode]) +
                le([UInt32(first.count), UInt32(second.count)]) + first + second
            let header = Data("abmp12".utf8)
            let container = header + data
            let receipt = """
            [{"container_sha256":"\(container.sha256Hex)","offset":\(header.count),
              "length":\(data.count),"sha256":"\(data.sha256Hex)","format":"ARGB"}]
            """
            let recipe = try JSONDecoder().decode(ScriptImageRecipe.self, from: Data(receipt.utf8))
            let payload = try recipe.staticRasterPayload(container, sourceFile: "fixture.b", selectedMember: nil)
            XCTAssertEqual(payload, data)
            let image = try ResourceImage.decode(payload)
            let pixel = try rgba(image.image)
            XCTAssertEqual(image.format, "ARGB")
            XCTAssertEqual(pixel.count, 4)
            XCTAssertLessThanOrEqual(abs(Int(pixel[3]) - 128), 4)
            XCTAssertLessThanOrEqual(abs(Int(pixel[0]) - Int(pixel[3])), 4)
        }
    }

    func testABMPFullTexturePreviewDrawsPinnedJPEGAtOrigin() throws {
        let source = try ResourceImage.decode(png([255, 0, 0, 255])).image
        let encoded = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(encoded, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, source, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let payload = encoded as Data
        let prefix = Data("abmp12".utf8)
        let container = prefix + payload
        let digest = container.sha256Hex
        let receipt = """
        [{"container_sha256":"\(digest)","offset":\(prefix.count),"length":\(payload.count),
          "sha256":"\(payload.sha256Hex)","format":"JPEG","image_slot":0,"image_anchor_words":[0,0,0],
          "motion_timelines":{"0":[[{"time":0,"type":4,"offset":0,"texture_numbers":[0],
          "source_areas":[[0,0,0,0]],"blend":0,"sampling":0,"literal_opacity_input":255,"anchor_ratio_inputs":[0,0],
          "transform_fields":{"0x84":0,"0x88":0,"0x8c":0,"0x90":100,"0x94":100,"0x98":100,
          "0x9c":0,"0xa0":0,"0xa4":0,"0xa8":0}}]]}}]
        """
        let recipe = try JSONDecoder().decode(ScriptImageRecipe.self, from: Data(receipt.utf8))
        let location = ScriptLocation(sourceFile: "fixture.b", sourceSHA256: digest,
            byteOffset: 0, byteLength: container.count, rangeSHA256: digest, lineNumber: 1)
        let key = try XCTUnwrap(recipe.motionKeys(location, selectedMember: 0, time: 0)?.first)
        let black = SIMD4<UInt8>(0, 0, 0, 255)
        var canvas = [[black, black]]
        try recipe.drawFullTexturePreview(key, container: container, origin: SIMD2(1, 0), canvas: &canvas)
        XCTAssertEqual(canvas[0][0], black)
        XCTAssertGreaterThan(canvas[0][1].z, 240)
        var translucent = [[black, black]]
        try recipe.drawFullTexturePreview(key, container: container, origin: SIMD2(1, 0),
                                          layerOpacity: 128, canvas: &translucent)
        XCTAssertEqual(translucent[0][0], black)
        XCTAssertTrue((110...140).contains(translucent[0][1].z))

        var repeated = [[black, black]]
        try recipe.drawScopedTexturePreview([(key, []), (key, [])], container: container,
            boundTextures: [:], origin: SIMD2(1, 0), hostScale: SIMD2(1, 1),
            anchorOverride: nil, layerOpacity: 128, canvas: &repeated)
        XCTAssertGreaterThan(repeated[0][1].z, translucent[0][1].z)

        let asymmetric = try png([
            255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255,
            255, 255, 0, 255, 255, 0, 255, 255, 0, 255, 255, 255
        ], width: 3, height: 2)
        let sampling2Recipe = try JSONDecoder().decode(ScriptImageRecipe.self,
            from: Data(receipt.replacingOccurrences(of: "\"sampling\":0", with: "\"sampling\":2").utf8))
        let sampling2Key = try XCTUnwrap(sampling2Recipe.motionKeys(location, selectedMember: 0, time: 0)?.first)
        var samplingCanvas = Array(repeating: Array(repeating: black, count: 4), count: 3)
        XCTAssertThrowsError(try sampling2Recipe.drawFullTexturePreview(sampling2Key, container: container,
            boundTextures: [0: asymmetric], origin: .zero, canvas: &samplingCanvas))
        XCTAssertTrue(try sampling2Recipe.drawFullTexturePreview(sampling2Key, container: container,
            boundTextures: [0: asymmetric], origin: .zero, sampling2CandidateSlot: 0, canvas: &samplingCanvas))
        var upright = Array(repeating: Array(repeating: black, count: 3), count: 2)
        try recipe.drawFullTexturePreview(key, container: container, boundTextures: [0: asymmetric],
                                          origin: .zero, canvas: &upright)
        XCTAssertEqual(Set(upright.flatMap { $0 }).count, 6)
        var mirrored = Array(repeating: Array(repeating: black, count: 3), count: 2)
        try recipe.drawFullTexturePreview(key, container: container, boundTextures: [0: asymmetric],
            origin: SIMD2(2, 2), hostScale: SIMD2(-1, -1), canvas: &mirrored)
        XCTAssertEqual(mirrored, [
            [upright[1][1], upright[1][0], black],
            [upright[0][1], upright[0][0], black]
        ])

        let invalid = try JSONDecoder().decode(ScriptImageRecipe.MotionKey.self,
            from: Data(#"{"time":0,"type":0,"offset":0}"#.utf8))
        let prior = repeated
        XCTAssertThrowsError(try recipe.drawScopedTexturePreview([(key, []), (invalid, [])],
            container: container, boundTextures: [:], origin: SIMD2(1, 0), hostScale: SIMD2(1, 1),
            anchorOverride: nil, layerOpacity: 255, canvas: &repeated))
        XCTAssertEqual(repeated, prior)

        // A valid 8-bit grayscale PNG has no straight RGBA layout.
        let gray = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVR4nGP4DwABAQEAsTj2FAAAAABJRU5ErkJggg=="))
        XCTAssertThrowsError(try ResourceImage.straightPNGPixels(gray))
        let grayContainer = prefix + gray
        let grayReceipt = receipt.replacingOccurrences(of: digest, with: grayContainer.sha256Hex)
            .replacingOccurrences(of: payload.sha256Hex, with: gray.sha256Hex)
            .replacingOccurrences(of: "\(payload.count)", with: "\(gray.count)")
            .replacingOccurrences(of: "JPEG", with: "PNG")
        let grayRecipe = try JSONDecoder().decode(ScriptImageRecipe.self, from: Data(grayReceipt.utf8))
        var grayCanvas = [[black]]
        XCTAssertTrue(try grayRecipe.drawFullTexturePreview(key, container: grayContainer, origin: .zero, canvas: &grayCanvas))
        XCTAssertEqual(grayCanvas, [[SIMD4(255, 255, 255, 255)]])

        let upperReceipt = receipt
            .replacingOccurrences(of: "\"image_slot\":0", with: "\"image_slot\":1")
            .replacingOccurrences(of: "\"texture_numbers\":[0]", with: "\"texture_numbers\":[1]")
            .replacingOccurrences(of: "\"0xa8\":0", with: "\"0xa8\":10")
        let upperRecipe = try JSONDecoder().decode(ScriptImageRecipe.self, from: Data(upperReceipt.utf8))
        let upperKey = try XCTUnwrap(upperRecipe.motionKeys(location, selectedMember: 0, time: 0)?.first)
        var sortedCanvas = [[black]]
        XCTAssertTrue(try upperRecipe.drawScopedTexturePreview([(upperKey, []), (key, [])],
            container: container, boundTextures: [0: gray], origin: .zero, hostScale: SIMD2(1, 1),
            anchorOverride: nil, layerOpacity: 255, canvas: &sortedCanvas))
        XCTAssertGreaterThan(sortedCanvas[0][0].z, 240)
        XCTAssertLessThan(sortedCanvas[0][0].x, 16)
        var boundCanvas = [[black]]
        let red = try png([255, 0, 0, 255])
        XCTAssertTrue(try upperRecipe.drawScopedTexturePreview([(upperKey, []), (key, [])],
            container: container, boundTextures: [0: gray, 1: red], origin: .zero, hostScale: SIMD2(1, 1),
            anchorOverride: nil, layerOpacity: 255, canvas: &boundCanvas))
        XCTAssertEqual(boundCanvas, [[SIMD4(0, 0, 255, 255)]])
    }

    func testOpaquePNGCanvasPixelsPreserveDecoderChannels() throws {
        let opaque = try png([140, 77, 101, 255, 3, 211, 17, 255], width: 2, height: 1)
        XCTAssertEqual(try ResourceImage.opaquePNGCanvasPixels(opaque, width: 2, height: 1),
                       [[SIMD4(140, 77, 101, 255), SIMD4(3, 211, 17, 255)]])
        XCTAssertThrowsError(try ResourceImage.opaquePNGCanvasPixels(
            png([140, 77, 101, 128]), width: 1, height: 1))
        XCTAssertThrowsError(try ResourceImage.opaquePNGCanvasPixels(opaque, width: 1, height: 1))
    }

    func testABMPRecipeDrawsVerifiedDPNGMember() throws {
        let red = try png([255, 0, 0, 255])
        let payload = dpng([(1, 0, 1, 1, red, 0)], width: 3, height: 2)
        let header = Data("abmp12".utf8)
        let container = header + payload
        let receipt: [[String: Any]] = [[
            "container_sha256": container.sha256Hex, "offset": header.count,
            "length": payload.count, "sha256": payload.sha256Hex, "format": "DPNG",
            "image_slot": 0, "image_anchor_words": [0, 0, 0],
            "motion_timelines": ["0": [[[
                "time": 0, "type": 4, "offset": 0, "texture_numbers": [0],
                "source_areas": [[0, 0, 0, 0]], "blend": 0, "sampling": 0,
                "literal_opacity_input": 255, "anchor_ratio_inputs": [0, 0],
                "transform_fields": ["0x84": 0, "0x88": 0, "0x8c": 0, "0x90": 100,
                    "0x94": 100, "0x98": 100, "0x9c": 0, "0xa0": 0, "0xa4": 0, "0xa8": 0]
            ]]]]
        ]]
        let recipe = try JSONDecoder().decode(ScriptImageRecipe.self,
            from: JSONSerialization.data(withJSONObject: receipt))
        let bytes = try recipe.staticRasterPayload(container, sourceFile: "fixture.b", selectedMember: nil)
        let image = try ResourceImage.decode(bytes).image
        XCTAssertEqual(image.width, 3)
        XCTAssertEqual(image.height, 2)
        let location = ScriptLocation(sourceFile: "fixture.b", sourceSHA256: container.sha256Hex,
            byteOffset: 0, byteLength: container.count, rangeSHA256: container.sha256Hex, lineNumber: 1)
        let key = try XCTUnwrap(recipe.motionKeys(location, selectedMember: 0, time: 0)?.first)
        let black = SIMD4<UInt8>(0, 0, 0, 255)
        var canvas = [[black, black, black], [black, black, black]]
        XCTAssertTrue(try recipe.drawFullTexturePreview(key, container: container, origin: .zero, canvas: &canvas))
        XCTAssertEqual(canvas, [[black, SIMD4(0, 0, 255, 255), black], [black, black, black]])
    }

    func testDPNGDescriptorPreservesOffsetsAndRejectsBoundsFlagsAndTrailingBytes() throws {
        let data = dpng([(1,0,1,1,try png([1,2,3,255]),1)])
        let result = try DPNGDescriptor.parse(data)
        XCTAssertEqual(result.tiles[0].payload.lowerBound, 48)
        XCTAssertEqual(result.tiles[0].flags, [1,0])
        for bad in [data.dropLast(), data + Data([0]), dpng([(2,0,1,1,Data(),0)]), dpng([(0,0,0,1,Data(),257)])] {
            XCTAssertThrowsError(try DPNGDescriptor.parse(Data(bad)))
        }
    }
    func testExtremeUnsignedDimensionsAndReadOffsetsCannotOverflow() throws {
        XCTAssertThrowsError(try DPNGDescriptor.parse(dpng([], width: .max, height: .max)))
        XCTAssertThrowsError(try SafeDirectory.read(fd: -1, offset: .max, count: 2))
        XCTAssertThrowsError(try Data([1,2,3]).u32(0))
    }
    func testDPNGCoordinatesAndEmptyCanvasAreNotVerticallyFlipped() throws {
        let red = try png([255,0,0,255]), blue = try png([0,0,255,255])
        let data = dpng([(0,0,1,1,red,0),(1,1,1,1,blue,0)], height: 2)
        let decoded = try ResourceImage.decode(data)
        XCTAssertEqual(try rgba(decoded.image), [255,0,0,255, 0,0,0,0, 0,0,0,0, 0,0,255,255])
        XCTAssertEqual(decoded.originalRendererEquivalence, .notTested)
    }
    func testDPNGTransparentOverlapUsesCopyNotSourceOver() throws {
        let red = try png([255,0,0,255]), blue = try png([0,0,255,128])
        let data = dpng([(0,0,1,1,red,0),(0,0,1,1,blue,0)], width: 1)
        let actual = try rgba(ResourceImage.decode(data).image)
        XCTAssertEqual(actual, [0,0,128,128])
    }
    func testDPNGFlaggedEmptyPayloadFillsWholeRow() throws {
        let data = dpng([(0,0,1,1,try png([255,0,0,255]),0),(1,0,0,1,Data(),1)])
        XCTAssertEqual(try rgba(ResourceImage.decode(data).image), Array(repeating: 0, count: 8))
    }
    func testMalformedImagesAndUnsupportedFormatsThrow() throws {
        for data in [Data("abmp12".utf8), Data([0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a]), Data()] {
            XCTAssertThrowsError(try ResourceImage.decode(data))
        }
    }
}
