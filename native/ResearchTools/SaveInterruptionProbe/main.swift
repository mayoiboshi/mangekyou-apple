import Darwin
import Foundation
import MangekyouCore

private func emit(_ value: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}

private func sha(_ data: Data) -> String { data.sha256Hex }

private func requireRegularFile(_ path: String) throws {
    var info = stat()
    guard path.withCString({ lstat($0, &info) }) == 0,
          (info.st_mode & S_IFMT) == S_IFREG else {
        throw ResourceError.rejected("interrupt_probe_input_not_regular")
    }
}

private func pausePair(arguments: ArraySlice<String>) throws {
    let values = Array(arguments)
    guard values.count == 7, values[1] == "--save-dir", values[3] == "--replacement-dir",
          values[5] == "--game-dir" else {
        throw ResourceError.rejected("pair_interrupt_probe_arguments")
    }
    let stopAt: SaveTransaction.Checkpoint
    switch values[0] {
    case "journal": stopAt = .journalSynced
    case "system": stopAt = .systemSynced
    case "slot-staged": stopAt = .slotStaged
    case "slot": stopAt = .slotSynced
    default: throw ResourceError.rejected("pair_interrupt_probe_checkpoint")
    }
    let destination = try SafeDirectory(URL(fileURLWithPath: values[2], isDirectory: true))
    let replacement = try SafeDirectory(URL(fileURLWithPath: values[4], isDirectory: true))
    let game = try SafeDirectory(URL(fileURLWithPath: values[6], isDirectory: true))
    let outputPath = destination.root.standardizedFileURL.pathComponents.map { $0.lowercased() }
    for input in [replacement, game] {
        let inputPath = input.root.standardizedFileURL.pathComponents.map { $0.lowercased() }
        guard !outputPath.starts(with: inputPath), !inputPath.starts(with: outputPath) else {
            throw ResourceError.rejected("pair_interrupt_probe_overlaps_input")
        }
    }
    let exe = "美少女万華鏡４.exe"
    let slotHeader = try SaveEnvelope.slotHeaderTemplate(from: game, executable: exe)
    let systemHeader = try SaveSystemData.headerTemplate(from: game, executable: exe)
    let slot = "SaveData0.svd", system = "SystemData.dat"
    let newSlot = try replacement.read(slot, limit: SaveEnvelope.maxFileBytes)
    let newSystem = try replacement.read(system, limit: SaveEnvelope.maxFileBytes)
    let seed = try SaveEnvelope.validatedSlotSeed(newSlot, clearTemplate: slotHeader)
    _ = try SaveSystemData(data: newSystem, headerTemplate: systemHeader)
    try SaveTransaction.withRecoveredDirectory(destination) { transaction in
        let present = Set(try destination.entries().map(\.name))
        let oldSlot = present.contains(slot) ? try destination.read(slot, limit: SaveEnvelope.maxFileBytes) : nil
        let oldSystem = present.contains(system) ? try destination.read(system, limit: SaveEnvelope.maxFileBytes) : nil
        if let oldSlot { _ = try SaveEnvelope.validatedSlotSeed(oldSlot, clearTemplate: slotHeader) }
        if let oldSystem { _ = try SaveSystemData(data: oldSystem, headerTemplate: systemHeader) }
        _ = try transaction.replacePair(slotName: slot, slotData: newSlot, slotSeed: seed,
            expectedSlot: oldSlot.map { .sha256($0.sha256Hex) } ?? .absent, systemName: system,
            originalSystem: oldSystem, updatedSystem: newSystem) { checkpoint in
            if checkpoint == stopAt { _ = raise(SIGSTOP) }
        }
    }
    throw ResourceError.rejected("pair_interrupt_probe_completed_without_interrupt")
}

