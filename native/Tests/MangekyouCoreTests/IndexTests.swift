import XCTest
import Foundation
@testable import MangekyouCore

final class IndexTests: XCTestCase {
    func run(_ text: String) throws -> ScriptMachine {
        let bytes = Data([0xef,0xbb,0xbf])+Data(text.utf8)
        var m = try ScriptMachine(program: ScriptProgram(ScriptDocument(data: bytes,relativePath: "owned/index.s")),allowExperimental: true)
        try m.run(); return m
    }

    func testStringZeroIndexReturnsWholeElementIncludingSurrogates() throws {
        let m = try run("\\var,str,a\n\\var,str,b\n\\cal,a=\"字😀end\"\n\\cal,b=a[0]")
        XCTAssertEqual(m.phase,.finished); XCTAssertEqual(try m.value(named: "b"),.string("字😀end"))
        XCTAssertEqual(m.lastResult,.integer(1))
    }
    func testIndexWriteAndPlainReadShareTheSingletonElement() throws {
        let m = try run("\\var,int,a\n\\var,str,b\n\\cal,a[0]=42\n\\cal,b[0]=\"owned\"\n\\cal,a[0]+1")
        XCTAssertEqual(m.phase,.finished); XCTAssertEqual(try m.value(named: "a"),.integer(42))
        XCTAssertEqual(try m.value(named: "b"),.string("owned")); XCTAssertEqual(m.lastResult,.integer(43))
    }
    func testComputedAndNestedReadOnlyCoordinatesAreIntegerExpressions() throws {
        let m = try run("\\var,int,a\n\\var,int,i\n\\cal,a=5\n\\cal,a[i[0]+2-2]*3")
        XCTAssertEqual(m.phase,.finished); XCTAssertEqual(m.lastResult,.integer(15))
        let negative = try run("\\var,int,a\n\\cal,a=4\n\\cal,-a[0]")
        XCTAssertEqual(negative.lastResult,.integer(-4))
    }
    func testNonzeroNegativeAndWrappedCoordinatesStopWithoutWriting() throws {
        for coordinate in ["1","-1","2147483647","$FFFFFFFF"] {
            let m = try run("\\var,int,a\n\\cal,a=7\n\\cal,a[\(coordinate)]=9\n\\cal,a=10")
            XCTAssertEqual(m.stopReason,"array_index_out_of_range"); XCTAssertEqual(try m.value(named: "a"),.integer(7))
            XCTAssertEqual(m.traces.last?.reason,"array_index_out_of_range")
        }
    }
    func testIndexTypeErrorsAndArithmeticFailuresDoNotCoerce() throws {
        for coordinate in ["\"0\"","1/0","2147483647+1"] {
            let m = try run("\\var,str,a\n\\cal,a=\"owned\"\n\\cal,a[\(coordinate)]")
            XCTAssertEqual(m.phase,.stopped); XCTAssertEqual(try m.value(named: "a"),.string("owned"))
        }
        let m = try run("\\var,int,a\n\\cal,a[0]=\"7\"")
        XCTAssertEqual(m.stopReason,"scalar_assignment_type_outside_profile"); XCTAssertEqual(try m.value(named: "a"),.integer(0))
    }
    func testMissingBindingAndObjectIndicesRemainExplicitlyUnsupported() throws {
        XCTAssertEqual(try run("\\cal,missing[0]").stopReason,"undefined_or_unbound_scalar")
        XCTAssertEqual(try run("\\var,table,t\n\\cal,t[0]").stopReason,"object_index_outside_profile")
        XCTAssertEqual(try run("\\var,table,t\n\\cal,t[0]=1").stopReason,"object_index_outside_profile")
    }
    func testIndexSyntaxCannotIntroduceDimensionsCallsOrMutatingCoordinates() throws {
        for expression in ["a[]","a[0,0]","a[0][0]","a[0","a[(i=0)]","a[(b[0]=0)]","a[0]++","\"a\"[0]","(a+1)[0]"] {
            XCTAssertThrowsError(try ScriptExpression.parse(expression),expression)
        }
        XCTAssertEqual(try run("\\var,int,a[2,2]").phase,.stopped)
    }
    func testIndexCoordinatesPreserveVisibleBindingsAndGlobalResults() throws {
        let m = try run("\\gvar,int,a\n\\cal,a=9\n\\sub,@@Work\n\\cal,a[0]\n\\jmp,@@Done\n@@Work\n\\var,int,a\n\\cal,a[0]=2\n\\ret\n@@Done")
        XCTAssertEqual(m.phase,.finished); XCTAssertEqual(try m.value(named: "a"),.integer(2)); XCTAssertEqual(m.lastResult,.integer(2))
        var s = ScriptStorage(); try s.results(string: "whole",integer: 8)
        XCTAssertEqual(try s.readIndexed("ResultStr",0),.string("whole")); XCTAssertEqual(try s.readIndexed("ResultInt",0),.integer(8))
    }
    func testPureExpressionAPIRequiresExplicitIndexedStorageAndRetainsByteReferences() throws {
        XCTAssertThrowsError(try ScriptExpression.parse("a[0]").evaluate(read: { _ in .integer(3) },write: { _,_ in }))
        let text = "\\var,int,a\r\n\\cal,a[1]=4"
        let bytes = Data([0xff,0xfe])+text.data(using: .utf16LittleEndian)!
        var m = try ScriptMachine(program: ScriptProgram(ScriptDocument(data: bytes,relativePath: "owned/index.s")),allowExperimental: true)
        try m.run(); let r = try XCTUnwrap(m.traces.last?.location)
        XCTAssertEqual(r.lineNumber,2); XCTAssertEqual(r.rangeSHA256,bytes.subdata(in: r.byteOffset..<r.byteOffset+r.byteLength).sha256Hex)
    }
    func testOneDimensionalElementsAreIndependentAndPlainNameSelectsZero() throws {
        let m = try run("\\var,int,a[4]\n\\var,str,s[3]\n\\cal,a=6\n\\cal,a[3]=9\n\\cal,s[2]=\"字😀\"\n\\cal,a[0]+a[1]+a[3]")
        XCTAssertEqual(m.phase,.finished); XCTAssertEqual(m.lastResult,.integer(15))
        XCTAssertEqual(try m.value(named: "s"),.string(""))
        let s = try run("\\var,str,s[3]\n\\cal,s[2]=\"whole\"\n\\cal,s[2]")
        XCTAssertEqual(s.lastResult,.string("whole"))
    }
    func testDimensionExpressionAndNativeMinimumOneAreBounded() throws {
        let m = try run("\\var,int,n\n\\cal,n=3\n\\var,int,a[n[0]]\n\\cal,a[2]=8\n\\cal,a[2]")
        XCTAssertEqual(m.lastResult,.integer(8))
        for size in ["0","-9"] {
            XCTAssertEqual(try run("\\var,int,a[\(size)]\n\\cal,a[0]=8").phase,.finished)
            XCTAssertEqual(try run("\\var,int,a[\(size)]\n\\cal,a[1]").stopReason,"array_index_out_of_range")
        }
        XCTAssertEqual(try run("\\var,int,a[4097]").stopReason,"array_element_count_limit")
        XCTAssertEqual(try run("\\var,int,a[\"2\"]").stopReason,"array_dimension_requires_integer")
        XCTAssertEqual(try run("\\var,table,a[1]").stopReason,"object_array_outside_profile")
    }
    func testOutOfRangeArrayWriteRetainsPreviouslyCommittedElements() throws {
        let m = try run("\\var,int,a[2]\n\\cal,a[0]=5\n\\cal,a[1]=8\n\\cal,a[2]=99")
        XCTAssertEqual(m.stopReason,"array_index_out_of_range"); XCTAssertEqual(try m.value(named: "a"),.integer(5))
        XCTAssertEqual(m.lastResult,.integer(1))
    }
    func testTotalArrayBudgetStopsTheDeclarationAtomically() throws {
        let declarations = (0..<17).map { "\\var,int,a\($0)[4096]" }.joined(separator: "\n")
        let m = try run(declarations)
        XCTAssertEqual(m.stopReason,"array_total_element_limit")
        XCTAssertEqual(try m.value(named: "a15"),.integer(0)); XCTAssertThrowsError(try m.value(named: "a16"))
    }
    func testGlobalResultRegistersWriteOnlyElementZeroOfExistingArrays() throws {
        var s = ScriptStorage(); try s.declare("ResultStr",category: "gvar",type: "str",count: 2)
        try s.writeIndexed("ResultStr",1,.string("retained")); try s.results(string: "new",integer: 8)
        XCTAssertEqual(try s.readIndexed("ResultStr",0),.string("new")); XCTAssertEqual(try s.readIndexed("ResultStr",1),.string("retained"))
    }
}
