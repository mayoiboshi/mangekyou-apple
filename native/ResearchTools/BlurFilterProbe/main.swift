import Foundation
import CryptoKit
import MangekyouCore
import MangekyouMedia

struct Receipt: Encodable {
    let status = "inferred"
    let inputSHA256: String
    let width: Int
    let height: Int
    let decodedBGRAHash: String
    let filteredBGRAHash: String
    let alphaMinimum: UInt8
    let alphaMaximum: UInt8
    let horizontal: Int
    let vertical: Int
    var slotSHA256: String? = nil
    var matchedImageCount: Int? = nil
    var filterReferenceSHA256: String? = nil
    let originalEngineEquivalence = "not_tested"
}

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    guard (args.count == 8 || args.count == 12), args[0] == "--assets-dir", args[2] == "--source",
          args[4] == "--horizontal", args[6] == "--vertical",
          let horizontal = Int(args[5]), let vertical = Int(args[7]),
          args.count == 8 || (args[8] == "--save-dir" && args[10] == "--slot") else {
        throw ResourceError.rejected("blur_probe_arguments")
    }
    let directory = try SafeDirectory(URL(fileURLWithPath: args[1], isDirectory: true))
    let input = try directory.read(args[3], limit: 16 * 1024 * 1024)
    let decoded = try ResourceImage.straightDPNGBytes(input)
    let filtered = try BlurFilterCandidate.apply(decoded.bgra, width: decoded.width, height: decoded.height,
                                                 horizontal: horizontal, vertical: vertical)
    var minimum: UInt8 = 255, maximum: UInt8 = 0
    for index in stride(from: 3, to: decoded.bgra.count, by: 4) {
        minimum = min(minimum, decoded.bgra[index]); maximum = max(maximum, decoded.bgra[index])
    }
    var receipt = Receipt(inputSHA256: sha256(input), width: decoded.width, height: decoded.height,
                          decodedBGRAHash: sha256(decoded.bgra), filteredBGRAHash: sha256(filtered),
                          alphaMinimum: minimum, alphaMaximum: maximum,
                          horizontal: horizontal, vertical: vertical)
    if args.count == 12 {
        let saveDirectory = try SafeDirectory(URL(fileURLWithPath: args[9], isDirectory: true))
        let slot = try saveDirectory.read(args[11], limit: SaveEnvelope.maxFileBytes)
        let state = try SaveEnvelope.decodeSlotState(slot, inferSeed: true)
        let reader = try SaveReaderCursor(threadState: state)
        let prefix = try SaveStatePrefix(state: state, after: reader)
        let offset = try prefix.locateCalVal(in: state)
        let summary = try SaveVariableArrays.inspectCalVal(state: state, at: offset)
        guard let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(summary)) as? [String: Any],
              let images = json["imagePayloads"] as? [[String: Any]] else {
            throw ResourceError.rejected("blur_probe_saved_image_summary")
        }
        func text(_ reference: [String: Any]) throws -> String {
            guard let offset = reference["decodedOffset"] as? Int, let length = reference["length"] as? Int,
                  let digest = reference["sha256"] as? String, offset >= 0, length >= 0,
                  offset <= state.count, length <= state.count - offset, length % 2 == 0 else {
                throw ResourceError.rejected("blur_probe_saved_reference_bounds")
            }
            let bytes = state.subdata(in: offset..<(offset + length))
            guard sha256(bytes) == digest, let value = String(data: bytes, encoding: .utf16LittleEndian) else {
                throw ResourceError.rejected("blur_probe_saved_reference_identity")
            }
            return value
        }
        let parts = args[3].split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { throw ResourceError.rejected("blur_probe_logical_source") }
        let expectedSource = try ScriptModuleCatalog.key(String(parts[1]))
        var matches: [String] = []
        for image in images {
            guard let source = image["imageSource"] as? [String: Any],
                  let names = image["filterNames"] as? [[String: Any]], names.count == 32 else { continue }
            let sourceName = try text(source)
            guard try ScriptModuleCatalog.key(sourceName) == expectedSource else { continue }
            guard (image["drawGate"] as? Int) == 1, (image["enableFlag"] as? Int) == 1,
                  (image["rawActionIndex"] as? Int) == 0,
                  (image["textureSlots"] as? [[String: Any]])?.isEmpty == true,
                  try text(names[0]) == "blur,\(horizontal),\(vertical)",
                  try names.dropFirst().allSatisfy({ try text($0).isEmpty }),
                  let digest = names[0]["sha256"] as? String else {
                throw ResourceError.rejected("blur_probe_saved_filter_outside_profile")
            }
            matches.append(digest)
        }
        guard matches.count == 1 else { throw ResourceError.rejected("blur_probe_saved_image_not_unique") }
        receipt.slotSHA256 = sha256(slot)
        receipt.matchedImageCount = matches.count
        receipt.filterReferenceSHA256 = matches[0]
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(receipt))
    FileHandle.standardOutput.write(Data([10]))
} catch {
    FileHandle.standardError.write(Data("blur_probe_failed: \(error)\n".utf8))
    exit(2)
}
