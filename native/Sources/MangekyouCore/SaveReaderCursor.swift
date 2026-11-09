import Foundation

public struct SaveReaderCursor: Encodable {
    public let decodedOffset: Int
    public let relativeLine: Int32
    public let utf16Position: Int32
    public let replaceEnableByte: UInt8

    public struct Reference: Encodable, Sendable {
        public let decodedOffset: Int
        public let length: Int
        public let sha256: String
    }

    public let lineBuffer: Reference
    public let scriptPath: Reference
    public let label: Reference
    public let textPrefix: Reference
    public let emptyLineText: Reference
    public let replacementCount: Int
    public let replacements: [Replacement]

    public struct Replacement: Encodable {
        public let firstText: Reference
        public let secondText: Reference
        public let rawField: Int32
    }

    public let nextDecodedOffset: Int
    public let routines: [Routine]

    public struct Routine: Encodable {
        public let decodedOffset: Int
        public let parentDecodedOffset: Int?
        public let depth: Int
        public let rawState: UInt8
        public let waitTime: Int32
        public let skipTime: Int32
        public let channel: Int32
        public let jumpLabel: Reference
        public let eventLabel: Reference
        public let eventName: Reference
        public let scope: [Reference]
        public let resultSnapshot: Reference?
        public let resultStringReferences: [Reference]
        public let resultObjectReferences: [Reference]
        public let resultButtonReference: Reference?
        public let resultButtonInts: [Int32]
        public let resultButtonStrings: [Reference]
        public let resultSubInts: [Int32]
        public let resultSubStrings: [Reference]
        public let resultClickInt: Int32?
        public let resultStopInt: Int32?
        public var nonEmptyResultObjectReferenceCount: Int {
            resultObjectReferences.count { $0.length != 0 }
        }
        public let hasResultSnapshot: Bool
        public let childCount: Int32
        public let controlBlocks: [ControlBlock]
    }

    public struct ControlBlock: Encodable {
        public let decodedOffset: Int
        public let rawState: UInt8
        // TScriptBlock RTTI names these Line and Pos. Their units and
        // relationship to the active script cursor are not established.
        public let rawValueAt38: Int32
        public let rawValueAt3C: Int32
        // Reader 0x6c0df0 calls setters for FSrcFile and FLabelName,
        // then reads the eight Option slots.
        public let stringReferences: [Reference]

        func matchesThreeFieldLoop(_ fields: [ScriptField]) -> Bool {
            guard fields.count == 3, stringReferences.count == 10, (try? ScriptForPlan(fields)) != nil else { return false }
            // The three-field path stores its condition and update in Option[0...1].
            return zip(fields.dropFirst(), stringReferences.dropFirst(2)).allSatisfy { field, reference in
                guard let encoded = field.raw.data(using: .utf16LittleEndian) else { return false }
                return encoded.count == reference.length && encoded.sha256Hex == reference.sha256
            }
        }

        var declaredControlFamily: String? {
            switch rawState {
            case 2, 5, 6: return "if"
            case 3, 7, 8, 9: return "for"
            case 4, 10, 11: return "case"
            default: return nil
            }
        }
    }

