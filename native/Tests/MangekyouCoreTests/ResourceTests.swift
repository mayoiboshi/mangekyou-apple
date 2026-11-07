import XCTest
import Foundation
import CoreGraphics
import ImageIO
@testable import MangekyouCore
import MangekyouMedia

final class ResourceTests: XCTestCase {
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