private func child(arguments: ArraySlice<String>) throws -> Never {
    guard arguments.count == 6 else { throw ResourceError.rejected("interrupt_probe_child_arguments") }
    let values = Array(arguments)
    let mode = values[0]
    guard mode == "before" || mode == "after" else {
        throw ResourceError.rejected("interrupt_probe_mode")
    }
    let directory = try SafeDirectory(URL(fileURLWithPath: values[1], isDirectory: true))
    let slot = values[2]
    let replacementURL = URL(fileURLWithPath: values[3])
    try requireRegularFile(replacementURL.path)
    guard !replacementURL.path.hasPrefix(directory.root.path + "/") else {
        throw ResourceError.rejected("interrupt_probe_replacement_path")
    }
    let replacementDirectory = try SafeDirectory(replacementURL.deletingLastPathComponent())
    let replacement = try replacementDirectory.read(replacementURL.lastPathComponent,
        limit: SaveEnvelope.maxFileBytes)
    let gameDirectory = try SafeDirectory(URL(fileURLWithPath: values[4], isDirectory: true))
    let header = try SaveEnvelope.slotHeaderTemplate(from: gameDirectory, executable: values[5])
    let seed = try SaveEnvelope.validatedSlotSeed(replacement, clearTemplate: header)

    let stop = {
        guard raise(SIGSTOP) == 0 else {
            throw ResourceError.system("interrupt_probe_sigstop", errno)
        }
        throw ResourceError.rejected("interrupt_probe_resumed_unexpectedly")
    }
    if mode == "before" {
        try SaveEnvelope.replaceSlotAtomically(slot, in: directory, with: replacement,
            seed: seed, beforePublish: stop)
    } else {
        try SaveEnvelope.replaceSlotAtomically(slot, in: directory, with: replacement,
            seed: seed, afterPublish: stop)
    }
    throw ResourceError.rejected("interrupt_probe_publish_unexpectedly_completed")
}

