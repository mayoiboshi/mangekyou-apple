import Foundation

/// Local experimental state only; this is not the original engine's config format.
package struct ResearchConfigurationOverlay: Codable {
    package struct FontValue: Codable {
        let text: String?
        let integer: Int32?
    }
    let schemaVersion: Int
    let baseConfigurationSHA256: String
    let messageValues: [String: Int32]
    let messageAlphaNeedsRendering: Bool
    let displayValues: [String: Int32]?
    let displayNeedsHostUpdate: Bool?
    let displayRefreshRequested: Bool?
    let actorVolumes: [Int32: Int32]
    let actorMutes: [Int32: Int32]
    let actorAliasSHA256: String?
    let audioVolumes: [Int32: Int32]
    let audioMutes: [Int32: Int32]
    let fonts: [String: FontValue]

    static let allowedMessageKeys: Set<String> = ["MessageSpeed", "AutoPlayWaitTime", "AutoPlayClickTime",
        "MessageAlpha", "MessageAlpha1", "MessageAlpha2", "MessageAlpha3"]

    func validate(baseSHA256: String) throws {
        guard schemaVersion == 1, baseConfigurationSHA256 == baseSHA256,
              baseSHA256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              Set(messageValues.keys).isSubset(of: Self.allowedMessageKeys),
              actorVolumes.keys.allSatisfy({ (0..<64).contains($0) }),
              actorMutes.keys.allSatisfy({ (0..<64).contains($0) }),
              audioVolumes.keys.allSatisfy({ (0..<32).contains($0) }),
              audioMutes.keys.allSatisfy({ (0..<32).contains($0) }), fonts.count <= 32 else {
            throw ResourceError.rejected("research_config_overlay_identity_or_bounds")
        }
        for (key, value) in fonts {
            let validName = (0..<8).contains { key == "Font[\($0)].Name" }
            let validInteger = (0..<8).contains { slot in
                ["AA", "Style", "StyleColor"].contains { key == "Font[\(slot)].\($0)" }
            }
            guard (validName && value.integer == nil && value.text != nil && value.text!.utf8.count <= 8192) ||
                  (validInteger && value.text == nil && value.integer != nil) else {
                throw ResourceError.rejected("research_config_overlay_font_outside_profile")
            }
            if key.hasSuffix(".StyleColor"), let integer = value.integer,
               !(0...0x00ff_ffff).contains(integer) {
                throw ResourceError.rejected("research_config_overlay_font_outside_profile")
            }
        }
        if messageValues.keys.contains(where: { $0.hasPrefix("MessageAlpha") }) && !messageAlphaNeedsRendering {
            throw ResourceError.rejected("research_config_overlay_alpha_state_unverified")
        }
        let display = displayValues ?? [:]
        let needsHostUpdate = !display.isEmpty || displayRefreshRequested == true
        guard Set(display.keys).isSubset(of: ["FullScreen", "Interlace"]),
              display.values.allSatisfy({ $0 == 0 || $0 == 1 }),
              (displayNeedsHostUpdate == true) == needsHostUpdate else {
            throw ResourceError.rejected("research_config_overlay_display_state_unverified")
        }
        if !actorVolumes.isEmpty || !actorMutes.isEmpty {
            guard let actorAliasSHA256,
                  actorAliasSHA256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else {
                throw ResourceError.rejected("research_config_overlay_actor_identity_missing")
            }
        } else if actorAliasSHA256 != nil {
            throw ResourceError.rejected("research_config_overlay_actor_identity_unexpected")
        }
    }
}
