import Foundation

/// Structural walk from the verified script reader through paths, table and sound banks.
package struct SaveStatePrefix: Encodable, Sendable {
    let status: EvidenceStatus = .verified
    let pathCount: Int
    let pathReferences: [SaveReaderCursor.Reference]
    // TImoPath reader 0x6a5af0 and writer 0x6a5b1c serialize one byte at instance +0x20.
    // Its effect on path resolution is unverified.
    let rawPathFlag: UInt8
    let stateTableOffset: Int
    let soundOffset: Int
    let dsndCount: Int
    let ssndCount: Int
    struct SoundRecord: Encodable, Sendable {
        let record: SaveReaderCursor.Reference
        let strings: [SaveReaderCursor.Reference]
        // dsnd reader 0x59fd5c bypasses 0x59f7e4 when record byte +0x11 is nonzero.
        // Otherwise it calls that routine with the saved string if nonempty.
        let directReloadRequested: Bool?
        let directChannel: DirectChannel?
        let streamChannel: StreamChannel?
    }

    struct StreamChannel: Encodable, Sendable {
        let rawMode: UInt8
        let rawLoadOption: UInt8
        let rawSeekBits: UInt32

        init(bytes: UnsafeRawBufferPointer, start: Int) {
            // 0x5a04e4 gates reload on +0x10, then passes +0x11 to
            // the loader and scales the float at +0x15 before seeking.
            rawMode = bytes[start + 0x10]
            rawLoadOption = bytes[start + 0x11]
            rawSeekBits = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: start + 0x15, as: UInt32.self))
        }
    }

    struct DirectChannel: Encodable, Sendable {
        enum ResumeDispatch: String, Encodable, Sendable {
            case bypassed, none, conditionalMode2, mode3
        }

        let rawValueAt04: UInt32
        // 0x59fb00 scales this signed input by the channel factor, then
        // normalizes by 256 before converting to DirectSound attenuation.
        let volumeInput: Int32
        // Both read-side calls to 0x59fa94 pass zero as the start argument.
        let requestedStartOffset: Int?
        let loopingRequested: Bool?
        // 0x59fc60 requires a non-null buffer and an unsigned byte count
        // greater than 0xd7550. 0x59f7a1 supplies the decoded stream size.
        let minimumDecodedBufferBytes: Int?
        let rawValueAt09: UInt32
        let rawMode: UInt8
        let resumeDispatch: ResumeDispatch

        init(bytes: UnsafeRawBufferPointer, start: Int) {
            rawValueAt04 = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: start + 4, as: UInt32.self))
            volumeInput = Int32(bitPattern: rawValueAt04)
            rawValueAt09 = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: start + 9, as: UInt32.self))
            rawMode = bytes[start + 8]
            // 0x59fd5c bypasses post-load dispatch. Mode 2 additionally tests
            // the restored channel (0x59fdb2), while mode 3 calls directly.
            switch (bytes[start + 0x11], rawMode) {
            case (0, 2): resumeDispatch = .conditionalMode2
            case (0, 3): resumeDispatch = .mode3
            case (0, _): resumeDispatch = .none
            default: resumeDispatch = .bypassed
            }
            switch resumeDispatch {
            case .conditionalMode2:
                requestedStartOffset = 0
                loopingRequested = false
                minimumDecodedBufferBytes = 0xd7551
            case .mode3:
                requestedStartOffset = 0
                loopingRequested = true
                minimumDecodedBufferBytes = nil
            case .bypassed, .none:
                requestedStartOffset = nil
                loopingRequested = nil
                minimumDecodedBufferBytes = nil
            }
        }
    }
    let dsndReferences: [SoundRecord]
    let ssndReferences: [SoundRecord]
    let nextDecodedOffset: Int

    package init(state: Data, after reader: SaveReaderCursor) throws {
        (pathCount, pathReferences, rawPathFlag, stateTableOffset, soundOffset, dsndCount, ssndCount, dsndReferences, ssndReferences, nextDecodedOffset) =
            try state.withUnsafeBytes { bytes in
                var offset = reader.nextDecodedOffset
                func take(_ length: Int) throws -> Int {
                    guard offset >= 0, offset <= bytes.count, length >= 0, length <= bytes.count - offset else {
                        throw ResourceError.rejected("invalid_save_state_prefix_bounds")
                    }
                    let start = offset
                    offset += length
                    return start
                }
                func count() throws -> Int {
                    Int(Int32(littleEndian: bytes.loadUnaligned(fromByteOffset: try take(4), as: Int32.self)))
                }
                func stringRange() throws -> Range<Int> {
                    let units = Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: try take(2), as: Int16.self))
                    let length = Int(units) * 2
                    let start = try take(length)
                    return start..<(start + length)
                }
                func reference(_ range: Range<Int>) -> SaveReaderCursor.Reference {
                    SaveReaderCursor.Reference(decodedOffset: range.lowerBound, length: range.count,
                                               sha256: Data(bytes[range]).sha256Hex)
                }
                // Original load dispatch 0x5a100c calls readers 0x59fc74 and 0x5a0390.
                func soundBank(_ tag: String, recordSize: Int, strings: Int) throws -> [SoundRecord] {
                    let start = try take(8)
                    guard bytes[start..<(start + 8)].prefix(while: { $0 != 0 }).elementsEqual(tag.utf8) else {
                        throw ResourceError.rejected("save_sound_bank_tag_mismatch")
                    }
                    let entries = try count()
                    guard (0...min(65_535, (bytes.count - offset) / (recordSize + 2 * strings))).contains(entries) else {
                        throw ResourceError.rejected("invalid_save_sound_bank_count")
                    }
                    return try (0..<entries).map { _ in
                        let recordStart = try take(recordSize)
                        let fields = try (0..<strings).map { _ in reference(try stringRange()) }
                        let directReload = tag == "dsnd" ? bytes[recordStart + 0x11] == 0 && fields[0].length > 0 : nil
                        return SoundRecord(record: reference(recordStart..<offset), strings: fields,
                                           directReloadRequested: directReload,
                                           directChannel: tag == "dsnd" ? DirectChannel(bytes: bytes, start: recordStart) : nil,
                                           streamChannel: tag == "ssnd" ? StreamChannel(bytes: bytes, start: recordStart) : nil)
                    }
                }
                let paths = try count()
                guard (0...min(65_535, (bytes.count - offset) / 2)).contains(paths) else {
                    throw ResourceError.rejected("invalid_save_path_count")
                }
                let references = try (0..<paths).map { _ in
                    reference(try stringRange())
                }
                let flag = bytes[try take(1)]
                let tableStart = offset
                _ = try take(76)
                for _ in 0..<256 {
                    for _ in 0..<4 { _ = try stringRange() }
                    _ = try take(16)
                }
                let soundStart = offset
                let dsnd = try soundBank("dsnd", recordSize: 86, strings: 1)
                let ssnd = try soundBank("ssnd", recordSize: 131, strings: 2)
                return (paths, references, flag, tableStart, soundStart, dsnd.count, ssnd.count, dsnd, ssnd, offset)
            }
    }
}

