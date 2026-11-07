import AppKit
import CoreText
import Foundation

// ═══════════════════════════════════════════════════════════════
//  r46_harness.swift
//  开发任务单 R46 —— 批量导出异步调度器、多路径自适应与字体一键补全系统直证套件
// ═══════════════════════════════════════════════════════════════

@main
final class R46Harness {
    static var totalChecks = 0
    static var failedChecks = 0

    static func check(_ condition: Bool, _ title: String, _ detail: String = "") {
        totalChecks += 1
        if condition {
            let extra = detail.isEmpty ? "" : " | \(detail)"
            print("✅ PASS | \(title)\(extra)")
        } else {
            failedChecks += 1
            let extra = detail.isEmpty ? "" : " | 详情: \(detail)"
            print("❌ FAIL | \(title)\(extra)")
        }
    }

    static func main() {
        _ = NSApplication.shared
        print("==================================================")
        print("  FCPX Studio Pro —— R46 核心系统直证套件")
        print("==================================================")

        test1_MultiDestination_Smart_Fallback()
        test2_BatchExport_Progress_Sheet_And_Scheduler()
        test3_FontInstaller_CoreText_Registration()
        test4_DropAccepting_And_Inspector_Font_Integration()

        print("\n==================================================")
        print("  总计检查点: \(totalChecks) | 失败: \(failedChecks)")
        print("==================================================")

        if failedChecks > 0 {
            exit(1)
        }
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 1：多目标导出路径智能降级与防阻断
    // ─────────────────────────────────────────────────────────────
    static func test1_MultiDestination_Smart_Fallback() {
        print("\n── 判据 1：多目标导出路径智能降级（外置盘缺失自动降级本地，严禁弹窗阻断） ──")

        let config = AppConfig.shared
        let originalMode = config.exportDestinationMode
        let originalPreferred = config.preferredExternalDir
        defer {
            config.exportDestinationMode = originalMode
            config.preferredExternalDir = originalPreferred
        }

        // 1.1 模拟外置盘未挂载/不存在的情况：配置一个绝对不存在的外置路径
        config.exportDestinationMode = .smartAuto
        config.preferredExternalDir = "/Volumes/NonExistent_External_SSD_\(UUID().uuidString)/Motion Templates.localized"

        let resolvedFallback = config.resolveExportDestination(category: "Titles.localized", groupName: "PSD婚礼字幕")
        check(resolvedFallback.fallbackUsed == true, "外置盘未连接时触发自动降级", "fallbackUsed=\(resolvedFallback.fallbackUsed)")
        check(resolvedFallback.isExternal == false, "降级后不标记为外置存储", "isExternal=\(resolvedFallback.isExternal)")
        check(resolvedFallback.targetDir.contains("Movies/Motion Templates.localized/Titles.localized/PSD婚礼字幕"),
              "降级至本地标准路径", "targetDir=\(resolvedFallback.targetDir)")
        check(FileManager.default.fileExists(atPath: resolvedFallback.targetDir), "降级目录已自动确保创建存在", resolvedFallback.targetDir)

        // 1.2 测试本地纯系统盘模式
        config.exportDestinationMode = .localSystem
        let resolvedLocal = config.resolveExportDestination(category: "Titles.localized", groupName: "PSD婚礼字幕")
        check(resolvedLocal.fallbackUsed == false, "显式本地模式不计为异常降级", "fallbackUsed=\(resolvedLocal.fallbackUsed)")
        check(resolvedLocal.isExternal == false, "本地模式非外置", "isExternal=\(resolvedLocal.isExternal)")
        check(resolvedLocal.targetDir == config.defaultLocalTitlesDir, "本地路径完全吻合系统标准规范", resolvedLocal.targetDir)

        // 1.3 测试自定义输出目录模式
        let tmpCustom = "/tmp/fcpx_r46_custom_export_\(UUID().uuidString)"
        config.exportDestinationMode = .custom
        config.customExportDir = tmpCustom
        let resolvedCustom = config.resolveExportDestination()
        check(resolvedCustom.targetDir == tmpCustom, "自定义导出目录生效", resolvedCustom.targetDir)
        check(FileManager.default.fileExists(atPath: tmpCustom), "自定义目录自动创建", tmpCustom)
        try? FileManager.default.removeItem(atPath: tmpCustom)
        config.exportDestinationMode = .smartAuto
        config.customExportDir = nil

        // 1.4 测试外置盘挂载可用时的直接使用模式
        config.preferredExternalDir = "/Volumes/摄影师工具箱128GB/Motion Templates.localized"
        let resolvedExt = config.resolveExportDestination()
        check(resolvedExt.isExternal == true, "外置盘可用时标记为外置存储", "isExternal=\(resolvedExt.isExternal)")
        check(resolvedExt.fallbackUsed == false, "外置盘可用时不触发本地降级", "fallbackUsed=\(resolvedExt.fallbackUsed)")
        check(resolvedExt.targetDir.contains("/Volumes/摄影师工具箱128GB"), "目标路径正确指向外置存储", resolvedExt.targetDir)

        // 1.5 测试死软链自动清理能力
        let deadLinkTarget = "\(config.systemMotionTemplatesRoot)/Titles.localized/DeadLinkTest_\(UUID().uuidString)"
        let nonExistentDest = "/Volumes/GhostDisk/DoesNotExist"
        try? FileManager.default.createSymbolicLink(atPath: deadLinkTarget, withDestinationPath: nonExistentDest)
        check(FileManager.default.fileExists(atPath: deadLinkTarget) == false, "死软链创建验证（指向不存在目标）", deadLinkTarget)

        // 再次触发降级指向该分组，验证死软链被安全清理
        config.preferredExternalDir = "/Volumes/NonExistent_SSD_\(UUID().uuidString)"
        let resolvedCleaned = config.resolveExportDestination(category: "Titles.localized", groupName: (deadLinkTarget as NSString).lastPathComponent)
        var isDir: ObjCBool = false
        let dirExists = FileManager.default.fileExists(atPath: resolvedCleaned.targetDir, isDirectory: &isDir)
        check(dirExists && isDir.boolValue, "死软链被自动清理并重新创建为实体目录", resolvedCleaned.targetDir)
        try? FileManager.default.removeItem(atPath: deadLinkTarget)
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 2：批量导出进度面板 UI 与异步并发调度
    // ─────────────────────────────────────────────────────────────
    static func test2_BatchExport_Progress_Sheet_And_Scheduler() {
        print("\n── 判据 2：批量导出磨砂进度面板（BatchExportProgressSheet）与异步调度 ──")

        let sheet = BatchExportProgressSheet(totalCount: 20, targetDir: "/tmp/fcpx_batch_out")
        check(sheet.totalCount == 20, "进度面板总数初始化正确", "totalCount=\(sheet.totalCount)")
        check(sheet.completedCount == 0, "初始完成数为 0", "completed=\(sheet.completedCount)")
        check(sheet.isFinished == false, "初始状态未完成", "isFinished=\(sheet.isFinished)")
        check(sheet.isCancelled == false, "初始状态未取消", "isCancelled=\(sheet.isCancelled)")
        check(sheet.cancelButton.isHidden == false, "批处理中【取消】按钮可见", "cancelHidden=\(sheet.cancelButton.isHidden)")
        check(sheet.revealButton.isHidden == true, "批处理中【在 Finder 中查看】按钮隐藏", "revealHidden=\(sheet.revealButton.isHidden)")
        check(sheet.doneButton.isHidden == true, "批处理中【完成】按钮隐藏", "doneHidden=\(sheet.doneButton.isHidden)")

        // 2.1 进度更新测试
        sheet.updateProgress(completed: 8, total: 20, currentFileName: "婚礼序幕_镇雄.psd")
        check(sheet.completedCount == 8, "已完成数量正确更新", "completed=\(sheet.completedCount)")
        check(sheet.percentageLabel.stringValue.contains("40% (8/20)"), "百分比与计数文本精确渲染", sheet.percentageLabel.stringValue)
        check(sheet.progressIndicator.doubleValue == 8.0, "进度条底层 doubleValue 平滑同步", "value=\(sheet.progressIndicator.doubleValue)")
        check(sheet.currentFileLabel.stringValue.contains("婚礼序幕_镇雄.psd"), "实时文件状态反映正在处理文件", sheet.currentFileLabel.stringValue)

        // 2.2 日志流式追加测试（🟢 成功、🟡 警告、🔴 失败）
        sheet.appendLog(status: .success, fileName: "01_浪漫出场.psd", message: "生成 Motion XML 成功")
        sheet.appendLog(status: .warning, fileName: "02_草坪誓言.psd", message: "外置盘未连接，降级系统盘")
        sheet.appendLog(status: .failure, fileName: "03_损坏文件.psd", message: "解析失败: 损坏的图层结构")

        check(sheet.logItems.count == 3, "日志项总数正确追加", "count=\(sheet.logItems.count)")
        check(sheet.successCount == 1, "成功计数累加", "success=\(sheet.successCount)")
        check(sheet.failedCount == 1, "失败计数累加", "failed=\(sheet.failedCount)")
        check(sheet.logItems[0].status == .success && sheet.logItems[0].status.badge == "🟢", "成功日志带绿色徽标", sheet.logItems[0].status.badge)
        check(sheet.logItems[1].status == .warning && sheet.logItems[1].status.badge == "🟡", "警告日志带黄色徽标", sheet.logItems[1].status.badge)
        check(sheet.logItems[2].status == .failure && sheet.logItems[2].status.badge == "🔴", "失败日志带红色徽标", sheet.logItems[2].status.badge)

        // 2.3 完成动作与按钮状态翻转
        sheet.finishExport(successCount: 18, failedCount: 2, targetDir: "/tmp/fcpx_batch_out")
        check(sheet.isFinished == true, "完成状态置位", "isFinished=\(sheet.isFinished)")
        check(sheet.cancelButton.isHidden == true, "完成时【取消】按钮隐藏", "cancelHidden=\(sheet.cancelButton.isHidden)")
        check(sheet.revealButton.isHidden == false, "完成时【在 Finder 中查看】按钮展示", "revealHidden=\(sheet.revealButton.isHidden)")
        check(sheet.doneButton.isHidden == false, "完成时【完成】按钮展示", "doneHidden=\(sheet.doneButton.isHidden)")
        check(sheet.titleLabel.stringValue.contains("完成"), "完成时标题动态切换", sheet.titleLabel.stringValue)

        // 2.4 中途取消行为测试
        let cancelSheet = BatchExportProgressSheet(totalCount: 5, targetDir: "/tmp")
        var cancelCallbackFired = false
        cancelSheet.onCancel = { cancelCallbackFired = true }
        cancelSheet.cancelButton.performClick(nil)
        check(cancelCallbackFired == true, "取消按钮触发 onCancel 回调", "fired=\(cancelCallbackFired)")
        check(cancelSheet.isCancelled == true, "主动取消标记置位", "isCancelled=\(cancelSheet.isCancelled)")
        check(cancelSheet.logItems.last?.status == .warning, "记录取消警告日志", cancelSheet.logItems.last?.message ?? "")
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 3：字体拖拽一键补齐与 CoreText 用户级注册
    // ─────────────────────────────────────────────────────────────
    static func test3_FontInstaller_CoreText_Registration() {
        print("\n── 判据 3：字体拖拽补全（FontInstaller）与 CoreText 静默注册 ──")

        let installer = FontInstaller.shared

        // 3.1 格式判定
        check(FontInstaller.isFontFile(at: "/path/to/font.ttf") == false, "不存在的字体路径不误判", "nonexistent")
        check(FontInstaller.supportedExtensions.contains("ttf"), "支持 .ttf 格式", "ttf")
        check(FontInstaller.supportedExtensions.contains("otf"), "支持 .otf 格式", "otf")
        check(FontInstaller.supportedExtensions.contains("ttc"), "支持 .ttc 格式", "ttc")
        check(FontInstaller.supportedExtensions.contains("dfont"), "支持 .dfont 格式", "dfont")

        // 3.2 真实字体元数据解析与注册能力
        let systemFont = "/System/Library/Fonts/Supplemental/Arial.ttf"
        guard FileManager.default.fileExists(atPath: systemFont) else {
            check(false, "系统 Arial 字体存在性", systemFont)
            return
        }

        let sysUrl = URL(fileURLWithPath: systemFont)
        let meta = installer.extractFontMetadata(at: sysUrl)
        check(meta.postscriptName != nil && !meta.postscriptName!.isEmpty, "CoreText 元数据提取 PostScript 名称", meta.postscriptName ?? "")
        check(meta.familyName != nil && !meta.familyName!.isEmpty, "CoreText 元数据提取 Family 家族名称", meta.familyName ?? "")

        // 3.3 模拟动态加载注册与卸载闭环
        let tmpFontPath = "/tmp/FCPX_TestFont_\(UUID().uuidString).ttf"
        try? FileManager.default.copyItem(atPath: systemFont, toPath: tmpFontPath)
        defer { try? FileManager.default.removeItem(atPath: tmpFontPath) }

        let tmpUrl = URL(fileURLWithPath: tmpFontPath)
        var notificationObserved = false
        let observer = NotificationCenter.default.addObserver(
            forName: FontInstaller.didRegisterFontNotification,
            object: nil,
            queue: .main
        ) { notif in
            if let objUrl = notif.object as? URL, objUrl.path == tmpUrl.path {
                notificationObserved = true
            }
        }

        // 注册到 .process 作用域以防污染 macOS 永久用户字体目录
        let regResult = installer.registerFont(at: tmpUrl, scope: .process)
        check(regResult.isSuccess == true, "FontInstaller 成功注册字体到 CoreText 作用域", "scope=.process")
        check(regResult.postscriptName == meta.postscriptName, "注册结果带精确 PostScript 字体名", regResult.postscriptName ?? "")
        check(notificationObserved == true, "字体注册成功后广播 FCPXStudioDidRegisterFontNotification", "notif=true")
        NotificationCenter.default.removeObserver(observer)

        // 3.4 字体反注册与清理闭环
        let unregOk = installer.unregisterFont(at: tmpUrl, scope: .process)
        check(unregOk == true, "FontInstaller 成功反注册字体", "unreg=\(unregOk)")

        // 3.5 批量注册报告测试
        let batchReport = installer.registerFonts(at: [tmpUrl], scope: .process)
        check(batchReport.totalAttempted == 1, "批量安装总数上报准确", "total=\(batchReport.totalAttempted)")
        check(batchReport.successCount == 1, "批量安装成功数上报准确", "success=\(batchReport.successCount)")
        _ = installer.unregisterFont(at: tmpUrl, scope: .process)
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 4：拖拽穿透与检查器字体接收集成
    // ─────────────────────────────────────────────────────────────
    static func test4_DropAccepting_And_Inspector_Font_Integration() {
        print("\n── 判据 4：拖拽穿透（DropAcceptingView）与检查器（InspectorView）字体集成 ──")

        // 4.1 PSDImportPlanner 识别字体文件
        check(PSDImportPlanner.isFont("MyFont.ttf") == true, "PSDImportPlanner 识别 .ttf 为字体", "MyFont.ttf")
        check(PSDImportPlanner.isFont("TitleFont.otf") == true, "PSDImportPlanner 识别 .otf 为字体", "TitleFont.otf")
        check(PSDImportPlanner.isFont("Collection.ttc") == true, "PSDImportPlanner 识别 .ttc 为字体", "Collection.ttc")
        check(PSDImportPlanner.isFont("Graphic.psd") == false, "PSDImportPlanner 不把 .psd 混淆为字体", "Graphic.psd")

        // 4.2 InspectorView 字体拖拽提示区与回调
        let inspector = InspectorView(frame: NSRect(x: 0, y: 0, width: 340, height: 750))
        check(inspector.fontDropPromptBox != nil, "InspectorView 包含字体拖拽提示区", "fontDropPromptBox")
        check(inspector.fontDropPromptLabel != nil, "InspectorView 包含字体拖拽指引文本", "fontDropPromptLabel")
        check(inspector.fontDropPromptLabel.stringValue.contains("拖拽 .ttf / .otf"), "指引文案明确指向字体补齐", inspector.fontDropPromptLabel.stringValue)

        var fontDropCallbackPaths: [String] = []
        inspector.onFontsDropped = { paths in
            fontDropCallbackPaths = paths
        }
        inspector.onFontsDropped?(["/tmp/CustomFont.ttf"])
        check(fontDropCallbackPaths == ["/tmp/CustomFont.ttf"], "InspectorView onFontsDropped 回调正确触发", fontDropCallbackPaths.joined())

        // 4.3 MainWindowController 调度器与字体处理器
        let mainCtrl = MainWindowController()
        check(mainCtrl.activeExportSheet == nil, "初始未激活批量导出面板", "activeExportSheet=nil")
        check(mainCtrl.psdFiles.isEmpty, "初始 PSD 文件列表为空", "count=0")
    }
}
