import Foundation
import MangekyouCore
import MangekyouMedia

struct HeadlessSystemCapture {
    let bytes: Data
    let canvasSHA256: String

    init(scene paused: ScriptMachine, priority: Int32, assets: SafeDirectory,
         recipe: ScriptImageRecipe, saveDirectory: SafeDirectory?, movieHost: HeadlessMovieHost?) throws {
        guard paused.moviePlaybackRequest == nil else {
            throw ResourceError.rejected("game_thread_video_capture_unsupported")
        }
        var rendered: Data?
        let scene = try LoadThumbnailPass(task: paused, assets: assets, recipe: recipe,
            backgroundPath: nil, saveDirectory: saveDirectory, atDrawRequest: true,
            capturePriority: priority, canvasSize: SIMD2(1280, 720), forSystemCapture: true,
            sceneVideoFrame: movieHost.map { host in { source, ticks in
                try host.standaloneSceneFrame(source, ticks: ticks)
            } }, exportPNG: { rendered = $0 })
        // The strict research preview also flags verified local draws such
        // as standalone video. A capture requires the local frame to have
        // no omitted layers, unresolved text, or static interface fallback.
        guard scene.omittedLayers.isEmpty, scene.textPreviewIssues.isEmpty,
              scene.interfaceBackgroundPreviews.isEmpty else {
            let omitted = scene.omittedLayers.prefix(4).map { layer in
                let children = layer.directNestedMotions?.prefix(4).map { child in
                    let reasons = child.omittedDrawKeys.prefix(2).map { key in
                        "\(key.type)@\(key.offset):\(key.reason.prefix(128))"
                    }.joined(separator: ",")
                    return "slot=\(child.slot)/action=\(child.action)/ticks=\(child.ticks)/unresolved=\(child.unresolvedCount)" +
                        (reasons.isEmpty ? "" : " [\(reasons)]")
                }.joined(separator: " ") ?? ""
                let keys = layer.sampledKeys?.prefix(8).map { "\($0.type)@\($0.byteOffset)" }.joined(separator: "/")
                let motion = [layer.selectedMember.map { "action=\($0)" },
                              layer.motionElapsedTicks.map { "ticks=\($0)" },
                              keys.map { "keys=\($0)" }].compactMap { $0 }.joined(separator: " ")
                let details = [motion, children].filter { !$0.isEmpty }.joined(separator: " ")
                return "\(layer.resource.sourceFile)=\(layer.reason)" + (details.isEmpty ? "" : " [\(details)]")
            }.joined(separator: ",")
            let text = scene.textPreviewIssues.sorted(by: { $0.key < $1.key }).prefix(4).map { id, reason in
                "\(id)=\(reason.prefix(256))"
            }.joined(separator: ",")
            let fallbackResources = scene.interfaceBackgroundPreviews.prefix(4).map(\.sourceFile)
                .joined(separator: ",")
            let details = [omitted, text, fallbackResources].filter { !$0.isEmpty }.joined(separator: " ")
            throw ResourceError.rejected("game_thread_scene_capture_incomplete: omitted=\(scene.omittedLayers.count) text=\(scene.textPreviewIssues.count) interface_fallbacks=\(scene.interfaceBackgroundPreviews.count) \(details)")
        }
        guard let rendered else { throw ResourceError.rejected("game_thread_image_capture_render_failed") }
        bytes = rendered
        canvasSHA256 = scene.canvasSHA256
    }
}