    package init(threadState state: Data) throws {
        guard state.count >= 16, state.starts(with: "thread\0\0".utf8) else {
            throw ResourceError.rejected("thread_prefix_missing")
        }
        let (version, count) = state.withUnsafeBytes {
            (Int32(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: Int32.self)),
             Int32(littleEndian: $0.loadUnaligned(fromByteOffset: 12, as: Int32.self)))
        }
        guard version == 10 else { throw ResourceError.rejected("unsupported_thread_header") }
        try self.init(state: state, routineCount: count)
    }

    public init(state: Data, routineCount: Int32) throws {
        (decodedOffset, relativeLine, utf16Position, replaceEnableByte, lineBuffer, scriptPath, label,
         textPrefix, emptyLineText, replacementCount, replacements, routines, nextDecodedOffset) = try state.withUnsafeBytes { bytes in
            var offset = 16
            var remainingBlocks = 4096
            var routines: [Routine] = []

            func take(_ size: Int) throws -> Int {
                guard size >= 0, size <= bytes.count - offset else {
                    throw ResourceError.rejected("truncated_thread_record")
                }
                let start = offset
                offset += size
                return start
            }

            func integer() throws -> Int32 {
                Int32(littleEndian: bytes.loadUnaligned(fromByteOffset: try take(4), as: Int32.self))
            }

            func reference() throws -> Reference {
                let units = Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: try take(2), as: Int16.self))
                let length = Int(units) * 2
                let start = try take(length)
                return reference(start: start, length: length)
            }

            func reference(start: Int, length: Int) -> Reference {
                Reference(decodedOffset: start, length: length,
                          sha256: Data(bytes[start..<(start + length)]).sha256Hex)
            }

            func readRoutines(_ count: Int) throws {
                guard (0...1024).contains(count) else {
                    throw ResourceError.rejected("routine_tree_limit")
                }
                for _ in 0..<count {
                    let tag = try take(8)
                    guard bytes[tag..<(tag + 8)].elementsEqual("routine\0".utf8), try integer() == 10 else {
                        throw ResourceError.rejected("unsupported_routine_header")
                    }
                    let scope = try (0..<16).map { _ in try reference() }
                    let rawState = bytes[try take(1)]
                    // TScriptRoutine.State is bounded by the native dispatch at 0x6ac4c2.
                    guard rawState <= 10 else {
                        throw ResourceError.rejected("unsupported_saved_routine_state")
                    }
                    let waitTime = try integer()
                    let skipTime = try integer()
                    let channel = try integer()
                    let jumpLabel = try reference()
                    let eventLabel = try reference()
                    let eventName = try reference()
                    let hasSnapshot = bytes[try take(1)] != 0
                    let snapshotStart = offset
                    var resultStrings: [Reference] = []
                    var resultObjects: [Reference] = []
                    var resultButtonReference: Reference?
                    var resultButtonInts: [Int32] = []
                    var resultButtonStrings: [Reference] = []
                    var resultSubInts: [Int32] = []
                    var resultSubStrings: [Reference] = []
                    var resultClickInt: Int32?
                    var resultStopInt: Int32?
                    if hasSnapshot {
                        _ = try take(64)
                        // 0x6c1676–0x6c1694 restores the first sixteen strings.
                        resultStrings = try (0..<16).map { _ in try reference() }
                        // 0x6c1698–0x6c16ba fills sixteen object reference strings.
                        resultObjects = try (0..<16).map { _ in try reference() }
                        resultButtonReference = try reference()
                        resultButtonInts = try (0..<4).map { _ in try integer() }
                        resultButtonStrings = try (0..<4).map { _ in try reference() }
                        // 0x6c171f–0x6c1743 restores ResultClkInt and ResultStopInt.
                        resultClickInt = try integer()
                        resultStopInt = try integer()
                        resultSubInts = try (0..<4).map { _ in try integer() }
                        resultSubStrings = try (0..<4).map { _ in try reference() }
                    }
                    let snapshot = hasSnapshot ? reference(start: snapshotStart, length: offset - snapshotStart) : nil
                    let children = try integer()
                    guard (0...min(1024, remainingBlocks)).contains(Int(children)) else {
                        throw ResourceError.rejected("saved_control_block_limit")
                    }
                    remainingBlocks -= Int(children)
                    // Routine.Add (0x6c1074) allocates TScriptBlock. Its
                    // reader 0x6c0df0 has a version DWORD and no tag.
                    let blocks = try (0..<Int(children)).map { _ in
                        let start = offset
                        guard try integer() == 10 else {
                            throw ResourceError.rejected("unsupported_saved_control_block_version")
                        }
                        var strings = try (0..<2).map { _ in try reference() }
                        let mode = bytes[try take(1)]
                        let value38 = try integer()
                        let value3C = try integer()
                        strings += try (0..<8).map { _ in try reference() }
                        return ControlBlock(decodedOffset: start, rawState: mode, rawValueAt38: value38,
                                            rawValueAt3C: value3C, stringReferences: strings)
                    }
                    routines.append(Routine(decodedOffset: tag, parentDecodedOffset: nil,
                                            depth: 0, rawState: rawState,
                                            waitTime: waitTime, skipTime: skipTime, channel: channel,
                                            jumpLabel: jumpLabel, eventLabel: eventLabel, eventName: eventName,
                                            scope: scope, resultSnapshot: snapshot,
                                            resultStringReferences: resultStrings,
                                            resultObjectReferences: resultObjects,
                                            resultButtonReference: resultButtonReference, resultButtonInts: resultButtonInts,
                                            resultButtonStrings: resultButtonStrings, resultSubInts: resultSubInts,
                                            resultSubStrings: resultSubStrings, resultClickInt: resultClickInt, resultStopInt: resultStopInt,
                                            hasResultSnapshot: hasSnapshot, childCount: children, controlBlocks: blocks))
                }
            }

            try readRoutines(Int(routineCount))
            let start = offset
            guard bytes.count - start >= 77, try integer() == 10 else {
                throw ResourceError.rejected("invalid_reader_record")
            }
            let line = try integer()
            let position = try integer()
            let replaceEnable = bytes[try take(1)]
            _ = try take(64)

            let lineBuffer = try reference()
            let scriptPath = try reference()
            let label = try reference()
            let prefix = try reference()
            let emptyLine = try reference()
            let replacements = Int(try integer())
            guard (0...65536).contains(replacements), replacements <= (bytes.count - offset) / 8 else {
                throw ResourceError.rejected("reader_replacement_count_limit")
            }
            let entries = try (0..<replacements).map { _ in
                try Replacement(firstText: reference(), secondText: reference(), rawField: integer())
            }
            return (start, line, position, replaceEnable, lineBuffer, scriptPath, label,
                    prefix, emptyLine, replacements, entries, routines, offset)
        }
    }
}

