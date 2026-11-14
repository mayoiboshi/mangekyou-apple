import Foundation
import XCTest
import MangekyouMedia
@testable import MangekyouCore

final class SaveEnvelopeTests: XCTestCase {
    func testPlainStopWaitThreadAndCallbackRoundTrip() throws {
        let source = Data("@@Start\n\\scp,sys\n\\stop,@@!Imo_MesWaitAutoOnStop\n\\lk,0\n\\scp,\n\\cal,7\n\\clk\n@@!Imo_MesWaitAutoOnStop\n\\play\n\\ret\n".utf8)
        let program = try ScriptProgram(ScriptDocument(data: source, relativePath: "stop.s"))
        var live = try ScriptMachine(program: program, allowExperimental: true, entryLabel: "@@Start")
        try live.run()
        XCTAssertEqual(live.phase, .waitingForEvent)
        let thread = try live.encodeTimedWaitThread(readerOpaqueFields: Data(repeating: 0, count: 64))
        let reader = try SaveReaderCursor(threadState: thread)
        let routine = try XCTUnwrap(reader.routines.last)
        XCTAssertEqual(routine.rawState, 2)
        XCTAssertEqual(routine.waitTime, -1)
        XCTAssertEqual(routine.skipTime, -1)
        let label = try routine.eventLabel.utf16Text(in: thread)
        XCTAssertEqual(label, "@@!Imo_MesWaitAutoOnStop")
        XCTAssertEqual(try routine.eventName.utf16Text(in: thread), "")
        XCTAssertEqual(try routine.scope[0].utf16Text(in: thread), "sys")
        let anchor = program.document.records[0].location
        let position = try program.sourcePosition(for: reader, anchor: anchor)
        try program.validateSavedStop(position, label: label)
        XCTAssertThrowsError(try program.validateSavedStop(position, label: "@@wrong"))
        let successor = try program.savedResumeIndex(position, reader: reader)
        XCTAssertEqual(program.document.records[successor].command, "lk")
        var restoredStorage = ScriptStorage()
        restoredStorage.frames[0].tableScope = [ScriptStorage.systemHandle]
        let suspended = try XCTUnwrap(ScriptMachine.probeSavedCalculations(program: program, index: successor,
            storage: restoredStorage, savedStopLabel: label))
        XCTAssertEqual(suspended.stopReason, "waiting_for_script_event")
        XCTAssertEqual(suspended.eventWait?.kind, "message_auto_wait")
        XCTAssertTrue(suspended.steps.isEmpty)
        let resumed = try XCTUnwrap(ScriptMachine.probeSavedCalculations(program: program, index: successor,
            storage: restoredStorage, savedStopLabel: label, autoWaitClicks: 1))
        XCTAssertEqual(resumed.consumedInput?.autoWaitClicks, 1)
        XCTAssertTrue(resumed.steps.contains { $0.action == "stop_callback_play_candidate" })
        XCTAssertTrue(resumed.steps.contains { $0.command == "cal" })
        XCTAssertTrue(resumed.steps.contains { $0.command == "lk" })
        XCTAssertEqual(resumed.stopReason, "waiting_for_input_or_timer")
        let timed = try ScriptProgram(ScriptDocument(data: Data("@@Start\n\\stop,@@CB,10,10\n@@CB\n\\ret\n".utf8), relativePath: "timed-stop.s"))
        var timedLive = try ScriptMachine(program: timed, allowExperimental: true, entryLabel: "@@Start")
        try timedLive.run()
        XCTAssertThrowsError(try timedLive.encodeTimedWaitThread(readerOpaqueFields: Data(repeating: 0, count: 64)))
    }
    func testNestedIfSaveRestoresBothFrameControls() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/owned-save-tests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = Data("@@Root\n\\if,0\n\\then\n\\cal,1/0\n\\else\n\\sub,@@Child\n\\end\n\\cal,7\n\\clk\n@@Child\n\\if,1\n\\then\n\\stop,@@!Imo_MesWaitAutoOnStop\n\\end\n\\ret\n@@!Imo_MesWaitAutoOnStop\n\\play\n\\ret\n".utf8)
        try source.write(to: directory.appendingPathComponent("nested.s"))
        let catalog = try ScriptModuleCatalog(entries: [.init(logicalPath: "nested.s", sourceFile: "nested.s", sourceSHA256: source.sha256Hex)])
        var repository: ScriptRepository? = try ScriptRepository(directory: SafeDirectory(directory), catalog: catalog)
        var loadingRepository = try XCTUnwrap(repository)
        let program = try loadingRepository.load("nested.s")
        repository = loadingRepository
        var live = try ScriptMachine(program: program, allowExperimental: true, entryLabel: "@@Root", repository: repository)
        try live.run()
        let thread = try live.encodeTimedWaitThread(readerOpaqueFields: Data(repeating: 0, count: 64))
        let reader = try SaveReaderCursor(threadState: thread)
        XCTAssertEqual(reader.routines.map { $0.controlBlocks.map { $0.rawState } }, [[2], [1, 2]])
        var pinned = try XCTUnwrap(repository)
        let (returnPosition, returnIndex, caller, callerAnchor) = try SaveReaderCursor.routineReturnPosition(
            reader.routines[1].controlBlocks[0], in: thread, repository: &pinned)
        _ = returnPosition
        repository = pinned
        let target = try reader.resolveResumeInstruction(in: thread, repository: &pinned)
        repository = pinned
        let childAnchor = program.document.records[try program.label("@@Child")].location
        var restored = ScriptStorage()
        try ScriptMachine.stageSavedFrameControls(program: caller, index: try XCTUnwrap(returnIndex), anchor: callerAnchor,
            blocks: reader.routines[0].controlBlocks, state: thread, repository: &repository, storage: &restored, frameIndex: 0)
        try ScriptMachine.stageSavedCall(callee: target.program, anchor: childAnchor, caller: caller,
            returnIndex: try XCTUnwrap(returnIndex), catalog: catalog, storage: &restored)
        try ScriptMachine.stageSavedFrameControls(program: target.program, index: target.index, anchor: childAnchor,
            blocks: Array(reader.routines[1].controlBlocks.dropFirst()), state: thread, repository: &repository, storage: &restored, frameIndex: 1)
        let resumed = try XCTUnwrap(ScriptMachine.probeSavedCalculations(program: target.program, index: target.index,
            storage: restored, repository: repository, savedStopLabel: "@@!Imo_MesWaitAutoOnStop", autoWaitClicks: 1))
        XCTAssertEqual(resumed.stopReason, "waiting_for_input_or_timer")
        XCTAssertTrue(resumed.steps.contains { $0.command == "cal" })
    }
    func testBlankPrefixReturnCursorRoundTrip() throws {
        for (precedingLine, skipFirstBlank) in [("hello", false), ("\\cal,7", false), ("\\cal,7", true)] {
            let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".build/owned-save-tests/" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let setup = skipFirstBlank ? "\\gvar,int,PrefixCalls\n" : ""
            let skip = skipFirstBlank ? "\\cal,PrefixCalls=PrefixCalls+1\n\\if,PrefixCalls==1\\then\n\\ret\n\\end\n" : ""
            let source = Data("@@@included.s\n@@Root\n\\gvar,int,Imo_SentenceFlag\n\(setup)\\cal,Imo_SentenceFlag=1\n\\scp,rep\n\\nt,\"\\subp,@@Blank\"\n\\et,\"\\subp,@@Text,,\"\n\\scp,\n\(precedingLine)\n\n\n\\cal,7\n\\clk\n@@AfterStop\n\\cal,Imo_SentenceFlag=0\n\\ret\n".utf8)
            let included = Data("@@Text\n\\ret\n@@Blank\n\(skip)\\if,Imo_SentenceFlag==0\\then\n\\ret\n\\end\n\\stop,@@!Imo_MesWaitAutoOnStop\n\\sub,@@AfterStop\n\\ret\n@@!Imo_MesWaitAutoOnStop\n\\play\n\\ret\n".utf8)
            try source.write(to: directory.appendingPathComponent("blank.s"))
            try included.write(to: directory.appendingPathComponent("included.s"))
            let catalog = try ScriptModuleCatalog(entries: [
                .init(logicalPath: "blank.s", sourceFile: "blank.s", sourceSHA256: source.sha256Hex),
                .init(logicalPath: "included.s", sourceFile: "included.s", sourceSHA256: included.sha256Hex)])
            var repository = try ScriptRepository(directory: SafeDirectory(directory), catalog: catalog)
            let program = try repository.load("blank.s")
            var live = try ScriptMachine(program: program, allowExperimental: true, entryLabel: "@@Root", repository: repository)
            try live.run()
            XCTAssertEqual(live.phase, .waitingForEvent)
            XCTAssertTrue(live.traces.contains { $0.action == "blank_line_prefix_call_candidate" })
            let thread = try live.encodeTimedWaitThread(readerOpaqueFields: Data(repeating: 0, count: 64))
            try live.validateTimedWaitReturnCursors(thread)
            let reader = try SaveReaderCursor(threadState: thread)
            let block = try XCTUnwrap(reader.routines.last?.controlBlocks.first)
            XCTAssertEqual(Int(block.rawValueAt3C), "\\subp,@@Blank".utf16.count)
            let (_, instruction, caller, _) = try SaveReaderCursor.routineReturnPosition(block, in: thread,
                repository: &repository, emptyLineText: try reader.emptyLineText.utf16Text(in: thread))
            let index = try XCTUnwrap(instruction)
            XCTAssertEqual(caller.document.records[index - 1].kind, .empty)
            if skipFirstBlank { XCTAssertEqual(caller.document.records[index - 2].kind, .empty) }
            let target = try reader.resolveResumeInstruction(in: thread, repository: &repository)
            let anchor = caller.document.records[try caller.label("@@Blank")].location
            var restored = ScriptStorage()
            try restored.restoreReaderPrefixes(reader, in: thread)
            let savedLocal = Data("savedlocal".utf8)
            try ScriptMachine.stageSavedCall(callee: target.program, anchor: anchor, caller: caller,
                returnIndex: index, catalog: catalog,
                locals: [savedLocal: ScriptBinding(elements: [.integer(17)])], storage: &restored)
            XCTAssertEqual(restored.frames.count, 2)
            XCTAssertEqual(restored.frames.last?.locals[savedLocal]?.first, .integer(17))
            XCTAssertThrowsError(try ScriptMachine.stageSavedCall(callee: target.program, anchor: anchor, caller: caller,
                returnIndex: index, catalog: catalog, storage: &restored))
            restored.global[Data("imo_sentenceflag".utf8)] = ScriptBinding(elements: [.integer(1)])
            let expandedTarget = try ScriptMachine.mapSavedPosition(
                (target.program, target.index, anchor), to: caller)
            if precedingLine == "\\cal,7", !skipFirstBlank {
                var resumedProgress = try XCTUnwrap(ScriptMachine.makeSavedExecutionMachine(
                    program: expandedTarget.program, index: expandedTarget.index, storage: restored,
                    repository: repository, wait: nil, stopLabel: "@@!Imo_MesWaitAutoOnStop",
                    maximumSteps: 1000, retainFullTrace: true, imageLoader: nil, imageMemberLookup: nil,
                    imageExtendedValues: nil, imageMotionNames: nil))
                resumedProgress.allowLabelProgressCandidate = true
                try resumedProgress.dispatchStopCallback()
                try resumedProgress.run()
                XCTAssertGreaterThan(resumedProgress.labelProgressReturnOutcomes["advanced"] ?? 0, 0)
            }
            let resumed = try XCTUnwrap(ScriptMachine.probeSavedCalculations(program: expandedTarget.program,
                index: expandedTarget.index, storage: restored, repository: repository,
                savedStopLabel: "@@!Imo_MesWaitAutoOnStop", autoWaitClicks: 1))
            XCTAssertEqual(resumed.stopReason, "waiting_for_input_or_timer")
            XCTAssertTrue(resumed.steps.contains { $0.command == "sub" })
            XCTAssertThrowsError(try SaveReaderCursor.routineReturnPosition(block, in: thread,
                repository: &repository, emptyLineText: "\\subp,@@Blank,extra"))
        }
    }
    func testSavedBlankPrefixRejectsInternalLabel() throws {
        let source = Data("@@!Internal\n\n\\cal,7\n@@Blank\n\\ret\n".utf8)
        let program = try ScriptProgram(ScriptDocument(data: source, relativePath: "internal.s"))
        let blank = try XCTUnwrap(program.document.records.firstIndex { $0.kind == .empty })
        let anchor = program.document.records[try program.label("@@Blank")].location
        var storage = ScriptStorage()
        storage.noWordLineText = "\\subp,@@Blank"
        XCTAssertThrowsError(try ScriptMachine.stageSavedCall(callee: program, anchor: anchor, caller: program,
            returnIndex: blank + 1, catalog: nil, storage: &storage))
        XCTAssertEqual(storage.frames.count, 1)
    }
    func testSavedConsecutiveBlankPrefixCanRestore() throws {
        let source = Data("@@Root\n\\cal,7\n\n\n\\cal,8\n@@Blank\n\\ret\n".utf8)
        let program = try ScriptProgram(ScriptDocument(data: source, relativePath: "consecutive.s"))
        let blanks = program.document.records.indices.filter { program.document.records[$0].kind == .empty }
        XCTAssertEqual(blanks.count, 2)
        let second = try XCTUnwrap(blanks.last)
        let anchor = program.document.records[try program.label("@@Blank")].location
        var storage = ScriptStorage()
        storage.noWordLineText = "\\subp,@@Blank"
        try ScriptMachine.stageSavedCall(callee: program, anchor: anchor, caller: program,
            returnIndex: second + 1, catalog: nil, storage: &storage)
        XCTAssertEqual(storage.frames.count, 2)
    }
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
        var withOpaqueSlot = Data(state.dropLast(2))
        withOpaqueSlot += Data([1, 0, 90, 0])
        let names = ["新名称", "", "", "", "", "", "end"]
        let rewritten = try SaveEngineState.replacingSystemFields(in: withOpaqueSlot, at: 0, names: names,
                                                                 lockMask: 0x1234, customLockMask: -42)
        let rewrittenTail = try SaveEngineState(state: rewritten, at: 0)
        XCTAssertEqual(try rewrittenTail.systemNameSlots(in: rewritten), names)
        XCTAssertEqual(rewrittenTail.systemLockMask, 0x1234)
        XCTAssertEqual(rewrittenTail.systemCustomLockMask, -42)
        XCTAssertEqual(rewritten.prefix(12), withOpaqueSlot.prefix(12))
        XCTAssertEqual(rewritten[20..<firstOffset], withOpaqueSlot[20..<firstOffset])
        XCTAssertEqual(rewritten.suffix(4), withOpaqueSlot.suffix(4))
        let liveProgram = try ScriptProgram(ScriptDocument(data: Data(
            "\\scp,sys\n\\lk,4660\n\\lkc,-42\n\\n2,0,\"Live\"\n\\scp,\n\\wait,120\n".utf8),
            relativePath: "live-system.s"))
        var liveMachine = try ScriptMachine(program: liveProgram, allowExperimental: true)
        try liveMachine.run()
        let liveTail = try liveMachine.encodeTimedWaitSystemFields(template: withOpaqueSlot)
        let liveFields = try SaveEngineState(state: liveTail, at: 0)
        XCTAssertEqual(liveFields.systemLockMask, 4660)
        XCTAssertEqual(liveFields.systemCustomLockMask, -42)
        XCTAssertEqual(try liveFields.systemNameSlots(in: liveTail).first, "Live")
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

    func testSavedCaptureFadeUsesVisualClock() throws {
        let script = Data("\\scp,eff\n\\c,60000\n\\fdp,0,0,100,100,0\n\\fdm,1,100\n\\fdi,0,100,\"\",60000\n".utf8)
        let program = try ScriptProgram(ScriptDocument(data: script, relativePath: "effect.s"))
        let entry = try XCTUnwrap(program.document.records.firstIndex { $0.command == "scp" })
        var sampledOpacity: [UInt32: UInt8] = [:]
        let result = try ScriptMachine.probeSavedCalculations(program: program, index: entry, storage: ScriptStorage(),
            drawScene: { machine, pass in
                switch pass {
                case .capture:
                    return (.init(status: .inferred), Data([1]))
                case .overlapSample(_, let elapsed, _):
                    var sample = machine
                    sample.advanceVisualClock(ticks: Int32(elapsed))
                    sampledOpacity[elapsed] = sample.savedCaptureFade?.opacity ?? 0
                    return (.init(status: .inferred), nil)
                case .scene, .frozenLayerScene:
                    return (.init(status: .inferred), nil)
                }
            })
        XCTAssertEqual(sampledOpacity, [0: 255, 50: 127, 100: 0], "\(result?.stopReason ?? "nil") \(result?.steps.map(\.action) ?? [])")
    }

    func testSavedPlaybackConsumesSeekOnce() throws {
        var streamTemplate = Data(repeating: 0, count: 131)
        streamTemplate[0x10] = 2
        streamTemplate[0x11] = 7
        let encodedStream = try SaveStatePrefix.StreamChannel.replacingPlayback(in: streamTemplate,
            milliseconds: 1250, repeats: -1, volume: 192, pan: -48)
        let stream = encodedStream.withUnsafeBytes { SaveStatePrefix.StreamChannel(bytes: $0, start: 0) }
        XCTAssertEqual(stream.rawLoadOption, 7)
        XCTAssertEqual(stream.rawPlayerFlag508, 0)
        XCTAssertEqual(stream.rawPlayerFlag509, 0)
        var invalidFlags = streamTemplate
        invalidFlags[0x25] = 2
        XCTAssertThrowsError(try SaveStatePrefix.StreamChannel.replacingPlayback(in: invalidFlags,
            milliseconds: 1250, repeats: -1, volume: 192, pan: -48))
        XCTAssertEqual(Float(bitPattern: stream.rawSeekBits), 1.25)
        XCTAssertEqual(stream.resumeRepeatCount, -1)
        XCTAssertEqual(stream.resumeVolume, 192)
        XCTAssertEqual(stream.resumePan, -48)
        let fractional = try SaveStatePrefix.StreamChannel.replacingPlayback(in: streamTemplate,
            milliseconds: 1001, repeats: -1, volume: 192, pan: -48)
        let fractionalStream = fractional.withUnsafeBytes { SaveStatePrefix.StreamChannel(bytes: $0, start: 0) }
        XCTAssertTrue(fractionalStream.matchesEncodedMilliseconds(1001))
        XCTAssertFalse(fractionalStream.matchesEncodedMilliseconds(1000))
        let readerBytes = try SaveReaderCursor.encodeRecord(relativeLine: 0, utf16Position: 0,
            replaceEnableByte: 0, opaqueFields: Data(repeating: 0, count: 64), lineBuffer: "",
            scriptPath: "test.s", label: "Start", textPrefix: "", emptyLineText: "")
        var streamState = try SaveReaderCursor.encodeThread(routines: [], reader: readerBytes)
        let reader = try SaveReaderCursor(threadState: streamState)
        streamState += Data(repeating: 0, count: 4 + 1 + 76 + 256 * 24)
        streamState += Data("dsnd\0\0\0\0".utf8) + Data(repeating: 0, count: 4)
        streamState += Data("ssnd\0\0\0\0".utf8) + Data([1, 0, 0, 0])
        streamState += streamTemplate + Data([5, 0]) + Data("a.ogg".utf16.flatMap { [UInt8($0), 0] }) + Data([0, 0])
        let sound = ScriptModuleReference(logicalPath: "a.ogg", sourceFile: "assets/a.ogg", sourceSHA256: Data([1]).sha256Hex)
        let catalog = try ScriptModuleCatalog(entries: [sound])
        let prefix = try SaveStatePrefix(state: streamState, after: reader)
        XCTAssertEqual(prefix.savedStreamNameCandidates(in: streamState)[0], "a.ogg")
        XCTAssertEqual(prefix.savedStreamFilterCandidates(in: streamState)[0], "")
        var changedStreamName = streamState
        let nameReference = try XCTUnwrap(prefix.ssndReferences.first?.strings.first)
        changedStreamName[changedStreamName.startIndex + nameReference.decodedOffset] ^= 1
        XCTAssertNil(prefix.savedStreamNameCandidates(in: changedStreamName)[0])
        var resumedStorage = ScriptStorage()
        resumedStorage.unknownStreamFieldsOnRestore = true
        XCTAssertEqual(resumedStorage.stageSavedStreamNames(prefix.savedStreamNameCandidates(in: streamState)), 1)
        guard case .object(let resumedChannel) = try resumedStorage.readIndexed("snd", 0),
              case .object(let absentChannel) = try resumedStorage.readIndexed("snd", 1) else {
            return XCTFail("Expected saved stream handles")
        }
        XCTAssertEqual(resumedStorage.soundChannels[resumedChannel]?.filterRequestKnown, false)
        resumedStorage.ensureStreamChannel(absentChannel)
        XCTAssertEqual(resumedStorage.soundChannels[absentChannel]?.requestedSourceNameKnown, false)
        XCTAssertEqual(resumedStorage.soundChannels[absentChannel]?.filterRequestKnown, false)
        XCTAssertEqual(resumedStorage.stageSavedStreamFilters([0: "saved-filter"]), 1)
        let querySource = Data("\\gvar,str,Name,Filter\n\\scp,snd[0]\n\\?l\n\\cal,Name=ResultStr[0]\n\\?fo\n\\cal,Filter=ResultStr[0]\n\\wait,1\n".utf8)
        let queryProgram = try ScriptProgram(ScriptDocument(data: querySource, relativePath: "saved-name-query.s"))
        let queryIndex = try XCTUnwrap(queryProgram.document.records.firstIndex { $0.kind == .command })
        var queryMachine = try XCTUnwrap(ScriptMachine.makeSavedExecutionMachine(program: queryProgram,
            index: queryIndex, storage: resumedStorage, repository: nil, wait: nil, maximumSteps: 100,
            retainFullTrace: false, imageLoader: nil, imageMemberLookup: nil,
            imageExtendedValues: nil, imageMotionNames: nil))
        try queryMachine.run()
        XCTAssertEqual(queryMachine.phase, .waiting)
        XCTAssertEqual(try queryMachine.value(named: "Name"), .string("a.ogg"))
        XCTAssertEqual(try queryMachine.value(named: "Filter"), .string("saved-filter"))
        var liveAudio = ScriptStorage()
        guard case .object(let liveChannel) = try liveAudio.readIndexed("snd", 0) else {
            return XCTFail("Expected stream channel zero")
        }
        XCTAssertEqual(ScriptMachine.streamSaveChannelIndex(liveChannel), 0)
        liveAudio.soundChannels[liveChannel] = .init(playing: true, loopRequest: -1,
            panRequest: (-48, 0, 0), volume: 192, resource: sound.wholeFileLocation(byteLength: 1),
            requestedSourceName: "a.ogg")
        let rewritten = try prefix.replacingStreamPlayback(in: streamState, channel: 0,
            source: sound.wholeFileLocation(byteLength: 1), catalog: catalog,
            milliseconds: 1250, repeats: -1, volume: 192, pan: -48)
        XCTAssertEqual(try prefix.replacingLiveStreamPlayback(in: streamState, channel: 0, storage: liveAudio,
            catalog: catalog, milliseconds: 1250), rewritten)
        let normalized = try prefix.replacingLiveStreams(in: streamState, storage: liveAudio,
            catalog: catalog, positions: [0: 1250])
        let filterReference = try XCTUnwrap(prefix.ssndReferences.first?.strings.last)
        var staleFilterDonor = streamState
        let oldFilter = "old-filter"
        var oldFilterField = Data([UInt8(oldFilter.utf16.count), 0])
        oldFilterField.append(oldFilter.data(using: .utf16LittleEndian)!)
        staleFilterDonor.replaceSubrange((filterReference.decodedOffset - 2)..<(filterReference.decodedOffset + filterReference.length), with: oldFilterField)
        let staleFilterPrefix = try SaveStatePrefix(state: staleFilterDonor, after: reader)
        XCTAssertEqual(staleFilterPrefix.savedStreamFilterCandidates(in: staleFilterDonor)[0], oldFilter)
        let clearedFilter = try staleFilterPrefix.replacingLiveStreams(in: staleFilterDonor, storage: liveAudio,
            catalog: catalog, positions: [0: 1250])
        let clearedFilterPrefix = try SaveStatePrefix(state: clearedFilter, after: reader)
        XCTAssertEqual(clearedFilterPrefix.savedStreamFilterCandidates(in: clearedFilter)[0], "")
        XCTAssertEqual(clearedFilter.count, streamState.count)
        var unhandledFilter = liveAudio
        unhandledFilter.soundChannels[liveChannel]?.filterRequest = "active-filter"
        XCTAssertThrowsError(try prefix.replacingLiveStreams(in: streamState, storage: unhandledFilter,
            catalog: catalog, positions: [0: 1250])) { error in
            XCTAssertTrue(String(describing: error).contains("saved_stream_filter_application_unverified"))
        }
        var differentlySpelled = liveAudio
        differentlySpelled.soundChannels[liveChannel]?.requestedSourceName = "A.OGG"
        let renamed = try prefix.replacingLiveStreams(in: streamState, storage: differentlySpelled,
            catalog: catalog, positions: [0: 1250])
        let renamedPrefix = try SaveStatePrefix(state: renamed, after: reader)
        XCTAssertEqual(try renamedPrefix.ssndReferences[0].strings[0].utf16Text(in: renamed), "A.OGG")
        var unknownName = liveAudio
        unknownName.soundChannels[liveChannel]?.requestedSourceNameKnown = false
        XCTAssertThrowsError(try prefix.replacingLiveStreams(in: streamState, storage: unknownName,
            catalog: catalog, positions: [0: 1250]))
        var unobservedRepeats = liveAudio
        unobservedRepeats.soundChannels[liveChannel]?.loopRequest = 2
        XCTAssertThrowsError(try prefix.replacingLiveStreams(in: streamState, storage: unobservedRepeats,
            catalog: catalog, positions: [0: 1250])) { error in
            XCTAssertTrue(String(describing: error).contains("saved_stream_repeat_count_unobserved"))
        }
        var immediateOutstanding = liveAudio
        let immediateToken = UUID()
        immediateOutstanding.soundChannels[liveChannel]?.volumeControlToken = immediateToken
        XCTAssertThrowsError(try prefix.replacingLiveStreams(in: streamState, storage: immediateOutstanding,
            catalog: catalog, positions: [0: 1250]))
        XCTAssertTrue(immediateOutstanding.acknowledgeSoundControl(channel: liveChannel, token: immediateToken, volume: true))
        XCTAssertNoThrow(try prefix.replacingLiveStreams(in: streamState, storage: immediateOutstanding,
            catalog: catalog, positions: [0: 1250]))
        var dispatchedFade = liveAudio
        dispatchedFade.soundChannels[liveChannel]?.volumeDuration = 500
        dispatchedFade.soundChannels[liveChannel]?.volumeChangePending = false
        XCTAssertThrowsError(try prefix.replacingLiveStreams(in: streamState, storage: dispatchedFade,
            catalog: catalog, positions: [0: 1250]))
        let volumeToken = UUID()
        dispatchedFade.soundChannels[liveChannel]?.volumeControlToken = volumeToken
        let originalPlaybackStep = dispatchedFade.soundChannels[liveChannel]?.playbackStartStep
        dispatchedFade.soundChannels[liveChannel]?.volumeControlPlaybackStep = originalPlaybackStep
        XCTAssertFalse(dispatchedFade.acknowledgeSoundControl(channel: liveChannel, token: UUID(), volume: true))
        XCTAssertTrue(dispatchedFade.acknowledgeSoundControl(channel: liveChannel, token: volumeToken, volume: true))
        XCTAssertFalse(dispatchedFade.acknowledgeSoundControl(channel: liveChannel, token: volumeToken, volume: true))
        XCTAssertNoThrow(try prefix.replacingLiveStreams(in: streamState, storage: dispatchedFade,
            catalog: catalog, positions: [0: 1250]))
        var dispatchedPan = liveAudio
        dispatchedPan.soundChannels[liveChannel]?.panRequest = (0, 0, 500)
        dispatchedPan.soundChannels[liveChannel]?.panChangePending = false
        XCTAssertThrowsError(try prefix.replacingLiveStreams(in: streamState, storage: dispatchedPan,
            catalog: catalog, positions: [0: 1250]))
        let panToken = UUID()
        dispatchedPan.soundChannels[liveChannel]?.panControlToken = panToken
        dispatchedPan.soundChannels[liveChannel]?.panControlPlaybackStep = 1
        dispatchedPan.soundChannels[liveChannel]?.playbackStartStep = 2
        XCTAssertFalse(dispatchedPan.acknowledgeSoundControl(channel: liveChannel, token: panToken, volume: false))
        dispatchedPan.soundChannels[liveChannel]?.panControlPlaybackStep = 2
        XCTAssertTrue(dispatchedPan.acknowledgeSoundControl(channel: liveChannel, token: panToken, volume: false))
        XCTAssertNoThrow(try prefix.replacingLiveStreams(in: streamState, storage: dispatchedPan,
            catalog: catalog, positions: [0: 1250]))
        var delayedDonor = streamState
        let recordStart = try XCTUnwrap(prefix.ssndReferences.first).record.decodedOffset
        delayedDonor[recordStart + 0x33] = 1
        delayedDonor[recordStart + 0x3f] = 1
        let delayedPrefix = try SaveStatePrefix(state: delayedDonor, after: reader)
        let cleared = try delayedPrefix.replacingLiveStreams(in: delayedDonor, storage: liveAudio,
            catalog: catalog, positions: [0: 1250])
        XCTAssertEqual(Array(cleared[(recordStart + 0x33)..<(recordStart + 0x37)]), [0, 0, 0, 0])
        XCTAssertEqual(Array(cleared[(recordStart + 0x3f)..<(recordStart + 0x43)]), [0, 0, 0, 0])
        XCTAssertEqual(try SaveStatePrefix(state: normalized, after: reader).ssndReferences.first?.streamChannel?.rawMode, 3)
        let disabledDonor = try prefix.replacingLiveStreams(in: streamState, storage: ScriptStorage(), catalog: catalog, positions: [:])
        let disabledPrefix = try SaveStatePrefix(state: disabledDonor, after: reader)
        XCTAssertEqual(try disabledPrefix.ssndReferences[0].strings[0].utf16Text(in: disabledDonor), "")
        XCTAssertEqual(disabledPrefix.nextDecodedOffset, prefix.nextDecodedOffset - 10)
        XCTAssertEqual(try SaveStatePrefix(state: disabledDonor, after: reader).ssndReferences.first?.streamChannel?.rawMode, 0)
        var directPlaying = ScriptStorage()
        directPlaying.soundChannels[UInt64.max - 2048] = .init(playing: true)
        XCTAssertThrowsError(try prefix.replacingLiveStreams(in: streamState, storage: directPlaying, catalog: catalog, positions: [:])) {
            XCTAssertEqual(String(describing: $0), "saved_direct_sound_live_state_unsupported: count=1")
        }
        var unknownMode = streamState
        unknownMode[prefix.ssndReferences[0].record.decodedOffset + 0x10] = 4
        let unknownPrefix = try SaveStatePrefix(state: unknownMode, after: reader)
        XCTAssertThrowsError(try unknownPrefix.replacingLiveStreams(in: unknownMode,
            storage: ScriptStorage(), catalog: catalog, positions: [:]))
        XCTAssertThrowsError(try prefix.replacingLiveStreams(in: streamState, storage: liveAudio,
            catalog: catalog, positions: [:])) {
            XCTAssertEqual(String(describing: $0),
                "saved_stream_write_position_coverage: live=[0] template=[0] supplied=[]")
        }
        let parsed = try SaveStatePrefix(state: rewritten, after: reader)
        let saved = try XCTUnwrap(parsed.ssndReferences.first)
        XCTAssertEqual(saved.streamChannel?.rawSeekBits, Float(1.25).bitPattern)
        var idleDonor = rewritten
        idleDonor[saved.record.decodedOffset + 0x10] = 1
        let idlePrefix = try SaveStatePrefix(state: idleDonor, after: reader)
        let activated = try idlePrefix.replacingLiveStreams(in: idleDonor, storage: liveAudio,
            catalog: catalog, positions: [0: 1250])
        let activatedChannel = try XCTUnwrap(SaveStatePrefix(state: activated, after: reader).ssndReferences.first?.streamChannel)
        XCTAssertEqual(activatedChannel.rawMode, 3)
        XCTAssertEqual(activatedChannel.rawLoadOption, 7)
        XCTAssertTrue(activatedChannel.matchesEncodedMilliseconds(1250))
        XCTAssertEqual(activatedChannel.resumeRepeatCount, -1)
        var mismatchedAudio = liveAudio
        mismatchedAudio.soundChannels[liveChannel]?.resource = ScriptModuleReference(logicalPath: "a.ogg",
            sourceFile: "assets/a.ogg", sourceSHA256: Data([2]).sha256Hex).wholeFileLocation(byteLength: 1)
        XCTAssertThrowsError(try idlePrefix.replacingLiveStreams(in: idleDonor, storage: mismatchedAudio,
            catalog: catalog, positions: [0: 1250]))
        liveAudio.soundChannels[liveChannel]?.loopRequest = 0
        let finite = try idlePrefix.replacingLiveStreams(in: idleDonor, storage: liveAudio,
            catalog: catalog, positions: [0: 1250])
        XCTAssertEqual(try SaveStatePrefix(state: finite, after: reader).ssndReferences.first?.streamChannel?.rawMode, 2)
        liveAudio.soundChannels[liveChannel]?.loopRequest = -1
        let withoutDonorStream = try idlePrefix.replacingLiveStreams(in: idleDonor,
            storage: ScriptStorage(), catalog: catalog, positions: [:])
        XCTAssertEqual(try SaveStatePrefix(state: withoutDonorStream, after: reader)
            .ssndReferences.first?.streamChannel?.rawMode, 0)
        liveAudio.soundChannels[liveChannel]?.playing = false
        liveAudio.soundChannels[liveChannel]?.seekRequest = 1250
        XCTAssertEqual(try idlePrefix.replacingLiveStreams(in: idleDonor, storage: liveAudio,
            catalog: catalog, positions: [:]), idleDonor)
        liveAudio.soundChannels[liveChannel]?.seekRequest = 1251
        liveAudio.soundChannels[liveChannel]?.volume = 128
        let rewrittenIdle = try idlePrefix.replacingLiveStreams(in: idleDonor, storage: liveAudio,
            catalog: catalog, positions: [:])
        let idle = try SaveStatePrefix(state: rewrittenIdle, after: reader).ssndReferences.first?.streamChannel
        XCTAssertEqual(idle?.rawMode, 1)
        XCTAssertEqual(idle?.matchesEncodedMilliseconds(1251), true)
        XCTAssertEqual(idle?.resumeVolume, 128)
        XCTAssertEqual(try saved.strings[0].utf16Text(in: rewritten), "a.ogg")
        XCTAssertEqual(parsed.nextDecodedOffset, streamState.count)
        XCTAssertThrowsError(try prefix.replacingStreamPlayback(in: rewritten, channel: 0,
            source: sound.wholeFileLocation(byteLength: 1), catalog: catalog,
            milliseconds: 2500, repeats: -1, volume: 192, pan: -48))
        let script = Data("\\scp,snd[1]\n\\p2,0\n\\p2,0\n".utf8)
        let program = try ScriptProgram(ScriptDocument(data: script, relativePath: "sound.s"))
        let entry = try XCTUnwrap(program.document.records.firstIndex { $0.command == "scp" })
        var storage = ScriptStorage()
        guard case .object(let channel) = try storage.readIndexed("snd", 1) else {
            return XCTFail("Expected an indexed stream")
        }
        XCTAssertEqual(ScriptMachine.streamSaveChannelIndex(channel), 1)
        XCTAssertNil(ScriptMachine.streamSaveChannelIndex(1))
        let source = ScriptModuleReference(logicalPath: "owned.ogg", sourceFile: "owned.ogg",
                                           sourceSHA256: Data().sha256Hex).wholeFileLocation(byteLength: 0)
        storage.soundChannels[channel] = .init(seekRequest: 1250, resource: source)
        var seeks: [Int32?] = []
        let result = try XCTUnwrap(ScriptMachine.probeSavedCalculations(
            program: program, index: entry, storage: storage, decodeSound: { actualSource, seek in
                XCTAssertEqual(actualSource, source)
                seeks.append(seek)
            }))
        XCTAssertEqual(result.decodedSoundRequestCount, 2)
        XCTAssertEqual(seeks, [1250, nil])
    }

    func testSavedPreviewPreservesEarlierFrameFailure() {
        var boundary = ScriptMachine.SaveResumeBoundary(routineCount: 1, resultSnapshotCount: 0,
            controlBlockCount: 0, unresolvedResultObjectReferenceCount: 0, variableArrays: nil)
        boundary.isolatedContinuation = .init(steps: [], nextLocation: nil, stopReason: "waiting_for_script_event",
            eventFrame: .init(status: .unsupported, issue: "first_frame_incomplete"),
            advancedEventFrame: .init(status: .inferred))
        XCTAssertEqual(boundary.replaySceneDraw?.issue, "first_frame_incomplete")
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
        let waitingCaller = Data("@@Start\n\\sub,@@Child,\"waiting-child.s\"\n\\cal,7\n\\clk\n".utf8)
        let waitingChild = Data("@@Child\n\\scp,rep\n\\et,\"prefix\"\n\\nt,\"empty\"\n\\a,\"^name\",\"value\"\n\\scp,sys\n\\lk,0\n\\lkc,0\n\\scp,\n\\wait,120\n\\ret\n".utf8)
        let aliasSource = Data("@@Start\n\\var,obj,voice\n\\cal,voice=snd[3]\n\\wait,120\n\\cal,7\n".utf8)
        try waitingCaller.write(to: directory.appendingPathComponent("waiting-caller.s"))
        try waitingChild.write(to: directory.appendingPathComponent("waiting-child.s"))
        try aliasSource.write(to: directory.appendingPathComponent("alias-wait.s"))
        let catalog = try ScriptModuleCatalog(entries: [
            ScriptModuleReference(logicalPath: "owned.s", sourceFile: "owned.s", sourceSHA256: source.sha256Hex),
            .init(logicalPath: "caller.s", sourceFile: "caller.s", sourceSHA256: caller.sha256Hex),
            .init(logicalPath: "target.s", sourceFile: "target.s", sourceSHA256: target.sha256Hex),
            .init(logicalPath: "waiting-caller.s", sourceFile: "waiting-caller.s", sourceSHA256: waitingCaller.sha256Hex),
            .init(logicalPath: "waiting-child.s", sourceFile: "waiting-child.s", sourceSHA256: waitingChild.sha256Hex),
            .init(logicalPath: "alias-wait.s", sourceFile: "alias-wait.s", sourceSHA256: aliasSource.sha256Hex)
        ])
        var repository = try ScriptRepository(directory: SafeDirectory(directory), catalog: catalog)

        let timer = try ScriptProgram(ScriptDocument(data: Data(
            "@@Timer\n\\wait,120\n\\cal,1\n".utf8), relativePath: "timer.s"))
        let waitIndex = try XCTUnwrap(timer.document.records.firstIndex { $0.command == "wait" })
        let wait = timer.document.records[waitIndex].location
        let afterWait = wait.byteOffset + wait.byteLength
        let waitCursor = timer.document.source.location(afterWait..<afterWait, line: wait.lineNumber)
        let successor = try timer.savedTimedWaitSuccessor(waitCursor)
        XCTAssertEqual(timer.document.records[successor].command, "cal")
        let timerAnchor = timer.document.records[0].location
        let waitFields = try timer.savedReaderFields(commandIndex: waitIndex, anchor: timerAnchor, afterWaitCommand: "wait")
        XCTAssertEqual(waitFields.line, 1)
        XCTAssertEqual(waitFields.position, 9)
        XCTAssertEqual(waitFields.text, "\\wait,120")
        var liveWait = try ScriptMachine(program: timer, allowExperimental: true, entryLabel: "@@Timer")
        try liveWait.run()
        try liveWait.advanceClickWait(ticks: 101)
        let liveThread = try liveWait.encodeTimedWaitThread(scriptPath: "timer.s",
            readerOpaqueFields: Data(repeating: 0, count: 64))
        let liveReader = try SaveReaderCursor(threadState: liveThread)
        XCTAssertEqual(liveReader.routines.first?.waitTime, 19)
        let livePosition = try liveReader.resolveSourcePosition(anchor: timerAnchor, source: timer.document.source)
        XCTAssertEqual(try timer.savedResumeIndex(livePosition, reader: liveReader), successor)
        let clickProgram = try ScriptProgram(ScriptDocument(data: Data(
            "@@Click\n\\clk\n\\cal,1/0\n".utf8), relativePath: "click.s"))
        var clickWait = try ScriptMachine(program: clickProgram, allowExperimental: true, entryLabel: "@@Click")
        try clickWait.run()
        let clickThread = try clickWait.encodeTimedWaitThread(readerOpaqueFields: Data(repeating: 0, count: 64))
        let clickReader = try SaveReaderCursor(threadState: clickThread)
        XCTAssertEqual(clickReader.routines.last?.rawState, 4)
        XCTAssertEqual(clickReader.routines.last?.waitTime, -1)
        let clickPosition = try clickProgram.sourcePosition(for: clickReader,
            anchor: clickProgram.document.records[0].location)
        let clickIndex = try clickProgram.savedResumeIndex(clickPosition, reader: clickReader)
        let clickProbe = try XCTUnwrap(ScriptMachine.probeSavedCalculations(program: clickProgram,
            index: clickIndex, storage: ScriptStorage(), savedWait: -1))
        XCTAssertEqual(clickProbe.waitRemaining, -1)
        XCTAssertTrue(clickProbe.steps.isEmpty)

        let finiteClickProgram = try ScriptProgram(ScriptDocument(data: Data(
            "@@Click\n\\scp,eff\n\\clk,100\n\\cal,1/0\n".utf8), relativePath: "finite-click.s"))
        var finiteClick = try ScriptMachine(program: finiteClickProgram, allowExperimental: true, entryLabel: "@@Click")
        try finiteClick.run()
        try finiteClick.advanceClickWait(ticks: 35)
        let finiteThread = try finiteClick.encodeTimedWaitThread(readerOpaqueFields: Data(repeating: 0, count: 64))
        let finiteReader = try SaveReaderCursor(threadState: finiteThread)
        XCTAssertEqual(finiteReader.routines.last?.rawState, 4)
        XCTAssertEqual(finiteReader.routines.last?.waitTime, 65)
        XCTAssertEqual(finiteReader.routines.last?.skipTime, 100)
        let effectScope = try XCTUnwrap(finiteReader.routines.last?.scope.first)
        XCTAssertEqual(try effectScope.utf16Text(in: finiteThread), "eff")

        let nestedWaitProgram = try ScriptProgram(ScriptDocument(data: Data(
            "@@Root\n\\sub,@@Child\n\\cal,7\n\\clk\n@@Child\n\\wait,120\n\\ret\n".utf8),
            relativePath: "nested.s"))
        var nestedWait = try ScriptMachine(program: nestedWaitProgram, allowExperimental: true, entryLabel: "@@Root")
        try nestedWait.run()
        let nestedThread = try nestedWait.encodeTimedWaitThread(scriptPath: "nested.s",
            readerOpaqueFields: Data(repeating: 0, count: 64))
        let nestedReader = try SaveReaderCursor(threadState: nestedThread)
        XCTAssertEqual(nestedReader.routines.map(\.rawState), [0, 3])
        let returnBlock = try XCTUnwrap(nestedReader.routines.last?.controlBlocks.first)
        XCTAssertEqual(returnBlock.rawState, 1)
        XCTAssertEqual(returnBlock.rawValueAt38, 1)
        XCTAssertEqual(Int(returnBlock.rawValueAt3C), "\\sub,@@Child".utf16.count)
        XCTAssertEqual(try returnBlock.stringReferences[1].utf16Text(in: nestedThread), "Root")
        let crossProgram = try repository.load("waiting-caller.s")
        var crossWait = try ScriptMachine(program: crossProgram, allowExperimental: true,
            entryLabel: "@@Start", repository: repository)
        try crossWait.run()
        XCTAssertThrowsError(try crossWait.encodeTimedWaitThread(scriptPath: "waiting-caller.s",
            readerOpaqueFields: Data(repeating: 0, count: 64))) {
            XCTAssertEqual(String(describing: $0), "save_thread_live_reader_source_mismatch")
        }
        let crossThread = try crossWait.encodeTimedWaitThread(
            readerOpaqueFields: Data(repeating: 0, count: 64))
        let crossReader = try SaveReaderCursor(threadState: crossThread)
        XCTAssertEqual(try crossReader.scriptPath.utf16Text(in: crossThread), "waiting-child.s")
        let emptyBankTemplate = crossThread + Data(repeating: 0, count: 4 + 1 + 76 + 256 * 24)
            + Data("dsnd\0\0\0\0".utf8) + Data(repeating: 0, count: 4)
            + Data("ssnd\0\0\0\0".utf8) + Data(repeating: 0, count: 4)
        XCTAssertEqual(try crossWait.encodeTimedWaitStreams(template: emptyBankTemplate, positions: [:]), emptyBankTemplate)
        XCTAssertThrowsError(try crossWait.encodeTimedWaitStreams(template: emptyBankTemplate, positions: [0: 1250]))
        let generator = Data("vgene\0\0\0".utf8) + Data([3, 0, 0, 0]) + Data(repeating: 0, count: 44)
        var library = Data(repeating: 0, count: 0xA5E + 2 + 33 * 6 + 64 * 2 + 256)
        for _ in 0..<4 { library += generator }
        library += Data(repeating: 0, count: 2 + 8 * 6 + 2)
        var completeTemplate = emptyBankTemplate + library + library
        completeTemplate += Data(repeating: 0, count: 140 + 2 + 69 + 4 + 4 + 27 * 14 + 141)
        completeTemplate += Data("CalVal\0\0".utf8) + Data([1, 0, 0, 0]) + Data(repeating: 0, count: 8)
        completeTemplate += Data(repeating: 0, count: 419 + 14 + 69 + 69 + 4 + 68 + 4)
        completeTemplate += Data("imotwt".utf8) + Data(repeating: 0, count: 258 + 53)
        completeTemplate += Data([1, 0, 0, 0]) + Data(repeating: 0, count: 121)
        for _ in 0..<4 { completeTemplate += generator }
        completeTemplate += Data(repeating: 0, count: 4) + Data([1, 0, 0, 0])
        completeTemplate += Data(repeating: 0, count: 24 + 16)
        XCTAssertEqual(try crossWait.assembleTimedWaitResearchState(template: completeTemplate, positions: [:]),
                       completeTemplate)
        let aliasProgram = try repository.load("alias-wait.s")
        var aliasWait = try ScriptMachine(program: aliasProgram, allowExperimental: true,
                                          entryLabel: "@@Start", repository: repository)
        try aliasWait.run()
        let aliasState = try aliasWait.assembleTimedWaitResearchState(template: completeTemplate, positions: [:])
        let aliasReader = try SaveReaderCursor(threadState: aliasState)
        let aliasPrefix = try SaveStatePrefix(state: aliasState, after: aliasReader)
        let aliasArrays = try SaveVariableArrays.readCalVal(state: aliasState, at: aliasPrefix.locateCalVal(in: aliasState))
        var savedFrame: SaveVariableArrays?
        _ = try aliasArrays.summary(in: aliasState, at: try aliasPrefix.locateCalVal(in: aliasState)) { _, _, group in
            savedFrame = group
        }
        let savedFrameGroup = try XCTUnwrap(savedFrame)
        var restoredFrame = try ScriptStorage.stageSavedGlobalScalars(savedFrameGroup)
        _ = try restoredFrame.stageSavedSoundAliases(savedFrameGroup)
        XCTAssertEqual(try restoredFrame.read("voice"), try restoredFrame.readIndexed("snd", 3))
        var laterWait = crossWait
        try laterWait.advanceClickWait(ticks: 101)
        let assembled = try laterWait.assembleTimedWaitResearchState(template: completeTemplate, positions: [:])
        XCTAssertEqual(try SaveReaderCursor(threadState: assembled).routines.last?.waitTime, 19)
        // A donor with a shorter thread must not leave stale section offsets.
        let shortReader = try SaveReaderCursor.encodeRecord(relativeLine: 0, utf16Position: 0,
            replaceEnableByte: 0, opaqueFields: Data(repeating: 0, count: 64), lineBuffer: "",
            scriptPath: "waiting-child.s", label: "Child", textPrefix: "", emptyLineText: "")
        let shortThread = try SaveReaderCursor.encodeThread(routines: [], reader: shortReader)
        let shiftedTemplate = shortThread + completeTemplate.dropFirst(crossThread.count)
        XCTAssertLessThan(shiftedTemplate.count, completeTemplate.count)
        let shifted = try laterWait.assembleTimedWaitResearchState(template: shiftedTemplate, positions: [:])
        XCTAssertEqual(shifted, assembled)
        var surfaceTemplate = completeTemplate
        let displayOffset = emptyBankTemplate.count + 2 * library.count
        surfaceTemplate[displayOffset + 33] = 1
        surfaceTemplate[displayOffset + 34] = 1
        let originalPNG = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVR4nGP4DwABAQEAsTj2FAAAAABJRU5ErkJggg=="))
        let surfaceRecord = Data([5, 0]) + Data("a.png".utf16.flatMap { [UInt8($0), 0] })
            + withUnsafeBytes(of: Int32(originalPNG.count).littleEndian) { Data($0) } + originalPNG
        surfaceTemplate.insert(contentsOf: surfaceRecord + surfaceRecord, at: displayOffset + 142)
        let surfacePrefix = try SaveStatePrefix(state: surfaceTemplate, after: crossReader)
        let oldCalVal = try surfacePrefix.locateCalVal(in: surfaceTemplate)
        let largerSurface = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAIAAAB7QOjdAAAAD0lEQVR4nGP4z8DA8J8BAAf/Af8Bf4mnAAAAAElFTkSuQmCC"))
        let sizeChange = largerSurface.count - originalPNG.count
        let replacedSurface = try surfacePrefix.replacingDisplaySurface(in: surfaceTemplate, index: 0, payload: largerSurface)
        XCTAssertEqual(try surfacePrefix.displaySurfaceBytes(in: replacedSurface, index: 0), largerSurface)
        XCTAssertEqual(try surfacePrefix.locateCalVal(in: replacedSurface), oldCalVal + sizeChange)
        let assembledSurface = try laterWait.assembleTimedWaitResearchState(template: surfaceTemplate,
            positions: [:], displaySurfaces: [0: largerSurface, 1: largerSurface])
        let seed: UInt32 = 0x12345678
        let slotBytes = try laterWait.encodeTimedWaitResearchSlot(template: surfaceTemplate,
            positions: [:], displaySurfaces: [0: largerSurface, 1: largerSurface],
            metadata: Array(repeating: "", count: 8), thumbnail: Data(), savedDays: 45_000, seed: seed)
        let recoveredState = try SaveEnvelope.decodeSlotState(slotBytes, seed: seed)
        XCTAssertEqual(recoveredState, assembledSurface)
        let assembledReader = try SaveReaderCursor(threadState: recoveredState)
        let assembledPrefix = try SaveStatePrefix(state: recoveredState, after: assembledReader)
        XCTAssertEqual(assembledReader.routines.last?.waitTime, 19)
        let recoveredPNG = try assembledPrefix.displaySurfaceBytes(in: recoveredState, index: 0)
        XCTAssertEqual(recoveredPNG, largerSurface)
        XCTAssertEqual(try assembledPrefix.displaySurfaceBytes(in: recoveredState, index: 1), largerSurface)
        let recoveredImage = try ResourceImage.decode(recoveredPNG).image
        XCTAssertEqual(recoveredImage.width, 2)
        XCTAssertEqual(recoveredImage.height, 1)
        XCTAssertEqual(try assembledPrefix.locateCalVal(in: recoveredState), oldCalVal + 2 * sizeChange)
        XCTAssertEqual(try crossReader.textPrefix.utf16Text(in: crossThread), "prefix")
        XCTAssertEqual(try crossReader.emptyLineText.utf16Text(in: crossThread), "empty")
        XCTAssertEqual(crossReader.replaceEnableByte, 1)
        let crossRule = try XCTUnwrap(crossReader.replacements.first)
        XCTAssertEqual(try crossRule.firstText.utf16Text(in: crossThread), "^name")
        XCTAssertEqual(try crossRule.secondText.utf16Text(in: crossThread), "value")
        let crossBlock = try XCTUnwrap(crossReader.routines.last?.controlBlocks.first)
        let (_, returnIndex, returnProgram, _) = try SaveReaderCursor.routineReturnPosition(
            crossBlock, in: crossThread, repository: &repository)
        let resumedIndex = try XCTUnwrap(returnIndex)
        XCTAssertEqual(returnProgram.document.records[resumedIndex].location.sourceFile, "waiting-caller.s")
        XCTAssertEqual(returnProgram.document.records[resumedIndex + 1].command, "cal")
        let crossTarget = try crossReader.resolveLabel(in: crossThread, repository: &repository)
        let crossPosition = try crossTarget.program.sourcePosition(for: crossReader, anchor: crossTarget.location)
        let crossIndex = try crossTarget.program.savedResumeIndex(crossPosition, reader: crossReader)
        var crossStorage = ScriptStorage()
        try crossStorage.restoreReaderPrefixes(crossReader, in: crossThread)
        XCTAssertEqual(crossStorage.exceptTextPrefix, "prefix")
        XCTAssertEqual(crossStorage.noWordLineText, "empty")
        try crossStorage.restoreReaderReplacements(crossReader, in: crossThread)
        XCTAssertEqual(crossStorage.replacementRules[Data("^name".utf8)]?.value, "value")
        try ScriptMachine.stageSavedCall(callee: crossTarget.program, anchor: crossTarget.location,
            caller: returnProgram, returnIndex: resumedIndex, catalog: repository.catalog,
            locals: [:], storage: &crossStorage)
        let crossContinuation = try XCTUnwrap(ScriptMachine.probeSavedCalculations(
            program: crossTarget.program, index: crossIndex, storage: crossStorage, repository: repository,
            savedWait: crossReader.routines.last?.waitTime))
        XCTAssertEqual(crossContinuation.simulatedSavedWaitTicks, 120)
        XCTAssertTrue(crossContinuation.steps.contains { $0.action == "module_return" })
        XCTAssertEqual(crossContinuation.steps.first { $0.action == "calculate" }?.location.sourceFile,
                       "waiting-caller.s")
        XCTAssertEqual(crossContinuation.stopReason, "waiting_for_input_or_timer")
        let resumedTimer = try XCTUnwrap(ScriptMachine.probeSavedCalculations(
            program: timer, index: successor, storage: ScriptStorage(), savedWait: assembledReader.routines.last?.waitTime))
        XCTAssertEqual(resumedTimer.simulatedSavedWaitTicks, 19)
        XCTAssertEqual(resumedTimer.steps.first?.command, "cal")
        let callback = try ScriptProgram(ScriptDocument(data: Data(
            "@@Callback\n\\cal,2\n\\ret\n".utf8), relativePath: "callback.s"))
        var timerStorage = ScriptStorage()
        timerStorage.timers[1] = .init(callback: (callback, try callback.label("@@Callback"), "@@Callback"),
                                       enabled: true, elapsed: 4, interval: 10)
        let interrupted = try XCTUnwrap(ScriptMachine.probeSavedCalculations(
            program: timer, index: successor, storage: timerStorage, savedWait: 19))
        let calculations = interrupted.steps.filter { $0.command == "cal" }
        XCTAssertEqual(calculations.map(\.location.sourceFile), ["callback.s", "callback.s", "timer.s"])
        XCTAssertEqual(interrupted.simulatedSavedWaitTicks, 19)
        let waitingCallback = try ScriptProgram(ScriptDocument(data: Data(
            "@@Callback\n\\wait,7\n\\ret\n".utf8), relativePath: "waiting-callback.s"))
        timerStorage.timers[1]?.callback = (waitingCallback, try waitingCallback.label("@@Callback"), "@@Callback")
        let paused = try XCTUnwrap(ScriptMachine.probeSavedCalculations(
            program: timer, index: successor, storage: timerStorage, savedWait: 19))
        XCTAssertEqual(paused.simulatedSavedWaitTicks, 6)
        XCTAssertEqual(paused.waitRemaining, 7)

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

        let owned = try ScriptDocument(data: source, relativePath: "owned.s")
        let anchor = try XCTUnwrap(owned.records.first { $0.location.lineNumber == 1 }).location
        let instruction = try XCTUnwrap(owned.records.firstIndex { $0.command == "cal" })
        let fields = try ScriptProgram(owned).savedReaderFields(commandIndex: instruction, anchor: anchor)
        let reader = try SaveReaderCursor.encodeRecord(relativeLine: fields.line, utf16Position: fields.position,
            replaceEnableByte: 0, opaqueFields: Data(repeating: 0, count: 64),
            lineBuffer: fields.text, scriptPath: "owned.s", label: "Resume",
            textPrefix: "prefix", emptyLineText: "empty",
            replacements: [("雪", "测试", -7)])
        let serialized = try SaveReaderCursor.encodeThread(routines: [], reader: reader)
        let slot = try SaveEnvelope.encodeSlot(state: serialized, metadata: Array(repeating: "", count: 8),
                                               thumbnail: Data(), savedDays: 45_000.5, seed: 0)
        let state = try SaveEnvelope.decodeSlotState(slot, seed: 0)
        XCTAssertEqual(state, serialized)
        let cursor = try SaveReaderCursor(threadState: state)
        let replacement = try XCTUnwrap(cursor.replacements.first)
        XCTAssertEqual(cursor.replacementCount, 1)
        XCTAssertEqual(try replacement.firstText.utf16Text(in: state), "雪")
        XCTAssertEqual(try replacement.secondText.utf16Text(in: state), "测试")
        XCTAssertEqual(replacement.rawField, -7)
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

    func testTimerCallbackWaitDoesNotUseDeferredTimerDeadline() throws {
        let source = #"""
        \gvar,int,Observed
        \gvar,timer,Tick
        \scp,Tick
        \t,5
        \l,@@Tick
        \e
        \?t
        \cal,Observed=ResultInt[0]
        \wait,100
        @@Tick
        \wait,20
        \ret
        """#
        let program = try ScriptProgram(ScriptDocument(data: Data(source.utf8), relativePath: "timer.s"))
        var machine = try ScriptMachine(program: program, allowExperimental: true)
        try machine.run()
        XCTAssertEqual(try machine.value(named: "Observed"), .integer(5))
        XCTAssertEqual(machine.clickWaitRemaining, 100)
        XCTAssertEqual(machine.ticksUntilTimer, 5)
        try machine.advanceClickWait(ticks: 5)
        try machine.advancePlacementClock(ticks: 5)
        XCTAssertTrue(try machine.dispatchDueTimer())
        try machine.run()
        XCTAssertEqual(machine.clickWaitRemaining, 20)
        try machine.advancePlacementClock(ticks: 5)
        XCTAssertNil(machine.ticksUntilTimer)
        XCTAssertFalse(try machine.dispatchDueTimer())
        try machine.advanceClickWait(ticks: 20)
        try machine.run()
        XCTAssertEqual(machine.phase, .waiting)
        XCTAssertEqual(machine.clickWaitRemaining, 95)
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
        let jpeg = Data([0xff, 0xd8, 0xff, 0xd9])
        let withThumbnail = try SaveEnvelope.replacingSlotThumbnail(in: reencoded, with: jpeg)
        let updatedSlot = try XCTUnwrap(SaveEnvelope(withThumbnail).slot)
        XCTAssertTrue(updatedSlot.transformed)
        XCTAssertEqual(withThumbnail.suffix(17), reencoded.suffix(17))
        XCTAssertEqual(try SaveEnvelope.decodeSlotState(withThumbnail, seed: 0), output)
        XCTAssertEqual(Data(withThumbnail.dropFirst(updatedSlot.thumbnail.offset).prefix(updatedSlot.thumbnail.length)), jpeg)
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
        for size in [0, 1, 251, 252, 253, 507] {
            let original = Data((0..<size).map { UInt8(truncatingIfNeeded: $0) })
            XCTAssertEqual(try SaveRunLength.decode(SaveRunLength.encodeLiterals(original)), original)
        }
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
        let child = try SaveReaderCursor.ControlBlock.encode(rawState: 3, rawValueAt38: 0, rawValueAt3C: 0,
                                                            strings: Array(repeating: "", count: 10))
        XCTAssertEqual(child, Data([10, 0, 0, 0, 0, 0, 0, 0, 3]) + Data(repeating: 0, count: 24))
        nested.insert(contentsOf: child, at: cursor.decodedOffset)
        let snapshot = try SaveReaderCursor.Routine.encodeResultSnapshot(
            integers: [-2] + Array(repeating: 0, count: 15),
            strings: ["A"] + Array(repeating: "", count: 15),
            objects: ["B"] + Array(repeating: "", count: 15),
            button: "", buttonInts: [11, 0, 0, 0], buttonStrings: ["C", "", "", ""],
            click: 7, stop: -3, subInts: [13, 0, 0, 0], subStrings: ["D", "", "", ""])
        XCTAssertEqual(snapshot, Data(state[snapshotStart..<(cursor.decodedOffset - 4)]))
        let encodedRoutine = try SaveReaderCursor.Routine.encode(scope: Array(repeating: "", count: 16),
            rawState: 0, waitTime: 0, skipTime: 0, channel: 0, jumpLabel: "", eventLabel: "", eventName: "",
            resultSnapshot: snapshot, controlBlocks: [child])
        let reader = Data(state.suffix(from: cursor.decodedOffset))
        let encodedThread = try SaveReaderCursor.encodeThread(routines: [encodedRoutine], reader: reader)
        XCTAssertEqual(encodedThread, nested)
        XCTAssertThrowsError(try SaveReaderCursor.encodeThread(routines: [encodedRoutine], reader: reader + Data([0])))
        let nestedCursor = try SaveReaderCursor(threadState: encodedThread)
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
        XCTAssertEqual(try storage.encodeRoutineResultSnapshot(
            objectNames: ["B"] + Array(repeating: "", count: 15), buttonName: ""), snapshot)
        try storage.declare("B", category: "gvar", type: "list")
        storage.global[Data("resultobj".utf8)] = storage.global[Data("b".utf8)]
        XCTAssertEqual(try storage.encodeRoutineResultSnapshot(buttonName: ""),
            try storage.encodeRoutineResultSnapshot(objectNames: ["b"] + Array(repeating: "", count: 15), buttonName: ""))
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
        var liveStrings = strings
        try liveStrings.write("x", .string("长字符串"))
        let rebuilt = try SaveVariableArrays.encodeCalValValues(template: stringCalVal, storage: liveStrings)
        let restoredStrings = try ScriptStorage.stageSavedGlobalScalars(SaveVariableArrays.readCalVal(state: rebuilt, at: 0))
        XCTAssertEqual(try restoredStrings.read("x"), .string("长字符串"))
        var twoRecords = calVal
        let dimensionOffset = twoRecords.count - 24
        twoRecords.replaceSubrange(dimensionOffset..<(dimensionOffset + 16),
            with: Array(repeating: [UInt8(1), 0, 0, 0], count: 4).flatMap { $0 })
        twoRecords[16] = 2
        let stringRecord = stringCalVal.dropFirst(20)
        var renamedStringRecord = Data(stringRecord)
        renamedStringRecord[20] = 0x79
        twoRecords.append(renamedStringRecord)
        var liveArrays = try ScriptStorage.stageSavedGlobalScalars(SaveVariableArrays.readCalVal(state: twoRecords, at: 0))
        try liveArrays.setConfigResultArray([.integer(-3), .integer(42)], string: false)
        liveArrays.global[Data("x".utf8)] = liveArrays.global.removeValue(forKey: Data("resultint".utf8))
        try liveArrays.write("y", .string("雪"))
        let rebuiltArrays = try SaveVariableArrays.encodeCalValValues(template: twoRecords, storage: liveArrays)
        let decodedArrays = try SaveVariableArrays.readCalVal(state: rebuiltArrays, at: 0)
        XCTAssertEqual(decodedArrays.nextDecodedOffset, rebuiltArrays.count)
        XCTAssertEqual(rebuiltArrays[dimensionOffset], 2)
        let restoredArrays = try ScriptStorage.stageSavedGlobalScalars(decodedArrays)
        XCTAssertEqual(try restoredArrays.readIndexed("x", 0), .integer(-3))
        XCTAssertEqual(try restoredArrays.readIndexed("x", 1), .integer(42))
        XCTAssertEqual(try restoredArrays.read("y"), .string("雪"))
        let liveProgram = try ScriptProgram(ScriptDocument(data: Data(
            "@@Start\n\\gvar,int,x\n\\cal,x=87\n\\wait,120\n\\cal,1/(x==87)\n\\clk\n".utf8),
            relativePath: "live-globals.s"))
        var liveMachine = try ScriptMachine(program: liveProgram, allowExperimental: true, entryLabel: "@@Start")
        try liveMachine.run()
        try liveMachine.advanceClickWait(ticks: 101)
        let emptyCalVal = Data(calVal.prefix(16)) + Data(repeating: 0, count: 4)
        let generated = try liveMachine.encodeTimedWaitGlobals(template: emptyCalVal)
        let generatedArrays = try SaveVariableArrays.readCalVal(state: generated, at: 0)
        let generatedRecord = try XCTUnwrap(generatedArrays.records.first)
        XCTAssertEqual(generatedRecord.header.prefix(12), Data([0, 0, 0, 0, 255, 0, 0, 0, 240, 0, 0, 0]))
        XCTAssertEqual(try ScriptStorage.stageSavedGlobalScalars(generatedArrays).read("x"), .integer(87))
        let liveThread = try liveMachine.encodeTimedWaitThread(readerOpaqueFields: Data(repeating: 0, count: 64))
        let liveCalVal = try liveMachine.encodeTimedWaitGlobals(template: calVal)
        let liveSlot = try SaveEnvelope.encodeSlot(state: liveThread + liveCalVal,
            metadata: Array(repeating: "", count: 8), thumbnail: Data(), savedDays: 45_000.5)
        let liveState = try SaveEnvelope.decodeSlotState(liveSlot)
        let liveCursor = try SaveReaderCursor(threadState: liveState)
        let liveGlobals = try ScriptStorage.stageSavedGlobalScalars(
            SaveVariableArrays.readCalVal(state: liveState, at: liveCursor.nextDecodedOffset))
        XCTAssertEqual(try liveGlobals.read("x"), .integer(87))
        let liveAnchor = liveProgram.document.records[try liveProgram.label("@@Start")].location
        let livePosition = try liveCursor.resolveSourcePosition(anchor: liveAnchor, source: liveProgram.document.source)
        let liveIndex = try liveProgram.savedResumeIndex(livePosition, reader: liveCursor)
        let liveContinuation = try XCTUnwrap(ScriptMachine.probeSavedCalculations(
            program: liveProgram, index: liveIndex, storage: liveGlobals, savedWait: liveCursor.routines.first?.waitTime))
        XCTAssertEqual(liveContinuation.simulatedSavedWaitTicks, 19)
        XCTAssertTrue(liveContinuation.steps.contains { $0.action == "calculate" })
        XCTAssertEqual(liveContinuation.stopReason, "waiting_for_input_or_timer")
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

        var frame = ScriptFrame(returnIndex: nil)
        frame.locals = strings.global
        let localTemplate = Data("ValIdx\0\0".utf8) + Data([0, 0, 0, 0, 1, 0, 0, 0])
            + stringCalVal.dropFirst(16)
        let encodedLocals = try SaveVariableArrays.encodeIndexedLocals(in: localTemplate, at: 0, frames: [frame])
        XCTAssertEqual(encodedLocals.end, localTemplate.count)
        let localValues = try ScriptStorage.stageSavedGlobalScalars(
            SaveVariableArrays(state: encodedLocals.bytes, decodedOffset: 16))
        XCTAssertEqual(try localValues.read("x"), .string("雪"))
        let generatedLocals = try SaveVariableArrays.encodeIndexedLocals(in: Data("tail".utf8), at: 0, frames: [frame])
        XCTAssertEqual(generatedLocals.end, 0)
        let generatedValues = try ScriptStorage.stageSavedGlobalScalars(
            SaveVariableArrays(state: generatedLocals.bytes, decodedOffset: 16))
        XCTAssertEqual(try generatedValues.read("x"), .string("雪"))
        var unsupportedFrame = ScriptFrame(returnIndex: nil)
        unsupportedFrame.locals[Data("obj".utf8)] = ScriptBinding(elements: [.object(1)])
        XCTAssertThrowsError(try SaveVariableArrays.encodeIndexedLocals(in: Data("tail".utf8), at: 0, frames: [unsupportedFrame]))
        XCTAssertThrowsError(try SaveVariableArrays.encodeIndexedLocals(in: localTemplate, at: 0,
                                                                        frames: [ScriptFrame(returnIndex: nil)]))

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
        var inlineList = listObject
        inlineList.replaceSubrange(22..<24, with: [1, 0, 0x6c, 0])
        let listTemplate = Data("CalVal\0\0".utf8) + Data([1, 0, 0, 0, 0, 0, 0, 0]) + inlineList
        var inlineListStorage = ScriptStorage()
        _ = try inlineListStorage.stageSavedGlobalTextObjects(SaveVariableArrays.readCalVal(state: listTemplate, at: 0))
        guard case .object(let listHandle) = try inlineListStorage.read("l") else {
            return XCTFail("Expected a restored list")
        }
        let listSource = try ScriptSource(data: Data("test".utf8), relativePath: "list.txt")
        try inlineListStorage.lists[listHandle]?.append("雪", at: listSource.location(0..<4, line: 1))
        let rebuiltList = try SaveVariableArrays.encodeCalValValues(template: listTemplate, storage: inlineListStorage)
        let generatedList = try SaveVariableArrays.encodeCalValValues(
            template: Data(listTemplate.prefix(16)) + Data(repeating: 0, count: 4),
            storage: inlineListStorage, newBindingKeys: [Data("l".utf8)])
        var generatedListStorage = ScriptStorage()
        _ = try generatedListStorage.stageSavedGlobalTextObjects(SaveVariableArrays.readCalVal(state: generatedList, at: 0))
        guard case .object(let generatedListHandle) = try generatedListStorage.read("l") else {
            return XCTFail("Expected a generated list")
        }
        XCTAssertEqual(generatedListStorage.lists[generatedListHandle]?.rawLines, ["A", "雪"])
        let rebuiltListRecord = try XCTUnwrap(SaveVariableArrays.readCalVal(state: rebuiltList, at: 0).records.first)
        guard case .objectText(let rebuiltElements) = rebuiltListRecord.values else {
            return XCTFail("Expected an encoded list")
        }
        XCTAssertEqual(rebuiltElements.first?.payload?.lines, ["A", "雪"])
        var timerObject = Data(listObject.dropLast(20))
        timerObject.replaceSubrange(24..<34, with: [5, 0, 116, 0, 105, 0, 109, 0, 101, 0, 114, 0])
        let timerOffset = timerObject.count
        timerObject += Data("objd".utf8) + Data([1, 0, 0, 0, 0, 0, 0, 0])
        let fixedTimerOffset = timerObject.count
        var fixedTimer = Data(repeating: 0, count: 89)
        fixedTimer[0] = 10
        fixedTimer[4] = 25
        fixedTimer[8] = 7
        fixedTimer[12] = 1
        fixedTimer[13] = 0xFF
        fixedTimer[21] = 1
        timerObject += fixedTimer
        timerObject += Data([1, 0, 65, 0, 0, 0])
        XCTAssertThrowsError(try SaveVariableArrays(state: Data(timerObject.dropLast()), decodedOffset: 0))
        let nextTimerOffset = timerObject.count
        timerObject[0] = 2
        timerObject += listObject.dropFirst(4)
        let timerArray = try SaveVariableArrays(state: timerObject, decodedOffset: 0)
        let timerSummary = try timerArray.summary(in: timerObject, at: 0)
        let timerPayload = try XCTUnwrap(timerSummary.timerPayloads.first)
        XCTAssertEqual(timerPayload.decodedOffset, timerOffset)
        XCTAssertEqual(timerPayload.fixedRecord.decodedOffset, fixedTimerOffset)
        XCTAssertEqual(timerPayload.interval, 25)
        XCTAssertEqual(timerPayload.elapsed, 7)
        XCTAssertEqual(timerPayload.enabledByte, 1)
        XCTAssertEqual(timerPayload.updateMask, 0xFF)
        XCTAssertEqual(timerPayload.rawUpdateMode, 1)
        XCTAssertEqual(timerPayload.callbackStrings.map(\.decodedOffset), [fixedTimerOffset + 91, fixedTimerOffset + 95])
        XCTAssertEqual(try timerPayload.callbackStrings.map { try $0.utf16Text(in: timerObject) }, ["A", ""])
        XCTAssertEqual(timerPayload.nextDecodedOffset, nextTimerOffset)
        XCTAssertEqual(timerArray.records[1].decodedOffset, nextTimerOffset)
        XCTAssertEqual(timerArray.nextDecodedOffset, timerObject.count)
        var inactiveTimer = Data(timerObject.prefix(nextTimerOffset))
        inactiveTimer[0] = 1
        for offset in [8, 12, 13, 21] { inactiveTimer[fixedTimerOffset + offset] = 0 }
        inactiveTimer.replaceSubrange((fixedTimerOffset + 89)..<nextTimerOffset, with: [0, 0, 0, 0])
        inactiveTimer.replaceSubrange(22..<24, with: [1, 0, 84, 0])
        let inactiveArrays = try SaveVariableArrays(state: inactiveTimer, decodedOffset: 0)
        var timerStorage = ScriptStorage()
        XCTAssertEqual(try timerStorage.stageSavedInactiveTimers(inactiveArrays), 1)
        XCTAssertEqual(timerStorage.timers.values.first?.interval, 25)
        XCTAssertEqual(timerStorage.timers.values.first?.enabled, false)
        let timerHandle = try XCTUnwrap(timerStorage.timers.keys.first)
        timerStorage.timers[timerHandle]?.interval = 87
        let timerTemplate = Data("CalVal\0\0".utf8) + Data([1, 0, 0, 0, 0, 0, 0, 0]) + inactiveTimer
        let encodedTimer = try SaveVariableArrays.encodeCalValValues(template: timerTemplate, storage: timerStorage)
        var restoredTimer = ScriptStorage()
        XCTAssertEqual(try restoredTimer.stageSavedInactiveTimers(
            SaveVariableArrays.readCalVal(state: encodedTimer, at: 0)), 1)
        XCTAssertEqual(restoredTimer.timers.values.first?.interval, 87)
        timerStorage.timers[timerHandle]?.enabled = true
        XCTAssertThrowsError(try SaveVariableArrays.encodeCalValValues(template: timerTemplate, storage: timerStorage))
        let activeTimerTemplate = Data("CalVal\0\0".utf8) + Data([1, 0, 0, 0, 0, 0, 0, 0]) + timerObject
        XCTAssertThrowsError(try SaveVariableArrays.encodeCalValValues(template: activeTimerTemplate,
                                                                      storage: timerStorage)) {
            XCTAssertEqual(String(describing: $0), "save_global_object_write_outside_profile")
        }
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
        XCTAssertEqual(button.userIntegerWords, [Int32](repeating: 0, count: 8))
        XCTAssertEqual(button.userIntegerReferences.count, 8)
        let buttonJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(button)) as? [String: Any])
        XCTAssertNil(buttonJSON["userIntegerWords"])
        XCTAssertNotNil(buttonJSON["userIntegerReferences"])
        XCTAssertNil(button.rawCheckByte) // Version zero is outside the v10 candidate.
        XCTAssertNil(button.rawLockByte)
        XCTAssertEqual(button.nextDecodedOffset, buttonObject.count)
        XCTAssertThrowsError(try SaveVariableArrays(state: Data(buttonObject.dropLast()), decodedOffset: 0))
        var messageObject = Data(buttonObject.prefix(buttonOffset))
        messageObject.replaceSubrange(24..<34, with: [3, 0, 109, 0, 115, 0, 103, 0])
        messageObject.replaceSubrange(22..<24, with: [1, 0, 109, 0])
        messageObject[fixedOffset + 0x44] = 1
        let messageArrays = try SaveVariableArrays(state: messageObject, decodedOffset: 0)
        let message = try XCTUnwrap(messageArrays.summary(in: messageObject, at: 0).messagePayloads.first)
        XCTAssertEqual(message.drawableRectangle, [1, 2, 31, 42])
        XCTAssertEqual(try message.imageSource?.utf16Text(in: messageObject), "A")
        XCTAssertEqual(message.rawTextCursor, 1)
        XCTAssertEqual(message.textStrings.count, 5)
        XCTAssertEqual(try message.textStrings[0].utf16Text(in: messageObject), "A")
        let plain = try message.primaryText(in: messageObject)
        XCTAssertEqual(plain.displayed, "A")
        XCTAssertEqual(plain.pending, "")
        XCTAssertEqual(message.nextDecodedOffset, messageObject.count)
        let rewrittenMessage = try SaveVariableArrays.replacingMessagePrimaryCandidate(in: messageObject,
            decodedOffset: 0, recordIndex: 0, elementIndex: 0, displayed: "你好[s,24,24]字", pending: "[rb,花,はな]")
        let rewrittenArrays = try SaveVariableArrays(state: rewrittenMessage, decodedOffset: 0)
        let rewrittenPayload = try XCTUnwrap(rewrittenArrays.summary(in: rewrittenMessage, at: 0).messagePayloads.first)
        let rewrittenText = try rewrittenPayload.primaryText(in: rewrittenMessage)
        XCTAssertEqual(rewrittenText.displayed, "你好[s,24,24]字")
        XCTAssertEqual(rewrittenText.pending, "[rb,花,はな]")
        XCTAssertEqual(rewrittenPayload.drawableRectangle, message.drawableRectangle)
        XCTAssertThrowsError(try SaveVariableArrays.replacingMessagePrimaryCandidate(in: messageObject,
            decodedOffset: 0, recordIndex: 0, elementIndex: 0, displayed: "[s,24", pending: ",24]"))
        var liveMessage = ScriptStorage.MessageObject()
        for text in ["你", "好[s,24,24]字"] {
            liveMessage.enqueueOutput(text, parsed: try ScriptStorage.MessageObject.parseOutput(text))
        }
        try liveMessage.commitOutput()
        let pendingText = "[rb,花,はな]"
        liveMessage.enqueueOutput(pendingText, parsed: try ScriptStorage.MessageObject.parseOutput(pendingText))
        let liveWritten = try SaveVariableArrays.replacingMessagePrimaryCandidate(in: messageObject,
            decodedOffset: 0, recordIndex: 0, elementIndex: 0, message: liveMessage)
        let livePayload = try XCTUnwrap(SaveVariableArrays(state: liveWritten, decodedOffset: 0)
            .summary(in: liveWritten, at: 0).messagePayloads.first)
        XCTAssertEqual(try livePayload.primaryText(in: liveWritten).displayed, "你好[s,24,24]字")
        XCTAssertEqual(try livePayload.primaryText(in: liveWritten).pending, pendingText)
        liveMessage.kinsokuWordLength = 3
        liveMessage.prohibitedLineStart = "、😀"
        liveMessage.prohibitedLineEnd = "（"
        liveMessage.ignoredReturnWords = "e\u{0301}"
        liveMessage.asEnabled = true
        liveMessage.textBounds = [-8, 3, 392, 203]
        liveMessage.textMargins = [5, 7]
        let layoutWritten = try SaveVariableArrays.replacingMessageLayoutCandidate(in: liveWritten,
            decodedOffset: 0, recordIndex: 0, elementIndex: 0, message: liveMessage)
        let layoutPayload = try XCTUnwrap(SaveVariableArrays(state: layoutWritten, decodedOffset: 0)
            .summary(in: layoutWritten, at: 0).messagePayloads.first)
        XCTAssertEqual(layoutPayload.rawKinsokuWordLength, 3)
        XCTAssertEqual(layoutPayload.rawAsEnabled, 1)
        XCTAssertEqual(layoutPayload.rawApEnabled, 0)
        XCTAssertEqual(layoutPayload.drawableRectangle, [-8, 3, 392, 203])
        XCTAssertEqual(layoutPayload.rawTextMargins, [5, 7])
        XCTAssertEqual(try layoutPayload.textStrings[2].utf16Text(in: layoutWritten), "、😀")
        XCTAssertEqual(try layoutPayload.textStrings[3].utf16Text(in: layoutWritten), "（")
        XCTAssertTrue(try layoutPayload.textStrings[4].utf16Text(in: layoutWritten).utf16.elementsEqual("e\u{0301}".utf16))
        XCTAssertEqual(try layoutPayload.primaryText(in: layoutWritten).pending, pendingText)
        liveMessage.textBounds = [0, 0, 4097, 100]
        XCTAssertThrowsError(try SaveVariableArrays.replacingMessageLayoutCandidate(in: messageObject,
            decodedOffset: 0, recordIndex: 0, elementIndex: 0, message: liveMessage))
        liveMessage.kinsokuWordLength = nil
        XCTAssertThrowsError(try SaveVariableArrays.replacingMessageLayoutCandidate(in: messageObject,
            decodedOffset: 0, recordIndex: 0, elementIndex: 0, message: liveMessage))
        liveMessage.pendingOutput.removeAll()
        XCTAssertThrowsError(try SaveVariableArrays.replacingMessagePrimaryCandidate(in: messageObject,
            decodedOffset: 0, recordIndex: 0, elementIndex: 0, message: liveMessage))
        XCTAssertThrowsError(try SaveVariableArrays(state: Data(messageObject.dropLast()), decodedOffset: 0))
        var surrogateMessage = messageObject
        surrogateMessage.replaceSubrange((fixedOffset + 189)..<(fixedOffset + 193),
                                         with: [2, 0, 0x3d, 0xd8, 0x00, 0xde])
        let surrogateArrays = try SaveVariableArrays(state: surrogateMessage, decodedOffset: 0)
        let surrogatePayload = try XCTUnwrap(surrogateArrays.summary(in: surrogateMessage, at: 0).messagePayloads.first)
        XCTAssertThrowsError(try surrogatePayload.primaryText(in: surrogateMessage))
        surrogateMessage[fixedOffset + 0x44] = 2
        let completeSurrogate = try SaveVariableArrays(state: surrogateMessage, decodedOffset: 0)
        let completePayload = try XCTUnwrap(completeSurrogate.summary(in: surrogateMessage, at: 0).messagePayloads.first)
        XCTAssertEqual(try completePayload.primaryText(in: surrogateMessage).displayed, "😀")
        var markupMessage = messageObject
        markupMessage[fixedOffset + 191] = UInt8(ascii: "[")
        let markupArrays = try SaveVariableArrays(state: markupMessage, decodedOffset: 0)
        let markupPayload = try XCTUnwrap(markupArrays.summary(in: markupMessage, at: 0).messagePayloads.first)
        XCTAssertThrowsError(try markupPayload.primaryText(in: markupMessage))
        var taggedMessage = messageObject
        let taggedText = "[s,24,24]A[rb,字,じ]"
        var taggedBytes = Data([UInt8(taggedText.utf16.count), 0])
        taggedBytes.append(try XCTUnwrap(taggedText.data(using: .utf16LittleEndian)))
        taggedMessage.replaceSubrange((fixedOffset + 189)..<(fixedOffset + 193), with: taggedBytes)
        taggedMessage[fixedOffset + 0x44] = UInt8("[s,24,24]A".utf16.count)
        let taggedArrays = try SaveVariableArrays(state: taggedMessage, decodedOffset: 0)
        let taggedPayload = try XCTUnwrap(taggedArrays.summary(in: taggedMessage, at: 0).messagePayloads.first)
        let tagged = try taggedPayload.primaryText(in: taggedMessage)
        XCTAssertEqual(tagged.displayedOutput.count, 2)
        guard case .ruby(let base, let reading) = try XCTUnwrap(tagged.pendingOutput.first) else {
            return XCTFail("expected pending ruby")
        }
        XCTAssertEqual(base, "字")
        XCTAssertEqual(reading, "じ")
        taggedMessage[fixedOffset + 0x44] = 2
        let splitArrays = try SaveVariableArrays(state: taggedMessage, decodedOffset: 0)
        let splitPayload = try XCTUnwrap(splitArrays.summary(in: taggedMessage, at: 0).messagePayloads.first)
        XCTAssertThrowsError(try splitPayload.primaryText(in: taggedMessage))
        var previewMessage = taggedMessage
        previewMessage[fixedOffset + 0x44] = UInt8("[s,24,24]A".utf16.count)
        previewMessage[fixedOffset + 0x8c] = 3
        previewMessage[fixedOffset + 0x9a] = 1
        previewMessage[fixedOffset + 0x9b] = 1
        for (reference, value) in zip(taggedPayload.textStrings[2...4], ["、", "（", "除"]).reversed() {
            let bytes = try XCTUnwrap(value.data(using: .utf16LittleEndian))
            var field = Data([UInt8(value.utf16.count), 0]); field.append(bytes)
            previewMessage.replaceSubrange((reference.decodedOffset - 2)..<(reference.decodedOffset + reference.length), with: field)
        }
        previewMessage[libraryOffset + 0x9f9] = 1
        for offset in [0x959, 0x965, 0x971] { previewMessage[libraryOffset + offset] = 100 }
        let previewArrays = try SaveVariableArrays(state: previewMessage, decodedOffset: 0)
        let previewPayload = try XCTUnwrap(previewArrays.summary(in: previewMessage, at: 0).messagePayloads.first)
        let previewSource = ScriptLocation(sourceFile: "preview.png", sourceSHA256: String(repeating: "0", count: 64),
            byteOffset: 0, byteLength: 1, rangeSHA256: String(repeating: "0", count: 64), lineNumber: 1)
        let previewResource = ScriptStorage.SavedImageResource(location: previewSource, width: 1, height: 1,
            memberCount: 1, hasExtendedContainerMetadata: false)
        var previewStorage = ScriptStorage()
        XCTAssertEqual(try previewStorage.stageSavedMessagePreviews(previewArrays, state: previewMessage,
            resources: [previewPayload.decodedOffset: previewResource]), 1)
        let preview = try XCTUnwrap(previewStorage.messages.values.first)
        XCTAssertTrue(preview.enabled)
        XCTAssertEqual(preview.textBounds, [1, 2, 31, 42])
        XCTAssertEqual(preview.prohibitedLineStart, "、")
        XCTAssertEqual(preview.prohibitedLineEnd, "（")
        XCTAssertEqual(preview.ignoredReturnWords, "除")
        XCTAssertEqual(preview.kinsokuWordLength, 3)
        XCTAssertTrue(preview.asEnabled)
        XCTAssertTrue(preview.apEnabled)
        XCTAssertEqual(preview.committedOutput.count, 2)
        XCTAssertEqual(preview.pendingOutput.count, 1)
        XCTAssertEqual(preview.background, previewSource)
        var rejectedPreview = ScriptStorage()
        XCTAssertThrowsError(try rejectedPreview.stageSavedMessagePreviews(previewArrays, state: previewMessage, resources: [:]))
        XCTAssertTrue(rejectedPreview.messages.isEmpty)
        var movingMessage = previewMessage
        movingMessage[libraryOffset + 0x804] = 1
        movingMessage[libraryOffset + 0x80c] = 100
        movingMessage[libraryOffset + 0x894] = 30
        let movingArrays = try SaveVariableArrays(state: movingMessage, decodedOffset: 0)
        let movingPayload = try XCTUnwrap(movingArrays.summary(in: movingMessage, at: 0).messagePayloads.first)
        let movingResource = ScriptStorage.SavedImageResource(location: previewSource, width: 1, height: 1,
            memberCount: 1, hasExtendedContainerMetadata: true, motionCount: 2)
        var movingPreview = ScriptStorage()
        XCTAssertEqual(try movingPreview.stageSavedMessagePreviews(movingArrays, state: movingMessage,
            resources: [movingPayload.decodedOffset: movingResource]), 1)
        let movingMessagePreview = try XCTUnwrap(movingPreview.messages.values.first)
        XCTAssertEqual(movingMessagePreview.backgroundSelectedMember, 1)
        XCTAssertEqual(movingMessagePreview.backgroundMotionStartTick, -30)
        movingMessage[libraryOffset + 0x810] = 1
        let unresolvedMotion = try SaveVariableArrays(state: movingMessage, decodedOffset: 0)
        var rejectedMotion = ScriptStorage()
        XCTAssertThrowsError(try rejectedMotion.stageSavedMessagePreviews(unresolvedMotion, state: movingMessage,
            resources: [movingPayload.decodedOffset: movingResource]))
        XCTAssertTrue(rejectedMotion.messages.isEmpty)
        movingMessage[libraryOffset + 0x810] = 0
        let textureOffset = libraryOffset + 0xa5e + 4
        movingMessage.replaceSubrange(textureOffset..<(textureOffset + 6), with: [1, 0, 84, 0, 0, 0, 0, 0])
        let texturedArrays = try SaveVariableArrays(state: movingMessage, decodedOffset: 0)
        let texturedPayload = try XCTUnwrap(texturedArrays.summary(in: movingMessage, at: 0).messagePayloads.first)
        var texturedResource = movingResource
        texturedResource.boundTextures = [0: previewSource]
        var texturedPreview = ScriptStorage()
        XCTAssertEqual(try texturedPreview.stageSavedMessagePreviews(texturedArrays, state: movingMessage,
            resources: [texturedPayload.decodedOffset: texturedResource]), 1)
        XCTAssertEqual(texturedPreview.messages.values.first?.backgroundBoundImages[0], previewSource)
        var baseButton = buttonObject
        baseButton.replaceSubrange(24..<34, with: [3, 0, 98, 0, 116, 0, 110, 0])
        baseButton.replaceSubrange(22..<24, with: [1, 0, 98, 0])
        let baseButtonArrays = try SaveVariableArrays(state: baseButton, decodedOffset: 0)
        XCTAssertEqual(try baseButtonArrays.summary(in: baseButton, at: 0).buttonPayloads.count, 1)
        var baseButtonStorage = ScriptStorage()
        XCTAssertEqual(try baseButtonStorage.stageSavedGlobalButtonIdentities(baseButtonArrays), 1)
        guard case .object(let baseButtonHandle) = try baseButtonStorage.read("b") else { return XCTFail("expected button") }
        XCTAssertEqual(baseButtonStorage.visualObjectTypes[baseButtonHandle], "btn")
        XCTAssertFalse(baseButtonStorage.buttonIsKnownUnlocked(baseButtonHandle))
        XCTAssertThrowsError(try baseButtonStorage.requireKnownSavedButtonStatesForAdoption()) {
            XCTAssertEqual(String(describing: $0), "saved_button_state_unverified")
        }
        for (command, issue) in [("?lk", "saved_button_lock_unverified"), ("?ck", "saved_button_check_unverified")] {
            let source = Data("\\scp,b[0]\n\\\(command)\n".utf8)
            let program = try ScriptProgram(ScriptDocument(data: source, relativePath: "unknown-button-state.s"))
            var machine = try XCTUnwrap(ScriptMachine.makeSavedExecutionMachine(program: program, index: 0,
                storage: baseButtonStorage, repository: nil, wait: nil, maximumSteps: 100,
                retainFullTrace: false, imageLoader: nil, imageMemberLookup: nil,
                imageExtendedValues: nil, imageMotionNames: nil))
            try machine.run()
            XCTAssertEqual(machine.phase, .stopped)
            XCTAssertEqual(machine.stopReason, issue)
        }
        let resetSource = Data("\\gvar,int,LockValue,CheckValue\n\\scp,b[0]\n\\lk,0\n\\?lk\n\\cal,LockValue=ResultInt[0]\n\\ck,0\n\\?ck\n\\cal,CheckValue=ResultInt[0]\n\\wait,1\n".utf8)
        let resetProgram = try ScriptProgram(ScriptDocument(data: resetSource, relativePath: "reset-button-state.s"))
        var resetMachine = try XCTUnwrap(ScriptMachine.makeSavedExecutionMachine(program: resetProgram, index: 0,
            storage: baseButtonStorage, repository: nil, wait: nil, maximumSteps: 100,
            retainFullTrace: false, imageLoader: nil, imageMemberLookup: nil,
            imageExtendedValues: nil, imageMotionNames: nil))
        try resetMachine.run()
        XCTAssertEqual(resetMachine.phase, .waiting)
        XCTAssertEqual(try resetMachine.value(named: "LockValue"), .integer(0))
        XCTAssertEqual(try resetMachine.value(named: "CheckValue"), .integer(0))

        var baseImage = Data(buttonObject.prefix(fixedOffset))
        baseImage.replaceSubrange(24..<34, with: [3, 0, 105, 0, 109, 0, 103, 0])
        baseImage.replaceSubrange(22..<24, with: [1, 0, 105, 0])
        let baseImageArrays = try SaveVariableArrays(state: baseImage, decodedOffset: 0)
        XCTAssertEqual(try baseImageArrays.summary(in: baseImage, at: 0).imagePayloads.count, 1)
        let basePayload = try XCTUnwrap(baseImageArrays.summary(in: baseImage, at: 0).imagePayloads.first)
        var timedImage = baseImage
        let imageFixed = basePayload.fixedRecord.decodedOffset
        timedImage.replaceSubrange((imageFixed + 4)..<(imageFixed + 0x804), with: Data(repeating: 0, count: 0x800))
        timedImage[imageFixed + 4] = 7
        timedImage[imageFixed + 0x400] = 1 // Last time word.
        timedImage[imageFixed + 0x404] = 0xff
        timedImage[imageFixed + 0x800] = 2 // Last auxiliary word.
        let timing = try XCTUnwrap(SaveVariableArrays(state: timedImage, decodedOffset: 0)
            .summary(in: timedImage, at: 0).imagePayloads.first?.layerTiming)
        XCTAssertEqual(timing.savedTimeWords.decodedOffset, imageFixed + 4)
        XCTAssertEqual(timing.savedAuxiliaryWords.decodedOffset, imageFixed + 0x404)
        XCTAssertEqual(timing.savedTimeWords.length, 1024)
        XCTAssertEqual(timing.savedAuxiliaryWords.length, 1024)
        XCTAssertEqual(timing.nonzeroTimeCount, 2)
        XCTAssertEqual(timing.nonzeroAuxiliaryCount, 2)
        XCTAssertEqual(timing.restoreStatus, .unsupported)
        XCTAssertEqual(timing.timeWords.count, 256)
        XCTAssertEqual(timing.auxiliaryWords.count, 256)
        XCTAssertEqual(timing.timeWords[0], 7)
        XCTAssertEqual(timing.timeWords[255], 1)
        XCTAssertEqual(timing.auxiliaryWords[0], 255)
        XCTAssertEqual(timing.auxiliaryWords[255], 2)
        let timingJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(timing)) as? [String: Any])
        XCTAssertNil(timingJSON["timeWords"])
        XCTAssertNil(timingJSON["auxiliaryWords"])
        XCTAssertEqual(timing.savedTimeWords.sha256, Data(timedImage[(imageFixed + 4)..<(imageFixed + 0x404)]).sha256Hex)
        XCTAssertEqual(timing.savedAuxiliaryWords.sha256, Data(timedImage[(imageFixed + 0x404)..<(imageFixed + 0x804)]).sha256Hex)
        let timingSource = Data("saved-layer-fixture".utf8)
        let timingLocation = ScriptLocation(sourceFile: "saved-layer.b", sourceSHA256: timingSource.sha256Hex,
            byteOffset: 0, byteLength: timingSource.count, rangeSHA256: timingSource.sha256Hex, lineNumber: 1)
        let timingRecipeJSON = """
        [{"container_sha256":"\(timingSource.sha256Hex)","offset":0,"length":\(timingSource.count),"sha256":"\(timingSource.sha256Hex)",
          "motion_timelines":{"0":[
            [{"time":0,"type":4,"offset":0},{"time":5,"type":4,"offset":1}],
            [{"time":0,"type":4,"offset":2},{"time":5,"type":4,"offset":3}]]}}]
        """
        let timingRecipe = try JSONDecoder().decode(ScriptImageRecipe.self, from: Data(timingRecipeJSON.utf8))
        let timingKeys = try XCTUnwrap(timingRecipe.motionKeysAtSavedLayerTimesCandidate(
            timingLocation, selectedMember: 0, layerTimes: timing.timeWords))
        XCTAssertEqual(timingKeys.map(\.offset), [1, 2])
        let positionedImage = try SaveVariableArrays.replacingImagePlacementCandidate(in: baseImage,
            decodedOffset: 0, recordIndex: 0, elementIndex: 0,
            placement: SIMD3(210, 92, 110), scale: SIMD3(80, 120, 100))
        let positionedPayload = try XCTUnwrap(SaveVariableArrays(state: positionedImage, decodedOffset: 0)
            .summary(in: positionedImage, at: 0).imagePayloads.first)
        XCTAssertEqual(positionedPayload.staticPlacement, SIMD3(210, 92, 110))
        XCTAssertEqual(positionedPayload.staticScale, SIMD3(80, 120, 100))
        XCTAssertThrowsError(try SaveVariableArrays.replacingImagePlacementCandidate(in: baseImage,
            decodedOffset: 0, recordIndex: 0, elementIndex: 0,
            placement: SIMD3(0, 0, 0), scale: SIMD3(100, 100, 99)))
        var baseImageStorage = ScriptStorage()
        XCTAssertEqual(try baseImageStorage.stageSavedGlobalImageIdentities(baseImageArrays), 1)
        guard case .object(let baseImageHandle) = try baseImageStorage.read("i") else { return XCTFail("expected image") }
        XCTAssertEqual(baseImageStorage.visualObjectTypes[baseImageHandle], "img")

        var integerImage = baseImage
        XCTAssertEqual(basePayload.userIntegerReferences.count, 8)
        for (reference, value): (SaveReaderCursor.Reference, Int32) in zip(basePayload.userIntegerReferences, [37, -12, 3, 9, 41, -42, 43, -44]) {
            integerImage.replaceSubrange(reference.decodedOffset..<(reference.decodedOffset + 4),
                with: withUnsafeBytes(of: value.littleEndian) { Data($0) })
        }
        let imageUserString = try XCTUnwrap(basePayload.userStrings.first)
        integerImage.replaceSubrange((imageUserString.decodedOffset - 2)..<(imageUserString.decodedOffset + imageUserString.length),
            with: Data([5, 0]) + (try XCTUnwrap("hello".data(using: .utf16LittleEndian))))
        let integerArrays = try SaveVariableArrays(state: integerImage, decodedOffset: 0)
        let integerPayload = try XCTUnwrap(integerArrays.summary(in: integerImage, at: 0).imagePayloads.first)
        XCTAssertEqual(Array(integerPayload.userIntegerWords.prefix(4)), [37, -12, 3, 9])
        let integerJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(integerPayload)) as? [String: Any])
        XCTAssertNil(integerJSON["userIntegerWords"])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(integerPayload), as: UTF8.self).contains("hello"))
        let rewrittenIntegerImage = try SaveVariableArrays.replacingImageUserIntegersCandidate(in: integerImage,
            decodedOffset: 0, recordIndex: 0, elementIndex: 0, values: [-2, 1024, 0, Int32.min])
        let rewrittenIntegerPayload = try XCTUnwrap(SaveVariableArrays(state: rewrittenIntegerImage, decodedOffset: 0)
            .summary(in: rewrittenIntegerImage, at: 0).imagePayloads.first)
        XCTAssertEqual(rewrittenIntegerPayload.userIntegerWords, [-2, 1024, 0, Int32.min, 41, -42, 43, -44])
        let writableOffsets = Set(integerPayload.userIntegerReferences.prefix(4).flatMap { $0.decodedOffset..<($0.decodedOffset + 4) })
        XCTAssertTrue(integerImage.indices.allSatisfy { writableOffsets.contains($0) || integerImage[$0] == rewrittenIntegerImage[$0] })
        XCTAssertThrowsError(try SaveVariableArrays.replacingImageUserIntegersCandidate(in: integerImage,
            decodedOffset: 0, recordIndex: 0, elementIndex: 0, values: [1]))
        var integerStorage = ScriptStorage()
        XCTAssertThrowsError(try integerStorage.stageSavedGlobalImageIdentities(integerArrays))
        XCTAssertEqual(try integerStorage.stageSavedGlobalImageIdentities(integerArrays, savedState: integerImage), 1)
        let integerSource = Data("\\gvar,int,A,B,C,D\n\\gvar,str,Before,After\n\\scp,i\n\\?ui\n\\cal,A=ResultInt[0]\n\\cal,B=ResultInt[1]\n\\ui,,42\n\\?ui\n\\cal,C=ResultInt[1]\n\\cal,D=ResultInt[3]\n\\?us\n\\cal,Before=ResultStr[0]\n\\us,\"new\"\n\\?us\n\\cal,After=ResultStr[0]\n\\wait,1\n".utf8)
        let integerProgram = try ScriptProgram(ScriptDocument(data: integerSource, relativePath: "saved-image-user-integers.s"))
        let integerIndex = try XCTUnwrap(integerProgram.document.records.firstIndex { $0.kind == .command })
        var integerMachine = try XCTUnwrap(ScriptMachine.makeSavedExecutionMachine(program: integerProgram,
            index: integerIndex, storage: integerStorage, repository: nil, wait: nil, maximumSteps: 100,
            retainFullTrace: false, imageLoader: nil, imageMemberLookup: nil,
            imageExtendedValues: nil, imageMotionNames: nil))
        try integerMachine.run()
        XCTAssertEqual(integerMachine.phase, .waiting)
        for (name, value): (String, Int32) in [("A", 37), ("B", -12), ("C", 42), ("D", 9)] {
            XCTAssertEqual(try integerMachine.value(named: name), .integer(value))
        }
        XCTAssertEqual(try integerMachine.value(named: "Before"), .string("hello"))
        XCTAssertEqual(try integerMachine.value(named: "After"), .string("new"))

        var fadingImage = Data(buttonObject.prefix(fixedOffset))
        fadingImage.replaceSubrange(24..<34, with: [4, 0, 115, 0, 105, 0, 109, 0, 103, 0])
        fadingImage.replaceSubrange(22..<24, with: [1, 0, 105, 0])
        let imageLibraryOffset = libraryOffset + 2 // One UTF-16 unit added for the variable name.
        for (offset, value): (Int, UInt8) in [(0x9c1, 0), (0x9c5, 200), (0x9c9, 25), (0x9cd, 100)] {
            fadingImage[imageLibraryOffset + offset] = value
        }
        fadingImage[imageLibraryOffset + 0x804] = 1
        fadingImage[imageLibraryOffset + 4] = 7
        fadingImage[imageLibraryOffset + 0x894] = 25
        fadingImage[imageLibraryOffset + 0x810] = 3
        fadingImage[imageLibraryOffset + 0x80c] = 50
        fadingImage[imageLibraryOffset + 0x9ed] = 100
        fadingImage[imageLibraryOffset + 0x915] = 42
        for offset in [0x959, 0x965, 0x971] { fadingImage[imageLibraryOffset + offset] = 100 }
        fadingImage[imageLibraryOffset + 0x9f9] = 1
        fadingImage[imageLibraryOffset + 0x9fa] = 0
        var imageStorage = ScriptStorage()
        let imageArrays = try SaveVariableArrays(state: fadingImage, decodedOffset: 0)
        let parsedImage = try XCTUnwrap(imageArrays.summary(in: fadingImage, at: 0).imagePayloads.first)
        XCTAssertEqual(parsedImage.fixedRecord.decodedOffset, imageLibraryOffset)
        XCTAssertEqual(parsedImage.opacityTransition?.remaining, 25)
        XCTAssertEqual(parsedImage.staticPlacement?.x, 42)
        XCTAssertEqual(parsedImage.rawActionIndex, 1)
        XCTAssertEqual(parsedImage.rawActionClockRemainder, 3)
        XCTAssertEqual(parsedImage.drawGate, 1)
        XCTAssertEqual(parsedImage.enableFlag, 0)
        let raster = ScriptLocation(sourceFile: "fixture.png", sourceSHA256: fadingImage.sha256Hex,
                                    byteOffset: 0, byteLength: fadingImage.count,
                                    rangeSHA256: fadingImage.sha256Hex, lineNumber: 1)
        XCTAssertEqual(try imageStorage.stageSavedGlobalImageIdentities(imageArrays,
            resources: [parsedImage.decodedOffset: .init(location: raster, width: 28, height: 25,
                memberCount: 2, hasExtendedContainerMetadata: true, motionCount: 2, motionUpdateThreshold: 8)]), 1)
        guard case .object(let imageHandle) = try imageStorage.readIndexed("i", 0) else {
            return XCTFail("Expected a restored image identity")
        }
        var image = try XCTUnwrap(imageStorage.images[imageHandle])
        XCTAssertEqual(image.resource, raster)
        XCTAssertEqual(image.width, 28)
        XCTAssertEqual(image.height, 25)
        XCTAssertEqual(image.memberCount, 2)
        XCTAssertEqual(image.selectedMember, 1)
        XCTAssertEqual(image.motionElapsedHundredths(at: 0), 2500)
        XCTAssertEqual(image.savedLayerTimeSnapshot?.times.first, 7)
        let savedPreviewProgram = try ScriptProgram(ScriptDocument(data: Data("\\wait,1\n".utf8), relativePath: "saved-preview.s"))
        let savedPreview = try XCTUnwrap(ScriptMachine.makeSavedExecutionMachine(program: savedPreviewProgram, index: 0,
            storage: imageStorage, repository: nil, wait: nil, maximumSteps: 100, retainFullTrace: false,
            imageLoader: nil, imageMemberLookup: nil, imageExtendedValues: nil, imageMotionNames: nil))
        XCTAssertEqual(savedPreview.staticImageLayers.first?.savedLayerTimeCandidate?.first, 7)
        var advancedPreview = savedPreview
        advancedPreview.advanceVisualClock(ticks: 1)
        XCTAssertNil(advancedPreview.staticImageLayers.first?.savedLayerTimeCandidate)
        var resumedPreview = savedPreview
        try resumedPreview.run()
        XCTAssertNil(resumedPreview.staticImageLayers.first?.savedLayerTimeCandidate)
        var frozenSample: Int32?
        let frozenContinuation = try XCTUnwrap(ScriptMachine.probeSavedCalculations(
            program: savedPreviewProgram, index: 0, storage: imageStorage,
            drawScene: { machine, pass in
                if case .frozenLayerScene = pass {
                    XCTAssertEqual(machine.executedSteps, 0)
                    frozenSample = machine.staticImageLayers.first?.savedLayerTimeCandidate?.first
                    return (.init(status: .unsupported, issue: "frozen_candidate"), nil)
                }
                return (.init(status: .inferred), nil)
            }, frozenLayerPreview: true, limit: 16))
        XCTAssertEqual(frozenSample, 7)
        XCTAssertEqual(frozenContinuation.frozenSceneDraw?.status, .unsupported)
        XCTAssertEqual(frozenContinuation.frozenSceneDraw?.issue, "frozen_candidate")
        var videoImage = fadingImage
        videoImage[imageLibraryOffset + 0x804] = 0
        videoImage[imageLibraryOffset + 0x810] = 0
        videoImage[imageLibraryOffset + 0x80c] = 100
        let videoArrays = try SaveVariableArrays(state: videoImage, decodedOffset: 0)
        let videoPayload = try XCTUnwrap(videoArrays.summary(in: videoImage, at: 0).imagePayloads.first)
        var videoStorage = ScriptStorage()
        XCTAssertEqual(try videoStorage.stageSavedGlobalImageIdentities(videoArrays,
            resources: [videoPayload.decodedOffset: .init(location: raster, width: 28, height: 25,
                memberCount: 1, hasExtendedContainerMetadata: false, isTheoraResource: true, motionCount: 1)]), 1)
        guard case .object(let videoHandle) = try videoStorage.readIndexed("i", 0) else {
            return XCTFail("Expected a restored video identity")
        }
        let video = try XCTUnwrap(videoStorage.images[videoHandle])
        XCTAssertTrue(video.isTheoraResource)
        XCTAssertNil(video.savedLayerTimeSnapshot)
        XCTAssertEqual(video.selectedMember, 0)
        XCTAssertEqual(video.motionElapsedHundredths(at: 0), 2500)
        XCTAssertEqual(video.motionElapsedHundredths(at: 10), 3500)
        var invalidVideo = videoImage
        invalidVideo[imageLibraryOffset + 0x810] = 1
        let invalidVideoArrays = try SaveVariableArrays(state: invalidVideo, decodedOffset: 0)
        var invalidVideoStorage = ScriptStorage()
        XCTAssertThrowsError(try invalidVideoStorage.stageSavedGlobalImageIdentities(invalidVideoArrays,
            resources: [videoPayload.decodedOffset: .init(location: raster, width: 28, height: 25,
                memberCount: 1, hasExtendedContainerMetadata: false, isTheoraResource: true, motionCount: 1)]))
        XCTAssertTrue(invalidVideoStorage.images.isEmpty)
        image.advanceRestoredMotion(ticks: 9)
        XCTAssertEqual(image.motionElapsedHundredths(at: 9), 2500)
        image.advanceRestoredMotion(ticks: 1)
        XCTAssertEqual(image.motionElapsedHundredths(at: 10), 3300)
        XCTAssertTrue(image.hasExtendedContainerMetadata)
        XCTAssertTrue(image.isDrawable)
        XCTAssertFalse(image.enabled)
        XCTAssertEqual(image.presentedOpacity, 150)
        image.advanceOpacity(ticks: 25)
        XCTAssertEqual(image.presentedOpacity, 200)
        XCTAssertNil(image.opacityEndpoint)
        var malformedFade = fadingImage
        malformedFade[imageLibraryOffset + 0x9c2] = 1
        let malformedArrays = try SaveVariableArrays(state: malformedFade, decodedOffset: 0)
        var rejectedStorage = ScriptStorage()
        XCTAssertThrowsError(try rejectedStorage.stageSavedGlobalImageIdentities(malformedArrays)) {
            XCTAssertEqual(String(describing: $0), "saved_drawable_image_opacity_unrestored:\(parsedImage.decodedOffset)")
        }
        XCTAssertTrue(rejectedStorage.images.isEmpty)
        var unmodeledTransform = fadingImage
        unmodeledTransform[imageLibraryOffset + 0x929] = 1
        let transformArrays = try SaveVariableArrays(state: unmodeledTransform, decodedOffset: 0)
        XCTAssertThrowsError(try rejectedStorage.stageSavedGlobalImageIdentities(transformArrays)) {
            XCTAssertEqual(String(describing: $0), "saved_drawable_image_scale_or_transform_unrestored:\(parsedImage.decodedOffset)")
        }
        XCTAssertTrue(rejectedStorage.images.isEmpty)
        var invalidPlacement = fadingImage
        invalidPlacement[imageLibraryOffset + 0x918] = 2
        let invalidPlacementArrays = try SaveVariableArrays(state: invalidPlacement, decodedOffset: 0)
        XCTAssertThrowsError(try rejectedStorage.stageSavedGlobalImageIdentities(invalidPlacementArrays)) {
            XCTAssertEqual(String(describing: $0), "saved_drawable_image_placement_unrestored:\(parsedImage.decodedOffset)")
        }
        XCTAssertTrue(rejectedStorage.images.isEmpty)
        var movingImage = fadingImage
        movingImage[imageLibraryOffset + 0x9ee] = 8 // Duration 2148; the final two ticks sample the destination.
        movingImage[imageLibraryOffset + 0x9e9] = 25
        movingImage[imageLibraryOffset + 0x909] = 11
        for offset in [0x955, 0x959, 0x961, 0x965, 0x96d, 0x971] {
            movingImage[imageLibraryOffset + offset] = 100
        }
        movingImage[imageLibraryOffset + 0x955] = 75
        movingImage[imageLibraryOffset + 0x959] = 125
        let moving = try SaveVariableArrays(state: movingImage, decodedOffset: 0)
        var movingStorage = ScriptStorage()
        XCTAssertEqual(try movingStorage.stageSavedGlobalImageIdentities(moving), 1)
        guard case .object(let movingHandle) = try movingStorage.readIndexed("i", 0) else {
            return XCTFail("Expected a moving image identity")
        }
        XCTAssertEqual(movingStorage.images[movingHandle]?.placement, [11, 0, 0])
        XCTAssertEqual(movingStorage.images[movingHandle]?.transform?.scale, [75, 100, 100])
        XCTAssertEqual(movingStorage.placementTransitions[movingHandle]?.destination, [42, 0, 0])
        XCTAssertEqual(movingStorage.placementTransitions[movingHandle]?.duration, 23)
        XCTAssertEqual(movingStorage.placementTransitions[movingHandle]?.savedMode, 0)
        movingImage[imageLibraryOffset + 0x9fd] = 1
        let linear = try SaveVariableArrays(state: movingImage, decodedOffset: 0)
        let sampled = try XCTUnwrap(linear.summary(in: movingImage, at: 0).imagePayloads.first?.activePlacement)
        XCTAssertEqual(sampled.mode, 1)
        XCTAssertEqual(try linear.summary(in: movingImage, at: 0).imagePayloads.first?.rawPlacementMode, 1)
        var restoredLinear = ScriptStorage()
        XCTAssertEqual(try restoredLinear.stageSavedGlobalImageIdentities(linear), 1)
        guard case .object(let linearHandle) = try restoredLinear.readIndexed("i", 0) else {
            return XCTFail("Expected a restored image identity")
        }
        XCTAssertEqual(restoredLinear.images[linearHandle]?.savedPlacementMode, 1)
        XCTAssertEqual(sampled.remaining, 25)
        XCTAssertEqual(sampled.duration, 2148)
        XCTAssertEqual(sampled.destinationScale.x, 125)
        let midpoint = ScriptStorage.PlacementTransition(destination: [42, 0, 0],
            duration: sampled.duration, elapsed: sampled.duration / 2, savedMode: sampled.mode)
        XCTAssertEqual(midpoint.sampleSavedLinearAxis(from: 75, to: sampled.destinationScale.x), 100)
        XCTAssertEqual(midpoint.sampleSavedLinearAxis(from: 10, to: 11), 10)
        XCTAssertEqual(midpoint.sampleLinearScale(from: 51, to: 100), 75.5)
        movingImage[imageLibraryOffset + 0x9ed] = 100
        movingImage[imageLibraryOffset + 0x9ee] = 0
        movingImage[imageLibraryOffset + 0x9e9] = 50
        movingImage[imageLibraryOffset + 0x955] = 51
        movingImage[imageLibraryOffset + 0x959] = 100
        let fractionalArrays = try SaveVariableArrays(state: movingImage, decodedOffset: 0)
        var fractionalStorage = ScriptStorage()
        XCTAssertEqual(try fractionalStorage.stageSavedGlobalImageIdentities(fractionalArrays,
            resources: [parsedImage.decodedOffset: .init(location: raster, width: 28, height: 25,
                memberCount: 1, hasExtendedContainerMetadata: false, motionCount: nil, motionUpdateThreshold: nil)]), 1)
        let resumeProgram = try ScriptProgram(ScriptDocument(data: Data("\\wait,1\n".utf8), relativePath: "resume.s"))
        let resumed = try XCTUnwrap(ScriptMachine.makeSavedExecutionMachine(program: resumeProgram, index: 0,
            storage: fractionalStorage, repository: nil, wait: 1, maximumSteps: 10, retainFullTrace: false,
            imageLoader: nil, imageMemberLookup: nil, imageExtendedValues: nil, imageMotionNames: nil))
        let resumedLayer = try XCTUnwrap(resumed.staticImageLayers.first)
        XCTAssertEqual(resumedLayer.fractionalScalePercent, SIMD2<Float>(75.5, 100))
        XCTAssertTrue(resumedLayer.unappliedTransform)
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
        let buttonArrays = try SaveVariableArrays(state: buttonObject, decodedOffset: 0)
        guard case .objectText(let buttonElements) = buttonArrays.records[0].values else {
            return XCTFail("Expected saved button records")
        }
        let userSlot = try XCTUnwrap(buttonElements.first?.buttonPayload?.userStrings.first)
        let buttonPayload = try XCTUnwrap(buttonElements.first?.buttonPayload)
        for (reference, value) in zip(buttonPayload.userIntegerReferences, [Int32(37), -12, 3, 9]) {
            buttonObject.replaceSubrange(reference.decodedOffset..<(reference.decodedOffset + 4),
                with: withUnsafeBytes(of: value.littleEndian) { Data($0) })
        }
        buttonObject[buttonPayload.imageLibraryOffset + 0x9fa] = 1
        buttonObject[buttonPayload.buttonRecordOffset] = 10
        buttonObject[buttonPayload.buttonRecordOffset + 8] = 2
        buttonObject[buttonPayload.buttonRecordOffset + 9] = 7
        let geometry: [(Int, Int32)] = [(0x915, 320), (0x919, 240), (0x91d, 8),
                                        (0x959, 80), (0x965, 90), (0x971, 100)]
        for (offset, value) in geometry {
            let start = buttonPayload.imageLibraryOffset + offset
            buttonObject.replaceSubrange(start..<(start + 4),
                with: withUnsafeBytes(of: value.littleEndian) { Data($0) })
        }
        let buttonResource = ScriptModuleReference(logicalPath: "button.png", sourceFile: "button.png",
            sourceSHA256: Data([1]).sha256Hex).wholeFileLocation(byteLength: 1)
        let hoverTexture = ScriptModuleReference(logicalPath: "hover.png", sourceFile: "hover.png",
            sourceSHA256: Data([2]).sha256Hex).wholeFileLocation(byteLength: 1)
        let label = "@@Click"
        buttonObject.replaceSubrange((userSlot.decodedOffset - 2)..<userSlot.decodedOffset,
            with: Data([UInt8(label.utf16.count), 0]) + (try XCTUnwrap(label.data(using: .utf16LittleEndian))))
        let clickProgram = try ScriptProgram(ScriptDocument(data: Data("@@Click\n\\clk\n".utf8),
            relativePath: "button-target.s"))
        var buttonStorage = ScriptStorage()
        XCTAssertEqual(try buttonStorage.stageSavedGlobalButtonIdentities(
            SaveVariableArrays(state: buttonObject, decodedOffset: 0),
            resources: [buttonPayload.decodedOffset: buttonResource],
            textures: [buttonPayload.decodedOffset: [1: hoverTexture]], savedState: buttonObject, program: clickProgram), 1)
        XCTAssertEqual(try buttonStorage.buttonArrayCount("b"), 1)
        XCTAssertNoThrow(try buttonStorage.requireKnownSavedButtonStatesForAdoption())
        if case .object(let handle) = try buttonStorage.readIndexed("b", 0) {
            XCTAssertEqual(buttonStorage.drawableRectangles[handle], [1, 2, 31, 42])
            XCTAssertEqual(buttonStorage.buttonUserStrings[handle]?[0], label)
            XCTAssertEqual(buttonStorage.buttonCheckVisual[handle], 2)
            XCTAssertEqual(buttonStorage.buttonLocks[handle], 7)
            XCTAssertEqual(buttonStorage.buttonUserIntegers[handle], [0: 37, 1: -12, 2: 3, 3: 9])
            let checkSource = Data("\\gvar,int,CheckValue,LockValue,User0,User1,User2,User3\n\\scp,b[0]\n\\?ck\n\\cal,CheckValue=ResultInt[0]\n\\?lk\n\\cal,LockValue=ResultInt[0]\n\\?ui\n\\cal,User0=ResultInt[0]\n\\cal,User1=ResultInt[1]\n\\cal,User2=ResultInt[2]\n\\cal,User3=ResultInt[3]\n\\wait,1\n".utf8)
            let checkProgram = try ScriptProgram(ScriptDocument(data: checkSource, relativePath: "saved-button-check.s"))
            let checkIndex = try XCTUnwrap(checkProgram.document.records.firstIndex { $0.kind == .command })
            var checkMachine = try XCTUnwrap(ScriptMachine.makeSavedExecutionMachine(program: checkProgram,
                index: checkIndex, storage: buttonStorage, repository: nil, wait: nil, maximumSteps: 100,
                retainFullTrace: false, imageLoader: nil, imageMemberLookup: nil,
                imageExtendedValues: nil, imageMotionNames: nil))
            try checkMachine.run()
            XCTAssertEqual(checkMachine.phase, .waiting)
            XCTAssertEqual(try checkMachine.value(named: "CheckValue"), .integer(1))
            XCTAssertEqual(try checkMachine.value(named: "LockValue"), .integer(1))
            XCTAssertEqual(try checkMachine.value(named: "User0"), .integer(37))
            XCTAssertEqual(try checkMachine.value(named: "User1"), .integer(-12))
            XCTAssertEqual(try checkMachine.value(named: "User2"), .integer(3))
            XCTAssertEqual(try checkMachine.value(named: "User3"), .integer(9))
            let lockedLayer = try XCTUnwrap(checkMachine.staticImageLayers.first { $0.id == handle })
            XCTAssertNil(lockedLayer.hoverResource)
            XCTAssertEqual(buttonStorage.buttonScriptTargets[handle], label)
            XCTAssertTrue(buttonStorage.enabledButtons.contains(handle))
            XCTAssertEqual(buttonStorage.buttonPlacement[handle], [320, 240, 8])
            XCTAssertEqual(buttonStorage.savedButtonPlacementScale[handle], SIMD2(80, 90))
            let drawProgram = try ScriptProgram(ScriptDocument(data: Data(
                "\\draw,1\n\\draw,1\n\\clk\n".utf8), relativePath: "button-draw.s"))
            let entry = try XCTUnwrap(drawProgram.document.records.firstIndex { $0.command == "draw" })
            var drewButton = false
            var unlockedStorage = buttonStorage
            unlockedStorage.buttonLocks[handle] = 0
            let eventSource = Data("\\gvar,int,Event0,Event1,Event2,Event3\n\\gvar,str,EventName\n\\stop,@@OnStop\n\\wait,1\n@@OnStop\n\\scp,inp\n\\gbc\n\\cal,EventName=ResultStr[0]\n\\cal,Event0=ResultInt[0]\n\\cal,Event1=ResultInt[1]\n\\cal,Event2=ResultInt[2]\n\\cal,Event3=ResultInt[3]\n\\play\n\\ret\n@@Click\n\\ret\n".utf8)
            let eventProgram = try ScriptProgram(ScriptDocument(data: eventSource, relativePath: "saved-button-event.s"))
            let eventIndex = try XCTUnwrap(eventProgram.document.records.firstIndex { $0.kind == .command })
            var lockedEventMachine = try XCTUnwrap(ScriptMachine.makeSavedExecutionMachine(program: eventProgram,
                index: eventIndex, storage: buttonStorage, repository: nil, wait: nil, maximumSteps: 200,
                retainFullTrace: false, imageLoader: nil, imageMemberLookup: nil,
                imageExtendedValues: nil, imageMotionNames: nil))
            try lockedEventMachine.run()
            XCTAssertEqual(lockedEventMachine.phase, .waitingForEvent)
            XCTAssertThrowsError(try lockedEventMachine.dispatchStopCallback(buttonIndex: 0, buttonArray: "b")) {
                XCTAssertEqual(String(describing: $0), "stop_button_not_selectable")
            }
            var eventMachine = try XCTUnwrap(ScriptMachine.makeSavedExecutionMachine(program: eventProgram,
                index: eventIndex, storage: unlockedStorage, repository: nil, wait: nil, maximumSteps: 200,
                retainFullTrace: false, imageLoader: nil, imageMemberLookup: nil,
                imageExtendedValues: nil, imageMotionNames: nil))
            try eventMachine.run()
            try eventMachine.dispatchStopCallback(buttonIndex: 0, buttonArray: "b")
            try eventMachine.run()
            XCTAssertEqual(eventMachine.phase, .waiting)
            XCTAssertEqual(try eventMachine.value(named: "EventName"), .string(label))
            for (name, value): (String, Int32) in [("Event0", 37), ("Event1", -12), ("Event2", 3), ("Event3", 9)] {
                XCTAssertEqual(try eventMachine.value(named: name), .integer(value))
            }
            var unlockedCheck = try XCTUnwrap(ScriptMachine.makeSavedExecutionMachine(program: checkProgram,
                index: checkIndex, storage: unlockedStorage, repository: nil, wait: nil, maximumSteps: 100,
                retainFullTrace: false, imageLoader: nil, imageMemberLookup: nil,
                imageExtendedValues: nil, imageMotionNames: nil))
            try unlockedCheck.run()
            XCTAssertEqual(try unlockedCheck.value(named: "LockValue"), .integer(0))
            let continuation = try ScriptMachine.probeSavedCalculations(program: drawProgram,
                index: entry, storage: unlockedStorage, drawPreview: { .init(status: .inferred) },
                drawScene: { machine, _ in
                    let layer = try XCTUnwrap(machine.staticImageLayers.first { $0.id == handle })
                    XCTAssertEqual(layer.x, 320)
                    XCTAssertEqual(layer.y, 240)
                    XCTAssertEqual(layer.priority, 8)
                    XCTAssertEqual(layer.scaleXPercent, 80)
                    XCTAssertEqual(layer.scaleYPercent, 90)
                    XCTAssertEqual(layer.hoverResource, hoverTexture)
                    drewButton = true
                    return (.init(status: .inferred), nil)
                })
            XCTAssertNotNil(continuation)
            XCTAssertTrue(drewButton)
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
        var liveTables = listStorage
        try liveTables.tables[tableHandle]?.setValue("雪=1", for: "x")
        let tableTemplate = Data("CalVal\0\0".utf8) + Data([1, 0, 0, 0, 0, 0, 0, 0]) + tableObject
        let encodedTables = try SaveVariableArrays.encodeCalValValues(template: tableTemplate, storage: liveTables)
        var restoredTables = ScriptStorage()
        _ = try restoredTables.stageSavedGlobalTextObjects(SaveVariableArrays.readCalVal(state: encodedTables, at: 0))
        guard case .object(let restoredFirst) = try restoredTables.readIndexed("t", 0),
              case .object(let restoredSecond) = try restoredTables.readIndexed("t", 1) else {
            return XCTFail("Expected two restored tables")
        }
        XCTAssertEqual(try restoredTables.tables[restoredFirst]?.value(for: "x"), "雪=1")
        XCTAssertEqual(try restoredTables.tables[restoredSecond]?.value(for: "x"), "z")
        try liveTables.tables[tableHandle]?.setValue("lost//on reload", for: "x")
        XCTAssertThrowsError(try SaveVariableArrays.encodeCalValValues(template: tableTemplate, storage: liveTables))
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
