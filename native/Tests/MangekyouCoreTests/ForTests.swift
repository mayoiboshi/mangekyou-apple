import XCTest
import Foundation
@testable import MangekyouCore

final class ForTests: XCTestCase {
    func run(_ text: String, limit: Int = 10000) throws -> ScriptMachine {
        let doc = try ScriptDocument(data: Data([0xef,0xbb,0xbf])+Data(text.utf8),relativePath: "owned/loops.s")
        var m = try ScriptMachine(program: ScriptProgram(doc),allowExperimental: true,maximumSteps: limit)
        try m.run(); return m
    }
    func testInitializerOnceAndUpdateBeforeNextCondition() throws {
        let m = try run("\\var,int,i\n\\var,int,total\n\\for,i=0,i<4,i++\n\\cal,total=total+i\n\\end")
        XCTAssertEqual(m.phase,.finished); XCTAssertEqual(try m.value(named: "total"),.integer(6)); XCTAssertEqual(try m.value(named: "i"),.integer(4))
        XCTAssertEqual(m.traces.filter { $0.action == "for_enter_candidate" }.count,1)
        XCTAssertEqual(m.traces.filter { $0.action == "for_update_then_repeat" }.count,3)
    }
    func testFalseAndNonOneConditionsCommitInitializerWithoutRunningBody() throws {
        for condition in ["0","2","i<0"] {
            let m = try run("\\var,int,i\n\\for,i=4,\(condition),i++\n\\unknown\n\\end")
            XCTAssertEqual(m.phase,.finished); XCTAssertEqual(try m.value(named: "i"),.integer(4))
            XCTAssertTrue(m.traces.contains { $0.skipped?.recordTypes["command"] == 2 })
        }
    }
    func testAssignmentAndDecrementUpdatesUseEndPhase() throws {
        let m = try run("\\var,int,i\n\\var,int,total\n\\for,i=0,i<3,i=i+2\n\\cal,total=total+i\n\\end")
        XCTAssertEqual(m.lastResult,.integer(1)); XCTAssertEqual(try m.value(named: "total"),.integer(2)); XCTAssertEqual(try m.value(named: "i"),.integer(4))
        XCTAssertEqual(try run("\\var,int,i\n\\for,i=3,i>0,i--\n\\end").value(named: "i"),.integer(0))
    }
    func testNestedLoopsAndConditionalBlocksRestoreControlStacks() throws {
        let m = try run("\\var,int,i\n\\var,int,j\n\\var,int,total\n\\for,i=0,i<2,i++\n\\for,j=0,j<3,j++\n\\if,j==1\n\\then\n\\cal,total=total+1\n\\end\n\\end\n\\end")
        XCTAssertEqual(m.phase,.finished); XCTAssertEqual(try m.value(named: "total"),.integer(2))
    }
    func testCallInsideLoopPreservesCallerPlan() throws {
        let m = try run("\\var,int,i\n\\gvar,int,total\n\\for,i=0,i<3,i++\n\\sub,@@Work\n\\end\n\\jmp,@@Done\n@@Work\n\\cal,total=total+1\n\\ret\n@@Done")
        XCTAssertEqual(m.phase,.finished); XCTAssertEqual(try m.value(named: "total"),.integer(3))
    }
    func testMalformedFieldsMarkersAndConditionWritesStop() throws {
        for header in ["\\for,1","\\for,i=0,1,","\\for,i=0,i=1,i++","\\for,i=0,1,a[0]++"] {
            XCTAssertEqual(try run("\\var,int,i\n"+header+"\n\\end").phase,.stopped)
        }
        XCTAssertEqual(try run("\\var,int,i\n\\for,i=0,1,i++\n\\brk\n\\end").stopReason,"for_control_markers_outside_profile")
    }
    func testFailedConditionAndOverflowDoNotCommitPartialInstruction() throws {
        let m = try run("\\var,int,i\n\\cal,i=9\n\\for,i=4,\"owned\",i++\n\\end")
        XCTAssertEqual(m.stopReason,"for_condition_requires_integer"); XCTAssertEqual(try m.value(named: "i"),.integer(9))
        let overflow = try run("\\var,int,i\n\\for,i=2147483647,1,i++\n\\end")
        XCTAssertEqual(overflow.stopReason,"for_update_overflow_outside_profile"); XCTAssertEqual(try overflow.value(named: "i"),.integer(.max))
    }
    func testInfiniteLoopRemainsBoundedAndUnknownBodyIsTerminal() throws {
        let m = try run("\\var,int,i\n\\for,i=0,1,i\n\\end",limit: 20)
        XCTAssertEqual(m.phase,.stopped); XCTAssertEqual(m.stopReason,"machine_total_step_limit")
        let unknown = try run("\\var,int,i\n\\for,i=0,1,i++\n\\unknown\n\\end")
        XCTAssertEqual(unknown.stopReason,"unsupported_command"); XCTAssertEqual(try unknown.value(named: "i"),.integer(0))
    }
    func testFormatPairsAreTypedBoundedAndPreserveIntegerResult() throws {
        let m = try run("\\gvar,int,ResultInt\n\\cal,ResultInt=7\n\\fmt,\"owned%d\",-2,\"%%/%s\",\"字😀\"")
        XCTAssertEqual(m.phase,.finished); XCTAssertEqual(try m.value(named: "ResultStr"),.string("owned-2%/字😀"))
        XCTAssertEqual(try m.value(named: "ResultInt"),.integer(7))
        for text in ["\\fmt,\"%02d\",1","\\fmt,\"%d%d\",1","\\fmt,\"%d\",\"1\"","\\fmt,\"%\",1","\\fmt,\"%d\""] {
            XCTAssertEqual(try run(text).phase,.stopped)
        }
    }
    func testFormatInsideLoopUsesUpdatedElementAndSourceReferences() throws {
        let m = try run("\\var,int,i\n\\var,str,names[3]\n\\for,i=0,i<3,i++\n\\fmt,\"owned%d\",i\n\\cal,names[i]=ResultStr\n\\end\n\\cal,names[2]")
        XCTAssertEqual(m.phase,.finished); XCTAssertEqual(m.lastResult,.string("owned2"))
        XCTAssertEqual(m.traces.filter { $0.action == "format_pairs_candidate" }.count,3)
        let end = try XCTUnwrap(m.traces.first { $0.action == "for_update_then_repeat" })
        XCTAssertNotNil(end.target); XCTAssertEqual(end.location.lineNumber,6)
    }
    func testAllRawEmptyScopeFieldsClearWithoutDroppingMixedSelectors() throws {
        for commas in [",",",,",",,,"] {
            let m = try run("\\var,table,t\n\\scp,t\n\\scp"+commas+"\n\\?v,\"owned\"")
            XCTAssertEqual(m.stopReason,"table_object_scope_required")
            XCTAssertEqual(m.summary.tableObjectCount,1); XCTAssertTrue(m.traces.contains { $0.action == "clear_empty_scope_candidate" })
        }
        XCTAssertEqual(try run("\\var,table,t\n\\scp,t,").phase,.finished)
        XCTAssertEqual(try run("\\var,table,t\n\\scp,t,,t").stopReason,"scope_gap_before_nonempty_selector_unverified")
    }
}
