import Foundation
import CoreGraphics
import ImageIO

/// Bounded writers for the shared visual-object save layout. Object-specific
/// fixed records are supplied by a separate, fully mapped encoder.
package enum SaveVisualObjectEncoder {
    package struct TextureSlot: Sendable {
        package let name: String
        package let jpeg: Data?

        package init(name: String, jpeg: Data?) {
            self.name = name
            self.jpeg = jpeg
        }
    }

    package static func defaultGeneratorRecord() -> Data {
        var data = Data("vgene\0\0\0".utf8)
        append(Int32(3), to: &data)
        data.append(contentsOf: [0, 0, 2])
        for word: UInt32 in [1, 1, 0, 0, 0, 0, 0, 0, 0] {
            append(word, to: &data)
        }
        data.append(0)
        append(UInt32(0), to: &data)
        return data
    }

    /// Encode mapped g-command input fields when the caller also supplies the
    /// live interpolation outputs. Those output words depend on the generator
    /// clock and must not be guessed from the request alone.
    static func encodeGeneratorRecord(_ request: ScriptStorage.GeneratorRequest,
                                      outputWords: [UInt32]) throws -> Data {
        guard request.arguments.count == 8, outputWords.count == 3,
              (0...12).contains(request.arguments[0]),
              (0...2).contains(request.arguments[6]),
              (0...6).contains(request.arguments[7]) else {
            throw ResourceError.rejected("save_visual_generator_request_outside_profile")
        }
        let unit: Float
        switch request.arguments[6] {
        case 0: unit = 1
        case 1: unit = 0.01
        default: unit = 0.0027777778
        }
        let rawDuration = request.arguments[1]
        let duration = max(0, rawDuration)
        let normalizedDuration = duration == 0 ? Int32(1) : duration
        let persistent = request.persistent || rawDuration < 0
        func scaled(_ value: Int32) -> UInt32 {
            (Float(value) * unit).bitPattern
        }
        var data = Data("vgene\0\0\0".utf8)
        append(Int32(3), to: &data)
        data.append(UInt8(truncatingIfNeeded: request.arguments[0]))
        data.append(UInt8(truncatingIfNeeded: request.arguments[6]))
        data.append(UInt8(truncatingIfNeeded: request.arguments[7]))
        append(request.currentTime & 0x0fff_ffff, to: &data)
        append(UInt32(bitPattern: normalizedDuration), to: &data)
        append(UInt32(bitPattern: request.arguments[2]), to: &data)
        append(scaled(request.arguments[5]), to: &data)
        append(scaled(request.arguments[4]), to: &data)
        append(scaled(request.arguments[3]), to: &data)
        for word in outputWords { append(word, to: &data) }
        data.append(persistent ? 1 : 0)
        append(UInt32(0), to: &data)
        guard data.count == 56 else { throw ResourceError.rejected("save_visual_generator_record_length") }
        return data
    }

    /// Build the fixed img/simg prefix from the static constructor reset at
    /// 0x5ae1fc and its immediate setter calls. This is only a constructor
    /// baseline; callers must overlay every live object field before emission.
    package static func defaultImageFixedRecord() -> Data {
        var data = Data(repeating: 0, count: 0xA5E)
        func word(_ value: Int32, at offset: Int) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) {
                data.replaceSubrange(offset..<(offset + 4), with: $0)
            }
        }
        func byte(_ value: UInt8, at offset: Int) { data[offset] = value }
        word(10, at: 0)
        word(256, at: 0x804)
        word(100, at: 0x810)
        for offset in [0x8fd, 0x901, 0x905, 0x909, 0x90d, 0x911, 0x915, 0x919, 0x91d,
                       0x921, 0x925, 0x929, 0x92d, 0x931, 0x935, 0x939, 0x93d, 0x941,
                       0x945, 0x949, 0x94d] {
            word(0, at: offset)
        }
        for offset in [0x951, 0x955, 0x959, 0x95d, 0x961, 0x965, 0x969, 0x96d, 0x971] {
            word(100, at: offset)
        }
        word(Int32(bitPattern: 0xffff_d8f0), at: 0x8b5)
        word(Int32(bitPattern: 0xffff_d8f0), at: 0x8b9)
        word(0xff, at: 0x8bd)
        word(0xff, at: 0x8c1)
        word(0, at: 0x8c5)
        word(0, at: 0x8c9)
        word(1, at: 0x8f9)
        word(0xff, at: 0x9bd)
        word(0xff, at: 0x9c1)
        word(0xff, at: 0x9c5)
        word(0, at: 0x9c9)
        word(0, at: 0x9cd)
        word(0x00ff_ffff, at: 0x9d1)
        word(0x00ff_ffff, at: 0x9d5)
        word(0x00ff_ffff, at: 0x9d9)
        word(0, at: 0x9dd)
        word(0, at: 0x9e1)
        word(0, at: 0x9e5)
        word(0, at: 0x9e9)
        word(0, at: 0x9ed)
        word(100, at: 0x9f1)
        byte(0, at: 0x9f9)
        byte(0, at: 0x9fa)
        byte(0, at: 0x9fb)
        byte(1, at: 0x9fd)
        word(2, at: 0x8b0)
        word(0, at: 0xa42)
        return data
    }

    /// Encode the shared image-library section that precedes img/btn/msg class
    /// payloads. The fixed 0xa5e block and all object fields must be supplied
    /// from a separately mapped state; this routine never invents them.
    package static func encodeImageLibrary(fixedRecord: Data, sourceName: String,
                                          textureSlots: [TextureSlot], soundNames: [String],
                                          auxiliaryNames: [String], auxiliaryBytes: Data,
                                          generatorRecords: [Data], generatorGroup: String,
                                          generatorGroupRecords: [Data] = [],
                                          userIntegers: [Int32], userStrings: [String],
                                          finalString: String) throws -> Data {
        guard fixedRecord.count == 0xA5E,
              textureSlots.count == 33, soundNames.count == 32, auxiliaryNames.count == 32,
              auxiliaryBytes.count == 256, generatorRecords.count == 4,
              ((generatorGroup.isEmpty && generatorGroupRecords.isEmpty) ||
               (generatorGroup == "mode" && generatorGroupRecords.count == 1)),
              userIntegers.count == 8, userStrings.count == 8 else {
            throw ResourceError.rejected("save_visual_image_library_shape")
        }
        for record in generatorRecords + generatorGroupRecords {
            guard record.count == 56, record.prefix(8).elementsEqual("vgene\0\0\0".utf8),
                  record.withUnsafeBytes({ Int32(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: Int32.self)) }) == 3 else {
                throw ResourceError.rejected("save_visual_generator_record_shape")
            }
        }
        var output = Data()
        func appendBounded(_ bytes: Data) throws {
            guard bytes.count <= SaveEnvelope.maxFileBytes - output.count else {
                throw ResourceError.rejected("save_visual_image_library_size_limit")
            }
            output.append(bytes)
        }
        func appendText(_ text: String) throws {
            guard text.utf8.count <= 8192, let units = Int16(exactly: text.utf16.count),
                  let bytes = text.data(using: .utf16LittleEndian) else {
                throw ResourceError.rejected("save_visual_image_library_string_limit")
            }
            append(units, to: &output)
            try appendBounded(bytes)
        }
        try appendBounded(fixedRecord)
        try appendText(sourceName)
        var embeddedBytes = 0
        for slot in textureSlots {
            try appendText(slot.name)
            let jpeg = slot.jpeg ?? Data()
            guard jpeg.count <= 16 * 1024 * 1024 - embeddedBytes,
                  jpeg.isEmpty || InventoryScanner.signature(Data(jpeg.prefix(16))) == "JPEG" else {
                throw ResourceError.rejected("save_visual_texture_jpeg_outside_profile")
            }
            embeddedBytes += jpeg.count
            guard let count = Int32(exactly: jpeg.count) else {
                throw ResourceError.rejected("save_visual_texture_length")
            }
            append(count, to: &output)
            try appendBounded(jpeg)
        }
        for name in soundNames { try appendText(name) }
        for name in auxiliaryNames { try appendText(name) }
        try appendBounded(auxiliaryBytes)
        for record in generatorRecords { try appendBounded(record) }
        try appendText(generatorGroup)
        for record in generatorGroupRecords { try appendBounded(record) }
        for (integer, string) in zip(userIntegers, userStrings) {
            append(integer, to: &output)
            try appendText(string)
        }
        try appendText(finalString)
        return output
    }

    package static func encodeImageObjectPayload(baseRecordWord: Int32, imageLibrary: Data) throws -> Data {
        try encodeObjectPayloadHeader(baseRecordWord: baseRecordWord, imageLibrary: imageLibrary)
    }

    package static func encodeDefaultImageObjectPayload(baseRecordWord: Int32, sourceName: String = "",
                                                        userIntegers: [Int32] = Array(repeating: 0, count: 8),
                                                        userStrings: [String] = Array(repeating: "", count: 8)) throws -> Data {
        let library = try encodeImageLibrary(fixedRecord: defaultImageFixedRecord(), sourceName: sourceName,
            textureSlots: Array(repeating: .init(name: "", jpeg: nil), count: 33),
            soundNames: Array(repeating: "", count: 32),
            auxiliaryNames: Array(repeating: "", count: 32), auxiliaryBytes: Data(repeating: 1, count: 256),
            generatorRecords: Array(repeating: defaultGeneratorRecord(), count: 4), generatorGroup: "",
            userIntegers: userIntegers, userStrings: userStrings, finalString: "")
        return try encodeImageObjectPayload(baseRecordWord: baseRecordWord, imageLibrary: library)
    }

    static func encodeImageObjectPayload(handle: UInt64, storage: ScriptStorage,
                                         repository: ScriptRepository?,
                                         jpegEncoder: (@Sendable (Data) throws -> Data)? = nil,
                                         researchVideoProfiles: [String: ResearchVideoSaveProfile] = [:]) throws -> Data {
        guard let image = storage.images[handle], let baseWord = storage.savedObjectBaseWords[handle] else {
            throw ResourceError.rejected("save_image_object_identity_unavailable")
        }
        let filter = image.generatorFilterRequests.last ?? ""
        let supportedGroup = filter == "mode" && image.generatorFilterModeClock != nil
        guard (filter.isEmpty || supportedGroup), image.filterOverrides.keys.allSatisfy({ (0..<32).contains($0) }) else {
            let descriptor = image.generatorFilterRequests.last ?? ""
            throw ResourceError.rejected("save_image_generator_filter_state_unmapped:generator_count=\(image.generatorFilterRequests.count):descriptor_utf16=\(descriptor.utf16.count):descriptor_sha256=\(Data(descriptor.utf8).sha256Hex):override_count=\(image.filterOverrides.count)")
        }
        guard (image.selectedMember == nil) == (image.motionStartTick == nil) else {
            throw ResourceError.rejected("save_image_action_identity_unavailable")
        }
        guard !image.colorTransitionActive else {
            throw ResourceError.rejected("save_image_color_transition_unmapped")
        }
        let researchVideo = image.researchVideoProfile(in: researchVideoProfiles)
        let nativeVideo = image.canUseStandaloneVideoClock && researchVideo == nil
        if nativeVideo {
            guard image.standaloneVideoLayerTick(at: storage.visualTicks) != nil else {
                throw ResourceError.rejected("save_standalone_video_clock_unverified")
            }
        } else if image.isTheoraResource {
            guard let profile = researchVideo, image.selectedMember == 0, image.memberCount == 1, image.enabled,
                  let snapshot = image.savedLayerTimeSnapshot, snapshot.visualTick == storage.visualTicks,
                  snapshot.times.count == 256, snapshot.auxiliary.count == 256,
                  snapshot.auxiliary[0] == 0,
                  Float(bitPattern: UInt32(bitPattern: snapshot.times[0])).isFinite,
                  Float(bitPattern: UInt32(bitPattern: snapshot.times[0])) >= 0,
                  Float(bitPattern: UInt32(bitPattern: snapshot.times[0])) < Float(profile.duration),
                  let elapsed = image.motionElapsedHundredths(at: storage.visualTicks), elapsed >= 0,
                  elapsed % 100 == 0,
                  Float(bitPattern: UInt32(bitPattern: snapshot.times[0])) == Float((elapsed / 100) % Int64(profile.duration)) else {
                throw ResourceError.rejected("save_image_theora_state_unmapped")
            }
        }
        guard !image.hasExtendedContainerMetadata || image.layerAuxiliaryFlags?.count == 256 else {
            let source = image.resource?.sourceFile ?? "none"
            let member = image.selectedMember.map(String.init) ?? "none"
            throw ResourceError.rejected(
                "save_image_extended_container_state_unmapped:resource=\(image.resourceName ?? "none"):source=\(source):member=\(member):member_count=\(image.memberCount):layer_flags=\(image.layerAuxiliaryFlags?.count ?? -1)")
        }
        if image.selectedMember != nil || image.motionStartTick != nil {
            guard image.layerClockRemainder == 0 else {
                throw ResourceError.rejected("save_image_action_clock_remainder_unmapped")
            }
            guard let snapshot = image.savedLayerTimeSnapshot,
                  snapshot.visualTick == storage.visualTicks,
                  snapshot.times.count == 256, snapshot.auxiliary.count == 256 else {
                let source = image.resource?.sourceSHA256.prefix(12) ?? "unbound"
                let member = image.selectedMember.map(String.init) ?? "none"
                let snapshotTick = image.savedLayerTimeSnapshot.map { String($0.visualTick) } ?? "none"
                let firstTimes = image.savedLayerTimeSnapshot?.times.prefix(4).map { String($0) }.joined(separator: ",") ?? "none"
                let firstAuxiliary = image.savedLayerTimeSnapshot?.auxiliary.prefix(4).map { String($0) }.joined(separator: ",") ?? "none"
                throw ResourceError.rejected(
                    "save_image_action_clock_unmapped:source=\(source):member=\(member):extended=\(image.hasExtendedContainerMetadata ? 1 : 0):flags=\(image.layerAuxiliaryFlags?.count ?? 0):animation_speed=\(image.animationSpeed ?? -1):playback_speed=\(image.playbackSpeed ?? -1):enabled=\(image.enabled ? 1 : 0):start=\(image.motionStartTick ?? -1):snapshot=\(snapshotTick):times=\(firstTimes):aux=\(firstAuxiliary):visual=\(storage.visualTicks)")
            }
        }
        guard (image.resource == nil) == (image.resourceName == nil),
              image.memberCount <= 1 || (image.hasExtendedContainerMetadata && image.resourceName != nil) else {
            throw ResourceError.rejected("save_image_resource_identity_unavailable")
        }
        let placement = image.placement ?? [0, 0, 0]
        let transform = image.transform ?? .init(depth: 0, scale: [100, 100, 100], rotation: [0, 0, 0], loop: 0)
        guard placement.count == 3, transform.scale.count == 3, transform.rotation.count == 3,
              transform.depth == 0, transform.rotation == [0, 0, 0], transform.loop == 0,
              (0..<3).allSatisfy({ (-16_777_216...16_777_216).contains(placement[$0]) &&
                  (-16_777_216...16_777_216).contains(transform.scale[$0]) }) else {
            throw ResourceError.rejected("save_image_transform_outside_profile")
        }
        let userIntegers = storage.buttonUserIntegers[handle] ?? [:]
        let userStrings = storage.buttonUserStrings[handle] ?? [:]
        guard userIntegers.keys.allSatisfy({ (0..<8).contains($0) }),
              userStrings.keys.allSatisfy({ (0..<8).contains($0) }) else {
            throw ResourceError.rejected("save_image_user_field_index_outside_profile")
        }

        var fixed = defaultImageFixedRecord()
        func store(_ value: Int32, at offsets: [Int]) {
            for offset in offsets { Self.append(value, at: offset, to: &fixed) }
        }
        store(placement[0], at: [0x8fd, 0x909, 0x915])
        store(placement[1], at: [0x901, 0x90d, 0x919])
        store(placement[2], at: [0x905, 0x911, 0x91d])
        store(transform.scale[0], at: [0x951, 0x955, 0x959])
        store(transform.scale[1], at: [0x95d, 0x961, 0x965])
        store(transform.scale[2], at: [0x969, 0x96d, 0x971])
        let motionMode = image.motion?.mode ?? image.savedPlacementMode ?? 1
        let motionStrength = image.motion?.strength ?? image.savedPlacementStrength ?? 100
        if let transition = storage.placementTransitions[handle] {
            guard ScriptStorage.PlacementTransition.canSample(mode: motionMode, strength: motionStrength),
                  transition.savedMode == nil || transition.savedMode == motionMode,
                  transition.duration > 0, transition.duration <= Int32.max / 1024,
                  transition.elapsed >= 0, transition.elapsed < transition.duration,
                  transition.destination.count == 3, let target = transition.destinationTransform,
                  target.depth == 0, target.rotation == [0, 0, 0], target.loop == 0,
                  target.scale.count == 3, transform.scale[2] == 100, target.scale[2] == 100,
                  (0..<3).allSatisfy({ (-16_777_216...16_777_216).contains(transition.destination[$0]) &&
                      (-16_777_216...16_777_216).contains(target.scale[$0]) }) else {
                let target = transition.destinationTransform
                throw ResourceError.rejected("save_image_active_placement_unmapped:mode=\(motionMode):saved_mode=\(transition.savedMode.map(String.init) ?? "none"):duration=\(transition.duration):elapsed=\(transition.elapsed):target_depth=\(target?.depth ?? -1):target_loop=\(target?.loop ?? -1):target_scale=\(target?.scale.map(String.init).joined(separator: ",") ?? "none"):target_rotation=\(target?.rotation.map(String.init).joined(separator: ",") ?? "none")")
            }
            let current = (0..<3).map {
                transition.sampleSavedAxis(from: placement[$0], to: transition.destination[$0],
                                           mode: motionMode, strength: motionStrength)
            }
            let currentScale = (0..<3).map {
                transition.sampleSavedAxis(from: transform.scale[$0], to: target.scale[$0],
                                           mode: motionMode, strength: motionStrength)
            }
            for (axis, offsets) in [[0x8fd, 0x909, 0x915], [0x901, 0x90d, 0x919], [0x905, 0x911, 0x91d]].enumerated() {
                store(current[axis], at: [offsets[0]])
                store(placement[axis], at: [offsets[1]])
                store(transition.destination[axis], at: [offsets[2]])
            }
            for (axis, offsets) in [[0x951, 0x955, 0x959], [0x95d, 0x961, 0x965], [0x969, 0x96d, 0x971]].enumerated() {
                store(currentScale[axis], at: [offsets[0]])
                store(transform.scale[axis], at: [offsets[1]])
                store(target.scale[axis], at: [offsets[2]])
            }
            store(transition.duration - transition.elapsed, at: [0x9e9])
            store(transition.duration, at: [0x9ed])
        }
        fixed[0x9fd] = motionMode
        store(motionStrength, at: [0x9f1])
        store(image.volume ?? 256, at: [0x804])
        store(image.selectedMember ?? 0, at: [0x80c])
        let nativeClock = nativeVideo || image.hasIndependentActionClock
        if nativeClock {
            // The native record stores the selected action, animation speed
            // and layer clock remainder at +0x808, +0x810 and +0x814.
            store(image.selectedMember ?? 0, at: [0x808])
            store(image.animationSpeed ?? 100, at: [0x810])
            store(0, at: [0x814])
        } else {
            store(image.animationSpeed ?? 0, at: [0x814])
        }
        store(image.playbackSpeed ?? 100, at: [0x8ac])
        if image.selectedMember != nil {
            guard let elapsed = image.motionElapsedHundredths(at: storage.visualTicks), elapsed >= 0,
                  let elapsedTicks = Int32(exactly: elapsed / 100) else {
                throw ResourceError.rejected("save_image_action_elapsed_unavailable")
            }
            if image.hasIndependentActionClock, elapsedTicks == 0, (image.animationSpeed ?? 100) != 100 {
                throw ResourceError.rejected("save_image_native_clock_at_origin_ambiguous")
            }
            store(elapsedTicks, at: [nativeClock ? 0x898 : 0x894])
            if !nativeClock { store(0, at: [0x810]) }
        }
        if image.restoredMotionThreshold != nil, !nativeClock {
            guard let clock = Int32(exactly: image.restoredMotionRemainder / 100) else {
                throw ResourceError.rejected("save_image_action_clock_remainder_unavailable")
            }
            store(clock, at: [0x810])
        }
        store(image.volumeType ?? 2, at: [0x8b0])
        // Native img mi writes object +0xbec, inside the fixed record starting at +0x338.
        fixed[0x8b4] = image.miFlag
        store(image.tabOrder ?? 0, at: [0x8cd])
        store(image.alignment?.x ?? 0, at: [0x8f1])
        store(image.alignment?.y ?? 0, at: [0x8f5])
        store(image.blendMode ?? 0, at: [0x9b5])
        store(image.textureFilter ?? 0, at: [0x9b9])
        store(image.inputMask ?? 0xff, at: [0x8bd])
        store(image.outputMask ?? 0xff, at: [0x8c1])
        store(image.drawChannel ?? 0, at: [0x8a0])
        store(image.colorMultiply ?? 0x00ff_ffff, at: [0x9d1, 0x9d5, 0x9d9])
        store(image.colorAdd ?? 0, at: [0x9dd, 0x9e1, 0x9e5])
        let drawGate = image.savedDrawGate ?? image.enabled
        fixed[0x9f9] = drawGate ? 1 : 0
        fixed[0x9fa] = image.enabled ? 1 : 0
        if let opacity = image.opacityEndpoint {
            guard opacity.duration > 0, opacity.remaining >= 0, opacity.remaining <= opacity.duration else {
                throw ResourceError.rejected("save_image_opacity_transition_invalid")
            }
            store(Int32(image.immediateOpacity), at: [0x9bd, 0x9c1])
            store(Int32(opacity.value), at: [0x9c5])
            store(opacity.remaining, at: [0x9c9])
            store(opacity.duration, at: [0x9cd])
            store(opacity.repeats, at: [0xa42])
        } else {
            store(Int32(image.immediateOpacity), at: [0x9bd, 0x9c1, 0x9c5])
            store(image.colorRepeatCount ?? 0, at: [0xa42])
        }
        if let snapshot = image.savedLayerTimeSnapshot {
            guard snapshot.visualTick == storage.visualTicks,
                  snapshot.times.count == 256, snapshot.auxiliary.count == 256 else {
                throw ResourceError.rejected("save_image_layer_clock_snapshot_mismatch")
            }
            for (index, word) in try SaveLayerClockWords.savedWords(fromRuntimeFloatBitPatterns: snapshot.times).enumerated() {
                Self.append(word, at: 4 + index * 4, to: &fixed)
            }
            for (index, word) in try SaveLayerClockWords.savedWords(fromRuntimeFloatBitPatterns: snapshot.auxiliary).enumerated() {
                Self.append(word, at: 0x404 + index * 4, to: &fixed)
            }
        }

        let imageNames = image.boundImageNames
        guard Set(imageNames.keys) == Set(image.boundImages.keys),
              imageNames.keys.allSatisfy({ (0..<33).contains($0) }) else {
            throw ResourceError.rejected("save_image_texture_name_mapping_incomplete")
        }
        let slots = try (0..<33).map { index -> TextureSlot in
            guard let name = imageNames[Int32(index)] else { return .init(name: "", jpeg: nil) }
            guard let location = image.boundImages[Int32(index)] else {
                throw ResourceError.rejected("save_image_texture_payload_unavailable")
            }
            let source = try Self.readTexture(location, storage: storage, repository: repository)
            return .init(name: Self.nativeJPEGName(name), jpeg: try Self.jpegRepresentation(source, fallback: jpegEncoder))
        }
        let integerWords = (0..<8).map { userIntegers[$0] ?? 0 }
        let stringWords = (0..<8).map { userStrings[$0] ?? "" }
        var generatorRecords = Array(repeating: defaultGeneratorRecord(), count: 4)
        for (index, request) in image.generatorRequests {
            guard (0..<4).contains(index), request.arguments.first == 0 else {
                throw ResourceError.rejected("save_image_generator_mode_unmapped")
            }
            // The native mode-0 branch returns zero for all three output
            // channels; the remaining request fields and live +0x04 counter
            // are still serialized from the tracked request.
            generatorRecords[Int(index)] = try encodeGeneratorRecord(request, outputWords: [0, 0, 0])
        }
        let groupRecords: [Data]
        if supportedGroup, let clock = image.generatorFilterModeClock {
            let request = ScriptStorage.GeneratorRequest(index: 0, arguments: [0, 0, 100, 0, 0, 0, 0, 0],
                                                         persistent: false, currentTime: clock)
            groupRecords = [try encodeGeneratorRecord(request, outputWords: [0, 0, 0])]
        } else {
            groupRecords = []
        }
        let library = try encodeImageLibrary(fixedRecord: fixed,
            sourceName: try serializedResourceName(image.resourceName, location: image.resource, repository: repository),
            textureSlots: slots, soundNames: Array(repeating: "", count: 32),
            auxiliaryNames: (0..<32).map { image.filterOverrides[Int32($0)] ?? "" },
            auxiliaryBytes: Data(image.layerAuxiliaryFlags ?? Array(repeating: 1, count: 256)),
            generatorRecords: generatorRecords, generatorGroup: supportedGroup ? "mode" : "",
            generatorGroupRecords: groupRecords,
            userIntegers: integerWords, userStrings: stringWords, finalString: storage.visualAnchorNames[handle] ?? "")
        return try encodeImageObjectPayload(baseRecordWord: baseWord, imageLibrary: library)
    }

    private static func defaultButtonClassRecord() -> Data {
        var data = Data(repeating: 0, count: 189)
        append(Int32(11), at: 0, to: &data)
        // Constructor fields established by 0x67bd2c. These are the class
        // record words; per-object rectangle and text values are overlaid later.
        let words: [(Int, Int32)] = [
            (0x04, 0), (0x08, 0), (0x1c, 0), (0x20, 0), (0x24, 0), (0x28, 0),
            (0x34, 0x20), (0x38, 0x20), (0x3c, 0x20), (0x40, 0x20),
            (0x44, 0), (0x48, -1), (0x4c, -1), (0x50, 12), (0x54, 12),
            (0x58, -1), (0x5c, -1), (0x60, 7), (0x64, 0), (0x68, 0), (0x6c, 0),
            (0x70, -8), (0x74, 0), (0x78, 0), (0x84, 0), (0x88, -1),
            (0x8c, 1), (0x90, 0), (0x94, 0), (0x9d, 0)
        ]
        for (offset, value) in words { append(value, at: offset, to: &data) }
        return data
    }

    static func encodeButtonObjectPayload(handle: UInt64, storage: ScriptStorage,
                                          repository: ScriptRepository?,
                                          jpegEncoder: (@Sendable (Data) throws -> Data)? = nil) throws -> Data {
        guard storage.buttons.contains(handle),
              let baseWord = storage.savedObjectBaseWords[handle] else {
            throw ResourceError.rejected("save_button_object_identity_unavailable")
        }
        guard !storage.unknownSavedButtonLocks.contains(handle),
              !storage.unknownSavedButtonChecks.contains(handle),
              !storage.buttonMI.contains(handle),
              !storage.buttonActionSelectionUnknown.contains(handle) else {
            throw ResourceError.rejected("save_button_class_state_unmapped")
        }
        guard (storage.buttonSelectedMembers[handle] == nil) == (storage.buttonMotionStartTicks[handle] == nil) else {
            throw ResourceError.rejected("save_button_action_identity_unavailable")
        }
        let resource = storage.buttonResources[handle]
        let resourceName = storage.buttonResourceNames[handle]
        let serializedName = try serializedResourceName(resourceName,
            location: resource, repository: repository)
        guard (resource == nil) == (resourceName == nil) else {
            throw ResourceError.rejected("save_button_resource_identity_unavailable")
        }
        if let resource {
            guard let repository else { throw ResourceError.rejected("save_button_resource_repository_unavailable") }
            let bytes = try repository.directory.read(resource.sourceFile, limit: 32 * 1024 * 1024)
            guard bytes.sha256Hex == resource.sourceSHA256,
                  resource.byteOffset >= 0, resource.byteOffset <= bytes.count,
                  resource.byteLength <= bytes.count - resource.byteOffset else {
                throw ResourceError.rejected("save_button_resource_identity_mismatch")
            }
            let start = bytes.startIndex + resource.byteOffset
            let content = Data(bytes[start..<(start + resource.byteLength)])
            guard content.sha256Hex == resource.rangeSHA256 else {
                throw ResourceError.rejected("save_button_resource_range_mismatch")
            }
            let extended = content.starts(with: Data("abmp12".utf8))
            guard extended == storage.buttonHasExtendedContainerMetadata.contains(handle) else {
                throw ResourceError.rejected("save_button_extended_resource_identity_unmapped")
            }
            if storage.enabledButtons.contains(handle) &&
                (extended || storage.buttonResourceMemberCounts[handle, default: 0] > 1) {
                guard storage.buttonSelectedMembers[handle] != nil,
                      storage.buttonSavedLayerTimeSnapshots[handle]?.visualTick == storage.visualTicks,
                      storage.buttonLayerAuxiliaryFlags[handle]?.count == 256 else {
                    let source = resource.sourceSHA256.prefix(12)
                    let member = storage.buttonSelectedMembers[handle].map(String.init) ?? "none"
                    let snapshot = storage.buttonSavedLayerTimeSnapshots[handle]
                    throw ResourceError.rejected(
                        "save_button_active_background_clock_unmapped:source=\(source):member=\(member):extended=\(extended ? 1 : 0):flags=\(storage.buttonLayerAuxiliaryFlags[handle]?.count ?? 0):start=\(storage.buttonMotionStartTicks[handle] ?? -1):snapshot=\(snapshot.map { String($0.visualTick) } ?? "none"):visual=\(storage.visualTicks)")
                }
            }
        }

        let imageNames = storage.buttonImageNames[handle] ?? [:]
        let imageLocations = storage.buttonImages[handle] ?? [:]
        guard Set(imageNames.keys) == Set(imageLocations.keys),
              imageNames.keys.allSatisfy({ (0..<33).contains($0) }) else {
            throw ResourceError.rejected("save_button_texture_name_mapping_incomplete")
        }
        let textureSlots = try (0..<33).map { index -> TextureSlot in
            guard let name = imageNames[Int32(index)] else { return .init(name: "", jpeg: nil) }
            guard let location = imageLocations[Int32(index)] else {
                throw ResourceError.rejected("save_button_texture_payload_unavailable")
            }
            let source = try Self.readTexture(location, storage: storage, repository: repository)
            return .init(name: Self.nativeJPEGName(name), jpeg: try Self.jpegRepresentation(source, fallback: jpegEncoder))
        }
        let buttonSounds = storage.buttonSounds[handle] ?? [:]
        let buttonSoundNames = storage.buttonSoundNames[handle] ?? [:]
        guard Set(buttonSounds.keys) == Set(buttonSoundNames.keys),
              buttonSoundNames.keys.allSatisfy({ (0..<32).contains($0) }) else {
            throw ResourceError.rejected("save_button_sound_name_mapping_incomplete")
        }
        let soundSlots = try (0..<32).map { index -> String in
            let slot = Int32(index)
            guard let name = buttonSoundNames[slot] else { return "" }
            guard let location = buttonSounds[slot] else {
                throw ResourceError.rejected("save_button_sound_resource_unavailable")
            }
            return try serializedResourceName(name, location: location, repository: repository)
        }

        let integers = storage.buttonUserIntegers[handle] ?? [:]
        let userStrings = storage.buttonUserStrings[handle] ?? [:]
        guard integers.keys.allSatisfy({ (0..<8).contains($0) }),
              userStrings.keys.allSatisfy({ (0..<8).contains($0) }) else {
            throw ResourceError.rejected("save_button_user_field_index_outside_profile")
        }

        var imageFixed = defaultImageFixedRecord()
        func storeImage(_ value: Int32, at offsets: [Int]) {
            for offset in offsets { Self.append(value, at: offset, to: &imageFixed) }
        }
        let placement = storage.buttonPlacement[handle] ?? [0, 0, 0]
        guard placement.count == 3 else { throw ResourceError.rejected("save_button_placement_shape") }
        storeImage(placement[0], at: [0x8fd, 0x909, 0x915])
        storeImage(placement[1], at: [0x901, 0x90d, 0x919])
        storeImage(placement[2], at: [0x905, 0x911, 0x91d])
        if let sp = storage.buttonSP[handle] {
            guard sp.count == 2 else { throw ResourceError.rejected("save_button_sp_shape") }
            storeImage(sp[0], at: [0x8c5])
            storeImage(sp[1], at: [0x8c9])
        }
        let scale: [Int32]
        if let savedScale = storage.savedButtonPlacementScale[handle] {
            scale = [savedScale.x, savedScale.y]
        } else {
            scale = [100, 100]
        }
        guard scale.count == 2 else { throw ResourceError.rejected("save_button_scale_shape") }
        storeImage(scale[0], at: [0x951, 0x955, 0x959])
        storeImage(scale[1], at: [0x95d, 0x961, 0x965])
        storeImage(storage.buttonVolumeType[handle] ?? 2, at: [0x8b0])
        storeImage(storage.buttonTabOrder[handle] ?? 0, at: [0x8cd])
        storeImage(storage.buttonInputMasks[handle] ?? 0xff, at: [0x8bd])
        storeImage(storage.buttonOutputMasks[handle] ?? 0xff, at: [0x8c1])
        if let motion = storage.buttonMotion[handle] {
            imageFixed[0x9fd] = motion.mode
            storeImage(motion.strength, at: [0x9f1])
        }
        storeImage(storage.buttonSelectedMembers[handle] ?? 0, at: [0x80c])
        storeImage(0, at: [0x814])
        storeImage(100, at: [0x8ac])
        if let startTick = storage.buttonMotionStartTicks[handle] {
            let elapsed = max(0, storage.visualTicks - startTick)
            guard let elapsedTicks = Int32(exactly: elapsed) else {
                throw ResourceError.rejected("save_button_action_elapsed_unavailable")
            }
            storeImage(elapsedTicks, at: [0x894])
            storeImage(0, at: [0x810])
        }
        if let snapshot = storage.buttonSavedLayerTimeSnapshots[handle] {
            guard snapshot.visualTick == storage.visualTicks,
                  snapshot.times.count == 256, snapshot.auxiliary.count == 256 else {
                throw ResourceError.rejected("save_button_layer_clock_snapshot_mismatch")
            }
            for (index, word) in try SaveLayerClockWords.savedWords(fromRuntimeFloatBitPatterns: snapshot.times).enumerated() {
                Self.append(word, at: 4 + index * 4, to: &imageFixed)
            }
            for (index, word) in try SaveLayerClockWords.savedWords(fromRuntimeFloatBitPatterns: snapshot.auxiliary).enumerated() {
                Self.append(word, at: 0x404 + index * 4, to: &imageFixed)
            }
        }
        imageFixed[0x9f9] = (resource != nil || !imageLocations.isEmpty) ? 1 : 0
        imageFixed[0x9fa] = storage.enabledButtons.contains(handle) ? 1 : 0

        let opaqueText = storage.unknownSavedButtonText.contains(handle) ? storage.savedButtonTextOpaque[handle] : nil
        if storage.unknownSavedButtonText.contains(handle) {
            guard !storage.enabledButtons.contains(handle), !storage.dirtySavedButtonText.contains(handle),
                  let opaqueText, opaqueText.fixedRecord.count == 189, opaqueText.strings.count == 5 else {
                throw ResourceError.rejected("saved_button_text_unverified")
            }
        }
        var buttonRecord = opaqueText?.fixedRecord ?? defaultButtonClassRecord()
        let rectangle = storage.buttonTextBounds[handle] ?? storage.drawableRectangles[handle] ?? [0, 0, 0, 0]
        guard rectangle.count == 4, rectangle[2] >= rectangle[0], rectangle[3] >= rectangle[1] else {
            throw ResourceError.rejected("save_button_rectangle_outside_profile")
        }
        if opaqueText == nil {
            for (index, value) in rectangle.enumerated() { Self.append(value, at: 12 + index * 4, to: &buttonRecord) }
        }

        var strings = opaqueText?.strings ?? Array(repeating: "", count: 5)
        if opaqueText == nil, let text = storage.buttonText[handle] {
            guard let candidate = text.primaryTextWriteCandidate() else {
                throw ResourceError.rejected("save_button_text_state_unmapped")
            }
            guard !storage.enabledButtons.contains(handle) || candidate.pending.isEmpty else {
                throw ResourceError.rejected("save_enabled_button_pending_text_unmapped")
            }
            strings = [candidate.displayed, candidate.pending, text.prohibitedLineStart,
                       text.prohibitedLineEnd, text.ignoredReturnWords]
            guard let cursor = Int32(exactly: candidate.displayed.utf16.count) else {
                throw ResourceError.rejected("save_button_text_cursor_outside_profile")
            }
            Self.append(cursor, at: 0x44, to: &buttonRecord)
            let margins = text.textMargins ?? [0, 0]
            guard margins.count == 2 else { throw ResourceError.rejected("save_button_text_margins_shape") }
            Self.append(margins[0], at: 0x90, to: &buttonRecord)
            Self.append(margins[1], at: 0x94, to: &buttonRecord)
            Self.append(text.kinsokuWordLength ?? 1, at: 0x8c, to: &buttonRecord)
            if let spacing = text.returnSpacing {
                Self.append(spacing.0, at: 0x84, to: &buttonRecord)
                Self.append(spacing.1, at: 0x9d, to: &buttonRecord)
            }
            buttonRecord[0x9a] = text.asEnabled ? 1 : 0
            buttonRecord[0x9b] = text.apEnabled ? 1 : 0
        }
        var tail = Data(repeating: 0, count: 42)
        Self.append(Int32(10), at: 0, to: &tail)
        tail[8] = storage.buttonCheckVisual[handle, default: 0]
        tail[9] = storage.buttonLocks[handle, default: 0]
        let library = try encodeImageLibrary(fixedRecord: imageFixed, sourceName: serializedName,
            textureSlots: textureSlots, soundNames: soundSlots,
            auxiliaryNames: Array(repeating: "", count: 32),
            auxiliaryBytes: Data(storage.buttonLayerAuxiliaryFlags[handle] ?? Array(repeating: 1, count: 256)),
            generatorRecords: Array(repeating: defaultGeneratorRecord(), count: 4), generatorGroup: "",
            userIntegers: (0..<8).map { integers[$0] ?? 0 },
            userStrings: (0..<8).map { userStrings[$0] ?? "" }, finalString: storage.visualAnchorNames[handle] ?? "")
        return try encodeButtonObjectPayload(baseRecordWord: baseWord, imageLibrary: library,
            fixedRecord: buttonRecord, strings: strings, buttonTail: tail)
    }

    static func encodeMessageObjectPayload(handle: UInt64, storage: ScriptStorage,
                                           repository: ScriptRepository?,
                                           jpegEncoder: (@Sendable (Data) throws -> Data)? = nil) throws -> Data {
        guard let message = storage.messages[handle],
              let baseWord = storage.savedObjectBaseWords[handle] else {
            throw ResourceError.rejected("save_message_object_identity_unavailable")
        }
        guard message.generatorFilterRequests.allSatisfy(\.isEmpty),
              storage.buttonUserIntegers[handle]?.isEmpty != false,
              storage.buttonSoundNames[handle]?.isEmpty != false,
              storage.buttonSounds[handle]?.isEmpty != false else {
            throw ResourceError.rejected("save_message_shared_library_state_unmapped")
        }
        guard (message.background == nil) == (message.backgroundName == nil) else {
            throw ResourceError.rejected("save_message_background_identity_unavailable")
        }
        if (message.backgroundSelectedMember == nil) != (message.backgroundMotionStartTick == nil) {
            throw ResourceError.rejected("save_message_background_motion_identity_unavailable")
        }
        if let snapshot = message.backgroundSavedLayerTimeSnapshot {
            guard snapshot.visualTick == storage.visualTicks,
                  snapshot.times.count == 256, snapshot.auxiliary.count == 256 else {
                let source = message.background?.sourceSHA256.prefix(12) ?? "unbound"
                let member = message.backgroundSelectedMember.map(String.init) ?? "none"
                throw ResourceError.rejected(
                    "save_message_background_clock_snapshot_mismatch:source=\(source):member=\(member):extended=\(message.backgroundHasExtendedContainerMetadata ? 1 : 0):flags=\(message.backgroundLayerAuxiliaryFlags?.count ?? 0):animation_speed=\(message.backgroundAnimationSpeed):playback_speed=\(message.backgroundPlaybackSpeed):start=\(message.backgroundMotionStartTick ?? -1):snapshot=\(snapshot.visualTick):visual=\(storage.visualTicks):times=\(snapshot.times.count):aux=\(snapshot.auxiliary.count)")
            }
        }
        guard !message.backgroundHasExtendedContainerMetadata ||
                message.backgroundLayerAuxiliaryFlags?.count == 256 else {
            let source = message.background?.sourceSHA256.prefix(12) ?? "unbound"
            let offset = message.background?.byteOffset ?? -1
            let member = message.backgroundSelectedMember.map(String.init) ?? "none"
            throw ResourceError.rejected(
                "save_message_extended_background_flags_unmapped:source=\(source):offset=\(offset):members=\(message.backgroundMemberCount):member=\(member):flags=\(message.backgroundLayerAuxiliaryFlags?.count ?? 0)")
        }
        if message.enabled, message.backgroundSelectedMember != nil {
            guard message.backgroundSavedLayerTimeSnapshot?.visualTick == storage.visualTicks else {
                let source = message.background?.sourceSHA256.prefix(12) ?? "unbound"
                let member = message.backgroundSelectedMember.map(String.init) ?? "none"
                let snapshot = message.backgroundSavedLayerTimeSnapshot
                throw ResourceError.rejected(
                    "save_message_active_background_clock_unmapped:source=\(source):members=\(message.backgroundMemberCount):extended=\(message.backgroundHasExtendedContainerMetadata ? 1 : 0):enabled=\(message.enabled ? 1 : 0):member=\(member):snapshot=\(snapshot.map { String($0.visualTick) } ?? "none"):times=\(snapshot?.times.count ?? 0):aux=\(snapshot?.auxiliary.count ?? 0):visual=\(storage.visualTicks)")
            }
        }

        let placement = message.placement ?? [0, 0, 0]
        let transform = message.transform ?? .init(depth: 0, scale: [100, 100, 100], rotation: [0, 0, 0], loop: 0)
        guard placement.count == 3, transform.scale.count == 3, transform.rotation.count == 3,
              transform.depth == 0, transform.rotation == [0, 0, 0], transform.loop == 0,
              (0..<3).allSatisfy({ (-16_777_216...16_777_216).contains(placement[$0]) &&
                  (-16_777_216...16_777_216).contains(transform.scale[$0]) }) else {
            throw ResourceError.rejected("save_message_transform_outside_profile")
        }
        guard let text = message.primaryTextWriteCandidate(),
              let rectangle = message.textBounds, rectangle.count == 4,
              rectangle[2] >= rectangle[0], rectangle[3] >= rectangle[1],
              let cursor = Int32(exactly: text.displayed.utf16.count) else {
            throw ResourceError.rejected("save_message_text_state_unmapped")
        }
        let margins = message.textMargins ?? [0, 0]
        guard margins.count == 2 else { throw ResourceError.rejected("save_message_text_margins_shape") }
        // 0x67be57 initializes the reserve to one. An explicit table can
        // become active with later text, so preserve that reserve in its slot.
        let hasLineTable = !message.prohibitedLineStart.isEmpty || !message.prohibitedLineEnd.isEmpty
        let kinsoku = message.kinsokuWordLength ?? (hasLineTable ? 1 : 0)

        var imageFixed = defaultImageFixedRecord()
        func storeImage(_ value: Int32, at offsets: [Int]) {
            for offset in offsets { Self.append(value, at: offset, to: &imageFixed) }
        }
        storeImage(placement[0], at: [0x8fd, 0x909, 0x915])
        storeImage(placement[1], at: [0x901, 0x90d, 0x919])
        storeImage(placement[2], at: [0x905, 0x911, 0x91d])
        storeImage(transform.scale[0], at: [0x951, 0x955, 0x959])
        storeImage(transform.scale[1], at: [0x95d, 0x961, 0x965])
        storeImage(transform.scale[2], at: [0x969, 0x96d, 0x971])
        storeImage(message.volumeType ?? 2, at: [0x8b0])
        storeImage(message.inputMask ?? 0xff, at: [0x8bd])
        storeImage(message.outputMask ?? 0xff, at: [0x8c1])
        storeImage(message.drawChannel ?? 0, at: [0x8a0])
        guard message.backgroundPlaybackSpeed == 100 else {
            throw ResourceError.rejected("save_message_playback_speed_outside_profile")
        }
        storeImage(message.backgroundAnimationSpeed, at: [0x814])
        storeImage(message.backgroundPlaybackSpeed, at: [0x8ac])
        storeImage(message.alignment?.0 ?? 0, at: [0x8f1])
        storeImage(message.alignment?.1 ?? 0, at: [0x8f5])
        imageFixed[0x9f9] = (message.backgroundDrawGate ?? message.enabled) ? 1 : 0
        imageFixed[0x9fa] = message.enabled ? 1 : 0
        if let member = message.backgroundSelectedMember {
            guard let elapsed = message.backgroundMotionElapsed(at: storage.visualTicks), elapsed >= 0,
                  let elapsedTicks = Int32(exactly: elapsed / 100) else {
                throw ResourceError.rejected("save_message_background_elapsed_unavailable")
            }
            guard message.backgroundAnimationSpeed == 0, message.backgroundRestoredMotionRemainder == 0 else {
                throw ResourceError.rejected("save_message_background_clock_outside_profile")
            }
            // The host advances supported message backgrounds at normal speed.
            // 0x5ac11f and 0x5ac1a9 write the action and elapsed time relative to +0x338.
            storeImage(member, at: [0x808])
            storeImage(elapsedTicks, at: [0x898])
        }
        if let snapshot = message.backgroundSavedLayerTimeSnapshot {
            for (index, word) in try SaveLayerClockWords.savedWords(fromRuntimeFloatBitPatterns: snapshot.times).enumerated() {
                Self.append(word, at: 4 + index * 4, to: &imageFixed)
            }
            for (index, word) in try SaveLayerClockWords.savedWords(fromRuntimeFloatBitPatterns: snapshot.auxiliary).enumerated() {
                Self.append(word, at: 0x404 + index * 4, to: &imageFixed)
            }
        }

        let imageNames = message.backgroundBoundImageNames
        let imageLocations = message.backgroundBoundImages
        guard Set(imageNames.keys) == Set(imageLocations.keys),
              imageNames.keys.allSatisfy({ (0..<33).contains($0) }) else {
            throw ResourceError.rejected("save_message_texture_name_mapping_incomplete")
        }
        let textureSlots = try (0..<33).map { index -> TextureSlot in
            guard let name = imageNames[Int32(index)] else { return .init(name: "", jpeg: nil) }
            guard let location = imageLocations[Int32(index)] else {
                throw ResourceError.rejected("save_message_texture_payload_unavailable")
            }
            let source = try Self.readTexture(location, storage: storage, repository: repository)
            return .init(name: Self.nativeJPEGName(name), jpeg: try Self.jpegRepresentation(source, fallback: jpegEncoder))
        }
        let userStrings = storage.buttonUserStrings[handle] ?? [:]
        guard userStrings.keys.allSatisfy({ (0..<8).contains($0) }) else {
            throw ResourceError.rejected("save_message_user_string_index_outside_profile")
        }
        let soundNames = Array(repeating: "", count: 32)
        let library = try encodeImageLibrary(fixedRecord: imageFixed,
            sourceName: try serializedResourceName(message.backgroundName, location: message.background,
                repository: repository), textureSlots: textureSlots,
            soundNames: soundNames, auxiliaryNames: Array(repeating: "", count: 32),
            auxiliaryBytes: Data(message.backgroundLayerAuxiliaryFlags ?? Array(repeating: 1, count: 256)),
            generatorRecords: Array(repeating: defaultGeneratorRecord(), count: 4), generatorGroup: "",
            userIntegers: Array(repeating: 0, count: 8),
            userStrings: (0..<8).map { userStrings[$0] ?? "" }, finalString: storage.visualAnchorNames[handle] ?? "")

        var messageRecord = Data(repeating: 0, count: 189)
        Self.append(Int32(11), at: 0, to: &messageRecord)
        for (index, value) in rectangle.enumerated() { Self.append(value, at: 12 + index * 4, to: &messageRecord) }
        Self.append(cursor, at: 0x44, to: &messageRecord)
        Self.append(margins[0], at: 0x90, to: &messageRecord)
        Self.append(margins[1], at: 0x94, to: &messageRecord)
        Self.append(kinsoku, at: 0x8c, to: &messageRecord)
        // With the fixed record at EBP-0xc5, the reader at 0x678ead and
        // 0x678eb6 restores these two words into object +0xe90 and +0xea9.
        if let spacing = message.returnSpacing {
            Self.append(spacing.0, at: 0x84, to: &messageRecord)
            Self.append(spacing.1, at: 0x9d, to: &messageRecord)
        }
        messageRecord[0x9a] = message.asEnabled ? 1 : 0
        messageRecord[0x9b] = message.apEnabled ? 1 : 0
        let strings = [text.displayed, text.pending, message.prohibitedLineStart,
                       message.prohibitedLineEnd, message.ignoredReturnWords]
        return try encodeMessageObjectPayload(baseRecordWord: baseWord, imageLibrary: library,
            fixedRecord: messageRecord, strings: strings)
    }

    package static func encodeMessageObjectPayload(baseRecordWord: Int32, imageLibrary: Data,
                                                   fixedRecord: Data, strings: [String]) throws -> Data {
        try encodeSharedVisualObjectPayload(baseRecordWord: baseRecordWord, imageLibrary: imageLibrary,
                                            fixedRecord: fixedRecord, strings: strings, buttonTail: nil)
    }

    package static func encodeButtonObjectPayload(baseRecordWord: Int32, imageLibrary: Data,
                                                  fixedRecord: Data, strings: [String],
                                                  buttonTail: Data) throws -> Data {
        try encodeSharedVisualObjectPayload(baseRecordWord: baseRecordWord, imageLibrary: imageLibrary,
                                            fixedRecord: fixedRecord, strings: strings, buttonTail: buttonTail)
    }

    private static func encodeObjectPayloadHeader(baseRecordWord: Int32, imageLibrary: Data) throws -> Data {
        guard imageLibrary.count <= SaveEnvelope.maxFileBytes - 12 else {
            throw ResourceError.rejected("save_visual_object_payload_size_limit")
        }
        var output = Data("objd".utf8)
        append(Int32(1), to: &output)
        append(baseRecordWord, to: &output)
        output.append(imageLibrary)
        return output
    }

    private static func encodeSharedVisualObjectPayload(baseRecordWord: Int32, imageLibrary: Data,
                                                        fixedRecord: Data, strings: [String],
                                                        buttonTail: Data?) throws -> Data {
        guard fixedRecord.count == 189, strings.count == 5,
              buttonTail == nil || buttonTail?.count == 42 else {
            throw ResourceError.rejected("save_visual_shared_record_shape")
        }
        var output = try encodeObjectPayloadHeader(baseRecordWord: baseRecordWord, imageLibrary: imageLibrary)
        guard fixedRecord.count <= SaveEnvelope.maxFileBytes - output.count else {
            throw ResourceError.rejected("save_visual_object_payload_size_limit")
        }
        output.append(fixedRecord)
        for string in strings {
            guard string.utf8.count <= 8192, let units = Int16(exactly: string.utf16.count),
                  let bytes = string.data(using: .utf16LittleEndian),
                  bytes.count + 2 <= SaveEnvelope.maxFileBytes - output.count else {
                throw ResourceError.rejected("save_visual_object_string_limit")
            }
            append(units, to: &output)
            output.append(bytes)
        }
        if let buttonTail { output.append(buttonTail) }
        return output
    }

    private static func append(_ value: Int32, at offset: Int, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) {
            data.replaceSubrange(offset..<(offset + 4), with: $0)
        }
    }

    private static func serializedResourceName(_ fallback: String?, location: ScriptLocation?,
                                               repository: ScriptRepository?) throws -> String {
        guard let location else { return fallback ?? "" }
        guard let repository else {
            guard let fallback else { throw ResourceError.rejected("save_visual_resource_name_unavailable") }
            return fallback
        }
        let bytes = try repository.directory.read(location.sourceFile, limit: 32 * 1024 * 1024)
        guard bytes.sha256Hex == location.sourceSHA256,
              location.byteOffset >= 0, location.byteOffset <= bytes.count,
              location.byteLength >= 0, location.byteLength <= bytes.count - location.byteOffset else {
            throw ResourceError.rejected("save_visual_resource_name_identity")
        }
        let start = bytes.startIndex + location.byteOffset
        let range = Data(bytes[start..<(start + location.byteLength)])
        guard range.sha256Hex == location.rangeSHA256 else {
            throw ResourceError.rejected("save_visual_resource_range_identity")
        }
        if let packRange = location.sourceFile.range(of: ".pack/") {
            let logicalName = String(location.sourceFile[packRange.upperBound...])
            guard !logicalName.isEmpty, try SafeDirectory.components(logicalName).count <= 32 else {
                throw ResourceError.rejected("save_visual_resource_name_outside_profile")
            }
            return logicalName
        }
        guard let fallback else { throw ResourceError.rejected("save_visual_resource_name_unavailable") }
        return fallback
    }

    /// 0x4162e8 replaces the saved texture suffix with `.jpg` after the
    /// native writer has encoded its cached bitmap as JPEG.
    private static func nativeJPEGName(_ name: String) -> String {
        (name as NSString).deletingPathExtension + ".jpg"
    }

    private static func readTexture(_ location: ScriptLocation, storage: ScriptStorage,
                                    repository: ScriptRepository?) throws -> Data {
        if let embedded = storage.savedTextureData[location] { return embedded }
        guard let repository, location.byteLength > 0, location.byteLength <= 16 * 1024 * 1024 else {
            throw ResourceError.rejected("save_visual_texture_source_unavailable")
        }
        let bytes = try repository.directory.read(location.sourceFile, limit: 32 * 1024 * 1024)
        guard bytes.sha256Hex == location.sourceSHA256,
              location.byteOffset >= 0, location.byteOffset <= bytes.count,
              location.byteLength <= bytes.count - location.byteOffset else {
            throw ResourceError.rejected("save_visual_texture_source_identity")
        }
        let lowerBound = bytes.startIndex + location.byteOffset
        let upperBound = lowerBound + location.byteLength
        let range = Data(bytes[lowerBound..<upperBound])
        guard range.sha256Hex == location.rangeSHA256 else {
            throw ResourceError.rejected("save_visual_texture_range_identity")
        }
        return range
    }

    package static func jpegRepresentation(_ source: Data,
                                          fallback: (@Sendable (Data) throws -> Data)?) throws -> Data {
        guard source.count <= 16 * 1024 * 1024 else {
            throw ResourceError.rejected("save_visual_texture_decode_outside_profile")
        }
        guard let imageSource = CGImageSourceCreateWithData(source as CFData, nil),
              CGImageSourceGetCount(imageSource) == 1,
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
              image.width > 0, image.height > 0, image.width <= 8192, image.height <= 8192 else {
            guard let fallback else {
                throw ResourceError.rejected("save_visual_texture_decode_outside_profile")
            }
            let jpeg = try fallback(source)
            guard jpeg.count <= 16 * 1024 * 1024,
                  InventoryScanner.signature(Data(jpeg.prefix(16))) == "JPEG" else {
                throw ResourceError.rejected("save_visual_texture_fallback_output_outside_profile")
            }
            return jpeg
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else {
            throw ResourceError.rejected("save_visual_jpeg_destination_unavailable")
        }
        CGImageDestinationAddImage(destination, image,
            [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ResourceError.rejected("save_visual_jpeg_encode_failed")
        }
        let jpeg = output as Data
        guard InventoryScanner.signature(Data(jpeg.prefix(16))) == "JPEG" else {
            throw ResourceError.rejected("save_visual_jpeg_signature")
        }
        return jpeg
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
