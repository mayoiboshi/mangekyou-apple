import Foundation
import XCTest
@testable import MangekyouCore

final class SaveEnvelopeTests: XCTestCase {
    func testPlainSlotEnvelopeRoundTrip() throws {
        let state = Data("thread\0\0".utf8) + Data([1, 2, 3])
        let metadata = ["A", "雪", "", "", "", "", "", ""]
        let thumbnail = Data([0xff, 0xd8, 0xff, 0xd9])
        let encoded = try SaveEnvelope.encodeSlot(state: state, metadata: metadata,
                                                  thumbnail: thumbnail, savedDays: 45_000.5)
        // Independently assembled with Python struct and save_slot_probe.payload_checksum.
        XCTAssertEqual(encoded.sha256Hex, "c9588ba6a5420df7288be242052c806e09e49096ed9e9e9ad758b0838d5af507")
        let slot = try XCTUnwrap(SaveEnvelope(encoded).slot)
        XCTAssertEqual(slot.headerVersion, 10)
        XCTAssertEqual(slot.savedLocalTime?.hour, 12)
        XCTAssertEqual(Data(encoded.dropFirst(slot.thumbnail.offset).prefix(slot.thumbnail.length)), thumbnail)
        XCTAssertEqual(try SaveEnvelope.readSlotMetadata(encoded), metadata)
        XCTAssertEqual(try SaveEnvelope.decodeSlotState(encoded), state)
        let verification = Data(repeating: 0x5a, count: 40)
        let withVerification = try SaveEnvelope.encodeSlot(state: state, metadata: metadata, thumbnail: thumbnail,
                                                            savedDays: 45_000.5, headerVerification: verification)
        let section = try XCTUnwrap(SaveEnvelope(withVerification).slot?.headerVerification)
        XCTAssertEqual(withVerification.subdata(in: section.offset..<(section.offset + section.length)), verification)
        let clear = Data(repeating: 0x5a, count: 40)
        let encodedPrefix = try SaveEnvelope.encodeSlot(state: Data(clear.prefix(32)), metadata: metadata,
                                                        thumbnail: Data(), savedDays: 0, seed: 123)
        let storedVerification = Data(encodedPrefix.suffix(32)) + clear.suffix(8)
        let verifiedHeader = try SaveEnvelope.encodeSlot(state: state, metadata: metadata,
            thumbnail: thumbnail, savedDays: 45_000.5, headerVerification: storedVerification)
        XCTAssertNoThrow(try SaveEnvelope.verifySlotHeader(verifiedHeader, clearTemplate: clear, seed: 123))
        XCTAssertThrowsError(try SaveEnvelope.verifySlotHeader(verifiedHeader, clearTemplate: clear, seed: 124))
        XCTAssertEqual(try SaveEnvelope.validatedSlotSeed(verifiedHeader, clearTemplate: clear), 123)
        var wrongTemplate = clear
        wrongTemplate[39] = 0
        XCTAssertThrowsError(try SaveEnvelope.validatedSlotSeed(verifiedHeader, clearTemplate: wrongTemplate))
    }

    func testEngineTailStringSpansPreserveRecordBoundaries() throws {
        var state = Data(repeating: 0, count: 419 + 14 + 69 + 69 + 4 + 68 + 4)
        state += Data("imotwt".utf8) + Data(repeating: 0, count: 258)
        state += Data(repeating: 0, count: 53) + Data([3, 0, 0, 0])
        state += Data(repeating: 0, count: 121)
        for _ in 0..<4 {
            state += Data("vgene\0\0\0".utf8) + Data([3, 0, 0, 0]) + Data(repeating: 0, count: 44)
        }
        state += Data(repeating: 0, count: 10) + Data([2, 0, 0, 0])
        state += Data(repeating: 0, count: 28)
        let firstOffset = state.count
        state += Data([1, 0, 65, 0]) + Data(repeating: 0, count: 14)

        let parsed = try SaveEngineState(state: state, at: 0)
        XCTAssertEqual(parsed.tailStringSpans.map(\.byteLength), [4, 2, 2, 2, 2, 2, 2, 2])
        XCTAssertEqual(parsed.tailStringSpans.first?.decodedOffset, firstOffset)
        XCTAssertEqual(parsed.tailStringSpans.last?.decodedOffset, state.count - 2)
        XCTAssertEqual(parsed.nextDecodedOffset, state.count)
        XCTAssertEqual(try parsed.systemNameSlots(in: state), ["A", "", "", "", "", "", ""])
        let countOffset = 419 + 14 + 69 + 69
        state.replaceSubrange(countOffset..<(countOffset + 4), with: [UInt8](repeating: 255, count: 4))
        let sentinel = try SaveEngineState(state: state, at: 0)
        XCTAssertEqual(sentinel.stringListCount, 0)
        XCTAssertEqual(sentinel.nextDecodedOffset, state.count)
        XCTAssertThrowsError(try SaveEngineState(state: Data(state.dropLast()), at: 0))
    }

    func testSavedCapturePreservesModeOneAndStopsWithoutIt() throws {
        let program = try ScriptProgram(ScriptDocument(
            data: Data("\\scp,eff\n\\c\n".utf8), relativePath: "effect.s"))
        let entry = try XCTUnwrap(program.document.records.firstIndex { $0.command == "scp" })
        var storage = ScriptStorage()
        let missing = try XCTUnwrap(ScriptMachine.probeSavedCalculations(
            program: program, index: entry, storage: storage))
        XCTAssertEqual(missing.stopReason, "saved_effect_capture_requires_restored_state")
        storage.effectCapturePriority = 60000
        let restored = try XCTUnwrap(ScriptMachine.probeSavedCalculations(
            program: program, index: entry, storage: storage))
        XCTAssertTrue(restored.steps.contains { $0.action == "effect_capture_preserved_candidate" })
    }

