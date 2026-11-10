import Foundation

/// TR-020：调用内置 Python 的 png_split.py（PIL / numpy / scipy.ndimage / psd_tools）。
/// 只做进程调用与 JSON 解码，不在这里决定任何层数。
public struct PngSplitFailure: Error {
    public let message: String
}

public enum PngSplitSocket {

    /// 脚本查找顺序：App 内置资源 → App 同级仓库 → 当前工作目录 → 项目根。
    public static func scriptPath() -> String? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let res = Bundle.main.resourcePath {
            candidates.append((res as NSString).appendingPathComponent("tools/tr020/png_split.py"))
        }
        let root = (Bundle.main.bundlePath as NSString).deletingLastPathComponent
        candidates.append((root as NSString).appendingPathComponent("tools/tr020/png_split.py"))
        candidates.append((fm.currentDirectoryPath as NSString).appendingPathComponent("tools/tr020/png_split.py"))
        candidates.append("/Volumes/摄影师工具箱128GB/未命名文件夹/FCPX_Studio_Pro/tools/tr020/png_split.py")
        return candidates.first { fm.isReadableFile(atPath: $0) }
    }

    private struct Reply: Codable {
        let status: String
        let message: String?
    }

    private static func run(_ args: [String]) -> Result<Data, PngSplitFailure> {
        guard let script = scriptPath() else {
            return .failure(PngSplitFailure(message: "找不到 tools/tr020/png_split.py，无法预切。"))
        }
        let python = AppConfig.shared.pythonPath
        guard FileManager.default.isExecutableFile(atPath: python) else {
            return .failure(PngSplitFailure(message: "Python 解释器不可执行：\(python)"))
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = [script] + args
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do {
            try proc.run()
        } catch {
            return .failure(PngSplitFailure(message: "启动分析进程失败：\(error.localizedDescription)"))
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let detail = String(data: errData, encoding: .utf8) ?? ""
            return .failure(PngSplitFailure(message: "分析进程退出码 \(proc.terminationStatus)：\(detail.prefix(600))"))
        }
        return .success(data)
    }

    /// 预切：产出 candidates.json / 缩略图 / 框选预览。绝不写回原 PNG。
    public static func analyze(pngPath: String, workDir: String) -> Result<PngSplitDocument, PngSplitFailure> {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: workDir, withIntermediateDirectories: true)
        switch run(["analyze", "--src", pngPath, "--out", workDir]) {
        case .failure(let e):
            return .failure(e)
        case .success:
            break
        }
        let path = (workDir as NSString).appendingPathComponent("candidates.json")
        guard let data = fm.contents(atPath: path) else {
            return .failure(PngSplitFailure(message: "没有生成 candidates.json"))
        }
        do {
            let doc = try JSONDecoder().decode(PngSplitDocument.self, from: data)
            return .success(doc)
        } catch {
            return .failure(PngSplitFailure(message: "candidates.json 解码失败：\(error.localizedDescription)"))
        }
    }

    /// 按人工批准的 approved.json 切块 + 写多层 PSD。返回 PSD 路径。
    public static func commit(pngPath: String, workDir: String,
                              approvedPath: String, psdPath: String) -> Result<String, PngSplitFailure> {
        switch run(["commit", "--src", pngPath, "--out", workDir,
                    "--approved", approvedPath, "--psd", psdPath]) {
        case .failure(let e):
            return .failure(e)
        case .success(let data):
            if let reply = try? JSONDecoder().decode(Reply.self, from: data),
               reply.status != "ok" {
                return .failure(PngSplitFailure(message: reply.message ?? "导出失败"))
            }
            guard FileManager.default.fileExists(atPath: psdPath) else {
                return .failure(PngSplitFailure(message: "PSD 未生成：\(psdPath)"))
            }
            return .success(psdPath)
        }
    }
}