private func parent(arguments: ArraySlice<String>) throws -> [String: Any] {
    guard arguments.count == 5 else { throw ResourceError.rejected("interrupt_probe_parent_arguments") }
    let values = Array(arguments)
    let mode = values[0]
    guard mode == "before" || mode == "after" else {
        throw ResourceError.rejected("interrupt_probe_mode")
    }
    let directoryURL = URL(fileURLWithPath: values[1], isDirectory: true)
    let directory = try SafeDirectory(directoryURL)
    let slot = values[2]
    let oldBytes = try directory.read(slot, limit: SaveEnvelope.maxFileBytes)
    let replacementURL = URL(fileURLWithPath: values[3])
    try requireRegularFile(replacementURL.path)
    let replacementDirectory = try SafeDirectory(replacementURL.deletingLastPathComponent())
    let replacement = try replacementDirectory.read(replacementURL.lastPathComponent,
        limit: SaveEnvelope.maxFileBytes)
    let gameDirectory = try SafeDirectory(URL(fileURLWithPath: values[4], isDirectory: true))
    let header = try SaveEnvelope.slotHeaderTemplate(from: gameDirectory, executable: "美少女万華鏡４.exe")
    let oldSeed = try SaveEnvelope.validatedSlotSeed(oldBytes, clearTemplate: header)
    let replacementSeed = try SaveEnvelope.validatedSlotSeed(replacement, clearTemplate: header)
    guard sha(oldBytes) != sha(replacement) else { throw ResourceError.rejected("interrupt_probe_slots_identical") }

    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
    let childArguments = [executable, "--child", mode, directoryURL.path, slot,
                         replacementURL.path, gameDirectory.root.path, "美少女万華鏡４.exe"]
    var cArguments: [UnsafeMutablePointer<CChar>?] = childArguments.map { strdup($0) }
    cArguments.append(nil)
    defer { cArguments.forEach { if let value = $0 { free(value) } } }
    var childPID: pid_t = 0
    let spawnStatus = executable.withCString { path in
        cArguments.withUnsafeBufferPointer { arguments in
            posix_spawn(&childPID, path, nil, nil, arguments.baseAddress!, environ)
        }
    }
    guard spawnStatus == 0 else { throw ResourceError.system("interrupt_probe_spawn", spawnStatus) }

    var waitStatus: Int32 = 0
    guard waitpid(childPID, &waitStatus, WUNTRACED) == childPID else {
        let code = errno
        _ = kill(childPID, SIGKILL)
        _ = waitpid(childPID, &waitStatus, 0)
        throw ResourceError.system("interrupt_probe_wait_stopped", code)
    }
    guard (waitStatus & 0xff) == 0x7f else {
        let exitStatus = waitStatus
        let beforeCleanup = try directory.entries().filter { $0.name.hasPrefix(".mangekyou-stage-") }
        _ = kill(childPID, SIGKILL)
        _ = waitpid(childPID, &waitStatus, 0)
        throw ResourceError.rejected("interrupt_probe_child_not_stopped:\(exitStatus):stages=\(beforeCleanup.count)")
    }

    let staged = try directory.entries().filter { $0.name.hasPrefix(".mangekyou-stage-") }
    let expectedStageCount = mode == "before" ? 1 : 0
    guard staged.count == expectedStageCount, staged.allSatisfy({ $0.kind == .regular }) else {
        _ = kill(childPID, SIGKILL)
        _ = waitpid(childPID, &waitStatus, 0)
        throw ResourceError.rejected("interrupt_probe_stage_count_mismatch")
    }
    let stagedBytes = try staged.first.map { try directory.read($0.name, limit: SaveEnvelope.maxFileBytes) }
    let targetBeforeKill = try directory.read(slot, limit: SaveEnvelope.maxFileBytes)
    let expectedBeforeKill = mode == "before" ? oldBytes : replacement
    guard stagedBytes.map(sha) == (mode == "before" ? sha(replacement) : nil),
          sha(targetBeforeKill) == sha(expectedBeforeKill) else {
        _ = kill(childPID, SIGKILL)
        _ = waitpid(childPID, &waitStatus, 0)
        throw ResourceError.rejected("interrupt_probe_commit_identity_mismatch")
    }

    guard kill(childPID, SIGKILL) == 0 else {
        let code = errno
        _ = waitpid(childPID, &waitStatus, 0)
        throw ResourceError.system("interrupt_probe_kill", code)
    }
    guard waitpid(childPID, &waitStatus, 0) == childPID,
          (waitStatus & 0x7f) == SIGKILL else {
        throw ResourceError.rejected("interrupt_probe_child_not_killed")
    }
    let targetAfterKill = try directory.read(slot, limit: SaveEnvelope.maxFileBytes)
    let stagesAfterKill = try directory.entries().filter { $0.name.hasPrefix(".mangekyou-stage-") }
    let expectedAfterKill = mode == "before" ? oldBytes : replacement
    let expectedSeedAfterKill = mode == "before" ? oldSeed : replacementSeed
    let targetStateAfterKill = try SaveEnvelope.decodeSlotState(targetAfterKill, seed: expectedSeedAfterKill)
    let expectedStateAfterKill = try SaveEnvelope.decodeSlotState(expectedAfterKill, seed: expectedSeedAfterKill)
    guard sha(targetAfterKill) == sha(expectedAfterKill),
          sha(targetStateAfterKill) == sha(expectedStateAfterKill),
          stagesAfterKill.map(\.name) == staged.map(\.name) else {
        throw ResourceError.rejected("interrupt_probe_postkill_state_mismatch")
    }

    if let orphan = staged.first {
        let stageURL = directoryURL.appendingPathComponent(orphan.name)
        try FileManager.default.removeItem(at: stageURL)
    }
    let remaining = try directory.entries().filter { $0.name.hasPrefix(".mangekyou-stage-") }
    guard remaining.isEmpty else { throw ResourceError.rejected("interrupt_probe_stage_cleanup_failed") }
    return [
        "status": "verified",
        "scope": mode == "before"
            ? "Private copy only; child was SIGKILLed after staged slot fsync and verification but before renameat publication."
            : "Private copy only; child was SIGKILLed after renameat publication and parent-directory fsync.",
        "interruptionPoint": mode,
        "slot": slot,
        "oldSHA256": sha(oldBytes),
        "replacementSHA256": sha(replacement),
        "stagedSHA256AtPause": stagedBytes.map(sha) as Any? ?? NSNull(),
        "stagingFileCountAtPause": staged.count,
        "stagingFileCountAfterCleanup": remaining.count,
        "childStoppedAtPublishHook": true,
        "childTerminatedBySIGKILL": true,
        "targetSHA256AfterKill": sha(targetAfterKill),
        "targetMatchesExpectedAfterKill": sha(targetAfterKill) == sha(expectedAfterKill),
        "targetSlotStateSHA256AfterKill": sha(targetStateAfterKill),
        "targetSlotStateMatchesExpectedAfterKill": sha(targetStateAfterKill) == sha(expectedStateAfterKill),
        "gameExecutableSHA256": "ad02b1115887b8e5b453d4b5760077e8b63e153bba1161e1704209cf3db5cda5",
        "originalFilesWritten": false
    ]
}

