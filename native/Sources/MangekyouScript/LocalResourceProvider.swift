import Foundation
import Darwin
import MangekyouCore

struct LocalResourceProvider: Sendable {
    let executable: URL
    let cache: [String: ScriptModuleReference]

    private func emitReceipt(_ reference: ScriptModuleReference) throws -> ScriptModuleReference {
        let receipt = try JSONEncoder().encode(reference)
        FileHandle.standardError.write(Data("supplied_resource=".utf8) + receipt + Data([10]))
        return reference
    }

    func load(_ logical: String) throws -> ScriptModuleReference {
        let key = try ScriptModuleCatalog.key(logical).sha256Hex
        if let reference = cache[key] { return try emitReceipt(reference) }
        let process = Process()
        let output = Pipe()
        let done = DispatchSemaphore(value: 0)
        process.executableURL = executable
        process.arguments = [key]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + 15) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            throw ResourceError.rejected("resource_provider_timeout")
        }
        guard process.terminationStatus == 0 else {
            throw ResourceError.rejected("resource_provider_failed")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard data.count <= 16 * 1024 else { throw ResourceError.rejected("resource_provider_receipt_limit") }
        let reference = try JSONDecoder().decode(ScriptModuleReference.self, from: data)
        return try emitReceipt(reference)
    }
}
