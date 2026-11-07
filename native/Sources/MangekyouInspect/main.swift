import Foundation
import MangekyouCore
import MangekyouMedia
import CryptoKit

struct ImageCheck: Encodable {
    let relativePath: String
    let sourceSHA256: String?
    let status: EvidenceStatus
    let width: Int?
    let height: Int?
    let notes: [String]
    let issue: String?
    let originalRendererEquivalence: EvidenceStatus = .notTested
}
struct InspectReport: Encodable {
    let inventory: Inventory
    let imageChecks: [ImageCheck]
    let imageDecodeStatus: EvidenceStatus
}

@main struct Inspect {
    static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard args.count >= 2, args.count <= 3, ["--game-dir", "--assets-dir"].contains(args[0]),
                  args.count == 2 || args[2] == "--verify-images" else {
                throw ResourceError.rejected("Usage: mangekyou-inspect (--game-dir|--assets-dir) PATH [--verify-images]")
            }
            let directory = try SafeDirectory(URL(fileURLWithPath: args[1], isDirectory: true))
            let result = try InventoryScanner().scan(directory)
            var checks: [ImageCheck] = []
            if args.count == 3 {
                let images = result.files.filter { ["PNG", "DPNG", "JPEG"].contains($0.format) }
                guard images.count <= 128 else { throw ResourceError.rejected("image_sample_limit") }
                var total = 0
                let deadline = Date().addingTimeInterval(60)
                for entry in images {
                    do {
                        guard Date() < deadline else { throw ResourceError.rejected("image_time_limit") }
                        let data = try directory.read(entry.relativePath)
                        total += data.count
                        guard total <= 128 * 1024 * 1024 else { throw ResourceError.rejected("image_total_byte_limit") }
                        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                        let decoded = try ResourceImage.decode(data)
                        checks.append(ImageCheck(relativePath: entry.relativePath, sourceSHA256: sha,
                            status: .verified, width: decoded.image.width, height: decoded.image.height, notes: decoded.notes, issue: nil))
                    } catch {
                        checks.append(ImageCheck(relativePath: entry.relativePath, sourceSHA256: nil,
                            status: .unsupported, width: nil, height: nil, notes: [], issue: String(describing: error)))
                    }
                }
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let report = InspectReport(inventory: result, imageChecks: checks, imageDecodeStatus: args.count == 3 && !checks.isEmpty ?
                (checks.allSatisfy { $0.status == .verified } ? .verified : .unsupported) : .notTested)
            FileHandle.standardOutput.write(try encoder.encode(report)); print("")
            if !result.issues.isEmpty || checks.contains(where: { $0.status == .unsupported }) { exit(2) }
        } catch {
            let message = "Mangekyou: \(error)\n"
            FileHandle.standardError.write(Data(message.utf8)); exit(2)
        }
    }
}
