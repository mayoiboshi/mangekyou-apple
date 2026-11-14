import XCTest
import Foundation
@testable import MangekyouCore

final class ModuleTests: XCTestCase {
    func testParentRelativeIncludeStaysInCatalogAndUsesLookupOrder() throws {
        try temporary { root in
            let main = try write(root, "dir/deep/root.s", "\\gvar,int,#sum\n@@@..\\child.s\n\\cal,#sum=#sum+1")
            let child = try write(root, "dir/child.s", "\\cal,#sum=7")
            let fallback = try write(root, "common/target.s", "@@Work\n\\ret")
            let catalog = try ScriptModuleCatalog(entries: [main, child, fallback],
                indexedResourceNames: ["dir/child.s", "common/target.s", "dir/deep/common/target.s"])
            XCTAssertEqual(try catalog.resourcePath("..\\child.s", currentSourceFile: main.sourceFile), "dir/child.s")
            XCTAssertEqual(try catalog.resourcePath("unused/../common/target.s", currentSourceFile: main.sourceFile),
                           "dir/deep/common/target.s")
            let noNearIndex = try ScriptModuleCatalog(entries: [main, child, fallback])
            XCTAssertEqual(try noNearIndex.resourcePath("unused/../common/target.s", currentSourceFile: main.sourceFile),
                           "common/target.s")
            XCTAssertThrowsError(try catalog.resourcePath("../../../outside.s", currentSourceFile: main.sourceFile))
            XCTAssertThrowsError(try catalog.resourcePath("../child.s/", currentSourceFile: main.sourceFile))
            let result = try machine(root, [main, child, fallback])
            XCTAssertEqual(result.phase, .finished)
            XCTAssertEqual(try result.value(named: "#sum"), .integer(8))
        }
    }
    func testFileExistenceRejectsDirectoryTraversalAndTreatsSafeDirectoryAsAbsent() throws {
        let ref = ScriptModuleReference(logicalPath: "root.s", sourceFile: "root.s",
                                        sourceSHA256: Data("root".utf8).sha256Hex)
        let indexed = try ScriptModuleCatalog(entries: [ref], indexedResourceNames: ["images/example.png"])
        XCTAssertFalse(try indexed.resourceExists("images\\", currentSourceFile: "root.s"))
        XCTAssertThrowsError(try indexed.resourceExists("images\\..\\", currentSourceFile: "root.s"))
        XCTAssertThrowsError(try indexed.resourceExists("/", currentSourceFile: "root.s"))
        let unindexed = try ScriptModuleCatalog(entries: [ref])
        XCTAssertThrowsError(try unindexed.resourceExists("images/", currentSourceFile: "root.s"))
    }
    func temporary(_ body: (URL) throws -> Void) throws {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = base.appendingPathComponent(".build/owned-modules/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }
    @discardableResult func write(_ root: URL, _ relative: String, _ text: String, logical: String? = nil) throws -> ScriptModuleReference {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),withIntermediateDirectories: true)
        let data = Data([0xef,0xbb,0xbf]) + Data(text.utf8); try data.write(to: url)
        return ScriptModuleReference(logicalPath: logical ?? relative,sourceFile: relative,sourceSHA256: data.sha256Hex)
    }
    func machine(_ root: URL, _ references: [ScriptModuleReference], selected: [String] = []) throws -> ScriptMachine {
        let directory = try SafeDirectory(root)
        var catalog = try ScriptModuleCatalog(entries: references)
        for name in selected { try catalog.select(sourceFile: name) }
        let first = references[0]
        let program = try ScriptProgram(ScriptDocument(data: directory.read(first.sourceFile),relativePath: first.sourceFile))
        var machine = try ScriptMachine(program: program,allowExperimental: true,repository: ScriptRepository(directory: directory,catalog: catalog))
        try machine.run(); return machine
    }
    func testCrossFileCallAndReturnRestoreTheSourceSnapshotAndCallerLocals() throws {
        try temporary { root in
            let main = try write(root,"root.s","\\gvar,int,#sum\n\\var,int,#local\n\\cal,#local=42\n\\sub,@@Work,\"lib\\worker.s\"\n\\cal,#sum=#sum+10")
            let work = try write(root,"copy/worker.s","@@Work\n\\var,int,#local\n\\cal,#local=7\n\\cal,#sum=#sum+2\n\\ret",logical: "lib/worker.s")
            let m = try machine(root,[main,work])
            XCTAssertEqual(m.phase,.finished); XCTAssertEqual(try m.value(named: "#sum"),.integer(12))
            XCTAssertEqual(try m.value(named: "#local"),.integer(42)); XCTAssertEqual(m.summary.callDepth,1)
            XCTAssertEqual(m.program.document.source.relativePath,"root.s")
            XCTAssertEqual(m.traces.first { $0.action == "module_call" }?.target?.sourceFile,"copy/worker.s")
            XCTAssertEqual(m.traces.first { $0.action == "module_return" }?.target?.sourceFile,"root.s")
            XCTAssertEqual(m.summary.moduleSnapshotCount,2)
        }
    }
    func testDifferentVariantsStopBeforeCallingAndRequireAnExplicitSelection() throws {
        try temporary { root in
            let main = try write(root,"root.s","\\gvar,int,#sum\n\\sub,@@Work,\"work.s\"")
            let a = try write(root,"data7.pack/work.s","@@Work\n\\cal,#sum=7\n\\ret",logical: "work.s")
            let b = try write(root,"data8.pack/work.s","@@Work\n\\cal,#sum=8\n\\ret",logical: "work.s")
            let stopped = try machine(root,[main,a,b])
            XCTAssertEqual(stopped.stopReason,"ambiguous_module_variants"); XCTAssertEqual(stopped.summary.callDepth,1)
            XCTAssertEqual(stopped.pendingModuleCandidates.count,2); XCTAssertEqual(try stopped.value(named: "#sum"),.integer(0))
            for (chosen,value) in [(a,7),(b,8)] {
                let run = try machine(root,[main,a,b],selected: [chosen.sourceFile])
                XCTAssertEqual(run.phase,.finished); XCTAssertEqual(try run.value(named: "#sum"),.integer(Int32(value)))
            }
        }
    }
    func testIdenticalAliasesResolveDeterministicallyWithoutMountPriority() throws {
        let text = Data("owned".utf8).sha256Hex
        let a = ScriptModuleReference(logicalPath: "work.s",sourceFile: "data7.pack/work.s",sourceSHA256: text)
        let b = ScriptModuleReference(logicalPath: "work.s",sourceFile: "data8.pack/work.s",sourceSHA256: text)
        let catalog = try ScriptModuleCatalog(entries: [b,a])
        XCTAssertEqual(try catalog.resolve("WORK.s").sourceFile,a.sourceFile)
        XCTAssertEqual(try catalog.variants(for: "work.s").count,2)
    }
    func testPathTraversalAbsolutePathsAndInvalidReferencesAreRejected() throws {
        for path in ["../work.s","/work.s","C:\\work.s","a//work.s","a/./work.s"] {
            XCTAssertThrowsError(try ScriptModuleCatalog.key(path))
        }
        let bad = ScriptModuleReference(logicalPath: "work.s",sourceFile: "work.s",sourceSHA256: "wrong")
        XCTAssertThrowsError(try ScriptModuleCatalog(entries: [bad]))
        let good = ScriptModuleReference(logicalPath: "work.s",sourceFile: "work.s",sourceSHA256: Data().sha256Hex)
        XCTAssertThrowsError(try ScriptModuleCatalog(entries: [good,good]))
    }
    func testUnicodeCanonicalEquivalenceIsNotAnImplicitLabelOrModuleAlias() throws {
        let a = "\u{00e9}.s", b = "e\u{301}.s"
        XCTAssertNotEqual(try ScriptModuleCatalog.key(a),try ScriptModuleCatalog.key(b))
        let program = try ScriptProgram(ScriptDocument(data: Data([0xef,0xbb,0xbf])+Data("@@\u{00e9}".utf8),relativePath: "root.s"))
        XCTAssertThrowsError(try program.label("@@e\u{301}"))
    }
    func testSelfDefaultAndQuotedSelfStayInTheCurrentModule() throws {
        for file in [""," ,SELF",",\"self\""] {
            let suffix = file == " ,SELF" ? ",SELF" : file
            let text = "\\sub,@@Work\(suffix)\n\\jmp,@@Done\n@@Work\n\\ret\n@@Done"
            var m = try ScriptMachine(program: ScriptProgram(ScriptDocument(data: Data(text.utf8),relativePath: "root.s")),allowExperimental: true)
            try m.run(); XCTAssertEqual(m.phase,.finished)
        }
    }
    func testHashMismatchSymlinkAndMissingIncludesRemainTerminal() throws {
        try temporary { root in
            let main = try write(root,"root.s","\\sub,@@Work,\"work.s\"")
            let target = try write(root,"work.s","@@Work\n\\ret")
            try Data("changed".utf8).write(to: root.appendingPathComponent("work.s"))
            XCTAssertEqual(try machine(root,[main,target]).stopReason,"module_source_identity")
            let current = try write(root,"work.s","@@@included.s\n@@Work\n\\ret")
            XCTAssertEqual(try machine(root,[main,current]).stopReason,"module_not_in_catalog")
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias.s"),withDestinationURL: root.appendingPathComponent("work.s"))
            let alias = ScriptModuleReference(logicalPath: "work.s",sourceFile: "alias.s",sourceSHA256: current.sourceSHA256)
            XCTAssertEqual(try machine(root,[main,alias]).phase,.stopped)
        }
    }
    func testMissingCatalogUnsupportedSelectorAndRawEmptyAreNotDefaulted() throws {
        for (tail,reason) in [("\"elsewhere.s\"","module_catalog_required"),("1","non_string_module_selector"),("","empty_module_field_mapping_not_verified")] {
            var m = try ScriptMachine(program: ScriptProgram(ScriptDocument(data: Data("\\sub,@@Work,\(tail)".utf8),relativePath: "root.s")),allowExperimental: true)
            try m.run(); XCTAssertEqual(m.stopReason,reason)
        }
    }
    func testSnapshotAndModuleCountLimitsAreAppliedBeforeAnotherFileIsExecuted() throws {
        try temporary { root in
            let main = try write(root,"root.s","\\sub,@@Work,\"work.s\"")
            let target = try write(root,"work.s","@@Work\n\\ret")
            let directory = try SafeDirectory(root), catalog = try ScriptModuleCatalog(entries: [main,target])
            let program = try ScriptProgram(ScriptDocument(data: directory.read("root.s"),relativePath: "root.s"))
            var m = try ScriptMachine(program: program,allowExperimental: true,
                repository: ScriptRepository(directory: directory,catalog: catalog,maximumModules: 1))
            try m.run(); XCTAssertEqual(m.stopReason,"module_snapshot_budget"); XCTAssertEqual(m.summary.callDepth,1)
            XCTAssertThrowsError(try ScriptMachine(program: program,allowExperimental: true,
                repository: ScriptRepository(directory: directory,catalog: catalog,maximumBytes: 1)))
        }
    }
    func testResearchCopyLayoutPreservesEveryVariantAndPinsFileBytes() throws {
        try temporary { root in
            let first = try write(root,"data7.pack/avg/owned.s","@@Own")
            _ = try write(root,"data8.pack/avg/owned.s","@@Other")
            let directory = try SafeDirectory(root), inventory = try InventoryScanner().scan(directory)
            let catalog = try ScriptModuleCatalog.researchCopies(directory: directory,inventory: inventory)
            XCTAssertEqual(try catalog.variants(for: "avg/owned.s").count,2)
            XCTAssertEqual(catalog.reference(forPhysical: first.sourceFile)?.sourceSHA256,first.sourceSHA256)
            XCTAssertThrowsError(try catalog.resolve("avg/owned.s"))
        }
    }
}
