import Foundation

/// Read-only validation for the Win32 save envelope (0x4e277c, 0x4e2578).
public struct SaveEnvelope: Encodable {
    public static let maxFileBytes = 16 * 1024 * 1024
    public let payloadLength: Int
    public let kind: String
    public let slot: SlotSections?

    public struct SlotSections: Encodable {
        public struct Section: Encodable {
            public let offset: Int
            public let length: Int
        }

        public let headerVersion: Int32
        public let transformed: Bool
        public let packed: Bool
        public let codec: UInt32
        public let metadata: [Section]
        /// Delphi TDateTime is a local wall-clock value. These components carry no time zone.
        public let savedLocalTime: DateComponents?
        public let savedMillisecond: Int?
        public let thumbnail: Section
        public let state: Section
        public let trailingBytes: Int
        public let headerVerification: Section

        fileprivate init(_ bytes: UnsafeRawBufferPointer) throws {
            headerVerification = Section(offset: 12 + 16, length: 40)
            headerVersion = Int32(littleEndian: bytes.loadUnaligned(fromByteOffset: 68, as: Int32.self))
            guard headerVersion <= 10 else {
                throw ResourceError.rejected("unsupported_slot_header_version")
            }
            transformed = bytes[72] != 0
            packed = bytes[73] != 0
            codec = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 82, as: UInt32.self))
            let timeBits = UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: 74, as: UInt64.self))
            let days = Double(bitPattern: timeBits)
            if days.isFinite, days > 0, days < 2_958_466 {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(secondsFromGMT: 0)!
                let milliseconds = Int64((days * 86_400_000).rounded())
                let date = Date(timeIntervalSince1970: Double(milliseconds / 1000 - 2_209_161_600))
                savedMillisecond = Int(milliseconds % 1000)
                savedLocalTime = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            } else {
                savedLocalTime = nil
                savedMillisecond = nil
            }
            var offset = 12 + 138
            func consume(_ length: Int) throws -> Int {
                guard length >= 0, length <= bytes.count - offset else {
                    throw ResourceError.rejected("slot_section_bounds")
                }
                let start = offset
                offset += length
                return start
            }
            var fields: [Section] = []
            for _ in 0..<8 {
                let start = try consume(2)
                let units = Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: start, as: Int16.self))
                let length = Int(units) * 2
                fields.append(Section(offset: try consume(length), length: length))
            }
            func section() throws -> Section {
                let start = try consume(4)
                let length = Int(Int32(littleEndian: bytes.loadUnaligned(fromByteOffset: start, as: Int32.self)))
                return Section(offset: try consume(length), length: length)
            }
            metadata = fields
            thumbnail = try section()
            state = try section()
            trailingBytes = bytes.count - offset
        }
    }

    /// The original ?gd handler returns eight strings in stored order.
    /// Keep these local to the caller. The inspection report encodes ranges only.
    public static func readSlotMetadata(_ data: Data) throws -> [String] {
        guard let slot = try Self(data).slot else { throw ResourceError.rejected("save_slot_required") }
        return try slot.metadata.map { field in
            if field.length == 0 { return "" }
            let start = data.startIndex + field.offset
            guard let text = String(data: data[start..<(start + field.length)], encoding: .utf16LittleEndian) else {
                throw ResourceError.rejected("invalid_save_metadata_encoding")
            }
            return text
        }
    }

    /// The optional inferred seed is only for inspecting slots with a known state signature.
    public static func decodeSlotState(_ data: Data, seed: UInt32? = nil, inferSeed: Bool = false) throws -> Data {
        guard let slot = try Self(data).slot else {
            throw ResourceError.rejected("save_slot_required")
        }
        var effectiveSeed = seed
        let inferred = inferSeed && seed == nil && slot.transformed
        if inferred, slot.state.length >= 8 {
            let knownPrefix: UInt32
            switch (slot.packed, slot.codec) {
            case (false, _): knownPrefix = 0x65726874 // "thre"
            case (true, 0): knownPrefix = 0xff435031 // "1PC" and 0xff
            case (true, 1): knownPrefix = 0x6c6e7572 // "runl"
            default: throw ResourceError.rejected("unknown_state_codec")
            }
            let start = slot.state.offset
            let first = data.withUnsafeBytes {
                UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: start, as: UInt32.self))
            }
            // Reverse only the first word. The decoder independently checks the full signature and stream bounds.
            effectiveSeed = seedFromFirstWord(stored: first, clear: knownPrefix, length: slot.state.length)
        }
        let payload = try readStatePayload(data, slot: slot, seed: effectiveSeed)
        let state: Data
        switch (slot.packed, slot.codec) {
        case (false, _): state = payload
        case (true, 0): state = try SaveBPE.decode(payload)
        case (true, 1): state = try SaveRunLength.decode(payload)
        default: throw ResourceError.rejected("unknown_state_codec")
        }
        if inferred, !state.starts(with: "thread\0\0".utf8) {
            throw ResourceError.rejected("inferred_seed_thread_signature_mismatch")
        }
        return state
    }

    /// Returns the verified slot state before decompression.
    public static func readStatePayload(_ data: Data, seed: UInt32? = nil) throws -> Data {
        guard let slot = try Self(data).slot else {
            throw ResourceError.rejected("save_slot_required")
        }
        return try readStatePayload(data, slot: slot, seed: seed)
    }

    private static func readStatePayload(_ data: Data, slot: SlotSections, seed: UInt32?) throws -> Data {
        let start = data.startIndex + slot.state.offset
        let payload = data[start..<(start + slot.state.length)]
        guard slot.transformed else { return Data(payload) }
        guard let seed else { throw ResourceError.rejected("state_seed_required") }
        return transformState(Data(payload), seed: seed, encoding: false)
    }

    private static func transformState(_ input: Data, seed: UInt32, encoding: Bool) -> Data {
        var output = input
        output.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            var low: UInt32 = 0xa73c5f9d
            var high = low
            var previousLow = (UInt32(bytes.count) &+ seed) ^ 0xfec9753e
            var previousHigh = previousLow
            for offset in stride(from: 0, to: bytes.count & ~7, by: 8) {
                low = (low &+ 0xce24f523) ^ previousLow
                high = (high &+ 0xce24f523) ^ previousHigh
                let inputLow = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                let inputHigh = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self))
                let first = inputLow ^ low
                let second = inputHigh ^ high
                previousLow = encoding ? first : inputLow
                previousHigh = encoding ? second : inputHigh
                bytes.storeBytes(of: first.littleEndian, toByteOffset: offset, as: UInt32.self)
                bytes.storeBytes(of: second.littleEndian, toByteOffset: offset + 4, as: UInt32.self)
            }
        }
        return output
    }

    private static func seedFromFirstWord(stored: UInt32, clear: UInt32, length: Int) -> UInt32 {
        let initial = stored ^ clear ^ (UInt32(0xa73c5f9d) &+ 0xce24f523) ^ 0xfec9753e
        return initial &- UInt32(length)
    }

    /// Compare against a caller-supplied clear header template. The
    /// verification field is independent of the state transformation flag.
    package static func verifySlotHeader(_ data: Data, clearTemplate: Data, seed: UInt32) throws {
        guard clearTemplate.count == 40, let slot = try Self(data).slot else {
            throw ResourceError.rejected("save_header_verification_bounds")
        }
        let start = data.startIndex + slot.headerVerification.offset
        let stored = data[start..<(start + slot.headerVerification.length)]
        var clear = transformState(Data(stored.prefix(32)), seed: seed, encoding: false)
        clear.append(contentsOf: stored.suffix(8))
        guard clear == clearTemplate else {
            throw ResourceError.rejected("save_header_verification_mismatch")
        }
    }

    package static func validatedSlotSeed(_ data: Data, clearTemplate: Data) throws -> UInt32 {
        guard clearTemplate.count == 40, let slot = try Self(data).slot else {
            throw ResourceError.rejected("save_header_verification_bounds")
        }
        let first = data.withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: slot.headerVerification.offset, as: UInt32.self))
        }
        let clear = clearTemplate.withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
        }
        let seed = seedFromFirstWord(stored: first, clear: clear, length: 32)
        try verifySlotHeader(data, clearTemplate: clearTemplate, seed: seed)
        return seed
    }

    /// File range mapped from PE VA 0x6908a4 for the pinned fourth-game executable.
    package static func slotHeaderTemplate(from directory: SafeDirectory, executable: String) throws -> Data {
        let binary = try directory.read(executable, limit: 64 * 1024 * 1024)
        guard binary.sha256Hex == "ad02b1115887b8e5b453d4b5760077e8b63e153bba1161e1704209cf3db5cda5" else {
            throw ResourceError.rejected("save_header_template_exe_identity")
        }
        let offset = 2_686_116
        return binary.subdata(in: offset..<(offset + 40))
    }

    private static func payloadChecksum(_ bytes: UnsafeRawBufferPointer) -> UInt32 {
    func advance(_ accumulator: UInt32, _ value: UInt32) -> UInt32 {
        let lower = (accumulator &+ value) & 0xffff
        let upper = ((accumulator >> 16) &+ (value >> 16)) << 16
        let combined = upper | lower
        return (combined << 3) | (combined >> 29)
    }
    var low: UInt32 = 0
    var high: UInt32 = 0
    var saltLow: UInt16 = 0
    var saltHigh: UInt16 = 0
    for offset in stride(from: 0, to: bytes.count & ~7, by: 8) {
        saltLow &+= 0x93a7
        saltHigh &+= 0xa357
        let salt = UInt32(saltLow) | (UInt32(saltHigh) << 16)
        low = advance(low, UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) ^ salt)
        high = advance(high, UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self)) ^ salt)
    }
    func signedHalf(_ value: UInt32) -> Int32 {
        Int32(Int16(bitPattern: UInt16(truncatingIfNeeded: value)))
    }
    let checksum = signedHalf(low) &* signedHalf(high)
        &+ signedHalf(low >> 16) &* signedHalf(high >> 16)
        return UInt32(bitPattern: checksum)
    }

    /// Wrap an already serialized, uncompressed state. A caller-provided seed
    /// enables the state feedback transform. A missing verification field
    /// produces a synthetic slot for native tests only.
    package static func encodeSlot(state: Data, metadata: [String], thumbnail: Data,
                                   savedDays: Double, seed: UInt32? = nil,
                                   headerVerification: Data? = nil) throws -> Data {
        guard metadata.count == 8, savedDays.isFinite, (0..<2_958_466).contains(savedDays),
              state.count <= maxFileBytes, thumbnail.count <= maxFileBytes else {
            throw ResourceError.rejected("save_slot_encoding_bounds")
        }
        var payload = Data(repeating: 0, count: 138)
        payload.replaceSubrange(0..<10, with: "IMOSAVE110".utf8)
        if let headerVerification {
            guard headerVerification.count == 40 else {
                throw ResourceError.rejected("save_header_verification_size")
            }
            payload.replaceSubrange(16..<56, with: headerVerification)
        }
        payload[56] = 10
        if seed != nil { payload[60] = 1 }
        withUnsafeBytes(of: savedDays.bitPattern.littleEndian) {
            payload.replaceSubrange(62..<70, with: $0)
        }
        for field in metadata {
            guard let units = Int16(exactly: field.utf16.count),
                  let text = field.data(using: .utf16LittleEndian) else {
                throw ResourceError.rejected("save_slot_metadata_encoding_bounds")
            }
            withUnsafeBytes(of: units.littleEndian) { payload.append(contentsOf: $0) }
            payload.append(text)
        }
        guard payload.count + 20 + state.count + thumbnail.count <= maxFileBytes else {
            throw ResourceError.rejected("save_envelope_size")
        }
        let storedState = seed.map { transformState(state, seed: $0, encoding: true) } ?? state
        for section in [thumbnail, storedState] {
            withUnsafeBytes(of: UInt32(section.count).littleEndian) { payload.append(contentsOf: $0) }
            payload.append(section)
        }
        return wrapPayload(payload)
    }

    /// Replace only the preview image in memory, preserving the stored state
    /// including its compression and transformation fields.
    package static func replacingSlotThumbnail(in data: Data, with jpeg: Data) throws -> Data {
        guard let slot = try Self(data).slot, InventoryScanner.signature(jpeg) == "JPEG",
              jpeg.count <= maxFileBytes - (data.count - slot.thumbnail.length) else {
            throw ResourceError.rejected("save_thumbnail_replacement_bounds")
        }
        let start = data.startIndex + slot.thumbnail.offset
        var payload = Data(data[(data.startIndex + 12)..<(start - 4)])
        withUnsafeBytes(of: UInt32(jpeg.count).littleEndian) { payload.append(contentsOf: $0) }
        payload.append(jpeg)
        payload.append(contentsOf: data[(start + slot.thumbnail.length)...])
        let result = wrapPayload(payload)
        _ = try Self(result)
        return result
    }

    package static func wrapPayload(_ payload: Data) -> Data {
        let checksum = payload.withUnsafeBytes { payloadChecksum($0) }
        var result = Data()
        for field: UInt32 in [0xfd324d4e, checksum, UInt32(payload.count)] {
            withUnsafeBytes(of: field.littleEndian) { result.append(contentsOf: $0) }
        }
        result.append(payload)
        return result
    }

    public init(_ data: Data) throws {
        guard (12...Self.maxFileBytes).contains(data.count) else {
            throw ResourceError.rejected("save_envelope_size")
        }
        (payloadLength, kind, slot) = try data.withUnsafeBytes { bytes in
            func word(_ offset: Int) -> UInt32 {
                UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            }
            guard word(0) == 0xfd324d4e else {
                throw ResourceError.rejected("save_envelope_magic")
            }
            let length = Int(word(8))
            guard length == bytes.count - 12 else {
                throw ResourceError.rejected("save_envelope_length")
            }
            let payloadBytes = UnsafeRawBufferPointer(rebasing: bytes[12...])
            guard Self.payloadChecksum(payloadBytes) == word(4) else {
                throw ResourceError.rejected("save_envelope_checksum")
            }
            let payload = bytes.dropFirst(12)
            if payload.starts(with: "IMOSYSDATA12".utf8) { return (length, "system", nil) }
            if payload.starts(with: "IMOSAVE110\0".utf8) {
                guard length >= 138 else { return (length, "truncated_slot_header", nil) }
                return (length, "slot", try SlotSections(bytes))
            }
            return (length, "unknown", nil)
        }
    }
}
