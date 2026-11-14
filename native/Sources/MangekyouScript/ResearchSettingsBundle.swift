import Foundation
import MangekyouCore

/// Private, experimental container; neither a game save nor an original config.
struct ResearchSettingsBundle: Codable {
    let schemaVersion: Int
    let systemData: Data
    let systemSHA256: String
    let configurationOverlay: Data
    let configurationSHA256: String

    init(systemData: Data, configurationOverlay: Data) throws {
        guard !systemData.isEmpty, systemData.count <= 8 * 1024 * 1024,
              !configurationOverlay.isEmpty, configurationOverlay.count <= 64 * 1024 else {
            throw ResourceError.rejected("research_settings_bundle_bounds")
        }
        self.schemaVersion = 1
        self.systemData = systemData
        self.systemSHA256 = systemData.sha256Hex
        self.configurationOverlay = configurationOverlay
        self.configurationSHA256 = configurationOverlay.sha256Hex
    }

    static func decode(_ data: Data) throws -> ResearchSettingsBundle {
        guard data.count <= 12 * 1024 * 1024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["schemaVersion", "systemData", "systemSHA256", "configurationOverlay", "configurationSHA256"] else {
            throw ResourceError.rejected("research_settings_bundle_schema")
        }
        let decoded = try JSONDecoder().decode(ResearchSettingsBundle.self, from: data)
        guard decoded.schemaVersion == 1, !decoded.systemData.isEmpty, decoded.systemData.count <= 8 * 1024 * 1024,
              !decoded.configurationOverlay.isEmpty, decoded.configurationOverlay.count <= 64 * 1024,
              decoded.systemData.sha256Hex == decoded.systemSHA256,
              decoded.configurationOverlay.sha256Hex == decoded.configurationSHA256 else {
            throw ResourceError.rejected("research_settings_bundle_identity_or_bounds")
        }
        return decoded
    }

    func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= 12 * 1024 * 1024 else { throw ResourceError.rejected("research_settings_bundle_bounds") }
        return data
    }
}
