import Foundation

struct ScriptBinding: Sendable {
    var elements: [ScriptValue]
    var first: ScriptValue { elements[0] }
}

struct ScriptFrame: Sendable {
    let returnIndex: Int?
    var returnProgram: ScriptProgram?
    var locals: [Data: ScriptBinding] = [:]
    var controls: [Int] = []
    var tableScope: [UInt64] = []
    var forPlans: [Int: ScriptForPlan] = [:]
}

/// Explicit experimental storage profile; does not reproduce native object ownership/ABI.
struct ScriptStorage: Sendable {
    var system: [Data: ScriptBinding] = [:]
    var global: [Data: ScriptBinding] = [:]
    var frames: [ScriptFrame] = [ScriptFrame(returnIndex: nil)]
    var tables: [UInt64: ScriptTable] = [:]
    var lists: [UInt64: ScriptStringList] = [:]
    private var nextObject: UInt64 = 1

    func read(_ raw: String) throws -> ScriptValue {
        let name = Data(asciiLower(raw).utf8)
        guard let value = frames.last?.locals[name] ?? global[name] ?? system[name]
        else { throw ResourceError.rejected("undefined_or_unbound_scalar") }
        return value.first
    }
    func readIndexed(_ raw: String, _ index: Int32) throws -> ScriptValue {
        let name = Data(asciiLower(raw).utf8)
        guard let binding = frames.last?.locals[name] ?? global[name] ?? system[name]
        else { throw ResourceError.rejected("undefined_or_unbound_scalar") }
        guard binding.first.typeName != "object" else { throw ResourceError.rejected("object_index_outside_profile") }
        guard index >= 0, Int(index) < binding.elements.count else { throw ResourceError.rejected("array_index_out_of_range") }
        return binding.elements[Int(index)]
    }
    mutating func writeIndexed(_ raw: String, _ index: Int32, _ value: ScriptValue) throws {
        _ = try readIndexed(raw,index)
        try writeElement(raw,index: Int(index),value: value)
    }
    mutating func write(_ raw: String, _ value: ScriptValue) throws {
        try writeElement(raw,index: 0,value: value)
    }
    private mutating func writeElement(_ raw: String, index: Int, value: ScriptValue) throws {
        let name = Data(asciiLower(raw).utf8), i = frames.count-1
        guard let previous = frames[i].locals[name] ?? global[name] ?? system[name]
        else { throw ResourceError.rejected("assignment_target_not_declared") }
        guard previous.first.typeName == value.typeName, value.typeName != "object"
        else { throw ResourceError.rejected("scalar_assignment_type_outside_profile") }
        if case .string(let s) = value, s.utf8.count > 8192 { throw ResourceError.rejected("string_value_limit") }
        if frames[i].locals[name] != nil { frames[i].locals[name]!.elements[index] = value }
        else if global[name] != nil { global[name]!.elements[index] = value }
        else { system[name]!.elements[index] = value }
        try validate()
    }
    @discardableResult mutating func declare(_ raw: String, category: String, type: String, count: Int = 1) throws -> Bool {
        guard (1...4096).contains(count) else { throw ResourceError.rejected("array_element_count_limit") }
        guard !["table","list"].contains(type) || count == 1 else { throw ResourceError.rejected("object_array_outside_profile") }
        guard raw.utf8.count <= 4096, raw.range(of: #"^#?[\p{L}_][\p{L}\p{N}_]*$"#, options: .regularExpression) != nil
        else { throw ResourceError.rejected("non_scalar_declaration_name") }
        guard ["int","str","table","list"].contains(type) else { throw ResourceError.rejected("declaration_type_outside_profile") }
        guard category != "svar" || ["int","str"].contains(type) else { throw ResourceError.rejected("system_object_declaration_outside_profile") }
        // 0x69d048 tests the visible lookup category before allocating a binding.
        if lookupCategory(raw) != 0 { return false }
        let name = Data(asciiLower(raw).utf8), i = frames.count-1
        let value: ScriptValue
        switch type {
        case "int": value = .integer(0)
        case "str": value = .string("")
        case "table":
            guard tables.count+lists.count < 512 else { throw ResourceError.rejected("table_object_limit") }
            value = .object(nextObject); tables[nextObject] = ScriptTable(); nextObject += 1
        case "list":
            guard tables.count+lists.count < 512 else { throw ResourceError.rejected("table_object_limit") }
            value = .object(nextObject); lists[nextObject] = ScriptStringList(); nextObject += 1
        default: throw ResourceError.rejected("declaration_type_outside_profile")
        }
        let binding = ScriptBinding(elements: Array(repeating: value,count: count))
        if category == "var" { frames[i].locals[name] = binding }
        else if category == "gvar" { global[name] = binding }
        else { system[name] = binding }
        try validate(); return true
    }
    mutating func results(string: String, integer: Int32) throws {
        guard string.utf8.count <= 8192 else { throw ResourceError.rejected("string_value_limit") }
        let sk = Data(asciiLower("ResultStr").utf8), ik = Data(asciiLower("ResultInt").utf8)
        guard global[sk] == nil || global[sk]?.first.typeName == "string",
              global[ik] == nil || global[ik]?.first.typeName == "integer"
        else { throw ResourceError.rejected("table_result_register_type_conflict") }
        if global[sk] == nil { global[sk] = ScriptBinding(elements: [.string(string)]) }
        else { global[sk]!.elements[0] = .string(string) }
        if global[ik] == nil { global[ik] = ScriptBinding(elements: [.integer(integer)]) }
        else { global[ik]!.elements[0] = .integer(integer) }
        try validate()
    }
    func lookupCategory(_ raw: String) -> Int32 {
        let key = Data(asciiLower(raw).utf8)
        return frames.last?.locals[key] != nil ? 3 : global[key] != nil ? 2 : system[key] != nil ? 1 : 0
    }
    mutating func resultInteger(_ value: Int32) throws {
        let key = Data(asciiLower("ResultInt").utf8)
        guard global[key] == nil || global[key]?.first.typeName == "integer"
        else { throw ResourceError.rejected("table_result_register_type_conflict") }
        if global[key] == nil { global[key] = ScriptBinding(elements: [.integer(value)]) }
        else { global[key]!.elements[0] = .integer(value) }
        try validate()
    }
    mutating func resultString(_ value: String) throws {
        guard value.utf8.count <= 8192 else { throw ResourceError.rejected("string_value_limit") }
        let key = Data(asciiLower("ResultStr").utf8)
        guard global[key] == nil || global[key]?.first.typeName == "string"
        else { throw ResourceError.rejected("table_result_register_type_conflict") }
        if global[key] == nil { global[key] = ScriptBinding(elements: [.string(value)]) }
        else { global[key]!.elements[0] = .string(value) }
        try validate()
    }
    func scopedTables() throws -> [UInt64] {
        let scope = frames.last!.tableScope
        guard !scope.isEmpty, scope.allSatisfy({ tables[$0] != nil || lists[$0] != nil })
        else { throw ResourceError.rejected("table_object_scope_required") }
        return scope
    }
    func validate() throws {
        let dictionaries = [system,global] + frames.map(\.locals)
        guard dictionaries.reduce(0, { $0+$1.count }) <= 4096 else { throw ResourceError.rejected("scalar_storage_limit") }
        guard dictionaries.reduce(0, { n, dict in n+dict.values.reduce(0, { $0+$1.elements.count }) }) <= 65_536
        else { throw ResourceError.rejected("array_total_element_limit") }
        let strings = dictionaries.reduce(0) { total, dict in
            total + dict.values.reduce(0) { n, b in n+b.elements.reduce(0) { count, v in
                if case .string(let s) = v { return count+s.utf8.count }; return count
            } }
        }
        guard strings <= 8*1024*1024 else { throw ResourceError.rejected("string_storage_limit") }
        let loaded = tables.values.compactMap(\.summary)
        guard loaded.reduce(0, { $0+$1.source.byteLength }) <= 8*1024*1024,
              loaded.reduce(0, { $0+$1.lines.count }) <= 50_000,
              tables.values.reduce(0, { $0+$1.count }) <= 100_000
        else { throw ResourceError.rejected("table_storage_budget") }
        let loadedLists = lists.values.compactMap(\.summary)
        guard loadedLists.reduce(0, { $0+$1.source.byteLength }) <= 8*1024*1024,
              loadedLists.reduce(0, { $0+$1.lineCount }) <= 50_000
        else { throw ResourceError.rejected("list_storage_budget") }
    }
}
