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
    // TImoLog (0x5b02d8 / 0x5b01a8): 0x4c-byte header followed by 256
    // fixed entries, each containing four length-prefixed strings and four Int32s.
    let dialogueLogVersion: Int32
    let dialogueLogCount: Int32
    let dialogueLogCursor: Int32
    let dialogueLogRecords: [DialogueLogRecord]
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

    struct DialogueLogRecord: Encodable, Sendable {
        let strings: [SaveReaderCursor.Reference]
        let integerFields: [Int32]
    }

    struct DialogueLogEntry: Encodable, Sendable {
        let speaker: String
        let text: String
        let voice: String
        let extra: String
        let integerFields: [Int32]
    }

    struct StreamChannel: Encodable, Sendable {
        let rawMode: UInt8
        let rawLoadOption: UInt8
        let rawVolumeType: Int32
        let rawSeekBits: UInt32
        /// The slot stores the seek as IEEE-754 binary32 seconds. Keeping this
        /// exact value avoids an unnecessary milliseconds round-trip when the
        /// host audio API accepts fractional seconds.
        var resumeSeekSeconds: Double? {
            let seconds = Float(bitPattern: rawSeekBits)
            guard seconds.isFinite, seconds >= 0 else { return nil }
            return Double(seconds)
        }
        // Copied from player +0x508/+0x509 by 0x5a071a–0x5a0734 and
        // restored before the stream reload at 0x5a04d0–0x5a04de.
        let rawPlayerFlag508: UInt8
        let rawPlayerFlag509: UInt8
        // The native writer copies the delayed volume and pan triplets from
        // player +0x510…+0x524 into record +0x2b…+0x3f.
        let rawPlayerStateWords510To524: [Int32]
        // The native load path replays the channel setters from this record;
        // keep these auxiliary words raw until their full semantics are mapped.
        let rawVolumeControlArgumentAt08: Int32
        let rawPanControlArgumentAt21: Int32
        let playerFlagsMatchLiveState: EvidenceStatus = .notTested
        let resumeRepeatCount: Int32?
        let resumeVolume: Int32
        let resumePan: Int32

        func savedVolumeDelay() throws -> (target: Int32, duration: Int32, delay: Int32)? {
            let frames = rawPlayerStateWords510To524[2]
            guard frames > 0 else { return nil }
            let target = Float(bitPattern: UInt32(bitPattern: rawPlayerStateWords510To524[0])) * 256
            let seconds = Float(bitPattern: UInt32(bitPattern: rawPlayerStateWords510To524[1]))
            let duration = (Double(seconds) * 1_000).rounded(.toNearestOrEven)
            guard resumeRepeatCount != nil, (0...256).contains(resumeVolume),
                  (0...256).contains(target), let volume = Int32(exactly: target),
                  seconds >= 0, let milliseconds = Int32(exactly: duration) else {
                throw ResourceError.rejected("saved_stream_delayed_volume_outside_profile")
            }
            let remaining = (Double(frames) * 1_000 / 44_100).rounded(.toNearestOrEven)
            return (volume, milliseconds, max(1, Int32(remaining)))
        }

        var savedPanDelay: (targetBits: Int32, durationBits: Int32, delay: Int32)? {
            // 0x5a0589 exits both delay branches when the volume gate is closed.
            let frames = rawPlayerStateWords510To524[5]
            guard rawPlayerStateWords510To524[2] > 0, frames > 0 else { return nil }
            let remaining = (Double(frames) * 1_000 / 44_100).rounded(.toNearestOrEven)
            // 0x574790 stores these words verbatim while waiting. At expiry,
            // 0x572b0b and 0x572b14 pass the volume pair to the pan setter.
            return (rawPlayerStateWords510To524[3], rawPlayerStateWords510To524[4], max(1, Int32(remaining)))
        }

        func matchesEncodedMilliseconds(_ milliseconds: Int32) -> Bool {
            milliseconds >= 0 && rawSeekBits == Float(Double(milliseconds) / 1000).bitPattern
        }

        /// The stream reader restores these two player flags directly. The
        /// candidate host currently supports only the constructor defaults.
        var nativePlayerFlagsMatchFreshLoadDefaults: Bool {
            rawPlayerFlag508 == 1 && rawPlayerFlag509 == 1
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
            rawVolumeType = Int32(littleEndian: bytes.loadUnaligned(fromByteOffset: start + 0x11, as: Int32.self))
            rawSeekBits = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: start + 0x15, as: UInt32.self))
            rawPlayerFlag508 = bytes[start + 0x25]
            rawPlayerFlag509 = bytes[start + 0x26]
            rawPlayerStateWords510To524 = (0..<6).map { index in
                Int32(littleEndian: bytes.loadUnaligned(fromByteOffset: start + 0x2b + index * 4,
                                                        as: Int32.self))
            }
            rawVolumeControlArgumentAt08 = Int32(littleEndian: bytes.loadUnaligned(
                fromByteOffset: start + 0x08, as: Int32.self))
            rawPanControlArgumentAt21 = Int32(littleEndian: bytes.loadUnaligned(
                fromByteOffset: start + 0x21, as: Int32.self))
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
    let ssndBankOffset: Int
    let nextDecodedOffset: Int

    var streamPlayerFlagsMatchFreshLoadDefaults: Bool {
        ssndReferences.count == 32 && ssndReferences.allSatisfy {
            $0.streamChannel?.nativePlayerFlagsMatchFreshLoadDefaults == true
        }
    }

    package init(state: Data, after reader: SaveReaderCursor) throws {
        (pathCount, pathReferences, rawPathFlag, stateTableOffset, dialogueLogVersion, dialogueLogCount,
         dialogueLogCursor, dialogueLogRecords, soundOffset, dsndCount, ssndCount, dsndReferences,
         ssndReferences, ssndBankOffset, nextDecodedOffset) =
            try state.withUnsafeBytes { bytes in
                var offset = reader.nextDecodedOffset
                var streamBankOffset: Int?
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
                func int32(at offset: Int) -> Int32 {
                    Int32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: Int32.self))
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
                    if tag == "ssnd" { streamBankOffset = start }
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
                let headerStart = try take(76)
                let logVersion = int32(at: headerStart)
                let logCount = int32(at: headerStart + 4)
                let logCursor = int32(at: headerStart + 8)
                guard (0...256).contains(logCount), (0...255).contains(logCursor) else {
                    throw ResourceError.rejected("invalid_save_dialogue_log_header")
                }
                var logRecords: [DialogueLogRecord] = []
                logRecords.reserveCapacity(256)
                for _ in 0..<256 {
                    let fields = try (0..<4).map { _ in reference(try stringRange()) }
                    let integers = try (0..<4).map { _ -> Int32 in
                        int32(at: try take(4))
                    }
                    logRecords.append(.init(strings: fields, integerFields: integers))
                }
                let soundStart = offset
                let dsnd = try soundBank("dsnd", recordSize: 86, strings: 1)
                let ssnd = try soundBank("ssnd", recordSize: 131, strings: 2)
                guard let streamBankOffset else { throw ResourceError.rejected("save_stream_bank_missing") }
                return (paths, references, flag, tableStart, logVersion, logCount, logCursor, logRecords,
                        soundStart, dsnd.count, ssnd.count, dsnd, ssnd, streamBankOffset, offset)
            }
    }
}