extension SaveStatePrefix {
    struct SoundResourceMatch: Encodable, Sendable {
        let recordOffset: Int
        let status: EvidenceStatus
        let sourceSHA256: String?
        let issue: String?
        var vorbisHeader: EvidenceStatus? = nil
        var mediaIssue: String? = nil
        var stagedLocation: ScriptLocation? = nil
        var requestedSeekMilliseconds: Int32? = nil
        var seekStatus: EvidenceStatus? = nil
        var seekIssue: String? = nil
    }

    /// Match direct-load names against the available catalog. Native fallback paths
    /// and channel state are separate from this lookup.
    func soundResources(in state: Data, repository: ScriptRepository,
                        streamed: Bool = false) -> [SoundResourceMatch] {
        var remainingBytes = 64 * 1024 * 1024
        var attempts = 0
        let records = streamed ? ssndReferences : dsndReferences
        return records.compactMap { entry -> SoundResourceMatch? in
            let reload = streamed ? entry.streamChannel.map { $0.rawMode != 0 } : entry.directReloadRequested
            guard reload == true else { return nil }
            let field = entry.strings[0]
            let offset = entry.record.decodedOffset
            guard field.length <= 8192, field.decodedOffset <= state.count,
                  field.length <= state.count - field.decodedOffset,
                  let path = String(data: state.dropFirst(field.decodedOffset).prefix(field.length),
                                    encoding: .utf16LittleEndian) else {
                return .init(recordOffset: offset, status: .unsupported, sourceSHA256: nil,
                             issue: "invalid_saved_sound_name")
            }
            do {
                let source = try repository.catalog.resolve(path)
                var match = SoundResourceMatch(recordOffset: offset, status: .inferred,
                                               sourceSHA256: source.sourceSHA256, issue: nil)
                guard remainingBytes > 0, attempts < 64 else {
                    match.vorbisHeader = .notTested
                    match.mediaIssue = "saved_sound_validation_budget"
                    return match
                }
                attempts += 1
                do {
                    let data = try repository.directory.read(source.sourceFile, limit: min(remainingBytes, 16 * 1024 * 1024))
                    remainingBytes -= data.count
                    guard data.sha256Hex == source.sourceSHA256 else {
                        throw ResourceError.rejected("module_source_identity")
                    }
                    match.stagedLocation = try ScriptRepository.vorbisLocation(source, data: data)
                    match.vorbisHeader = .verified
                    if let stream = entry.streamChannel {
                        // The native x87 conversion uses its current rounding mode.
                        // Accept integral milliseconds independently of that mode.
                        let scaled = Double(Float(bitPattern: stream.rawSeekBits)) * 1000
                        if scaled >= 0, let milliseconds = Int32(exactly: scaled) {
                            match.requestedSeekMilliseconds = milliseconds
                            match.seekStatus = .verified
                        } else {
                            match.seekStatus = .unsupported
                            match.seekIssue = "saved_stream_seek_outside_exact_profile"
                        }
                    }
                } catch {
                    match.vorbisHeader = .unsupported
                    match.mediaIssue = String(describing: error)
                }
                return match
            } catch {
                return .init(recordOffset: offset, status: .unsupported, sourceSHA256: nil,
                             issue: String(describing: error))
            }
        }
    }

