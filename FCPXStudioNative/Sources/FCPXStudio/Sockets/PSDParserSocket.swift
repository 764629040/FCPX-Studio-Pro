import Foundation
import Darwin

// ═══════════════════════════════════════════════════════════════
//  PSDParserSocket —— PSD → JSON 桥接调用（R32 / A-65 重写）
//
//  R31 及之前的三处致命问题：
//    1. 先 waitUntilExit() 再 readDataToEndOfFile() → 子进程写满
//       管道缓冲区（macOS 默认 64 KB）后阻塞在 write()，父进程永远
//       等不到退出 → 双方互锁，解析大 PSD 必然挂死；
//    2. stderr 只建 Pipe 从不读取 → 第二条死锁通道；
//    3. 任何失败都返回 .empty（warnings = []），UI 因此显示绿色
//       「✓ 矢量文字层完整提取」→ 失败被伪装成成功。
//
//  本实现的契约（红线 4：失败必须显式失败）：
//    · stdout / stderr 两条管道**并发读取**，读净后才等待退出；
//    · 整体超时（默认 60s）→ 终止子进程 → 返回 isValid=false；
//    · 任何一步失败都带 failureReason，warnings 永不为空；
//    · 画幅字段缺失/为 0 视为解析失败，不再用 1920×1080 兜底掩盖。
// ═══════════════════════════════════════════════════════════════

/// R33 / A-69：层数守恒与忽略明细。诊断不允许再用「layers.count > 0」单点判成功。
public struct PSDLayerCounts: Equatable {
    public let input: Int
    public let preserved: Int
    public let degraded: Int
    public let ignored: Int
    public let failed: Int
    public let hidden: Int
    public let background: Int
    public let groups: Int
    public let empty: Int
    public let otherIgnored: Int
    public let preview: Int
    public let visibleEmitted: Int
    public let conservationHolds: Bool
    public let countSumHolds: Bool
    public let ignoredSummary: String
    /// 桥接是否返回了 summary（旧桥接不返回时，禁止宣称「完整提取」）
    public let summaryPresent: Bool

    public init(input: Int = 0, preserved: Int = 0, degraded: Int = 0, ignored: Int = 0,
                failed: Int = 0, hidden: Int = 0, background: Int = 0, groups: Int = 0,
                empty: Int = 0, otherIgnored: Int = 0, preview: Int = 0,
                visibleEmitted: Int = 0, conservationHolds: Bool = true,
                countSumHolds: Bool = true, ignoredSummary: String = "",
                summaryPresent: Bool = true) {
        self.input = input
        self.preserved = preserved
        self.degraded = degraded
        self.ignored = ignored
        self.failed = failed
        self.hidden = hidden
        self.background = background
        self.groups = groups
        self.empty = empty
        self.otherIgnored = otherIgnored
        self.preview = preview
        self.visibleEmitted = visibleEmitted
        self.conservationHolds = conservationHolds
        self.countSumHolds = countSumHolds
        self.ignoredSummary = ignoredSummary
        self.summaryPresent = summaryPresent
    }

    public static let empty = PSDLayerCounts()
}

public struct PSDParseResult {
    public let width: CGFloat
    public let height: CGFloat
    public let aspectRatio: String
    public let resolutionSpec: String
    public let layers: [LayerModel]
    public let warnings: [String]
    public let notes: [String]

    /// R32 / A-65：解析是否真的成功。UI 只允许在 isValid && 层数守恒 && 无忽略层
    /// 时显示绿色「完整提取」（R33 / A-69 收紧）。
    public let isValid: Bool
    /// 失败原因（isValid == false 时必有值），给用户看的人话。
    public let failureReason: String?
    /// R33 / A-69：层数统计（input / preserved / degraded / ignored / hidden ...）
    public let counts: PSDLayerCounts
    /// R33 / A-68：底板预览贴图（转换仍忽略底板，画布用它显示完整画面）
    public let backgroundPreview: LayerModel?
    /// R45：PSD 原始完整成图路径（供画布直观对比）
    public let originalCompositePath: String?

