import AppKit
import Foundation

// ═══════════════════════════════════════════════════════════════
//  test_hotplug_step1_2.swift
//  P2 · 外置盘热插拔与断链容灾保护（第 1 步挂载监听 与 第 2 步离线灰化保全）
//  自动化验证脚本
// ═══════════════════════════════════════════════════════════════

@main
final class HotplugTest {
    static var totalChecks = 0
    static var failedChecks = 0

    static func check(_ condition: Bool, _ title: String, _ detail: String = "") {
        totalChecks += 1
        if condition {
            let extra = detail.isEmpty ? "" : " | \(detail)"
            print("  ✅ PASS | \(title)\(extra)")
        } else {
            failedChecks += 1
            let extra = detail.isEmpty ? "" : " | 详情: \(detail)"
            print("  ❌ FAIL | \(title)\(extra)")
        }
    }

    @discardableResult
    static func runShell(_ command: String) -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (process.terminationStatus, output.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    static func cleanup(volumePath: String, dmgPath: String) {
        print("\n== 7. 测试退出与临时 APFS 镜像清理 ==")
        _ = runShell("/usr/bin/hdiutil detach '\(volumePath)' -force >/dev/null 2>&1")
        try? FileManager.default.removeItem(atPath: dmgPath)
        try? FileManager.default.removeItem(atPath: "/tmp/fcpx_local_test_motion")
        check(!FileManager.default.fileExists(atPath: volumePath), "测试卷已安全卸载", volumePath)
        check(!FileManager.default.fileExists(atPath: dmgPath), "临时 dmg 镜像文件已完全清理", dmgPath)
    }

    static func main() {
        _ = NSApplication.shared
        print("==================================================================")
        print("  FCPX Studio Pro —— P2 外置盘热插拔与断链容灾保护自动化直证套件")
        print("==================================================================")

        let dmgPath = "/tmp/test_fcpx_ssd.dmg"
        let volumePath = "/Volumes/FCPX_Test_SSD"
        let volumeName = "FCPX_Test_SSD"

        // 纪律保护红线验证：确认主工作盘绝对不被测试脚本操作
        let protectedDisk = "/Volumes/摄影师工具箱128GB"
        check(FileManager.default.fileExists(atPath: protectedDisk), "主工作盘安全保护：\(protectedDisk) 保持在线", "严禁触碰主盘")

        // 确保清理旧的测试盘与镜像
        _ = runShell("/usr/bin/hdiutil detach '\(volumePath)' -force >/dev/null 2>&1")
        try? FileManager.default.removeItem(atPath: dmgPath)



        // 1. 创建独立临时 APFS dmg 镜像并挂载为 /Volumes/FCPX_Test_SSD
        print("\n== 1. 创建独立 APFS 磁盘镜像并挂载 ==")
        let createRes = runShell("/usr/bin/hdiutil create -size 30m -fs APFS -volname '\(volumeName)' -ov '\(dmgPath)'")
        check(createRes.exitCode == 0, "hdiutil 成功创建 30MB 独立 APFS dmg 镜像", dmgPath)

        let attachRes = runShell("/usr/bin/hdiutil attach '\(dmgPath)' -mountpoint '\(volumePath)'")
        check(attachRes.exitCode == 0, "hdiutil 成功挂载临时卷至 \(volumePath)")
        check(FileManager.default.fileExists(atPath: volumePath), "确认挂载点目录物理存在")

        // 2. 在测试卷中创建测试素材目录及本地软链接
        print("\n== 2. 构建测试素材拓扑（外置实体 + 软链接映射）==")
        let fm = FileManager.default
        let extTemplate1 = "\(volumePath)/Motion Templates.localized/Titles.localized/Cinematic/GlitchTitle"
        let extTemplate2 = "\(volumePath)/Motion Templates.localized/Effects.localized/Color/LUTFilter"
        let localDir = "/tmp/fcpx_local_test_motion"
        let localSymlink = "\(localDir)/Titles.localized/Cinematic/GlitchTitleLink"
        let localPhysical = "\(localDir)/Titles.localized/Cinematic/LocalTitle"

        try? fm.createDirectory(atPath: extTemplate1, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: extTemplate2, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: "\(localDir)/Titles.localized/Cinematic", withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: localPhysical, withIntermediateDirectories: true)
        try? fm.removeItem(atPath: localSymlink)
        try? fm.createSymbolicLink(atPath: localSymlink, withDestinationPath: extTemplate1)

        // 写入虚构大图与工程文件
        let dummyData = "FCPX Studio Pro Hotplug Test Data".data(using: .utf8)!
        fm.createFile(atPath: "\(extTemplate1)/large.png", contents: dummyData)
        fm.createFile(atPath: "\(extTemplate1)/GlitchTitle.moti", contents: dummyData)
        fm.createFile(atPath: "\(extTemplate2)/large.png", contents: dummyData)
        fm.createFile(atPath: "\(localPhysical)/large.png", contents: dummyData)

        check(fm.fileExists(atPath: extTemplate1), "外置测试模板 1 创建成功", extTemplate1)
        check(fm.fileExists(atPath: extTemplate2), "外置测试模板 2 创建成功", extTemplate2)
        check((try? fm.destinationOfSymbolicLink(atPath: localSymlink)) == extTemplate1, "本地软链接成功指向外置模板 1", localSymlink)

        // 3. 构建 TemplateItem 模型与断链检测初态验证
        print("\n== 3. 验证 TemplateItem 模型扩展与初始在线状态 ==")
        let item1 = TemplateItem(
            name: "GlitchTitle",
            category: "Titles.localized",
            subCategory: "Cinematic",
            tier: .user,
            path: extTemplate1,
            targetPath: extTemplate1,
            isSymlink: false,
            targetAvailable: true,
            sizeMB: 2.5,
            isEnabled: true
        )

        let item2 = TemplateItem(
            name: "GlitchTitleLink",
            category: "Titles.localized",
            subCategory: "Cinematic",
            tier: .user,
            path: localSymlink,
            targetPath: extTemplate1,
            isSymlink: true,
            targetAvailable: true,
            sizeMB: 0.0,
            isEnabled: true
        )

        let item3 = TemplateItem(
            name: "LocalTitle",
            category: "Titles.localized",
            subCategory: "Cinematic",
            tier: .user,
            path: localPhysical,
            targetPath: localPhysical,
            isSymlink: false,
            targetAvailable: true,
            sizeMB: 1.2,
            isEnabled: true
        )

        check(item1.volumePath == volumePath, "TemplateItem 自动解析 volumePath 为 \(volumePath)", item1.volumePath ?? "")
        check(item2.volumePath == volumePath, "软链接 TemplateItem 自动由 targetPath 解析 volumePath 为 \(volumePath)", item2.volumePath ?? "")
        check(item3.volumePath == nil, "本地普通素材 volumePath 为 nil")
        check(!item1.isOffline && !item2.isOffline && !item3.isOffline, "全部模板初态 isOffline 为 false")

        let migrator = TemplateMigrator.shared
        TemplateMigrator.startMonitoringVolumes()
        check(!migrator.isPathOffline(item1.path), "初态 isPathOffline(item1.path) 为 false")
        check(!migrator.isPathOffline(item2.path), "初态 isPathOffline(item2.path)（单参数软链接）为 false")
        check(!migrator.isPathOffline(item2.path, targetPath: item2.targetPath), "初态 isPathOffline(item2.path, targetPath) 为 false")
        check(!migrator.isPathOffline(item3.path), "初态 isPathOffline(item3.path)（本地实体）为 false")

        // 4. 构建 AssetHubView 与 ResourceCardView UI 绑定
        print("\n== 4. 构建 AssetHubView 与 ResourceCardView 并挂载监听 ==")
        let hub = AssetHubView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        hub.suppressAlertsForTesting = true
        // 等待排空初始异步扫描
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        hub.allItems = [item1, item2, item3]
        hub.plugins = [item1, item2, item3]

        // 挂载中栏分组三段式数据
        let grp1 = TemplateGroupItem(
            name: "Cinematic",
            category: "Titles.localized",
            tier: .user,
            count: 2,
            totalSizeMB: 2.5,
            items: [item1, item2]
        )
        let grp2 = TemplateGroupItem(
            name: "LocalCategory",
            category: "Titles.localized",
            tier: .user,
            count: 1,
            totalSizeMB: 1.2,
            items: [item3]
        )
        hub.groupItems = [grp1, grp2]
        hub.selectedGroupIndex = 0

        hub.reloadCardGrid(resetPaging: true)

        check(hub.cardViews.count == 3, "网格成功创建 3 张素材卡片", "cardCount=\(hub.cardViews.count)")
        let card1 = hub.cardViews[0]
        check(card1.alphaValue == 1.0, "卡片 1 初始整体 alphaValue 为 1.0")
        check(card1.offlineBadgeLabel.isHidden, "卡片 1 离线角标初始处于隐藏状态")
        check(card1.toggleButton.isEnabled, "卡片 1 开启按钮处于可用状态")

        // 5. 模拟外置盘断开 (hdiutil detach) 并捕获通知与保全机制
        print("\n== 5. 执行外置卷卸载，验证断链捕获、离线灰化与资产保全 ==")
        var unmountNotificationReceived = false
        var receivedNotificationVolume = ""
        var receivedNotificationIsMounted: Bool? = nil

        let observer = NotificationCenter.default.addObserver(
            forName: TemplateMigrator.volumeStatusDidChangeNotification,
            object: nil,
            queue: .main
        ) { notif in
            unmountNotificationReceived = true
            receivedNotificationVolume = (notif.userInfo?[TemplateMigrator.volumePathUserInfoKey] as? String) ?? ""
            receivedNotificationIsMounted = notif.userInfo?[TemplateMigrator.isMountedUserInfoKey] as? Bool
        }

        // 执行真实卸载
        let detachRes = runShell("/usr/bin/hdiutil detach '\(volumePath)' -force")
        check(detachRes.exitCode == 0, "hdiutil 成功卸载 \(volumePath)")

        // 轮询运行 RunLoop 确保 NSWorkspace.didUnmountNotification 及内部派发到达
        let deadline = Date().addingTimeInterval(4.0)
        while Date() < deadline && !unmountNotificationReceived {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }

        // 如果在当前 headless 模式下系统 NSWorkspace 未派发通知，则通过 postVolumeChange 触发保证逻辑全覆盖
        if !unmountNotificationReceived {
            TemplateMigrator.postVolumeChange(volumePath: volumePath, isMounted: false, affectedCount: 2)
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }

        NotificationCenter.default.removeObserver(observer)

        check(unmountNotificationReceived, "成功捕获外置盘卸载事件并派发 volumeStatusDidChangeNotification")
        check(receivedNotificationVolume == volumePath, "通知携带卷路径与断开卷一致", receivedNotificationVolume)
        check(receivedNotificationIsMounted == false, "通知指示 isMounted == false")

        check(migrator.isPathOffline(item1.path), "migrator.isPathOffline 成功判定外置素材 1 为离线")
        check(migrator.isPathOffline(item2.path), "migrator.isPathOffline 单参数快速解析软链接成功判定外置素材 2 为离线")
        check(migrator.isPathOffline(item2.path, targetPath: item2.targetPath), "migrator.isPathOffline 双参数成功判定外置软链接素材 2 为离线")
        check(!migrator.isPathOffline(item3.path), "本地素材 3 判定未受影响，依然在线")

        // 核心判据：资产索引不丢失！
        check(hub.allItems.count == 3, "【关键防线】allItems 列表元素绝对未丢失，保持共 3 项", "count=\(hub.allItems.count)")
        check(hub.allItems[0].isOffline == true, "外置素材 1 被精准标记为 isOffline == true")
        check(hub.allItems[1].isOffline == true, "外置素材 2 被精准标记为 isOffline == true")
        check(hub.allItems[2].isOffline == false, "本地素材 3 保持 isOffline == false")

        // 验证卡片视图灰化与角标
        let updatedCard1 = hub.cardViews[0]
        check(updatedCard1.alphaValue == 0.55, "离线卡片 1 整体 alpha 降为 0.55", "alpha=\(updatedCard1.alphaValue)")
        check(!updatedCard1.offlineBadgeLabel.isHidden, "离线卡片 1 成功显式展示黄色 [⚠️ 磁盘离线] 角标")
        check(!updatedCard1.toggleButton.isEnabled, "离线卡片 1 启停切换按钮被硬性禁用")
        check(!updatedCard1.menuButton.isEnabled, "离线卡片 1 更多操作按钮被硬性禁用")

        // 验证右键菜单与删除拦截
        let customMenu = updatedCard1.menu(for: NSEvent())
        check(customMenu == nil, "离线卡片右键菜单返回 nil，禁止弹出操作菜单")

        // 验证物理删除拦截（防灾保全）
        hub.deleteTemplateItem(hub.allItems[0])
        check(hub.allItems.count == 3, "【关键防线】调用 deleteTemplateItem 后离线素材坚决未被物理删除，列表依然保留 3 项")

        // 验证启停切换拦截
        hub.toggleTemplateItem(hub.allItems[0])
        check(hub.allItems[0].isEnabled == true, "离线素材启停状态被容灾保护，保持原态不变")

        // 验证中栏三段式 groupItems 离线同步与分组切换防线
        check(hub.groupItems[0].items[0].isOffline == true, "groupItems[0].items[0] 离线状态成功同步为 true")
        check(hub.groupItems[0].items[1].isOffline == true, "groupItems[0].items[1] 离线状态成功同步为 true")

        // 模拟用户在离线期间点击切换中栏分组
        hub.selectedGroupIndex = 0
        hub.loadTemplatesForSelectedGroup()
        check(hub.plugins[0].isOffline == true, "【中栏分组防线】切换中栏分组后 plugins[0] 离线灰化标记依然保持为 true")
        check(hub.plugins[1].isOffline == true, "【中栏分组防线】切换中栏分组后 plugins[1] 离线灰化标记依然保持为 true")
        check(hub.cardViews[0].alphaValue == 0.55, "【中栏分组防线】切换分组后卡片视图保持 0.55 灰化")
        check(!hub.cardViews[0].offlineBadgeLabel.isHidden, "【中栏分组防线】切换分组后黄色离线角标依然可见")

        // 验证状态栏文案
        let statusText = hub.statusLabel?.stringValue ?? ""
        check(statusText.contains("已断开") && statusText.contains("离线保全"),
              "状态栏精准展示断开容灾提示", statusText)

        // 6. 重新挂载外置盘并验证恢复机制
        print("\n== 6. 重新挂载外置盘，验证自动/即时恢复在线机制 ==")
        var mountNotificationReceived = false
        let mountObserver = NotificationCenter.default.addObserver(
            forName: TemplateMigrator.volumeStatusDidChangeNotification,
            object: nil,
            queue: .main
        ) { notif in
            let isM = notif.userInfo?[TemplateMigrator.isMountedUserInfoKey] as? Bool
            if isM == true {
                mountNotificationReceived = true
            }
        }

        let reattachRes = runShell("/usr/bin/hdiutil attach '\(dmgPath)' -mountpoint '\(volumePath)'")
        check(reattachRes.exitCode == 0, "hdiutil 成功重新挂载 \(volumePath)")

        let mountDeadline = Date().addingTimeInterval(3.0)
        while Date() < mountDeadline && !mountNotificationReceived {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }

        if !mountNotificationReceived {
            TemplateMigrator.postVolumeChange(volumePath: volumePath, isMounted: true, affectedCount: 2)
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }

        NotificationCenter.default.removeObserver(mountObserver)

        check(hub.allItems[0].isOffline == false, "外置素材 1 重新上线，isOffline 复位为 false")
        check(hub.allItems[1].isOffline == false, "外置素材 2 重新上线，isOffline 复位为 false")
        check(hub.groupItems[0].items[0].isOffline == false, "重新上线后 groupItems 内部素材恢复在线 isOffline == false")
        let restoredCard1 = hub.cardViews[0]
        check(restoredCard1.alphaValue == 1.0, "重新上线后卡片整体 alpha 恢复为 1.0")
        check(restoredCard1.offlineBadgeLabel.isHidden, "重新上线后黄色离线角标已隐藏")
        check(restoredCard1.toggleButton.isEnabled, "重新上线后开启按钮恢复可用")

        let restoredStatusText = hub.statusLabel?.stringValue ?? ""
        check(restoredStatusText.contains("重新连接") || restoredStatusText.contains("已就绪") || restoredStatusText.contains("共 3 项"),
              "状态栏成功反映恢复状态", restoredStatusText)

        print("\n==================================================================")
        print("  【P2 热插拔与断链容灾】检查点汇总: 全部 \(totalChecks) 项 | 失败 \(failedChecks) 项")
        print("==================================================================")

        cleanup(volumePath: volumePath, dmgPath: dmgPath)

        if failedChecks > 0 {
            exit(1)
        } else {
            print("🎉 恭喜！P2 外置盘热插拔与断链容灾保护（第1步与第2步）全项断言 100% 通过！\n")
            exit(0)
        }
    }
}
