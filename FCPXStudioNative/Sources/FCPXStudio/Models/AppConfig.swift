import Foundation
import Metal

// ═══════════════════════════════════════════════════════════════
//  AppConfig —— 应用全局配置与多源级联便携环境探测器（D-82 / D-83）
//
//  级联探测链：
//    1. 优先内置便携包（Contents/Resources/python_bundle 或 Contents/Frameworks）；
//    2. 环境变量（FCPX_STUDIO_PYTHON / VIRTUAL_ENV）；
//    3. 项目/工作目录虚拟环境（.venv / venv）；
//    4. 系统与包管理器环境（/opt/homebrew、/usr/local、/usr/bin）。
//
//  核心依赖完整性自检：
//    - 检查 psd-tools 与核心 Python bridge 完整性；
//    - 为设置面板与诊断系统提供便携化就绪状态。
// ═══════════════════════════════════════════════════════════════

public final class AppConfig {
    public static let shared = AppConfig()

    public private(set) var pythonPath: String
    public let bridgeScriptPath: String
    public let defaultPsdDir: String = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path

    // MARK: - R47 版本与硬件加速状态
    public let appVersionString: String = "v1.0.0 (Build 20261106.R47 - Commercial)"
    public var hardwareAccelerationSummary: String {
        if let device = MTLCreateSystemDefaultDevice() {
            return "🟢 Metal 硬件加速就绪 (\(device.name))"
        } else {
            return "🟡 软件渲染模式 (CPU 纯净计算)"
        }
    }

    // MARK: – R46 多目标导出路径与智能降级
    public enum ExportDestinationMode: String, CaseIterable {
        case smartAuto = "智能自适应 (优先外置，未插盘降级本地)"
        case externalSSD = "外置高速存储"
        case localSystem = "系统本地模板库"
        case custom = "自定义保存目录"
    }

    public struct ResolvedExportDestination {
        public let targetDir: String
        public let externalRoot: String?
        public let isExternal: Bool
        public let fallbackUsed: Bool
        public let summary: String

        public init(targetDir: String, externalRoot: String?, isExternal: Bool, fallbackUsed: Bool, summary: String) {
            self.targetDir = targetDir
            self.externalRoot = externalRoot
            self.isExternal = isExternal
            self.fallbackUsed = fallbackUsed
            self.summary = summary
        }
    }

    public var exportDestinationMode: ExportDestinationMode = .smartAuto
    public var customExportDir: String? = nil

    // UI-G069: 不硬编码开发者卷名，初始为空，由首启引导或用户配置存入 UserDefaults
    private static let externalDirKey = "FCPXStudio_PreferredExternalDir"
    public var defaultExternalAssetsDir: String {
        get { return UserDefaults.standard.string(forKey: Self.externalDirKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Self.externalDirKey) }
    }
    public var preferredExternalDir: String {
        get { return defaultExternalAssetsDir }
        set { defaultExternalAssetsDir = newValue }
    }
    public var systemMotionTemplatesRoot: String = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Motion Templates.localized").path

    public var defaultLocalTitlesDir: String {
        return "\(systemMotionTemplatesRoot)/Titles.localized/PSD婚礼字幕"
    }

    public func resolveExportDestination(
        category: String = "Titles.localized",
        groupName: String = "PSD婚礼字幕"
    ) -> ResolvedExportDestination {
        let fm = FileManager.default
        let localBase = "\(systemMotionTemplatesRoot)/\(category)/\(groupName)"

        // 1. 自定义导出目录
        if exportDestinationMode == .custom, let custom = customExportDir, !custom.isEmpty {
            try? fm.createDirectory(atPath: custom, withIntermediateDirectories: true)
            return ResolvedExportDestination(
                targetDir: custom,
                externalRoot: nil,
                isExternal: false,
                fallbackUsed: false,
                summary: "自定义输出目录: \(custom)"
            )
        }

        // 2. 纯本地系统盘模式
        if exportDestinationMode == .localSystem {
            cleanBrokenSymlinkIfNeeded(at: localBase)
            try? fm.createDirectory(atPath: localBase, withIntermediateDirectories: true)
            return ResolvedExportDestination(
                targetDir: localBase,
                externalRoot: nil,
                isExternal: false,
                fallbackUsed: false,
                summary: "系统本地目录: \(localBase)"
            )
        }

        // 3. 优先探测外置存储
        let candidate = preferredExternalDir.trimmingCharacters(in: .whitespacesAndNewlines)
        var availableExternalRoot: String? = nil

        if !candidate.isEmpty {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate, isDirectory: &isDir) && isDir.boolValue {
                if fm.isWritableFile(atPath: candidate) {
                    availableExternalRoot = candidate
                }
            } else {
                // 如果是 /Volumes/ 下的外置存储设备，探测挂载卷是否存在且可写
                let comps = (candidate as NSString).pathComponents
                if comps.count >= 3 && comps[1] == "Volumes" {
                    let volPath = "/\(comps[1])/\(comps[2])"
                    var volIsDir: ObjCBool = false
                    if fm.fileExists(atPath: volPath, isDirectory: &volIsDir) && volIsDir.boolValue && fm.isWritableFile(atPath: volPath) {
                        try? fm.createDirectory(atPath: candidate, withIntermediateDirectories: true)
                        availableExternalRoot = candidate
                    }
                }
            }
        }