    package struct ARGBHeader: Encodable, Sendable {
        package let mode: UInt8
        package let firstPayloadLength: Int
        package let secondPayloadLength: Int

        package init(_ data: Data) throws {
            let magic = Data("ARGBSaveData1".utf8) + Data(repeating: 0, count: 3)
            guard data.count >= 25, data.starts(with: magic) else {
                throw ResourceError.rejected("invalid_saved_argb_header")
            }
            mode = data[data.startIndex + 16]
            firstPayloadLength = Int(Int32(bitPattern: try data.u32(17)))
            secondPayloadLength = Int(Int32(bitPattern: try data.u32(21)))
            guard firstPayloadLength >= 0, secondPayloadLength >= 0,
                  firstPayloadLength <= data.count - 25,
                  secondPayloadLength == data.count - 25 - firstPayloadLength else {
                throw ResourceError.rejected("invalid_saved_argb_payload_lengths")
            }
        }
    }

    package struct ImageLibrarySummary: Encodable, Sendable {
        struct Slot: Encodable, Sendable {
            let index: Int
            let name: SaveReaderCursor.Reference?
            let embeddedOffset: Int
            let embeddedLength: Int
            let embeddedSignature: String?
            let nativeReloadRequested: Bool
            let nativeDecoder: String?
        }
        let decodedOffset: Int
        let byteLength: Int
        let sourceName: SaveReaderCursor.Reference?
        let slots: [Slot]
        let generators: [SaveImageGenerators.Record]
    }

    private static func imageDecoder(for name: String) -> String? {
        let decoders = ["bmp": "BMP", "jpg": "JPEG", "png": "PNG", "dpng": "DPNG", "argb": "ARGB"]
        return decoders[asciiLower((name as NSString).pathExtension)]
    }

    static func imageDecoder(_ decoder: String?, accepts signature: String) -> Bool {
        guard let decoder else { return false }
        if decoder == "PNG" || decoder == "DPNG" {
            return signature == "PNG" || signature == "DPNG"
        }
        return decoder == signature
    }