    public init(width: CGFloat, height: CGFloat, aspectRatio: String, resolutionSpec: String,
                layers: [LayerModel], warnings: [String], notes: [String],
                isValid: Bool = true, failureReason: String? = nil,
                counts: PSDLayerCounts = .empty,
                backgroundPreview: LayerModel? = nil,
                originalCompositePath: String? = nil) {
        self.width = width
        self.height = height
        self.aspectRatio = aspectRatio
        self.resolutionSpec = resolutionSpec
        self.layers = layers
        self.warnings = warnings
        self.notes = notes
        self.isValid = isValid
        self.failureReason = failureReason
        self.counts = counts
        self.backgroundPreview = backgroundPreview
        self.originalCompositePath = originalCompositePath
    }

    /// 构造一个「显式失败」结果：warnings 必含原因，绝不静默。
    public static func failure(_ reason: String, stderr: String = "") -> PSDParseResult {
        var warnings = [reason]
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !detail.isEmpty {
            warnings.append("stderr: " + String(detail.suffix(800)))
        }
        return PSDParseResult(
            width: 0, height: 0,
            aspectRatio: "—", resolutionSpec: "—",
            layers: [], warnings: warnings, notes: [],
            isValid: false, failureReason: reason
        )
    }

    /// 保留旧符号以免外部引用编译失败，但语义已改为「显式失败」。
    @available(*, deprecated, message: "失败不再伪装成空结果，请使用 PSDParseResult.failure(_:)")
    public static var empty: PSDParseResult { .failure("解析失败：未返回任何结果") }
}

public protocol PSDParserSocketProtocol {
    func parsePSD(at path: String) -> PSDParseResult
}

/// 跨线程收集管道数据（两条读取线程 + 主线程超时判定）
private final class PipeDataBox {
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

public final class PSDParserSocket: PSDParserSocketProtocol {
    public static let shared = PSDParserSocket()

    /// 默认 120s：2848×1600 的 13 层照片稿实测约 17s（关掉缩略图后），
    /// 留足余量；超时仍会显式失败，绝不允许无限挂起。
    public static let defaultTimeoutSeconds: TimeInterval = 120

    private let pythonPathOverride: String?
    private let bridgePathOverride: String?
    private let timeoutOverride: TimeInterval?

    /// - Parameters:
    ///   - pythonPath: 仅测试 harness 使用；nil 时走 AppConfig（产品默认行为）
    ///   - bridgePath: 同上
    ///   - timeoutSeconds: 同上，便于把 60s 超时分支在 harness 里压缩到几秒
    public init(pythonPath: String? = nil,
                bridgePath: String? = nil,
                timeoutSeconds: TimeInterval? = nil) {
        self.pythonPathOverride = pythonPath
        self.bridgePathOverride = bridgePath
        self.timeoutOverride = timeoutSeconds
    }

    private var effectiveTimeout: TimeInterval {
        guard let t = timeoutOverride, t > 0 else { return Self.defaultTimeoutSeconds }
        return t
    }

    public func parsePSD(at path: String) -> PSDParseResult {
        return parsePSD(at: path, includeHidden: false)
    }

    /// R33 / A-70：includeHidden=true 时桥接会额外返回隐藏层预览（visible=false），
    /// 只用于界面「显示隐藏图层」开关，不改变转换口径。
    public func parsePSD(at path: String, includeHidden: Bool) -> PSDParseResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            return .failure("文件不存在：\(path)")
        }

