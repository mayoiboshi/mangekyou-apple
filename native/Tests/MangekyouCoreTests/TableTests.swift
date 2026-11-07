import XCTest
import Foundation
@testable import MangekyouCore

final class TableTests: XCTestCase {
    func withFiles(_ script: String, files: [(String,Data)] = [], selected: [String] = [],
                   _ body: (ScriptMachine) throws -> Void) throws {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = base.appendingPathComponent(".build/owned-tables/"+UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scriptData = Data([0xef,0xbb,0xbf])+Data(script.utf8)
        var refs: [ScriptModuleReference] = []
        for (path,data) in [("root.s",scriptData)]+files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),withIntermediateDirectories: true)
            try data.write(to: url)
            let parts = path.split(separator: "/")
            let logical = parts.first?.hasPrefix("v") == true && parts.count > 1 ? parts.dropFirst().joined(separator: "/") : path
            refs.append(ScriptModuleReference(logicalPath: logical,sourceFile: path,sourceSHA256: data.sha256Hex))
        }
        var catalog = try ScriptModuleCatalog(entries: refs)
        for s in selected { try catalog.select(sourceFile: s) }
        let repo = try ScriptRepository(directory: SafeDirectory(root),catalog: catalog)
        var machine = try ScriptMachine(program: ScriptProgram(ScriptDocument(data: scriptData,relativePath: "root.s")),
            allowExperimental: true,repository: repo)
        try machine.run(); try body(machine)
    }
    func utf8(_ text: String) -> Data { Data([0xef,0xbb,0xbf])+Data(text.utf8) }

    func testFirstDuplicateValueFilteringAndEmptyMarkerAreDistinct() throws {
        let table = try ScriptTable(data: utf8("Key=bad//owned\r\nkey=good\r\nx=%%none%%\r\ny=\r\nz=/one\r\n"),relativePath: "owned.txt")
        XCTAssertNil(try table.value(for: "KEY")); XCTAssertNil(try table.value(for: "x")); XCTAssertNil(try table.value(for: "y"))
        XCTAssertEqual(try table.value(for: "z"),"/one"); XCTAssertEqual(table.count,3)
        XCTAssertEqual(table.summary?.emptyValueCount,2)
        XCTAssertEqual(table.summary?.lines.prefix(2).map(\.action),["filtered_double_slash","filtered_double_slash"])
    }
    func testWhitespaceAdditionalEqualsAndByteReferencesArePreserved() throws {
        let text = " key = first=second \r\nlast=字😀"
        let data = Data([0xff,0xfe])+text.data(using: .utf16LittleEndian)!
        let table = try ScriptTable(data: data,relativePath: "owned.txt")
        XCTAssertEqual(try table.value(for: " key ")," first=second ")
        XCTAssertNil(try table.value(for: "key")); XCTAssertEqual(try table.value(for: "last"),"字😀")
        for line in try XCTUnwrap(table.summary).lines {
            let r = line.location
            XCTAssertEqual(data.subdata(in: r.byteOffset..<r.byteOffset+r.byteLength).sha256Hex,r.rangeSHA256)
        }
    }
    func testCP932AndUTF16LoadsAndStrictIntegerCache() throws {
        let data = Data([0x61,0x3d,0x8e,0x9a,0x0d,0x0a])
        XCTAssertEqual(try ScriptTable(data: data,relativePath: "owned.txt").value(for: "a"),"字")
        XCTAssertEqual(ScriptExpression.integerTextCache("  +$FF"),255)
        XCTAssertEqual(ScriptExpression.integerTextCache("xFFFFFFFF"),-1)
        XCTAssertEqual(ScriptExpression.integerTextCache("-2147483648"),.min)
        for bad in ["1 ","\t1","1junk","4294967295","$100000000",""] { XCTAssertNil(ScriptExpression.integerTextCache(bad)) }
    }
    func testNonASCIIKeysInvalidEncodingsAndBudgetsStopExplicitly() throws {
        XCTAssertThrowsError(try ScriptTable(data: utf8("a=ok\n鍵=value\n"),relativePath: "owned.txt")) { error in
            let failure = error as? ScriptTableFailure
            XCTAssertEqual(failure?.code,"table_non_ascii_key_comparison_unverified"); XCTAssertEqual(failure?.location.lineNumber,2)
        }
        for bytes in [Data([0xff,0xfe,0]),Data(repeating: 0x20,count: 1024*1024+1),utf8(String(repeating: "a=1\n",count: 10_001))] {
            XCTAssertThrowsError(try ScriptTable(data: bytes,relativePath: "owned.txt"))
        }
    }
    func testStringDeclarationsAssignmentsAndTypeErrorsAreAtomic() throws {
        try withFiles("\\var,str,#s\n\\cal,#s=\"owned\"\n\\var,int,n\n\\cal,n=#s") { m in
            XCTAssertEqual(try m.value(named: "#s"),.string("owned")); XCTAssertEqual(try m.value(named: "n"),.integer(0))
            XCTAssertEqual(m.stopReason,"scalar_assignment_type_outside_profile")
        }
        try withFiles("\\var,str,x") { m in XCTAssertEqual(m.phase,.finished); XCTAssertEqual(try m.value(named: "x"),.string("")) }
    }
    func testFoundMissingEmptyAndNonnumericQueriesWriteBothGlobalResults() throws {
        let data = utf8("a=42\nempty=\nnotnumber=owned\n")
        for (key, fallback, expectedString, expectedInt) in [("a","7","42",Int32(42)),("missing","7","7",7),
            ("empty","\"fallback\"","fallback",0),("notnumber","7","owned",7)] {
            try withFiles("\\var,table,t\n\\scp,t\n\\l,\"own.txt\"\n\\?v,\"\(key)\",\(fallback)",files: [("own.txt",data)]) { m in
                XCTAssertEqual(m.phase,.finished)
                XCTAssertEqual(try m.value(named: "ResultStr"),.string(expectedString)); XCTAssertEqual(try m.value(named: "ResultInt"),.integer(expectedInt))
                XCTAssertEqual(m.summary.sourceSnapshotCount,2); XCTAssertEqual(m.summary.tableEntryCount,3)
            }
        }
    }
    func testAllSelectedTablesDispatchInOrderAndLoadTouchesBoth() throws {
        let script = "\\var,table,a\n\\var,table,b\n\\scp,a\n\\l,\"a.txt\"\n\\scp,b\n\\l,\"b.txt\"\n\\scp,a,b\n\\?v,\"key\""
        try withFiles(script,files: [("a.txt",utf8("key=3\n")),("b.txt",utf8("key=9\n"))]) { m in
            XCTAssertEqual(m.phase,.finished); XCTAssertEqual(try m.value(named: "ResultInt"),.integer(9)); XCTAssertEqual(m.summary.tableObjectCount,2)
        }
        try withFiles(script+"\n\\l,\"a.txt\"\n\\?v,\"key\"",files: [("a.txt",utf8("key=3\n")),("b.txt",utf8("key=9\n"))]) { m in
            XCTAssertEqual(try m.value(named: "ResultInt"),.integer(3)); XCTAssertEqual(m.summary.tableEntryCount,2)
        }
    }
    func testCalleeStartsWithFreshScopeAndReturnRetainsCallerScope() throws {
        let root = "\\var,table,a\n\\scp,a\n\\l,\"a.txt\"\n\\sub,@@Work\n\\?v,\"key\"\n\\jmp,@@Done\n@@Work\n"
        try withFiles(root+"\\?v,\"key\"\n\\ret\n@@Done",files: [("a.txt",utf8("key=3\n"))]) { m in
            XCTAssertEqual(m.stopReason,"table_object_scope_required"); XCTAssertEqual(m.summary.callDepth,2)
        }
        let child = "\\var,table,b\n\\scp,b\n\\l,\"b.txt\"\n\\?v,\"key\"\n\\ret\n@@Done"
        try withFiles(root+child,files: [("a.txt",utf8("key=3\n")),("b.txt",utf8("key=8\n"))]) { m in
            XCTAssertEqual(m.phase,.finished); XCTAssertEqual(try m.value(named: "ResultInt"),.integer(3))
            XCTAssertEqual(m.summary.callDepth,1)
        }
    }
    func testFailedLoadPreservesTableRegistersAndRepositorySnapshot() throws {
        let script = "\\var,table,t\n\\scp,t\n\\l,\"a.txt\"\n\\?v,\"key\"\n\\l,\"bad.txt\"\n\\cal,999"
        try withFiles(script,files: [("a.txt",utf8("key=3\n")),("bad.txt",utf8("ok=1\n鍵=x\n"))]) { m in
            XCTAssertEqual(m.phase,.stopped); XCTAssertEqual(try m.value(named: "ResultInt"),.integer(3))
            XCTAssertEqual(m.summary.sourceSnapshotCount,2); XCTAssertEqual(m.summary.tableSnapshots.first?.source.sourceFile,"a.txt")
            XCTAssertEqual(m.traces.last?.resource?.sourceFile,"bad.txt"); XCTAssertEqual(m.traces.last?.resource?.lineNumber,2)
            XCTAssertEqual(m.summary.currentLocation,m.traces.last?.location)
        }
    }
    func testResourceVariantsRequireExplicitChoiceEvenIfDecodedTextMatches() throws {
        let script = "\\var,table,t\n\\scp,t\n\\l,\"own.txt\"\n\\?v,\"key\""
        let files = [("v1/own.txt",Data("key=3\n".utf8)),("v2/own.txt",utf8("key=3\n"))]
        try withFiles(script,files: files) { m in
            XCTAssertEqual(m.stopReason,"ambiguous_module_variants"); XCTAssertEqual(m.pendingModuleCandidates.count,2)
            XCTAssertEqual(m.summary.tableEntryCount,0); XCTAssertEqual(m.summary.sourceSnapshotCount,1)
        }
        try withFiles(script,files: files,selected: ["v2/own.txt"]) { m in
            XCTAssertEqual(m.phase,.finished); XCTAssertEqual(try m.value(named: "ResultInt"),.integer(3))
        }
    }
    func testResultRegisterTypeConflictDoesNotPartiallyCreateRegisters() throws {
        try withFiles("\\gvar,int,ResultStr\n\\var,table,t\n\\scp,t\n\\?v,\"missing\",7") { m in
            XCTAssertEqual(m.stopReason,"table_result_register_type_conflict")
            XCTAssertEqual(try m.value(named: "ResultStr"),.integer(0)); XCTAssertThrowsError(try m.value(named: "ResultInt"))
        }
    }
    func testUnknownSelectorsDefaultsAliasesAndTableCommandsStop() throws {
        for tail in ["\\scp,\"t\"", "\\scp,t,,t", "\\scp,"+Array(repeating:"t",count:17).joined(separator:","),
            "\\cal,t=t", "\\scp,t\n\\?v,\"k\",0x1", "\\scp,t\n\\?v,\"k\",t", "\\scp,t\n\\unreviewed"] {
            try withFiles("\\var,table,t\n"+tail) { m in XCTAssertEqual(m.phase,.stopped); XCTAssertEqual(m.summary.currentLocation,m.traces.last?.location) }
        }
    }
}