extension SaveStatePrefix {
    /// Reject physical records the local active-entry model cannot preserve.
    func requireEmptyInactiveDialogueLogRecords() throws {
        guard dialogueLogRecords.count == 256, (0...256).contains(dialogueLogCount),
              (0...255).contains(dialogueLogCursor) else {
            throw ResourceError.rejected("saved_dialogue_log_rebuild_bounds")
        }
        let active = Set((0..<Int(dialogueLogCount)).map {
            (Int(dialogueLogCursor) - $0 - 1 + 256) % 256
        })
        for (index, record) in dialogueLogRecords.enumerated() where !active.contains(index) {
            guard record.strings.count == 4, record.integerFields.count == 4,
                  record.strings.allSatisfy({ $0.length == 0 }),
                  record.integerFields.allSatisfy({ $0 == 0 }) else {
                throw ResourceError.rejected("saved_dialogue_log_inactive_records_unmapped")
            }
        }
    }

    /// TImoLog's query indexes from the newest record at (cursor - 1) modulo 256.
    /// The native reader ignores the first header word but bounds the live count
    /// and ring cursor through its indexed query path.
    func decodedDialogueLog(in state: Data) throws -> [DialogueLogEntry] {
        guard stateTableOffset >= 0, soundOffset >= stateTableOffset,
              soundOffset <= state.count, dialogueLogRecords.count == 256 else {
            throw ResourceError.rejected("saved_dialogue_log_bounds")
        }
        func decode(_ reference: SaveReaderCursor.Reference) throws -> String {
            try reference.utf16Text(in: state)
        }
        return try (0..<Int(dialogueLogCount)).map { reverseIndex in
            let index = (Int(dialogueLogCursor) - reverseIndex - 1 + 256) % 256
            let entry = dialogueLogRecords[index]
            guard entry.strings.count == 4, entry.integerFields.count == 4 else {
                throw ResourceError.rejected("saved_dialogue_log_record_shape")
            }
            return .init(speaker: try decode(entry.strings[0]), text: try decode(entry.strings[1]),
                         voice: try decode(entry.strings[2]), extra: try decode(entry.strings[3]),
                         integerFields: entry.integerFields)
        }
    }

