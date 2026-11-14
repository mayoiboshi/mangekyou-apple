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
                    (1...255).contains(layer.count) && (layer.first?.time ?? -1) >= 0 &&
                        zip(layer, layer.dropFirst()).allSatisfy { $0.time < $1.time }
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

    public func embeddedTexture(_ container: ScriptLocation, slot: Int32) -> (name: String, hasZeroAnchorOffset: Bool, size: CGSize?, location: ScriptLocation)? {
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
        let location = ScriptLocation(sourceFile: container.sourceFile, sourceSHA256: container.sourceSHA256,
            byteOffset: member.offset, byteLength: member.length, rangeSHA256: member.sha256, lineNumber: 1)
        return (name, member.image_anchor_words == [0, 0, 0], size, location)
    }

    package func hasTinyAnchorOffsetCandidate(_ container: ScriptLocation, slot: Int32) -> Bool {
        guard container.byteOffset == 0, container.sourceSHA256 == container.rangeSHA256,
              let words = texturesByContainer[container.sourceSHA256]?[Int(slot)]?.image_anchor_words else { return false }
        return Self.isTinyAnchorOffsetCandidate(words)
    }

    private static func isTinyAnchorOffsetCandidate(_ words: [UInt32]) -> Bool {
        words.count == 3 && words.contains(where: { $0 != 0 }) && words.allSatisfy {
            let value = Float(bitPattern: $0)
            return value.isFinite && abs(value) <= 1e-30
        }
    }

    package func hasNamedMessageSurface(_ container: ScriptLocation) -> Bool {
        guard container.byteOffset == 0, container.sourceSHA256 == container.rangeSHA256 else { return false }
        return entriesByContainer[container.sourceSHA256]?.contains {
            $0.name?.lowercased().hasPrefix("*messurface") == true
        } == true
    }

    public struct MotionKey: Decodable, Sendable {
        public struct DualTextureRawInputs: Decodable, Sendable {
            public let layout: String
            public let output_b1: Int32
            public let output_ac: Int32
            public let output_b2: Int32
            public let key_c8: Int32
            public let key_cc: Int32
        }
        public let time: Int32
        public let type: Int32
        public let offset: Int
        public let dual_texture_raw_inputs: DualTextureRawInputs?
        public fileprivate(set) var sampledDualTransferValue: Int32?
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
        let source_area_mode_input: UInt8?
        let source_area_interpolation_flag: Bool?
        let source_area_strength_input: Int32?
        let position_mode_input: UInt8?
        let position_strength_input: Int32?
        let time_control_inputs: [Int32]?
        fileprivate var sampledTranslation: (x: Double, y: Double)?
        fileprivate var translationUnsupported = false
        fileprivate var sampledOpacity: UInt8?
        /// The first source rectangle after supported literal sampling; nil means unresolved.
        public fileprivate(set) var sampledFirstSourceArea: [Float]?

        enum CodingKeys: String, CodingKey {
            case time, type, offset, texture_numbers, source_areas, transform_fields, blend, sampling, type1_color_inputs, type11_color_inputs, dual_texture_raw_inputs
            case literal_opacity_input, opacity_mode_input, source_area_mode_input, source_area_interpolation_flag
            case source_area_strength_input
            case anchor_ratio_inputs, position_mode_input, position_strength_input
            case time_control_inputs
        }
    }

    public func hasNoActiveDrawKey(_ container: ScriptLocation, selectedMember: Int32, time: Int32) -> Bool {
        // A known timeline emits nothing before its first key. Type 0 also emits no draw (0x587a32).
        motionKeys(container, selectedMember: selectedMember, time: time)?
            .allSatisfy { $0.type == 0 } == true
    }

    public func motionKeys(_ container: ScriptLocation, selectedMember: Int32, time: Int32) -> [MotionKey]? {
        guard container.byteOffset == 0, container.sourceSHA256 == container.rangeSHA256,
              let layers = validTimelines[container.sourceSHA256]?[Int(selectedMember)] else { return nil }
        return sampleMotion(layers, container: container, selectedMember: selectedMember, time: Double(time))
    }

    /// Sample a frozen candidate snapshot using the saved per-layer times.
    /// This does not advance the saved auxiliary state or establish original playback equivalence.
    public func motionKeysAtSavedLayerTimesCandidate(_ container: ScriptLocation, selectedMember: Int32,
                                                      layerTimes: [Int32]) -> [MotionKey]? {
        guard layerTimes.count == 256, layerTimes.allSatisfy({ $0 >= 0 }),
              container.byteOffset == 0, container.sourceSHA256 == container.rangeSHA256,
              let layers = validTimelines[container.sourceSHA256]?[Int(selectedMember)],
              layers.count <= layerTimes.count else { return nil }
        return sampleMotion(layers, container: container, selectedMember: selectedMember, time: 0,
                            savedLayerTimes: layerTimes)
    }

    /// Restricted research candidate for one integer clock increment. Only a single
    /// literal backward loop is modeled; terminal, scheduler, and original equivalence remain unsupported.
    public func advanceSavedLayerTimesCandidate(_ container: ScriptLocation, selectedMember: Int32,
                                                 layerTimes: [Int32], auxiliary: [Int32], delta: Int32)
        -> (times: [Int32], auxiliary: [Int32], keys: [MotionKey])? {
        let exactLimit: Int32 = 16_777_216
        guard (1...100_000).contains(delta), layerTimes.count == 256, auxiliary.count == 256,
              layerTimes.allSatisfy({ (0...exactLimit).contains($0) }),
              auxiliary.allSatisfy({ (0...exactLimit).contains($0) }),
              container.byteOffset == 0, container.sourceSHA256 == container.rangeSHA256,
              let layers = validTimelines[container.sourceSHA256]?[Int(selectedMember)] else { return nil }
        var times = layerTimes, remaining = auxiliary
        for (index, layer) in layers.enumerated() {
            let current = times[index]
            guard let active = layer.lastIndex(where: { $0.time <= current }),
                  active + 1 < layer.count,
                  layer[active].time_control_inputs == [0, 0, 0, 0] else { return nil }
            let amount = max(0, delta - remaining[index])
            let next = Int64(current) + Int64(amount)
            guard next <= Int64(exactLimit), let last = layer.last,
                  next < Int64(last.time) else { return nil }
            let crossed = Array(layer[(active + 1)...].prefix(while: { Int64($0.time) <= next }))
            var destination = next
            if let control = crossed.last, control.time_control_inputs != [0, 0, 0, 0] {
                // Native control 1 with zero condition and alternate-variable inputs
                // uses the literal target index and carries excess time once.
                guard crossed.dropLast().allSatisfy({ $0.time_control_inputs == [0, 0, 0, 0] }),
                      let inputs = control.time_control_inputs, inputs.count == 4,
                      inputs[0] == 1, inputs[2] == 0, inputs[3] == 0,
                      layer.indices.contains(Int(inputs[1])) else { return nil }
                let target = layer[Int(inputs[1])]
                guard target.time < control.time, target.time_control_inputs == [0, 0, 0, 0] else { return nil }
                destination = Int64(target.time) + next - Int64(control.time)
                // Do not fold repeated loops or skip controls reached after the jump.
                guard destination < Int64(control.time),
                      layer.filter({ $0.time > target.time && Int64($0.time) <= destination })
                        .allSatisfy({ $0.time_control_inputs == [0, 0, 0, 0] }) else { return nil }
            } else {
                guard crossed.allSatisfy({ $0.time_control_inputs == [0, 0, 0, 0] }) else { return nil }
            }
            remaining[index] = max(0, remaining[index] - delta)
            times[index] = Int32(destination)
        }
        guard let keys = sampleMotion(layers, container: container, selectedMember: selectedMember,
                                      time: 0, savedLayerTimes: times) else { return nil }
        return (times, remaining, keys)
    }

    /// Time-zero type-6 region with identity host transform and no perspective
    /// or visibility suppression. This does not establish the active region.
    public func identityHostType6RegionCandidate(_ key: MotionKey, origin: SIMD2<Int32>) -> (x: [Float], y: [Float])? {
        guard key.type == 6, key.time == 0, !key.translationUnsupported,
              key.position_mode_input == 0, key.time_control_inputs == [0, 0, 0, 0],
              // 0x58d8a4 copies this key field to output +0xb2. The
              // 0x55b654 projection gate leaves mode zero unsuppressed;
              // an absent or different mode cannot establish that condition.
              key.dual_texture_raw_inputs?.output_b2 == 0,
              let anchor = key.literalAnchorRatio, anchor.x == 0, anchor.y == 0,
              let f = key.transform_fields, f["0x8c"] == 0, f["0x98"] == 100,
              f["0x9c"] == 0, f["0xa0"] == 0, f["0xa4"] == 0, f["0xa8"] == 0,
              let dx = f["0x84"], let dy = f["0x88"], let w = f["0x90"], let h = f["0x94"],
              (-8192...8192).contains(dx), (-8192...8192).contains(dy),
              (1...8192).contains(w), (1...8192).contains(h),
              (-32768...32767).contains(origin.x), (-32768...32767).contains(origin.y) else { return nil }
        // 0x58b512/0x58b55a store the scaled inputs as float; 0x584e08–0x584e24
        // multiplies by 100 before constructing the type-6 quad.
        let width = (Float(w) * Float(0.01)) * Float(100)
        let height = (Float(h) * Float(0.01)) * Float(100)
        let x0 = Float(origin.x) + Float(dx), y0 = Float(origin.y) + Float(dy)
        let x1 = x0 + width, y1 = y0 + height
        return (x: [x0, x1, x1, x0], y: [y0, y0, y1, y1])
    }

    /// Preserve the original layer clock's fractional part for geometry sampling.
    public func motionKeysAtFractionalTime(_ container: ScriptLocation, selectedMember: Int32, time: Float) -> [MotionKey]? {
        guard time.isFinite, container.byteOffset == 0, container.sourceSHA256 == container.rangeSHA256,
              let layers = validTimelines[container.sourceSHA256]?[Int(selectedMember)] else { return nil }
        return sampleMotion(layers, container: container, selectedMember: selectedMember, time: Double(time))
    }

    package func samplePartialMotion(_ container: ScriptLocation, selectedMember: Int32, time: Int32) -> [MotionKey]? {
        guard container.byteOffset == 0, container.sourceSHA256 == container.rangeSHA256,
              let layers = entriesByContainer[container.sourceSHA256]?.first(where: {
                  $0.partial_motion_timelines != nil
              })?.partial_motion_timelines?[Int(selectedMember)],
              (1...256).contains(layers.count), layers.allSatisfy({ layer in
                  (1...255).contains(layer.count) && (layer.first?.time ?? -1) >= 0 &&
                        zip(layer, layer.dropFirst()).allSatisfy { $0.time < $1.time }
              }) else { return nil }
        return sampleMotion(layers, container: container, selectedMember: selectedMember, time: Double(time))
    }

    private func sampleMotion(_ layers: [[MotionKey]], container: ScriptLocation,
                              selectedMember: Int32, time: Double,
                              savedLayerTimes: [Int32]? = nil) -> [MotionKey]? {
        guard time >= 0 else { return nil }
        return layers.enumerated().compactMap { entry -> MotionKey? in
            let (layerIndex, layer) = entry
            let time = savedLayerTimes.map { Double($0[layerIndex]) } ?? time
            let sampleTime: Double
            if savedLayerTimes != nil {
                // Saved values already represent each layer's selected time;
                // applying the global-clock loop candidate again would change them.
                sampleTime = time
            } else if layer.allSatisfy({ $0.time_control_inputs?.count == 4 }),
               let control = layer.first(where: { ($0.time_control_inputs?.first ?? 0) != 0 }),
               let inputs = control.time_control_inputs,
               inputs[0] == 1, inputs[2] == 0, inputs[3] == 0,
               layer.indices.contains(Int(inputs[1])),
               case let start = layer[Int(inputs[1])].time, start < control.time {
                // Zero disables both variable lookups. The literal target is
                // +0xd4, and the jump carries excess time (0x57f7c7–0x57f8cf).
                let period = Double(control.time) - Double(start)
                sampleTime = time < Double(control.time) ? time : Double(start) + (time - Double(control.time)).truncatingRemainder(dividingBy: period)
            } else if container.sourceSHA256 == "5b0f2bc31cc6b14311642df53590c1efd3edec3b6a032e13b90424ce70e99b03",
               selectedMember == 0, layer.first?.offset == 2133,
               layer.count == 4, layer[1].offset == 2573, layer[1].time == 1000 {
                // Older recipes omit the audited default action's control.
                sampleTime = time.truncatingRemainder(dividingBy: 1000)
            } else {
                sampleTime = time
            }
            // 0x58d685–0x58d698 clears only the current layer before its first key.
            var low = 0
            var high = layer.count
            while low < high {
                let middle = (low + high) / 2
                if Double(layer[middle].time) <= sampleTime {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            guard low > 0 else { return nil }
            let index = low - 1
            var key = layer[index]
            if let input = key.dual_texture_raw_inputs, input.layout == "ablayer18",
               (0...255).contains(input.key_c8) {
                if sampleTime == Double(key.time) || key.opacity_mode_input == 0 || index == layer.count - 1 {
                    key.sampledDualTransferValue = input.key_c8
                } else if key.opacity_mode_input == 1,
                          let next = layer[index + 1].dual_texture_raw_inputs,
                          next.layout == input.layout, (0...255).contains(next.key_c8) {
                    let duration = Int64(layer[index + 1].time) - Int64(key.time)
                    let fraction = Float(sampleTime - Double(key.time)) / Float(duration)
                    let sampled = Float(input.key_c8) * (1 - fraction) + Float(next.key_c8) * fraction
                    key.sampledDualTransferValue = Int32(sampled.rounded(.toNearestOrEven))
                }
            }
            if sampleTime == Double(key.time) || key.opacity_mode_input == 0 || index == layer.count - 1 {
                key.sampledOpacity = key.literal_opacity_input
            } else if key.opacity_mode_input == 1, let start = key.literal_opacity_input,
                      let end = layer[index + 1].literal_opacity_input {
                let duration = Int64(layer[index + 1].time) - Int64(key.time)
                let fraction = Float(sampleTime - Double(key.time)) / Float(duration)
                // 0x50b9e4 followed by 0x50a840 with the default rounding mode.
                let opacity = Float(start) * (1 - fraction) + Float(end) * fraction
                key.sampledOpacity = UInt8(clamping: Int(opacity.rounded(.toNearestOrEven)))
            }
            if sampleTime > Double(key.time), index < layer.count - 1, let mode = key.position_mode_input, mode != 0 {
                let next = layer[index + 1]
                let fraction = Float(sampleTime - Double(key.time)) / Float(Int64(next.time) - Int64(key.time))
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
            if let mode = key.source_area_mode_input, let flag = key.source_area_interpolation_flag,
               let source = key.source_areas?.first, source.count == 4,
               source.allSatisfy({ (-32768...32767).contains($0) }) {
                // The special modes take a separate branch before the flag test (0x58ad97).
                if mode == 0 || (!flag && ![2, 5, 9, 10, 11].contains(mode)) {
                    key.sampledFirstSourceArea = source.map(Float.init)
                } else if mode == 1, flag {
                    let next = index + 1 < layer.count ? layer[index + 1] : key
                    if let target = next.source_areas?.first, target.count == 4,
                       target.allSatisfy({ (-32768...32767).contains($0) }) {
                        let fraction: Float = next.time == key.time ? 0 :
                            Float(sampleTime - Double(key.time)) / Float(Int64(next.time) - Int64(key.time))
                        key.sampledFirstSourceArea = zip(source, target).map {
                            Float($0) * (1 - fraction) + Float($1) * fraction
                        }
                    }
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
        let areaIsFull = key.source_area_mode_input == nil
            ? key.source_areas?.first == [0, 0, 0, 0]
            : key.sampledFirstSourceArea == [0, 0, 0, 0]
        guard key.type == 4, areaIsFull,
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
    package func windowTextureIsOffCanvas(_ layer: ScriptMachine.StaticImageLayer, offsetY: CGFloat, canvasHeight: Int) -> Bool {
        guard layer.resource.sourceSHA256 == "49c040e37eebc295e9fc2b8fdf9db40e70cc773dd41ab9ae486e95dd84cdda39",
              layer.priority == 1500, layer.selectedMember == 0, layer.boundRasterPreview == nil,
              !layer.unappliedTransform, layer.alignmentXPercent == 0, layer.alignmentYPercent == 0,
              layer.scaleXPercent == 100, layer.scaleYPercent == 100,
              let time = layer.motionElapsedTicks, let keys = motionKeys(layer.resource, selectedMember: 0, time: time),
              keys.map(\.type) == [16, 4, 17],
              let texture = embeddedTexture(layer.resource, slot: 0), texture.hasZeroAnchorOffset,
              let size = texture.size, keys[1].texture_numbers == [0, 0],
              let rect = fullTextureRectangle(keys[1], size: size,
                  host: CGAffineTransform(translationX: CGFloat(layer.x), y: CGFloat(layer.y))) else { return false }
        // In this audited action the scope changes Y and alpha only.
        return rect.minY + offsetY >= CGFloat(canvasHeight)
    }

    package static func sampleDialogueWindow(closing: Bool, ticks: Int32) -> (y: CGFloat, alpha: UInt8) {
        // The audited *Enable and *Disable keys use modes 3 and 4, respectively.
        let fraction = Float(min(ticks, 250)) / 250
        let progress = closing ? fraction : 1 - fraction
        return (CGFloat(40 * pow(progress, 2.4)),
                UInt8(clamping: Int((255 * (1 - progress)).rounded(.toNearestOrEven))))
    }

    package func drawScopedTexturePreview(_ entries: [(texture: MotionKey, states: [MotionKey])],
                                          container: Data, boundTextures: [Int32: Data], origin: SIMD2<Int>,
                                          hostScale: SIMD2<Double>, anchorOverride: SIMD2<Double>?,
                                          layerOpacity: UInt8, sampling2CandidateSlot: Int32? = nil,
                                          allowTinyAnchorCandidate: Bool = false,
                                          canvas: inout [[SIMD4<UInt8>]]) throws -> Bool {
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
                boundTextures: boundTextures, origin: origin, hostScale: hostScale,
                anchorOverride: anchorOverride, layerOpacity: layerOpacity, states: entry.states,
                sampling2CandidateSlot: sampling2CandidateSlot, allowTinyAnchorCandidate: allowTinyAnchorCandidate, canvas: &staged)
            covered = covered || drew
        }
        if covered { canvas = staged }
        return covered
    }

    package func drawFullTexturePreview(_ key: MotionKey, container data: Data,
                                        boundTextures: [Int32: Data] = [:],
                                        origin: SIMD2<Int>, hostScale: SIMD2<Double> = SIMD2(1, 1),
                                        anchorOverride: SIMD2<Double>? = nil,
                                        layerOpacity: UInt8 = 255,
                                        states: [MotionKey] = [],
                                        sampling2CandidateSlot: Int32? = nil,
                                        allowTinyAnchorCandidate: Bool = false,
                                        canvas: inout [[SIMD4<UInt8>]]) throws -> Bool {
        guard key.type == 4 else { throw ResourceError.rejected("unsupported_texture_preview_key") }
        guard key.blend != nil, key.sampling != nil,
              states.allSatisfy({ $0.blend != nil && $0.sampling != nil }) else {
            throw ResourceError.rejected("texture_preview_recipe_missing_raster_modes")
        }
        guard let modes = composedRasterModes(texture: key, states: states),
              (modes.blend == 1 || modes.blend == 4) else {
            throw ResourceError.rejected("unsupported_texture_preview_raster_modes")
        }
        let sampling2Candidate = modes.sampling == 2 && modes.blend == 1 &&
            sampling2CandidateSlot != nil && key.texture_numbers?.first == sampling2CandidateSlot &&
            sampling2CandidateSlot.flatMap { boundTextures[$0] } != nil
        guard modes.sampling == 0 || sampling2Candidate else {
            throw ResourceError.rejected("unsupported_texture_preview_raster_modes")
        }
        guard let keyOpacity = composedOpacity(texture: key, states: states) else {
            throw ResourceError.rejected("unsupported_texture_preview_opacity")
        }
        guard modes.blend != 4 || (keyOpacity == 255 && layerOpacity == 255) else {
            throw ResourceError.rejected("screen_texture_preview_opacity_unsupported")
        }
        let payload: Data
        var decodedRaster: ResourceImage?
        if let slot = key.texture_numbers?.first, let bound = boundTextures[slot] {
            payload = bound
            decodedRaster = try ResourceImage.decode(payload)
        } else {
            guard let slot = key.texture_numbers?.first,
                  let member = texturesByContainer[ImageMemberRecipe.digest(data)]?[Int(slot)],
                  member.image_anchor_words == [0, 0, 0] || (allowTinyAnchorCandidate &&
                    member.image_anchor_words.map(Self.isTinyAnchorOffsetCandidate) == true) else {
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
        let area: [Float]?
        if key.source_area_mode_input == nil {
            // Older recipes did not preserve the rectangle mode. Only retain
            // their established all-zero full-texture profile.
            area = key.source_areas?.first == [0, 0, 0, 0] ? [0, 0, 0, 0] : nil
        } else {
            area = key.sampledFirstSourceArea
        }
        guard let area, area.count == 4, area.allSatisfy(\.isFinite) else {
            throw ResourceError.rejected("unsupported_texture_source_area")
        }
        let fullArea = area == [0, 0, 0, 0]
        guard !sampling2Candidate || (fullArea && decodedRaster != nil) else {
            throw ResourceError.rejected("sampling2_preview_requires_full_bound_texture")
        }
        if !fullArea, area.contains(where: { Int(exactly: $0) == nil }) {
            // The selected 0x5342c8 branch uses a direct scan when the
            // quantized source and target spans match. Keep this candidate
            // limited to unscaled, zero-origin source rectangles.
            guard modes.blend == 4, states.isEmpty, decodedRaster == nil,
                  area[0] == 0, area[1] == 0, area[2] > 0, area[3] > 0,
                  area[2] <= Float(size.width), area[3] <= Float(size.height),
                  hostScale == SIMD2(1, 1), anchorOverride == nil,
                  let anchor = key.literalAnchorRatio, anchor.x == 0, anchor.y == 0,
                  let local = axisAlignedState([key]), local.scaleX == 1, local.scaleY == 1,
                  let left = Int(exactly: local.x), let top = Int(exactly: local.y),
                  (-65536...65536).contains(origin.x), (-65536...65536).contains(origin.y),
                  (-65536...65536).contains(left), (-65536...65536).contains(top),
                  let canvasWidth = canvas.first?.count, !canvas.isEmpty,
                  canvas.allSatisfy({ $0.count == canvasWidth }),
                  let x = Int32(exactly: origin.x + left), let y = Int32(exactly: origin.y + top),
                  x >= 0, y >= 0,
                  let targetWidth = SingleTextureScanBounds.quantized(area[2]),
                  let targetHeight = SingleTextureScanBounds.quantized(area[3]),
                  let sourceWidth = SingleTextureScanBounds.quantized(Float(area[2] / Float(size.width)) * Float(size.width)),
                  let sourceHeight = SingleTextureScanBounds.quantized(Float(area[3] / Float(size.height)) * Float(size.height)),
                  targetWidth == sourceWidth, targetHeight == sourceHeight,
                  let horizontal = SingleTextureScanBounds.inclusiveRange(start: Float(x), end: Float(x) + area[2], limit: canvasWidth),
                  let vertical = SingleTextureScanBounds.inclusiveRange(start: Float(y), end: Float(y) + area[3], limit: canvas.count),
                  horizontal.lowerBound >= Int(x), vertical.lowerBound >= Int(y),
                  horizontal.upperBound - Int(x) < Int(size.width),
                  vertical.upperBound - Int(y) < Int(size.height) else {
                throw ResourceError.rejected("unsupported_fractional_texture_geometry")
            }
            var covered = false
            for row in vertical {
                for column in horizontal {
                    let source = pixels[row - Int(y)][column - Int(x)]
                    guard source.w != 0 else { continue }
                    covered = true
                    canvas[row][column] = TwoTexturePixel.screenOntoTarget(source: source, target: canvas[row][column])
                }
            }
            return covered
        }
        let sourceArea = fullArea ? [0, 0, Int(size.width), Int(size.height)] : area.compactMap { Int(exactly: $0) }
        guard sourceArea.count == 4, sourceArea.allSatisfy({ $0 >= 0 }),
              sourceArea[0] <= Int(size.width), sourceArea[1] <= Int(size.height),
              sourceArea[2] <= Int(size.width) - sourceArea[0],
              sourceArea[3] <= Int(size.height) - sourceArea[1] else {
            throw ResourceError.rejected("unsupported_texture_source_area")
        }
        guard sourceArea[2] > 0, sourceArea[3] > 0 else { return false }
        guard (fullArea && modes.blend == 1) || decodedRaster == nil else {
            throw ResourceError.rejected("unsupported_texture_preview_pixel_format")
        }
        let host = CGAffineTransform(translationX: CGFloat(origin.x), y: CGFloat(origin.y))
            .scaledBy(x: hostScale.x, y: hostScale.y)
        let localRect: CGRect?
        if fullArea {
            localRect = fullTextureRectangle(key, size: size, host: host, anchorOverride: anchorOverride)
        } else if let anchor = key.literalAnchorRatio, let local = axisAlignedState([key]),
                  local.scaleX > 0, local.scaleY > 0 {
            let w = Double(sourceArea[2]) * local.scaleX, h = Double(sourceArea[3]) * local.scaleY
            localRect = CGRect(x: local.x - (anchorOverride?.x ?? anchor.x) * w,
                               y: local.y - (anchorOverride?.y ?? anchor.y) * h,
                               width: w, height: h).applying(host)
        } else { localRect = nil }
        guard let localRect,
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
        guard (fullArea && modes.blend == 1) ||
                          (hostScale.x == 1 && hostScale.y == 1 && state.scaleX == 1 && state.scaleY == 1 &&
                           rasterWidth == sourceArea[2] && rasterHeight == sourceArea[3]) else {
            throw ResourceError.rejected("scaled_texture_source_area_unsupported")
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
                interpolation: sampling2Candidate ? .low : .none,
                canvas: &canvas)
        }
        var coveredPixels = false
        for y in yStart..<yEnd {
            let sampleY = hostScale.y < 0 ? rasterHeight - 1 - y : y
            let row = pixels[sourceArea[1] + sampleY * sourceArea[3] / rasterHeight]
            for x in xStart..<xEnd {
                let sampleX = hostScale.x < 0 ? rasterWidth - 1 - x : x
                let source = row[sourceArea[0] + sampleX * sourceArea[2] / rasterWidth]
                let alpha = (Int(source.w) * opacity + 127) / 255
                guard alpha != 0 else { continue }
                coveredPixels = true
                if modes.blend == 4 {
                    canvas[top + y][left + x] = TwoTexturePixel.screenOntoTarget(
                        source: source, target: canvas[top + y][left + x])
                } else {
                    canvas[top + y][left + x] = TwoTexturePixel.blendOntoTarget(
                        source: SIMD4(Int16(source.x), Int16(source.y), Int16(source.z), Int16(alpha)),
                        target: canvas[top + y][left + x])
                }
            }
        }
        return coveredPixels
    }

    /// Explicit preview candidate for the audited center-text type-10 path.
    /// The direct command-3 mask is known; branch selection, filtering and
    /// final destination blending remain unverified against the original.
    package func drawCenterTextTransitionCandidate(_ key: MotionKey, container data: Data,
                                                    messageSurface: Data, origin: SIMD2<Int>,
                                                    canvas: inout [[SIMD4<UInt8>]]) throws -> Bool {
        let digest = ImageMemberRecipe.digest(data)
        guard digest == "97bb05fa8aaaff094f9ef12978d6fca0c7af6bd3081a01bbedd7ae5c02902a68",
              key.type == 10, key.blend == 0, key.sampling == 2,
              key.texture_numbers == [0, 1], key.source_areas == [[0, 0, 0, 0], [0, 0, 0, 0]],
              let anchor = key.literalAnchorRatio, anchor.x == 0.5, anchor.y == 0.5,
              let transform = axisAlignedState([key]), transform.x == 0, transform.y == 0,
              transform.scaleX == 1, transform.scaleY == 1, key.sampledOpacity == 255,
              let input = key.dual_texture_raw_inputs, input.layout == "ablayer18",
              input.output_b1 == 0, input.output_ac == 0, input.output_b2 == 0,
              (input.key_cc == 4 || input.key_cc == 132), let value = key.sampledDualTransferValue,
              let prepared = TwoTexturePixel.command3Threshold(value: value, rawMode: UInt32(input.key_cc)),
              let textures = texturesByContainer[digest], let surfaceMember = textures[0],
              surfaceMember.name?.lowercased().hasPrefix("*messurface") == true,
              let fadeMember = textures[1], fadeMember.name?.lowercased() == "fade.png",
              let canvasWidth = canvas.first?.count, (1...4096).contains(canvasWidth),
              (1...4096).contains(canvas.count), canvas.count <= 4_194_304 / canvasWidth,
              canvas.allSatisfy({ $0.count == canvasWidth }) else {
            throw ResourceError.rejected("center_transition_inputs_unsupported")
        }
        let source = try ResourceImage.straightPNGPixels(messageSurface)
        let fade = try ResourceImage.decode(fadeMember.payload(data)).opaqueCanvas(over: CGColor(gray: 0, alpha: 1))
        guard let sourceWidth = source.first?.count, (1...4096).contains(sourceWidth),
              (1...4096).contains(source.count), source.count <= 4_194_304 / sourceWidth,
              source.allSatisfy({ $0.count == sourceWidth }),
              let fadeWidth = fade.first?.count, fadeWidth > 0, !fade.isEmpty,
              fade.allSatisfy({ $0.count == fadeWidth }) else {
            throw ResourceError.rejected("center_transition_texture_bounds")
        }
        let left = Int((Double(origin.x) - Double(sourceWidth) * 0.5).rounded())
        let top = Int((Double(origin.y) - Double(source.count) * 0.5).rounded())
        let x0 = max(0, left), y0 = max(0, top)
        let x1 = min(canvasWidth, left + sourceWidth), y1 = min(canvas.count, top + source.count)
        guard x0 < x1, y0 < y1 else { return false }
        func sampleFade(_ x: Int, _ y: Int) -> UInt8 {
            // A bilinear local approximation; the original sampling branch is unknown.
            let fx = max(0, min(Double(fadeWidth - 1), (Double(x) + 0.5) * Double(fadeWidth) / Double(sourceWidth) - 0.5))
            let fy = max(0, min(Double(fade.count - 1), (Double(y) + 0.5) * Double(fade.count) / Double(source.count) - 0.5))
            let ax = Int(fx), ay = Int(fy), bx = min(ax + 1, fadeWidth - 1), by = min(ay + 1, fade.count - 1)
            let dx = fx - Double(ax), dy = fy - Double(ay)
            let upper = Double(fade[ay][ax].x) * (1 - dx) + Double(fade[ay][bx].x) * dx
            let lower = Double(fade[by][ax].x) * (1 - dx) + Double(fade[by][bx].x) * dx
            return UInt8(clamping: Int((upper * (1 - dy) + lower * dy).rounded()))
        }
        var covered = false
        for y in y0..<y1 {
            for x in x0..<x1 {
                let localX = x - left, localY = y - top
                let pixel = source[localY][localX]
                guard pixel.w > 0 else { continue }
                let mask = TwoTexturePixel.command3Mask(sample: sampleFade(localX, localY),
                    threshold: prepared.threshold, gain: prepared.gain, inverted: prepared.inverted)
                let weight = (Int(mask) >> 1) + (Int(mask) >> 7)
                let alpha = (Int(pixel.w) * weight) >> 7
                guard alpha > 0 else { continue }
                covered = true
                canvas[y][x] = TwoTexturePixel.blendOntoTarget(
                    source: SIMD4(Int16(pixel.x), Int16(pixel.y), Int16(pixel.z), Int16(alpha)), target: canvas[y][x])
            }
        }
        return covered
    }

    /// Draw a full type-11 PNG pair over the existing pixels of a clipped canvas.
    @discardableResult
    package func drawFullTwoTextureKey(_ key: MotionKey, container data: Data,
                                      boundTextures: [Int32: (data: Data, location: ScriptLocation)] = [:],
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
        func pixels(_ slot: Int32, _ member: ImageMemberRecipe) throws -> [[SIMD4<UInt8>]] {
            guard let bound = boundTextures[slot] else {
                return try ResourceImage.straightPNGPixels(member.payload(data))
            }
            guard bound.data.count <= 16 * 1024 * 1024,
                  bound.data.count == bound.location.byteLength,
                  ImageMemberRecipe.digest(bound.data) == bound.location.rangeSHA256 else {
                throw ResourceError.rejected("two_texture_bound_member_identity")
            }
            if InventoryScanner.signature(bound.data) == "JPEG" {
                return try ResourceImage.decode(bound.data).opaqueCanvas(over: CGColor(gray: 0, alpha: 1))
            }
            return try ResourceImage.straightPNGPixels(bound.data)
        }
        let first = try pixels(slots[0], firstMember)
        let second = try pixels(slots[1], secondMember)
        let colors = TwoTexturePixel.scannerColors(additiveRGB: UInt32(inputs[0]),
            multiplierRGB: UInt32(inputs[1]), multiplierAlpha: multiplierAlpha)
        guard let firstRow = first.first, let secondRow = second.first,
              let geometry = fullTwoTextureGeometry(key,
                  first: CGSize(width: firstRow.count, height: first.count),
                  second: CGSize(width: secondRow.count, height: second.count), origin: .zero),
              (0...1).contains(geometry.scanSelector) else {
            throw ResourceError.rejected("unsupported_two_texture_geometry")
        }
        // 0x53ed38 advances both equal-span sources by one pixel. The same
        // rectangle sampler yields unit steps when both sources match the target.
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
    package func whiteFlashPreview(_ key: MotionKey, container: ScriptLocation) -> (size: SIMD2<Int>, alpha: UInt8)? {
        guard container.byteOffset == 0, container.sourceSHA256 == container.rangeSHA256,
              key.type == 1, key.blend == 1, key.sampling == 0,
              let alpha = key.sampledOpacity, key.type1_color_inputs == [0xffffff, 0xffffff],
              let size = entriesByContainer[container.sourceSHA256]?.compactMap(\.motion_canvas_inputs).first,
              size.width == 1280, size.height == 720 else { return nil }
        switch container.rangeSHA256 {
        case "dea47b18a5dac17a733523ca0a8c00167bf24217b168bf5330e8f11097f0d354":
            guard key.offset == 5649, key.opacity_mode_input == 0, alpha == 255,
                  key.transform_fields?["0x90"] == 0x10000107,
                  key.transform_fields?["0x94"] == 0x10000108 else { return nil }
        case "fec9d49e9c5fe248bb6ec76d6c60b87f93c87ed70533a9c829c6e8621d811370":
            guard key.offset == 5298, key.opacity_mode_input == 1,
                  key.transform_fields?["0x90"] == 1280,
                  key.transform_fields?["0x94"] == 720 else { return nil }
        case "1ac81465631f953bcd762639ea41a940a5c9ae1bc42ce438fdf776a88f4ab497":
            guard [762, 924].contains(key.offset), key.opacity_mode_input == 1,
                  key.transform_fields?["0x90"] == 0x10000107,
                  key.transform_fields?["0x94"] == 0x10000108 else { return nil }
        default:
            return nil
        }
        return (SIMD2(size.width, size.height), alpha)
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
        case "script/saveload/button_delete.b": staticMember = "削除ボタン_off.png"
        case "script/dialog/button_yes.b": staticMember = "確認_はい_off.png"
        case "script/dialog/button_no.b": staticMember = "確認_いいえ_off.png"
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
        let backgroundSlot: Int?
        switch path {
        case "avg/window/windowframe_window.b", "avg/window/windowframe_window02.b": backgroundSlot = 0
        case "script/dialog/message.b": backgroundSlot = 1
        default: backgroundSlot = nil
        }
        if let backgroundSlot, members.contains(where: { $0.image_slot != nil }) {
            let slots = texturesByContainer[digest]
            guard let pinnedBackground = slots?[backgroundSlot], pinnedBackground.name == background.name,
                  slots?[1 - backgroundSlot]?.name == surface.name else {
                throw ResourceError.rejected("abmp_interface_texture_slot_mismatch")
            }
            return try pinnedBackground.payload(data)
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
                    guard (1...8192).contains(dimensions.0), (1...8192).contains(dimensions.1) else {
                        throw ResourceError.rejected("theora_image_dimensions")
                    }
                } else if member.format == "IMOAVI" {
                    guard payload.starts(with: Data("IMOAVI".utf8)),
                          let width = member.width, let height = member.height,
                          (1...8192).contains(width), (1...8192).contains(height) else {
                        throw ResourceError.rejected("imoavi_image_recipe_required")
                    }
                    if let frames = member.imoavi_frame_references {
                        guard (1...255).contains(frames.count) else {
                            throw ResourceError.rejected("imoavi_frame_count")
                        }
                        var cursor = 0
                        for frame in frames {
                            guard frame.offset >= cursor, frame.offset <= payload.count,
                                  frame.length > 0, frame.length <= payload.count - frame.offset else {
                                throw ResourceError.rejected("imoavi_frame_range")
                            }
                            cursor = frame.offset + frame.length
                            let jpeg = payload.subdata(in: frame.offset..<cursor)
                            guard InventoryScanner.signature(jpeg) == "JPEG",
                                  ImageMemberRecipe.digest(jpeg) == frame.sha256 else {
                                throw ResourceError.rejected("imoavi_frame_identity")
                            }
                        }
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

    package func motionUpdateThreshold(_ container: ScriptLocation) -> Int32? {
        entriesByContainer[container.sourceSHA256]?.compactMap(\.motion_update_threshold).first?.effective_value
    }

    public func motionDurationInputs(_ container: ScriptLocation) -> (duration: Int32, loopStart: Int32)? {
        guard container.byteOffset == 0, container.sourceSHA256 == container.rangeSHA256,
              let input = entriesByContainer[container.sourceSHA256]?.compactMap(\.motion_duration_inputs).first else {
            return nil
        }
        return (input.duration, input.loop_start)
    }

    public func motionCanvasInputs(_ container: ScriptLocation) -> (width: Int32, height: Int32)? {
        guard container.byteOffset == 0, container.sourceSHA256 == container.rangeSHA256,
              let input = entriesByContainer[container.sourceSHA256]?.compactMap(\.motion_canvas_inputs).first,
              let width = Int32(exactly: input.width), let height = Int32(exactly: input.height) else { return nil }
        return (width, height)
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
    struct FrameReference: Decodable, Sendable {
        let offset: Int
        let length: Int
        let sha256: String
    }
    let imoavi_frame_references: [FrameReference]?
    let motion_canvas_inputs: MotionCanvasInputs?
    struct MotionDurationInputs: Decodable, Sendable { let duration: Int32; let loop_start: Int32 }
    let motion_duration_inputs: MotionDurationInputs?
    struct MotionUpdateThreshold: Decodable, Sendable { let effective_value: Int32 }
    let motion_update_threshold: MotionUpdateThreshold?
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
    let partial_motion_timelines: [Int: [[ScriptImageRecipe.MotionKey]]]?
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
