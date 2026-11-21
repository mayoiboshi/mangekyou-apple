import Foundation

/// Coordinates a native storyline slot and the system data written with it.
/// The slot publication is the commit point. The journal contains an undo copy
/// of system data until the slot's publication has been synced.
package struct SaveTransaction {
    package enum Checkpoint {
        case journalSynced, systemSynced, slotStaged, slotSynced
    }

    private struct Journal: Codable {
        let version: Int
        let slotName: String
        let oldSlot: String?
        let newSlot: String
        let systemName: String
        let oldSystem: String?
        let newSystem: String

        func validate() throws {
            guard version == 1 else { throw ResourceError.rejected("save_transaction_journal_version") }
            let names = [slotName, systemName]
            let hashes = [oldSlot, newSlot, oldSystem, newSystem].compactMap { $0 }
            guard try names.allSatisfy({ try SafeDirectory.components($0).count == 1 && $0.utf8.count <= 255 }),
                  asciiLower(slotName).hasSuffix(".svd"),
                  asciiLower(systemName) != asciiLower(slotName),
                  asciiLower(systemName) != SaveTransaction.journalName,
                  hashes.allSatisfy({ $0.utf8.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }),
                  oldSystem != newSystem else {
                throw ResourceError.rejected("save_transaction_journal_invalid")
            }
        }
    }

    private static let journalName = ".mangekyou-save-transaction"
    private static let journalLimit = SafeDirectory.maximumAtomicReplacementBytes
    private static let saveLimit = SaveEnvelope.maxFileBytes
    private let directory: SafeDirectory

    /// Keep cooperating readers and writers out while an interrupted pair is
    /// recovered, then keep the directory stable through the caller's reads or write.
    package static func withRecoveredDirectory<T>(_ directory: SafeDirectory, allowRecovery: Bool = true,
                                                  _ body: (SaveTransaction) throws -> T) throws -> T {
        try directory.withExclusiveSaveAccess {
            let transaction = SaveTransaction(directory: directory)
            if let journal = try directory.readIfPresent(journalName, limit: journalLimit) {
                guard allowRecovery else {
                    throw ResourceError.rejected("save_transaction_recovery_requires_game_directory")
                }
                try transaction.recover(journal)
            }
            return try body(transaction)
        }
    }

    package func replacePair(slotName: String, slotData: Data, slotSeed: UInt32,
                             expectedSlot: SafeDirectory.AtomicDestinationExpectation,
                             systemName: String, originalSystem: Data?, updatedSystem: Data,
                             checkpoint: ((Checkpoint) -> Void)? = nil) throws -> SafeDirectory.AtomicReplacementReceipt {
        let oldSlot: String?
        switch expectedSlot {
        case .absent: oldSlot = nil
        case .sha256(let hash): oldSlot = hash
        }
        let newSlot = slotData.sha256Hex
        let oldSystem = originalSystem?.sha256Hex
        let newSystem = updatedSystem.sha256Hex
        guard try SaveEnvelope(updatedSystem).kind == "system",
              try originalSystem.map({ try SaveEnvelope($0).kind == "system" }) != false else {
            throw ResourceError.rejected("save_transaction_system_data_invalid")
        }
        _ = try SaveEnvelope.decodeSlotState(slotData, seed: slotSeed)
        guard try digest(slotName) == oldSlot, try digest(systemName) == oldSystem else {
            throw ResourceError.rejected("save_transaction_destination_changed")
        }
        let journal = Journal(version: 1, slotName: slotName, oldSlot: oldSlot, newSlot: newSlot, systemName: systemName,
                              oldSystem: oldSystem, newSystem: newSystem)
        try journal.validate()
        let expectedSystem: SafeDirectory.AtomicDestinationExpectation = oldSystem.map { .sha256($0) } ?? .absent
        if oldSlot == newSlot {
            return try directory.replaceAtomically(systemName, data: updatedSystem, limit: Self.saveLimit,
                                                   expectedDestination: expectedSystem)
        }
        let metadata = try JSONEncoder().encode(journal)
        guard metadata.count <= 4092 else { throw ResourceError.rejected("save_transaction_journal_bounds") }
        var record = withUnsafeBytes(of: UInt32(metadata.count).littleEndian) { Data($0) }
        record.append(metadata)
        if let originalSystem { record.append(originalSystem) }
        let preparation = try directory.replaceAtomically(Self.journalName, data: record, limit: Self.journalLimit,
                                                            expectedDestination: .absent)
        if let error = preparation.directorySyncError { throw ResourceError.system("sync_save_transaction_journal", error) }
        checkpoint?(.journalSynced)
        let publication: SafeDirectory.AtomicReplacementReceipt
        var publishedSystem = false
        do {
            let system = try directory.replaceAtomically(systemName, data: updatedSystem, limit: Self.saveLimit,
                                                          expectedDestination: expectedSystem)
            publishedSystem = true
            if let error = system.directorySyncError { throw ResourceError.system("sync_save_transaction_system", error) }
            checkpoint?(.systemSynced)
            publication = try SaveEnvelope.replaceSlotAtomically(slotName, in: directory, with: slotData, seed: slotSeed,
                expectedDestination: expectedSlot, beforePublish: {
                    checkpoint?(.slotStaged)
                    guard try digest(systemName) == newSystem else {
                        throw ResourceError.rejected("save_transaction_system_changed_before_slot_publication")
                    }
                })
        } catch let writeError {
            do {
                // No throwing hook runs after the slot commit. We know our
                // slot was never published, even if another writer changed it.
                if publishedSystem, try digest(systemName) == newSystem {
                    try restoreSystem(journal, backup: originalSystem)
                }
                try directory.syncSaveDirectory()
                try removeJournal(record)
            } catch let recoveryError {
                throw ResourceError.rejected("save_transaction_rollback_failed: \(writeError) / \(recoveryError)")
            }
            throw writeError
        }
        if publication.directorySyncError != nil { return publication }
        checkpoint?(.slotSynced)
        do { try removeJournal(record) }
        catch {
            return .init(directorySyncError: nil, cleanupIssue: "save_committed_transaction_cleanup_unconfirmed: \(error)")
        }
        return publication
    }

    private func digest(_ name: String) throws -> String? {
        try directory.readIfPresent(name, limit: Self.saveLimit)?.sha256Hex
    }

    private func recover(_ record: Data) throws {
        guard record.count >= 4 else { throw ResourceError.rejected("save_transaction_journal_bounds") }
        let length = Int(record.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) })
        guard (1...4092).contains(length), record.count >= 4 + length else {
            throw ResourceError.rejected("save_transaction_journal_bounds")
        }
        let journal: Journal
        do { journal = try JSONDecoder().decode(Journal.self, from: record.subdata(in: 4..<(4 + length))) }
        catch is DecodingError { throw ResourceError.rejected("save_transaction_journal_invalid") }
        try journal.validate()
        guard journal.oldSlot != journal.newSlot else { throw ResourceError.rejected("save_transaction_journal_invalid") }
        let backup = record.count == length + 4 ? nil : Data(record.dropFirst(length + 4))
        guard backup?.sha256Hex == journal.oldSystem,
              try backup.map({ try SaveEnvelope($0).kind == "system" }) != false else {
            throw ResourceError.rejected("save_transaction_backup_invalid")
        }
        let slot = try digest(journal.slotName)
        let system = try directory.readIfPresent(journal.systemName, limit: Self.saveLimit)
        let systemHash = system?.sha256Hex
        guard try system.map({ try SaveEnvelope($0).kind == "system" }) != false else {
            throw ResourceError.rejected("save_transaction_recovery_conflict")
        }
        if slot == journal.oldSlot {
            if systemHash == journal.newSystem {
                try restoreSystem(journal, backup: backup)
            } else if systemHash != journal.oldSystem {
                throw ResourceError.rejected("save_transaction_recovery_conflict")
            }
        } else if slot != journal.newSlot || systemHash != journal.newSystem {
            throw ResourceError.rejected("save_transaction_recovery_conflict")
        }
        try directory.syncSaveDirectory()
        try removeJournal(record)
    }

    private func restoreSystem(_ journal: Journal, backup: Data?) throws {
        if let backup {
            let rollback = try directory.replaceAtomically(journal.systemName, data: backup, limit: Self.saveLimit,
                                                            expectedDestination: .sha256(journal.newSystem))
            if let error = rollback.directorySyncError {
                throw ResourceError.system("sync_save_transaction_rollback", error)
            }
        } else {
            try directory.removeCreatedFile(journal.systemName, sha256: journal.newSystem, limit: Self.saveLimit)
        }
    }

    private func removeJournal(_ record: Data) throws {
        try directory.removeCreatedFile(Self.journalName, sha256: record.sha256Hex, limit: Self.journalLimit)
    }
}
