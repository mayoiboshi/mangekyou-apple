import XCTest
import Foundation
@testable import MangekyouCore

final class ListTests: XCTestCase {
    func utf8(_ text: String) -> Data { Data([0xef,0xbb,0xbf])+Data(text.utf8) }
    func run(_ script: String, files: [(String,Data)] = [], selected: [String] = []) throws -> ScriptMachine {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = base.appendingPathComponent(".build/owned-lists/"+UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var entries: [ScriptModuleReference] = []
        let source = utf8(script)
        for (path,data) in [("root.s",source)]+files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),withIntermediateDirectories: true)
            try data.write(to: url)
            let parts = path.split(separator: "/"), logical = parts.first?.hasPrefix("v") == true && parts.count>1 ? parts.dropFirst().joined(separator: "/") : path
            entries.append(ScriptModuleReference(logicalPath: logical,sourceFile: path,sourceSHA256: data.sha256Hex))
        }
        var catalog = try ScriptModuleCatalog(entries: entries)
        for path in selected { try catalog.select(sourceFile: path) }
        var machine = try ScriptMachine(program: ScriptProgram(ScriptDocument(data: source,relativePath: "root.s")),allowExperimental: true,
            repository: ScriptRepository(directory: SafeDirectory(root),catalog: catalog))
        try machine.run(); return machine
    }

    func testListPreservesCommentsMarkerWhitespaceAndFirstDuplicateValue() throws {
        let list = try ScriptStringList(data: utf8("key=first//value\r\nKEY=second\r\nmark=%%none%%\r\n key = value \r\n=empty-name\r\n"),relativePath: "owned.txt")
        XCTAssertEqual(try list.value(for: "KEY"),"first//value"); XCTAssertEqual(try list.value(for: "mark"),"%%none%%")
        XCTAssertEqual(try list.value(for: " key ")," value "); XCTAssertEqual(try list.value(for: ""),"empty-name")
        XCTAssertEqual(list.summary?.lineCount,5); XCTAssertEqual(list.summary?.nameCount,4)
    }
    func testLineTerminatorsEmptySourcesAndUTF16ByteReferences() throws {
        let text = "a=字😀\rb=2\n\r\nc=3\r\n"
        let bytes = Data([0xff,0xfe])+text.data(using: .utf16LittleEndian)!
        let list = try ScriptStringList(data: bytes,relativePath: "owned.txt")
        XCTAssertEqual(list.lineCount,4); XCTAssertEqual(try list.value(for: "a"),"字😀")
        for row in try XCTUnwrap(list.summary).lines {
            let r = row.location; XCTAssertEqual(r.rangeSHA256,bytes.subdata(in: r.byteOffset..<r.byteOffset+r.byteLength).sha256Hex)
        }
        for bytes in [Data(),Data([0xef,0xbb,0xbf])] { XCTAssertEqual(try ScriptStringList(data: bytes,relativePath: "owned.txt").lineCount,0) }
    }
    func testNameAndSizeFailuresRemainExplicit() throws {
        for bytes in [utf8(String(repeating: "x",count: 8193)),Data(repeating: 32,count: 1024*1024+1),utf8(String(repeating: "a\n",count: 10001)),Data([0xff,0xfe,0])] {
            XCTAssertThrowsError(try ScriptStringList(data: bytes,relativePath: "owned.txt"))
        }
    }
    func testListQueryFoundNonnumericUsesZeroRatherThanNumericFallback() throws {
        let m = try run("\\var,list,x\n\\scp,x\n\\l,\"owned.txt\"\n\\?v,\"word\",7",files: [("owned.txt",utf8("word=owned\n"))])
        XCTAssertEqual(m.phase,.finished); XCTAssertEqual(try m.value(named: "ResultStr"),.string("owned"))
        XCTAssertEqual(try m.value(named: "ResultInt"),.integer(0)); XCTAssertEqual(m.summary.listObjectCount,1); XCTAssertEqual(m.summary.listLineCount,1)
    }
    func testMissingEmptyAndNumericValuesKeepSeparateDefaultContracts() throws {
        for (key,expected) in [("missing",7),("empty",7),("number",12)] {
            let m = try run("\\var,list,x\n\\scp,x\n\\l,\"owned.txt\"\n\\?v,\"\(key)\",7",files: [("owned.txt",utf8("empty=\nnumber=12\n"))])
            XCTAssertEqual(m.phase,.finished); XCTAssertEqual(try m.value(named: "ResultInt"),.integer(Int32(expected)))
        }
        let m = try run("\\var,list,x\n\\scp,x\n\\l,\"owned.txt\"\n\\?v,\"number\",7",files: [("owned.txt",utf8("number=4294967295\n"))])
        XCTAssertEqual(m.phase,.finished); XCTAssertEqual(try m.value(named: "ResultInt"),.integer(-1))
    }
    func testMixedScopeRetainsDistinctListAndTableAdmission() throws {
        let m = try run("\\var,table,t\n\\var,list,x\n\\scp,t,x\n\\l,\"owned.txt\"\n\\?v,\"key\",7",files: [("owned.txt",utf8("key=first//owned\n"))])
        XCTAssertEqual(m.phase,.finished); XCTAssertEqual(try m.value(named: "ResultStr"),.string("first//owned"))
        XCTAssertEqual(m.summary.tableEntryCount,0); XCTAssertEqual(m.summary.listLineCount,1)
    }
    func testVariableExistsReturnsCategoryAndPreservesStringResult() throws {
        for (declaration,expected) in [("",0),("\\svar,int,#a\n",1),("\\gvar,int,#a\n",2),("\\var,int,#a\n",3)] {
            let m = try run("\\gvar,str,ResultStr\n\\cal,ResultStr=\"retained\"\n"+declaration+"\\vexs,#a")
            XCTAssertEqual(m.phase,.finished); XCTAssertEqual(try m.value(named: "ResultInt"),.integer(Int32(expected)))
            XCTAssertEqual(try m.value(named: "ResultStr"),.string("retained"))
        }
        let m = try run("\\svar,int,a\n\\gvar,int,a\n\\var,int,a\n\\vexs,a")
        XCTAssertEqual(try m.value(named: "ResultInt"),.integer(1))
        for field in ["\"a\"","a[0]","a=1"] { XCTAssertEqual(try run("\\vexs,"+field).stopReason,"variable_exists_requires_bare_name") }
    }
    func testRelativeLoadPrefersCurrentSourceDirectoryAndRestoresOnReturn() throws {
        let child = utf8("@@Work\n\\var,list,x\n\\scp,x\n\\l,\"owned.txt\"\n\\?v,\"key\"\n\\ret")
        let m = try run("\\sub,@@Work,\"sub/child.s\"",files: [("sub/child.s",child),("sub/owned.txt",utf8("key=relative")),("owned.txt",utf8("key=root"))])
        XCTAssertEqual(m.phase,.finished); XCTAssertEqual(try m.value(named: "ResultStr"),.string("relative"))
        XCTAssertEqual(m.summary.sourceSnapshotCount,3); XCTAssertEqual(m.traces.first { $0.resource != nil }?.resource?.sourceFile,"sub/owned.txt")
    }
    func testRelativeAmbiguityCannotFallThroughToUniqueRootResource() throws {
        let child = utf8("@@Work\n\\var,list,x\n\\scp,x\n\\l,\"owned.txt\"\n\\ret")
        let files = [("sub/child.s",child),("v1/sub/owned.txt",utf8("key=first")),("v2/sub/owned.txt",utf8("key=second")),("owned.txt",utf8("key=root"))]
        let m = try run("\\sub,@@Work,\"sub/child.s\"",files: files)
        XCTAssertEqual(m.stopReason,"ambiguous_module_variants"); XCTAssertEqual(m.summary.sourceSnapshotCount,2)
        let chosen = try run("\\sub,@@Work,\"sub/child.s\"",files: files,selected: ["v2/sub/owned.txt"])
        XCTAssertEqual(chosen.phase,.finished); XCTAssertEqual(chosen.summary.listLineCount,1)
    }
    func testFailedListLoadDoesNotReplaceCommittedSnapshot() throws {
        let m = try run("\\var,list,x\n\\scp,x\n\\l,\"good.txt\"\n\\l,\"bad.txt\"",files: [("good.txt",utf8("key=1")),("bad.txt",Data([0xff,0xfe,0]))])
        XCTAssertEqual(m.phase,.stopped); XCTAssertEqual(m.summary.listLineCount,1)
        XCTAssertEqual(m.summary.sourceSnapshotCount,2); XCTAssertEqual(m.summary.listSnapshots.first?.source.sourceFile,"good.txt")
    }
    func testUnicodeNamesArePreservedAndCannotBeSilentlySkippedDuringLookup() throws {
        let list = try ScriptStringList(data: utf8("known=1\n鍵=value\nlater=2"),relativePath: "owned.txt")
        XCTAssertEqual(list.summary?.unresolvedNameCount,1); XCTAssertEqual(list.lineCount,3)
        XCTAssertEqual(try list.value(for: "known"),"1")
        XCTAssertThrowsError(try list.value(for: "later")) { error in
            let failure = error as? ScriptTableFailure
            XCTAssertEqual(failure?.code,"list_name_locale_comparison_required"); XCTAssertEqual(failure?.location.lineNumber,2)
        }
        let m = try run("\\var,list,x\n\\scp,x\n\\l,\"owned.txt\"\n\\?v,\"later\"",files: [("owned.txt",utf8("鍵=value\nlater=2"))])
        XCTAssertEqual(m.stopReason,"list_name_locale_comparison_required"); XCTAssertEqual(m.summary.listLineCount,2)
        XCTAssertEqual(m.traces.last?.resource?.lineNumber,1); XCTAssertThrowsError(try m.value(named: "ResultInt"))
    }
}
