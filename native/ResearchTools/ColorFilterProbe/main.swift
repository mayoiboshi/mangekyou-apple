import CryptoKit
import Foundation
import MangekyouCore
import MangekyouMedia

func sha(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count == 10, args[0] == "--assets-dir", args[2] == "--source",
          args[4] == "--width", args[6] == "--height", args[8] == "--color",
          let width = Int(args[5]), let height = Int(args[7]),
          let color = UInt32(args[9], radix: 16) else {
        throw ResourceError.rejected("color_probe_arguments")
    }
    let directory = try SafeDirectory(URL(fileURLWithPath: args[1], isDirectory: true))
    let input = try directory.read(args[3], limit: 16 * 1024 * 1024)
    let chroma = try ChromaFilterCandidate.desaturate(input, width: width, height: height)
    let output = try ChromaFilterCandidate.screenFill(chroma, width: width, height: height, color: color)
    let receipt: [String: Any] = ["status": "inferred", "inputSHA256": sha(input),
        "width": width, "height": height, "chromaSHA256": sha(chroma),
        "outputSHA256": sha(output), "originalEngineEquivalence": "not_tested"]
    let encoded = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
    FileHandle.standardOutput.write(encoded)
    FileHandle.standardOutput.write(Data([10]))
} catch {
    FileHandle.standardError.write(Data("color_probe_failed: \(error)\n".utf8))
    exit(2)
}