extension SaveReaderCursor {
    /// Validate the reader text and routine data before building frames.
    package func validateRoutinePayloads(in state: Data) throws -> Int {
        for field in [lineBuffer, textPrefix, emptyLineText] {
            _ = try field.utf16Text(in: state)
        }
        for replacement in replacements {
            _ = try replacement.firstText.utf16Text(in: state)
            _ = try replacement.secondText.utf16Text(in: state)
        }
        var snapshots = 0
        for routine in routines {
            for field in routine.scope + [routine.jumpLabel, routine.eventLabel, routine.eventName]
                + routine.resultObjectReferences {
                _ = try field.utf16Text(in: state)
            }
            for block in routine.controlBlocks {
                for field in block.stringReferences { _ = try field.utf16Text(in: state) }
            }
            if let button = routine.resultButtonReference { _ = try button.utf16Text(in: state) }
            if routine.hasResultSnapshot {
                var staged = ScriptStorage()
                try staged.stageRoutineResultScalars(from: routine, in: state)
                snapshots += 1
            }
        }
        return snapshots
    }

    /// Maps a cursor only when its saved buffer matches the original line exactly.
    public func resolveSourcePosition(anchor: ScriptLocation, source: ScriptSource) throws -> ScriptLocation {
        try Self.resolvePosition(anchor: anchor, source: source, relativeLine: relativeLine,
                                 utf16Position: utf16Position, lineBuffer: lineBuffer)
    }

    private static func resolvePosition(anchor: ScriptLocation, source: ScriptSource,
                                        relativeLine: Int32, utf16Position: Int32,
                                        lineBuffer: Reference?) throws -> ScriptLocation {
        guard anchor.sourceFile.utf8.elementsEqual(source.relativePath.utf8),
              anchor.sourceSHA256 == source.sha256 else {
            throw ResourceError.rejected("save_reader_source_mismatch")
        }
        let (target, overflow) = anchor.lineNumber.addingReportingOverflow(Int(relativeLine))
        guard !overflow, target > 0, utf16Position >= 0 else {
            throw ResourceError.rejected("save_reader_cursor_bounds")
        }
        let scalars = source.scalars
        var index = 0
        var line = 1
        while line < target, index < scalars.count {
            let scalar = scalars[index].value
            index += 1
            if scalar == "\r", index < scalars.count, scalars[index].value == "\n" { index += 1 }
            if scalar == "\r" || scalar == "\n" { line += 1 }
        }
        guard line == target, index < scalars.count else { throw ResourceError.rejected("save_reader_line_unavailable") }
        var end = index
        while end < scalars.count, scalars[end].value != "\r", scalars[end].value != "\n" { end += 1 }
        if let lineBuffer {
            let text = source.string(index..<end)
            guard let encoded = text.data(using: .utf16LittleEndian),
                  encoded.count == lineBuffer.length, encoded.sha256Hex == lineBuffer.sha256 else {
                throw ResourceError.rejected("save_reader_line_buffer_differs")
            }
        }
        var position = Int(utf16Position)
        while index < end, position > 0 {
            position -= scalars[index].value.value > 0xffff ? 2 : 1
            index += 1
        }
        guard position <= 0 else { throw ResourceError.rejected("save_reader_cursor_beyond_line") }
        guard position == 0 else { throw ResourceError.rejected("save_reader_cursor_not_scalar_boundary") }
        let byte = index < scalars.count ? scalars[index].bytes.lowerBound : source.data.count
        return source.location(byte..<byte, line: target)
    }