        let pythonPath = pythonPathOverride ?? AppConfig.shared.pythonPath
        let bridgePath = bridgePathOverride ?? AppConfig.shared.bridgeScriptPath
        guard fm.fileExists(atPath: bridgePath) else {
            return .failure("解析桥接脚本不存在：\(bridgePath)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        var args = [bridgePath, "parse", path]
        if includeHidden { args.append("--include-hidden") }
        process.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        // 解析器不需要输入；显式给 /dev/null，避免子进程等待继承来的 stdin
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return .failure("无法启动解析进程（\(pythonPath)）：\(error.localizedDescription)")
        }

        // ── 关键修复 1/2：stdout + stderr **并发**读取，读净后才 waitUntilExit。
        //    任何一条管道不被读，子进程写满 64 KB 缓冲后就会永久阻塞。
        let outBox = PipeDataBox()
        let errBox = PipeDataBox()
        let readers = DispatchGroup()

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

        // ── 关键修复 3：超时保护。超时后先 SIGTERM，宽限 3s 再 SIGKILL。
        let timeout = effectiveTimeout
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
        let errText = String(data: errBox.data, encoding: .utf8) ?? ""

        if timedOut {
            return .failure("解析超时（超过 \(Int(timeout)) 秒未返回）：\((path as NSString).lastPathComponent)",
                            stderr: errText)
        }
        if process.terminationReason == .uncaughtSignal {
            return .failure("解析进程被信号终止（signal \(process.terminationStatus)）", stderr: errText)
        }
        guard process.terminationStatus == 0 else {
            // 桥接脚本失败时会把 {"status":"error","message":"..."} 打到 stdout，
            // 尽量把真实原因带给用户，而不是只丢一个 exit code。
            var reason = "解析进程异常退出（exit code \(process.terminationStatus)）"
            if let obj = try? JSONSerialization.jsonObject(with: outData) as? [String: Any],
               let msg = obj["message"] as? String, !msg.isEmpty {
                reason += "：\(msg)"
            } else if let firstLine = errText.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                reason += "：\(firstLine)"
            }
            return .failure(reason, stderr: errText)
        }
        guard !outData.isEmpty else {
            return .failure("解析进程未返回任何输出（stdout 0 字节）", stderr: errText)
        }

        // ── 关键修复 4：不使用兜底默认值掩盖输出异常。
        let json: [String: Any]
        do {
            guard let obj = try JSONSerialization.jsonObject(with: outData) as? [String: Any] else {
                return .failure("解析输出不是 JSON 对象（\(outData.count) 字节）", stderr: errText)
            }
            json = obj
        } catch {
            return .failure("解析输出 JSON 解析失败（\(outData.count) 字节）：\(error.localizedDescription)",
                            stderr: errText)
        }

        guard let layersArray = json["layers"] as? [[String: Any]] else {
            return .failure("解析输出缺少 layers 字段（\(outData.count) 字节）", stderr: errText)
        }
        guard let widthNum = json["width"] as? NSNumber,
              let heightNum = json["height"] as? NSNumber,
              widthNum.doubleValue > 0, heightNum.doubleValue > 0 else {
            return .failure("解析输出画幅字段缺失或为 0（拒绝用 1920×1080 兜底掩盖）", stderr: errText)
        }

        let width = CGFloat(widthNum.doubleValue)
        let height = CGFloat(heightNum.doubleValue)

        var warnings: [String] = []
        var notes: [String] = []
        if let diag = json["diagnostics"] as? [String: Any] {
            warnings = diag["warnings"] as? [String] ?? []
            notes = diag["notes"] as? [String] ?? []
        }

        // UI-G050: 缺失时记 warning 并计入诊断，与拒绝 1920×1080 契约一致
        let aspectRatio: String
        if let ar = json["aspect_ratio"] as? String, !ar.isEmpty {
            aspectRatio = ar
        } else {
            aspectRatio = "\(Int(width)):\(Int(height))"
            warnings.append("桥接未返回 aspect_ratio，已按像素宽高比估算")
        }
        let resSpec: String
        if let rs = json["resolution_spec"] as? String, !rs.isEmpty {
            resSpec = rs
        } else {
            resSpec = "\(Int(height))P"
            warnings.append("桥接未返回 resolution_spec，已按高度推断")
        }

        let errTail = errText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !errTail.isEmpty {
            notes.append("stderr: " + String(errTail.suffix(800)))
        }

