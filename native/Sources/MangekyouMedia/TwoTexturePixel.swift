/// Intermediate output of the original command-4 pixel callback at 0x5333a8.
/// Lane order follows the scan input. Later color operations and destination
/// blending are the caller's responsibility.
package enum TwoTexturePixel {
    /// 0x5333ec prepares the command-3 direct-path threshold and gain.
    /// This does not select a renderer, sampling branch, or input channel.
    package static func command3Threshold(value: Int32, rawMode: UInt32) -> (threshold: Int16, gain: Int16, inverted: Bool)? {
        guard (0...255).contains(value) else { return nil }
        let shift = min(Int(rawMode & 0xf), 7)
        let gain = 1 << shift
        let divisor = 256 / gain
        let threshold = ((255 - Int(value)) * (255 + divisor)) / 255 - divisor
        return (Int16(threshold), Int16(gain), (rawMode & 0x80) != 0)
    }

    /// Lowest packed byte produced by 0x533438 / 0x5334a0 for one sampled lane.
    package static func command3Mask(sample: UInt8, threshold: Int16, gain: Int16, inverted: Bool) -> UInt8 {
        let input = inverted ? 255 - Int(sample) : Int(sample)
        let difference = Int16(clamping: input - Int(threshold))
        return UInt8(clamping: Int(difference &* gain))
    }

    /// Direct single-texture mode 4 callback at 0x532c14–0x532c70.
    package static func screenOntoTarget(source: SIMD4<UInt8>, target: SIMD4<UInt8>) -> SIMD4<UInt8> {
        let weight = Int(source.w) + (Int(source.w) >> 7)
        var result = SIMD4<UInt8>.zero
        for lane in 0..<4 {
            let scaled = (Int(source[lane]) * weight) >> 8
            let dest = Int(target[lane])
            result[lane] = UInt8(clamping: scaled + dest - ((scaled * dest) >> 8))
        }
        return result
    }
    /// Parameter conversion at 0x533394, before command 4 selects a scanner.
    package static func command4Weights(_ raw: UInt32) -> UInt32 {
        ((raw << 23) & 0xff000000) | 0x00808080
    }

    /// Color preparation at 0x53ad72–0x53ad9f and the scanner entry.
    package static func scannerColors(additiveRGB: UInt32, multiplierRGB: UInt32,
                                      multiplierAlpha: UInt8) -> (additive: SIMD4<UInt8>, multiplier: SIMD4<UInt8>) {
        func lanes(_ rgb: UInt32, alpha: UInt8) -> SIMD4<UInt8> {
            SIMD4(UInt8(truncatingIfNeeded: rgb), UInt8(truncatingIfNeeded: rgb >> 8),
                  UInt8(truncatingIfNeeded: rgb >> 16), alpha)
        }
        let additive = lanes(additiveRGB, alpha: 0)
        let raw = lanes(multiplierRGB, alpha: multiplierAlpha)
        var multiplier = SIMD4<UInt8>.zero
        for lane in 0..<4 {
            multiplier[lane] = (raw[lane] >> 1) + (raw[lane] >> 7)
        }
        return (additive, multiplier)
    }

    /// Callback inputs prepared by the 0x53bf50 and 0x53c89c nearest-sample scanners.
    package static func nearestSample(source: SIMD4<UInt8>, secondaryLowByte: UInt8,
                                      packedWeights: UInt32) -> SIMD4<Int16> {
        let weights = SIMD4(
            UInt8(truncatingIfNeeded: packedWeights),
            UInt8(truncatingIfNeeded: packedWeights >> 8),
            UInt8(truncatingIfNeeded: packedWeights >> 16),
            UInt8(truncatingIfNeeded: packedWeights >> 24)
        )
        return evaluate(source: source, secondaryLowByte: secondaryLowByte,
                        maskWords: SIMD4(255, 255, 255, 0), weights: weights)
    }

    /// Scan setup at 0x53afd9–0x53b0d0 scales and biases before flooring.
    package static func fixedPointCoordinate(_ value: Float) -> Int32? {
        Int32(exactly: (Double(value) * 65_536 + 0.5).rounded(.down))
    }

    /// The sampled portion of 0x53c89c, after the caller selects both source rows.
    /// Positions and steps are signed 16.16 coordinates supplied by scan setup.
    package static func sampleRow(first: [SIMD4<UInt8>], second: [SIMD4<UInt8>],
                                  start: SIMD2<Int32>, step: SIMD2<Int32>, count: Int,
                                  packedWeights: UInt32) -> [SIMD4<Int16>]? {
        guard (0...8192).contains(count) else { return nil }
        var position = start
        var result: [SIMD4<Int16>] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            let firstIndex = Int(position.x >> 16)
            let secondIndex = Int(position.y >> 16)
            guard first.indices.contains(firstIndex), second.indices.contains(secondIndex) else { return nil }
            result.append(nearestSample(source: first[firstIndex], secondaryLowByte: second[secondIndex].x,
                                        packedWeights: packedWeights))
            position = position &+ step
        }
        return result
    }

    /// Draw a prepared scanline using the default destination blend.
    /// A failed sample leaves the caller's destination row intact.
    package static func drawRow(first: [SIMD4<UInt8>], second: [SIMD4<UInt8>],
                                start: SIMD2<Int32>, step: SIMD2<Int32>, packedWeights: UInt32,
                                multiplier: SIMD4<UInt8>, additive: SIMD4<UInt8>,
                                target: inout [SIMD4<UInt8>]) -> Bool {
        guard let samples = sampleRow(first: first, second: second, start: start, step: step,
                                      count: target.count, packedWeights: packedWeights) else { return false }
        for index in target.indices {
            target[index] = blendOntoTarget(source: samples[index], target: target[index],
                                            multiplier: multiplier, additive: additive)
        }
        return true
    }

    /// Scan complete source surfaces into an integer-aligned target, optionally clipped.
    package static func drawFullTextures(first: [[SIMD4<UInt8>]], second: [[SIMD4<UInt8>]],
                                         fullSize: SIMD2<Int>? = nil, clippedOrigin: SIMD2<Int> = .zero,
                                         packedWeights: UInt32, multiplier: SIMD4<UInt8>,
                                         additive: SIMD4<UInt8>, target: inout [[SIMD4<UInt8>]]) -> Bool {
        guard let width = target.first?.count, width > 0 else { return false }
        let size = fullSize ?? SIMD2(width, target.count)
        guard (1...8192).contains(size.x), (1...8192).contains(size.y),
              width <= size.x, target.count <= size.y,
              (0...(size.x - width)).contains(clippedOrigin.x),
              (0...(size.y - target.count)).contains(clippedOrigin.y),
              let firstWidth = first.first?.count, firstWidth > 0,
              let secondWidth = second.first?.count, secondWidth > 0,
              first.allSatisfy({ $0.count == firstWidth }),
              second.allSatisfy({ $0.count == secondWidth }),
              let firstX = fixedPointCoordinate(Float(firstWidth) / Float(size.x)),
              let secondX = fixedPointCoordinate(Float(secondWidth) / Float(size.x)),
              let firstY = fixedPointCoordinate(Float(first.count) / Float(size.y)),
              let secondY = fixedPointCoordinate(Float(second.count) / Float(size.y)) else { return false }
        func clippedStart(_ first: Int32, _ second: Int32, offset: Int) -> SIMD2<Int32>? {
            guard let x = Int32(exactly: Int64(first) * Int64(offset)),
                  let y = Int32(exactly: Int64(second) * Int64(offset)) else { return nil }
            return SIMD2(x, y)
        }
        guard let startX = clippedStart(firstX, secondX, offset: clippedOrigin.x),
              let startY = clippedStart(firstY, secondY, offset: clippedOrigin.y) else { return false }
        return drawRectangle(first: first, second: second, startX: startX, stepX: SIMD2(firstX, secondX),
                             startY: startY, stepY: SIMD2(firstY, secondY),
                             packedWeights: packedWeights, multiplier: multiplier, additive: additive, target: &target)
    }

    /// Draw a rectangle after the caller resolves clipping and scan coordinates.
    /// All rows must succeed before the destination is replaced.
    package static func drawRectangle(first: [[SIMD4<UInt8>]], second: [[SIMD4<UInt8>]],
                                      startX: SIMD2<Int32>, stepX: SIMD2<Int32>,
                                      startY: SIMD2<Int32>, stepY: SIMD2<Int32>,
                                      packedWeights: UInt32, multiplier: SIMD4<UInt8>,
                                      additive: SIMD4<UInt8>, target: inout [[SIMD4<UInt8>]]) -> Bool {
        guard let width = target.first?.count, (1...8192).contains(width),
              target.count <= 16_777_216 / width,
              target.allSatisfy({ $0.count == width }) else { return false }
        var result = target
        var positionY = startY
        for row in result.indices {
            let firstY = Int(positionY.x >> 16)
            let secondY = Int(positionY.y >> 16)
            guard first.indices.contains(firstY), second.indices.contains(secondY),
                  drawRow(first: first[firstY], second: second[secondY], start: startX, step: stepX,
                          packedWeights: packedWeights, multiplier: multiplier, additive: additive,
                          target: &result[row]) else { return false }
            positionY = positionY &+ stepY
        }
        target = result
        return true
    }

    /// Color adjustment and default target blend at 0x53c9ad–0x53ca42.
    /// Multipliers are the scanner's prepared values, after its initial byte adjustment.
    package static func blendOntoTarget(source: SIMD4<Int16>, target: SIMD4<UInt8>,
                                       multiplier: SIMD4<UInt8> = SIMD4(repeating: 128),
                                       additive: SIMD4<UInt8> = .zero) -> SIMD4<UInt8> {
        var adjusted = SIMD4<UInt16>.zero
        let multiply = multiplier != SIMD4(repeating: 128)
        for lane in 0..<4 {
            var word = UInt16(bitPattern: source[lane])
            if multiply { word = (word &* UInt16(multiplier[lane])) >> 7 }
            // paddusb changes only the low byte of each word.
            let low = UInt8(clamping: Int(word & 0xff) + Int(additive[lane]))
            adjusted[lane] = (word & 0xff00) | UInt16(low)
        }
        // paddd with 0x00010001 allows carry from lane 2 into lane 3.
        let highPair = UInt32(adjusted.z) | (UInt32(adjusted.w) << 16)
        let weight = Int16((highPair &+ 0x00010001) >> 17)
        var result = SIMD4<UInt8>.zero
        for lane in 0..<4 {
            let destination = Int(target[lane])
            let delta = Int16(clamping: Int(Int16(bitPattern: adjusted[lane])) - destination)
            let scaled = (delta &* weight) >> 7
            result[lane] = UInt8(clamping: destination + Int(scaled))
        }
        return result
    }

    package static func evaluate(source: SIMD4<UInt8>, secondaryLowByte: UInt8,
                                 maskWords: SIMD4<UInt16>, weights: SIMD4<UInt8>) -> SIMD4<Int16> {
        var result = SIMD4<Int16>.zero
        for lane in 0..<4 {
            let sourceWord = UInt16(source[lane])
            let sample = lane == 3 ? UInt16(secondaryLowByte) : 0
            let masked = (sourceWord &* (maskWords[lane] | sample)) >> 8
            let delta = Int16(masked) - Int16(sourceWord)
            let scaled = (delta &* Int16(weights[lane])) >> 7
            result[lane] = Int16(clamping: Int(sourceWord) + Int(scaled))
        }
        return result
    }
}