    static func controlPosition(_ block: ControlBlock, in state: Data,
                                   reader: SaveReaderCursor, anchor: ScriptLocation,
                                   program: ScriptProgram) throws -> ScriptLocation {
        let path = try block.stringReferences[0].utf16Text(in: state)
        let label = try block.stringReferences[1].utf16Text(in: state)
        let readerPath = try reader.scriptPath.utf16Text(in: state)
        let readerLabel = try reader.label.utf16Text(in: state)
        guard try ScriptModuleCatalog.key(path) == ScriptModuleCatalog.key(readerPath),
              Data(asciiLower(label).utf8) == Data(asciiLower(readerLabel).utf8),
              let source = program.sources[Data(anchor.sourceFile.utf8)] else {
            throw ResourceError.rejected("saved_control_anchor_differs_from_reader")
        }
        return try resolvePosition(anchor: anchor, source: source, relativeLine: block.rawValueAt38,
                                   utf16Position: block.rawValueAt3C, lineBuffer: nil)
    }

    static func routineReturnPosition(_ block: ControlBlock, in state: Data,
                                      repository: inout ScriptRepository) throws -> (ScriptLocation, Int?, ScriptProgram, ScriptLocation) {
        let path = try block.stringReferences[0].utf16Text(in: state)
        let label = try block.stringReferences[1].utf16Text(in: state)
        let resolved = try resolveLabel(path: path, name: label, repository: &repository)
        guard let source = resolved.program.sources[Data(resolved.location.sourceFile.utf8)] else {
            throw ResourceError.rejected("saved_return_source_unavailable")
        }
        let position = try resolvePosition(anchor: resolved.location, source: source,
            relativeLine: block.rawValueAt38, utf16Position: block.rawValueAt3C, lineBuffer: nil)
        let records = resolved.program.document.records
        let calls = records.indices.dropLast().filter { index in
            let record = records[index]
            let location = record.location
            return record.kind == .command && record.command.map(asciiLower) == "sub" &&
                location.sourceFile.utf8.elementsEqual(position.sourceFile.utf8) &&
                location.sourceSHA256 == position.sourceSHA256 && location.lineNumber == position.lineNumber &&
                location.byteOffset + location.byteLength == position.byteOffset
        }
        let instruction = (try? resolved.program.saveCommandIndex(position)) ??
            (calls.count == 1 ? calls[0] + 1 : nil)
        return (position, instruction, resolved.program, resolved.location)
    }

    /// Resolve a saved label against the explicitly selected script catalog.
    public func resolveLabel(in state: Data, repository: inout ScriptRepository) throws -> (location: ScriptLocation, program: ScriptProgram) {
        let path = try scriptPath.utf16Text(in: state)
        let name = try label.utf16Text(in: state)
        return try Self.resolveLabel(path: path, name: name, repository: &repository)
    }

    private static func resolveLabel(path: String, name: String,
                                     repository: inout ScriptRepository) throws -> (location: ScriptLocation, program: ScriptProgram) {
        guard !path.isEmpty, !path.contains("\0"), !name.isEmpty, !name.contains("\0") else {
            throw ResourceError.rejected("invalid_save_reader_reference")
        }
        let program = try repository.load(path)
        let index = try program.label(name.hasPrefix("@@") ? name : "@@" + name)
        return (program.document.records[index].location, program)
    }
}

extension SaveReaderCursor.Reference {
    /// Decode a saved UTF-16 field without including its contents in encoded reports.
    public func utf16Text(in state: Data) throws -> String {
        guard decodedOffset >= 0, decodedOffset <= state.count,
              length >= 0, length <= state.count - decodedOffset else {
            throw ResourceError.rejected("save_reader_reference_bounds")
        }
        let start = state.startIndex + decodedOffset
        let raw = Data(state[start..<(start + length)])
        guard raw.sha256Hex == sha256, length.isMultiple(of: 2),
              let value = String(data: raw, encoding: .utf16LittleEndian) else {
            throw ResourceError.rejected("invalid_save_reader_reference")
        }
        return value
    }
}

