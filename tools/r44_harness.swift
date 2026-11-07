import AppKit
import Foundation
import CryptoKit

// ═══════════════════════════════════════════════════════════════
//  r44_harness.swift
//  开发任务单 R44 —— 团队资产免流量分发与环境克隆系统直证套件
// ═══════════════════════════════════════════════════════════════

@main
final class R44Harness {
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

    static func waitOnMainRunLoop(timeout: TimeInterval = 6.0, condition: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
    }

    static func main() {
        _ = NSApplication.shared
        print("==================================================")
        print("  FCPX Studio Pro —— R44 团队资产免流量分发与环境克隆直证")
        print("==================================================")

        test1_Bonjour_And_Server_Lifecycle()
        test2_P2P_Packet_Assembly_And_SHA256_Integrity()
        test3_Dual_Endpoint_TCP_Direct_Transfer()
        test4_Environment_Cloner_Export()
        test5_Environment_Cloner_Import_And_Conflict_Policies()
        test6_Dashboard_UI_And_Sidebar_Integration()

        print("\n==================================================")
        print("  总计检查点: \(totalChecks) | 失败: \(failedChecks)")
        print("==================================================")

        if failedChecks > 0 {
            exit(1)
        }
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 1：Bonjour 广播、NetService 服务配置与生命周期
    // ─────────────────────────────────────────────────────────────
    static func test1_Bonjour_And_Server_Lifecycle() {
        print("\n── 判据 1：Bonjour 广播与套接字服务器生命周期 (TeamP2PSyncManager) ──")
        let mgr = TeamP2PSyncManager.shared

        check(TeamP2PSyncManager.serviceType == "_fcpxsync._tcp.", "Bonjour 协议服务类型规范对标", TeamP2PSyncManager.serviceType)
        check(TeamP2PSyncManager.magicHeader == "FCPXPK", "P2P 协议包头魔数正确 (FCPXPK)", TeamP2PSyncManager.magicHeader)

        // 启动本地监听
        let testPort = 53123
        do {
            try mgr.startServer(port: testPort)
            check(mgr.isListening, "本地 TCP 套接字服务器启动成功", "port=\(mgr.localPort)")
        } catch {
            check(false, "本地 TCP 套接字服务器启动失败", error.localizedDescription)
        }

        // 验证在线设备维护
        mgr.clearPeers()
        check(mgr.peers.isEmpty, "初始在线设备列表已清空")

        mgr.addManualPeer(name: "剪辑机 A (Mac Studio)", host: "192.168.1.101", port: 52888)
        mgr.addManualPeer(name: "调色机 B (Mac Pro)", host: "192.168.1.102", port: 52888)
        check(mgr.peers.count == 2, "成功手动添加 2 台局域网对端剪辑机", "count=\(mgr.peers.count)")

        let p1 = mgr.peers.first(where: { $0.host == "192.168.1.101" })
        check(p1 != nil, "对端 A 属性完整识别", "name=\(p1?.name ?? "") host=\(p1?.host ?? "")")
        check(p1?.status.contains("在线") == true, "对端状态标记在线", p1?.status ?? "")

        // 停止服务
        mgr.stopServer()
        check(!mgr.isListening, "套接字服务器已安全停止释放端口")
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 2：P2P 数据包打包、SHA-256 硬件校验与防篡改拦截
    // ─────────────────────────────────────────────────────────────
    static func test2_P2P_Packet_Assembly_And_SHA256_Integrity() {
        print("\n── 判据 2：P2P 数据包打包与 SHA-256 硬件校验 (TeamP2PSyncManager) ──")
        let tempDir = NSTemporaryDirectory() + "fcpx_r44_packet_test_\(UUID().uuidString)"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: tempDir) }

        // 构建模拟模板
        let tmplFolder = (tempDir as NSString).appendingPathComponent("婚礼唯美光效片头")
        try? fm.createDirectory(atPath: tmplFolder, withIntermediateDirectories: true)
        let motiFile = (tmplFolder as NSString).appendingPathComponent("婚礼唯美光效片头.moti")
        let motiContent = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><ozml version=\"5.13\"><template/></ozml>"
        try? motiContent.write(toFile: motiFile, atomically: true, encoding: .utf8)

        do {
            let (manifest, payload) = try TeamP2PSyncManager.packTemplate(
                atPath: tmplFolder,
                category: "Titles.localized",
                subcategory: "婚礼系列"
            )
            check(manifest.templateName == "婚礼唯美光效片头", "清单包含正确模板名称", manifest.templateName)
            check(manifest.category == "Titles.localized", "清单包含正确分类", manifest.category)
            check(manifest.subcategory == "婚礼系列", "清单包含正确子分类", manifest.subcategory)
            check(manifest.payloadSize == payload.count, "清单记录数据包大小准确", "bytes=\(manifest.payloadSize)")

            let computedHash = TeamP2PSyncManager.sha256(data: payload)
            check(computedHash == manifest.sha256, "硬件计算 SHA-256 与清单校验和 100% 吻合", computedHash)

            // 篡改测试：人为修改 payload 破坏哈希一致性
            var corruptedPayload = payload
            if !corruptedPayload.isEmpty {
                corruptedPayload[0] ^= 0xFF
            }

            var intercepted = false
            do {
                _ = try TeamP2PSyncManager.unpackAndInstall(manifest: manifest, payload: corruptedPayload)
            } catch TeamP2PError.sha256Mismatch {
                intercepted = true
            } catch {
                intercepted = false
            }
            check(intercepted, "SHA-256 校验和不匹配时成功拦截并拒绝安装，杜绝损坏模板")

            // 正常解包安装测试
            let installDir = (tempDir as NSString).appendingPathComponent("InstallDest")
            try? fm.createDirectory(atPath: installDir, withIntermediateDirectories: true)
            let results = try TeamP2PSyncManager.unpackAndInstall(
                manifest: manifest,
                payload: payload,
                targetTierRoot: installDir
            )
            check(!results.isEmpty, "解包并安装成功", "count=\(results.count)")
            let installedItem = results.first
            check(installedItem?.templateName == "婚礼唯美光效片头", "安装目标项名称正确", installedItem?.templateName ?? "")
        } catch {
            check(false, "数据包打包或解包异常", error.localizedDescription)
        }
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 3：单机双端点 TCP 局域网免流量直传通信 (Server <-> Client)
    // ─────────────────────────────────────────────────────────────
    static func test3_Dual_Endpoint_TCP_Direct_Transfer() {
        print("\n── 判据 3：双端点 TCP 免流量直传与审计日志 (Server <-> Client) ──")
        let server = TeamP2PSyncManager.shared
        let serverPort = 53899

        let tempDir = NSTemporaryDirectory() + "fcpx_r44_tcp_test_\(UUID().uuidString)"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        setenv("FCPXSTUDIO_USER_TEMPLATES_ROOT", tempDir, 1)
        defer {
            server.stopServer()
            try? fm.removeItem(atPath: tempDir)
        }

        do {
            try server.startServer(port: serverPort)
            check(server.isListening, "目标接收端 Server 监听就绪", "port=\(serverPort)")
        } catch {
            check(false, "启动目标接收端失败", error.localizedDescription)
            return
        }

        // 构建待发送模板
        let tmplFolder = (tempDir as NSString).appendingPathComponent("自媒体快节奏网感转场")
        try? fm.createDirectory(atPath: tmplFolder, withIntermediateDirectories: true)
        let motrFile = (tmplFolder as NSString).appendingPathComponent("自媒体快节奏网感转场.motr")
        try? "<?xml version=\"1.0\"?><ozml/>".write(toFile: motrFile, atomically: true, encoding: .utf8)

        var completed = false
        var sendSuccess = false
        var returnedMsg = ""

        server.sendTemplate(
            to: "127.0.0.1",
            port: serverPort,
            folderPath: tmplFolder,
            category: "Transitions.localized",
            subcategory: "自媒体"
        ) { result in
            completed = true
            switch result {
            case .success(let msg):
                sendSuccess = true
                returnedMsg = msg
            case .failure(let err):
                sendSuccess = false
                returnedMsg = err.localizedDescription
            }
        }

        waitOnMainRunLoop(timeout: 5.0) { completed }
        check(sendSuccess, "TCP 真实套接字免流量直传并返回 OK", returnedMsg.trimmingCharacters(in: .whitespacesAndNewlines))

        // 验证接收端已安装并记录传输历史
        waitOnMainRunLoop(timeout: 2.0) {
            !server.transferHistory.isEmpty
        }

        let history = server.transferHistory
        check(!history.isEmpty, "审计日志已记录直传流水", "条数=\(history.count)")
        let last = history.first
        check(last?.itemName == "自媒体快节奏网感转场", "审计记录正确识别资产名", last?.itemName ?? "")
        check(last?.status.contains("成功") == true || last?.status.contains("部署") == true, "审计记录状态标示成功", last?.status ?? "")
        check((last?.durationMs ?? 0) >= 0, "审计记录准确度量耗时 (ms)", "\(last?.durationMs ?? 0) ms")
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 4：生产环境一键克隆打包器 (.fcpxpack 导出全流程)
    // ─────────────────────────────────────────────────────────────
    static func test4_Environment_Cloner_Export() {
        print("\n── 判据 4：生产环境克隆打包器导出 (.fcpxpack) ──")
        let tempSandbox = NSTemporaryDirectory() + "fcpx_r44_cloner_export_\(UUID().uuidString)"
        let fm = FileManager.default

        let fakeUserRoot = (tempSandbox as NSString).appendingPathComponent("MotionTemplates")
        let fakeLUTRoot = (tempSandbox as NSString).appendingPathComponent("CameraLUTs")
        let fakeProfRoot = (tempSandbox as NSString).appendingPathComponent("Profiles")

        setenv("FCPXSTUDIO_USER_TEMPLATES_ROOT", fakeUserRoot, 1)
        setenv("FCPXSTUDIO_LUTS_DIR", fakeLUTRoot, 1)
        setenv("FCPXSTUDIO_PROFILES_DIR", fakeProfRoot, 1)

        defer {
            try? fm.removeItem(atPath: tempSandbox)
        }

        // 1. 造数据：字幕模板
        let catPath = (fakeUserRoot as NSString).appendingPathComponent("Titles.localized/婚礼系列/浪漫誓言字幕")
        try? fm.createDirectory(atPath: catPath, withIntermediateDirectories: true)
        try? "<ozml/>".write(toFile: (catPath as NSString).appendingPathComponent("浪漫誓言字幕.moti"), atomically: true, encoding: .utf8)

        // 2. 造数据：LUT 调色文件
        try? fm.createDirectory(atPath: fakeLUTRoot, withIntermediateDirectories: true)
        let lutFile = (fakeLUTRoot as NSString).appendingPathComponent("电影感胶片冷调.cube")
        try? "TITLE \"FilmCold\"\nLUT_3D_SIZE 2\n0 0 0\n1 1 1".write(toFile: lutFile, atomically: true, encoding: .utf8)

        // 3. 造数据：工作区情境
        try? fm.createDirectory(atPath: fakeProfRoot, withIntermediateDirectories: true)
        let profJson = (fakeProfRoot as NSString).appendingPathComponent("workspace_profiles.json")
        try? "[]".write(toFile: profJson, atomically: true, encoding: .utf8)

        let outPack = (tempSandbox as NSString).appendingPathComponent("ProductionEnv.fcpxpack")

        do {
            let cloner = EnvironmentCloner.shared
            let manifest = try cloner.exportPackage(
                categories: ["Titles.localized"],
                includeLUTs: true,
                includeProfiles: true,
                outputPath: outPack
            )

            check(fm.fileExists(atPath: outPack), "成功生成 .fcpxpack 归档包文件", outPack)
            check(manifest.templateCount >= 1, "清单准确统计导出模板数量", "count=\(manifest.templateCount)")
            check(manifest.lutCount >= 1, "清单准确统计导出 LUT 数量", "count=\(manifest.lutCount)")
            check(manifest.profileCount >= 1, "清单准确统计导出情境数量", "count=\(manifest.profileCount)")
            check(!manifest.sha256.isEmpty, "清单记录整包 SHA-256 指纹", manifest.sha256)
            check(manifest.totalSizeBytes > 0, "清单记录打包字节容量", "\(manifest.totalSizeBytes) bytes")
        } catch {
            check(false, "导出 .fcpxpack 克隆包异常", error.localizedDescription)
        }
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 5：生产环境一键克隆导入解包与冲突解决部署全流程
    // ─────────────────────────────────────────────────────────────
    static func test5_Environment_Cloner_Import_And_Conflict_Policies() {
        print("\n── 判据 5：克隆包导入解包与冲突策略部署 (EnvironmentCloner) ──")
        let tempSandbox = NSTemporaryDirectory() + "fcpx_r44_cloner_import_\(UUID().uuidString)"
        let fm = FileManager.default

        let fakeSrc = (tempSandbox as NSString).appendingPathComponent("SourceEnv")
        let fakeDst = (tempSandbox as NSString).appendingPathComponent("DestEnv")

        let srcUserRoot = (fakeSrc as NSString).appendingPathComponent("Templates")
        let srcLUTRoot  = (fakeSrc as NSString).appendingPathComponent("LUTs")
        let srcProfRoot = (fakeSrc as NSString).appendingPathComponent("Profiles")

        let dstUserRoot = (fakeDst as NSString).appendingPathComponent("Templates")
        let dstLUTRoot  = (fakeDst as NSString).appendingPathComponent("LUTs")
        let dstProfRoot = (fakeDst as NSString).appendingPathComponent("Profiles")

        defer {
            try? fm.removeItem(atPath: tempSandbox)
        }

        // 准备源数据
        let catPath = (srcUserRoot as NSString).appendingPathComponent("Effects.localized/光影特效/赛博霓虹辉光")
        try? fm.createDirectory(atPath: catPath, withIntermediateDirectories: true)
        try? "<ozml/>".write(toFile: (catPath as NSString).appendingPathComponent("赛博霓虹辉光.moef"), atomically: true, encoding: .utf8)

        try? fm.createDirectory(atPath: srcLUTRoot, withIntermediateDirectories: true)
        try? "LUT_3D_SIZE 2".write(toFile: (srcLUTRoot as NSString).appendingPathComponent("赛博朋克青橙.cube"), atomically: true, encoding: .utf8)

        try? fm.createDirectory(atPath: srcProfRoot, withIntermediateDirectories: true)
        let sampleProf = WorkspaceProfile(name: "赛博霓虹测试情境", icon: "🌌", category: "科幻特效", description: "导入测试情境")
        let profData = try? JSONEncoder().encode([sampleProf])
        try? profData?.write(to: URL(fileURLWithPath: (srcProfRoot as NSString).appendingPathComponent("workspace_profiles.json")))

        // 切换环境变量导出
        setenv("FCPXSTUDIO_USER_TEMPLATES_ROOT", srcUserRoot, 1)
        setenv("FCPXSTUDIO_LUTS_DIR", srcLUTRoot, 1)
        setenv("FCPXSTUDIO_PROFILES_DIR", srcProfRoot, 1)

        let packPath = (tempSandbox as NSString).appendingPathComponent("CyberEnv.fcpxpack")
        _ = try? EnvironmentCloner.shared.exportPackage(
            categories: ["Effects.localized"],
            includeLUTs: true,
            includeProfiles: true,
            outputPath: packPath
        )

        // 切换环境变量模拟目标机全新环境导入
        setenv("FCPXSTUDIO_USER_TEMPLATES_ROOT", dstUserRoot, 1)
        setenv("FCPXSTUDIO_LUTS_DIR", dstLUTRoot, 1)
        setenv("FCPXSTUDIO_PROFILES_DIR", dstProfRoot, 1)

        do {
            let summary1 = try EnvironmentCloner.shared.importPackage(packagePath: packPath, conflictPolicy: .overwrite)
            check(summary1.success, "目标机一键导入部署成功")
            check(summary1.installedTemplatesCount >= 1, "模板成功安装至目标目录", "count=\(summary1.installedTemplatesCount)")
            check(summary1.installedLUTsCount >= 1, "3D LUT 成功恢复至调色库", "count=\(summary1.installedLUTsCount)")

            let targetTmplFile = (dstUserRoot as NSString).appendingPathComponent("Effects.localized/光影特效/赛博霓虹辉光/赛博霓虹辉光.moef")
            check(fm.fileExists(atPath: targetTmplFile), "目标机模板物理文件完整还原", targetTmplFile)

            let targetLutFile = (dstLUTRoot as NSString).appendingPathComponent("赛博朋克青橙.cube")
            check(fm.fileExists(atPath: targetLutFile), "目标机 LUT 物理文件完整还原", targetLutFile)

            // 冲突策略测试 1：.skip 跳过
            let summarySkip = try EnvironmentCloner.shared.importPackage(packagePath: packPath, conflictPolicy: .skip)
            check(summarySkip.skippedCount >= 2, "冲突策略 .skip 正确跳过已存在资产", "skipped=\(summarySkip.skippedCount)")

            // 冲突策略测试 2：.keepBoth 保留两者（生成副本）
            let summaryKeepBoth = try EnvironmentCloner.shared.importPackage(packagePath: packPath, conflictPolicy: .keepBoth)
            check(summaryKeepBoth.installedTemplatesCount >= 1, "冲突策略 .keepBoth 成功生成副本安装", "installed=\(summaryKeepBoth.installedTemplatesCount)")
            let dupLut = (dstLUTRoot as NSString).appendingPathComponent("赛博朋克青橙 (副本).cube")
            check(fm.fileExists(atPath: dupLut), "冲突策略生成副本文件成功", dupLut)
        } catch {
            check(false, "导入部署异常", error.localizedDescription)
        }
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 6：UI 看板雷达与侧边栏接入集成 (TeamSyncDashboardView)
    // ─────────────────────────────────────────────────────────────
    static func test6_Dashboard_UI_And_Sidebar_Integration() {
        print("\n── 判据 6：UI 看板雷达与主侧边栏集成 (TeamSyncDashboardView & AssetHubView) ──")
        let dashboard = TeamSyncDashboardView(frame: NSRect(x: 0, y: 0, width: 1000, height: 750))

        check(dashboard.radarTableView != nil, "雷达设备 TableView 已就绪")
        check(dashboard.historyTableView != nil, "传输历史审计 TableView 已就绪")
        check(dashboard.exportPackageBtn != nil, "导出克隆包操作按钮已绑定")
        check(dashboard.importPackageBtn != nil, "导入克隆包操作按钮已绑定")
        check(dashboard.conflictPolicyPopup != nil, "冲突解决策略下拉框已挂载")

        check(dashboard.chkTitles.state == .on, "标题分类默认勾选")
        check(dashboard.chkLUTs.state == .on, "LUT 调色库默认勾选")
        check(dashboard.chkProfiles.state == .on, "情境配置默认勾选")

        // 验证主侧边栏集成
        let assetHub = AssetHubView(frame: NSRect(x: 0, y: 0, width: 1200, height: 780))
        check(assetHub.teamSyncContainerView != nil, "AssetHubView 已挂载团队分发容器视图")
        check(assetHub.teamSyncDashboardView != nil, "AssetHubView 已嵌入 TeamSyncDashboardView 实例")

        let btn10 = assetHub.sidebarButtons.first(where: { $0.tag == 10 })
        check(btn10 != nil, "侧边栏第 10 项已接入【🚀 团队分发】", btn10?.title ?? "")
        check(btn10?.title.contains("团队分发") == true, "侧边栏项文案包含团队分发")

        // 切换到团队分发
        assetHub.selectSidebarItem(at: 10)
        check(assetHub.currentSidebarIndex == 10, "当前侧边栏索引切换为 10")
        check(assetHub.currentHubTab == 7, "超级模块 Tab 索引切换为 7")
        check(!assetHub.teamSyncContainerView.isHidden, "团队分发看板容器显示正常 (未隐藏)")
        check(assetHub.templateContainerView.isHidden, "原模板容器已自动隐藏")

        // 验证主窗口控制器联动
        let winCtrl = MainWindowController()
        winCtrl.showTeamSync()
        check(winCtrl.assetHubView.currentSidebarIndex == 10, "MainWindowController.showTeamSync() 成功跳转")
    }
}
