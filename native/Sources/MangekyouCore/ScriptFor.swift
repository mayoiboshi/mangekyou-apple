import Foundation

/// Bounded three-field loop contract, based on the retained control/update instruction evidence.
/// Standalone postfix updates are supported only where their expression value is discarded.
struct ScriptForPlan: Sendable {
    let initial: ScriptExpression
    let condition: ScriptExpression
    let update: ScriptExpression?
    let updateName: String?
    let updateDelta: Int32

    init(_ fields: [ScriptField]) throws {
        guard fields.count == 3, fields.allSatisfy({ $0.key == nil && !$0.raw.isEmpty })
        else { throw ResourceError.rejected("for_requires_three_nonempty_fields") }
        initial = try ScriptExpression.parse(fields[0].raw)
        condition = try ScriptExpression.parse(fields[1].raw)
        if case .binary("=",_,_) = condition { throw ResourceError.rejected("for_assignment_condition_outside_profile") }
        let raw = fields[2].raw.trimmingCharacters(in: .whitespaces)
        if raw.hasSuffix("++") || raw.hasSuffix("--") {
            guard case .name(let name) = try ScriptExpression.parse(String(raw.dropLast(2)))
            else { throw ResourceError.rejected("for_update_target_outside_profile") }
            updateName = name; updateDelta = raw.hasSuffix("++") ? 1 : -1; update = nil
        } else { update = try ScriptExpression.parse(raw); updateName = nil; updateDelta = 0 }
    }

    private func evaluate(_ expression: ScriptExpression, storage: inout ScriptStorage) throws -> ScriptValue {
        var working = storage
        let value = try expression.evaluate(read: { try working.read($0) },write: { try working.write($0,$1) },
            readIndexed: { try working.readIndexed($0,$1) },writeIndexed: { try working.writeIndexed($0,$1,$2) })
        storage = working; return value
    }
    private func test(_ storage: ScriptStorage) throws -> Bool {
        let value = try condition.evaluate(read: { try storage.read($0) },write: { _,_ in
            throw ResourceError.rejected("mutating_for_condition_outside_profile")
        },readIndexed: { try storage.readIndexed($0,$1) })
        guard let integer = value.integer else { throw ResourceError.rejected("for_condition_requires_integer") }
        return integer == 1
    }
    func enter(_ storage: inout ScriptStorage) throws -> Bool {
        var working = storage
        _ = try evaluate(initial,storage: &working)
        let result = try test(working); storage = working; return result
    }
    func advance(_ storage: inout ScriptStorage) throws -> Bool {
        var working = storage
        if let name = updateName {
            try working.updateInteger(name,delta: updateDelta)
        } else if let update { _ = try evaluate(update,storage: &working) }
        let result = try test(working); storage = working; return result
    }
}