extension ScriptProgram {
    public func sourcePosition(for cursor: SaveReaderCursor, anchor: ScriptLocation) throws -> ScriptLocation {
        guard document.records.contains(where: { $0.kind == .label && $0.location == anchor }) else {
            throw ResourceError.rejected("save_reader_anchor_not_label")
        }
        guard let source = sources[Data(anchor.sourceFile.utf8)] else {
            throw ResourceError.rejected("save_reader_source_unavailable")
        }
        return try cursor.resolveSourcePosition(anchor: anchor, source: source)
    }

    public func commandAtSavePosition(_ position: ScriptLocation) throws -> ScriptLocation {
        try saveCommandBoundary(position).location
    }

    /// Static nesting at the saved command. Active branch and loop state must be restored separately.
    public func saveCommandBoundary(_ position: ScriptLocation) throws -> (location: ScriptLocation, controlDepth: Int) {
        let index = try saveCommandIndex(position)
        return (document.records[index].location, ancestors[index].count)
    }

    package func savedResumeIndex(_ position: ScriptLocation, reader: SaveReaderCursor) throws -> Int {
        if reader.routines.last?.rawState == 3 {
            return try savedTimedWaitSuccessor(position)
        }
        return try saveCommandIndex(position)
    }

    /// Native timed waits leave the reader after the dispatched command.
    func savedTimedWaitSuccessor(_ position: ScriptLocation) throws -> Int {
        let records = document.records
        let waits = records.indices.filter {
            let record = records[$0]
            let location = record.location
            return record.kind == .command && record.command.map(asciiLower) == "wait" &&
                location.sourceFile.utf8.elementsEqual(position.sourceFile.utf8) &&
                location.sourceSHA256 == position.sourceSHA256 && location.lineNumber == position.lineNumber &&
                location.byteOffset + location.byteLength == position.byteOffset
        }
        guard position.byteLength == 0, waits.count == 1,
              let next = records.indices.dropFirst(waits[0] + 1).first(where: {
                  ![.layout, .comment].contains(records[$0].kind)
              }), records[next].location.sourceFile.utf8.elementsEqual(position.sourceFile.utf8) else {
            throw ResourceError.rejected("save_timed_wait_successor_unresolved")
        }
        return next
    }

    func saveCommandIndex(_ position: ScriptLocation) throws -> Int {
        guard position.byteLength == 0 else { throw ResourceError.rejected("save_reader_position_not_cursor") }
        let matches = document.records.indices.filter {
            let record = document.records[$0]
            return record.kind == .command && record.location.sourceFile.utf8.elementsEqual(position.sourceFile.utf8)
                && record.location.sourceSHA256 == position.sourceSHA256
                && record.location.byteOffset == position.byteOffset
                && record.location.lineNumber == position.lineNumber
        }
        guard matches.count == 1 else {
            throw ResourceError.rejected(matches.isEmpty ? "save_command_boundary_missing" : "save_command_boundary_ambiguous")
        }
        return matches[0]
    }
}

extension SaveReaderCursor.Routine {
    func savedResultScalars(in state: Data) throws -> ScriptFrame.SavedResultScalars? {
        guard let integers = try resultIntegers(in: state), let strings = try resultStrings(in: state) else { return nil }
        return .init(integers: integers, strings: strings, click: resultClickInt, stop: resultStopInt,
                     buttonInts: resultButtonInts, buttonStrings: try resultButtonStrings.map { try $0.utf16Text(in: state) },
                     subInts: resultSubInts, subStrings: try resultSubStrings.map { try $0.utf16Text(in: state) })
    }

    public func resultStrings(in state: Data) throws -> [String]? {
        guard hasResultSnapshot else { return nil }
        return try resultStringReferences.map { try $0.utf16Text(in: state) }
    }

    /// Read the sixteen signed ResultInt registers into memory after checking the snapshot identity.
    public func resultIntegers(in state: Data) throws -> [Int32]? {
        guard let snapshot = resultSnapshot else { return nil }
        guard snapshot.length >= 64, snapshot.decodedOffset >= 0, snapshot.decodedOffset <= state.count,
              snapshot.length <= state.count - snapshot.decodedOffset else {
            throw ResourceError.rejected("save_result_snapshot_bounds")
        }
        let start = state.startIndex + snapshot.decodedOffset
        let raw = state[start..<(start + snapshot.length)]
        guard raw.sha256Hex == snapshot.sha256 else {
            throw ResourceError.rejected("save_result_snapshot_identity")
        }
        return raw.withUnsafeBytes { bytes in
            (0..<16).map {
                Int32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 4, as: Int32.self))
            }
        }
    }
}
