import XCTest
import Foundation
@testable import MangekyouCore

final class ScriptTests: XCTestCase {
    func testScriptFrameClockClampsSelectedNativeElapsedPath() {
        XCTAssertEqual(ScriptFrameClock.elapsedMilliseconds(current: 100, previous: 100), 1)
        XCTAssertEqual(ScriptFrameClock.elapsedMilliseconds(current: 116, previous: 100), 16)
        XCTAssertEqual(ScriptFrameClock.elapsedMilliseconds(current: 5_100, previous: 100), 5_000)
        XCTAssertEqual(ScriptFrameClock.elapsedMilliseconds(current: 5_101, previous: 100), 5_000)
        XCTAssertEqual(ScriptFrameClock.elapsedMilliseconds(current: 3, previous: UInt32.max - 2), 1)
    }

    func testResearchConfigurationOverlayRoundTripAndBaseIdentity() throws {
        let configText = (1..<8).map { "Font[\($0)].Name=Fallback" }.joined(separator: "\n") + "\nMessageSpeed=10\n"
        let config = try ScriptTable(data: Data(configText.utf8), relativePath: "config.txt")
        let writerSource = Data("\\scp,cfg\n\\ms,33\n\\mtw,44\n\\mcw,55\n\\ma2,0,66\n\\fs,1\n\\il,1\n\\smr\n\\vtv,2,123\n\\vtm,2,1\n\\fn2,0,\"Example\"\n\\wait,1\n".utf8)
        let writerProgram = try ScriptProgram(ScriptDocument(data: writerSource, relativePath: "overlay-writer.s"))
        var writer = try ScriptMachine(program: writerProgram, allowExperimental: true, configuration: config)
        try writer.run()
        XCTAssertEqual(writer.phase, .waiting)
        let overlay = try writer.encodeResearchConfigurationOverlay()
        let readerSource = Data("\\gvar,int,Speed,Wait,Click,Alpha,Volume,Mute,Screen,Quality\n\\gvar,str,Font\n\\scp,cfg\n\\?ms\n\\cal,Speed=ResultInt[0]\n\\?mtw\n\\cal,Wait=ResultInt[0]\n\\?mcw\n\\cal,Click=ResultInt[0]\n\\?ma\n\\cal,Alpha=ResultInt[0]\n\\?fs\n\\cal,Screen=ResultInt[0]\n\\?il\n\\cal,Quality=ResultInt[0]\n\\?vtv,2\n\\cal,Volume=ResultInt[0]\n\\?vtm,2\n\\cal,Mute=ResultInt[0]\n\\?fn\n\\cal,Font=ResultStr[0]\n\\wait,1\n".utf8)
        let readerProgram = try ScriptProgram(ScriptDocument(data: readerSource, relativePath: "overlay-reader.s"))
        var reader = try ScriptMachine(program: readerProgram, allowExperimental: true, configuration: config)
        try reader.applyResearchConfigurationOverlay(overlay)
        try reader.run()
        for (name, value): (String, Int32) in [("Speed",33), ("Wait",44), ("Click",55), ("Alpha",66), ("Screen",1), ("Quality",1), ("Volume",123), ("Mute",1)] {
            XCTAssertEqual(try reader.value(named: name), .integer(value))
        }
        XCTAssertEqual(try reader.value(named: "Font"), .string("Example"))
        XCTAssertEqual(reader.summary.displayConfigurationHostStatus, .unsupported)
        XCTAssertTrue(reader.summary.displayRefreshRequested)
        XCTAssertThrowsError(try reader.applyResearchConfigurationOverlay(overlay))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: overlay) as? [String: Any])
        object["messageAlphaNeedsRendering"] = false
        var rejected = try ScriptMachine(program: readerProgram, allowExperimental: true, configuration: config)
        XCTAssertThrowsError(try rejected.applyResearchConfigurationOverlay(JSONSerialization.data(withJSONObject: object)))
        object["messageAlphaNeedsRendering"] = true
        object["displayNeedsHostUpdate"] = false
        XCTAssertThrowsError(try rejected.applyResearchConfigurationOverlay(JSONSerialization.data(withJSONObject: object)))
        object["displayNeedsHostUpdate"] = true
        object["displayValues"] = ["FullScreen": 7]
        XCTAssertThrowsError(try rejected.applyResearchConfigurationOverlay(JSONSerialization.data(withJSONObject: object)))
        object["displayValues"] = ["FullScreen": 1, "Interlace": 1]
        object["unexpected"] = 1
        XCTAssertThrowsError(try rejected.applyResearchConfigurationOverlay(JSONSerialization.data(withJSONObject: object)))
        try rejected.applyResearchConfigurationOverlay(overlay)
        try rejected.run()
        XCTAssertEqual(try rejected.value(named: "Speed"), .integer(33))
        object.removeValue(forKey: "unexpected")
        object.removeValue(forKey: "displayValues")
        object.removeValue(forKey: "displayNeedsHostUpdate")
        object.removeValue(forKey: "displayRefreshRequested")
        var oldOverlay = try ScriptMachine(program: readerProgram, allowExperimental: true, configuration: config)
        try oldOverlay.applyResearchConfigurationOverlay(JSONSerialization.data(withJSONObject: object))
        try oldOverlay.run()
        XCTAssertEqual(try oldOverlay.value(named: "Screen"), .integer(0))
        XCTAssertEqual(oldOverlay.summary.displayConfigurationHostStatus, .notTested)
        let refreshProgram = try ScriptProgram(ScriptDocument(data: Data("\\scp,cfg\n\\smr\n\\wait,1\n".utf8), relativePath: "refresh-only.s"))
        var refresh = try ScriptMachine(program: refreshProgram, allowExperimental: true, configuration: config)
        try refresh.run()
        var restoredRefresh = try ScriptMachine(program: readerProgram, allowExperimental: true, configuration: config)
        try restoredRefresh.applyResearchConfigurationOverlay(refresh.encodeResearchConfigurationOverlay())
        XCTAssertTrue(restoredRefresh.summary.displayRefreshRequested)
        XCTAssertEqual(restoredRefresh.summary.displayConfigurationHostStatus, .unsupported)
        let otherConfig = try ScriptTable(data: Data("MessageSpeed=11\n".utf8), relativePath: "config.txt")
        var mismatch = try ScriptMachine(program: readerProgram, allowExperimental: true, configuration: otherConfig)
        XCTAssertThrowsError(try mismatch.applyResearchConfigurationOverlay(overlay))
    }
    func testInitialMessageConfigurationQueries() throws {
        let source = Data("\\gvar,int,A,B,C,D,Speed,Delay,NewSpeed,NewDelay,NewClick,RawAlpha,Alpha0,Alpha1,Alpha3\n\\gvar,msg,Sample\n\\scp,Sample\n\\e\n\\o,\"test\"\n\\scp,cfg\n\\?ma\n\\cal,A=ResultInt[0],B=ResultInt[1],C=ResultInt[2],D=ResultInt[3]\n\\?ms\n\\cal,Speed=ResultInt[0]\n\\?mtw\n\\cal,Delay=ResultInt[0]\n\\ms,-7\n\\mtw,42\n\\mcw,66\n\\?ms\n\\cal,NewSpeed=ResultInt[0]\n\\?mtw\n\\cal,NewDelay=ResultInt[0]\n\\?mcw\n\\cal,NewClick=ResultInt[0]\n\\fs,1\n\\ma2,-1,300\n\\?ma\n\\cal,RawAlpha=ResultInt[0]\n\\ma,,-7,,999\n\\?ma\n\\cal,Alpha0=ResultInt[0],Alpha1=ResultInt[1],Alpha3=ResultInt[3]\n\\if,1\\then\n\\stop,@@!End\n\\end\n@@!End\n\\ret\n".utf8)
        let program = try ScriptProgram(ScriptDocument(data: source, relativePath: "message-config-query.s"))
        let table = try ScriptTable(data: Data("MessageAlpha=178\nMessageAlpha1=12\nMessageAlpha2=invalid\nMessageSpeed=11\n".utf8), relativePath: "config.txt")
        var machine = try ScriptMachine(program: program, allowExperimental: true, configuration: table)
        try machine.run()
        XCTAssertEqual(machine.phase, .waitingForEvent)
        for (name, value): (String, Int32) in [("A", 178), ("B", 12), ("C", 255), ("D", 255), ("Speed", 11), ("Delay", 30), ("NewSpeed", -7), ("NewDelay", 42), ("NewClick", 66), ("RawAlpha", 300), ("Alpha0", 300), ("Alpha1", 0), ("Alpha3", 255)] {
            XCTAssertEqual(try machine.value(named: name), .integer(value))
        }
        XCTAssertTrue(try machine.commitHeadlessMessageOutput())
        XCTAssertTrue(try XCTUnwrap(machine.messageTextLayers.first).unhandledDirectives.contains("config_message_alpha"))
        XCTAssertTrue(try XCTUnwrap(machine.messageTextLayers.first).unhandledDirectives.contains("config_display_state"))
    }
    func testInitialDisplayQueriesUseConfiguredValuesAndFallbacks() throws {
        let source = Data("\\gvar,int,Value,InterlaceValue\n\\scp,cfg\n\\?fs\n\\cal,Value=ResultInt[0]\n\\?il\n\\cal,InterlaceValue=ResultInt[0]\n\\wait,1\n".utf8)
        let program = try ScriptProgram(ScriptDocument(data: source, relativePath: "fullscreen-query.s"))
        for (config, expected, interlace): (String, Int32, Int32) in [("FullScreen=1\nInterlace=1\n", 1, 1),
            ("FullScreen=-2\nInterlace=-3\n", -2, -3), ("FullScreen=invalid\nInterlace=invalid\n", 0, 0),
            ("Other=1\n", 0, 0)] {
            let table = try ScriptTable(data: Data(config.utf8), relativePath: "config.txt")
            var machine = try ScriptMachine(program: program, allowExperimental: true, configuration: table)
            try machine.run()
            XCTAssertEqual(machine.phase, .waiting)
            XCTAssertEqual(try machine.value(named: "Value"), .integer(expected))
            XCTAssertEqual(try machine.value(named: "InterlaceValue"), .integer(interlace))
        }
    }
    func testResearchAudioSnapshotComparisonPreservesStringBytes() {
        func location(_ name: String) -> ScriptLocation {
            ScriptLocation(sourceFile: name, sourceSHA256: "hash", byteOffset: 0,
                           byteLength: 1, rangeSHA256: "range", lineNumber: 1)
        }
        func snapshot(_ name: String, filter: String? = nil) -> ScriptMachine.ResearchActiveAudioSnapshot {
            .init(kind: "stream", index: 1, source: location(name), playbackStartStep: 1,
                  probedDurationMilliseconds: 100, loopRequest: 0, filterRequest: filter, volumeFilterCandidate: nil,
                  filterChainCandidateText: nil,
                  volumeType: 0, appliedVolumeType: 0, volumeTarget: 128, volumeDuration: 0,
                  volumeDelay: 0, volumeChangePending: false, volumeAcknowledgementPending: false,
                  panDuration: 0, panDelay: 0, panTarget: 0, panChangePending: false,
                  panAcknowledgementPending: false, seekPending: false, seekTarget: nil)
        }
        let composed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        XCTAssertEqual(composed, decomposed)
        XCTAssertEqual(snapshot(composed), snapshot(composed))
        XCTAssertNotEqual(snapshot(composed), snapshot(decomposed))
        XCTAssertNotEqual(snapshot("file", filter: composed), snapshot("file", filter: decomposed))
    }

    func testPositiveLineAdvanceMovesEstimatedPenAndRejectsOtherForms() throws {
        let output = try ScriptStorage.MessageObject.parseOutput("[n,6]text")
        guard output.count == 2, case .directive("n", let operands) = output[0], case .text("text") = output[1] else {
            return XCTFail("Expected the unrendered directive and text to be preserved")
        }
        XCTAssertEqual(operands, [6])
        var message = ScriptStorage.MessageObject()
        message.committedOutput = try ScriptStorage.MessageObject.parseOutput("A[n,6]B")
        XCTAssertEqual(message.headlessTextPosition, [12, 6])
        XCTAssertThrowsError(try ScriptStorage.MessageObject.parseOutput("[n,-1]"))
        XCTAssertThrowsError(try ScriptStorage.MessageObject.parseOutput("[n,0]"))
    }

    func testEstimatedPenUsesConfiguredLineBreakClasses() throws {
        var message = ScriptStorage.MessageObject()
        message.textBounds = [0, 0, 100, 100]
        message.kinsokuWordLength = 1
        message.prohibitedLineStart = "、"
        message.prohibitedLineEnd = "（"
        message.committedOutput = try ScriptStorage.MessageObject.parseOutput("[s,20,20]甲乙丙丁、甲")
        XCTAssertEqual(message.headlessTextPosition, [20, 20])
        message.committedOutput = try ScriptStorage.MessageObject.parseOutput("[s,20,20]甲乙丙（甲")
        XCTAssertEqual(message.headlessTextPosition, [40, 20])
    }

    func testUnchangedPlacementRequestPreservesActiveTransition() {
        let transform = ScriptStorage.ImageTransform(depth: 0, scale: [100, 100, 100], rotation: [0, 0, 0], loop: 0)
        let changed = ScriptStorage.ImageTransform(depth: 0, scale: [101, 100, 100], rotation: [0, 0, 0], loop: 0)
        let transition = ScriptStorage.PlacementTransition(destination: [0, 3, 140], duration: 250,
                                                            elapsed: 7, destinationTransform: transform)
        XCTAssertTrue(transition.matchesUnchangedRequest(destination: [0, 3, 140], duration: 250, transform: transform))
        XCTAssertFalse(transition.matchesUnchangedRequest(destination: [0, 3, 141], duration: 250, transform: transform))
        XCTAssertFalse(transition.matchesUnchangedRequest(destination: [0, 3, 140], duration: 251, transform: transform))
        XCTAssertFalse(transition.matchesUnchangedRequest(destination: [0, 3, 140], duration: 250, transform: changed))
        XCTAssertEqual(transition.elapsed, 7)
    }

    func testImmediateMessagePlacementResetsPriorScale() throws {
        let script = #"""
        \gvar,msg,sample
        \scp,sample
        \ts,0,0,240,80
        \p4,0,0,0,50,70,100,0,0,0,1,0
        \p,10,20,1
        \e
        \o,"text"
        \if,1\then
        \stop,@@!Resume
        \end
        @@!Resume
        \ret
        """#
        var machine = try run(script)
        XCTAssertTrue(try machine.commitHeadlessMessageOutput())
        let layer = try XCTUnwrap(machine.messageTextLayers.first)
        XCTAssertEqual([layer.x, layer.y, layer.scaleXPercent, layer.scaleYPercent], [10, 20, 100, 100])
    }

    func testMessagePreviewReportsUnimplementedCustomLineRules() throws {
        let script = #"""
        \gvar,msg,sample
        \scp,sample
        \ts,0,0,240,80
        \kwb,"、"
        \kwe,"（"
        \nsw,"除"
        \kwl,3
        \p,0,0,1
        \e
        \o,"text"
        \if,1\then
        \stop,@@!Resume
        \end
        @@!Resume
        \ret
        """#
        var machine = try run(script)
        XCTAssertTrue(try machine.commitHeadlessMessageOutput())
        XCTAssertEqual(try XCTUnwrap(machine.messageTextLayers.first).unhandledDirectives,
                       ["kwb", "kwe", "kwl", "nsw"])
    }

    func testImagePlacementResetsScaleAtImmediateAndTimedEndpoints() throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/owned-image-placement-tests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = Data([1, 2, 3])
        try image.write(to: directory.appendingPathComponent("image.png"))
        for (duration, initialXScale) in [(0, 50), (100, 50), (100, 51)] {
            let script = "\\gvar,img,sample\n\\scp,sample\n\\l,\"image.png\"\n\\p2,0,0,1,\(initialXScale),70,0\n\\p,10,20,1,\(duration)\n\\e\n\\wait,1\n"
            let bytes = Data([0xef, 0xbb, 0xbf]) + Data(script.utf8)
            let root = ScriptModuleReference(logicalPath: "root.s", sourceFile: "root.s", sourceSHA256: bytes.sha256Hex)
            let resource = ScriptModuleReference(logicalPath: "image.png", sourceFile: "image.png", sourceSHA256: image.sha256Hex)
            let repository = try ScriptRepository(directory: SafeDirectory(directory), catalog: ScriptModuleCatalog(entries: [root, resource]))
            var machine = try ScriptMachine(program: ScriptProgram(ScriptDocument(data: bytes, relativePath: "root.s")),
                                            allowExperimental: true, repository: repository, imageLoader: { _ in (10, 10, 1) })
            try machine.run()
            if duration > 0 {
                machine.advanceVisualClock(ticks: 50)
                let midpoint = try XCTUnwrap(machine.staticImageLayers.first)
                XCTAssertEqual([midpoint.x, midpoint.y, midpoint.scaleYPercent], [5, 10, 85])
                XCTAssertEqual(midpoint.unappliedTransform, initialXScale == 51)
                if initialXScale == 50 { XCTAssertEqual(midpoint.scaleXPercent, 75) }
                else { XCTAssertEqual(midpoint.fractionalScalePercent, SIMD2<Float>(75.5, 85)) }
                machine.advanceVisualClock(ticks: 50)
            }
            let layer = try XCTUnwrap(machine.staticImageLayers.first, machine.summary.stopReason ?? "missing image")
            XCTAssertEqual([layer.x, layer.y, layer.scaleXPercent, layer.scaleYPercent], [10, 20, 100, 100])
        }
    }

    func testSHA256HexUsesCanonicalLowercaseEncoding() {
        XCTAssertEqual(Data().sha256Hex, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(Data("abc".utf8).sha256Hex, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testTimedImageOpacityUsesQuantizedProgress() {
        var image = ScriptStorage.ImageObject()
        image.immediateOpacity = 0
        image.opacityEndpoint = (255, 500, 500, 0)
        XCTAssertEqual(image.presentedOpacity, 0)
        image.opacityEndpoint?.remaining = 250
        XCTAssertEqual(image.presentedOpacity, 128)
        image.opacityEndpoint?.remaining = 0
        XCTAssertEqual(image.presentedOpacity, 255)
    }

    func testTimedImageOpacityRepeatsOnlyAfterEndpoint() {
        var image = ScriptStorage.ImageObject()
        image.immediateOpacity = 0
        image.opacityEndpoint = (255, 500, 500, 1)
        image.advanceOpacity(ticks: 500)
        XCTAssertEqual(image.presentedOpacity, 255)
        XCTAssertEqual(image.opacityEndpoint?.repeats, 1)
        image.advanceOpacity(ticks: 1)
        XCTAssertEqual(image.presentedOpacity, 1)
        XCTAssertEqual(image.opacityEndpoint?.repeats, 0)
        image.advanceOpacity(ticks: 499)
        XCTAssertNil(image.opacityEndpoint)
        XCTAssertEqual(image.presentedOpacity, 255)
    }

    func document(_ text: String) throws -> ScriptDocument {
        try ScriptDocument(data: Data([0xef,0xbb,0xbf]) + Data(text.utf8),relativePath: "owned/scene.s")
    }
    func run(_ text: String, maximumSteps: Int = 1000, maximumFrames: Int = 64) throws -> ScriptMachine {
        var machine = try ScriptMachine(program: ScriptProgram(document(text)),allowExperimental: true,
            maximumSteps: maximumSteps,maximumFrames: maximumFrames)
        try machine.run(); return machine
    }
    func testTimedStopCountdownsAndIndefiniteZero() throws {
        let source = #"""
        \gvar,int,Observed
        \stop,@@!OnStop,10,2
        \wait,1
        @@!OnStop
        \cal,Observed=ResultStopInt
        \ret
        """#
        var machine = try run(source)
        XCTAssertEqual(machine.phase, .waitingForEvent)
        try machine.advanceTimedStop(ticks: 3)
        XCTAssertEqual(machine.timedStopRequest?.duration, 7)
        XCTAssertEqual(machine.timedStopRequest?.alternateDuration, 0)
        try machine.advanceTimedStop(ticks: 7)
        XCTAssertEqual(machine.phase, .ready)
        XCTAssertNil(machine.timedStopRequest)

        var indefinite = try run(source.replacingOccurrences(of: ",10,2", with: ",0,2"))
        XCTAssertEqual(indefinite.timedStopRequest?.duration, -1)
        try indefinite.advanceTimedStop(ticks: Int32.max)
        XCTAssertEqual(indefinite.phase, .waitingForEvent)
        XCTAssertEqual(indefinite.timedStopRequest?.duration, -1)
        XCTAssertEqual(indefinite.timedStopRequest?.alternateDuration, 2)
        try indefinite.dispatchStopCallback()
        try indefinite.run()
        XCTAssertEqual(try indefinite.value(named: "Observed"), .integer(-1))
    }
    func testSkipQueryRejectsUnmodelledActiveModes() throws {
        for mode in 3...5 {
            let machine = try run("\\scp,sys\n\\p,\(mode)\n\\?skp\n\\wait,1\n")
            XCTAssertEqual(machine.summary.stopReason, "system_skip_frame_state_unsupported")
        }
        let reset = try run(#"""
        \gvar,int,Observed
        \scp,sys
        \p,3
        \p,0
        \?skp
        \cal,Observed=ResultInt[0]
        \wait,1
        """#)
        XCTAssertEqual(reset.phase, .waiting, reset.summary.stopReason ?? "unexpected phase")
        XCTAssertEqual(try reset.value(named: "Observed"), .integer(0))
    }
    func testResearchSkipFrameRequiresSampleAndResets() throws {
        let source = #"""
        \gvar,int,Active,Reset
        \scp,sys
        \p,3
        \wait,1
        \?skp
        \cal,Active=ResultInt[0]
        \p,0
        \?skp
        \cal,Reset=ResultInt[0]
        \wait,1
        """#
        var machine = try ScriptMachine(program: ScriptProgram(document(source)), allowExperimental: true)
        machine.allowResearchSkipFrameCandidate = true
        try machine.run()
        XCTAssertEqual(machine.phase, .waiting)
        try machine.advanceClickWait(ticks: 1)
        try machine.advancePlacementClock(ticks: 1)
        try machine.run()
        XCTAssertEqual(machine.phase, .waiting, machine.summary.stopReason ?? "unexpected phase")
        XCTAssertEqual(try machine.value(named: "Active"), .integer(1))
        XCTAssertEqual(try machine.value(named: "Reset"), .integer(0))
        XCTAssertEqual(machine.researchSkipFrameSamples, 1)
    }
    func testResearchSkipFrameModeWriteKeepsPreviousSampleUntilNextFrame() throws {
        let source = #"""
        \gvar,int,BeforeFrame,AfterFrame
        \wait,1
        \scp,sys
        \p,3
        \?skp
        \cal,BeforeFrame=ResultInt[0]
        \wait,1
        \?skp
        \cal,AfterFrame=ResultInt[0]
        \wait,1
        """#
        var machine = try ScriptMachine(program: ScriptProgram(document(source)), allowExperimental: true)
        machine.allowResearchSkipFrameCandidate = true
        try machine.run()
        for _ in 0..<2 {
            try machine.advanceClickWait(ticks: 1)
            try machine.advancePlacementClock(ticks: 1)
            try machine.run()
        }
        XCTAssertEqual(machine.phase, .waiting, machine.summary.stopReason ?? "unexpected phase")
        XCTAssertEqual(try machine.value(named: "BeforeFrame"), .integer(0))
        XCTAssertEqual(try machine.value(named: "AfterFrame"), .integer(1))
    }
    func testResearchSkipTimeAccumulatesUntilFiniteHostFrame() throws {
        let source = #"""
        \skip,200
        \skip,300
        \wait,501
        \wait,1
        """#
        var machine = try ScriptMachine(program: ScriptProgram(document(source)), allowExperimental: true)
        machine.allowResearchSkipTimeCandidate = true
        try machine.run()
        XCTAssertEqual(machine.pendingResearchSkipTime, 500)
        XCTAssertEqual(try machine.consumeResearchSkipTime(hostTicks: 0), 0)
        let elapsed = try machine.consumeResearchSkipTime(hostTicks: 1)
        XCTAssertEqual(elapsed, 501)
        try machine.advanceClickWait(ticks: elapsed)
        try machine.advancePlacementClock(ticks: elapsed)
        try machine.run()
        XCTAssertEqual(machine.phase, .waiting, machine.summary.stopReason ?? "unexpected phase")
        XCTAssertEqual(machine.clickWaitRemaining, 1)
        XCTAssertEqual(machine.pendingResearchSkipTime, 0)
        XCTAssertEqual(machine.researchSkipTimeConsumed, 500)

        var zero = try ScriptMachine(program: ScriptProgram(document("\\zero\n\\skip,500\n\\wait,501\n")), allowExperimental: true)
        zero.allowResearchSkipFrameCandidate = true
        zero.allowResearchSkipTimeCandidate = true
        try zero.run()
        let zeroElapsed = try zero.consumeResearchWaitZeroClock(hostTicks: 1)
        XCTAssertEqual(zeroElapsed, 500)
        XCTAssertEqual(zero.pendingResearchSkipTime, 0)
        XCTAssertEqual(zero.researchSkipTimeConsumed, 500)
        try zero.advanceClickWait(ticks: zeroElapsed)
        XCTAssertEqual(zero.clickWaitRemaining, 1)
    }
    func testResearchStopCallbackLocationDistinguishesSameFileCallbacks() throws {
        let source = #"""
        \stop,@@!First
        \stop,@@!Second
        \wait,1
        @@!First
        \play
        \ret
        @@!Second
        \ret
        """#
        var machine = try ScriptMachine(program: ScriptProgram(document(source)), allowExperimental: true)
        try machine.run()
        let first = try XCTUnwrap(machine.researchStopCallbackLocation)
        try machine.dispatchStopCallback()
        try machine.run()
        let second = try XCTUnwrap(machine.researchStopCallbackLocation)
        XCTAssertEqual(first.sourceFile, second.sourceFile)
        XCTAssertNotEqual(first, second)
    }
    func testResearchDrawBoundarySuspendsBeforeFollowingCommand() throws {
        let source = #"""
        \gvar,int,After
        \draw,1
        \cal,After=1
        \wait,1
        """#
        var machine = try ScriptMachine(program: ScriptProgram(document(source)), allowExperimental: true)
        machine.researchStopAtDrawBoundary = true
        try machine.run()
        XCTAssertEqual(machine.phase, .waitingForFrame)
        XCTAssertEqual(machine.researchPendingDrawCount, 1)
        XCTAssertEqual(try machine.value(named: "After"), .integer(0))
        try machine.advanceResearchDrawFrame(ticks: 1)
        try machine.run()
        XCTAssertEqual(machine.phase, .waiting)
        XCTAssertEqual(try machine.value(named: "After"), .integer(1))
        var pending = try ScriptMachine(program: ScriptProgram(document("\\skip,5\n\\draw,1\n\\wait,1\n")), allowExperimental: true)
        pending.allowResearchSkipTimeCandidate = true
        try pending.run()
        XCTAssertEqual(pending.phase, .waitingForFrame)
        XCTAssertEqual(pending.pendingResearchSkipTime, 5)
        XCTAssertThrowsError(try pending.advanceResearchDrawFrame(ticks: 1))
        XCTAssertEqual(pending.pendingResearchSkipTime, 5)
        try pending.advanceResearchDrawFrame(ticks: 1, consumePendingSkipTime: true)
        XCTAssertEqual(pending.pendingResearchSkipTime, 0)
        XCTAssertEqual(pending.researchSkipTimeConsumed, 5)
        XCTAssertEqual(pending.researchVisualTicks, 6)
        XCTAssertEqual(pending.phase, .ready)
        var zeroAndSkip = try ScriptMachine(program: ScriptProgram(document("\\zero\n\\skip,5\n\\draw,1\n")), allowExperimental: true)
        zeroAndSkip.allowResearchSkipTimeCandidate = true
        try zeroAndSkip.run()
        try zeroAndSkip.advanceResearchDrawFrame(ticks: 1, consumePendingSkipTime: true)
        XCTAssertEqual(zeroAndSkip.researchVisualTicks, 5)
        XCTAssertEqual(zeroAndSkip.pendingResearchSkipTime, 0)
        XCTAssertEqual(zeroAndSkip.researchDrawZeroClockFrames, 1)
        var excessive = try ScriptMachine(program: ScriptProgram(document("\\skip,60000\n\\draw,1\n")), allowExperimental: true)
        excessive.allowResearchSkipTimeCandidate = true
        try excessive.run()
        XCTAssertThrowsError(try excessive.advanceResearchDrawFrame(ticks: 1, consumePendingSkipTime: true))
        XCTAssertEqual(excessive.pendingResearchSkipTime, 60_000)
        XCTAssertEqual(excessive.researchVisualTicks, 0)
        let zeroSource = #"""
        \gvar,int,Observed
        \scp,sys
        \p,3
        \zero
        \draw,1
        \?skp
        \cal,Observed=ResultInt[0]
        \wait,1
        """#
        var zero = try ScriptMachine(program: ScriptProgram(document(zeroSource)), allowExperimental: true)
        zero.allowResearchSkipFrameCandidate = true
        zero.researchStopAtDrawBoundary = true
        try zero.run()
        try zero.advanceResearchDrawFrame(ticks: 1)
        try zero.run()
        XCTAssertEqual(zero.phase, .waiting, zero.summary.stopReason ?? "unexpected phase")
        XCTAssertEqual(try zero.value(named: "Observed"), .integer(1))
        XCTAssertEqual(zero.researchDrawZeroClockFrames, 1)
        var stale = try ScriptMachine(program: ScriptProgram(document("\\zero\n\\wait,1\n\\draw,1\n")), allowExperimental: true)
        stale.allowResearchSkipFrameCandidate = true
        stale.researchStopAtDrawBoundary = true
        try stale.run()
        try stale.advanceClickWait(ticks: 1)
        try stale.advancePlacementClock(ticks: 1)
        try stale.run()
        XCTAssertThrowsError(try stale.advanceResearchDrawFrame(ticks: 1)) { error in
            XCTAssertEqual(String(describing: error), "draw_frame_zero_history_unmodelled")
        }
        var guarded = try ScriptMachine(program: ScriptProgram(document("\\zero\n\\wait,1\n\\draw,1\n")), allowExperimental: true)
        guarded.allowResearchSkipFrameCandidate = true
        guarded.researchStopAtDrawBoundary = true
        try guarded.run()
        let zeroTicks = try guarded.consumeResearchWaitZeroClock(hostTicks: 1)
        XCTAssertEqual(zeroTicks, 0)
        try guarded.advanceClickWait(ticks: zeroTicks)
        try guarded.advancePlacementClock(ticks: zeroTicks)
        XCTAssertEqual(guarded.clickWaitRemaining, 1)
        XCTAssertEqual(guarded.researchWaitZeroClockFrames, 1)
        try guarded.advanceClickWait(ticks: 1)
        try guarded.advancePlacementClock(ticks: 1)
        try guarded.run()
        XCTAssertEqual(guarded.phase, .waitingForFrame)
        try guarded.advanceResearchDrawFrame(ticks: 1)
        XCTAssertEqual(guarded.phase, .ready)
    }
    func testSystemOutputMaskWriteQueryAndReset() throws {
        let machine = try run(#"""
        \gvar,int,Before,After,Input
        \scp,sys
        \in,37
        \out,123
        \?out
        \cal,Before=ResultInt[0]
        \out
        \?out
        \cal,After=ResultInt[0]
        \?in
        \cal,Input=ResultInt[0]
        \wait,1
        """#)
        XCTAssertEqual(try machine.value(named: "Before"), .integer(123))
        XCTAssertEqual(try machine.value(named: "After"), .integer(0xffffff))
        XCTAssertEqual(try machine.value(named: "Input"), .integer(37))
    }
    func testResearchSceneOutputMaskCandidate() throws {
        let machine = try run(#"""
        \gvar,img,Gallery,Viewer
        \gvar,btn,DefaultButton,ViewerButton
        \gvar,msg,UnknownMessage,ViewerMessage
        \scp,Viewer
        \out,$10000
        \scp,ViewerButton
        \out,$10000
        \scp,ViewerMessage
        \out,$10000
        \scp,sys
        \out,$10000
        \wait,1
        """#)
        func handle(_ name: String) throws -> UInt64 {
            guard case .object(let value) = try machine.value(named: name) else {
                throw ResourceError.rejected("fixture_object_missing")
            }
            return value
        }
        XCTAssertEqual(machine.researchSceneOutputVisibility(try handle("Gallery")), false)
        XCTAssertEqual(machine.researchSceneOutputVisibility(try handle("Viewer")), true)
        XCTAssertEqual(machine.researchSceneOutputVisibility(try handle("DefaultButton")), false)
        XCTAssertEqual(machine.researchSceneOutputVisibility(try handle("ViewerButton")), true)
        XCTAssertNil(machine.researchSceneOutputVisibility(try handle("UnknownMessage")))
        XCTAssertEqual(machine.researchSceneOutputVisibility(try handle("ViewerMessage")), true)
    }
    func testDeclaredListArrayHasIndependentElements() throws {
        let machine = try run(#"""
        \gvar,int,A,B
        \gvar,list,Items[2]
        \scp,Items[0]
        \a,"first"
        \?c
        \cal,A=ResultInt[0]
        \scp,Items[1]
        \?c
        \cal,B=ResultInt[0]
        \wait,1
        """#)
        XCTAssertEqual(try machine.value(named: "A"), .integer(1))
        XCTAssertEqual(try machine.value(named: "B"), .integer(0))
        let single = try run(#"""
        \gvar,int,Count
        \gvar,list,Items[1]
        \scp,Items[0]
        \a,"one"
        \?c
        \cal,Count=ResultInt[0]
        \wait,1
        """#)
        XCTAssertEqual(single.phase, .waiting, single.summary.stopReason ?? "unexpected phase")
        XCTAssertEqual(try single.value(named: "Count"), .integer(1))
    }
    func testListSplitObservedFiveArgumentMode() throws {
        let machine = try run(#"""
        \gvar,int,Count,EmptyCount,PaddedCount,LongCount
        \gvar,list,Items[4]
        \scp,Items[0]
        \ad,",","one,two,",0,0,1
        \?c
        \cal,Count=ResultInt[0]
        \scp,Items[1]
        \ad,",","",0,0,1
        \?c
        \cal,EmptyCount=ResultInt[0]
        \scp,Items[2]
        \ad,",","one,two",0,0,3
        \?c
        \cal,PaddedCount=ResultInt[0]
        \scp,Items[3]
        \ad,",","one,two,three,four",0,0,3
        \?c
        \cal,LongCount=ResultInt[0]
        \wait,1
        """#)
        XCTAssertEqual(try machine.value(named: "Count"), .integer(3))
        XCTAssertEqual(try machine.value(named: "EmptyCount"), .integer(1))
        XCTAssertEqual(try machine.value(named: "PaddedCount"), .integer(3))
        XCTAssertEqual(try machine.value(named: "LongCount"), .integer(4))
    }
    func testMiscExtractExtensionUsesLastPathBoundary() throws {
        let machine = try run(#"""
        \gvar,str,Extension,Missing
        \scp,misc
        \efe,"dir.name\\track.ogg"
        \cal,Extension=ResultStr[0]
        \efe,"dir.name\\track"
        \cal,Missing=ResultStr[0]
        \wait,1
        """#)
        XCTAssertEqual(try machine.value(named: "Extension"), .string(".ogg"))
        XCTAssertEqual(try machine.value(named: "Missing"), .string(""))
    }
    func testListLineReplacementUpdatesNamedLookup() throws {
        let machine = try run(#"""
        \gvar,str,Line,Value
        \gvar,list,Items[2]
        \scp,Items[0]
        \a,"old=1"
        \s,0,"new=2"
        \?s,0
        \cal,Line=ResultStr[0]
        \?v,"new"
        \cal,Value=ResultStr[0]
        \wait,1
        """#)
        XCTAssertEqual(machine.phase, .waiting, machine.summary.stopReason ?? "unexpected phase")
        XCTAssertEqual(try machine.value(named: "Line"), .string("new=2"))
        XCTAssertEqual(try machine.value(named: "Value"), .string("2"))
    }
    func testBarMotionSamplingRequiresExplicitEasing() throws {
        let power = try XCTUnwrap(BarMotionSampling.animationTime(start: 0, target: 100, maximum: 100,
            duration: 100, remaining: 50, animationDuration: 1000, easing: .power))
        let quartic = try XCTUnwrap(BarMotionSampling.animationTime(start: 0, target: 100, maximum: 100,
            duration: 100, remaining: 50, animationDuration: 1000, easing: .quartic))
        XCTAssertEqual(power, 928.206, accuracy: 0.01)
        XCTAssertEqual(quartic, 937.5, accuracy: 0.001)
        XCTAssertEqual(BarMotionSampling.animationTime(start: 0, target: 100, maximum: 100,
            duration: 100, remaining: 101, animationDuration: 1000, easing: .quartic), nil)
    }

    func testBarPointerGeometryUsesExplicitRounding() throws {
        let geometry = try XCTUnwrap(BarPointerGeometry(knobLength: 0, trackLength: 399, maximum: 100_000))
        XCTAssertEqual(geometry.start, 0)
        XCTAssertEqual(geometry.end, 399)
        XCTAssertEqual(geometry.value(pointer: 409, origin: 210, rounding: .nearestEven), 49_875)
        XCTAssertEqual(geometry.value(pointer: 409, origin: 210, rounding: .down), 49_874)
        XCTAssertEqual(geometry.value(pointer: 609, origin: 210, rounding: .nearestEven), 100_000)
        XCTAssertEqual(geometry.value(pointer: 100, origin: 210, rounding: .nearestEven), 0)
        let half = try XCTUnwrap(BarPointerGeometry(knobLength: 0, trackLength: 10, maximum: 1))
        XCTAssertEqual(half.value(pointer: 5, origin: 0, rounding: .nearestEven), 0)
        XCTAssertEqual(half.value(pointer: 5, origin: 0, rounding: .up), 1)
        let overflow = try XCTUnwrap(BarPointerGeometry(knobLength: 0, trackLength: 10, maximum: .max))
        XCTAssertEqual(overflow.value(pointer: 2, origin: 0, rounding: .nearestEven), 0)
    }

    func testExplicitEntryArgumentsPopulateParameterArrays() throws {
        let program = try ScriptProgram(document(#"""
        @@!Entry
        \gvar,int,Number,Count
        \gvar,str,Text
        \cal,Text=ParamStr[0],Number=ParamInt[1],Count=ParamCount
        \wait,1
        """#))
        var machine = try ScriptMachine(program: program, allowExperimental: true, entryLabel: "@@!Entry",
                                        entryArguments: [.string("clip.ogv"), .integer(192)])
        try machine.run()
        XCTAssertEqual(try machine.value(named: "Text"), .string("clip.ogv"))
        XCTAssertEqual(try machine.value(named: "Number"), .integer(192))
        XCTAssertEqual(try machine.value(named: "Count"), .integer(2))
        XCTAssertThrowsError(try ScriptMachine(program: program, allowExperimental: true,
                                               entryArguments: [.integer(1)]))
    }

    func testSoundCategoryGainPreservesIndependentMuteRule() throws {
        var storage = ScriptStorage()
        var sound = ScriptStorage.SoundChannel()
        sound.volumeType = 4
        storage.configVoiceValues[4] = 128
        sound.appliedVolumeType = 4
        sound.volumeType = 0
        XCTAssertEqual(try storage.soundCategoryGain(sound), 128)
        storage.configVoiceModes[4] = 1
        XCTAssertEqual(try storage.soundCategoryGain(sound), 0)
        storage.configVoiceModes[4] = 2
        XCTAssertEqual(try storage.soundCategoryGain(sound), 128)
        sound.appliedVolumeType = 32
        XCTAssertThrowsError(try storage.soundCategoryGain(sound))
    }

    func testRepeatedStreamP2PreservesPlaybackAndPendingControl() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/owned-stream-p2-tests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var ogg = Data("OggS".utf8) + Data(repeating: 0, count: 23)
        ogg[5] = 2; ogg[26] = 1; ogg.append(30)
        ogg.append(Data([1]) + Data("vorbis".utf8) + Data(repeating: 0, count: 23))
        try ogg.write(to: directory.appendingPathComponent("clip.ogg"))
        let script = #"""
        \scp,snd[0]
        \l,"clip.ogg"
        \p2,0
        \v,128,100
        \p2,-2
        \wait,1
        """#
        let source = Data([0xef, 0xbb, 0xbf]) + Data(script.utf8)
        let root = ScriptModuleReference(logicalPath: "root.s", sourceFile: "root.s", sourceSHA256: source.sha256Hex)
        let clip = ScriptModuleReference(logicalPath: "clip.ogg", sourceFile: "clip.ogg", sourceSHA256: ogg.sha256Hex)
        let repository = try ScriptRepository(directory: SafeDirectory(directory), catalog: ScriptModuleCatalog(entries: [root, clip]))
        var machine = try ScriptMachine(program: ScriptProgram(ScriptDocument(data: source, relativePath: "root.s")),
                                        allowExperimental: true, repository: repository)
        try machine.run()
        XCTAssertEqual(machine.phase, .waitingForMedia, machine.summary.stopReason ?? "unexpected phase")
        XCTAssertFalse(machine.soundPlaybackPreservesPosition)
        let channel = try XCTUnwrap(machine.soundPlaybackChannel)
        let firstStep = try XCTUnwrap(machine.activeStreamPlaybackSnapshots[channel]?.step)
        try machine.acknowledgeSoundPlayback()
        while machine.phase == .ready {
            if machine.step()?.action == "sound_v_candidate" { break }
        }
        let change = try XCTUnwrap(machine.takeSoundVolumeChanges()[channel])
        try machine.run()
        XCTAssertEqual(machine.phase, .waitingForMedia, machine.summary.stopReason ?? "unexpected phase")
        XCTAssertTrue(machine.soundPlaybackPreservesPosition)
        XCTAssertEqual(machine.soundPlaybackRepeatCount, -1)
        XCTAssertEqual(machine.activeStreamPlaybackSnapshots[channel]?.step, firstStep)
        try machine.acknowledgeSoundPlayback()
        XCTAssertTrue(machine.acknowledgeSoundControlChange(change, channel: channel, kind: .volume))
    }

    func testStreamLoadNameQueryPreservesRequestedSpellingAndReset() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/owned-stream-name-tests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var ogg = Data("OggS".utf8) + Data(repeating: 0, count: 23)
        ogg[5] = 2; ogg[26] = 1; ogg.append(30)
        ogg.append(Data([1]) + Data("vorbis".utf8) + Data(repeating: 0, count: 23))
        try ogg.write(to: directory.appendingPathComponent("clip.ogg"))
        let script = #"""
        \gvar,str,Before,Loaded,After,Filter,ResetFilter
        \scp,snd[0]
        \?l
        \cal,Before=ResultStr[0]
        \l,"CLIP.OGG"
        \?l
        \cal,Loaded=ResultStr[0]
        \fo,"candidate-filter"
        \?fo
        \cal,Filter=ResultStr[0]
        \i
        \?l
        \cal,After=ResultStr[0]
        \?fo
        \cal,ResetFilter=ResultStr[0]
        \wait,1
        """#
        let source = Data([0xef, 0xbb, 0xbf]) + Data(script.utf8)
        let root = ScriptModuleReference(logicalPath: "root.s", sourceFile: "root.s", sourceSHA256: source.sha256Hex)
        let clip = ScriptModuleReference(logicalPath: "clip.ogg", sourceFile: "clip.ogg", sourceSHA256: ogg.sha256Hex)
        let repository = try ScriptRepository(directory: SafeDirectory(directory), catalog: ScriptModuleCatalog(entries: [root, clip]))
        var machine = try ScriptMachine(program: ScriptProgram(ScriptDocument(data: source, relativePath: "root.s")),
                                        allowExperimental: true, repository: repository)
        try machine.run()
        XCTAssertEqual(machine.phase, .waiting, machine.summary.stopReason ?? "unexpected phase")
        XCTAssertEqual(try machine.value(named: "Before"), .string(""))
        XCTAssertEqual(try machine.value(named: "Loaded"), .string("CLIP.OGG"))
        XCTAssertEqual(try machine.value(named: "After"), .string(""))
        XCTAssertEqual(try machine.value(named: "Filter"), .string("candidate-filter"))
        XCTAssertEqual(try machine.value(named: "ResetFilter"), .string(""))
    }

    func testLiveStreamFilterIssueRetainsTransientActiveChange() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/owned-stream-filter-tests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var ogg = Data("OggS".utf8) + Data(repeating: 0, count: 23)
        ogg[5] = 2; ogg[26] = 1; ogg.append(30)
        ogg.append(Data([1]) + Data("vorbis".utf8) + Data(repeating: 0, count: 23))
        try ogg.write(to: directory.appendingPathComponent("clip.ogg"))
        let script = #"""
        \scp,snd[0]
        \l,"clip.ogg"
        \fo,"pending"
        \fo,""
        \fo,"volume,vol:150"
        \fo,"volume,pan:25"
        \p
        \fo,"candidate-filter"
        \fo,""
        \wait,1
        """#
        let source = Data([0xef, 0xbb, 0xbf]) + Data(script.utf8)
        let root = ScriptModuleReference(logicalPath: "root.s", sourceFile: "root.s", sourceSHA256: source.sha256Hex)
        let clip = ScriptModuleReference(logicalPath: "clip.ogg", sourceFile: "clip.ogg", sourceSHA256: ogg.sha256Hex)
        let repository = try ScriptRepository(directory: SafeDirectory(directory), catalog: ScriptModuleCatalog(entries: [root, clip]))
        var machine = try ScriptMachine(program: ScriptProgram(ScriptDocument(data: source, relativePath: "root.s")),
                                        allowExperimental: true, repository: repository)
        try machine.run()
        XCTAssertEqual(machine.phase, .waitingForMedia)
        XCTAssertEqual(machine.researchLiveStreamFilterIssue, "live_audio_stream_filter_application_unverified")
        let volume = try XCTUnwrap(machine.researchActiveAudioSnapshots.first?.volumeFilterCandidate)
        XCTAssertEqual(volume, .init(volume: 150, pan: 25, range: 200))
        let channel = try XCTUnwrap(machine.soundPlaybackChannel)
        XCTAssertNil(machine.researchLiveStreamFilterIssue(accepting: [channel: volume]))
        XCTAssertNotNil(machine.researchLiveStreamFilterIssue(accepting: [channel: .init()]))
        try machine.acknowledgeSoundPlayback()
        try machine.run()
        XCTAssertEqual(machine.phase, .waiting)
        XCTAssertEqual(machine.researchLiveStreamFilterIssue, "live_audio_stream_filter_application_unverified")
        XCTAssertNotNil(machine.researchLiveStreamFilterIssue(accepting: [channel: volume]))

        let liveScript = script.replacingOccurrences(of: "candidate-filter", with: "volume,pan:75")
        let liveSource = Data([0xef, 0xbb, 0xbf]) + Data(liveScript.utf8)
        let liveRoot = ScriptModuleReference(logicalPath: "root.s", sourceFile: "root.s", sourceSHA256: liveSource.sha256Hex)
        let liveRepository = try ScriptRepository(directory: SafeDirectory(directory),
            catalog: ScriptModuleCatalog(entries: [liveRoot, clip]))
        var live = try ScriptMachine(program: ScriptProgram(ScriptDocument(data: liveSource, relativePath: "root.s")),
                                     allowExperimental: true, repository: liveRepository)
        live.allowLiveSoundFilterHandoff = true
        try live.run()
        try live.acknowledgeSoundPlayback()
        try live.run()
        XCTAssertEqual(live.phase, .waitingForSoundFilter)
        let request = try XCTUnwrap(live.soundFilterRequest)
        XCTAssertEqual(request.previous, .init(volume: 150, pan: 25, range: 200))
        XCTAssertEqual(request.updated, .init(volume: 150, pan: 75, range: 200))
        let invalid = ScriptMachine.SoundFilterRequest(channel: request.channel, source: request.source,
            playbackStep: request.playbackStep, previous: request.previous, updated: .init(), previousChain: nil)
        XCTAssertThrowsError(try live.acknowledgeSoundFilter(invalid))
        try live.acknowledgeSoundFilter(request)
        try live.run()
        XCTAssertEqual(live.phase, .waitingForSoundFilter)
        let cleared = try XCTUnwrap(live.soundFilterRequest)
        XCTAssertNil(cleared.updated)
        try live.acknowledgeSoundFilter(cleared)
        try live.run()
        XCTAssertEqual(live.phase, .waiting)
        XCTAssertNil(live.researchLiveStreamFilterIssue)
    }

    func testLiveStreamSwapRequiresMatchingHostAcknowledgement() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/owned-stream-swap-tests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var ogg = Data("OggS".utf8) + Data(repeating: 0, count: 23)
        ogg[5] = 2; ogg[26] = 1; ogg.append(30)
        ogg.append(Data([1]) + Data("vorbis".utf8) + Data(repeating: 0, count: 23))
        try ogg.write(to: directory.appendingPathComponent("clip.ogg"))
        let script = #"""
        \scp,snd[0]
        \l,"clip.ogg"
        \p
        \swap,snd[0],snd[1]
        \wait,1
        """#
        let source = Data([0xef, 0xbb, 0xbf]) + Data(script.utf8)
        let root = ScriptModuleReference(logicalPath: "root.s", sourceFile: "root.s", sourceSHA256: source.sha256Hex)
        let clip = ScriptModuleReference(logicalPath: "clip.ogg", sourceFile: "clip.ogg", sourceSHA256: ogg.sha256Hex)
        let repository = try ScriptRepository(directory: SafeDirectory(directory), catalog: ScriptModuleCatalog(entries: [root, clip]))
        var machine = try ScriptMachine(program: ScriptProgram(ScriptDocument(data: source, relativePath: "root.s")),
                                        allowExperimental: true, repository: repository)
        machine.allowLiveSoundSwapHandoff = true
        try machine.run()
        let originalChannel = try XCTUnwrap(machine.soundPlaybackChannel)
        let original = try XCTUnwrap(machine.activeStreamPlaybackSnapshots[originalChannel])
        try machine.acknowledgeSoundPlayback()
        try machine.run()
        XCTAssertEqual(machine.phase, .waitingForSoundSwap)
        let request = try XCTUnwrap(machine.soundSwapRequest)
        XCTAssertEqual(request.first, originalChannel)
        XCTAssertNil(machine.activeStreamPlaybackSnapshots[request.first])
        XCTAssertEqual(machine.activeStreamPlaybackSnapshots[request.second]?.source, original.source)
        XCTAssertEqual(machine.activeStreamPlaybackSnapshots[request.second]?.step, original.step)
        XCTAssertThrowsError(try machine.acknowledgeSoundSwap(.init(first: request.second, second: request.first)))
        XCTAssertEqual(machine.phase, .waitingForSoundSwap)
        try machine.acknowledgeSoundSwap(request)
        try machine.run()
        XCTAssertEqual(machine.phase, .waiting)

        var defaultMachine = try ScriptMachine(program: ScriptProgram(ScriptDocument(data: source, relativePath: "root.s")),
                                               allowExperimental: true, repository: repository)
        try defaultMachine.run()
        try defaultMachine.acknowledgeSoundPlayback()
        try defaultMachine.run()
        XCTAssertEqual(defaultMachine.phase, .waiting)
        XCTAssertNil(defaultMachine.soundSwapRequest)
    }

    func testDirectSoundRepeatLoadUpdatesTypeWithoutResettingVolume() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/owned-direct-sound-tests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wave = Data("RIFF0000WAVE".utf8)
        try wave.write(to: directory.appendingPathComponent("clip.wav"))
        let script = #"""
        \gvar,int,Type,Volume
        \scp,dsnd[12]
        \i
        \l,"clip.wav"
        \vtn,3
        \v,123
        \l,"clip.wav"
        \?vtn
        \cal,Type=ResultInt[0]
        \?v
        \cal,Volume=ResultInt[0]
        \wait,1
        """#
        let source = Data([0xef, 0xbb, 0xbf]) + Data(script.utf8)
        let root = ScriptModuleReference(logicalPath: "root.s", sourceFile: "root.s", sourceSHA256: source.sha256Hex)
        let clip = ScriptModuleReference(logicalPath: "clip.wav", sourceFile: "clip.wav", sourceSHA256: wave.sha256Hex)
        let repository = try ScriptRepository(directory: SafeDirectory(directory),
            catalog: ScriptModuleCatalog(entries: [root, clip]))
        var machine = try ScriptMachine(program: ScriptProgram(ScriptDocument(data: source, relativePath: "root.s")),
            allowExperimental: true, repository: repository)
        try machine.run()
        XCTAssertEqual(machine.phase, .waiting, machine.summary.stopReason ?? "unexpected phase")
        XCTAssertEqual(try machine.value(named: "Type"), .integer(2))
        XCTAssertEqual(try machine.value(named: "Volume"), .integer(123))
    }

    func testDirectSoundCooldownUsesSignedWrappingMilliseconds() {
        XCTAssertFalse(DirectSoundTiming.permitsPlayback(now: 149, previous: 100, lockMilliseconds: 50))
        XCTAssertTrue(DirectSoundTiming.permitsPlayback(now: 150, previous: 100, lockMilliseconds: 50))
        XCTAssertTrue(DirectSoundTiming.permitsPlayback(now: 30, previous: UInt32.max - 20, lockMilliseconds: 50))
        XCTAssertFalse(DirectSoundTiming.permitsPlayback(now: 0x80000000, previous: 0, lockMilliseconds: 50))
    }

    func testStreamChannelObservedUpperBound() throws {
        let storage = ScriptStorage()
        guard case .object(let handle) = try storage.readIndexed("snd", 31) else {
            return XCTFail("stream handle expected")
        }
        XCTAssertEqual(ScriptStorage.streamChannelIndex(handle), 31)
        XCTAssertThrowsError(try storage.readIndexed("snd", 32))
    }

    func testMoviePlaybackVolumeUsesConfiguredSlotAndMute() throws {
        var storage = ScriptStorage()
        var movie = ScriptStorage.MovieObject()
        XCTAssertEqual(try storage.effectiveMovieVolume(movie), 256)
        movie.volumeTarget = 5
        movie.volume = 192
        storage.configVoiceValues[5] = 128
        XCTAssertEqual(try storage.effectiveMovieVolume(movie), 96)
        storage.configVoiceModes[5] = 1
        XCTAssertEqual(try storage.effectiveMovieVolume(movie), 0)
        movie.volumeTarget = 32
        XCTAssertThrowsError(try storage.effectiveMovieVolume(movie))

        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/owned-movie-tests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var page = Data("OggS".utf8) + Data(repeating: 0, count: 23)
        page[5] = 2
        page[26] = 1
        page.append(42)
        var packet = Data([0x80]) + Data("theora".utf8) + Data(repeating: 0, count: 35)
        packet[15] = 5
        packet[18] = 2
        packet[19] = 208
        page.append(packet)
        try page.write(to: directory.appendingPathComponent("clip.ogv"))
        let script = #"""
        \gvar,theora,Movie
        \scp,cfg
        \vtv,5,128
        \scp,Movie
        \i
        \l,"clip.ogv",1
        \vtn,5
        \v,192
        \pp,0,0,0
        \e
        \p
        """#
        let source = Data([0xef, 0xbb, 0xbf]) + Data(script.utf8)
        let root = ScriptModuleReference(logicalPath: "root.s", sourceFile: "root.s", sourceSHA256: source.sha256Hex)
        let clip = ScriptModuleReference(logicalPath: "clip.ogv", sourceFile: "clip.ogv", sourceSHA256: page.sha256Hex)
        let catalog = try ScriptModuleCatalog(entries: [root, clip])
        let repository = try ScriptRepository(directory: SafeDirectory(directory), catalog: catalog)
        var machine = try ScriptMachine(program: ScriptProgram(ScriptDocument(data: source, relativePath: "root.s")),
                                        allowExperimental: true, repository: repository)
        try machine.run()
        XCTAssertEqual(machine.moviePlaybackRequest?.volume, 96, "\(machine.summary.stopReason ?? "missing request") \(machine.traces.suffix(4))")
    }

    func testStandaloneTheoraImageDimensionsRequireMatchingHeader() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/owned-image-tests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var page = Data("OggS".utf8) + Data(repeating: 0, count: 23)
        page[5] = 2
        page[26] = 1
        page.append(42)
        var packet = Data([0x80]) + Data("theora".utf8) + Data(repeating: 0, count: 35)
        packet[15] = 5
        packet[18] = 2
        packet[19] = 208
        page.append(packet)
        try page.write(to: directory.appendingPathComponent("clip.ogv"))
        let script = #"""
        \gvar,img,Picture
        \gvar,int,Width,Height
        \scp,Picture
        \l,"clip.ogv"
        \?wh
        \cal,Width=ResultInt[0]
        \cal,Height=ResultInt[1]
        \wait,1
        """#
        let source = Data([0xef, 0xbb, 0xbf]) + Data(script.utf8)
        let root = ScriptModuleReference(logicalPath: "root.s", sourceFile: "root.s", sourceSHA256: source.sha256Hex)
        let clip = ScriptModuleReference(logicalPath: "clip.ogv", sourceFile: "clip.ogv", sourceSHA256: page.sha256Hex)
        let catalog = try ScriptModuleCatalog(entries: [root, clip])
        let program = try ScriptProgram(ScriptDocument(data: source, relativePath: "root.s"))
        let repository = try ScriptRepository(directory: SafeDirectory(directory), catalog: catalog)
        var machine = try ScriptMachine(program: program, allowExperimental: true, repository: repository,
                                        imageLoader: { _ in (1280, 720, 1) })
        try machine.run()
        XCTAssertEqual(machine.phase, .waiting, machine.summary.stopReason ?? "unexpected phase")
        XCTAssertEqual(try machine.value(named: "Width"), .integer(1280))
        XCTAssertEqual(try machine.value(named: "Height"), .integer(720))
        var mismatched = try ScriptMachine(program: program, allowExperimental: true, repository: repository,
                                           imageLoader: { _ in (640, 720, 1) })
        try mismatched.run()
        XCTAssertEqual(mismatched.summary.stopReason, "theora_image_header_dimensions_mismatch")

        let timingScript = #"""
        \gvar,img,Picture
        \scp,Picture
        \l,"clip.ogv"
        \p,0,0,0
        \wait,1
        \e
        \wait,1
        \d
        \wait,1
        \e
        \wait,1
        """#
        let timingBytes = Data([0xef, 0xbb, 0xbf]) + Data(timingScript.utf8)
        let timingRoot = ScriptModuleReference(logicalPath: "root.s", sourceFile: "root.s", sourceSHA256: timingBytes.sha256Hex)
        let timingRepository = try ScriptRepository(directory: SafeDirectory(directory),
            catalog: ScriptModuleCatalog(entries: [timingRoot, clip]))
        var timing = try ScriptMachine(program: ScriptProgram(ScriptDocument(data: timingBytes, relativePath: "root.s")),
                                       allowExperimental: true, repository: timingRepository,
                                       imageLoader: { _ in (1280, 720, 1) })
        try timing.run()
        timing.advanceVisualClock(ticks: 500)
        try timing.advanceClickWait(ticks: 1)
        try timing.run()
        var layer = try XCTUnwrap(timing.staticImageLayers.first)
        XCTAssertEqual(layer.selectedMember, 0)
        XCTAssertEqual(layer.motionElapsedTicks, 0)
        timing.advanceVisualClock(ticks: 200)
        layer = try XCTUnwrap(timing.staticImageLayers.first)
        XCTAssertEqual(layer.motionElapsedTicks, 200)
        try timing.advanceClickWait(ticks: 1)
        try timing.run()
        timing.advanceVisualClock(ticks: 500)
        try timing.advanceClickWait(ticks: 1)
        try timing.run()
        layer = try XCTUnwrap(timing.staticImageLayers.first)
        XCTAssertEqual(layer.motionElapsedTicks, 200)
        timing.advanceVisualClock(ticks: 100)
        XCTAssertEqual(try XCTUnwrap(timing.staticImageLayers.first).motionElapsedTicks, 300)
    }

    func testConfigVolumeAndMuteQueriesRespectSlots() throws {
        let machine = try run(#"""
        \gvar,int,Default,Volume,Missing,Mode,ModeZero
        \scp,cfg
        \?vtv,5
        \cal,Default=ResultInt[0]
        \vtv,5,173
        \?vtv,5
        \cal,Volume=ResultInt[0]
        \?vtv,32
        \cal,Missing=ResultInt[0]
        \vtm,5,7
        \?vtm,5
        \cal,Mode=ResultInt[0]
        \vtm,0,9
        \?vtm,0
        \cal,ModeZero=ResultInt[0]
        \wait,1
        """#)
        XCTAssertEqual(try machine.value(named: "Default"), .integer(256))
        XCTAssertEqual(try machine.value(named: "Volume"), .integer(173))
        XCTAssertEqual(try machine.value(named: "Missing"), .integer(0))
        XCTAssertEqual(try machine.value(named: "Mode"), .integer(7))
        XCTAssertEqual(try machine.value(named: "ModeZero"), .integer(0))
    }

    func testBarLockAndQueryUseExactOne() throws {
        var bar = ScriptStorage.BarObject()
        bar.setImmediatePlacement([0, 0, 0])
        XCTAssertFalse(bar.placementSet)
        bar.setImmediatePlacement([210, 92, 110])
        bar.setImmediatePlacement([210, 92, 110])
        XCTAssertTrue(bar.placementSet)
        bar.setLock(false)
        XCTAssertFalse(bar.lockStateChanged)
        bar.setLock(true)
        bar.setLock(false)
        XCTAssertFalse(bar.locked)
        XCTAssertTrue(bar.lockStateChanged)
        let machine = try run(#"""
        \gvar,int,First,Second,Third
        \gvar,bar,Control
        \scp,Control
        \lk,1
        \?lk
        \cal,First=ResultInt[0]
        \lk,2
        \?lk
        \cal,Second=ResultInt[0]
        \lk,0
        \?lk
        \cal,Third=ResultInt[0]
        \wait,1
        """#)
        XCTAssertEqual(try machine.value(named: "First"), .integer(1))
        XCTAssertEqual(try machine.value(named: "Second"), .integer(0))
        XCTAssertEqual(try machine.value(named: "Third"), .integer(0))
    }

    func testBarPlacementWithoutFourthNativeArgumentIsHandledWithoutWriteCandidate() throws {
        let missingArgument = try run(#"""
        \gvar,bar,Control
        \scp,Control
        \p,210,92,110
        \wait,1
        """#)
        XCTAssertEqual(missingArgument.phase, .waiting)
        XCTAssertNil(missingArgument.stopReason)
        XCTAssertEqual(missingArgument.traces.first(where: { $0.command == "p" })?.action,
                       "bar_placement_missing_argument_handled_candidate")
        XCTAssertTrue(missingArgument.traces.contains(where: { $0.command == "wait" }))

        let presentArgument = try run(#"""
        \gvar,bar,Control
        \scp,Control
        \p,210,92,110,0
        \wait,1
        """#)
        XCTAssertEqual(presentArgument.phase, .waiting)
        XCTAssertEqual(presentArgument.traces.first(where: { $0.command == "p" })?.action,
                       "bar_placement_candidate")
    }

    func testBarUserIntegersAndChangeResultConsumption() throws {
        let machine = try run(#"""
        \gvar,int,First,Third
        \gvar,bar,Control
        \scp,Control
        \ui,7,,9
        \?ui
        \cal,First=ResultInt[0],Third=ResultInt[2]
        \wait,1
        """#)
        XCTAssertEqual(try machine.value(named: "First"), .integer(7))
        XCTAssertEqual(try machine.value(named: "Third"), .integer(9))

        var storage = ScriptStorage()
        try storage.declare("Control", category: "gvar", type: "bar")
        guard case .object(let handle) = try storage.read("Control") else { return XCTFail("missing bar") }
        try storage.declare("Second", category: "gvar", type: "bar")
        guard case .object(let second) = try storage.read("Second") else { return XCTFail("missing second bar") }
        storage.bars[second]?.userStrings[0] = "@@!Second"
        storage.bars[second]?.changeCyclesRemaining = 4
        storage.bars[handle]?.userStrings[0] = "@@!Seek"
        storage.bars[handle]?.userIntegers[0] = 37
        storage.bars[handle]?.changeCyclesRemaining = 4
        try storage.setBarChangeResults()
        XCTAssertEqual(try storage.readIndexed("ResultObj", 0), .object(handle))
        XCTAssertEqual(try storage.readIndexed("ResultStr", 0), .string("@@!Seek"))
        XCTAssertEqual(try storage.readIndexed("ResultInt", 0), .integer(37))
        XCTAssertEqual(storage.bars[handle]?.changeCyclesRemaining, 0)
        XCTAssertEqual(storage.bars[second]?.changeCyclesRemaining, 4)
        try storage.setBarChangeResults()
        XCTAssertEqual(try storage.readIndexed("ResultObj", 0), .object(second))
        XCTAssertEqual(try storage.readIndexed("ResultStr", 0), .string("@@!Second"))
        XCTAssertEqual(storage.bars[second]?.changeCyclesRemaining, 0)
        try storage.setBarChangeResults()
        XCTAssertEqual(try storage.readIndexed("ResultObj", 0), .object(ScriptStorage.nullHandle))
    }

    func testEmptyBarChangeQueryWorksInStopCallback() throws {
        let program = try ScriptProgram(document(#"""
        \gvar,int,NoChange
        \stop,@@!OnStop
        \wait,1
        @@!OnStop
        \scp,inp
        \gsc
        \if,ResultObj[0]==null\then
          \cal,NoChange=1
        \end
        \play
        \ret
        """#))
        var machine = try ScriptMachine(program: program, allowExperimental: true)
        try machine.run()
        try machine.dispatchStopCallback()
        try machine.run()
        XCTAssertEqual(try machine.value(named: "NoChange"), .integer(1))
    }

    func testBarTracksValueAndRejectsUnimplementedEnable() throws {
        let machine = try run(#"""
        \gvar,int,Observed,Clamped,Immediate
        \gvar,bar,Control
        \scp,Control
        \mv,10
        \v,20
        \?v
        \cal,Observed=ResultInt[0]
        \vt,100
        \v,8,2
        \?v
        \cal,Immediate=ResultInt[0]
        \p,1,2,3
        \us,"@@!Changed"
        \mv,5
        \?v
        \cal,Clamped=ResultInt[0]
        \e
        """#)
        XCTAssertEqual(try machine.value(named: "Observed"), .integer(10))
        XCTAssertEqual(try machine.value(named: "Immediate"), .integer(8))
        XCTAssertEqual(try machine.value(named: "Clamped"), .integer(5))
        XCTAssertEqual(machine.summary.stopReason, "bar_rendering_and_input_unsupported")
        let transition = try run(#"""
        \gvar,int,Observed
        \gvar,bar,Control
        \scp,Control
        \us,"@@!Changed"
        \vt,100
        \v,1,0
        \?v
        \cal,Observed=ResultInt[0]
        \wait,1
        """#)
        XCTAssertEqual(try transition.value(named: "Observed"), .integer(1))
    }
    func testSourceVisitsAreOptInAndReferenceExecutedRecords() throws {
        let program = try ScriptProgram(document("\\cal,1\n\\cal,2\n"))
        var disabled = try ScriptMachine(program: program, allowExperimental: true)
        try disabled.run()
        XCTAssertNil(disabled.summary.sourceVisits)
        var enabled = try ScriptMachine(program: program, allowExperimental: true)
        enabled.captureSourceVisits = true
        enabled.coverageSourceFile = "owned/scene.s"
        try enabled.run()
        let visits = try XCTUnwrap(enabled.summary.sourceVisits)
        XCTAssertEqual(visits.count, 1)
        XCTAssertEqual(visits[0].firstStep, enabled.traces.first?.sequence)
        XCTAssertEqual(visits[0].firstLocation, enabled.traces.first?.location)
        XCTAssertEqual(visits[0].entries, 1)
        XCTAssertEqual(enabled.summary.sourceVisitsTruncated, false)
        let coverage = try XCTUnwrap(enabled.summary.sourceCoverage)
        XCTAssertEqual(coverage.sourceFile, "owned/scene.s")
        XCTAssertFalse(coverage.truncated)
        XCTAssertEqual(coverage.entries.map(\.location), enabled.traces.filter { $0.recordType == .command }.map(\.location))
        XCTAssertTrue(coverage.entries.allSatisfy { $0.executions == 1 })
    }
    func testReaderAdvanceFastPathPreservesTraceAndCoverage() throws {
        let program = try ScriptProgram(document("@@Start\n\n  \n// comment\n\\cal,1\n"))
        var fast = try ScriptMachine(program: program, allowExperimental: true)
        var reference = fast
        fast.captureSourceVisits = true; reference.captureSourceVisits = true
        fast.coverageSourceFile = "owned/scene.s"; reference.coverageSourceFile = "owned/scene.s"
        reference.allowLabelProgressCandidate = true
        try fast.run(); try reference.run()
        XCTAssertEqual(fast.phase, .finished)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(try encoder.encode(fast.traces), try encoder.encode(reference.traces))
        XCTAssertEqual(try encoder.encode(fast.summary.sourceCoverage), try encoder.encode(reference.summary.sourceCoverage))
        XCTAssertEqual(try encoder.encode(fast.summary.sourceVisits), try encoder.encode(reference.summary.sourceVisits))
    }
    func value(_ text: String, reads: @escaping (String) throws -> ScriptValue = { _ in throw ResourceError.rejected("unbound") }) throws -> ScriptValue {
        try ScriptExpression.parse(text).evaluate(read: reads,write: { _,_ in throw ResourceError.rejected("unexpected_write") })
    }

    func testCP932AliasOriginalByteSpansAndSingleByteExtensions() throws {
        let bytes = Data([0xfa,0x40,0x81,0x60,0x80,0xa0,0xfd,0xfe,0xff])
        let source = try ScriptSource(data: bytes,relativePath: "owned.s")
        XCTAssertEqual(source.scalars.map { $0.value.value }, [0x2170,0xff5e,0x80,0xf8f0,0xf8f1,0xf8f2,0xf8f3])
        XCTAssertEqual(source.scalars.map(\.bytes), [0..<2,2..<4,4..<5,5..<6,6..<7,7..<8,8..<9])
        XCTAssertEqual(source.encodingStatus,.inferred)
    }
    func testUTF16SurrogateBoundariesAndFieldLocations() throws {
        let text = "\\cal,\"字😀\"\r\n\\ret"
        for (bom,encoding) in [(Data([0xff,0xfe]),String.Encoding.utf16LittleEndian),(Data([0xfe,0xff]),.utf16BigEndian)] {
            let data = bom + text.data(using: encoding)!
            let doc = try ScriptDocument(data: data,relativePath: "owned.s")
            let scalar = try XCTUnwrap(doc.source.scalars.first { $0.value.value == 0x1f600 })
            XCTAssertEqual(scalar.bytes.count,4)
            let field = try XCTUnwrap(doc.records.first { $0.command == "cal" }?.fields.first)
            XCTAssertEqual(field.raw,"\"字😀\""); XCTAssertEqual(field.location.byteLength,10)
            XCTAssertEqual(field.location.rangeSHA256,data.subdata(in: field.location.byteOffset..<field.location.byteOffset+field.location.byteLength).sha256Hex)
            XCTAssertEqual(doc.records.first { $0.command == "ret" }?.location.lineNumber,2)
        }
    }
    func testInlineCommandsQuotedBackslashesAndSparseFields() throws {
        let doc = try document("\\sub,@@Own,,\"C:\\owned\\image.png\" \\cal,1\n")
        let commands = doc.records.filter { $0.kind == .command }
        XCTAssertEqual(commands.map(\.command),["sub","cal"])
        XCTAssertEqual(commands[0].fields.count,3); XCTAssertEqual(commands[0].fields[1].raw,"")
        XCTAssertEqual(commands[0].fields[2].value,"C:\\owned\\image.png")
        XCTAssertEqual(commands[0].fields[1].location.byteLength,0)
    }
    func testSignedFieldCounterMatchesReviewedModelNotBracketStack() throws {
        let doc = try document("\\own,(1,2),x \\own,],a,b")
        let rows = doc.records.filter { $0.kind == .command }
        XCTAssertEqual(rows[0].fields.map(\.raw),["(1,2)","x"])
        XCTAssertEqual(rows[1].fields.map(\.raw),["]","a","b"])
    }
    func testSourceRecordCoverageIncludesBOMLayoutAndBlankRuns() throws {
        let doc = try document("\n \n@@Own\r\n  \\cal,1  \\cal,2\r\n\n")
        var cursor = 0
        for record in doc.records {
            XCTAssertEqual(record.location.byteOffset,cursor)
            cursor += record.location.byteLength
        }
        XCTAssertEqual(cursor,doc.source.data.count)
        XCTAssertEqual(doc.records.first { $0.kind == .empty }?.lineCount,2)
        XCTAssertEqual(doc.records.first?.kind,.bom)
    }
    func testInvalidEncodingsControlsPathsQuotesAndFieldCapsAreRejected() throws {
        for data in [Data([0x81]),Data([0x81,0x7f]),Data([0xff,0xfe,0x00]),Data([0xff,0xfe,0x00,0xd8]),Data([0x00]),Data([0xef,0xbb,0xbf,0xff])] {
            XCTAssertThrowsError(try ScriptDocument(data: data,relativePath: "owned.s"))
        }
        XCTAssertThrowsError(try ScriptDocument(data: Data(),relativePath: "../owned.s"))
        XCTAssertThrowsError(try document("\\cal,\"unclosed"))
        XCTAssertThrowsError(try document("\\own," + Array(repeating: "x",count: 4096).joined(separator: ",")))
        XCTAssertThrowsError(try document("\\own," + String(repeating: "(",count: 65)))
    }
    func testEmptyAndBOMOnlySourcesRemainDistinct() throws {
        XCTAssertTrue(try ScriptDocument(data: Data(),relativePath: "owned.s").records.isEmpty)
        XCTAssertEqual(try ScriptDocument(data: Data([0xff,0xfe]),relativePath: "owned.s").records.map(\.kind),[.bom])
    }
    func testSingleLineFragmentBudgetIsEnforcedBeforeBuildingAllRecords() throws {
        XCTAssertThrowsError(try document(String(repeating: "\\x",count: 200_001))) { error in
            XCTAssertEqual(String(describing: error),"script_fragment_limit")
        }
    }
    func testIntegerLiteralBoundariesAndHexBits() throws {
        XCTAssertEqual(try ScriptExpression.integerLiteral("$FFFFFFFF"),-1)
        XCTAssertEqual(try ScriptExpression.integerLiteral("-$FFFFFFFF"),1)
        XCTAssertEqual(try value("-2147483648"),.integer(.min))
        for raw in ["2147483648","4294967295","$100000000","12x","0x",""] {
            XCTAssertThrowsError(try ScriptExpression.integerLiteral(raw))
        }
    }
    func testOperatorGroupsAndLeftAssociationAreNotHostLanguageDefaults() throws {
        XCTAssertEqual(try value("1||0&&0"),.integer(0))
        XCTAssertEqual(try value("8^3&1"),.integer(1))
        XCTAssertEqual(try value("10-3-2"),.integer(5))
        XCTAssertEqual(try value("2+3*4"),.integer(14))
    }
    func testLogicalOperatorsEagerlyResolveBothSidesAndRequireOne() throws {
        var reads: [String] = []
        XCTAssertEqual(try value("a&&b",reads: { reads.append($0); return .integer($0 == "a" ? 0 : 1) }),.integer(0))
        XCTAssertEqual(reads,["a","b"])
        XCTAssertEqual(try value("2||0"),.integer(0))
        XCTAssertThrowsError(try value("0&&unbound"))
    }
    func testUnsafeOrUnreviewedExpressionFormsNeverSilentlyCoerce() throws {
        for text in ["","x++","++x","a[0][0]","a.b","fn(1)","x=(y=1)","(x=1)+x","^1"] {
            XCTAssertThrowsError(try ScriptExpression.parse(text),text)
        }
        for text in ["2147483647+1","1/0","-2147483648/-1","1.5"] {
            XCTAssertThrowsError(try value(text),text)
        }
        XCTAssertEqual(try value("\"a\"+\"b\""), .string("ab"))
        XCTAssertThrowsError(try ScriptExpression.parse(Array(repeating: "1",count: 100).joined(separator: "+")))
    }
    func testLeftShiftUsesX86CountMask() throws {
        XCTAssertEqual(try value("1<<34"), .integer(4))
    }
    func testAssignmentReturnsOneAndNeedsAnExistingTypedScalar() throws {
        let machine = try run("\\var,int,count\n\\cal,count=7")
        XCTAssertEqual(try machine.value(named: "COUNT"),.integer(7)); XCTAssertEqual(machine.lastResult,.integer(1))
        XCTAssertEqual(try run("\\cal,count=7").stopReason,"assignment_target_not_declared")
        let mismatch = try run("\\var,int,count\n\\cal,count=\"private content\"")
        XCTAssertEqual(mismatch.phase,.finished); XCTAssertEqual(try mismatch.value(named: "count"),.integer(0))
    }
    func testRedeclarationKeepsExistingVisibleBindingAndCategory() throws {
        let machine = try run("\\svar,int,x\n\\cal,x=1\n\\gvar,int,x\n\\cal,x=2\n\\var,int,x\n\\cal,x=3")
        XCTAssertEqual(try machine.value(named: "x"),.integer(3))
        XCTAssertEqual(machine.summary.variableCounts,["system":1,"global":0,"all_local_frames":0])
    }
    func testHashSigilIsRetainedAsPartOfScalarIdentity() throws {
        let machine = try run("\\svar,int,#counter\n\\cal,#counter=#counter+1\n\\var,int,counter\n\\cal,counter=9")
        XCTAssertEqual(try machine.value(named: "#COUNTER"),.integer(1))
        XCTAssertEqual(try machine.value(named: "counter"),.integer(9))
    }
    func testLabelLogInitializePreservesValuesAndUnknownReadStatusStops() throws {
        let machine = try run(#"""
        \gvar,int,Found,Missing,Empty
        \scp,llog
        \lk,1
        \s,"MiXeD",321
        \i
        \?g,"mixed"
        \cal,Found=ResultInt[0]
        \?g,"absent"
        \cal,Missing=ResultInt[0]
        \s,"",7
        \?g,""
        \cal,Empty=ResultInt[0]
        \?k2
        """#)
        XCTAssertEqual(try machine.value(named: "Found"), .integer(321))
        XCTAssertEqual(try machine.value(named: "Missing"), .integer(-1))
        XCTAssertEqual(try machine.value(named: "Empty"), .integer(-1))
        XCTAssertEqual(machine.stopReason, "label_read_status_unsupported")
        let fresh = try run("\\scp,llog\n\\?k2")
        XCTAssertEqual(fresh.stopReason, "label_read_status_unsupported")
        XCTAssertFalse(fresh.traces.contains { $0.action == "fresh_session_unread_status_candidate" })
        let document = try ScriptDocument(data: Data("\\scp,llog\n\\?k2".utf8), relativePath: "fresh.s")
        var research = try ScriptMachine(program: ScriptProgram(document), allowExperimental: true)
        research.allowLabelHistoryCandidate = true
        try research.run()
        XCTAssertEqual(research.phase, .finished)
        XCTAssertTrue(research.traces.contains { $0.action == "fresh_session_unread_status_candidate" })
    }
    func testPendingSentenceBlankPrefixAfterCommand() throws {
        let machine = try run(#"""
        @@Root
        \gvar,int,Imo_SentenceFlag,Calls
        \scp,rep
        \nt,"\subp,@@!Blank"
        \scp,
        \cal,Imo_SentenceFlag=1
        \cal,Calls=2

        \jmp,@@!Done
        @@!Blank
        \cal,Calls=Calls+1
        \cal,Imo_SentenceFlag=0
        \ret
        @@!Done
        """#)
        XCTAssertEqual(machine.phase, .finished)
        XCTAssertEqual(try machine.value(named: "Calls"), .integer(3))
        XCTAssertTrue(machine.traces.contains { $0.action == "blank_line_prefix_call_candidate" })
        let internalLabel = try run(#"""
        @@!Root
        \gvar,int,Imo_SentenceFlag,Calls
        \scp,rep
        \nt,"\subp,@@!Blank"
        \scp,
        \cal,Imo_SentenceFlag=1

        \cal,Imo_SentenceFlag=0
        \jmp,@@!Done
        @@!Blank
        \cal,Calls=1
        \ret
        @@!Done
        """#)
        XCTAssertEqual(internalLabel.phase, .finished)
        XCTAssertEqual(try internalLabel.value(named: "Calls"), .integer(0))
        XCTAssertFalse(internalLabel.traces.contains { $0.action == "blank_line_prefix_call_candidate" })
        let noSentenceFlag = try run(#"""
        @@Root
        \gvar,int,Calls
        \scp,rep
        \nt,"\subp,@@!Blank"
        \scp,

        \jmp,@@!Done
        @@!Blank
        \cal,Calls=Calls+1
        \ret
        @@!Done
        """#)
        XCTAssertEqual(noSentenceFlag.phase, .finished)
        XCTAssertEqual(try noSentenceFlag.value(named: "Calls"), .integer(1))
        let recursive = try run(#"""
        @@Root
        \gvar,int,Calls
        \scp,rep
        \nt,"\subp,@@Blank"
        \scp,

        \jmp,@@!Done
        @@Blank
        \cal,Calls=Calls+1

        \ret
        @@!Done
        """#)
        XCTAssertEqual(recursive.stopReason, "blank_line_prefix_recursive_unsupported")
    }
    func testRepeatedBlankPrefixUsesDistinctPhysicalLines() throws {
        let machine = try run(#"""
        @@Root
        \gvar,int,Imo_SentenceFlag,Calls
        \scp,rep
        \nt,"\subp,@@!Blank"
        \scp,
        \cal,Imo_SentenceFlag=1



        \jmp,@@!Done
        @@!Blank
        \if,Imo_SentenceFlag==0\then
        \ret
        \end
        \cal,Calls=Calls+1
        \if,Calls==2\then
        \cal,Imo_SentenceFlag=0
        \end
        \ret
        @@!Done
        """#)
        let calls = machine.traces.filter { $0.action == "blank_line_prefix_call_candidate" }
        XCTAssertEqual(machine.phase, .finished)
        XCTAssertEqual(try machine.value(named: "Calls"), .integer(2))
        XCTAssertEqual(calls.count, 3)
        if calls.count == 3 {
            XCTAssertEqual(calls[1].location.lineNumber, calls[0].location.lineNumber + 1)
            XCTAssertEqual(calls[2].location.lineNumber, calls[1].location.lineNumber + 1)
            XCTAssertGreaterThan(calls[1].location.byteOffset, calls[0].location.byteOffset)
        }
    }
    func testFileLogInitializePreservesEntriesUntilExplicitClear() throws {
        let machine = try run(#"""
        \gvar,int,Before,After
        \scp,flog
        \s,"file.s",123
        \lk,1
        \i
        \?g,"file.s"
        \cal,Before=ResultInt[0]
        \cc
        \?g,"file.s"
        \cal,After=ResultInt[0]
        """#)
        XCTAssertEqual(machine.phase, .finished)
        XCTAssertEqual(try machine.value(named: "Before"), .integer(123))
        XCTAssertEqual(try machine.value(named: "After"), .integer(-1))
    }
    func testFileLogPathsNormalizeDeduplicateAndRemove() throws {
        var storage = ScriptStorage()
        try storage.addFileLogPath("Folder/Scene.S")
        try storage.addFileLogPath("folder/scene.s")
        try storage.addFileLogPath("\u{00e9}.s")
        try storage.addFileLogPath("e\u{0301}.s")
        XCTAssertEqual(storage.fileLogPaths.count, 3)
        XCTAssertEqual(storage.fileLogPaths.first, "folder/scene.s")
        storage.removeFileLogPath("FOLDER/SCENE.S")
        storage.removeFileLogPath("missing.s")
        XCTAssertEqual(storage.fileLogPaths.count, 2)
        let machine = try run("\\scp,flog\n\\a,\"Scene.S\"\n\\d,\"scene.s\"")
        XCTAssertEqual(machine.phase, .finished)
        XCTAssertTrue(machine.traces.contains { $0.action == "file_log_path_remove_candidate" })
    }
    func testImageFileLogCandidateMatchesRegisteredPathAndHonorsLock() throws {
        var storage = ScriptStorage()
        try storage.addFileLogPath("CG\\Scene")
        storage.fileLogLocked = false
        let key = Data("cg\\scene\\image.png".utf8)
        XCTAssertEqual(try storage.recordImageFileLogCandidate("CG/Scene/Image.PNG"), .matched)
        try storage.recordImageFileLogCandidate("cg/scene/image.png")
        XCTAssertEqual(storage.fileLogValues[key], 2)
        let snapshot = storage.fileLogPatternSnapshot()
        XCTAssertEqual(snapshot.registeredPaths, 1)
        XCTAssertEqual(snapshot.matchingEntries, 1)
        XCTAssertFalse(snapshot.truncated)
        XCTAssertEqual(try storage.recordImageFileLogCandidate("other/image.png"), .noMatch)
        try storage.recordImageFileLogCandidate("$$$cg/scene/image.png")
        XCTAssertEqual(storage.fileLogValues.count, 1)
        storage.fileLogLocked = true
        XCTAssertEqual(try storage.recordImageFileLogCandidate("cg/scene/image.png"), .locked)
        XCTAssertEqual(storage.fileLogValues[key], 2)
        storage.fileLogLocked = false
        storage.fileLogValues[key] = 0x0fffffff
        try storage.recordImageFileLogCandidate("cg/scene/image.png")
        XCTAssertEqual(storage.fileLogValues[key], 0x0fffffff)
        storage.fileLogValues[key] = -12
        try storage.recordImageFileLogCandidate("cg/scene/image.png")
        XCTAssertEqual(storage.fileLogValues[key], 1)
        var rooted = ScriptStorage()
        try rooted.addFileLogPath("\\\\cg\\scene\\")
        rooted.fileLogLocked = false
        XCTAssertEqual(try rooted.recordImageFileLogCandidate("cg/scene/image.png"), .matched)
        XCTAssertEqual(rooted.fileLogValues[key], 1)
    }
    func testLabelLogClearAndBothLockQueriesUseFileLock() throws {
        let machine = try run(#"""
        \gvar,int,FileLock,LabelLock,AfterClear,ResetLock
        \scp,flog
        \i
        \lk,1
        \?lk
        \cal,FileLock=ResultInt[0]
        \scp,llog
        \lk,0
        \?lk
        \cal,LabelLock=ResultInt[0]
        \s,"entry",17
        \cc
        \?g,"entry"
        \cal,AfterClear=ResultInt[0]
        \scp,flog
        \i
        \?lk
        \cal,ResetLock=ResultInt[0]
        """#)
        XCTAssertEqual(machine.phase, .finished)
        XCTAssertEqual(try machine.value(named: "FileLock"), .integer(1))
        XCTAssertEqual(try machine.value(named: "LabelLock"), .integer(1))
        XCTAssertEqual(try machine.value(named: "AfterClear"), .integer(-1))
        XCTAssertEqual(try machine.value(named: "ResetLock"), .integer(0))
    }
    func testLabelHistoryCountsSimpleIncludeAndRejectsChildLabels() throws {
        func probe(_ childText: String?) throws -> LabelHistoryProbe.Frame {
            let source = try document(childText == nil ? "@@Scene\n\\unknown" : "@@Scene\n@@@child.s\n\\unknown")
            var records = source.records, sources: [Data: ScriptSource] = [:]
            if let childText {
                let child = try ScriptDocument(data: Data(childText.utf8), relativePath: "owned/child.s")
                let marker = try XCTUnwrap(records.firstIndex { $0.kind == .include })
                records.insert(contentsOf: child.records, at: marker + 1)
                sources[Data(child.source.relativePath.utf8)] = child.source
            }
            let expanded = ScriptDocument(expandedSource: source.source, records: records)
            let program = try ScriptProgram(expanded, sources: sources, includesExpanded: true)
            var machine = try ScriptMachine(program: program, allowExperimental: true)
            try machine.run()
            return try XCTUnwrap(machine.labelHistoryProbe.frames.first)
        }
        XCTAssertEqual(try probe(nil).relativeLine, 1)
        XCTAssertEqual(try probe("// one\n\n// two\n").relativeLine, 4)
        let withinChild = try probe("// one\n\\unknown\n")
        XCTAssertEqual(withinChild.nearestLabel?.sourceFile, "owned/scene.s")
        XCTAssertEqual(withinChild.relativeLine, 2)
        XCTAssertNil(try probe("@@Child\n// text\n").relativeLine)
        XCTAssertNil(try probe("@@@nested.s\n// text\n").relativeLine)
        // A foreign record without an include marker is not a simple span,
        // even after execution returns to the anchor's physical source.
        let parent = try document("@@Scene\n\\unknown")
        let child = try ScriptDocument(data: Data("// foreign\n".utf8), relativePath: "owned/child.s")
        var mixed = parent.records
        let label = try XCTUnwrap(mixed.firstIndex { $0.kind == .label })
        mixed.insert(contentsOf: child.records, at: label + 1)
        let expanded = ScriptDocument(expandedSource: parent.source, records: mixed)
        let program = try ScriptProgram(expanded, sources: [Data(child.source.relativePath.utf8): child.source], includesExpanded: true)
        let command = try XCTUnwrap(mixed.lastIndex { $0.command == "unknown" })
        XCTAssertNil(program.candidateLabelRelativeLine(anchor: label, position: command))
    }
    func testLabelProgressRejectsForeignRecordWithoutInclude() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/owned-label-progress-tests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let parentData = Data("@@Scene\n\\gvar,int,x\n\\cal,x=1\n\\wait,1\n".utf8)
        let parent = try ScriptDocument(data: parentData, relativePath: "root.s")
        let child = try ScriptDocument(data: Data("// foreign\n".utf8), relativePath: "child.s")
        var mixed = parent.records
        let label = try XCTUnwrap(mixed.firstIndex { $0.kind == .label })
        mixed.insert(contentsOf: child.records, at: label + 1)
        let expanded = ScriptDocument(expandedSource: parent.source, records: mixed)
        let program = try ScriptProgram(expanded, sources: [Data("child.s".utf8): child.source], includesExpanded: true)
        let root = ScriptModuleReference(logicalPath: "root.s", sourceFile: "root.s", sourceSHA256: parentData.sha256Hex)
        let repository = try ScriptRepository(directory: SafeDirectory(directory), catalog: ScriptModuleCatalog(entries: [root]))
        var machine = try ScriptMachine(program: program, allowExperimental: true, repository: repository)
        machine.allowLabelProgressCandidate = true
        try machine.run()
        XCTAssertEqual(machine.phase, .waiting)
        XCTAssertGreaterThan(machine.labelProgressCandidateOutcomes["includeOrForeignSpan"] ?? 0, 0)
        XCTAssertNil(machine.labelProgressCandidateOutcomes["advanced"])
        XCTAssertNil(machine.labelProgressCandidateOutcomes["includeAdvanced"])
    }
    func testBlankLineProgressWaitsForPrefixReturn() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/owned-label-progress-tests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = Data(#"""
        @@Scene
        \gvar,int,Value
        \scp,rep
        \nt,"\subp,@@!Blank"
        \scp,

        \cal,Value=1
        \wait,1
        @@!Blank
        \wait,1
        \ret
        """#.utf8)
        let document = try ScriptDocument(data: source, relativePath: "root.s")
        let reference = ScriptModuleReference(logicalPath: "root.s", sourceFile: "root.s", sourceSHA256: source.sha256Hex)
        let repository = try ScriptRepository(directory: SafeDirectory(directory), catalog: ScriptModuleCatalog(entries: [reference]))
        var machine = try ScriptMachine(program: ScriptProgram(document), allowExperimental: true, repository: repository)
        machine.allowLabelProgressCandidate = true
        try machine.run()
        XCTAssertEqual(machine.phase, .waiting)
        XCTAssertEqual(machine.labelHistoryProbe.frames.first { $0.eligibleLabel }?.candidateStoredLine, 5)
        XCTAssertNil(machine.labelProgressReturnOutcomes["advanced"])
        try machine.advanceClickWait(ticks: 1)
        var returned = false
        for _ in 0..<8 {
            guard let item = machine.step() else { break }
            if item.action == "local_return" { returned = true; break }
        }
        XCTAssertTrue(returned)
        XCTAssertEqual(machine.labelHistoryProbe.frames.first { $0.eligibleLabel }?.candidateStoredLine, 6)
        XCTAssertEqual(machine.labelProgressReturnOutcomes["advanced"], 1)
    }
    func testExactOneBranchesAndAllSkippedRecordsAreAccountedFor() throws {
        for condition in [0,1,2,-1] {
            let machine = try run("\\var,int,x\n\\if,\(condition)\\then\n\\cal,x=7\n\\else\n\\cal,x=9\n\\end")
            XCTAssertEqual(machine.phase,.finished)
            XCTAssertEqual(try machine.value(named: "x"),.integer(condition == 1 ? 7 : 9))
            XCTAssertTrue(machine.traces.contains { $0.skipped != nil })
        }
    }
    func testNestedInactiveUnknownsAreRecordedWithoutBeingExecuted() throws {
        let machine = try run("\\var,int,x\n\\if,0\\then\n\\unknown,opaque\n\\if,1\\then\n\\cal,x=100\n\\end\n\\else\n\\cal,x=9\n\\end")
        XCTAssertEqual(machine.phase,.finished); XCTAssertEqual(try machine.value(named: "x"),.integer(9))
        XCTAssertTrue(machine.traces.contains { ($0.skipped?.recordTypes["command"] ?? 0) >= 5 })
        XCTAssertFalse(machine.traces.contains { $0.command == "unknown" })
    }
    func testSameFileCallsReturnToRetainedCallerAndDropCalleeLocals() throws {
        let machine = try run("\\gvar,int,total\n\\var,int,local\n\\cal,total=1\n\\cal,local=42\n\\sub,@@Work\n\\cal,total=total+10\n\\jmp,@@Done\n@@Work\n\\var,int,local\n\\cal,local=7\n\\cal,total=total+1\n\\ret\n@@Done")
        XCTAssertEqual(machine.phase,.finished); XCTAssertEqual(try machine.value(named: "total"),.integer(12))
        XCTAssertEqual(try machine.value(named: "local"),.integer(42)); XCTAssertEqual(machine.summary.callDepth,1)
        XCTAssertTrue(machine.traces.contains { $0.action == "local_return" && $0.target != nil })
    }
    func testCalleeDoesNotInventCallerLocalInheritance() throws {
        let machine = try run("\\var,int,callerOnly\n\\sub,@@Work\n@@Work\n\\cal,callerOnly+1")
        XCTAssertEqual(machine.stopReason,"undefined_or_unbound_scalar"); XCTAssertEqual(machine.summary.callDepth,2)
    }
    func testUnknownCommandAndTextStopAtExactUnchangedPC() throws {
        for text in ["\\mystery,private\n\\cal,1","Original owned prose\n\\cal,1","$owned=unreviewed\n\\cal,1","@@@owned.s\n\\cal,1","^owned,private\n\\cal,1"] {
            var machine = try run(text)
            XCTAssertEqual(machine.phase,.stopped)
            let pc = machine.pc, count = machine.traces.count
            try machine.run(); XCTAssertEqual(machine.pc,pc); XCTAssertEqual(machine.traces.count,count)
            XCTAssertEqual(machine.summary.currentLocation,machine.traces.last?.location)
        }
    }
    func testVisualDeclarationTypesSurviveUntilDeletion() throws {
        var storage = ScriptStorage()
        for type in ["img", "simg", "btn", "sbtn"] {
            try storage.declare("v_" + type, category: "gvar", type: type)
            guard case .object(let handle) = try storage.read("v_" + type) else {
                return XCTFail("expected visual handle")
            }
            XCTAssertEqual(storage.visualObjectTypes[handle], type)
            try storage.deleteGlobalBinding("v_" + type)
            XCTAssertNil(storage.visualObjectTypes[handle])
        }
    }
    func testObjectAliasKeepsOnlyExplicitReferenceText() throws {
        var storage = ScriptStorage()
        try storage.declare("TableA", category: "gvar", type: "table")
        try storage.declare("AliasA", category: "gvar", type: "obj")
        let key = Data("aliasa".utf8)
        XCTAssertEqual(storage.globalAliasReferences[key]?[0], "")
        try storage.write("AliasA", .string("TableA"))
        XCTAssertEqual(storage.globalAliasReferences[key]?[0], "TableA")
        XCTAssertThrowsError(try storage.write("AliasA", .string("missing")))
        XCTAssertEqual(storage.globalAliasReferences[key]?[0], "TableA")
        let handle = try storage.read("TableA")
        try storage.write("AliasA", handle)
        XCTAssertNil(storage.globalAliasReferences[key]?[0])
        let sound = try storage.readIndexed("snd", 3)
        try storage.write("AliasA", sound)
        guard case .object(let soundHandle) = sound else { return XCTFail("expected sound handle") }
        try storage.recordSoundAliasReference(target: "AliasA", index: 0, soundIndex: 4, handle: soundHandle)
        XCTAssertNil(storage.globalAliasReferences[key]?[0])
        try storage.recordSoundAliasReference(target: "AliasA", index: 0, soundIndex: 3, handle: soundHandle)
        XCTAssertEqual(storage.globalAliasReferences[key]?[0], "snd[3]")
        XCTAssertEqual(storage.recordedSoundAliasIndex(source: "AliasA", index: 0, handle: soundHandle), 3)
        XCTAssertNil(storage.recordedSoundAliasIndex(source: "AliasA", index: 1, handle: soundHandle))
        try storage.declare("LocalAlias", category: "var", type: "obj")
        try storage.write("LocalAlias", sound)
        try storage.recordSoundAliasReference(target: "LocalAlias", index: 0, soundIndex: 3, handle: soundHandle)
        XCTAssertEqual(storage.recordedSoundAliasIndex(source: "LocalAlias", index: 0, handle: soundHandle), 3)
        try storage.declare("NullAlias", category: "gvar", type: "obj")
        let nullKey = Data("nullalias".utf8)
        let emptyTemplate = Data("CalVal\0\0".utf8) + Data([1, 0, 0, 0]) + Data(repeating: 0, count: 8)
        let encoded = try SaveVariableArrays.encodeCalValValues(template: emptyTemplate, storage: storage,
            newBindingKeys: [key, nullKey])
        let arrays = try SaveVariableArrays.readCalVal(state: encoded, at: 0)
        var restored = ScriptStorage()
        XCTAssertEqual(try restored.stageSavedSoundAliases(arrays), 2)
        XCTAssertEqual(try restored.read("AliasA"), sound)
        XCTAssertEqual(try restored.read("NullAlias"), .object(ScriptStorage.nullHandle))
        XCTAssertEqual(restored.savedSoundAliasTexts(key), ["snd[3]"])
        let rewrittenAliases = try SaveVariableArrays.encodeCalValValues(template: encoded, storage: storage)
        XCTAssertEqual(rewrittenAliases, encoded)
        let generatedLocals = try SaveVariableArrays.encodeIndexedLocals(in: Data("tail".utf8), at: 0,
                                                                          frames: storage.frames)
        let localGroup = try SaveVariableArrays(state: generatedLocals.bytes, decodedOffset: 16)
        var restoredLocals = try ScriptStorage.stageSavedGlobalScalars(localGroup)
        XCTAssertEqual(try restoredLocals.stageSavedSoundAliases(localGroup), 1)
        XCTAssertEqual(try restoredLocals.read("LocalAlias"), sound)
        let nextSound = try storage.readIndexed("snd", 4)
        try storage.write("LocalAlias", nextSound)
        guard case .object(let nextHandle) = nextSound else { return XCTFail("expected sound handle") }
        try storage.recordSoundAliasReference(target: "LocalAlias", index: 0, soundIndex: 4, handle: nextHandle)
        let updatedLocals = try SaveVariableArrays.encodeIndexedLocals(in: generatedLocals.bytes, at: 0,
                                                                        frames: storage.frames)
        let updatedGroup = try SaveVariableArrays(state: updatedLocals.bytes, decodedOffset: 16)
        var updatedStorage = try ScriptStorage.stageSavedGlobalScalars(updatedGroup)
        XCTAssertEqual(try updatedStorage.stageSavedSoundAliases(updatedGroup), 1)
        XCTAssertEqual(try updatedStorage.read("LocalAlias"), nextSound)
        XCTAssertEqual(updatedStorage.savedSoundAliasTexts(Data("localalias".utf8)), ["snd[4]"])
        try storage.write("LocalAlias", sound)
        XCTAssertThrowsError(try SaveVariableArrays.encodeIndexedLocals(in: generatedLocals.bytes, at: 0,
                                                                         frames: storage.frames))
        try storage.write("AliasA", sound)
        XCTAssertNil(SaveVariableArrays.generatedBindingType(key, in: storage))
        try storage.deleteGlobalBinding("AliasA")
        XCTAssertNil(storage.globalAliasReferences[key])
    }
    func testMalformedBlocksAliasesNamedReturnsAndCallArgumentsAreNotGuessed() throws {
        for text in ["\\end","\\then","\\if,1\\then"] { XCTAssertThrowsError(try ScriptProgram(document(text))) }
        for text in ["\\subp,@@Work","\\subr,@@Work","\\ret,@@Other","\\sub,@@Work,private","\\go,@@Other,private","\\var,unreviewedType,x"] {
            let machine = try run(text); XCTAssertEqual(machine.phase,.stopped); XCTAssertEqual(machine.summary.callDepth,1)
        }
        XCTAssertEqual(try run("\\ret").stopReason,"root_return_outside_profile")
    }
    func testAmbiguousTargetsAndJumpingAcrossControlScopeAreRejected() throws {
        XCTAssertEqual(try run("\\jmp,@@Same\n@@same\n@@Same").stopReason,"ambiguous_same_file_target")
        XCTAssertEqual(try run("\\jmp,@@Inside\n\\if,1\\then\n@@Inside\n\\end").stopReason,"jump_crosses_control_scope")
        XCTAssertEqual(try run("\\jmp,@@Elsewhere").stopReason,"unresolved_same_file_target")
    }
    func testAtomicFailurePreservesValuesAndConditionalAssignmentsAreExcluded() throws {
        let machine = try run("\\var,int,x\n\\cal,x=9\n\\cal,x=1/0")
        XCTAssertEqual(try machine.value(named: "x"),.integer(9))
        let condition = try run("\\var,int,x\n\\if,x=1\\then\n\\end")
        XCTAssertEqual(condition.stopReason,"assignment_condition_outside_profile")
        XCTAssertEqual(try condition.value(named: "x"),.integer(0))
    }
    func testExplicitOptInAndStepAndRecursionBoundsAreEnforced() throws {
        let program = try ScriptProgram(document("@@Loop\n\\jmp,@@Loop"))
        XCTAssertThrowsError(try ScriptMachine(program: program,allowExperimental: false))
        var looping = try ScriptMachine(program: program,allowExperimental: true,maximumSteps: 8)
        try looping.run(); XCTAssertEqual(looping.traces.count,8); XCTAssertEqual(looping.stopReason,"machine_total_step_limit")
        let recursive = try run("@@Loop\n\\sub,@@Loop",maximumFrames: 2)
        XCTAssertEqual(recursive.stopReason,"call_frame_limit"); XCTAssertEqual(recursive.summary.callDepth,2)
        var stepper = try ScriptMachine(program: program,allowExperimental: true)
        try stepper.run(stepQuota: 1); XCTAssertEqual(stepper.phase,.ready); XCTAssertEqual(stepper.traces.count,1)
        XCTAssertThrowsError(try stepper.run(stepQuota: 0))
    }
    func testEncodedTraceCannotLeakOperandTextOrVariableNames() throws {
        let machine = try run("\\var,int,privateIdentifier\n\\cal,\"Original owned secret sentence\"\n\\unsupported,privateArgument")
        let encoder = JSONEncoder(); let json = String(data: try encoder.encode(machine.summary),encoding: .utf8)!
        for text in ["privateIdentifier","Original owned secret sentence","privateArgument"] { XCTAssertFalse(json.contains(text)) }
        XCTAssertTrue(json.contains("not_tested")); XCTAssertTrue(json.contains("inferred"))
    }
}

extension ScriptTests {
    func testBarHitGeometryCandidateBoundaryAndWinding() {
        let xx: [Float] = [0, 10, 10, 0], yy: [Float] = [0, 0, 10, 10]
        XCTAssertEqual(BarHitGeometry.contains(x: 5, y: 5, vertexX: xx, vertexY: yy), true)
        XCTAssertEqual(BarHitGeometry.contains(x: 0, y: 5, vertexX: xx, vertexY: yy), false)
        XCTAssertEqual(BarHitGeometry.contains(x: 10, y: 5, vertexX: xx, vertexY: yy), false)
        XCTAssertEqual(BarHitGeometry.contains(x: 5, y: 11, vertexX: xx, vertexY: yy), false)
        XCTAssertEqual(BarHitGeometry.contains(x: 5, y: 5, vertexX: xx.reversed(), vertexY: yy.reversed()), false)
        let sx: [Float] = [0, 10, 15, 5], sy: [Float] = [0, 0, 10, 10]
        XCTAssertEqual(BarHitGeometry.contains(x: 2, y: 4, vertexX: sx, vertexY: sy), true)
        XCTAssertNil(BarHitGeometry.contains(x: .nan, y: 4, vertexX: sx, vertexY: sy))
    }
}