private func makeInactiveLogFixture(arguments: ArraySlice<String>) throws -> [String: Any] {
    guard arguments.count == 3 else { throw ResourceError.rejected("inactive_log_fixture_arguments") }
    let values = Array(arguments)
    let sourceURL = URL(fileURLWithPath: values[0])
    try requireRegularFile(sourceURL.path)
    let sourceDirectory = try SafeDirectory(sourceURL.deletingLastPathComponent())
    let original = try sourceDirectory.read(sourceURL.lastPathComponent, limit: SaveEnvelope.maxFileBytes)
    let envelope = try SaveEnvelope(original)
    guard let slot = envelope.slot, slot.transformed, slot.packed, slot.codec == 1 else {
        throw ResourceError.rejected("inactive_log_fixture_source_profile")
    }
    let gameDirectory = try SafeDirectory(URL(fileURLWithPath: values[1], isDirectory: true))
    let header = try SaveEnvelope.slotHeaderTemplate(from: gameDirectory, executable: "美少女万華鏡４.exe")
    let seed = try SaveEnvelope.validatedSlotSeed(original, clearTemplate: header)
    var state = try SaveEnvelope.decodeSlotState(original, seed: seed)
    let prefix = try SaveStatePrefix(state: state, after: SaveReaderCursor(threadState: state))
    guard let summary = try JSONSerialization.jsonObject(with: JSONEncoder().encode(prefix)) as? [String: Any],
          let count = summary["dialogueLogCount"] as? Int, (0..<256).contains(count),
          let cursor = summary["dialogueLogCursor"] as? Int, (0..<256).contains(cursor),
          let records = summary["dialogueLogRecords"] as? [[String: Any]], records.count == 256 else {
        throw ResourceError.rejected("inactive_log_fixture_requires_unused_slot")
    }
    let active = Set((0..<count).map { (cursor - $0 - 1 + 256) % 256 })
    guard let index = (0..<256).first(where: { !active.contains($0) }) else {
        throw ResourceError.rejected("inactive_log_fixture_requires_unused_slot")
    }
    for (position, record) in records.enumerated() where !active.contains(position) {
        guard let strings = record["strings"] as? [[String: Any]], strings.count == 4,
              strings.allSatisfy({ ($0["length"] as? Int) == 0 }),
              let integers = record["integerFields"] as? [Int], integers == [0, 0, 0, 0] else {
            throw ResourceError.rejected("inactive_log_fixture_record_shape")
        }
    }
    guard let strings = records[index]["strings"] as? [[String: Any]], let last = strings.last,
          let lastOffset = last["decodedOffset"] as? Int, let lastLength = last["length"] as? Int else {
        throw ResourceError.rejected("inactive_log_fixture_record_shape")
    }
    let integerOffset = lastOffset + lastLength
    guard integerOffset >= 0, integerOffset <= state.count - 4,
          state[integerOffset..<(integerOffset + 4)].allSatisfy({ $0 == 0 }) else {
        throw ResourceError.rejected("inactive_log_fixture_record_bounds")
    }
    state[integerOffset] = 7
    let thumbnail = Data(original[slot.thumbnail.offset..<(slot.thumbnail.offset + slot.thumbnail.length)])
    let savedDays = original.withUnsafeBytes {
        Double(bitPattern: UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 74, as: UInt64.self)))
    }
    let fixture = try SaveEnvelope.encodeSlot(state: state, metadata: SaveEnvelope.readSlotMetadata(original),
        thumbnail: thumbnail, savedDays: savedDays, seed: seed,
        packedCodec: slot.codec, clearHeaderTemplate: header, headerSeed: seed)
    let decoded = try SaveEnvelope.decodeSlotState(fixture, seed: seed)
    guard decoded == state else { throw ResourceError.rejected("inactive_log_fixture_roundtrip_mismatch") }
    let output = try SafeDirectory(URL(fileURLWithPath: values[2], isDirectory: true))
    guard output.root.path != gameDirectory.root.path,
          !output.root.path.hasPrefix(gameDirectory.root.path + "/"),
          output.root.path != sourceDirectory.root.path,
          !output.root.path.hasPrefix(sourceDirectory.root.path + "/") else {
        throw ResourceError.rejected("inactive_log_fixture_output_inside_input")
    }
    try output.writeNew("SaveData0.svd", data: fixture, limit: SaveEnvelope.maxFileBytes)
    return ["status": "verified", "sourceSaveSHA256": sha(original), "fixtureSHA256": sha(fixture),
            "inactiveIndex": index, "changedDecodedOffset": integerOffset,
            "scope": "Private constructed fixture only; original files unchanged.", "originalFilesWritten": false]
}