/// Vertex inputs after the original scanner has scaled texture coordinates.
package struct TwoTextureScanQuad {
    package let x: SIMD4<Float>
    package let y: SIMD4<Float>

    package init(x: SIMD4<Float>, y: SIMD4<Float>) {
        self.x = x
        self.y = y
    }

    // 0x535518 tests the two pairs of equal coordinates on each axis.
    var isAxisAligned: Bool {
        x[0] == x[3] && x[1] == x[2] && y[0] == y[1] && y[2] == y[3]
    }

    // 0x53534c compares diagonal differences between the target and one texture.
    func matchesSpan(of other: Self) -> Bool {
        let dx = x[2] - x[0], dy = y[2] - y[0]
        let otherDX = other.x[2] - other.x[0], otherDY = other.y[2] - other.y[0]
        let tolerance = Float(bitPattern: 0x39000000)
        return dx >= 0 && dy >= 0 && otherDX >= 0 && otherDY >= 0
            && abs(dx - otherDX) < tolerance && abs(dy - otherDY) < tolerance
    }

    /// Geometry selector at 0x53b6c0, for draws with exactly four vertices.
    package static func selector(target: Self, first: Self, second: Self) -> Int {
        guard target.isAxisAligned, first.isAxisAligned, second.isAxisAligned else { return 2 }
        return target.matchesSpan(of: first) && target.matchesSpan(of: second) ? 0 : 1
    }
}