    package struct DisplaySummary: Encodable, Sendable {
        package struct Reload: Encodable, Sendable {
            package struct Transform: Encodable, Sendable {
                package let translationX: Int32
                package let translationY: Int32
                package let scaleX: Double
                package let scaleY: Double
                package let rotationTurns: Double
            }
            let resource: SaveReaderCursor.Reference
            let rawOperands: [Int32]
            let normalizedOperands: [Double]
            package let transform: Transform

            package func readImage(in state: Data, catalog: ScriptModuleCatalog,
                                   directory: SafeDirectory) throws -> (ScriptModuleReference, Data) {
                let path = try resource.utf16Text(in: state)
                guard !path.isEmpty, path.utf8.count <= 4096 else {
                    throw ResourceError.rejected("saved_display_resource_name_outside_profile")
                }
                let source = try catalog.resolve(path)
                let bytes = try directory.read(source.sourceFile, limit: 16 * 1024 * 1024)
                guard bytes.sha256Hex == source.sourceSHA256 else {
                    throw ResourceError.rejected("module_source_identity")
                }
                let signature = InventoryScanner.signature(Data(bytes.prefix(16)))
                guard SaveStatePrefix.imageDecoder(SaveStatePrefix.imageDecoder(for: path), accepts: signature) else {
                    throw ResourceError.rejected("saved_display_resource_native_decoder_mismatch")
                }
                return (source, bytes)
            }

        }
        package struct ProceduralRect: Encodable, Sendable {
            package let left: Int32
            package let top: Int32
            package let right: Int32
            package let bottom: Int32
            package let colorARGB: UInt32

            init(_ text: String) throws {
                let fields = text.split(separator: ",", omittingEmptySubsequences: false)
                guard fields.count == 6, asciiLower(String(fields[0])) == "rect" else {
                    throw ResourceError.rejected("saved_display_rect_field_count")
                }
                func value(_ index: Int, fallback: Int32) throws -> Int32 {
                    let field = String(fields[index])
                    if field.isEmpty { return fallback }
                    guard let number = ScriptExpression.integerTextCache(field) else {
                        throw ResourceError.rejected("saved_display_rect_invalid_number")
                    }
                    return number
                }
                left = try value(1, fallback: 0)
                top = try value(2, fallback: 0)
                right = try value(3, fallback: 800)
                bottom = try value(4, fallback: 600)
                colorARGB = UInt32(bitPattern: try value(5, fallback: -1))
                guard right >= left, bottom >= top else {
                    throw ResourceError.rejected("saved_display_rect_inverted_edges")
                }
            }
        }
        struct ObjectSurfaceReplacement: Encodable, Sendable {
            let objectIndex: Int
            let displaySurfaceIndex: Int
            let embeddedOffset: Int?
            let requiresLiveDisplayFlags: Bool
        }
        let decodedOffset: Int
        let rawMode: UInt8
        let capturePriority: Int32?
        let surfaces: [ImageLibrarySummary.Slot]
        let nestedImageLibraryOffset: Int?
        let objectSurfaceReplacements: [ObjectSurfaceReplacement]?
        let postReplacementReloadRequested: Bool?
        let nestedImageLibrarySource: SaveReaderCursor.Reference?
        package let proceduralRect: ProceduralRect?
        package let proceduralRectIssue: String?
        package let externalReload: Reload?
    }

    package struct DisplayState: Encodable, Sendable {
        package let calValOffset: Int
        package let imageLibraries: [ImageLibrarySummary]
        package let display: DisplaySummary
    }

    package func inspectDisplayState(in state: Data) throws -> DisplayState {
        var libraries: [ImageLibrarySummary] = []
        var display: DisplaySummary?
        let offset = try locateCalVal(in: state, visitImageLibrary: { libraries.append($0) },
                                      visitDisplay: { display = $0 })
        guard let display else { throw ResourceError.rejected("saved_display_record_unavailable") }
        return .init(calValOffset: offset, imageLibraries: libraries, display: display)
    }

    package func inspectDisplay(in state: Data) throws -> DisplaySummary {
        var display: DisplaySummary?
        _ = try locateCalVal(in: state, visitImageLibrary: nil, visitDisplay: { display = $0 })
        guard let display else { throw ResourceError.rejected("saved_display_record_unavailable") }
        return display
    }

