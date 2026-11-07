import Foundation

public protocol MotionBuilderSocketProtocol {
    func buildTemplate(psdPath: String, outputDir: String, templateName: String, layers: [LayerModel]) -> Bool
}

public final class MotionBuilderSocket: MotionBuilderSocketProtocol {
    public static let shared = MotionBuilderSocket()

    public init() {}

    public func buildTemplate(psdPath: String, outputDir: String, templateName: String, layers: [LayerModel]) -> Bool {
        var layersList: [[String: Any]] = []
        for l in layers {
            let item: [String: Any] = [
                "index": l.id,
                "name": l.name,
                "text": l.text,
                "font_name": l.fontName,
                "font_size": l.fontSize,
                "tracking": l.tracking,
                "motion_pos": [l.posX, l.posY],
                "visible": l.visible,
                "is_published": l.isPublished,
                "rotation": l.rotation,
                "scale_x": l.scaleX,
                "scale_y": l.scaleY,
                "opacity": l.opacity,
                "writing_direction": l.writingDirection,
                "published_channels": [
                    "text": l.publishText,
                    "font": l.publishFont,
                    "size": l.publishSize,
                    "tracking": l.publishTracking,
                    "position": l.publishPosition,
                    "rotation": l.publishRotation,
                    "scale": l.publishScale,
                    "alignment": true
                ]
            ]
            layersList.append(item)
        }

        let payload: [String: Any] = [
            "psd_path": psdPath,
            "output_dir": outputDir,
            "template_name": templateName,
            "layers": layersList
        ]

        let tempJsonPath = NSTemporaryDirectory() + "fcpx_build_\(UUID().uuidString).json"
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted)
            try data.write(to: URL(fileURLWithPath: tempJsonPath))

            let pythonPath = AppConfig.shared.pythonPath
            let bridgePath = AppConfig.shared.bridgeScriptPath

            let process = Process()
            process.executableURL = URL(fileURLWithPath: pythonPath)
            process.arguments = [bridgePath, "build", tempJsonPath]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()

            try? FileManager.default.removeItem(atPath: tempJsonPath)
            return process.terminationStatus == 0
        } catch {
            print("Motion Builder Socket Error: \(error)")
            return false
        }
    }
}
