import Foundation

public struct TemplateBuildResult {
    public let success: Bool
    public let errorMessage: String?
    public let timedOut: Bool
    public let outputDir: String?

    public init(success: Bool, errorMessage: String? = nil, timedOut: Bool = false, outputDir: String? = nil) {
        self.success = success
        self.errorMessage = errorMessage
        self.timedOut = timedOut
        self.outputDir = outputDir
    }
}

private final class MotionPipeDataBox {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        buffer.append(data)
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}

public protocol MotionBuilderSocketProtocol {
    func buildTemplate(psdPath: String, outputDir: String, templateName: String, layers: [LayerModel]) -> Bool
    func buildTemplateResult(psdPath: String, outputDir: String, templateName: String, layers: [LayerModel], timeout: TimeInterval) -> TemplateBuildResult
}

public final class MotionBuilderSocket: MotionBuilderSocketProtocol {
    public static let shared = MotionBuilderSocket()

    public init() {}

    public func buildTemplateResult(psdPath: String, outputDir: String, templateName: String, layers: [LayerModel], timeout: TimeInterval = 180.0) -> TemplateBuildResult {
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
        defer {
            try? FileManager.default.removeItem(atPath: tempJsonPath)
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted)
            try data.write(to: URL(fileURLWithPath: tempJsonPath))

            let pythonPath = AppConfig.shared.pythonPath
            let bridgePath = AppConfig.shared.bridgeScriptPath

            // UI-G053: 启动前 guard 两路径存在且可执行
            let fm = FileManager.default
            guard fm.fileExists(atPath: pythonPath) else {
                return TemplateBuildResult(success: false, errorMessage: "Python 解释器不存在: \(pythonPath)")
            }
            guard fm.isExecutableFile(atPath: pythonPath) else {
                return TemplateBuildResult(success: false, errorMessage: "Python 解释器不可执行: \(pythonPath)")
            }
            guard fm.fileExists(atPath: bridgePath) else {
                return TemplateBuildResult(success: false, errorMessage: "桥接脚本不存在: \(bridgePath)")
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: pythonPath)
            process.arguments = [bridgePath, "build", tempJsonPath]

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            let outBox = MotionPipeDataBox()
            let errBox = MotionPipeDataBox()
            let readers = DispatchGroup()

            // FCPX-002: 双管道并发读取排空，杜绝子进程写阻塞死锁
            readers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                outBox.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                readers.leave()
            }
            readers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                errBox.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                readers.leave()
            }

            try process.run()

            // FCPX-003: 180s 超时保护 + terminate + 3s 宽限 + SIGKILL
            var timedOut = false
            if readers.wait(timeout: .now() + timeout) == .timedOut {
                timedOut = true
                process.terminate()
                if readers.wait(timeout: .now() + 3) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                    _ = readers.wait(timeout: .now() + 3)
                }
            }
            process.waitUntilExit()

            let outData = outBox.data
            let errText = (String(data: errBox.data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            if timedOut {
                return TemplateBuildResult(success: false, errorMessage: "构建模板超时（超过 \(Int(timeout)) 秒），子进程已强制终止", timedOut: true)
            }

            // FCPX-004: 解析 Python 打到 stdout 的结构化错误与 stderr
            var parsedMessage: String? = nil
            if !outData.isEmpty {
                if let json = try? JSONSerialization.jsonObject(with: outData) as? [String: Any] {
                    if let status = json["status"] as? String, status == "ok" {
                        return TemplateBuildResult(success: true, outputDir: outputDir)
                    }
                    parsedMessage = json["message"] as? String
                }
            }

            if process.terminationStatus == 0 && parsedMessage == nil {
                return TemplateBuildResult(success: true, outputDir: outputDir)
            }

            let lastErrLine = errText.split(separator: "\n").last.map(String.init) ?? ""
            let finalMsg = parsedMessage ?? (!lastErrLine.isEmpty ? lastErrLine : "子进程异常退出 (退出码: \(process.terminationStatus))")
            return TemplateBuildResult(success: false, errorMessage: finalMsg)
        } catch {
            print("Motion Builder Socket Error: \(error)")
            return TemplateBuildResult(success: false, errorMessage: "启动构建进程失败: \(error.localizedDescription)")
        }
    }

    public func buildTemplate(psdPath: String, outputDir: String, templateName: String, layers: [LayerModel]) -> Bool {
        return buildTemplateResult(psdPath: psdPath, outputDir: outputDir, templateName: templateName, layers: layers, timeout: 180.0).success
    }
}