    package func displaySurfaceBytes(in state: Data, index: Int) throws -> Data {
        var selected: ImageLibrarySummary.Slot?
        _ = try locateCalVal(in: state, visitImageLibrary: nil, visitDisplay: { display in
            selected = display.surfaces.first { $0.index == index }
        })
        guard let selected else { throw ResourceError.rejected("saved_display_surface_unavailable") }
        guard let signature = selected.embeddedSignature,
              Self.imageDecoder(selected.nativeDecoder, accepts: signature) else {
            throw ResourceError.rejected("saved_display_surface_format_unsupported")
        }
        guard selected.embeddedLength <= 16 * 1024 * 1024 else {
            throw ResourceError.rejected("saved_display_surface_decode_budget")
        }
        let start = state.startIndex + selected.embeddedOffset
        return Data(state[start..<(start + selected.embeddedLength)])
    }

    @discardableResult
    static func walkImageLibrary(_ bytes: UnsafeRawBufferPointer, take: (Int) throws -> Int,
                                 integer: () throws -> Int, stringRange: () throws -> Range<Int>,
                                 imageSlot: ((Int, Range<Int>, Int, Int, Bool) -> ImageLibrarySummary.Slot)? = nil,
                                 visit: ((Int, Int, Range<Int>, [ImageLibrarySummary.Slot], [SaveImageGenerators.Record]) -> Void)? = nil) throws -> Bool {
        let start = try take(0xA5E)
        let sourceRange = try stringRange()
        var slots: [ImageLibrarySummary.Slot] = []
        for index in 0..<33 {
            let name = try stringRange()
            let length = try integer()
            let payload = try take(length)
            if let imageSlot, !name.isEmpty || length != 0 {
                slots.append(imageSlot(index, name, payload, length, length != 0))
            }
        }
        for _ in 0..<64 { _ = try stringRange() }
        _ = try take(256)
        var generators: [SaveImageGenerators.Record] = []
        let visitGenerator: ((SaveImageGenerators.Record) -> Void)? =
            imageSlot == nil ? nil : { generators.append($0) }
        for _ in 0..<4 { try SaveImageGenerators.skip(bytes, take: take, visit: visitGenerator) }
        try SaveImageGenerators.skipGroup(bytes, take: take, visit: visitGenerator)
        for _ in 0..<8 {
            _ = try take(4)
            _ = try stringRange()
        }
        _ = try stringRange()
        visit?(start, try take(0), sourceRange, slots, generators)
        return !sourceRange.isEmpty
    }

    /// Walk the two image libraries and display records in serialization order.
    package func locateCalVal(in state: Data) throws -> Int {
        try locateCalVal(in: state, visitImageLibrary: nil, visitDisplay: nil)
    }

    func locateCalVal(in state: Data, visitImageLibrary: ((ImageLibrarySummary) -> Void)?,
                      visitDisplay: ((DisplaySummary) -> Void)?) throws -> Int {
        try state.withUnsafeBytes { bytes in
            var offset = nextDecodedOffset
            func take(_ size: Int) throws -> Int {
                guard offset >= 0, offset <= bytes.count, size >= 0, size <= bytes.count - offset else {
                    throw ResourceError.rejected("invalid_save_image_display_bounds")
                }
                let start = offset
                offset += size
                return start
            }
            func integer() throws -> Int {
                Int(Int32(littleEndian: bytes.loadUnaligned(fromByteOffset: try take(4), as: Int32.self)))
            }
            func stringRange() throws -> Range<Int> {
                let size = Int(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: try take(2), as: Int16.self))) * 2
                let start = try take(size)
                return start..<(start + size)
            }
            func imageSlot(index: Int, nameRange: Range<Int>, payload: Int, length: Int, reloadRequested: Bool) -> ImageLibrarySummary.Slot {
                let name = nameRange.isEmpty ? nil : SaveReaderCursor.Reference(
                    decodedOffset: nameRange.lowerBound, length: nameRange.count,
                    sha256: Data(bytes[nameRange]).sha256Hex)
                let signature = length == 0 ? nil : InventoryScanner.signature(
                    Data(bytes[payload..<(payload + min(length, 16))]))
                // Both readers call 0x54f0c4, whose helper selects by saved suffix.
                let text = try? name?.utf16Text(in: state)
                let decoder = text.flatMap(Self.imageDecoder(for:))
                return .init(index: index, name: name, embeddedOffset: payload, embeddedLength: length,
                             embeddedSignature: signature, nativeReloadRequested: reloadRequested,
                             nativeDecoder: reloadRequested ? decoder : nil)
            }
            func imageLibrary() throws -> Bool {
                try Self.walkImageLibrary(bytes, take: take, integer: integer, stringRange: stringRange,
                    imageSlot: visitImageLibrary == nil ? nil : imageSlot, visit: { start, end, sourceRange, slots, generators in
                        guard let visitImageLibrary else { return }
                        let source = sourceRange.isEmpty ? nil : SaveReaderCursor.Reference(
                            decodedOffset: sourceRange.lowerBound, length: sourceRange.count,
                            sha256: Data(bytes[sourceRange]).sha256Hex)
                        visitImageLibrary(.init(decodedOffset: start, byteLength: end - start,
                                                sourceName: source, slots: slots, generators: generators))
                    })
            }