    /// Rewrite the native ring from the live host log. String lengths are signed
    /// UTF-16 code-unit counts, matching the original stream helper.
    func replacingDialogueLog(in state: Data, entries: [DialogueLogEntry]) throws -> Data {
        guard stateTableOffset >= 0, soundOffset >= stateTableOffset,
              soundOffset <= state.count, entries.count <= 20_000,
              dialogueLogRecords.count == 256 else {
            throw ResourceError.rejected("saved_dialogue_log_rebuild_bounds")
        }
        try requireEmptyInactiveDialogueLogRecords()
        func appendInt16(_ value: Int16, to data: inout Data) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func appendInt32(_ value: Int32, to data: inout Data) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func appendText(_ value: String, to data: inout Data) throws {
            guard let units = Int16(exactly: value.utf16.count),
                  let encoded = value.data(using: .utf16LittleEndian) else {
                throw ResourceError.rejected("saved_dialogue_log_string_limit")
            }
            appendInt16(units, to: &data)
            data.append(encoded)
        }
        let liveEntries = Array(entries.suffix(256))
        let cursor = Int32(liveEntries.count % 256)
        var log = Data(repeating: 0, count: 76)
        func replaceInt32(_ value: Int32, at offset: Int, in data: inout Data) {
            withUnsafeBytes(of: value.littleEndian) { data.replaceSubrange(offset..<(offset + 4), with: $0) }
        }
        replaceInt32(10, at: 0, in: &log)
        replaceInt32(Int32(liveEntries.count), at: 4, in: &log)
        replaceInt32(cursor, at: 8, in: &log)
        for slot in 0..<256 {
            let entry = slot < liveEntries.count ? liveEntries[slot] : nil
            let strings = entry.map { [$0.speaker, $0.text, $0.voice, $0.extra] } ?? ["", "", "", ""]
            for string in strings { try appendText(string, to: &log) }
            let integers = entry?.integerFields ?? [0, 0, 0, 0]
            guard integers.count == 4 else {
                throw ResourceError.rejected("saved_dialogue_log_integer_count")
            }
            for value in integers { appendInt32(value, to: &log) }
        }
        var result = Data(state.prefix(stateTableOffset))
        result.append(log)
        result.append(state.suffix(from: soundOffset))
        guard result.count <= SaveEnvelope.maxFileBytes else {
            throw ResourceError.rejected("saved_dialogue_log_state_size_limit")
        }
        return result
    }

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

    func replacingLiveDirectBank(in state: Data, storage: ScriptStorage,
                                 catalog: ScriptModuleCatalog) throws -> Data {
        let count = Int(storage.directSoundChannelCount)
        guard (1...16).contains(count), soundOffset >= 0,
              ssndBankOffset >= soundOffset + 12, ssndBankOffset <= state.count else {
            throw ResourceError.rejected("saved_direct_bank_outside_profile")
        }
        // 0x59feae writes version 10 and separate volume, mode and filename.
        // The native status query at 0x59f6a4 reads the buffer and play flags.
        let active = storage.soundChannels.filter { !ScriptStorage.isStreamHandle($0.key) && $0.value.playing }
        guard active.keys.allSatisfy({ handle in
            guard let index = ScriptStorage.directSoundIndex(handle) else { return false }
            return index < storage.directSoundChannelCount && storage.directSoundChannels[handle]?.resource != nil
        }) else { throw ResourceError.rejected("saved_direct_playback_identity_missing") }

        var bank = Data("dsnd\0\0\0\0".utf8)
        withUnsafeBytes(of: Int32(count).littleEndian) { bank.append(contentsOf: $0) }
        for index in 0..<count {
            let handle = ScriptStorage.directSoundHandle(index)
            let channel = storage.directSoundChannels[handle] ?? .init()
            guard (0...256).contains(channel.volume), (0...31).contains(channel.volumeType) else {
                throw ResourceError.rejected("saved_direct_controls_outside_profile")
            }
            var mode: UInt8 = 0
            var filename = Data()
            if let source = channel.resource {
                guard let name = channel.resourceName, !name.isEmpty, !name.contains("\0"),
                      let bytes = name.data(using: .utf16LittleEndian), bytes.count <= 8192 else {
                    throw ResourceError.rejected("saved_direct_name_unresolved")
                }
                try validateResourceName(name, channel: index, resource: source, catalog: catalog, bank: "direct")
                filename = bytes
                mode = 1
                if let playing = active[handle] {
                    guard source == playing.resource, playing.playbackStartStep != nil,
                          [-1, 0].contains(playing.loopRequest ?? 0) else {
                        throw ResourceError.rejected("saved_direct_playback_state_outside_profile")
                    }
                    mode = playing.loopRequest == -1 ? 3 : 2
                }
            }
            // Channel reset clears the 0x56-byte record. The admitted l
            // profile uses the default load option and bypasses no reloads.
            var record = Data(repeating: 0, count: 86)
            for (offset, value) in [(0, Int32(10)), (4, channel.volume), (9, channel.volumeType)] {
                withUnsafeBytes(of: value.littleEndian) { record.replaceSubrange(offset..<offset + 4, with: $0) }
            }
            record[8] = mode
            bank.append(record)
            withUnsafeBytes(of: Int16(filename.count / 2).littleEndian) { bank.append(contentsOf: $0) }
            bank.append(filename)
        }
        var result = state
        result.replaceSubrange((result.startIndex + soundOffset)..<(result.startIndex + ssndBankOffset), with: bank)
        let reader = try SaveReaderCursor(threadState: result)
        let rebuilt = try SaveStatePrefix(state: result, after: reader)
        guard rebuilt.dsndCount == count, rebuilt.ssndBankOffset == soundOffset + bank.count else {
            throw ResourceError.rejected("saved_direct_bank_roundtrip_shape")
        }
        return result
    }