    func testSavedReaderResolvesOnlyExactCommandBoundary() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/owned-save-tests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let command = "\\cal,#x=1"
        let source = Data([0xef, 0xbb, 0xbf]) + Data("@@Resume\r\n\(command)\r\n\\if,#x==1\r\n\\then\r\n\\cal,1/#x\r\n\\else\r\n\\wait,20\r\n\\end\r\n\\for,#x=0,#x<2,#x++\r\n\\cal,1\r\n\\end\r\n\\wait,10\r\n".utf8)
        try source.write(to: directory.appendingPathComponent("owned.s"))
        let caller = Data("@@Start\n\\jmp,@@Target,#JumpFile\n\\cal,1/0\n@@Callee\n\\cal,1/ParamInt[0]\n\\ret\n".utf8)
        let target = Data("@@Target\n\\cal,1\n\\sub,@@Callee,#CallFile,2\n\\cal,3\n\\clk\n".utf8)
        try caller.write(to: directory.appendingPathComponent("caller.s"))
        try target.write(to: directory.appendingPathComponent("target.s"))
        let catalog = try ScriptModuleCatalog(entries: [
            ScriptModuleReference(logicalPath: "owned.s", sourceFile: "owned.s", sourceSHA256: source.sha256Hex),
            .init(logicalPath: "caller.s", sourceFile: "caller.s", sourceSHA256: caller.sha256Hex),
            .init(logicalPath: "target.s", sourceFile: "target.s", sourceSHA256: target.sha256Hex)
        ])
        var repository = try ScriptRepository(directory: SafeDirectory(directory), catalog: catalog)

        let timer = try ScriptProgram(ScriptDocument(data: Data(
            "@@Timer\n\\wait,120\n\\cal,1\n".utf8), relativePath: "timer.s"))
        let wait = try XCTUnwrap(timer.document.records.first { $0.command == "wait" }).location
        let afterWait = wait.byteOffset + wait.byteLength
        let waitCursor = timer.document.source.location(afterWait..<afterWait, line: wait.lineNumber)
        let successor = try timer.savedTimedWaitSuccessor(waitCursor)
        XCTAssertEqual(timer.document.records[successor].command, "cal")
        let resumedTimer = try XCTUnwrap(ScriptMachine.probeSavedCalculations(
            program: timer, index: successor, storage: ScriptStorage(), savedWait: 19))
        XCTAssertEqual(resumedTimer.simulatedSavedWaitTicks, 19)
        XCTAssertEqual(resumedTimer.steps.first?.command, "cal")
        let startOfWait = timer.document.source.location(wait.byteOffset..<wait.byteOffset, line: wait.lineNumber)
        XCTAssertThrowsError(try timer.savedTimedWaitSuccessor(startOfWait))

        let jumpProgram = try repository.load("caller.s")
        let jumpEntry = try XCTUnwrap(jumpProgram.document.records.firstIndex { $0.command == "jmp" })
        var restoredStorage = ScriptStorage()
        for (name, value) in [("#JumpFile", "target.s"), ("#CallFile", "caller.s")] {
            try restoredStorage.declare(name, category: "gvar", type: "str")
            try restoredStorage.write(name, .string(value))
        }
        let jumped = try XCTUnwrap(ScriptMachine.probeSavedCalculations(
            program: jumpProgram, index: jumpEntry, storage: restoredStorage, repository: repository))
        XCTAssertEqual(jumped.steps.first?.action, "module_jump_candidate")
        XCTAssertEqual(jumped.steps.first { $0.action == "calculate" }?.location.sourceFile, "target.s")
        XCTAssertTrue(jumped.steps.contains { $0.action == "module_call" })
        XCTAssertTrue(jumped.steps.contains { $0.action == "module_return" })
        XCTAssertEqual(jumped.steps.filter { $0.action == "calculate" }.map { $0.location.sourceFile },
                       ["target.s", "caller.s", "target.s"])
        XCTAssertEqual(jumped.stopReason, "waiting_for_input_or_timer")
        XCTAssertEqual(jumped.waitRemaining, -1)