            _ = try imageLibrary()
            _ = try imageLibrary()
            let display = try take(140)
            let displayName = try stringRange()
            var surfaces: [ImageLibrarySummary.Slot] = []
            for (index, flag) in bytes[(display + 33)..<(display + 35)].enumerated() where flag == 1 {
                let nameRange = try stringRange()
                let length = try integer()
                let payload = try take(length)
                if visitDisplay != nil {
                    surfaces.append(imageSlot(index: index, nameRange: nameRange, payload: payload, length: length,
                                              reloadRequested: true))
                }
            }
            let mode = bytes[display + 9]
            let nestedOffset = mode == 9 ? offset : nil
            let nestedReload = nestedOffset == nil ? nil : try imageLibrary()
            var reload: DisplaySummary.Reload?
            if visitDisplay != nil, mode == 4 || mode == 5 {
                // 0x692518–0x692532 passes these signed words to 0x693cb0.
                let raw = (0..<5).map {
                    Int32(littleEndian: bytes.loadUnaligned(fromByteOffset: display + 52 + $0 * 4, as: Int32.self))
                }
                let divisors: [Double] = [1, 1, 100, 100, 360]
                let normalized = zip(raw, divisors).map { Double($0) / $1 }
                // 0x5368cd/0x5368da scale around the target center; 0x536929/0x536938 then translate.
                let transform = DisplaySummary.Reload.Transform(translationX: raw[0], translationY: raw[1],
                    scaleX: normalized[2], scaleY: normalized[3], rotationTurns: normalized[4])
                reload = .init(resource: .init(decodedOffset: displayName.lowerBound, length: displayName.count,
                                               sha256: Data(bytes[displayName]).sha256Hex),
                               rawOperands: raw, normalizedOperands: normalized, transform: transform)
            }
            let nestedSource = mode == 9 && !displayName.isEmpty ? SaveReaderCursor.Reference(
                decodedOffset: displayName.lowerBound, length: displayName.count,
                sha256: Data(bytes[displayName]).sha256Hex) : nil
            var rect: DisplaySummary.ProceduralRect?
            var rectIssue: String?
            if visitDisplay != nil, let nestedSource,
               let text = try? nestedSource.utf16Text(in: state), asciiLower(text).hasPrefix("rect,") {
                do { rect = try .init(text) }
                catch { rectIssue = String(describing: error) }
            }
            // 0x692565 and 0x692594 replace object image payloads before
            // loading the nested library. The second checks live flags.
            let replacements: [DisplaySummary.ObjectSurfaceReplacement]? = mode == 9 ? (0..<2).map { index in
                .init(objectIndex: index, displaySurfaceIndex: index,
                      embeddedOffset: surfaces.first { $0.index == index }?.embeddedOffset,
                      requiresLiveDisplayFlags: index == 1)
            } : nil
            // 0x6925b2 restores at +0x44, and eff ?c reads priority at +0x61.
            let capturePriority = mode == 1
                ? Int32(littleEndian: bytes.loadUnaligned(fromByteOffset: display + 29, as: Int32.self)) : nil
            visitDisplay?(.init(decodedOffset: display, rawMode: mode, capturePriority: capturePriority, surfaces: surfaces,
                                nestedImageLibraryOffset: nestedOffset, objectSurfaceReplacements: replacements,
                                postReplacementReloadRequested: nestedReload, nestedImageLibrarySource: nestedSource,
                                proceduralRect: rect, proceduralRectIssue: rectIssue, externalReload: reload))

