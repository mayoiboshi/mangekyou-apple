import Foundation

/// Minimal, donor-independent research shell for a timed-wait state.
///
/// It contains only empty path/table/audio collections, empty CalVal storage,
/// and the bounded default engine tail. Live thread, globals, stream records,
/// and engine system fields are assembled separately from the current machine.
/// This is a candidate baseline, not a claim that every game path starts empty.
package enum TimedWaitSaveTemplate {
    package static func emptyState(thread: Data) throws -> Data {
        let reader = try SaveReaderCursor(threadState: thread)
        guard reader.nextDecodedOffset == thread.count, !reader.routines.isEmpty else {
            throw ResourceError.rejected("save_template_thread_boundary")
        }

        var state = Data(thread)
        state.append(Data(repeating: 0, count: 4 + 1))
        var dialogueLog = Data(repeating: 0, count: 76 + 256 * 24)
        withUnsafeBytes(of: Int32(10).littleEndian) {
            dialogueLog.replaceSubrange(0..<4, with: $0)
        }
        state.append(dialogueLog)
        state.append(Data("dsnd\0\0\0\0".utf8))
        appendInt32(0, to: &state)
        state.append(Data("ssnd\0\0\0\0".utf8))
        appendInt32(0, to: &state)

        let generator = Data("vgene\0\0\0".utf8) + Data([3, 0, 0, 0]) + Data(repeating: 0, count: 44)
        var imageLibrary = Data(repeating: 0, count: 0xA5E + 2 + 33 * 6 + 64 * 2 + 256)
        for _ in 0..<4 { imageLibrary.append(generator) }
        imageLibrary.append(Data(repeating: 0, count: 2 + 8 * 6 + 2))
        state.append(imageLibrary)
        state.append(imageLibrary)
        state.append(Data(repeating: 0, count: 140 + 2 + 69 + 4 + 4 + 27 * 14 + 141))
        state.append(Data("CalVal\0\0".utf8))
        state.append(contentsOf: [1, 0, 0, 0])
        state.append(Data(repeating: 0, count: 8))

        state.append(Data(repeating: 0, count: 419 + 14 + 69 + 69 + 4 + 68 + 4))
        state.append(Data("imotwt".utf8))
        state.append(Data(repeating: 0, count: 258 + 53))
        state.append(contentsOf: [1, 0, 0, 0])
        state.append(Data(repeating: 0, count: 121))
        for _ in 0..<4 { state.append(generator) }
        state.append(Data(repeating: 0, count: 4))
        state.append(contentsOf: [1, 0, 0, 0])
        state.append(Data(repeating: 0, count: 24 + 16))

        let rebuiltReader = try SaveReaderCursor(threadState: state)
        let prefix = try SaveStatePrefix(state: state, after: rebuiltReader)
        let calVal = try prefix.locateCalVal(in: state)
        let arrays = try SaveVariableArrays.inspectCalVal(state: state, at: calVal)
        guard rebuiltReader.nextDecodedOffset == thread.count,
              arrays.status == .verified,
              try SaveEngineState(state: state, at: arrays.nextDecodedOffset).status == .verified else {
            throw ResourceError.rejected("save_template_section_boundary")
        }
        return state
    }

    private static func appendInt32(_ value: Int32, to data: inout Data) {
        var word = value.littleEndian
        withUnsafeBytes(of: &word) { data.append(contentsOf: $0) }
    }
}
