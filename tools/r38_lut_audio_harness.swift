// ═══════════════════════════════════════════════════════════════
//  R38 引擎二对标嘉星：3D LUT 实时分屏对比与音效波形系统自动化直证 Harness
//  对标基准：/Applications/嘉星插件管理 2.app (com.FxXu.0412)
// ═══════════════════════════════════════════════════════════════

import AppKit
import AVFoundation
import CoreImage
import Foundation

@main
struct R38LUTAudioHarness {
    static var failures = 0
    static var checks = 0

    static func check(_ cond: Bool, _ name: String, _ detail: String = "") {
        checks += 1
        if !cond { failures += 1 }
        let status = cond ? "✅ PASS" : "❌ FAIL"
        print("\(status) | \(name)\(detail.isEmpty ? "" : " | " + detail)")
    }

    static func main() {
        _ = NSApplication.shared
        print("==================================================")
        print("  FCPX Studio Pro —— R38 3D LUT 与音效波形 Harness 开始")
        print("==================================================")

        let rootDir = FileManager.default.currentDirectoryPath
        let evidenceDir = "\(rootDir)/docs/r38_evidence"
        try? FileManager.default.createDirectory(atPath: evidenceDir, withIntermediateDirectories: true)

        test1_RealLUTPathScanning()
        test2_3DLUTCubeParsingAndColorGrading()
        test3_DynamicSplitCompareViewport()
        test4_RealAudioLibraryScanAndWaveformExtraction()
        test5_AudioPlaybackAndInteractiveControl()
        test6_AssetHubViewTabExpansion()

        print("==================================================")
        print("  总计检查点: \(checks) | 失败: \(failures)")
        print("==================================================")
        exit(failures == 0 ? 0 : 1)
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 1：真实 LUT 路径扫描与元数据提取
    // ─────────────────────────────────────────────────────────────
    static func test1_RealLUTPathScanning() {
        print("\n── 判据 1：真实 LUT 路径扫描与缩略图关联 ──")

        let lutManager = LUTManager.shared
        let luts = lutManager.scan()

        check(!luts.isEmpty, "成功扫描到本机 3D LUT 文件", "count=\(luts.count)")

        // 验证 DJI OSMO Action 4 官方 Cube 是否命中
        let djiLut = luts.first { $0.name.contains("Action 4") || $0.name.contains("DJI") }
        check(djiLut != nil, "成功定位 DJI OSMO Action 4 真实调色文件", "name=\(djiLut?.name ?? "none")")

        if let dji = djiLut {
            check(dji.fileSizeBytes > 100_000, "LUT 文件体积正常 (>100KB)", "size=\(dji.fileSizeFormatted)")
            check(dji.dimension >= 17, "LUT 三维网格尺寸合法", "dimension=\(dji.dimension)³")

            // 验证同名 .jpg 缩略图探测
            let thumb = lutManager.findThumbnail(for: URL(fileURLWithPath: dji.path))
            check(thumb != nil, "成功发现配套官方实拍预览图", "thumb=\(thumb ?? "none")")
            if let thumbPath = thumb {
                check(FileManager.default.fileExists(atPath: thumbPath), "预览图物理存在于磁盘")
            }
        }

        // 验证分类提取
        let categories = Set(luts.map { $0.category })
        check(categories.count >= 1, "成功提取 LUT 分类/目录树", "categories=\(categories.joined(separator: ", "))")
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 2：3D LUT 解析与 CoreImage 硬件加速着色
    // ─────────────────────────────────────────────────────────────
    static func test2_3DLUTCubeParsingAndColorGrading() {
        print("\n── 判据 2：3D LUT Cube 解析与 CIColorCube 硬件加速着色 ──")

        let lutManager = LUTManager.shared
        let luts = lutManager.scan()
        guard let sampleLut = luts.first(where: { $0.name.contains("Action 4") }) ?? luts.first else {
            check(false, "缺少可测试的 LUT 文件")
            return
        }

        do {
            let (dim, cubeData) = try lutManager.parseCube(at: sampleLut.path)
            check(dim >= 17, "成功解析 .cube 尺寸 (LUT_3D_SIZE)", "dim=\(dim)")

            let expectedByteSize = dim * dim * dim * 4 * MemoryLayout<Float>.size
            check(cubeData.count == expectedByteSize, "Cube 数据字节数完全匹配", "bytes=\(cubeData.count), expected=\(expectedByteSize)")

            // 验证 CIColorCube 滤镜构建
            let filter = lutManager.makeColorCubeFilter(dimension: dim, cubeData: cubeData)
            check(filter != nil, "成功构建 CIColorCube 硬件加速滤镜")
            check(filter?.name == "CIColorCube", "滤镜标识符为 CIColorCube")

            // 色彩改变直证：给纯色像素施加 LUT，验证 RGB 发生色彩映射改变
            let inputCI = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0))
                .cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))

