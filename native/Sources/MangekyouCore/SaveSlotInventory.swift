import Foundation

public struct SaveSlotInventory {
    public struct Entry: Encodable {
        public let name: String
        public let status: EvidenceStatus
        public let envelope: SaveEnvelope?
        public let issue: String?
        var metadata: [String]? = nil
        var thumbnail: ScriptLocation? = nil
        var sourceSHA256: String? = nil

        enum CodingKeys: String, CodingKey {
            case name, status, envelope, issue
        }
    }

    public static func scan(_ directory: SafeDirectory, includeMetadata: Bool = false) throws -> [Entry] {
        let entries = try directory.entries()
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
                if includeMetadata, let slot = envelope.slot {
                    result.metadata = try SaveEnvelope.readSlotMetadata(data)
                    let digest = data.sha256Hex
                    result.sourceSHA256 = digest
                    if slot.thumbnail.length > 0 {
                        let offset = slot.thumbnail.offset
                        let payload = data.subdata(in: offset..<(offset + slot.thumbnail.length))
                        guard InventoryScanner.signature(payload) == "JPEG" else {
                            throw ResourceError.rejected("save_thumbnail_requires_jpeg")
                        }
                        result.thumbnail = ScriptLocation(sourceFile: "save-slot/" + entry.name,
                            sourceSHA256: digest, byteOffset: offset, byteLength: payload.count,
                            rangeSHA256: payload.sha256Hex, lineNumber: 1)
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