        var degradedLayersCount = 0
        var result: [LayerModel] = []
        for item in layersArray {
            let id = item["index"] as? Int ?? 1
            let name = item["name"] as? String ?? "Text"
            let kind = item["kind"] as? String ?? "type"
            let text = item["text"] as? String ?? ""
            let fontName = item["font_name"] as? String ?? "Helvetica"
            let fontSize = item["font_size"] as? Double ?? 36.0
            let tracking = item["tracking"] as? Double ?? 0.0
            let rawMotionPos = item["motion_pos"] as? [Double] ?? [0.0, 0.0]
            let motionPos = rawMotionPos.count >= 2 ? rawMotionPos : [0.0, 0.0]
            let visible = item["visible"] as? Bool ?? true
            let isPublished = item["is_published"] as? Bool ?? true
            let isLocked = (item["is_locked"] as? Bool) ?? (item["locked"] as? Bool) ?? false
            let rotation = item["rotation"] as? Double ?? 0.0
            let scaleX = item["scale_x"] as? Double ?? 1.0
            let scaleY = item["scale_y"] as? Double ?? 1.0
            let opacity = item["opacity"] as? Double ?? 1.0
            let direction = item["writing_direction"] as? String ?? "vertical"
            let fallbackPng = item["fallback_png_path"] as? String
            let psdBBox = item["psd_bbox"] as? [Double] ?? []
            var diagNotes = item["diagnostic_notes"] as? [String] ?? []
            let alignment = item["alignment"] as? String ?? "center"
            let lineSpacing = item["line_spacing"] as? Double ?? (fontSize * 1.2)

            // UI-G049: 关键字段缺失检测与告警
            var layerDegraded = false
            if item["name"] == nil {
                diagNotes.append("图层缺少 name 字段，降级为默认值")
                warnings.append("图层 #\(id) 缺少 name 字段")
                layerDegraded = true
            }
            if kind == "type" && item["font_name"] == nil {
                diagNotes.append("文本层缺少 font_name 字段，降级为 Helvetica")
                warnings.append("文本图层「\(name)」缺少 font_name 字段")
                layerDegraded = true
            }
            if item["motion_pos"] == nil {
                diagNotes.append("图层缺少 motion_pos 坐标，降级为 (0,0)")
                warnings.append("图层「\(name)」缺少 motion_pos 坐标")
                layerDegraded = true
            }
            if layerDegraded {
                degradedLayersCount += 1
            }

            // R28 / A-51 / R31 / A-59：缺字风险（口径由 core/missing_font.py 定义，此处只读）
            let fontInfo = item["font_info"] as? [String: Any] ?? [:]
            let fontStatus = fontInfo["detection_status"] as? String ?? ""
            let hasMissingGlyphs = fontInfo["has_missing_glyphs"] as? Bool ?? false
            let hasConfirmedMissingGlyphs = fontInfo["has_confirmed_missing_glyphs"] as? Bool ?? false
            let hasGlyphRisk = fontInfo["has_glyph_risk"] as? Bool ?? hasMissingGlyphs
            let missingChars = fontInfo["missing_chars"] as? [String] ?? []
            let markerFlag = item["missing_glyph_visible_marker"] as? Bool
                ?? (fontInfo["missing_glyph_visible_marker"] as? Bool ?? false)
            let flagged = item["highlight_missing_font"] as? Bool
                ?? (fontInfo["highlight_missing_font"] as? Bool ?? false)
            let markedText = item["marked_text"] as? String
                ?? (fontInfo["marked_text"] as? String ?? "")
            let highlightMissingFont = markerFlag || hasGlyphRisk || flagged

            let model = LayerModel(
                id: id, name: name, kind: kind, text: text, fontName: fontName,
                fontSize: fontSize, tracking: tracking,
                posX: motionPos[0], posY: motionPos[1], rotation: rotation,
                scaleX: scaleX, scaleY: scaleY, opacity: opacity,
                writingDirection: direction, visible: visible, isPublished: isPublished,
                fallbackPngPath: fallbackPng, psdBBox: psdBBox, diagnosticNotes: diagNotes,
                highlightMissingFont: highlightMissingFont, markedText: markedText,
                missingChars: missingChars, fontStatus: fontStatus,
                hasConfirmedMissingGlyphs: hasConfirmedMissingGlyphs, hasGlyphRisk: hasGlyphRisk,
                alignment: alignment, lineSpacing: lineSpacing,
                isLocked: isLocked
            )
            result.append(model)
        }

