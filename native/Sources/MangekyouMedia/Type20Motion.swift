import Foundation
import MangekyouCore

struct Type20Motion {
    struct RasterMode: Decodable, Sendable {
        let mode: UInt8
        let flags: UInt8
        let rotation_order: UInt8?
    }

    struct Pose {
        let translation: SIMD2<Float>
        let scale: SIMD2<Float>
        let anchor: SIMD2<Float>
        let angle: Float
        let depth: Int64
        let tilt: SIMD2<Float>?

        func rotate(_ point: SIMD2<Float>) -> SIMD2<Float> {
            let (c, s) = Self.rotationComponents(angle)
            return SIMD2(Float(Double(point.x) * c - Double(point.y) * s),
                         Float(Double(point.x) * s + Double(point.y) * c))
        }

        func project(_ point: SIMD2<Float>, centeredZ: Float) -> SIMD2<Float> {
            guard let tilt else { return rotate(point) }
            // 0x50b655 selects X, Y, then Z for order zero. The matrix
            // branch of 0x581cdc copies the transformed X/Y to the quad.
            let (cx, sx) = Self.rotationComponents(tilt.x)
            let (cy, sy) = Self.rotationComponents(tilt.y)
            let y = Double(point.y) * cx - Double(centeredZ) * sx
            let z = Double(point.y) * sx + Double(centeredZ) * cx
            return rotate(SIMD2(Float(Double(point.x) * cy + z * sy), Float(y)))
        }

        private static func rotationComponents(_ angle: Float) -> (Double, Double) {
            // 0x58c662 converts degrees to Single turns. The axis routines
            // store their sine and cosine as Single before updating the matrix.
            let turns = Float(Double(angle) / 360)
            let radians = Double(turns) * 2 * 3.14159265
            return (Double(Float(cos(radians))), Double(Float(sin(radians))))
        }
    }

    struct Input: Decodable, Sendable {
        let first_area: [Float]
        let second_area: [Float]
        let first_area_interpolates: Bool
        let second_area_interpolates: Bool
        let volume: [Float]
        let seed: UInt32
        let clock_interpolates: Bool
        let clock_range: [Float]

        private var isBounded: Bool {
            first_area.count == 4 && second_area.count == 4 && volume.count == 3 && clock_range.count == 2 &&
                (0...512).contains(first_area[0]) && (0...100).contains(first_area[1]) &&
                (0...32).contains(first_area[2]) && first_area[3] == 0 &&
                second_area.allSatisfy { (-10000...10000).contains($0) } &&
                second_area[3] > -100 && (0...8192).contains(volume[0]) &&
                (0...8192).contains(volume[1]) && (-8192...8192).contains(volume[2]) &&
                clock_range.allSatisfy { (0...16_000_000).contains($0) } &&
                (1...65535).contains(seed)
        }

        func sampled(fraction: Float, next: Self?) -> Self? {
            guard isBounded, (0...1).contains(fraction) else { return nil }
            guard fraction > 0, first_area_interpolates || second_area_interpolates || clock_interpolates else {
                return self
            }
            guard let next, next.isBounded else { return nil }
            func blend(_ first: [Float], _ second: [Float], enabled: Bool) -> [Float] {
                guard enabled else { return first }
                return zip(first, second).map { a, b in
                    Float(Double(a) * Double(1 - fraction) + Double(b) * Double(fraction))
                }
            }
            let clocks = blend(clock_range, next.clock_range, enabled: clock_interpolates)
                .map { $0.rounded(.towardZero) }
            return Self(first_area: blend(first_area, next.first_area, enabled: first_area_interpolates),
                        second_area: blend(second_area, next.second_area, enabled: second_area_interpolates),
                        first_area_interpolates: false, second_area_interpolates: false,
                        volume: volume, seed: seed, clock_interpolates: false, clock_range: clocks)
        }
    }

    struct RandomTable {
        private let words: [UInt32]
        let sha256: String
        let usedStartupFallback: Bool

