import XCTest
import Foundation
import CoreGraphics
import ImageIO
@testable import MangekyouCore
import MangekyouMedia

final class ResourceTests: XCTestCase {
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
    }

    func testLiteralMotionLoopRetainsIntroAndCarriesOvershoot() throws {
        let digest = Data("synthetic animation fixture".utf8).sha256Hex
        let location = ScriptLocation(sourceFile: "fixture.b", sourceSHA256: digest,
                                      byteOffset: 0, byteLength: 5, rangeSHA256: digest, lineNumber: 1)
        let receipt = """
        [{"container_sha256":"\(digest)","offset":0,"length":5,"sha256":"\(digest)",
          "motion_timelines":{"1":[[
            {"time":0,"type":4,"offset":0,"time_control_inputs":[0,0,0,0]},
            {"time":300,"type":4,"offset":1,"time_control_inputs":[0,0,0,0]},
            {"time":700,"type":4,"offset":2,"time_control_inputs":[0,0,0,0]},
            {"time":1800,"type":0,"offset":3,"time_control_inputs":[1,1,0,0]},
            {"time":2800,"type":0,"offset":4,"time_control_inputs":[0,0,0,0]}]]}}]
        """
        let recipe = try JSONDecoder().decode(ScriptImageRecipe.self, from: Data(receipt.utf8))
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
            boundSlotZero: nil, origin: SIMD2(1, 0), hostScale: SIMD2(1, 1),
            anchorOverride: nil, layerOpacity: 128, canvas: &repeated)
        XCTAssertGreaterThan(repeated[0][1].z, translucent[0][1].z)

        let asymmetric = try png([
            255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255,
            255, 255, 0, 255, 255, 0, 255, 255, 0, 255, 255, 255
        ], width: 3, height: 2)
        var upright = Array(repeating: Array(repeating: black, count: 3), count: 2)
        try recipe.drawFullTexturePreview(key, container: container, boundSlotZero: asymmetric,
                                          origin: .zero, canvas: &upright)
        XCTAssertEqual(Set(upright.flatMap { $0 }).count, 6)
        var mirrored = Array(repeating: Array(repeating: black, count: 3), count: 2)
        try recipe.drawFullTexturePreview(key, container: container, boundSlotZero: asymmetric,
            origin: SIMD2(2, 2), hostScale: SIMD2(-1, -1), canvas: &mirrored)
        XCTAssertEqual(mirrored, [
            [upright[1][1], upright[1][0], black],
            [upright[0][1], upright[0][0], black]
        ])

        let invalid = try JSONDecoder().decode(ScriptImageRecipe.MotionKey.self,
            from: Data(#"{"time":0,"type":0,"offset":0}"#.utf8))
        let prior = repeated
        XCTAssertThrowsError(try recipe.drawScopedTexturePreview([(key, []), (invalid, [])],
            container: container, boundSlotZero: nil, origin: SIMD2(1, 0), hostScale: SIMD2(1, 1),
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
            container: container, boundSlotZero: gray, origin: .zero, hostScale: SIMD2(1, 1),
            anchorOverride: nil, layerOpacity: 255, canvas: &sortedCanvas))
        XCTAssertGreaterThan(sortedCanvas[0][0].z, 240)
        XCTAssertLessThan(sortedCanvas[0][0].x, 16)
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