        // ── R33 / A-69：层数统计（缺失时 summaryPresent=false，禁止假绿）──
        var counts = PSDLayerCounts.empty
        if let summary = json["summary"] as? [String: Any] {
            func intVal(_ key: String, _ fallback: Int = 0) -> Int {
                if let n = summary[key] as? NSNumber { return n.intValue }
                if let n = summary[key] as? Int { return n }
                return fallback
            }
            let cons = summary["layer_conservation"] as? [String: Any] ?? [:]
            let conservationHolds = (cons["holds"] as? Bool) ?? true
            let countSumHolds = (summary["count_sum_holds"] as? Bool) ?? true
            counts = PSDLayerCounts(
                input: intVal("total_layers"),
                preserved: intVal("preserved_count"),
                degraded: intVal("degraded_count"),
                ignored: intVal("ignored_count"),
                failed: intVal("failed_count"),
                hidden: intVal("hidden_layer_count"),
                background: intVal("background_layer_count"),
                groups: intVal("group_layer_count"),
                empty: intVal("empty_layer_count"),
                otherIgnored: intVal("other_ignored_count"),
                preview: intVal("preview_layer_count"),
                visibleEmitted: intVal("visible_emitted_count"),
                conservationHolds: conservationHolds,
                countSumHolds: countSumHolds,
                ignoredSummary: summary["ignored_summary"] as? String ?? "",
                summaryPresent: true
            )
        } else {
            counts = PSDLayerCounts(summaryPresent: false)
            warnings.append("桥接未返回层数统计（summary），无法判定是否丢失图层")
        }

        // UI-G049: 累加客户端检测到的缺失字段降级层数
        if degradedLayersCount > 0 {
            counts = PSDLayerCounts(
                input: counts.input,
                preserved: max(0, counts.preserved - degradedLayersCount),
                degraded: counts.degraded + degradedLayersCount,
                ignored: counts.ignored,
                failed: counts.failed,
                hidden: counts.hidden,
                background: counts.background,
                groups: counts.groups,
                empty: counts.empty,
                otherIgnored: counts.otherIgnored,
                preview: counts.preview,
                visibleEmitted: counts.visibleEmitted,
                conservationHolds: counts.conservationHolds,
                countSumHolds: counts.countSumHolds,
                ignoredSummary: counts.ignoredSummary,
                summaryPresent: counts.summaryPresent
            )
        }

        // ── R33 / A-68：底板预览贴图（不进入图层列表，仅作画布底图）──
        var backgroundLayer: LayerModel?
        if let bg = json["background_preview"] as? [String: Any],
           let bgPath = bg["png_path"] as? String, !bgPath.isEmpty {
            let bgBBox = bg["psd_bbox"] as? [Double] ?? []
            backgroundLayer = LayerModel(
                id: 0,
                name: bg["name"] as? String ?? "底板预览",
                kind: "fallback_png",
                text: "",
                fontName: "",
                fontSize: 0,
                tracking: 0,
                posX: 0, posY: 0,
                opacity: bg["opacity"] as? Double ?? 1.0,
                visible: true, isPublished: false,
                fallbackPngPath: bgPath, psdBBox: bgBBox
            )
        }

        if result.isEmpty {
            warnings.append("解析成功，但未识别到任何图层（该 PSD 可能只有背景层或全部图层被隐藏）")
        }

        let originalCompositePath = json["original_composite_path"] as? String

        return PSDParseResult(
            width: width, height: height,
            aspectRatio: aspectRatio, resolutionSpec: resSpec,
            layers: result, warnings: warnings, notes: notes,
            isValid: true, failureReason: nil,
            counts: counts, backgroundPreview: backgroundLayer,
            originalCompositePath: originalCompositePath
        )
    }
}