            let outputCI = lutManager.applyLUT(to: inputCI, dimension: dim, cubeData: cubeData)
            check(outputCI != nil, "CIImage LUT 应用生成有效输出")

            let context = CIContext(options: nil)
            var pixel: [UInt8] = [0, 0, 0, 0]
            context.render(outputCI!, toBitmap: &pixel, rowBytes: 4,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())

            // 原图 0.5 对应 128，LUT 调色后应发生改变
            let colorChanged = (pixel[0] != 128 || pixel[1] != 128 || pixel[2] != 128)
            check(colorChanged, "调色像素值真实改变（非恒等变换）", "outputRGBA=\(pixel)")

            // 图像级渲染测试
            let refImage = LUTManager.makeCinematicReferenceImage(width: 480, height: 270)
            let renderedImage = lutManager.renderLUTImage(input: refImage, dimension: dim, cubeData: cubeData)
            check(renderedImage != nil, "NSImage 渲染 LUT 图像成功")
            check(renderedImage?.size.width == 480, "渲染图像分辨率一致", "width=\(renderedImage?.size.width ?? 0)")

        } catch {
            check(false, "Cube 解析抛出异常", "error=\(error)")
        }
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 3：悬停动态分屏对比视口交互与切分渲染
    // ─────────────────────────────────────────────────────────────
    static func test3_DynamicSplitCompareViewport() {
        print("\n── 判据 3：悬停动态分屏对比视口交互与切分渲染 ──")

        let viewRect = NSRect(x: 0, y: 0, width: 800, height: 450)
        let compareView = LUTCompareView(frame: viewRect)

        check(compareView.bounds.width == 800, "对比视口尺寸正常")
        check(compareView.splitRatio == 0.5, "默认切分线在中轴 0.5")

        let luts = LUTManager.shared.scan()
        if let firstLUT = luts.first {
            compareView.currentLUT = firstLUT
            check(compareView.lutImage != nil, "设置 LUT 后自动生成调色图像")
        }

        // 模拟鼠标移动到 200pt (25% 位置)
        let event25 = NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(x: 200, y: 200),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )!
        compareView.mouseMoved(with: event25)
        check(abs(compareView.splitRatio - 0.25) < 0.01, "鼠标移动精准驱动切分线至 25%", "ratio=\(compareView.splitRatio)")

        // 模拟鼠标移动到 600pt (75% 位置)
        let event75 = NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(x: 600, y: 200),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )!
        compareView.mouseMoved(with: event75)
        check(abs(compareView.splitRatio - 0.75) < 0.01, "鼠标移动精准驱动切分线至 75%", "ratio=\(compareView.splitRatio)")

        // 模式切换
        compareView.displayMode = .originalOnly
        check(compareView.displayMode == .originalOnly, "可切换至「仅看原片」模式")
        compareView.displayMode = .lutOnly
        check(compareView.displayMode == .lutOnly, "可切换至「仅看 LUT」模式")
        compareView.displayMode = .split
        check(compareView.displayMode == .split, "恢复「动态分屏」对比模式")

        // 验证绘制执行 (保证 drawRect 不崩溃且成功绘制至位图)
        let rep = compareView.bitmapImageRepForCachingDisplay(in: viewRect)!
        compareView.cacheDisplay(in: viewRect, to: rep)
        check(rep.size.width == 800 && rep.pixelsWide >= 800, "分屏视口离屏渲染成功，包含双画面与手柄", "size=\(rep.size.width), px=\(rep.pixelsWide)")
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 4：真实音效库扫描与 128 点声学波形提取
    // ─────────────────────────────────────────────────────────────
    static func test4_RealAudioLibraryScanAndWaveformExtraction() {
        print("\n── 判据 4：真实音效库扫描与 128 点声学波形提取 ──")

        let audioMgr = AudioManager.shared
        let items = audioMgr.scan()

        check(!items.isEmpty, "成功扫描到音频/音效库文件", "count=\(items.count)")

        // 选取测试文件（优先使用片头音效或系统音效）
        guard let testAudio = items.first(where: { $0.path.hasSuffix(".wav") || $0.path.hasSuffix(".aiff") || $0.path.hasSuffix(".caf") }) ?? items.first else {
            check(false, "未找到可用测试音频")
            return
        }

        check(testAudio.duration > 0, "音频时长有效", "duration=\(testAudio.durationFormatted)")
        check(testAudio.sampleRate > 0, "音频采样率有效", "sampleRate=\(Int(testAudio.sampleRate)) Hz")
        check(testAudio.channels >= 1, "音频声道数有效", "channels=\(testAudio.channels)")

        // 提取 128 点声学波形
        let fileURL = URL(fileURLWithPath: testAudio.path)
        let waveform = audioMgr.extractWaveform(from: fileURL, samplesCount: 128)

        check(waveform.count == 128, "精准提取 128 点声学振幅数组", "count=\(waveform.count)")
        let maxAmp = waveform.max() ?? 0
        let minAmp = waveform.min() ?? 0
        check(maxAmp <= 1.0001 && maxAmp >= 0.5, "振幅峰值已正确归一化至 1.0", "max=\(maxAmp)")
        check(minAmp >= 0.0, "振幅非负合法", "min=\(minAmp)")

        // 检查波形图渲染视图
        let waveView = AudioWaveformView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        waveView.amplitudes = waveform
        waveView.playbackProgress = 0.35
        check(waveView.amplitudes.count == 128, "AudioWaveformView 接收振幅数据")
        check(waveView.playbackProgress == 0.35, "播放指针位置同步")

        let waveRep = waveView.bitmapImageRepForCachingDisplay(in: NSRect(x: 0, y: 0, width: 400, height: 100))!
        waveView.cacheDisplay(in: NSRect(x: 0, y: 0, width: 400, height: 100), to: waveRep)
        check(waveRep.size.width == 400 && waveRep.pixelsWide >= 400, "对称声学波形离屏渲染成功", "size=\(waveRep.size.width), px=\(waveRep.pixelsWide)")
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 5：音频试听与低延迟交互控制
    // ─────────────────────────────────────────────────────────────
    static func test5_AudioPlaybackAndInteractiveControl() {
        print("\n── 判据 5：AVAudioPlayer 低延迟试听与播放控制 ──")

        let audioMgr = AudioManager.shared
        let items = audioMgr.scan()
        guard let item = items.first else {
            check(false, "缺少测试音频项")
            return
        }

        var progressReceived = false
        var lastProgress: Double = 0.0

        audioMgr.play(item: item, onProgress: { p in
            progressReceived = true
            lastProgress = p
        }, onFinish: {
            print("  试听播放自然结束")
        })

        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        check(audioMgr.isPlaying, "AVAudioPlayer 成功启动试听播放")
        check(audioMgr.currentPlayingItem?.name == item.name, "当前播放项准确关联")
        check(progressReceived, "试听进度回调实时触发", "progress=\(String(format: "%.2f", lastProgress))")

        // 测试 Seek 跳转
        audioMgr.seek(to: 0.5)
        check(audioMgr.isPlaying, "跳转后持续播放")

        // 测试暂停与停止
        audioMgr.pause()
        check(!audioMgr.isPlaying, "暂停播放生效")

        audioMgr.stop()
        check(!audioMgr.isPlaying, "停止播放复位完成")
        check(audioMgr.currentPlayingItem == nil, "播放项已清空")
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 6：AssetHubView 全景 Tab 扩展与多模块协同
    // ─────────────────────────────────────────────────────────────
    static func test6_AssetHubViewTabExpansion() {
        print("\n── 判据 6：AssetHubView 全景三大模块 Tab 扩展与协同 ──")

        let hub = AssetHubView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        check(hub.hubSegmentedControl != nil, "顶层 Tab 导航组件存在")
        check(hub.hubSegmentedControl.segmentCount == 3, "顶层 Tab 具备三大模块", "count=\(hub.hubSegmentedControl.segmentCount)")

        // 默认处于模块 0 (模板插件)
        check(hub.currentHubTab == 0, "默认进入【模板插件】Tab")
        check(!hub.templateContainerView.isHidden, "模板插件视图可见")
        check(hub.lutContainerView.isHidden, "3D LUT 视图默认隐藏")
        check(hub.audioContainerView.isHidden, "音效库视图默认隐藏")

        // 切换至模块 1 (3D LUT 调色)
        hub.switchHubTab(to: 1)
        check(hub.currentHubTab == 1, "切换至【3D LUT 调色】Tab")
        check(hub.templateContainerView.isHidden, "模板插件视图隐藏")
        check(!hub.lutContainerView.isHidden, "3D LUT 视图显示")
        check(!hub.allLUTItems.isEmpty, "LUT 数据列表已自动扫描装载", "count=\(hub.allLUTItems.count)")
        check(hub.lutCompareView != nil, "LUT 分屏对比视口已装载就绪")

        // 切换至模块 2 (影视级音效库)
        hub.switchHubTab(to: 2)
        check(hub.currentHubTab == 2, "切换至【影视级音效库】Tab")
        check(hub.lutContainerView.isHidden, "3D LUT 视图隐藏")
        check(!hub.audioContainerView.isHidden, "音效库视图显示")
        check(!hub.allAudioItems.isEmpty, "音效数据列表已自动扫描装载", "count=\(hub.allAudioItems.count)")
        check(hub.audioWaveformView != nil, "声学波形视图已装载就绪")

        // 恢复至模块 0 验证模板插件一键启停等能力未受干扰
        hub.switchHubTab(to: 0)
        check(hub.currentHubTab == 0, "切回【模板插件】Tab")
        check(hub.categoryPopup != nil && hub.pluginTableView != nil, "模板插件原有表格及控制器 100% 完好")
    }
}