        if let extRoot = availableExternalRoot {
            let extTarget = "\(extRoot)/\(category)/\(groupName)"
            try? fm.createDirectory(atPath: extTarget, withIntermediateDirectories: true)
            return ResolvedExportDestination(
                targetDir: extTarget,
                externalRoot: extRoot,
                isExternal: true,
                fallbackUsed: false,
                summary: "外置存储目标 (就绪软链): \(extTarget)"
            )
        }

        // 4. 外置盘不可用时，自动无缝降级到本地系统盘（UI-G069: 界面明确提示原因与降级目标）
        cleanBrokenSymlinkIfNeeded(at: localBase)
        try? fm.createDirectory(atPath: localBase, withIntermediateDirectories: true)
        let reason = candidate.isEmpty ? "未配置外置卷目录，已安全降级至内置盘" : "外置存储未挂载，已安全降级至内置盘"
        return ResolvedExportDestination(
            targetDir: localBase,
            externalRoot: nil,
            isExternal: false,
            fallbackUsed: true,
            summary: "\(reason): \(localBase)"
        )
    }

    private func cleanBrokenSymlinkIfNeeded(at path: String) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: path, isDirectory: &isDir) {
            if (try? fm.destinationOfSymbolicLink(atPath: path)) != nil {
                try? fm.removeItem(atPath: path)
            }
        }
    }

    public let isPortableEnvironment: Bool
    public private(set) var hasPsdTools: Bool
    public private(set) var environmentSummary: String

    private init() {
        let fm = FileManager.default

        // ── 1. 级联探测 Python 解释器 ──
        var detectedPython = ""
        var isPortable = false

        // 优先级 1：内置便携环境 (App Bundle 内置 python_bundle / Frameworks / Resources)
        let bundleURL = Bundle.main.bundleURL
        let embeddedCandidates = [
            bundleURL.appendingPathComponent("Contents/Resources/python_bundle/bin/python3").path,
            bundleURL.appendingPathComponent("Contents/Resources/python_bundle/bin/python").path,
            bundleURL.appendingPathComponent("Contents/Frameworks/Python.framework/Versions/Current/bin/python3").path,
            bundleURL.appendingPathComponent("Contents/Resources/python/bin/python3").path,
            bundleURL.appendingPathComponent("Contents/Resources/venv/bin/python3").path
        ]
        for candidate in embeddedCandidates {
            if fm.fileExists(atPath: candidate) {
                detectedPython = candidate
                isPortable = true
                break
            }
        }

        // 开发与测试阶段：如果在独立 Harness 进程中运行，向前向上级联检索当前工程 App Bundle 中的便携包
        if !isPortable {
            let devSearchRoots = [
                URL(fileURLWithPath: fm.currentDirectoryPath),
                URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("FCPX_Studio_Pro"),
                bundleURL,
                bundleURL.deletingLastPathComponent(),
                bundleURL.deletingLastPathComponent().deletingLastPathComponent(),
                bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            ]
            for root in devSearchRoots {
                let devCandidate = root.appendingPathComponent("FCPX Studio Pro.app/Contents/Resources/python_bundle/bin/python3").path
                if fm.fileExists(atPath: devCandidate) {
                    detectedPython = devCandidate
                    isPortable = true
                    break
                }
            }
        }

        // 优先级 2：环境变量显式指定 (FCPX_STUDIO_PYTHON 或激活的 VIRTUAL_ENV)
        if !isPortable {
            let env = ProcessInfo.processInfo.environment
            if let customPy = env["FCPX_STUDIO_PYTHON"], fm.fileExists(atPath: customPy) {
                detectedPython = customPy
            } else if let venv = env["VIRTUAL_ENV"] {
                let venvPy = URL(fileURLWithPath: venv).appendingPathComponent("bin/python3").path
                if fm.fileExists(atPath: venvPy) {
                    detectedPython = venvPy
                    isPortable = true
                }
            }
        }

        // 优先级 3：工作区或上级目录 .venv / venv
        if !isPortable {
            let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
            let localVenvs = [
                cwd.appendingPathComponent(".venv/bin/python3").path,
                cwd.appendingPathComponent("venv/bin/python3").path,
                bundleURL.deletingLastPathComponent().appendingPathComponent(".venv/bin/python3").path
            ]
            for candidate in localVenvs {
                if fm.fileExists(atPath: candidate) {
                    detectedPython = candidate
                    isPortable = true
                    break
                }
            }
        }

        // 优先级 4：系统级与包管理器备选项
        if !isPortable || detectedPython.isEmpty {
            let standardCandidates = [
                "/opt/homebrew/bin/python3",
                "/usr/local/bin/python3",
                "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
                "/usr/bin/python3"
            ]
            var fallbackCandidate: String? = nil
            for candidate in standardCandidates {
                if fm.fileExists(atPath: candidate) && fm.isExecutableFile(atPath: candidate) {
                    fallbackCandidate = candidate
                    break
                }
            }
            if detectedPython.isEmpty {
                if let cand = fallbackCandidate {
                    detectedPython = cand
                } else if fm.fileExists(atPath: "/usr/bin/python3") && fm.isExecutableFile(atPath: "/usr/bin/python3") {
                    detectedPython = "/usr/bin/python3"
                } else {
                    // FCPX-014: 兜底路径不可执行或不存在时，明写未找到可用 python3
                    detectedPython = ""
                }
            }
        }

        self.pythonPath = detectedPython
        self.isPortableEnvironment = isPortable

        // ── 2. 级联探测 cli_bridge.py ──
        var detectedBridge = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("core/cli_bridge.py").path

        // 优先级 1：内置 Resources
        let embeddedBridgeCandidates = [
            bundleURL.appendingPathComponent("Contents/Resources/core/cli_bridge.py").path,
            bundleURL.appendingPathComponent("Contents/Resources/cli_bridge.py").path
        ]
        var foundEmbeddedBridge = false
        for candidate in embeddedBridgeCandidates {
            if fm.fileExists(atPath: candidate) {
                detectedBridge = candidate
                foundEmbeddedBridge = true
                break
            }
        }

        // 开发与测试阶段：向前向上级联检索当前工程 App Bundle 中的 Resources/core
        if !foundEmbeddedBridge {
            let devSearchRoots = [
                URL(fileURLWithPath: fm.currentDirectoryPath),
                URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("FCPX_Studio_Pro"),
                bundleURL,
                bundleURL.deletingLastPathComponent(),
                bundleURL.deletingLastPathComponent().deletingLastPathComponent(),
                bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            ]
            for root in devSearchRoots {
                let devCandidate = root.appendingPathComponent("FCPX Studio Pro.app/Contents/Resources/core/cli_bridge.py").path
                if fm.fileExists(atPath: devCandidate) {
                    detectedBridge = devCandidate
                    foundEmbeddedBridge = true
                    break
                }
            }
        }

        // 优先级 2：环境变量 FCPX_STUDIO_BRIDGE
        if !foundEmbeddedBridge {
            if let customBridge = ProcessInfo.processInfo.environment["FCPX_STUDIO_BRIDGE"],
               fm.fileExists(atPath: customBridge) {
                detectedBridge = customBridge
                foundEmbeddedBridge = true
            }
        }

        // 优先级 3：动态向上追溯查找
        if !foundEmbeddedBridge {
            var searchDir = bundleURL
            for _ in 0..<6 {
                let candidate = searchDir.appendingPathComponent("core/cli_bridge.py").path
                if fm.fileExists(atPath: candidate) {
                    detectedBridge = candidate
                    break
                }
                let candidateInParent = searchDir.appendingPathComponent("FCPX_Studio_Pro/core/cli_bridge.py").path
                if fm.fileExists(atPath: candidateInParent) {
                    detectedBridge = candidateInParent
                    break
                }
                searchDir = searchDir.deletingLastPathComponent()
            }
        }

        self.bridgeScriptPath = detectedBridge

        // ── 3. 依赖完整性校验 (FCPX-014 & FCPX-015: 移后台异步检测，首屏 0ms 阻塞) ──
        let pythonExecutable = !detectedPython.isEmpty && fm.isExecutableFile(atPath: detectedPython)
        let modeStr = isPortable ? "便携模式 (Zero-Dependency Standalone)" : "主机系统模式"

        if !pythonExecutable {
            self.hasPsdTools = false
            self.environmentSummary = "[\(modeStr)] Python: 未找到可用 python3 · ⚠︎ 未找到可用 python3"
        } else {
            // 首屏快速先标记可用，后台线程 10s 超时精确自检
            self.hasPsdTools = true
            self.environmentSummary = "[\(modeStr)] Python: \(detectedPython) · 核心环境自检中..."
            DispatchQueue.global(qos: .userInitiated).async { [detectedPython, modeStr] in
                let ok = AppConfig.checkPsdTools(python: detectedPython)
                DispatchQueue.main.async {
                    AppConfig.shared.hasPsdTools = ok
                    let depStr = ok ? "psd-tools 核心引擎正常" : "⚠︎ 缺失 psd-tools"
                    AppConfig.shared.environmentSummary = "[\(modeStr)] Python: \(detectedPython) · \(depStr)"
                    NotificationCenter.default.post(name: NSNotification.Name("AppConfigEnvironmentUpdated"), object: nil)
                }
            }
        }
    }

    public var isStandalonePortableReady: Bool {
        return isPortableEnvironment && hasPsdTools && FileManager.default.isExecutableFile(atPath: pythonPath)
    }

    // UI-G065 & UI-O018: 探测移后台 + 结果缓存，子进程数 ≤1，冷启动首屏 <1s
    private static var cachedPsdToolsResult: [String: Bool] = [:]
    private static let psdToolsLock = NSLock()

    // FCPX-015: 10s 超时 + 双管道并发异步排空，彻底杜绝主线程卡顿与大输出死锁
    public static func checkPsdTools(python: String) -> Bool {
        guard !python.isEmpty, FileManager.default.isExecutableFile(atPath: python) else {
            return false
        }

        psdToolsLock.lock()
        if let cached = cachedPsdToolsResult[python] {
            psdToolsLock.unlock()
            return cached
        }
        let userDefaultsKey = "FCPX_PSDToolsCheck_\(python)"
        if UserDefaults.standard.bool(forKey: userDefaultsKey) {
            cachedPsdToolsResult[python] = true
            psdToolsLock.unlock()
            return true
        }
        psdToolsLock.unlock()

        let outPipe = Pipe()
        let errPipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = ["-c", "import psd_tools; print('OK')"]
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        do {
            try proc.run()
        } catch {
            return false
        }

        let timeout = group.wait(timeout: .now() + 10.0)
        if timeout == .timedOut {
            proc.terminate()
            usleep(200_000)
            if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            return false
        }

        proc.waitUntilExit()
        if proc.terminationStatus == 0 {
            let out = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let isOk = (out == "OK")
            psdToolsLock.lock()
            cachedPsdToolsResult[python] = isOk
            if isOk { UserDefaults.standard.set(true, forKey: userDefaultsKey) }
            psdToolsLock.unlock()
            return isOk
        } else {
            if !errData.isEmpty, let errStr = String(data: errData, encoding: .utf8) {
                _ = errStr // 保留 stderr 排空防死锁
            }
        }
        return false
    }

    public func overridePythonPath(_ path: String) {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) && fm.isExecutableFile(atPath: path) {
            self.pythonPath = path
            self.hasPsdTools = AppConfig.checkPsdTools(python: path)
        }
    }

    public func recheckEnvironment() {
        if !pythonPath.isEmpty {
            self.hasPsdTools = AppConfig.checkPsdTools(python: pythonPath)
        }
    }

    public func evaluateEnvironment() -> (isReady: Bool, summary: String) {
        let pythonExecutable = !pythonPath.isEmpty && FileManager.default.isExecutableFile(atPath: pythonPath)
        let ready = pythonExecutable &&
                    FileManager.default.fileExists(atPath: bridgeScriptPath) &&
                    hasPsdTools
        return (ready, environmentSummary)
    }
}
