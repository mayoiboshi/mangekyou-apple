import Foundation

/// Bounded research decoder for the system-variable section of version-12 data.
/// Automatic read-history tracking and original runtime restoration are not implemented.
package struct SaveSystemData {
    package struct Summary: Encodable {
        let status: EvidenceStatus = .verified
        let mode: Int32
        let sectionLengths: [Int]
        let decodedLength: Int
        let decodedSHA256: String
        let integerArrays: Int
        let stringArrays: Int
        let otherArrays: Int
        package let fileLogEntries: Int
        package let labelLogEntries: Int
        let restoreStatus: EvidenceStatus = .notTested
    }

    let variables: SaveVariableArrays
    package let summary: Summary
    private let source: Data
    private let decodedVariables: Data
    private let firstSection: Range<Int>
    private let fileLogSection: Range<Int>
    private let labelLogSection: Range<Int>
    let fileLog: SaveHashSection
    let labelLog: SaveHashSection
    private let seed: UInt32
    private let template: Data

    static func transform(_ input: Data, seed: UInt32, decode: Bool) -> Data {
        var result = input
        result.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            var low: UInt32 = 0xa73c5f9d, high = low
            var previousLow = (UInt32(bytes.count) &+ seed) ^ 0xfec9753e
            var previousHigh = previousLow
            for offset in stride(from: 0, to: bytes.count & ~7, by: 8) {
                low = (low &+ 0xce24f523) ^ previousLow
                high = (high &+ 0xce24f523) ^ previousHigh
                let inputLow = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                let inputHigh = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self))
                let first = inputLow ^ low, second = inputHigh ^ high
                bytes.storeBytes(of: first.littleEndian, toByteOffset: offset, as: UInt32.self)
                bytes.storeBytes(of: second.littleEndian, toByteOffset: offset + 4, as: UInt32.self)
                previousLow = decode ? first : inputLow
                previousHigh = decode ? second : inputHigh
            }
        }
        return result
    }

    package init(data: Data, headerTemplate: Data) throws {
        let data = Data(data)
        guard try SaveEnvelope(data).kind == "system", data.count >= 136,
              headerTemplate.count == 44 else {
            throw ResourceError.rejected("system_data_header_bounds")
        }
        func word(_ offset: Int) -> UInt32 {
            data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
        }
        let mode = Int32(bitPattern: word(68))
        guard mode == 2 else { throw ResourceError.rejected("system_data_codec_unsupported") }
        var cursor = 136
        var sections: [Range<Int>] = []
        for _ in 0..<3 {
            guard data.count - cursor >= 4 else { throw ResourceError.rejected("system_data_section_bounds") }
            let size = Int(Int32(bitPattern: word(cursor)))
            cursor += 4
            guard size >= 0, size <= data.count - cursor else {
                throw ResourceError.rejected("system_data_section_bounds")
            }
            sections.append(cursor..<(cursor + size))
            cursor += size
        }
        guard cursor == data.count else { throw ResourceError.rejected("system_data_trailing_bytes") }
        let clear = headerTemplate.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        let seed = (word(28) ^ clear ^ (UInt32(0xa73c5f9d) &+ 0xce24f523) ^ 0xfec9753e) &- 32
        var verifiedHeader = Self.transform(data.subdata(in: 28..<60), seed: seed, decode: true)
        verifiedHeader.append(data.subdata(in: 60..<68))
        guard verifiedHeader == headerTemplate.prefix(40) else {
            throw ResourceError.rejected("system_data_header_verification_mismatch")
        }
        let decoded = try SaveRunLength.decode(Self.transform(data.subdata(in: sections[0]), seed: seed, decode: true))
        let arrays = try SaveVariableArrays(state: decoded, decodedOffset: 0)
        guard arrays.nextDecodedOffset == decoded.count else {
            throw ResourceError.rejected("system_variable_trailing_data")
        }
        variables = arrays
        let hashSeed = headerTemplate.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 40, as: UInt32.self)) }
        let log = try SaveHashSection(data.subdata(in: sections[1]), seed: hashSeed)
        let labels = try SaveHashSection(data.subdata(in: sections[2]), seed: hashSeed)
        fileLog = log
        labelLog = labels
        source = data
        decodedVariables = decoded
        firstSection = sections[0]
        fileLogSection = sections[1]
        labelLogSection = sections[2]
        self.seed = seed
        template = headerTemplate
        let integers = arrays.records.count { if case .integers = $0.values { return true }; return false }
        let strings = arrays.records.count { if case .strings = $0.values { return true }; return false }
        summary = Summary(mode: mode, sectionLengths: sections.map(\.count), decodedLength: decoded.count,
                          decodedSHA256: decoded.sha256Hex, integerArrays: integers, stringArrays: strings,
                          otherArrays: arrays.records.count - integers - strings,
                          fileLogEntries: log.values.count, labelLogEntries: labels.values.count)
    }

    package static func headerTemplate(from directory: SafeDirectory, executable: String) throws -> Data {
        let binary = try directory.read(executable, limit: 64 * 1024 * 1024)
        guard binary.sha256Hex == "ad02b1115887b8e5b453d4b5760077e8b63e153bba1161e1704209cf3db5cda5" else {
            throw ResourceError.rejected("save_header_template_exe_identity")
        }
        return binary.subdata(in: 2_810_220..<(2_810_220 + 40)) +
            binary.subdata(in: 946_567..<(946_567 + 4))
    }

    /// Stage only scalar records atomically. Object records need a separate loader.
    func scalarBindings() throws -> [Data: ScriptBinding] {
        guard summary.otherArrays == 0 else {
            throw ResourceError.rejected("system_data_non_scalar_variables_unsupported")
        }
        let staged = try ScriptStorage.stageSavedGlobalScalars(variables)
        guard staged.global.count == variables.records.count else {
            throw ResourceError.rejected("system_data_variable_binding_mismatch")
        }
        return staged.global
    }

    package func validateScalarBindings() throws -> Int {
        try scalarBindings().count
    }

    static func encodeNew(from storage: ScriptStorage, headerTemplate: Data, seed: UInt32) throws -> Data {
        guard headerTemplate.count == 44 else {
            throw ResourceError.rejected("system_data_header_bounds")
        }
        let hashSeed = headerTemplate.withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 40, as: UInt32.self))
        }
        let emptyLog = try SaveHashSection.encodeEmpty(seed: hashSeed)
        let variables = try SaveRunLength.encodeLiterals(Data(repeating: 0, count: 4))
        // 0x6aeb97–0x6aebf8 clears 124 bytes, copies the tag and 40-byte
        // template, sets the codec, then transforms the first 32 template bytes.
        var payload = Data("IMOSYSDATA12".utf8)
        payload.append(Data(repeating: 0, count: 16 - payload.count))
        payload.append(transform(Data(headerTemplate.prefix(32)), seed: seed, decode: false))
        payload.append(headerTemplate.dropFirst(32).prefix(8))
        withUnsafeBytes(of: UInt32(2).littleEndian) { payload.append(contentsOf: $0) }
        payload.append(Data(repeating: 0, count: 64))
        for section in [transform(variables, seed: seed, decode: false), emptyLog, emptyLog] {
            withUnsafeBytes(of: UInt32(section.count).littleEndian) { payload.append(contentsOf: $0) }
            payload.append(section)
        }
        return try Self(data: SaveEnvelope.wrapPayload(payload), headerTemplate: headerTemplate)
            .replacingScalars(from: storage)
    }

    /// Rewrite matched scalars and both explicitly updated log tables.
    func replacingScalars(from storage: ScriptStorage) throws -> Data {
        let originalBindings = try scalarBindings()
        let originalKeys = Set(originalBindings.keys)
        let liveKeys = Set(storage.system.keys)
        let transient = liveKeys.subtracting(originalKeys)
        let missing = originalKeys.subtracting(liveKeys)
        guard missing.isEmpty else {
            throw ResourceError.rejected("system_data_live_bindings_missing_count_\(missing.count)")
        }
        let runtimeResultNames = Set([
            "resultint", "resultstr", "resultobj", "resultclkint", "resultsubint", "resultsubstr",
            "resultbtnint", "resultbtnstr"
        ].map { Data($0.utf8) }).union(storage.transientButtonResultNames)
        let newBindingKeys = transient.subtracting(runtimeResultNames)
        let nonScalarNewBindings = newBindingKeys.filter { key in
            guard let binding = storage.system[key], !binding.elements.isEmpty else { return true }
            return !binding.elements.allSatisfy({ $0.integer != nil }) &&
                !binding.elements.allSatisfy({ $0.typeName == "string" })
        }
        guard nonScalarNewBindings.isEmpty else {
            throw ResourceError.rejected("system_data_new_global_non_scalar_count_\(nonScalarNewBindings.count)")
        }
        var staged = ScriptStorage()
        staged.global = storage.system.filter { originalKeys.contains($0.key) || newBindingKeys.contains($0.key) }
        let header = Data("CalVal\0\0".utf8) + Data([1, 0, 0, 0, 0, 0, 0, 0])
        let encoded = try SaveVariableArrays.encodeCalValValues(template: header + decodedVariables,
            storage: staged, newBindingKeys: newBindingKeys)
        let values = Data(encoded.dropFirst(header.count))
        let packed = try SaveRunLength.encodeLiterals(values)
        let transformed = Self.transform(packed, seed: seed, decode: false)
        let fileLogData = try fileLog.replacingValues(storage.fileLogValues)
        let labelLogData = try labelLog.replacingValues(storage.lineLogValues)
        guard transformed.count + fileLogData.count + labelLogData.count <= SaveEnvelope.maxFileBytes - (source.count - firstSection.count - fileLogSection.count - labelLogSection.count) else {
            throw ResourceError.rejected("system_data_output_limit")
        }
        var payload = Data(source[12..<(firstSection.lowerBound - 4)])
        withUnsafeBytes(of: UInt32(transformed.count).littleEndian) { payload.append(contentsOf: $0) }
        payload.append(transformed)
        withUnsafeBytes(of: UInt32(fileLogData.count).littleEndian) { payload.append(contentsOf: $0) }
        payload.append(fileLogData)
        withUnsafeBytes(of: UInt32(labelLogData.count).littleEndian) { payload.append(contentsOf: $0) }
        payload.append(labelLogData)
        let result = SaveEnvelope.wrapPayload(payload)
        let checked = try Self(data: result, headerTemplate: template)
        guard checked.decodedVariables == values, checked.fileLog.values == storage.fileLogValues,
              checked.labelLog.values == storage.lineLogValues else {
            throw ResourceError.rejected("system_data_output_verification_mismatch")
        }
        return result
    }
}