private func makeInvalidSeekFixture(arguments: ArraySlice<String>) throws -> [String: Any] {
    guard arguments.count == 7 else { throw ResourceError.rejected("seek_fixture_arguments") }
    let values = Array(arguments)
    let sourceURL = URL(fileURLWithPath: values[0])
    try requireRegularFile(sourceURL.path)
    let sourceDirectory = try SafeDirectory(sourceURL.deletingLastPathComponent())
    let original = try sourceDirectory.read(sourceURL.lastPathComponent, limit: SaveEnvelope.maxFileBytes)
    let envelope = try SaveEnvelope(original)
    guard let slot = envelope.slot, slot.transformed, slot.packed, slot.codec == 1 else {
        throw ResourceError.rejected("seek_fixture_source_slot_profile")
    }
    let gameDirectory = try SafeDirectory(URL(fileURLWithPath: values[1], isDirectory: true))
    let header = try SaveEnvelope.slotHeaderTemplate(from: gameDirectory, executable: "美少女万華鏡４.exe")
    let seed = try SaveEnvelope.validatedSlotSeed(original, clearTemplate: header)
    var state = try SaveEnvelope.decodeSlotState(original, seed: seed)
    guard let recordOffset = Int(values[3]), let recordLength = Int(values[4]),
          let seconds = Float(values[6]), seconds.isFinite, seconds > 600,
          values[5].count == 64, values[5].allSatisfy({ $0.isHexDigit }),
          recordOffset >= 0, recordLength >= 0x19,
          recordOffset <= state.count, recordLength <= state.count - recordOffset else {
        throw ResourceError.rejected("seek_fixture_record_bounds")
    }
    let sourceRecord = Data(state[recordOffset..<(recordOffset + recordLength)])
    guard sha(sourceRecord) == values[5], state[recordOffset + 0x10] == 3 else {
        throw ResourceError.rejected("seek_fixture_stream_record_identity")
    }
    let oldBits = state.withUnsafeBytes {
        UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: recordOffset + 0x15, as: UInt32.self))
    }
    let newBits = seconds.bitPattern
    withUnsafeBytes(of: newBits.littleEndian) {
        state.replaceSubrange((recordOffset + 0x15)..<(recordOffset + 0x19), with: $0)
    }
    let mutatedRecord = Data(state[recordOffset..<(recordOffset + recordLength)])
    let thumbnail = Data(original[slot.thumbnail.offset..<(slot.thumbnail.offset + slot.thumbnail.length)])
    let savedDays = original.withUnsafeBytes {
        Double(bitPattern: UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 74, as: UInt64.self)))
    }
    let metadata = try SaveEnvelope.readSlotMetadata(original)
    let fixture = try SaveEnvelope.encodeSlot(state: state, metadata: metadata,
        thumbnail: thumbnail, savedDays: savedDays, seed: seed,
        packedCodec: slot.codec, clearHeaderTemplate: header, headerSeed: seed)
    let fixtureSeed = try SaveEnvelope.validatedSlotSeed(fixture, clearTemplate: header)
    let fixtureState = try SaveEnvelope.decodeSlotState(fixture, seed: fixtureSeed)
    let fixtureRecord = Data(fixtureState[recordOffset..<(recordOffset + recordLength)])
    let fixtureBits = fixtureState.withUnsafeBytes {
        UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: recordOffset + 0x15, as: UInt32.self))
    }
    guard fixtureBits == newBits, sha(fixtureRecord) == sha(mutatedRecord) else {
        throw ResourceError.rejected("seek_fixture_roundtrip_mismatch")
    }
    let outputDirectory = try SafeDirectory(URL(fileURLWithPath: values[2], isDirectory: true))
    try outputDirectory.writeNew("SaveData0.svd", data: fixture, limit: SaveEnvelope.maxFileBytes)
    return [
        "status": "verified",
        "scope": "Private invalid-seek slot fixture only; original save and game files were not changed.",
        "sourceSaveSHA256": sha(original),
        "decodedStateSHA256": sha(try SaveEnvelope.decodeSlotState(original, seed: seed)),
        "mutatedRecordDecodedOffset": recordOffset,
        "mutatedRecordLength": recordLength,
        "mutatedRecordSHA256": sha(mutatedRecord),
        "originalRecordSHA256": sha(sourceRecord),
        "rawSeekFieldOffsetInRecord": 0x15,
        "oldRawSeekBits": oldBits,
        "newRawSeekBits": newBits,
        "newSeekSeconds": Double(seconds),
        "newSeekMilliseconds": Int((Double(seconds) * 1000).rounded(.toNearestOrEven)),
        "headerValidation": "verified fixed EXE header template and seed",
        "fixtureRelativePath": "SaveData0.svd",
        "fixtureSHA256": sha(fixture),
        "fixtureBytes": fixture.count,
        "originalFilesWritten": false
    ]
}

do {
    if CommandLine.arguments.dropFirst().first == "--pause-pair" {
        try pausePair(arguments: CommandLine.arguments.dropFirst(2))
    } else if CommandLine.arguments.dropFirst().first == "--child" {
        try child(arguments: CommandLine.arguments.dropFirst(2))
    } else if CommandLine.arguments.dropFirst().first == "--make-inactive-log" {
        emit(try makeInactiveLogFixture(arguments: CommandLine.arguments.dropFirst(2)))
    } else if CommandLine.arguments.dropFirst().first == "--make-invalid-seek" {
        emit(try makeInvalidSeekFixture(arguments: CommandLine.arguments.dropFirst(2)))
    } else {
        emit(try parent(arguments: CommandLine.arguments.dropFirst()))
    }
} catch {
    emit(["status": "unsupported", "issue": String(describing: error), "originalFilesWritten": false])
    exit(2)
}
