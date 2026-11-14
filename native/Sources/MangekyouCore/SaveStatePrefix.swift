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
        // Copied from player +0x508/+0x509 by 0x5a071a–0x5a0734 and
        // restored before the stream reload at 0x5a04d0–0x5a04de.
        let rawPlayerFlag508: UInt8
        let rawPlayerFlag509: UInt8
        let playerFlagsMatchLiveState: EvidenceStatus = .notTested
        let resumeRepeatCount: Int32?
        let resumeVolume: Int32
        let resumePan: Int32

        func matchesEncodedMilliseconds(_ milliseconds: Int32) -> Bool {
            milliseconds >= 0 && rawSeekBits == Float(Double(milliseconds) / 1000).bitPattern
        }

        /// Update playback fields of an existing streaming record. The caller
        /// verifies the resource identity and supplies the measured host cursor.
        static func replacingPlayback(in template: Data, milliseconds: Int32, repeats: Int32?,
                                      volume: Int32, pan: Int32, clearDelayedControls: Bool = false) throws -> Data {
            guard template.count == 131, milliseconds >= 0 else {
                throw ResourceError.rejected("saved_stream_write_outside_profile")
            }
            let mode = template[template.startIndex + 0x10]
            guard template[template.startIndex + 0x25] <= 1,
                  template[template.startIndex + 0x26] <= 1,
                  repeats.map({ mode >= 2 && $0 >= -1 }) ?? (mode == 1) else {
                throw ResourceError.rejected("saved_stream_write_outside_profile")
            }
            let seconds = Float(Double(milliseconds) / 1000)
            guard (Double(seconds) * 1000).rounded(.toNearestOrEven) == Double(milliseconds) else {
                throw ResourceError.rejected("saved_stream_write_seek_precision")
            }
            var record = Data(template)
            func replace(_ offset: Int, with bits: UInt32) {
                withUnsafeBytes(of: bits.littleEndian) { record.replaceSubrange(offset..<(offset + 4), with: $0) }
            }
            replace(4, with: UInt32(bitPattern: volume))
            replace(0x15, with: seconds.bitPattern)
            replace(0x1d, with: UInt32(bitPattern: pan))
            if let repeats { replace(0x27, with: UInt32(bitPattern: repeats)) }
            if clearDelayedControls {
                // 0x5a0584 and 0x5a05b6 restore delayed controls from these
                // counters. The live writer uses this only after checking that
                // neither local control has a timed or delayed request.
                replace(0x33, with: 0)
                replace(0x3f, with: 0)
            }
            return record
        }

        init(bytes: UnsafeRawBufferPointer, start: Int) {
            // 0x5a04e4 gates reload on +0x10, then passes +0x11 to
            // the loader and scales the float at +0x15 before seeking.
            rawMode = bytes[start + 0x10]
            rawLoadOption = bytes[start + 0x11]
            rawSeekBits = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: start + 0x15, as: UInt32.self))
            rawPlayerFlag508 = bytes[start + 0x25]
            rawPlayerFlag509 = bytes[start + 0x26]
            // 0x5a053e and 0x5a0560 pass these values to the volume and pan setters.
            resumeVolume = Int32(littleEndian: bytes.loadUnaligned(fromByteOffset: start + 4, as: Int32.self))
            resumePan = Int32(littleEndian: bytes.loadUnaligned(fromByteOffset: start + 0x1d, as: Int32.self))
            // 0x5a056f–0x5a057f passes record +0x27 to the play endpoint for modes >= 2.
            resumeRepeatCount = rawMode >= 2
                ? Int32(littleEndian: bytes.loadUnaligned(fromByteOffset: start + 0x27, as: Int32.self)) : nil
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
    /// Experimental slots have no live direct-buffer snapshot. Set the
    /// reader's reload-bypass byte so the donor cannot start an old sound.
    func bypassingDonorDirectReloads(in state: Data) -> Data {
        var result = state
        for entry in dsndReferences where entry.directReloadRequested == true {
            result[result.startIndex + entry.record.decodedOffset + 0x11] = 1
        }
        return result
    }

    /// The writer has no direct-buffer snapshot; never silently discard one.
    static func validateNoLiveDirectSounds(_ storage: ScriptStorage) throws {
        let activeDirectCount = storage.soundChannels.filter {
            !ScriptStorage.isStreamHandle($0.key) && $0.value.playing
        }.count
        guard activeDirectCount == 0 else {
            throw ResourceError.rejected("saved_direct_sound_live_state_unsupported: count=\(activeDirectCount)")
        }
    }

    /// Only names present in the saved bank are candidates. Missing or invalid
    /// entries remain unknown rather than being synthesized as empty strings.
    func savedStreamNameCandidates(in state: Data) -> [Int32: String] {
        savedStreamStringCandidates(in: state, fieldIndex: 0)
    }

    func savedStreamFilterCandidates(in state: Data) -> [Int32: String] {
        savedStreamStringCandidates(in: state, fieldIndex: 1)
    }

    private func savedStreamStringCandidates(in state: Data, fieldIndex: Int) -> [Int32: String] {
        var result: [Int32: String] = [:]
        for (index, entry) in ssndReferences.prefix(32).enumerated() {
            guard let stream = entry.streamChannel, stream.rawMode <= 3,
                  entry.strings.indices.contains(fieldIndex), entry.strings[fieldIndex].length <= 16_384,
                  let text = try? entry.strings[fieldIndex].utf16Text(in: state), text.utf8.count <= 8192 else { continue }
            result[Int32(index)] = text
        }
        return result
    }

    /// Apply host positions for every playing template channel as one update.
    func replacingLiveStreams(in state: Data, storage: ScriptStorage, catalog: ScriptModuleCatalog,
                              positions: [Int32: Int32]) throws -> Data {
        try Self.validateNoLiveDirectSounds(storage)
        guard ssndReferences.allSatisfy({ ($0.streamChannel?.rawMode ?? UInt8.max) <= 3 }) else {
            throw ResourceError.rejected("saved_stream_write_mode_outside_profile")
        }
        let playing = Set(ssndReferences.indices.compactMap { index -> Int32? in
            guard ssndReferences[index].streamChannel?.resumeRepeatCount != nil else { return nil }
            return Int32(index)
        })
        let liveHandles = Set(storage.soundChannels.keys.filter {
            ScriptStorage.isStreamHandle($0) && storage.soundChannels[$0]?.playing == true
        })
        let live = Set(liveHandles.compactMap(ScriptStorage.streamChannelIndex))
        guard Set(positions.keys) == live, live.allSatisfy({ channel in
            ssndReferences.indices.contains(Int(channel)) &&
                (1...3).contains(ssndReferences[Int(channel)].streamChannel?.rawMode ?? 0)
        }) else {
            throw ResourceError.rejected(
                "saved_stream_write_position_coverage: live=\(live.sorted()) template=\(playing.sorted()) supplied=\(positions.keys.sorted())")
        }
        var result = state
        let liveIdle = Set(storage.soundChannels.compactMap { handle, channel -> Int32? in
            guard !channel.playing, channel.resource != nil else { return nil }
            return ScriptStorage.streamChannelIndex(handle)
        })
        var matchedIdle = Set<Int32>()
        for (index, entry) in ssndReferences.enumerated() where entry.streamChannel?.rawMode == 1 {
            let channel = Int32(index)
            if live.contains(channel) { continue }
            if !liveIdle.contains(channel) {
                // Mode zero bypasses the saved stream reload.
                result[result.startIndex + entry.record.decodedOffset + 0x10] = 0
                continue
            }
            guard case .object(let handle) = try storage.readIndexed("snd", channel),
                  let live = storage.soundChannels[handle], let source = live.resource,
                  let name = entry.strings.first, name.length > 0 else {
                throw ResourceError.rejected("saved_idle_stream_write_source_mismatch")
            }
            guard live.filterRequestKnown, (live.filterRequest ?? "").isEmpty else {
                throw ResourceError.rejected("saved_stream_filter_application_unverified")
            }
            let reference = try catalog.resolve(name.utf16Text(in: state))
            guard reference.sourceFile == source.sourceFile, reference.sourceSHA256 == source.sourceSHA256,
                  !live.volumeChangePending, !live.panChangePending,
                  live.volumeControlToken == nil, live.panControlToken == nil,
                  (live.volumeDuration ?? 0) == 0, (live.volumeDelay ?? 0) == 0,
                  (live.panRequest?.duration ?? 0) == 0, (live.panRequest?.delay ?? 0) == 0 else {
                throw ResourceError.rejected("saved_idle_stream_write_state_mismatch")
            }
            let start = result.startIndex + entry.record.decodedOffset
            let range = start..<(start + 131)
            let encoded = try StreamChannel.replacingPlayback(in: Data(result[range]),
                milliseconds: live.seekRequest ?? 0, repeats: nil,
                volume: live.volume ?? 256, pan: live.panRequest?.position ?? 0, clearDelayedControls: true)
            result.replaceSubrange(range, with: encoded)
            matchedIdle.insert(channel)
        }
        guard matchedIdle == liveIdle else {
            throw ResourceError.rejected("saved_idle_stream_write_coverage")
        }
        for channel in playing.subtracting(live) {
            let entry = ssndReferences[Int(channel)]
            // A donor-only stream must not resume in the new state.
            result[result.startIndex + entry.record.decodedOffset + 0x10] = 0
        }
        for channel in live.sorted() {
            guard let milliseconds = positions[channel] else {
                throw ResourceError.rejected("saved_stream_write_position_coverage")
            }
            result = try replacingLiveStreamPlayback(in: result, channel: channel, storage: storage,
                                                       catalog: catalog, milliseconds: milliseconds, normalizeMode: true)
        }
        // The script can compare ?l verbatim. The donor's spelling is not a
        // substitute for the current channel name, even when both resolve to
        // the same resource. Apply string edits from the end so all audited
        // offsets remain valid until the bank is reparsed.
        var replacements: [(index: Int, fieldIndex: Int, range: Range<Int>, data: Data, value: String)] = []
        for (index, entry) in ssndReferences.enumerated() {
            guard let channelIndex = Int32(exactly: index), index < 32,
                  case .object(let handle) = try storage.readIndexed("snd", channelIndex),
                  entry.strings.count == 2 else {
                throw ResourceError.rejected("saved_stream_write_name_outside_profile")
            }
            let channel = storage.soundChannels[handle]
            guard channel != nil || !storage.unknownStreamFieldsOnRestore,
                  channel?.requestedSourceNameKnown != false, channel?.filterRequestKnown != false else {
                throw ResourceError.rejected("saved_stream_write_name_unobserved")
            }
            let name = channel?.requestedSourceName ?? ""
            if let source = channel?.resource {
                guard !name.isEmpty else { throw ResourceError.rejected("saved_stream_write_name_unobserved") }
                let resolved = try catalog.resolve(name)
                guard resolved.sourceFile.utf8.elementsEqual(source.sourceFile.utf8),
                      resolved.sourceSHA256 == source.sourceSHA256 else {
                    throw ResourceError.rejected("saved_stream_write_name_source_mismatch")
                }
            }
            for (fieldIndex, value) in [name, channel?.filterRequest ?? ""].enumerated() {
                let reference = entry.strings[fieldIndex]
                guard reference.decodedOffset >= 2, reference.decodedOffset <= state.count,
                      reference.length >= 0, reference.length <= state.count - reference.decodedOffset,
                      value.utf8.count <= 8192, let units = Int16(exactly: value.utf16.count),
                      let encoded = value.data(using: .utf16LittleEndian),
                      let existing = try? reference.utf16Text(in: state) else {
                    throw ResourceError.rejected("saved_stream_write_string_outside_profile")
                }
                if existing.utf16.elementsEqual(value.utf16) { continue }
                var field = Data()
                withUnsafeBytes(of: units.littleEndian) { field.append(contentsOf: $0) }
                field.append(encoded)
                replacements.append((index, fieldIndex, (reference.decodedOffset - 2)..<(reference.decodedOffset + reference.length), field, value))
            }
        }
        let delta = replacements.reduce(0) { $0 + $1.data.count - $1.range.count }
        guard delta <= SaveEnvelope.maxFileBytes - result.count else {
            throw ResourceError.rejected("saved_stream_write_name_limit")
        }
        for replacement in replacements.reversed() {
            result.replaceSubrange((result.startIndex + replacement.range.lowerBound)..<(result.startIndex + replacement.range.upperBound), with: replacement.data)
        }
        if !replacements.isEmpty {
            let reader = try SaveReaderCursor(threadState: result)
            let checked = try SaveStatePrefix(state: result, after: reader)
            guard checked.ssndCount == ssndCount, checked.nextDecodedOffset == nextDecodedOffset + delta else {
                throw ResourceError.rejected("saved_stream_write_name_roundtrip_shape")
            }
            for replacement in replacements {
                guard checked.ssndReferences.indices.contains(replacement.index),
                      checked.ssndReferences[replacement.index].strings.indices.contains(replacement.fieldIndex),
                      try checked.ssndReferences[replacement.index].strings[replacement.fieldIndex].utf16Text(in: result).utf16.elementsEqual(replacement.value.utf16) else {
                    throw ResourceError.rejected("saved_stream_write_name_roundtrip_mismatch")
                }
            }
        }
        return result
    }

    func replacingLiveStreamPlayback(in state: Data, channel: Int32, storage: ScriptStorage,
                                     catalog: ScriptModuleCatalog, milliseconds: Int32, normalizeMode: Bool = false) throws -> Data {
        guard channel >= 0, case .object(let handle) = try storage.readIndexed("snd", channel),
              let live = storage.soundChannels[handle], live.playing,
              let source = live.resource, let repeats = live.loopRequest,
              !live.volumeChangePending, !live.panChangePending,
              live.volumeControlToken == nil, live.panControlToken == nil,
              (live.volumeDuration ?? 0) == 0, (live.volumeDelay ?? 0) == 0,
              (live.panRequest?.duration ?? 0) == 0, (live.panRequest?.delay ?? 0) == 0 else {
            throw ResourceError.rejected("saved_stream_live_channel_outside_profile")
        }
        guard live.filterRequestKnown, (live.filterRequest ?? "").isEmpty else {
            throw ResourceError.rejected("saved_stream_filter_application_unverified")
        }
        // The original decrements the remaining finite repeat count at
        // 0x575966. A position sample does not reveal how many loops elapsed.
        guard repeats == -1 || repeats == 0 else {
            throw ResourceError.rejected("saved_stream_repeat_count_unobserved")
        }
        return try replacingStreamPlayback(in: state, channel: Int(channel), source: source,
            catalog: catalog, milliseconds: milliseconds, repeats: repeats,
            volume: live.volume ?? 256, pan: live.panRequest?.position ?? 0,
            normalizedMode: normalizeMode ? (repeats == -1 ? 3 : 2) : nil, clearDelayedControls: true)
    }

    func replacingStreamPlayback(in state: Data, channel: Int, source: ScriptLocation,
                                 catalog: ScriptModuleCatalog, milliseconds: Int32, repeats: Int32,
                                 volume: Int32, pan: Int32, normalizedMode: UInt8? = nil,
                                 clearDelayedControls: Bool = false) throws -> Data {
        guard ssndReferences.indices.contains(channel) else {
            throw ResourceError.rejected("saved_stream_write_channel_unavailable")
        }
        let entry = ssndReferences[channel]
        let offset = entry.record.decodedOffset
        let length = entry.record.length
        guard length >= 131, offset >= 0, offset <= state.count, length <= state.count - offset else {
            throw ResourceError.rejected("saved_stream_write_record_bounds")
        }
        let start = state.startIndex + offset
        guard Data(state[start..<(start + length)]).sha256Hex == entry.record.sha256,
              let name = entry.strings.first, name.length > 0 else {
            throw ResourceError.rejected("saved_stream_write_record_identity")
        }
        let reference = try catalog.resolve(name.utf16Text(in: state))
        guard reference.sourceFile.utf8.elementsEqual(source.sourceFile.utf8),
              reference.sourceSHA256 == source.sourceSHA256 else {
            throw ResourceError.rejected("saved_stream_write_source_mismatch")
        }
        let range = start..<(start + 131)
        var record = Data(state[range])
        if let normalizedMode {
            guard (2...3).contains(normalizedMode), (1...3).contains(record[record.startIndex + 0x10]) else {
                throw ResourceError.rejected("saved_stream_write_mode_outside_profile")
            }
            record[record.startIndex + 0x10] = normalizedMode
        }
        let encoded = try StreamChannel.replacingPlayback(in: record, milliseconds: milliseconds,
            repeats: repeats, volume: volume, pan: pan, clearDelayedControls: clearDelayedControls)
        var result = state
        result.replaceSubrange(range, with: encoded)
        return result
    }

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
        var repository = repository
        var remainingBytes = 64 * 1024 * 1024
        var attempts = 0
        let records = streamed ? ssndReferences : dsndReferences
        return records.compactMap { entry -> SoundResourceMatch? in
            let reload = streamed ? entry.streamChannel.map { $0.rawMode != 0 } : entry.directReloadRequested
            guard reload == true else { return nil }
            let field = entry.strings[0]
            let offset = entry.record.decodedOffset
            guard (1...8192).contains(field.length), let path = try? field.utf16Text(in: state),
                  !path.contains("\0") else {
                return .init(recordOffset: offset, status: .unsupported, sourceSHA256: nil,
                             issue: "invalid_saved_sound_name")
            }
            let knownSource = try? repository.catalog.resolve(path)
            var match = SoundResourceMatch(recordOffset: offset, status: .inferred,
                                           sourceSHA256: knownSource?.sourceSHA256, issue: nil)
            guard remainingBytes > 0, attempts < 64 else {
                match.vorbisHeader = .notTested
                match.mediaIssue = "saved_sound_validation_budget"
                return match
            }
            attempts += 1
            do {
                let (source, data) = try repository.readResource(path,
                    byteLimit: min(remainingBytes, 16 * 1024 * 1024))
                remainingBytes -= data.count
                match = SoundResourceMatch(recordOffset: offset, status: .inferred,
                                           sourceSHA256: source.sourceSHA256, issue: nil)
                match.stagedLocation = try ScriptRepository.vorbisLocation(source, data: data)
                match.vorbisHeader = .verified
                if let stream = entry.streamChannel {
                    // x87 uses the current rounding mode. A fractional value
                    // can be probed using nearest-even without claiming that
                    // the original process used that mode.
                    let scaled = Double(Float(bitPattern: stream.rawSeekBits)) * 1000
                    if scaled >= 0, let milliseconds = Int32(exactly: scaled.rounded(.toNearestOrEven)) {
                        match.requestedSeekMilliseconds = milliseconds
                        match.seekStatus = scaled == Double(milliseconds) ? .verified : .inferred
                        if match.seekStatus == .inferred {
                            match.seekIssue = "saved_stream_seek_rounding_mode_unverified"
                        }
                    } else {
                        match.seekStatus = .unsupported
                        match.seekIssue = "saved_stream_seek_out_of_range"
                    }
                }
            } catch {
                if match.sourceSHA256 == nil {
                    return .init(recordOffset: offset, status: .unsupported, sourceSHA256: nil,
                                 issue: String(describing: error))
                }
                match.vorbisHeader = .unsupported
                match.mediaIssue = String(describing: error)
            }
            return match
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

    static func imageDecoder(for name: String) -> String? {
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

            package func readImage(in state: Data, repository: inout ScriptRepository) throws -> (ScriptModuleReference, Data) {
                let path = try resource.utf16Text(in: state)
                guard !path.isEmpty, path.utf8.count <= 4096 else {
                    throw ResourceError.rejected("saved_display_resource_name_outside_profile")
                }
                let (source, bytes) = try repository.readResource(path, byteLimit: 16 * 1024 * 1024)
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

    /// Replace an embedded surface in the existing display profile. The host
    /// owns image encoding and validates the captured image before calling.
    func replacingDisplaySurface(in state: Data, index: Int, payload: Data) throws -> Data {
        let display = try inspectDisplay(in: state)
        guard let slot = display.surfaces.first(where: { $0.index == index }),
              slot.embeddedLength > 0, !payload.isEmpty,
              payload.count <= SaveEnvelope.maxFileBytes - (state.count - slot.embeddedLength),
              slot.embeddedSignature == InventoryScanner.signature(payload),
              Self.imageDecoder(slot.nativeDecoder, accepts: InventoryScanner.signature(payload)) else {
            throw ResourceError.rejected("saved_display_surface_write_outside_profile")
        }
        let start = state.startIndex + slot.embeddedOffset
        var result = state
        var encoded = withUnsafeBytes(of: Int32(payload.count).littleEndian) { Data($0) }
        encoded.append(payload)
        result.replaceSubrange((start - 4)..<(start + slot.embeddedLength), with: encoded)
        guard try displaySurfaceBytes(in: result, index: index) == payload else {
            throw ResourceError.rejected("saved_display_surface_write_roundtrip")
        }
        return result
    }

    @discardableResult
    static func walkImageLibrary(_ bytes: UnsafeRawBufferPointer, take: (Int) throws -> Int,
                                 integer: () throws -> Int, stringRange: () throws -> Range<Int>,
                                 imageSlot: ((Int, Range<Int>, Int, Int, Bool) -> ImageLibrarySummary.Slot)? = nil,
                                 visitUserInteger: ((Range<Int>) -> Void)? = nil,
                                 visitUserString: ((Range<Int>) -> Void)? = nil,
                                 visitSoundName: ((Range<Int>) -> Void)? = nil,
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
        for _ in 0..<32 {
            let sound = try stringRange()
            visitSoundName?(sound)
        }
        for _ in 0..<32 { _ = try stringRange() }
        _ = try take(256)
        var generators: [SaveImageGenerators.Record] = []
        let visitGenerator: ((SaveImageGenerators.Record) -> Void)? =
            imageSlot == nil ? nil : { generators.append($0) }
        for _ in 0..<4 { try SaveImageGenerators.skip(bytes, take: take, visit: visitGenerator) }
        try SaveImageGenerators.skipGroup(bytes, take: take, visit: visitGenerator)
        for _ in 0..<8 {
            let integerOffset = try take(4)
            visitUserInteger?(integerOffset..<(integerOffset + 4))
            let text = try stringRange()
            visitUserString?(text)
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