        init(_ data: Data?) throws {
            if let data {
                guard data.count == 4096 else { throw ResourceError.rejected("particle_table_size") }
                words = data.withUnsafeBytes { bytes in
                    (0..<1024).map { UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)) }
                }
                sha256 = data.sha256Hex
                usedStartupFallback = false
            } else {
                // 0x6d5f71 selects the fixed seed when the startup stream is absent.
                // 0x50b748 requests each value through the unsigned multiply-high helper.
                var seed: UInt32 = 1058493671
                words = (0..<1024).map { _ in
                    seed = seed &* 134775813 &+ 1
                    return UInt32((UInt64(seed) * 2147483647) >> 32)
                }
                let bytes = words.map(\.littleEndian)
                sha256 = bytes.withUnsafeBytes { Data($0).sha256Hex }
                usedStartupFallback = true
            }
        }

        subscript(index: Int) -> Float {
            Float(Double(words[index & 1023] & 0xffffff) / 16_777_215)
        }
    }

    struct Instance: Encodable {
        let action: Int32
        let clock: Int32
        let opacity: UInt8
        let offset: [Float]
        let scale: Float
    }

    struct Raster {
        enum Blend {
            case normal
            case additive
        }

        let pixels: [[SIMD4<UInt8>]]
        let vertices: [SIMD2<Float>]
        let opacity: UInt8
        let blend: Blend
        let multiplierRGB: UInt32

        private struct Intersection {
            var x: Float
            var uv: SIMD2<Float>
        }

        func draw(canvas: inout [[SIMD4<UInt8>]]) -> Bool {
            guard let targetWidth = canvas.first?.count, let sourceWidth = pixels.first?.count else { return false }
            let sourceHeight = pixels.count
            // 0x532648 rounds vertices to 1/1024 before building the edge table.
            let points = vertices.map { point in
                SIMD2(Float(floor(Double(point.x) * 1024 + 0.5) / 1024),
                      Float(floor(Double(point.y) * 1024 + 0.5) / 1024))
            }
            guard let minimumY = points.map(\.y).min(), let maximumY = points.map(\.y).max(), maximumY >= 0 else {
                return false
            }
            let top = max(0, Int(minimumY + Float(bitPattern: 0x3f7fff80)))
            let bottom = min(canvas.count - 1, Int(maximumY))
            guard top <= bottom else { return false }
            let texels: [SIMD2<Float>] = [.zero, SIMD2(Float(sourceWidth), 0),
                SIMD2(Float(sourceWidth), Float(sourceHeight)), SIMD2(0, Float(sourceHeight))]
            var edges = Array(repeating: [Intersection](), count: bottom - top + 1)
            for edge in points.indices {
                var a = edge, b = (edge + 1) % points.count
                if points[a].y > points[b].y { swap(&a, &b) }
                guard points[b].y >= 0 else { continue }
                let height = points[b].y - points[a].y
                if height == 0 {
                    let y = Int(points[a].y)
                    if Float(y) == points[a].y, (top...bottom).contains(y) {
                        edges[y - top].append(.init(x: points[a].x, uv: texels[a]))
                        edges[y - top].append(.init(x: points[b].x, uv: texels[b]))
                    }
                    continue
                }
                let first = max(top, Int(points[a].y + Float(bitPattern: 0x3f7fff80)))
                let last = min(bottom, Int(points[b].y))
                guard first <= last else { continue }
                let stepX = (points[b].x - points[a].x) / height
                let stepUV = (texels[b] - texels[a]) / height
                let delta = max(0, Float(first) - points[a].y)
                var x = Float(Double(points[a].x) + Double(stepX) * Double(delta))
                var uv = texels[a] + stepUV * delta
                for y in first...last {
                    edges[y - top].append(.init(x: x, uv: uv))
                    x += stepX
                    uv += stepUV
                }
            }
            let multipliers = SIMD4<Int>(truncatingIfNeeded: TwoTexturePixel.scannerColors(additiveRGB: 0,
                multiplierRGB: multiplierRGB, multiplierAlpha: opacity).multiplier)
            var covered = false
            for (row, intersections) in edges.enumerated() {
                guard let left = intersections.min(by: { $0.x < $1.x }),
                      let right = intersections.max(by: { $0.x < $1.x }), right.x >= 0 else { continue }
                let first = max(0, Int(left.x + Float(bitPattern: 0x3f7fff80)))
                let last = min(targetWidth - 1, Int(right.x))
                guard first <= last else { continue }
                // At 0x533fba the scanner starts at the first clipped
                // destination pixel and advances the source in signed 16.16.
                let step = (right.uv - left.uv) / max(1, right.x - left.x)
                let start = left.uv + step * max(0, Float(first) - left.x)
                func fixed(_ v: Float) -> Int { Int(floor(Double(v) * 65536 + 0.5)) }
                var u = fixed(start.x), v = fixed(start.y)
                let du = fixed(step.x), dv = fixed(step.y)
                for x in first...last {
                    let pixel = pixels[min(max(v >> 16, 0), sourceHeight - 1)][min(max(u >> 16, 0), sourceWidth - 1)]
                    u += du
                    v += dv
                    let alpha = (Int(pixel.w) * multipliers.w) >> 7
                    guard alpha != 0 else { continue }
                    let y = top + row
                    switch blend {
                    case .normal:
                        canvas[y][x] = TwoTexturePixel.blendOntoTarget(
                            source: SIMD4(Int16(pixel.x), Int16(pixel.y), Int16(pixel.z), Int16(alpha)),
                            target: canvas[y][x])
                    case .additive:
                        // Backend mode 9 (0x533341 -> 0x532c74) scales the
                        // source lanes by the adjusted alpha, then saturates.
                        let weight = alpha + (alpha >> 7)
                        let source = SIMD4((Int(pixel.x) * multipliers.x) >> 7,
                            (Int(pixel.y) * multipliers.y) >> 7, (Int(pixel.z) * multipliers.z) >> 7, alpha)
                        let destination = canvas[y][x]
                        for lane in 0..<4 {
                            canvas[y][x][lane] = UInt8(clamping: Int(destination[lane]) + ((source[lane] * weight) >> 8))
                        }
                    }
                    covered = true
                }
            }
            return covered
        }
    }

    static func instances(_ input: Input, table: RandomTable, actionCount: Int, childSize: SIMD2<Int>,
                          opacity: UInt8) throws -> [Instance] {
        guard let input = input.sampled(fraction: 0, next: nil),
              (1...128).contains(actionCount), (0...8192).contains(childSize.x),
              (0...8192).contains(childSize.y) else { throw ResourceError.rejected("type20_instance_input") }
        let requested = input.first_area[0]
        let fraction = requested - requested.rounded(.towardZero)
        // 0x586bc4 drops the final iteration when the fraction is below 0.001.
        let count = Int(requested) + (Double(fraction) >= 0.001 ? 1 : 0)
        let lastOpacity = Double(fraction) < 0.001 ? 255 : Int((fraction * 255).rounded(.toNearestOrEven))
        let divisions = max(1, Int(input.first_area[2].rounded(.toNearestOrEven)))
        let fade = Float(Double(input.first_area[1]) * 0.005)
        let phaseBase = Float((100 - 100 % divisions) * 100)
        let seed = Int(input.seed) * 777
        let scale = Float(Double(input.second_area[3]) * 0.01 + 1)
        func edgeOpacity(_ value: Float) -> Int {
            let edge = min(Double(value), 1 - Double(value))
            guard edge < Double(fade) else { return 255 }
            let factor = Double(fade) > 0.001 ? Float(1 / Double(fade)) : 1
            return Int(Double(factor) * edge * 255)
        }
        // This is the rectangular variant selected at 0x588084. The
        // spherical variant changes positions and opacity after sampling.
        return (0..<count).map { index in
            let base = seed + index
            var x = Float(Double(phaseBase + input.second_area[0]) * 0.01) + table[base + 234]
            var y = Float(Double(phaseBase + input.second_area[1]) * 0.01) + table[base + 555]
            var z = Float(Double(phaseBase + input.second_area[2]) * 0.01) + table[base + 777]
            let ix = Int(x) % divisions, iy = Int(y) % divisions, iz = Int(z) % divisions
            if ix > 0 { y += table[ix + index + 123]; z += table[ix + index + 678] }
            if iy > 0 { x += table[iy + index + 789]; z += table[iy + index + 234] }
            if iz > 0 { x += table[iz + index + 345]; y += table[iz + index + 899] }
            x -= x.rounded(.towardZero); y -= y.rounded(.towardZero); z -= z.rounded(.towardZero)
            let cell = ix | (iy << 2) | (iz << 4)
            let t = Double(table[base ^ cell])
            let clock = Int32((1 - t) * Double(input.clock_range[0]) + t * Double(input.clock_range[1]))
            let action = min(actionCount - 1,
                Int((table[(base + 999) ^ cell] * Float(actionCount)).rounded(.toNearestOrEven)))
            let cap = index == count - 1 ? lastOpacity : 255
            let a = UInt8(clamping: min(cap, edgeOpacity(x), edgeOpacity(y), edgeOpacity(z)) * Int(opacity) / 255)
            let dx = Float(Double(x * input.volume[0]) - Double(childSize.x) * 0.5)
            let dy = Float(Double(y * input.volume[1]) - Double(childSize.y) * 0.5)
            return Instance(action: Int32(action), clock: clock, opacity: a,
                            offset: [dx, dy, z * input.volume[2]], scale: scale)
        }
    }
}