/// Axis-aligned scan bounds before pixel sampling; this is not a draw decision.
package enum SingleTextureScanBounds {
    package struct CoordinateSpan {
        package let pixels: ClosedRange<Int>
        package let firstFixed: Int32
        package let stepFixed: Int32
    }
    // 0x532648 quantizes each vertex to 1/1024 after adding one half.
    package static func quantized(_ value: Float) -> Float? {
        guard value.isFinite, value >= 0, value <= 65536 else { return nil }
        return Float((Double(value) * 1024 + 0.5).rounded(.down) / 1024)
    }

    // 0x53382e and 0x533f6f use truncation after adding 0.99999237
    // at the leading edge and subtracting zero at the trailing edge.
    package static func inclusiveRange(start: Float, end: Float, limit: Int) -> ClosedRange<Int>? {
        guard (1...65536).contains(limit), let first = quantized(start), let last = quantized(end),
              last > first,
              let lower = Int(exactly: (Double(first) + Double(Float(bitPattern: 0x3f7fff80))).rounded(.towardZero)),
              let upper = Int(exactly: Double(last).rounded(.towardZero)) else { return nil }
        let clippedLower = max(0, lower), clippedUpper = min(limit - 1, upper)
        return clippedLower <= clippedUpper ? clippedLower...clippedUpper : nil
    }

    /// Candidate axis-aligned scan interpolation from 0x533fba–0x534034.
    /// The caller must establish the original vertices and texture coordinates.
    package static func coordinateSpan(start: Float, end: Float, sourceStart: Float,
                                       sourceEnd: Float, limit: Int) -> CoordinateSpan? {
        guard sourceStart.isFinite, sourceEnd.isFinite,
              let first = quantized(start), let last = quantized(end),
              let pixels = inclusiveRange(start: start, end: end, limit: limit) else { return nil }
        let extent = max(Float(1), last - first)
        let step = Float((Double(sourceEnd) - Double(sourceStart)) / Double(extent))
        let offset = max(Float(0), Float(pixels.lowerBound) - first)
        let initial = Float(Double(step) * Double(offset) + Double(sourceStart))
        func fixed(_ value: Float) -> Int32? {
            guard value.isFinite else { return nil }
            return Int32(exactly: (Double(value) * 65536 + 0.5).rounded(.down))
        }
        guard let startFixed = fixed(initial), let stepFixed = fixed(step), startFixed >= -65536 else { return nil }
        return .init(pixels: pixels, firstFixed: startFixed, stepFixed: stepFixed)
    }
}