            _ = try take(69)
            let count = try integer()
            guard (0...min(65_535, (bytes.count - offset) / 12)).contains(count) else {
                throw ResourceError.rejected("invalid_post_display_count")
            }
            for _ in 0..<count {
                _ = try take(4)
                for _ in 0..<4 { _ = try stringRange() }
            }
            _ = try take(4)
            for _ in 0..<27 {
                _ = try stringRange()
                _ = try take(12)
            }
            _ = try take(141)
            return offset
        }
    }
}

enum SaveImageGenerators {
    struct Record: Encodable, Sendable {
        let decodedOffset: Int
        let version: Int32
        let rawFlagsAt1C: [UInt8]
        let rawWordsAt04: [UInt32]
        let rawWordsAt24: [UInt32]
        let rawByteAt1F: UInt8?
        let rawWordAt20: UInt32?
        let generatorInputsAt10: [Float?]
        let generatorOutputsAt24: [Float?]
    }

    static func skip(_ bytes: UnsafeRawBufferPointer, take: (Int) throws -> Int,
                     visit: ((Record) -> Void)? = nil) throws {
        let start = try take(8)
        guard bytes[start..<(start + 8)].elementsEqual("vgene\0\0\0".utf8) else {
            throw ResourceError.rejected("invalid_image_generator_tag")
        }
        let version = Int32(littleEndian: bytes.loadUnaligned(fromByteOffset: try take(4), as: Int32.self))
        guard (1...3).contains(version) else { throw ResourceError.rejected("unsupported_image_generator_version") }
        let body = try take(version == 3 ? 44 : version == 2 ? 40 : 39)
        if let visit {
            func word(_ offset: Int) -> UInt32 {
                UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: body + offset, as: UInt32.self))
            }
            func finiteFloat(_ offset: Int) -> Float? {
                let value = Float(bitPattern: word(offset))
                return value.isFinite ? value : nil
            }
            // 0x5a6118 reads +0x10…+0x18 as Single and writes results to +0x24…+0x2c.
            visit(.init(decodedOffset: start, version: version,
                        rawFlagsAt1C: Array(bytes[body..<(body + 3)]),
                        rawWordsAt04: (0..<6).map { word(3 + $0 * 4) },
                        rawWordsAt24: (0..<3).map { word(27 + $0 * 4) },
                        rawByteAt1F: version >= 2 ? bytes[body + 39] : nil,
                        rawWordAt20: version >= 3 ? word(40) : nil,
                        generatorInputsAt10: (0..<3).map { finiteFloat(15 + $0 * 4) },
                        generatorOutputsAt24: (0..<3).map { finiteFloat(27 + $0 * 4) }))
        }
    }

    static func skipGroup(_ bytes: UnsafeRawBufferPointer, take: (Int) throws -> Int,
                          visit: ((Record) -> Void)? = nil) throws {
        let length = Int(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: try take(2), as: Int16.self))) * 2
        let start = try take(length)
        guard let descriptor = String(data: Data(bytes[start..<(start + length)]), encoding: .utf16LittleEndian) else {
            throw ResourceError.rejected("invalid_generator_group_encoding")
        }
        if descriptor.isEmpty { return }
        let delimiters = Set("()[]{}\"/".utf8)
        for field in descriptor.split(separator: "\\", omittingEmptySubsequences: false) {
            guard !field.isEmpty, field.utf8.allSatisfy({ (33...126).contains($0) && !delimiters.contains($0) }) else {
                throw ResourceError.rejected("generator_group_descriptor_unparsed")
            }
            try skip(bytes, take: take, visit: visit)
        }
    }
}
