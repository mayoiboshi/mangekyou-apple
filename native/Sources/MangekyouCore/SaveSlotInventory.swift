import Foundation

public struct SaveSlotInventory {
    public struct Entry: Encodable {
        public let name: String
        public let status: EvidenceStatus
        public let envelope: SaveEnvelope?
        public internal(set) var issue: String?
        var stateValidation: EvidenceStatus? = nil
        package var stateValidationIssue: String? = nil
        var metadata: [String]? = nil
        var thumbnail: ScriptLocation? = nil
        var sourceSHA256: String? = nil

        enum CodingKeys: String, CodingKey {
            case name, status, envelope, issue, stateValidation, stateValidationIssue
        }
    }

    public static func scan(_ directory: SafeDirectory, includeMetadata: Bool = false,
                            validateThumbnail: ((Data) throws -> Void)? = nil) throws -> [Entry] {
        try scan(directory, includeMetadata: includeMetadata, validateThumbnail: validateThumbnail, validateState: nil)
    }

    package static func scanForPlayback(_ directory: SafeDirectory, headerTemplate: Data?,
                                        inferStateSeed: Bool = false, verifyUntransformedHeaders: Bool = true,
                                        validateThumbnail: ((Data) throws -> Void)? = nil) throws -> [Entry] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(4))
        var remainingDecoded = 128 * 1024 * 1024
        return try scan(directory, includeMetadata: true, validateThumbnail: validateThumbnail) { data, slot in
            let seed = try (slot.transformed || verifyUntransformedHeaders ? headerTemplate : nil)
                .map { try SaveEnvelope.validatedSlotSeed(data, clearTemplate: $0) }
            if slot.transformed, seed == nil, !inferStateSeed {
                return "save_inventory_state_requires_seed"
            }
            // Reserve room for one bounded decoder invocation. A deferred slot
            // still gets the full verification when the player selects it.
            guard remainingDecoded >= SaveEnvelope.maxFileBytes, clock.now < deadline else {
                return "save_inventory_state_check_deferred"
            }
            let state = try SaveEnvelope.decodeSlotState(data, seed: seed, inferSeed: inferStateSeed)
            remainingDecoded -= state.count
            _ = try SaveReaderCursor(playbackState: state)
            return nil
        }
    }

    private static func scan(_ directory: SafeDirectory, includeMetadata: Bool,
                             validateThumbnail: ((Data) throws -> Void)?,
                             validateState: ((Data, SaveEnvelope.SlotSections) throws -> String?)?) throws -> [Entry] {
        // An interrupted replacement can leave an otherwise valid save under
        // its private staging name. Only published paths enter the inventory.
        let entries = try directory.entries().filter { !$0.name.hasPrefix(".mangekyou-stage-") }
        guard entries.count <= 1024 else { throw ResourceError.rejected("save_inventory_entry_limit") }
        var remaining = 128 * 1024 * 1024
        let inspected: [Entry] = entries.compactMap { entry in
            let suffix = (entry.name as NSString).pathExtension.lowercased()
            let namedSave = suffix == "dat" || suffix == "svd"
            guard namedSave || (entry.kind == .regular && entry.size >= 12) else { return nil }
            do {
                guard entry.kind == .regular else { throw ResourceError.rejected("save_not_regular_file") }
                let data: Data? = try directory.withFile(entry.name) { fd, size in
                    if !namedSave {
                        guard size >= 12, try SafeDirectory.read(fd: fd, offset: 0, count: 4)
                            == Data([0x4e, 0x4d, 0x32, 0xfd]) else { return nil }
                    }
                    guard size <= min(remaining, SaveEnvelope.maxFileBytes) else {
                        throw ResourceError.rejected("save_inventory_byte_limit")
                    }
                    remaining -= Int(size)
                    return try SafeDirectory.read(fd: fd, offset: 0, count: Int(size))
                }
                guard let data else { return nil }
                let envelope = try SaveEnvelope(data)
                let recognized = envelope.kind == "slot" || envelope.kind == "system"
                var result = Entry(name: entry.name, status: recognized ? .verified : .unsupported,
                                   envelope: envelope, issue: recognized ? nil : "save_kind_unrecognized")
                if let slot = envelope.slot, let validateState {
                    let deferred = try validateState(data, slot)
                    result.stateValidation = deferred == nil ? .verified : .notTested
                    result.stateValidationIssue = deferred
                }
                if includeMetadata, let slot = envelope.slot {
                    result.metadata = try SaveEnvelope.readSlotMetadata(data)
                    let digest = data.sha256Hex
                    result.sourceSHA256 = digest
                    if slot.thumbnail.length > 0 {
                        let offset = slot.thumbnail.offset
                        let payload = data.subdata(in: offset..<(offset + slot.thumbnail.length))
                        if InventoryScanner.signature(payload) == "JPEG" {
                            do {
                                try validateThumbnail?(payload)
                                result.thumbnail = ScriptLocation(sourceFile: "save-slot/" + entry.name,
                                    sourceSHA256: digest, byteOffset: offset, byteLength: payload.count,
                                    rangeSHA256: payload.sha256Hex, lineNumber: 1)
                            } catch {
                                result.issue = "save_thumbnail_decode_failed: \(error)"
                            }
                        } else {
                            result.issue = "save_thumbnail_requires_jpeg"
                        }
                    }
                }
                return result
            } catch {
                return Entry(name: entry.name, status: .unsupported, envelope: nil, issue: String(describing: error))
            }
        }

        // Match the script save namespace's ASCII case folding. Never choose a
        // file arbitrarily when two host entries map to the same save name.
        let names = Dictionary(grouping: entries, by: { Data(asciiLower($0.name).utf8) })
        return inspected.map { entry in
            guard entry.envelope?.kind == "slot",
                  (names[Data(asciiLower(entry.name).utf8)]?.count ?? 0) > 1 else {
                return entry
            }
            return Entry(name: entry.name, status: .unsupported, envelope: entry.envelope,
                         issue: "ambiguous_save_slot_name")
        }
    }
}