        var state = Data("thread\0\0".utf8) + Data([10, 0, 0, 0, 0, 0, 0, 0])
        state += Data([10, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0])
        state += Data(repeating: 0, count: 65)
        for field in [command, "owned.s", "Resume", "prefix", "empty"] {
            state += Data([UInt8(field.utf16.count), 0])
            state += try XCTUnwrap(field.data(using: .utf16LittleEndian))
        }
        state += Data(repeating: 0, count: 4)
        let cursor = try SaveReaderCursor(state: state, routineCount: 0)
        XCTAssertEqual(try cursor.textPrefix.utf16Text(in: state), "prefix")
        XCTAssertEqual(try cursor.emptyLineText.utf16Text(in: state), "empty")
        XCTAssertEqual(cursor.replaceEnableByte, 0)
        let resolved = try cursor.resolveLabel(in: state, repository: &repository)
        let position = try resolved.program.sourcePosition(for: cursor, anchor: resolved.location)
        let commandBoundary = try resolved.program.saveCommandBoundary(position)
        XCTAssertEqual(commandBoundary.location.lineNumber, 2)
        XCTAssertEqual(commandBoundary.controlDepth, 0)
        let index = try resolved.program.saveCommandIndex(position)
        var storage = ScriptStorage()
        try storage.declare("#x", category: "gvar", type: "int")
        let continuation = try XCTUnwrap(ScriptMachine.probeSavedCalculations(
            program: resolved.program, index: index, storage: storage))
        let isolated = try XCTUnwrap(continuation.steps.first)
        XCTAssertEqual(continuation.steps.filter { $0.action == "calculate" }.count, 4)
        XCTAssertTrue(continuation.steps.contains { $0.action == "if_exact_one_true" })
        XCTAssertTrue(continuation.steps.contains { $0.action == "skip_else_after_true" })
        let loop = try XCTUnwrap(resolved.program.document.records.first { $0.command == "for" })
        func reference(_ text: String) -> SaveReaderCursor.Reference {
            let bytes = Data(text.utf16.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8($0 >> 8)] })
            return .init(decodedOffset: 0, length: bytes.count, sha256: bytes.sha256Hex)
        }
        let blank = reference("")
        let block = SaveReaderCursor.ControlBlock(decodedOffset: 0, rawState: 3, rawValueAt38: 0,
            rawValueAt3C: 0, stringReferences: [blank, blank, reference(loop.fields[1].raw),
                reference(loop.fields[2].raw)] + Array(repeating: blank, count: 6))
        XCTAssertTrue(block.matchesThreeFieldLoop(loop.fields))
        XCTAssertFalse(block.matchesThreeFieldLoop([loop.fields[0], loop.fields[2], loop.fields[1]]))
        let bodyIndex = try XCTUnwrap(resolved.program.document.records.firstIndex {
            $0.kind == .command && $0.location.lineNumber == 10
        })
        let body = resolved.program.document.records[bodyIndex].location
        let originalSource = try XCTUnwrap(resolved.program.sources[Data(body.sourceFile.utf8)])
        let returnPosition = originalSource.location(body.byteOffset..<body.byteOffset, line: body.lineNumber)
        var active = storage
        try active.write("#x", .integer(1))
        try ScriptMachine.stageSavedActiveControls(program: resolved.program, index: bodyIndex, blocks: [block],
            returnLocations: [block.decodedOffset: returnPosition], storage: &active)
        let resumed = try XCTUnwrap(ScriptMachine.probeSavedCalculations(
            program: resolved.program, index: bodyIndex, storage: active))
        XCTAssertEqual(resumed.steps.filter { $0.action == "calculate" }.count, 1)
        XCTAssertTrue(resumed.steps.contains { $0.action == "for_update_then_exit" })
        XCTAssertFalse(resumed.steps.contains { $0.action == "for_enter_candidate" })
        XCTAssertEqual(try active.read("#x"), .integer(1))
        XCTAssertTrue(continuation.steps.contains { $0.action == "for_update_then_repeat" })
        XCTAssertTrue(continuation.steps.contains { $0.action == "for_update_then_exit" })
        XCTAssertEqual(continuation.steps.last?.location.lineNumber, 12)
        XCTAssertEqual(continuation.waitRemaining, 10)
        XCTAssertEqual(continuation.stopReason, "waiting_for_input_or_timer")
        XCTAssertEqual(try storage.read("#x"), .integer(0))
        XCTAssertEqual(isolated.location.byteOffset, commandBoundary.location.byteOffset)
        XCTAssertEqual(isolated.action, "calculate")
        XCTAssertEqual(isolated.resultType, "integer")
        XCTAssertThrowsError(try resolved.program.sourcePosition(for: cursor, anchor: commandBoundary.location))
        XCTAssertThrowsError(try resolved.program.saveCommandBoundary(commandBoundary.location))

        // Same length and source identity, but a different saved reader buffer.
        var replacedState = state
        let lastCharacter = cursor.lineBuffer.decodedOffset + cursor.lineBuffer.length - 2
        replacedState[lastCharacter] = 50
        replacedState[cursor.decodedOffset + 12] = 1
        let replacedCursor = try SaveReaderCursor(state: replacedState, routineCount: 0)
        XCTAssertThrowsError(try resolved.program.sourcePosition(for: replacedCursor, anchor: resolved.location)) {
            XCTAssertEqual(String(describing: $0), "save_reader_line_buffer_differs")
        }
    }

    func testSavedLocalCallReturnsToCallerWithoutReplayingCall() throws {
        let program = try ScriptProgram(ScriptDocument(data: Data(
            "@@Caller\n\\sub,@@Callee\n\\cal,1/(ResultInt[0]+ResultClkInt+ResultStopInt)\n\\wait,10\n@@Callee\n\\cal,1/ParamInt[0]\n\\ret\n".utf8),
            relativePath: "owned.s"))
        let anchor = program.document.records[try program.label("@@Callee")].location
        let returnIndex = try XCTUnwrap(program.document.records.firstIndex { $0.command == "cal" })
        let entry = try XCTUnwrap(program.document.records.firstIndex { $0.command == "ret" })
        var staged = ScriptStorage()
        try ScriptMachine.stageSavedCall(callee: program, anchor: anchor, caller: program,
                                         returnIndex: returnIndex, catalog: nil, storage: &staged)
        staged.frames[1].savedReturnScalars = .init(integers: [1], strings: [""], click: 2, stop: 3)
        let result = try XCTUnwrap(ScriptMachine.probeSavedCalculations(program: program, index: entry, storage: staged))
        XCTAssertEqual(result.steps.first?.action, "local_return")
        XCTAssertEqual(result.steps.filter { $0.action == "calculate" }.count, 1)
        XCTAssertEqual(result.steps.last?.location.lineNumber, 4)
        XCTAssertEqual(result.waitRemaining, 10)
        XCTAssertEqual(result.stopReason, "waiting_for_input_or_timer")
        XCTAssertEqual(staged.frames.count, 2)

        let caller = try ScriptProgram(ScriptDocument(data: Data(
            "@@Caller\n\\sub,@@Callee,\"owned.s\",-2,\"42\"\n\\cal,3\n\\ret\n".utf8), relativePath: "caller.s"))
        let catalog = try ScriptModuleCatalog(entries: [
            .init(logicalPath: "owned.s", sourceFile: "owned.s", sourceSHA256: program.document.source.sha256)
        ])
        let moduleReturn = try XCTUnwrap(caller.document.records.firstIndex { $0.command == "cal" })
        staged = ScriptStorage()
        try ScriptMachine.stageSavedCall(callee: program, anchor: anchor, caller: caller,
            returnIndex: moduleReturn, catalog: catalog, storage: &staged)
        let crossModule = try XCTUnwrap(ScriptMachine.probeSavedCalculations(program: program, index: entry, storage: staged))
        XCTAssertEqual(crossModule.steps.first?.action, "module_return")
        XCTAssertEqual(crossModule.steps.first { $0.action == "calculate" }?.location.sourceFile, "caller.s")
        XCTAssertEqual(crossModule.nextLocation?.sourceFile, "caller.s")
        XCTAssertEqual(try staged.readIndexed("ParamInt", 0), .integer(-2))
        XCTAssertEqual(try staged.readIndexed("ParamInt", 1), .integer(42))
        XCTAssertEqual(try staged.readIndexed("ParamStr", 1), .string("42"))
        let parameterEntry = try XCTUnwrap(program.document.records.firstIndex {
            $0.command == "cal" && $0.location.lineNumber > anchor.lineNumber
        })
        let parameterProbe = try XCTUnwrap(ScriptMachine.probeSavedCalculations(
            program: program, index: parameterEntry, storage: staged))
        XCTAssertEqual(parameterProbe.steps.first?.action, "calculate")

        let dynamicCaller = try ScriptProgram(ScriptDocument(data: Data(
            "@@Caller\n\\sub,@@Callee,\"owned.s\",#Unavailable\n\\cal,3\n".utf8), relativePath: "dynamic.s"))
        let dynamicReturn = try XCTUnwrap(dynamicCaller.document.records.firstIndex { $0.command == "cal" })
        let savedParameters: [Data: ScriptBinding] = [
            Data("paramcount".utf8): .init(elements: [.integer(1)]),
            Data("paramint".utf8): .init(elements: [.integer(7)] + Array(repeating: .integer(0), count: 15)),
            Data("paramstr".utf8): .init(elements: [.string("7")] + Array(repeating: .string(""), count: 15))
        ]
        staged = ScriptStorage()
        try ScriptMachine.stageSavedCall(callee: program, anchor: anchor, caller: dynamicCaller,
            returnIndex: dynamicReturn, catalog: catalog, locals: savedParameters, storage: &staged)
        XCTAssertEqual(try staged.readIndexed("ParamInt", 0), .integer(7))
        XCTAssertEqual(try staged.readIndexed("ParamStr", 0), .string("7"))

        let outer = try ScriptProgram(ScriptDocument(data: Data(
            "@@Outer\n\\sub,@@Caller,\"caller.s\"\n\\cal,4\n\\wait,10\n".utf8), relativePath: "outer.s"))
        let nestedCatalog = try ScriptModuleCatalog(entries: [
            .init(logicalPath: "owned.s", sourceFile: "owned.s", sourceSHA256: program.document.source.sha256),
            .init(logicalPath: "caller.s", sourceFile: "caller.s", sourceSHA256: caller.document.source.sha256)
        ])
        let callerAnchor = caller.document.records[try caller.label("@@Caller")].location
        let outerReturn = try XCTUnwrap(outer.document.records.firstIndex { $0.command == "cal" })
        staged = ScriptStorage()
        try ScriptMachine.stageSavedCall(callee: caller, anchor: callerAnchor, caller: outer,
            returnIndex: outerReturn, catalog: nestedCatalog, storage: &staged)
        try ScriptMachine.stageSavedCall(callee: program, anchor: anchor, caller: caller,
            returnIndex: moduleReturn, catalog: nestedCatalog, storage: &staged)
        let nested = try XCTUnwrap(ScriptMachine.probeSavedCalculations(
            program: program, index: entry, storage: staged, savedWait: 25))
        XCTAssertEqual(nested.simulatedSavedWaitTicks, 25)
        XCTAssertEqual(nested.steps.first?.action, "module_return")
        XCTAssertEqual(nested.steps.filter { $0.action == "module_return" }.count, 2)
        XCTAssertEqual(nested.steps.filter { $0.action == "calculate" }.map { $0.location.sourceFile },
                       ["caller.s", "outer.s"])
        XCTAssertEqual(nested.steps.last?.location.sourceFile, "outer.s")
        XCTAssertEqual(nested.waitRemaining, 10)
    }

    func testTransformedStateRequiresSeedAndPreservesPartialBlock() throws {
        var slot = Data([0x4e, 0x4d, 0x32, 0xfd, 0x8e, 0x1f, 0x84, 0xe1, 179, 0, 0, 0])
        var header = Data(repeating: 0, count: 138 + 16 + 4)
        header.replaceSubrange(0..<10, with: "IMOSAVE110".utf8)
        header[60] = 1
        withUnsafeBytes(of: Double(45_000.5).bitPattern.littleEndian) {
            header.replaceSubrange(62..<70, with: $0)
        }
        slot.append(header)
        slot.append(contentsOf: [17, 0, 0, 0])
        slot.append(Data(repeating: 0, count: 16))
        slot.append(0x21)
        XCTAssertThrowsError(try SaveEnvelope.readStatePayload(slot))
        let output = try SaveEnvelope.readStatePayload(slot, seed: 0)
        let reencoded = try SaveEnvelope.encodeSlot(state: output, metadata: Array(repeating: "", count: 8),
                                                   thumbnail: Data(), savedDays: 45_000.5, seed: 0)
        XCTAssertEqual(Data(reencoded.suffix(17)), Data(slot.suffix(17)))
        XCTAssertEqual(try SaveEnvelope.decodeSlotState(reencoded, seed: 0), output)
        XCTAssertEqual(output, Data([
            0xef, 0x21, 0xa8, 0x8b, 0xef, 0x21, 0xa8, 0x8b,
            0x12, 0x17, 0xcd, 0x59, 0x12, 0x17, 0xcd, 0x59, 0x21,
        ]))
        let envelope = try SaveEnvelope(slot)
        XCTAssertEqual(envelope.kind, "slot")
        let program = try ScriptProgram(ScriptDocument(
            data: Data("\\scp,dat\n\\?g,\"savedata1.svd\"".utf8), relativePath: "owned.s"))
        for present in [false, true] {
            var machine = try ScriptMachine(program: program, allowExperimental: true)
            let entry = SaveSlotInventory.Entry(name: "SaveData1.svd", status: .verified,
                                                envelope: envelope, issue: nil)
            try machine.setReadOnlySaveSlots(present ? [entry] : [])
            try machine.run()
            XCTAssertEqual(machine.phase, .finished)
            XCTAssertEqual(try machine.value(named: "ResultInt"), .integer(present ? 1 : 0))
        }
        let metadataProgram = try ScriptProgram(ScriptDocument(
            data: Data("\\scp,dat\n\\?gd,\"savedata1.svd\"".utf8), relativePath: "owned.s"))
        var metadataMachine = try ScriptMachine(program: metadataProgram, allowExperimental: true)
        var entry = SaveSlotInventory.Entry(name: "SaveData1.svd", status: .verified,
                                            envelope: envelope, issue: nil)
        entry.metadata = try SaveEnvelope.readSlotMetadata(slot)
        try metadataMachine.setReadOnlySaveSlots([entry])
        try metadataMachine.run()
        XCTAssertEqual(metadataMachine.phase, .finished)
        XCTAssertEqual(try metadataMachine.value(named: "ResultStr"), .string(""))
        XCTAssertEqual(try metadataMachine.value(named: "ResultInt"), .integer(2023))

        let restoreProgram = try ScriptProgram(ScriptDocument(
            data: Data("\\scp,dat\n\\?g,\"savedata1.svd\"\n\\l,\"savedata1.svd\"".utf8),
            relativePath: "owned.s"))
        for present in [false, true] {
            var machine = try ScriptMachine(program: restoreProgram, allowExperimental: true)
            try machine.setReadOnlySaveSlots(present ? [entry] : [])
            try machine.run()
            XCTAssertEqual(machine.phase, .stopped)
            XCTAssertEqual(machine.stopReason, present ? "save_restore_execution_state_unsupported" :
                "save_restore_slot_unavailable")
            XCTAssertEqual(try machine.value(named: "ResultInt"), .integer(present ? 1 : 0))
        }
    }
    func testRunLengthRepeatLiteralReferenceAndTail() throws {
        var input = Data(repeating: 0, count: 64)
        input.replaceSubrange(0..<14, with: "runlengthpack\0".utf8)
        input[16] = 1
        input[20] = 16
        input[24] = 1
        input[28] = 33
        input.append(0xff)
        input.append(contentsOf: "ABCD".utf8)
        input.append(contentsOf: [0xc0, 2])
        input.append(contentsOf: "efgh".utf8)
        XCTAssertEqual(try SaveRunLength.decode(input), Data("ABCDABCDefghefgh!".utf8))
        XCTAssertThrowsError(try SaveRunLength.decode(Data(input.prefix(64)) + Data([0xc0])))
    }
    func testSaveBPEDictionaryExpansionAndOutputBound() throws {
        let input = Data([0x31, 0x50, 0x43, 0xff, 1, 0, 0, 0, 2, 0, 0, 0,
                          0, 65, 66, 255, 129, 253, 1, 0, 0])
        XCTAssertEqual(try SaveBPE.decode(input), Data("AB".utf8))
        var oversizedExpansion = input
        oversizedExpansion[8] = 1
        XCTAssertThrowsError(try SaveBPE.decode(oversizedExpansion))
    }
    func testSaveRoutineResultIntegersUseVerifiedSnapshot() throws {
        var state = Data("thread\0\0".utf8) + Data([10, 0, 0, 0, 1, 0, 0, 0])
        state += Data("routine\0".utf8) + Data([10, 0, 0, 0])
        state += Data(repeating: 0, count: 32 + 13 + 6)
        state.append(1)
        let snapshotStart = state.count
        state += Data([0xfe, 0xff, 0xff, 0xff])
        state += Data(repeating: 0, count: 60)
        state += Data([1, 0, 65, 0])
        state += Data(repeating: 0, count: 30)
        state += Data([1, 0, 66, 0])
        state += Data(repeating: 0, count: 32)
        state += Data([11, 0, 0, 0]) + Data(repeating: 0, count: 12)
        state += Data([1, 0, 67, 0]) + Data(repeating: 0, count: 6)
        state += Data([7, 0, 0, 0, 0xfd, 0xff, 0xff, 0xff])
        state += Data([13, 0, 0, 0]) + Data(repeating: 0, count: 12)
        state += Data([1, 0, 68, 0]) + Data(repeating: 0, count: 6 + 4)
        state += Data([10, 0, 0, 0]) + Data(repeating: 0, count: 73 + 14)
        let cursor = try SaveReaderCursor(state: state, routineCount: 1)
        let routine = try XCTUnwrap(cursor.routines.first)
        var nested = state
        nested[cursor.decodedOffset - 4] = 1
        let child = Data([10, 0, 0, 0, 0, 0, 0, 0, 3]) + Data(repeating: 0, count: 24)
        nested.insert(contentsOf: child, at: cursor.decodedOffset)
        let nestedCursor = try SaveReaderCursor(state: nested, routineCount: 1)
        XCTAssertEqual(nestedCursor.routines.count, 1)
        let block = try XCTUnwrap(nestedCursor.routines.first?.controlBlocks.first)
        XCTAssertEqual(block.decodedOffset, cursor.decodedOffset)
        XCTAssertEqual(block.rawState, 3)
        XCTAssertEqual(block.stringReferences.count, 10)
        XCTAssertEqual(nestedCursor.decodedOffset, cursor.decodedOffset + child.count)
        XCTAssertEqual(try routine.resultIntegers(in: state), [-2] + Array(repeating: 0, count: 15))
        XCTAssertEqual(try routine.resultStrings(in: state), ["A"] + Array(repeating: "", count: 15))
        XCTAssertEqual(routine.resultObjectReferences.count, 16)
        XCTAssertEqual(routine.nonEmptyResultObjectReferenceCount, 1)
        XCTAssertEqual(routine.resultClickInt, 7)
        XCTAssertEqual(routine.resultStopInt, -3)
        XCTAssertEqual(try routine.resultObjectReferences.first?.utf16Text(in: state), "B")
        var storage = ScriptStorage()
        try storage.stageRoutineResultScalars(from: routine, in: state)
        XCTAssertEqual(try storage.readIndexed("ResultInt", 0), .integer(-2))
        XCTAssertEqual(try storage.readIndexed("ResultInt", 15), .integer(0))
        XCTAssertEqual(try storage.readIndexed("ResultStr", 0), .string("A"))
        XCTAssertEqual(try storage.readIndexed("ResultStr", 15), .string(""))
        XCTAssertEqual(try storage.readIndexed("ResultBtnInt", 0), .integer(11))
        XCTAssertEqual(try storage.readIndexed("ResultBtnStr", 0), .string("C"))
        XCTAssertEqual(try storage.readIndexed("ResultSubInt", 0), .integer(13))
        XCTAssertEqual(try storage.readIndexed("ResultSubStr", 0), .string("D"))
        state[snapshotStart] = 0
        XCTAssertThrowsError(try storage.stageRoutineResultScalars(from: routine, in: state))
        XCTAssertEqual(try storage.readIndexed("ResultInt", 0), .integer(-2))
        var invalidState = state
        invalidState[16 + 12 + 32] = 11
        XCTAssertThrowsError(try SaveReaderCursor(state: invalidState, routineCount: 1)) {
            XCTAssertEqual(String(describing: $0), "unsupported_saved_routine_state")
        }
    }
    func testSaveVariableArrayDecodesSignedIntegerAndRejectsTruncation() throws {
        let state = Data([1, 0, 0, 0]) + Data(repeating: 0, count: 38)
            + Data([1, 0, 0, 0, 0xfe, 0xff, 0xff, 0xff])
        let arrays = try SaveVariableArrays(state: state, decodedOffset: 0)
        guard case .integers(let values) = arrays.records[0].values else {
            return XCTFail("Expected integer array")
        }
        XCTAssertEqual(values, [-2])
        XCTAssertEqual(arrays.nextDecodedOffset, state.count)
        XCTAssertThrowsError(try SaveVariableArrays(state: state.dropLast(), decodedOffset: 0))
        var absent = Data(repeating: 0, count: 22)
        absent[12] = 3
        let mixed = Data([2, 0, 0, 0]) + absent + state.dropFirst(4)
        let decoded = try SaveVariableArrays(state: mixed, decodedOffset: 0)
        guard case .absent = decoded.records[0].values,
              case .integers(let following) = decoded.records[1].values else {
            return XCTFail("Expected an absent value followed by an integer array")
        }
        XCTAssertEqual(following, [-2])
        XCTAssertEqual(decoded.nextDecodedOffset, mixed.count)
        var named = state
        named.replaceSubrange(22..<24, with: [1, 0, 0x78, 0])
        let staged = try ScriptStorage.stageSavedGlobalScalars(
            SaveVariableArrays(state: named, decodedOffset: 0))
        XCTAssertEqual(try staged.read("x"), .integer(-2))
        let calVal = Data("CalVal\0\0".utf8) + Data([1, 0, 0, 0, 0, 0, 0, 0]) + named
        let modified = try SaveVariableArrays.replacingCalValScalar(in: calVal, at: 0, name: "X",
                                                                   with: .integers([42]))
        XCTAssertEqual(modified.dropLast(4), calVal.dropLast(4))
        let restored = try ScriptStorage.stageSavedGlobalScalars(SaveVariableArrays.readCalVal(state: modified, at: 0))
        XCTAssertEqual(try restored.read("x"), .integer(42))
        var stringCalVal = calVal
        stringCalVal[16 + 4 + 12] = 1
        stringCalVal.replaceSubrange((stringCalVal.count - 4)..<stringCalVal.count, with: [1, 0, 65, 0])
        let changedString = try SaveVariableArrays.replacingCalValScalar(in: stringCalVal, at: 0, name: "x",
                                                                        with: .strings(["雪"]))
        let strings = try ScriptStorage.stageSavedGlobalScalars(SaveVariableArrays.readCalVal(state: changedString, at: 0))
        XCTAssertEqual(try strings.read("x"), .string("雪"))
        XCTAssertThrowsError(try SaveVariableArrays.replacingCalValScalar(in: stringCalVal, at: 0, name: "x",
                                                                         with: .strings(["longer"])))
        var objectGroup = Data([1, 0, 0, 0]) + Data(repeating: 0, count: 42)
        objectGroup[16] = 2
        let indexed = state + Data("ValIdx\0\0".utf8) + Data([0, 0, 0, 0, 2, 0, 0, 0])
            + mixed + objectGroup
        let summary = try arrays.summary(in: indexed, at: 0)
        XCTAssertEqual(summary.indexed.groupCount, 2)
        XCTAssertEqual(summary.indexed.recordCount, 3)
        XCTAssertEqual(summary.indexed.objectArrayCount, 1)
        XCTAssertEqual(summary.indexed.groupSpans?.map(\.byteLength), [mixed.count, objectGroup.count])
        XCTAssertEqual(summary.indexed.groupSpans?.map(\.decodedOffset),
                       [state.count + 16, state.count + 16 + mixed.count])
        XCTAssertEqual(summary.indexed.nextDecodedOffset, indexed.count)

        var listObject = Data([1, 0, 0, 0]) + Data(repeating: 0, count: 20)
        listObject[16] = 2
        listObject += Data([4, 0, 108, 0, 105, 0, 115, 0, 116, 0])
        listObject += Data(repeating: 0, count: 16) + Data([1, 0, 0, 0, 0, 0])
        listObject += Data("objd".utf8) + Data([1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 65, 0])
        let listArray = try SaveVariableArrays(state: listObject, decodedOffset: 0)
        XCTAssertEqual(listArray.nextDecodedOffset, listObject.count)
        guard case .objectText(let elements) = listArray.records[0].values else {
            return XCTFail("Expected a saved text object")
        }
        XCTAssertEqual(elements.first?.payload?.lines, ["A"])
        XCTAssertEqual(elements.first?.payload?.decodedOffset, listObject.count - 20)
        var buttonObject = Data(listObject.dropLast(20))
        buttonObject.replaceSubrange(24..<34, with: [4, 0, 115, 0, 98, 0, 116, 0, 110, 0])
        buttonObject += Data("objd".utf8) + Data([1, 0, 0, 0, 0, 0, 0, 0])
        let libraryOffset = buttonObject.count
        buttonObject += Data(repeating: 0, count: 0xA5E)
        buttonObject += Data([1, 0, 65, 0])
        buttonObject += Data(repeating: 0, count: 33 * 6 + 64 * 2 + 256)
        for _ in 0..<4 {
            buttonObject += Data("vgene\0\0\0".utf8) + Data([3, 0, 0, 0]) + Data(repeating: 0, count: 44)
        }
        buttonObject += Data(repeating: 0, count: 2 + 8 * 6 + 2)
        let fixedOffset = buttonObject.count
        buttonObject += Data(repeating: 0, count: 189)
        buttonObject.replaceSubrange((fixedOffset + 12)..<(fixedOffset + 28),
            with: [1, 0, 0, 0, 2, 0, 0, 0, 31, 0, 0, 0, 42, 0, 0, 0])
        buttonObject += Data([1, 0, 65, 0]) + Data(repeating: 0, count: 8)
        let buttonOffset = buttonObject.count
        buttonObject += Data(repeating: 0, count: 42)
        let buttonArray = try SaveVariableArrays(state: buttonObject, decodedOffset: 0)
        let button = try XCTUnwrap(buttonArray.summary(in: buttonObject, at: 0).buttonPayloads.first)
        XCTAssertEqual(button.imageLibraryOffset, libraryOffset)
        XCTAssertEqual(button.imageSource?.decodedOffset, libraryOffset + 0xA5E + 2)
        XCTAssertEqual(try button.imageSource?.utf16Text(in: buttonObject), "A")
        XCTAssertEqual(button.fixedRecordOffset, fixedOffset)
        XCTAssertEqual(button.drawableRectangle, [1, 2, 31, 42])
        XCTAssertEqual(button.stringOffsets, [189, 193, 195, 197, 199].map { fixedOffset + $0 })
        XCTAssertEqual(button.buttonRecordOffset, buttonOffset)
        XCTAssertEqual(button.nextDecodedOffset, buttonObject.count)
        XCTAssertThrowsError(try SaveVariableArrays(state: Data(buttonObject.dropLast()), decodedOffset: 0))

        var fadingImage = Data(buttonObject.prefix(fixedOffset))
        fadingImage.replaceSubrange(24..<34, with: [4, 0, 115, 0, 105, 0, 109, 0, 103, 0])
        fadingImage.replaceSubrange(22..<24, with: [1, 0, 105, 0])
        let imageLibraryOffset = libraryOffset + 2 // One UTF-16 unit added for the variable name.
        for (offset, value): (Int, UInt8) in [(0x9c1, 0), (0x9c5, 200), (0x9c9, 25), (0x9cd, 100)] {
            fadingImage[imageLibraryOffset + offset] = value
        }
        var imageStorage = ScriptStorage()
        let imageArrays = try SaveVariableArrays(state: fadingImage, decodedOffset: 0)
        let parsedImage = try XCTUnwrap(imageArrays.summary(in: fadingImage, at: 0).imagePayloads.first)
        XCTAssertEqual(parsedImage.fixedRecord.decodedOffset, imageLibraryOffset)
        XCTAssertEqual(parsedImage.opacityTransition?.remaining, 25)
        XCTAssertEqual(try imageStorage.stageSavedGlobalImageIdentities(imageArrays), 1)
        guard case .object(let imageHandle) = try imageStorage.readIndexed("i", 0) else {
            return XCTFail("Expected a restored image identity")
        }
        var image = try XCTUnwrap(imageStorage.images[imageHandle])
        XCTAssertEqual(image.presentedOpacity, 150)
        image.advanceOpacity(ticks: 25)
        XCTAssertEqual(image.presentedOpacity, 200)
        XCTAssertNil(image.opacityEndpoint)
        fadingImage[imageLibraryOffset + 0xa42] = 1
        let repeating = try SaveVariableArrays(state: fadingImage, decodedOffset: 0)
        var repeatingStorage = ScriptStorage()
        XCTAssertEqual(try repeatingStorage.stageSavedGlobalImageIdentities(repeating), 1)
        guard case .object(let repeatingHandle) = try repeatingStorage.readIndexed("i", 0) else {
            return XCTFail("Expected a repeating image identity")
        }
        var repeatingImage = try XCTUnwrap(repeatingStorage.images[repeatingHandle])
        repeatingImage.advanceOpacity(ticks: 25)
        XCTAssertEqual(repeatingImage.presentedOpacity, 200)
        XCTAssertEqual(repeatingImage.opacityEndpoint?.repeats, 1)
        repeatingImage.advanceOpacity(ticks: 1)
        XCTAssertEqual(repeatingImage.opacityEndpoint?.remaining, 99)
        XCTAssertEqual(repeatingImage.opacityEndpoint?.repeats, 0)
        buttonObject.replaceSubrange(22..<24, with: [1, 0, 98, 0])
        var buttonStorage = ScriptStorage()
        XCTAssertEqual(try buttonStorage.stageSavedGlobalButtonIdentities(
            SaveVariableArrays(state: buttonObject, decodedOffset: 0)), 1)
        XCTAssertEqual(try buttonStorage.buttonArrayCount("b"), 1)
        if case .object(let handle) = try buttonStorage.readIndexed("b", 0) {
            XCTAssertEqual(buttonStorage.drawableRectangles[handle], [1, 2, 31, 42])
        } else {
            XCTFail("Expected an isolated button identity")
        }

        var namedList = listObject
        namedList.replaceSubrange(22..<24, with: [1, 0, 108, 0])
        var secondList = Data(namedList.suffix(22))
        secondList[20] = 66
        namedList[namedList.count - 26] = 2
        secondList[14] = 2
        secondList += Data([0, 0])
        namedList += secondList
        var listStorage = ScriptStorage()
        XCTAssertEqual(try listStorage.stageSavedGlobalTextObjects(
            SaveVariableArrays(state: namedList, decodedOffset: 0)).lists, 1)
        guard case .object(let handle) = try listStorage.readIndexed("l", 0),
              case .object(let secondListHandle) = try listStorage.readIndexed("l", 1) else {
            return XCTFail("Expected two staged list handles")
        }
        XCTAssertNotEqual(handle, secondListHandle)
        XCTAssertEqual(try listStorage.lists[handle]?.line(at: 0), "A")
        XCTAssertEqual(try listStorage.lists[secondListHandle]?.line(at: 0), "B")
        XCTAssertEqual(try listStorage.lists[secondListHandle]?.line(at: 1), "")
        XCTAssertThrowsError(try SaveVariableArrays(state: listObject.dropLast(), decodedOffset: 0))
        var tableObject = listObject
        tableObject.replaceSubrange(24..<34, with: Data([5, 0]) + Data([116, 0, 97, 0, 98, 0, 108, 0, 101, 0]))
        XCTAssertEqual(try SaveVariableArrays(state: tableObject, decodedOffset: 0).nextDecodedOffset,
                       tableObject.count)
        tableObject.replaceSubrange(22..<24, with: [1, 0, 116, 0])
        tableObject.replaceSubrange((tableObject.count - 4)..<tableObject.count,
                                    with: [3, 0, 120, 0, 61, 0, 121, 0])
        var secondElement = Data(tableObject.suffix(26))
        secondElement[24] = 122
        tableObject[tableObject.count - 30] = 2
        tableObject += secondElement
        XCTAssertEqual(try listStorage.stageSavedGlobalTextObjects(
            SaveVariableArrays(state: tableObject, decodedOffset: 0)).tables, 1)
        guard case .object(let tableHandle) = try listStorage.readIndexed("t", 0),
              case .object(let secondTableHandle) = try listStorage.readIndexed("t", 1) else {
            return XCTFail("Expected two staged table handles")
        }
        XCTAssertNotEqual(tableHandle, secondTableHandle)
        XCTAssertEqual(try listStorage.tables[tableHandle]?.value(for: "x"), "y")
        XCTAssertEqual(try listStorage.tables[secondTableHandle]?.value(for: "x"), "z")
        let lookup = try ScriptProgram(ScriptDocument(data: Data(
            "\\vexs,t\n\\cal,1/(ResultInt==2)\n\\jmp,@@Lookup\n\\cal,1/0\n@@Lookup\n\\scp,t[1]\n\\?v,\"x\"\n\\cal,1/(ResultStr==\"z\")\n\\wait,10\n".utf8),
            relativePath: "lookup.s"))
        let lookupEntry = try XCTUnwrap(lookup.document.records.firstIndex { $0.command == "vexs" })
        let continuation = try XCTUnwrap(ScriptMachine.probeSavedCalculations(
            program: lookup, index: lookupEntry, storage: listStorage))
        XCTAssertTrue(continuation.steps.contains { $0.action == "local_jump" })
        XCTAssertEqual(continuation.steps.last { $0.command == "cal" }?.action, "calculate")
        XCTAssertEqual(continuation.stopReason, "waiting_for_input_or_timer")

    }
}
