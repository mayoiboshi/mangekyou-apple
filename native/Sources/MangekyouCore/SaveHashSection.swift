import Foundation

/// Narrow HashVer1.4 profile for the system file-log's four-byte values.
struct SaveHashSection {
    private let header: Data
    private let original: Data
    private let seed: UInt32
    let values: [Data: Int32]

    static func encodeEmpty(seed: UInt32) throws -> Data {
        let packed = try SaveRunLength.encodeLiterals(Data(repeating: 0, count: 256 * 4))
        let encoded = SaveSystemData.transform(packed, seed: seed, decode: false)
        // 0x4e7d9d–0x4e7dfb clears the 68-byte header before writing the
        // format tag, bucket count, lengths, codec and flags.
        var data = Data("HashVer1.4".utf8) + Data(repeating: 0, count: 6)
        for word: UInt32 in [256, 0, 0, UInt32(encoded.count), 2] {
            withUnsafeBytes(of: word.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(Data(repeating: 0, count: 32))
        data.append(encoded)
        return data
    }

    private static func hash(_ text: String) -> UInt32 {
        text.utf16.enumerated().reduce(UInt32(0)) { partial, item in
            (partial &+ (UInt32(item.element) << ((item.offset + 1) & 7))) & 0x3fff_ffff
        }
    }

    private static func bucket(_ hash: UInt32) -> Int {
        Int(((hash >> 16) &+ (hash >> 8) &+ (hash & 0xffff)) & 0xff)
    }

    init(_ source: Data, seed: UInt32) throws {
        let source = Data(source)
        guard source.count >= 68, source.prefix(16).elementsEqual(Data("HashVer1.4".utf8) + Data(repeating: 0, count: 6)) else {
            throw ResourceError.rejected("system_hash_header_unsupported")
        }
        func word(_ offset: Int) -> UInt32 {
            source.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
        }
        let count = Int(word(20)), dataLength = Int(word(24)), encodedLength = Int(word(28))
        guard word(16) == 256, count <= 20_000, dataLength == count * 4,
              encodedLength == source.count - 68, word(32) == 2, word(36) == 0 else {
            throw ResourceError.rejected("system_hash_profile_unsupported")
        }
        let packed = SaveSystemData.transform(source.subdata(in: 68..<source.count), seed: seed, decode: true)
        let data = try SaveRunLength.decode(packed)
        var cursor = 0
        func take(_ length: Int) throws -> Data {
            guard length >= 0, length <= data.count - cursor else {
                throw ResourceError.rejected("system_hash_record_bounds")
            }
            defer { cursor += length }
            return data.subdata(in: cursor..<(cursor + length))
        }
        func read32() throws -> UInt32 {
            try take(4).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        }
        var items: [(Data, Int)] = []
        var offsets = Set<Int>()
        var names = Set<Data>()
        for bucket in 0..<256 {
            let countInBucket = Int(try read32())
            guard countInBucket <= count - items.count else { throw ResourceError.rejected("system_hash_entry_count") }
            for _ in 0..<countInBucket {
                let units = try take(2).withUnsafeBytes { Int(Int16(littleEndian: $0.loadUnaligned(as: Int16.self))) }
                guard (1...4096).contains(units), let name = String(data: try take(units * 2), encoding: .utf16LittleEndian),
                      name.utf8.count <= 8192, asciiLower(name) == name else {
                    throw ResourceError.rejected("system_hash_key_unsupported")
                }
                let offset = try take(8).withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
                let hash = try read32()
                let key = Data(name.utf8)
                guard hash == Self.hash(name), Self.bucket(hash) == bucket,
                      offset <= UInt64(max(0, dataLength - 4)), offset % 4 == 0,
                      names.insert(key).inserted, offsets.insert(Int(offset)).inserted else {
                    throw ResourceError.rejected("system_hash_entry_identity")
                }
                items.append((key, Int(offset)))
            }
        }
        guard items.count == count, data.count - cursor == dataLength else {
            throw ResourceError.rejected("system_hash_data_boundary")
        }
        var values: [Data: Int32] = [:]
        for (key, offset) in items {
            let value = data.withUnsafeBytes { Int32(littleEndian: $0.loadUnaligned(fromByteOffset: cursor + offset, as: Int32.self)) }
            values[key] = value
        }
        self.header = Data(source.prefix(68))
        self.original = source
        self.seed = seed
        self.values = values
    }

    func replacingValues(_ values: [Data: Int32]) throws -> Data {
        if values == self.values { return original }
        guard values.count <= 20_000 else { throw ResourceError.rejected("system_hash_entry_count") }
        var buckets = [[(String, UInt32, Int32)]](repeating: [], count: 256)
        for key in values.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            guard let name = String(data: key, encoding: .utf8), !name.isEmpty, name.utf8.count <= 8192,
                  name.utf16.count <= 4096, asciiLower(name) == name, let value = values[key] else {
                throw ResourceError.rejected("system_hash_key_unsupported")
            }
            let h = Self.hash(name)
            buckets[Self.bucket(h)].append((name, h, value))
        }
        var records = Data(), payload = Data()
        func append32(_ value: UInt32, to output: inout Data) {
            withUnsafeBytes(of: value.littleEndian) { output.append(contentsOf: $0) }
        }
        for bucket in buckets {
            append32(UInt32(bucket.count), to: &records)
            for (name, hash, value) in bucket {
                guard let text = name.data(using: .utf16LittleEndian),
                      let units = Int16(exactly: name.utf16.count) else { throw ResourceError.rejected("system_hash_key_unsupported") }
                withUnsafeBytes(of: units.littleEndian) { records.append(contentsOf: $0) }
                records.append(text)
                withUnsafeBytes(of: UInt64(payload.count).littleEndian) { records.append(contentsOf: $0) }
                append32(hash, to: &records)
                append32(UInt32(bitPattern: value), to: &payload)
                guard records.count + payload.count <= SaveEnvelope.maxFileBytes else {
                    throw ResourceError.rejected("system_hash_output_limit")
                }
            }
        }
        records.append(payload)
        let packed = try SaveRunLength.encodeLiterals(records)
        let transformed = SaveSystemData.transform(packed, seed: seed, decode: false)
        guard transformed.count <= SaveEnvelope.maxFileBytes - header.count else { throw ResourceError.rejected("system_hash_output_limit") }
        var output = header
        for (offset, number) in [(20, UInt32(values.count)), (24, UInt32(payload.count)), (28, UInt32(transformed.count))] {
            withUnsafeBytes(of: number.littleEndian) { output.replaceSubrange(offset..<(offset + 4), with: $0) }
        }
        output.append(transformed)
        guard try Self(output, seed: seed).values == values else { throw ResourceError.rejected("system_hash_output_verification") }
        return output
    }
}
