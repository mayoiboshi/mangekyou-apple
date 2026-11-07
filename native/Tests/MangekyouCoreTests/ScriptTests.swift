import XCTest
import Foundation
@testable import MangekyouCore

final class ScriptTests: XCTestCase {
    func document(_ text: String) throws -> ScriptDocument {
        try ScriptDocument(data: Data([0xef,0xbb,0xbf]) + Data(text.utf8),relativePath: "owned/scene.s")
    }
    func run(_ text: String, maximumSteps: Int = 1000, maximumFrames: Int = 64) throws -> ScriptMachine {
        var machine = try ScriptMachine(program: ScriptProgram(document(text)),allowExperimental: true,
            maximumSteps: maximumSteps,maximumFrames: maximumFrames)
        try machine.run(); return machine
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
        for text in ["2147483647+1","1/0","-2147483648/-1","\"a\"+\"b\"","1<<2","1.5"] {
            XCTAssertThrowsError(try value(text),text)
        }
        XCTAssertThrowsError(try ScriptExpression.parse(Array(repeating: "1",count: 100).joined(separator: "+")))
    }
    func testAssignmentReturnsOneAndNeedsAnExistingTypedScalar() throws {
        let machine = try run("\\var,int,count\n\\cal,count=7")
        XCTAssertEqual(try machine.value(named: "COUNT"),.integer(7)); XCTAssertEqual(machine.lastResult,.integer(1))
        XCTAssertEqual(try run("\\cal,count=7").stopReason,"assignment_target_not_declared")
        let mismatch = try run("\\var,int,count\n\\cal,count=\"private content\"")
        XCTAssertEqual(mismatch.phase,.stopped); XCTAssertEqual(try mismatch.value(named: "count"),.integer(0))
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