    /// Only names present in the saved bank are candidates. Missing or invalid
    /// entries remain unknown rather than being synthesized as empty strings.
    func savedStreamNameCandidates(in state: Data) -> [Int32: String] {
        savedStreamStringCandidates(in: state, fieldIndex: 0)
    }

    func savedStreamFilterCandidates(in state: Data) -> [Int32: String] {
        savedStreamStringCandidates(in: state, fieldIndex: 1)
    }

    func savedDirectNameCandidates(in state: Data) -> [Int: String] {
        var names: [Int: String] = [:]
        for (index, entry) in dsndReferences.enumerated() where entry.directReloadRequested == true {
            guard let field = entry.strings.first, (1...8192).contains(field.length),
                  let text = try? field.utf16Text(in: state), !text.contains("\0") else { continue }
            names[index] = text
        }
        return names
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

    /// Rebuild the stream bank from the live channel table when the host has
    /// supplied the configured channel count. The original writer emits one
    /// 0x83-byte record and two strings per channel index; a donor with a
    /// shorter ssnd bank cannot represent later live channels.
    private func validateResourceName(_ name: String, channel: Int, resource: ScriptLocation,
                                      catalog: ScriptModuleCatalog, bank: String = "stream") throws {
        let resolved: ScriptModuleReference
        do { resolved = try catalog.resolve(name) }
        catch ResourceError.rejected("module_not_in_catalog") {
            if let packRange = resource.sourceFile.range(of: ".pack/"),
               let physicalName = try? ScriptModuleCatalog.key(String(resource.sourceFile[packRange.upperBound...])),
               let requestedName = try? ScriptModuleCatalog.key(name), physicalName == requestedName {
                return
            }
            let sourceSHA256 = resource.sourceSHA256
            let sourceFileSHA256 = Data(resource.sourceFile.utf8).sha256Hex
            let rangeSHA256 = resource.rangeSHA256
            let offset = resource.byteOffset
            let length = resource.byteLength
            throw ResourceError.rejected("saved_\(bank)_name_not_in_catalog:channel=\(channel):name_sha256=\(Data(name.utf8).sha256Hex):source_sha256=\(sourceSHA256):source_file_sha256=\(sourceFileSHA256):range_sha256=\(rangeSHA256):offset=\(offset):length=\(length)")
        }
        guard resolved.sourceFile.utf8.elementsEqual(resource.sourceFile.utf8),
              resolved.sourceSHA256 == resource.sourceSHA256 else {
            throw ResourceError.rejected("saved_\(bank)_write_name_source_mismatch")
        }
    }

    private func replacingLiveStreamBank(in state: Data, storage: ScriptStorage,
                                         catalog: ScriptModuleCatalog, positions: [Int32: Int32],
                                         streamPans: [Int32: ScriptMachine.SavedStreamPanSample],
                                         streamVolumes: [Int32: ScriptMachine.SavedDelayedVolumeSample],
                                         streamRepeats: [Int32: ScriptMachine.SavedFiniteRepeatSample],
                                         channelCount: Int) throws -> Data {
        guard channelCount == Int(ScriptStorage.streamChannelCount),
              channelCount > 0, channelCount <= 32,
              ssndBankOffset >= 0, nextDecodedOffset >= ssndBankOffset,
              nextDecodedOffset <= state.count else {
            throw ResourceError.rejected("saved_stream_bank_rebuild_outside_profile")
        }
        guard !storage.unknownStreamFieldsOnRestore else {
            throw ResourceError.rejected("saved_stream_bank_unknown_fields")
        }
        guard !storage.activeStreamFilterApplicationUnverified else {
            throw ResourceError.rejected("saved_stream_filter_application_unverified")
        }

        let activeChannels = Set(storage.soundChannels.compactMap { handle, channel -> Int32? in
            guard channel.playing else { return nil }
            return ScriptStorage.streamChannelIndex(handle)
        })
        guard activeChannels.allSatisfy({ (0..<channelCount).contains(Int($0)) }),
              Set(positions.keys) == activeChannels else {
            throw ResourceError.rejected(
                "saved_stream_write_position_coverage: live=\(activeChannels.sorted()) supplied=\(positions.keys.sorted())")
        }

        func appendInt16(_ value: Int16, to data: inout Data) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func appendInt32(_ value: Int32, to data: inout Data) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func replaceInt32(_ value: Int32, at offset: Int, in data: inout Data) {
            let bytes = withUnsafeBytes(of: value.littleEndian) { Data($0) }
            data.replaceSubrange(offset..<(offset + 4), with: bytes)
        }
        func appendText(_ value: String, to data: inout Data) throws {
            guard value.utf8.count <= 8192,
                  let units = Int16(exactly: value.utf16.count),
                  let encoded = value.data(using: .utf16LittleEndian) else {
                throw ResourceError.rejected("saved_stream_write_string_limit")
            }
            appendInt16(units, to: &data)
            data.append(encoded)
        }
        func sourceName(for channel: ScriptStorage.SoundChannel, index: Int) throws -> String {
            guard channel.requestedSourceNameKnown, channel.filterRequestKnown,
                  channel.volumeFilterCandidate == nil, channel.filterChainCandidateText == nil,
                  (channel.filterRequest ?? "").isEmpty else {
                throw ResourceError.rejected("saved_stream_write_name_or_filter_unobserved")
            }
            guard let resource = channel.resource else {
                if channel.playing { throw ResourceError.rejected("saved_stream_live_channel_outside_profile") }
                guard let name = channel.requestedSourceName, !name.isEmpty else { return "" }
                // An idle stream bank entry retains the last requested spelling
                // even when it has no currently loaded resource. Validate its
                // path shape, but do not require an asset copy merely to preserve
                // this dormant name in the save slot.
                _ = try ScriptModuleCatalog.key(name)
                return name
            }
            guard let name = channel.requestedSourceName, !name.isEmpty else {
                throw ResourceError.rejected("saved_stream_write_name_unobserved")
            }
            try validateResourceName(name, channel: index, resource: resource, catalog: catalog)
            return name
        }
        func liveControlIssue(_ channel: ScriptStorage.SoundChannel, acceptsActivePan: Bool, acceptsDelayedPan: Bool,
                              acceptsDelayedVolume: Bool) -> String? {
            var fields: [String] = []
            // Native 0x573798 clears player +0x518 when the volume delay is
            // zero, even while a volume transition is in progress. The saved
            // +0x33 gate then prevents 0x5a0390 from restarting that delayed
            // control. The native volume getter reads the target at +0x4d8,
            // so a handed-off, zero-delay transition can retain that target
            // while it is active, provided the playback identity still matches.
            let activeZeroDelayVolume = channel.playing && channel.resource != nil &&
                channel.playbackStartStep != nil &&
                channel.volumeControlPlaybackStep == channel.playbackStartStep &&
                channel.volumeControlToken != nil && !channel.volumeChangePending &&
                (channel.volumeDelay ?? 0) == 0 && (channel.volumeDuration ?? 0) > 0 &&
                channel.volumeDuration == channel.volumeLastDuration &&
                channel.volume.map { (0...256).contains($0) } == true
            // Also accept a matching observer-confirmed natural completion.
            let completedZeroDelayVolume = !channel.playing && channel.resource != nil &&
                channel.naturalCompletionStep != nil &&
                channel.naturalCompletionStep == channel.playbackStartStep &&
                channel.volumeControlPlaybackStep == channel.playbackStartStep &&
                channel.volumeControlToken != nil && !channel.volumeChangePending &&
                (channel.volumeDelay ?? 0) == 0 && (channel.volumeDuration ?? 0) > 0 &&
                channel.volume.map { (0...256).contains($0) } == true
            // 0x5a0848 forwards the volume setter to a loaded player without
            // checking the play flag. A zero-delay setter clears +0x518, so
            // the saved delayed-control gate is zero even if our host has not
            // consumed the request on an already inactive channel.
            let pendingIdleZeroDelayVolume = !channel.playing && channel.resource != nil &&
                channel.volumeChangePending && channel.volumeControlToken == nil &&
                (channel.volumeDelay ?? 0) == 0 && (channel.volumeDuration ?? 0) > 0 &&
                channel.volume.map { (0...256).contains($0) } == true
            if channel.volumeChangePending && !pendingIdleZeroDelayVolume { fields.append("volume_pending") }
            if channel.panChangePending { fields.append("pan_pending") }
            let acceptsVolume = completedZeroDelayVolume || activeZeroDelayVolume || acceptsDelayedVolume
            if channel.volumeControlToken != nil && !acceptsVolume { fields.append("volume_token") }
            if channel.panControlToken != nil && !acceptsActivePan { fields.append("pan_token") }
            if let duration = channel.volumeDuration, duration != 0 && !pendingIdleZeroDelayVolume && !acceptsVolume { fields.append("volume_duration=\(duration)") }
            if let delay = channel.volumeDelay, delay != 0 && !acceptsDelayedVolume { fields.append("volume_delay=\(delay)") }
            if let request = channel.panRequest {
                if request.duration != 0 && !acceptsActivePan { fields.append("pan_duration=\(request.duration)") }
                if request.delay != 0 && !acceptsDelayedPan { fields.append("pan_delay=\(request.delay)") }
            }
            return fields.isEmpty ? nil : fields.joined(separator: ",")
        }

        var bank = Data("ssnd\0\0\0\0".utf8)
        appendInt32(Int32(channelCount), to: &bank)
        var expectedModes: [Int: UInt8] = [:]
        var expectedNames: [Int: String] = [:]
        for index in 0..<channelCount {
            guard case .object(let handle) = try storage.readIndexed("snd", Int32(index)) else {
                throw ResourceError.rejected("saved_stream_channel_handle_unavailable")
            }
            let channel = storage.soundChannels[handle]
            var name = ""
            var filter = ""
            var mode: UInt8 = 0
            var milliseconds: Int32 = 0
            var repeats: Int32?
            var volume: Int32 = 256
            var volumeControlArgument: Int32 = 0
            var panControlArgument: Int32 = 0
            var selectedVolumeType: Int32 = 0
            var pan: Int32 = 0
            var delayedVolume: (target: Float, duration: Float, frames: Int32)?
            var delayedPan: (targetBits: Int32, durationBits: Int32, frames: Int32)?
            if let channel {
                let activePan = channel.playing && channel.resource != nil &&
                    channel.playbackStartStep != nil && channel.panControlPlaybackStep == channel.playbackStartStep &&
                    channel.panControlToken != nil && !channel.panChangePending
                let activeZeroDelayPan = activePan &&
                    channel.panRequest.map { $0.duration > 0 && $0.delay == 0 &&
                        $0.duration == channel.panLastDuration && (-256...256).contains($0.position) } == true
                let invariantPan = activeZeroDelayPan && channel.panControlIsInvariant &&
                    channel.panInvariantPlaybackStep == channel.playbackStartStep
                // 0x5744c8 samples the current pan independently of its delay gate.
                let observedPan = streamPans[Int32(index)].flatMap { sample -> ScriptMachine.SavedStreamPanSample? in
                    guard sample.playbackStep == channel.playbackStartStep,
                          sample.controlToken == channel.panControlToken else { return nil }
                    if sample.remainingFrames != nil {
                        guard activePan, (channel.panRequest?.delay ?? 0) > 0,
                              channel.savedPanDelayOperands != nil else { return nil }
                    } else if !activeZeroDelayPan { return nil }
                    return sample
                }
                let observedVolume = streamVolumes[Int32(index)].flatMap { sample -> ScriptMachine.SavedDelayedVolumeSample? in
                    guard channel.playing, channel.resource != nil, channel.playbackStartStep == sample.playbackStep,
                          channel.volumeControlPlaybackStep == sample.playbackStep, channel.volumeControlToken == sample.controlToken,
                          !channel.volumeChangePending, (channel.volumeDelay ?? 0) > 0,
                          channel.volume.map({ (0...256).contains($0) }) == true else { return nil }
                    return sample
                }
                if (channel.playing || channel.resource != nil),
                   let issue = liveControlIssue(channel, acceptsActivePan: invariantPan || observedPan != nil,
                                               acceptsDelayedPan: observedPan?.remainingFrames != nil,
                                               acceptsDelayedVolume: observedVolume != nil) {
                    throw ResourceError.rejected(
                        "saved_stream_live_control_outside_profile: channel=\(index) playing=\(channel.playing) resource=\(channel.resource != nil) \(issue)")
                }
                volume = channel.volume ?? 256
                if let observedVolume, observedVolume.remainingFrames > 0, let baseline = observedVolume.baselineVolume {
                    let milliseconds = channel.volumeDuration ?? 0
                    let seconds = Float(Double(milliseconds) / 1_000)
                    guard (Double(seconds) * 1_000).rounded(.toNearestOrEven) == Double(milliseconds) else {
                        throw ResourceError.rejected("saved_stream_delayed_volume_duration_precision")
                    }
                    delayedVolume = (Float(volume) / 256, seconds, observedVolume.remainingFrames)
                    volume = baseline
                }
                if let frames = observedPan?.remainingFrames, frames > 0,
                   let operands = channel.savedPanDelayOperands {
                    if delayedVolume != nil,
                       (channel.panRequest?.position != channel.volume || channel.panRequest?.duration != channel.volumeDuration) {
                        throw ResourceError.rejected("saved_stream_delayed_pan_volume_operands_replaced")
                    }
                    delayedPan = (operands.targetBits, operands.durationBits, frames)
                }
                selectedVolumeType = channel.volumeType ?? 0
                guard (0..<32).contains(selectedVolumeType) else {
                    throw ResourceError.rejected("saved_stream_volume_type_outside_profile")
                }
                // FUN_005a0848 stores its duration argument at record +0x08;
                // the selected volume type is a separate manager setting.
                volumeControlArgument = channel.volumeLastDuration
                panControlArgument = channel.panLastDuration
                pan = observedPan?.position ?? channel.panRequest?.position ?? 0
                guard (-256...256).contains(pan) else {
                    throw ResourceError.rejected("saved_stream_pan_outside_profile")
                }
                if channel.resource != nil || channel.playing || channel.requestedSourceName != nil {
                    name = try sourceName(for: channel, index: index)
                    filter = channel.filterRequest ?? ""
                } else if !channel.filterRequestKnown || !channel.requestedSourceNameKnown {
                    throw ResourceError.rejected("saved_stream_idle_fields_unobserved")
                }
                if channel.playing {
                    guard let loop = channel.loopRequest, loop >= -1,
                          let position = positions[Int32(index)], position >= 0 else {
                        throw ResourceError.rejected("saved_stream_repeat_count_or_position_unobserved")
                    }
                    let checkpoint = try Self.streamPlaybackCheckpoint(requested: loop,
                        playbackStep: channel.playbackStartStep, position: position, sample: streamRepeats[Int32(index)])
                    repeats = checkpoint.repeats
                    milliseconds = checkpoint.position
                    mode = loop == -1 ? 3 : 2
                } else if channel.resource != nil {
                    let loop = channel.loopRequest ?? 0
                    guard loop == -1 || loop == 0 else {
                        throw ResourceError.rejected("saved_stream_repeat_count_unobserved")
                    }
                    repeats = loop
                    milliseconds = channel.seekRequest ?? 0
                    mode = 1
                }
            }

            var record = Data(repeating: 0, count: 131)
            replaceInt32(10, at: 0, in: &record)
            replaceInt32(volume, at: 4, in: &record)
            replaceInt32(volumeControlArgument, at: 8, in: &record)
            replaceInt32(panControlArgument, at: 0x21, in: &record)
            record[0x10] = mode
            replaceInt32(selectedVolumeType, at: 0x11, in: &record)
            // The pinned EXE's player constructor sets +0x508/+0x509 to 1;
            // the per-channel initializer clears the record and sets defaults.
            record[0x25] = 1
            record[0x26] = 1
            if mode != 0 {
                record = try StreamChannel.replacingPlayback(
                    in: record, milliseconds: milliseconds,
                    repeats: mode >= 2 ? repeats : nil, volume: volume, pan: pan,
                    clearDelayedControls: true)
                if mode == 1, let repeats {
                    replaceInt32(repeats, at: 0x27, in: &record)
                }
            }
            if let delayedVolume {
                replaceInt32(Int32(bitPattern: delayedVolume.target.bitPattern), at: 0x2b, in: &record)
                replaceInt32(Int32(bitPattern: delayedVolume.duration.bitPattern), at: 0x2f, in: &record)
                replaceInt32(delayedVolume.frames, at: 0x33, in: &record)
            }
            if let delayedPan {
                replaceInt32(delayedPan.targetBits, at: 0x37, in: &record)
                replaceInt32(delayedPan.durationBits, at: 0x3b, in: &record)
                replaceInt32(delayedPan.frames, at: 0x3f, in: &record)
            }
            bank.append(record)
            try appendText(name, to: &bank)
            try appendText(filter, to: &bank)
            expectedModes[index] = mode
            expectedNames[index] = name
        }

        let oldBankLength = nextDecodedOffset - ssndBankOffset
        guard oldBankLength <= SaveEnvelope.maxFileBytes,
              bank.count <= SaveEnvelope.maxFileBytes - (state.count - oldBankLength) else {
            throw ResourceError.rejected("saved_stream_bank_size_limit")
        }
        var result = state
        result.replaceSubrange((result.startIndex + ssndBankOffset)..<(result.startIndex + nextDecodedOffset),
                               with: bank)
        let reader = try SaveReaderCursor(threadState: result)
        let rebuilt = try SaveStatePrefix(state: result, after: reader)
        guard rebuilt.ssndCount == channelCount,
              rebuilt.nextDecodedOffset == nextDecodedOffset + bank.count - oldBankLength else {
            throw ResourceError.rejected("saved_stream_bank_roundtrip_shape")
        }
        for (index, mode) in expectedModes {
            let entry = rebuilt.ssndReferences[index]
            guard entry.streamChannel?.rawMode == mode,
                  try entry.strings[0].utf16Text(in: result)
                    .utf16.elementsEqual(expectedNames[index, default: ""].utf16) else {
                throw ResourceError.rejected("saved_stream_bank_roundtrip_mismatch")
            }
        }
        return result
    }

    /// Apply host positions for every playing template channel as one update.
    /// Production slot assembly supplies the game's fixed configured channel
    /// count; isolated fixtures can omit it to preserve their short banks.
    func replacingLiveStreams(in state: Data, storage: ScriptStorage, catalog: ScriptModuleCatalog,
                              positions: [Int32: Int32],
                              streamPans: [Int32: ScriptMachine.SavedStreamPanSample] = [:],
                              streamVolumes: [Int32: ScriptMachine.SavedDelayedVolumeSample] = [:],
                              streamRepeats: [Int32: ScriptMachine.SavedFiniteRepeatSample] = [:],
                              channelCount: Int? = nil) throws -> Data {
        if let channelCount {
            return try replacingLiveStreamBank(in: state, storage: storage, catalog: catalog,
                                               positions: positions, streamPans: streamPans, streamVolumes: streamVolumes,
                                               streamRepeats: streamRepeats,
                                               channelCount: channelCount)
        }
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
            try validateResourceName(name.utf16Text(in: state), channel: index, resource: source,
                catalog: catalog)
            guard !live.volumeChangePending, !live.panChangePending,
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
                catalog: catalog, milliseconds: milliseconds, normalizeMode: true, repeatSample: streamRepeats[channel])
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
                try validateResourceName(name, channel: index, resource: source, catalog: catalog)
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

    private static func streamPlaybackCheckpoint(requested: Int32, playbackStep: Int?, position: Int32,
        sample: ScriptMachine.SavedFiniteRepeatSample?) throws -> (repeats: Int32, position: Int32) {
        if requested == -1 || requested == 0 { return (requested, position) }
        guard let sample, sample.requested == requested, sample.playbackStep == playbackStep else {
            throw ResourceError.rejected("saved_stream_repeat_count_unobserved")
        }
        return (sample.remaining, sample.positionMilliseconds)
    }

    func replacingLiveStreamPlayback(in state: Data, channel: Int32, storage: ScriptStorage,
                                     catalog: ScriptModuleCatalog, milliseconds: Int32, normalizeMode: Bool = false,
                                     repeatSample: ScriptMachine.SavedFiniteRepeatSample? = nil) throws -> Data {
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
        let checkpoint = try Self.streamPlaybackCheckpoint(requested: repeats,
            playbackStep: live.playbackStartStep, position: milliseconds, sample: repeatSample)
        return try replacingStreamPlayback(in: state, channel: Int(channel), source: source,
            catalog: catalog, milliseconds: checkpoint.position, repeats: checkpoint.repeats,
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
        var waveHeader: EvidenceStatus? = nil
        var mediaIssue: String? = nil
        var stagedLocation: ScriptLocation? = nil
        var requestedSeekMilliseconds: Int32? = nil
        var requestedSeekSeconds: Double? = nil
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
                if !streamed, data.count >= 12, data.prefix(4) == Data("RIFF".utf8),
                   data[8..<12] == Data("WAVE".utf8) {
                    match.stagedLocation = source.wholeFileLocation(byteLength: data.count)
                    match.waveHeader = .verified
                } else {
                    match.stagedLocation = try ScriptRepository.vorbisLocation(source, data: data)
                    match.vorbisHeader = .verified
                }
                if let stream = entry.streamChannel {
                    if let seconds = stream.resumeSeekSeconds {
                        match.requestedSeekSeconds = seconds
                        match.seekStatus = .verified
                        let scaled = seconds * 1000
                        if scaled <= Double(Int32.max) {
                            let milliseconds = Int32(scaled.rounded(.toNearestOrEven))
                        match.requestedSeekMilliseconds = milliseconds
                        } else {
                            match.seekStatus = .unsupported
                            match.seekIssue = "saved_stream_seek_out_of_range"
                        }
                    } else {
                        match.seekStatus = .unsupported
                        match.seekIssue = "saved_stream_seek_nonfinite_or_negative"
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
                                 visitFilterName: ((Range<Int>) -> Void)? = nil,
                                 visitLayerAuxiliaryBytes: ((Range<Int>) -> Void)? = nil,
                                 visitGeneratorGroup: ((Range<Int>, [SaveImageGenerators.Record]) -> Void)? = nil,
                                 visitAnchorName: ((Range<Int>) -> Void)? = nil,
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
        for _ in 0..<32 {
            let name = try stringRange()
            visitFilterName?(name)
        }
        let auxiliaryStart = try take(256)
        visitLayerAuxiliaryBytes?(auxiliaryStart..<(auxiliaryStart + 256))
        var generators: [SaveImageGenerators.Record] = []
        let visitGenerator: ((SaveImageGenerators.Record) -> Void)? =
            imageSlot == nil ? nil : { generators.append($0) }
        for _ in 0..<4 { try SaveImageGenerators.skip(bytes, take: take, visit: visitGenerator) }
        try SaveImageGenerators.skipGroup(bytes, take: take, visit: visitGenerator, visitGroup: visitGeneratorGroup)
        for _ in 0..<8 {
            let integerOffset = try take(4)
            visitUserInteger?(integerOffset..<(integerOffset + 4))
            let text = try stringRange()
            visitUserString?(text)
        }
        let anchor = try stringRange()
        visitAnchorName?(anchor)
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
                          visit: ((Record) -> Void)? = nil,
                          visitGroup: ((Range<Int>, [Record]) -> Void)? = nil) throws {
        let length = Int(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: try take(2), as: Int16.self))) * 2
        let start = try take(length)
        guard let descriptor = String(data: Data(bytes[start..<(start + length)]), encoding: .utf16LittleEndian) else {
            throw ResourceError.rejected("invalid_generator_group_encoding")
        }
        if descriptor.isEmpty { visitGroup?(start..<start, []); return }
        let delimiters = Set("()[]{}\"/".utf8)
        var records: [Record] = []
        for field in descriptor.split(separator: "\\", omittingEmptySubsequences: false) {
            guard !field.isEmpty, field.utf8.allSatisfy({ (33...126).contains($0) && !delimiters.contains($0) }) else {
                throw ResourceError.rejected("generator_group_descriptor_unparsed")
            }
            try skip(bytes, take: take, visit: { record in
                visit?(record)
                if visitGroup != nil { records.append(record) }
            })
        }
        visitGroup?(start..<(start + length), records)
    }
}
