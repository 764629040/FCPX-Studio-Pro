import AppKit
import Foundation

// ═══════════════════════════════════════════════════════════════
//  test_hotplug_step3.swift
//  P2 · 外置盘热插拔与断链容灾保护（第 3 步 卷重连自愈与一致性校验）
//  自动化验证脚本
// ═══════════════════════════════════════════════════════════════

@main
final class HotplugStep3Test {
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

    static func cleanupAll(disks: [String], dmgs: [String]) {
        print("\n== 清理临时 APFS 镜像与挂载点 ==")
        for d in disks {
            _ = runShell("/usr/bin/hdiutil detach '\(d)' -force >/dev/null 2>&1")
        }
        for dmg in dmgs {
            try? FileManager.default.removeItem(atPath: dmg)
        }
        try? FileManager.default.removeItem(atPath: "/tmp/fcpx_local_step3_motion")
    }

    static func main() {
        _ = NSApplication.shared
        print("==================================================================")
        print("  FCPX Studio Pro —— P2 第 3 步 卷重连自愈与一致性校验自动化套件")
        print("==================================================================")

        let origDmg = "/tmp/test_fcpx_step3_orig.dmg"
        let fakeDmg = "/tmp/test_fcpx_step3_fake.dmg"
        let origVol = "/Volumes/FCPX_Step3_SSD"
        let driftVol = "/Volumes/FCPX_Step3_Drift"

        // 纪律保护红线验证：确认主工作盘绝对不被测试脚本操作
        let protectedDisk = "/Volumes/摄影师工具箱128GB"
        check(FileManager.default.fileExists(atPath: protectedDisk), "主工作盘安全保护：\(protectedDisk) 保持在线", "严禁触碰主盘")

        // 确保清理残留
        cleanupAll(disks: [origVol, driftVol], dmgs: [origDmg, fakeDmg])

        // 1. 创建原装独立 APFS dmg 镜像并挂载为 /Volumes/FCPX_Step3_SSD
        print("\n== 1. 创建原装独立 APFS 磁盘镜像并挂载 ==")
        let res1 = runShell("/usr/bin/hdiutil create -size 30m -fs APFS -volname 'FCPX_Step3_SSD' -ov '\(origDmg)'")
        check(res1.exitCode == 0, "成功创建原装 APFS dmg 镜像", origDmg)

        let mountRes1 = runShell("/usr/bin/hdiutil attach '\(origDmg)' -mountpoint '\(origVol)' -nobrowse")
        check(mountRes1.exitCode == 0, "成功挂载原装卷至 \(origVol)")
        check(FileManager.default.fileExists(atPath: origVol), "挂载点物理存在")

        // 获取原装卷硬件 UUID
        let origUUID = TemplateItem.getVolumeUUID(for: origVol)
        check(origUUID != nil && !origUUID!.isEmpty, "成功读取原装卷唯一硬件 UUID", origUUID ?? "")

        // 2. 在原装卷构建素材结构
        print("\n== 2. 构建测试素材结构与本地软链接 ==")
        let tpl1Path = "\(origVol)/Motion Templates.localized/Titles.localized/Cinematic/GlitchTitle"
        let tplCorruptPath = "\(origVol)/Motion Templates.localized/Titles.localized/Cinematic/CorruptedTitle"
        try? FileManager.default.createDirectory(atPath: tpl1Path, withIntermediateDirectories: true)
        try? "test".write(toFile: "\(tpl1Path)/GlitchTitle.moti", atomically: true, encoding: .utf8)

        try? FileManager.default.createDirectory(atPath: tplCorruptPath, withIntermediateDirectories: true)
        try? "test".write(toFile: "\(tplCorruptPath)/CorruptedTitle.moti", atomically: true, encoding: .utf8)

        let localRoot = "/tmp/fcpx_local_step3_motion/Titles.localized/Cinematic"
        try? FileManager.default.createDirectory(atPath: localRoot, withIntermediateDirectories: true)
        let localSymlink = "\(localRoot)/GlitchTitleLink"
        _ = runShell("/bin/ln -s '\(tpl1Path)' '\(localSymlink)'")

        check(FileManager.default.fileExists(atPath: tpl1Path), "原装模板 1 创建成功", tpl1Path)
        check(FileManager.default.fileExists(atPath: tplCorruptPath), "即将被损坏模板创建成功", tplCorruptPath)
        check(FileManager.default.fileExists(atPath: localSymlink), "本地软链接创建成功", localSymlink)

        // 3. 构建 TemplateItem 模型与 AssetHubView
        print("\n== 3. 初始模型与 UI 装配 ==")
        var item1 = TemplateItem(
            name: "GlitchTitle",
            category: "Titles.localized",
            subCategory: "Cinematic",
            tier: .user,
            path: tpl1Path,
            targetPath: tpl1Path,
            isSymlink: false,
            targetAvailable: true,
            sizeMB: 1.5,
            volumePath: origVol,
            volumeUUID: origUUID
        )

        var itemCorrupted = TemplateItem(
            name: "CorruptedTitle",
            category: "Titles.localized",
            subCategory: "Cinematic",
            tier: .user,
            path: tplCorruptPath,
            targetPath: tplCorruptPath,
            isSymlink: false,
            targetAvailable: true,
            sizeMB: 2.0,
            volumePath: origVol,
            volumeUUID: origUUID
        )

        var itemLink = TemplateItem(
            name: "GlitchTitleLink",
            category: "Titles.localized",
            subCategory: "Cinematic",
            tier: .user,
            path: localSymlink,
            targetPath: tpl1Path,
            isSymlink: true,
            targetAvailable: true,
            sizeMB: 0.1,
            volumePath: origVol,
            volumeUUID: origUUID
        )

        check(item1.volumeUUID == origUUID, "item1 正确绑定原装卷 UUID")
        check(itemCorrupted.volumeUUID == origUUID, "itemCorrupted 正确绑定原装卷 UUID")
        check(itemLink.volumeUUID == origUUID, "itemLink 正确绑定原装卷 UUID")

        // 验证 S-3 & M-6 & M-7: 统一字典索引与剔除危险兜底键
        let testIndex = TemplateItem.buildItemIndex(from: [item1, itemCorrupted, itemLink])
        check(testIndex["\(item1.path)|\(item1.targetPath)"] != nil, "buildItemIndex 包含复合 key")
        check(testIndex[item1.path] != nil, "buildItemIndex 包含 path key")
        check(testIndex["Titles.localized|GlitchTitle"] == nil, "buildItemIndex 彻底剔除危险的 category|name 冲突兜底 key (S-3)")

        let hub = AssetHubView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        hub.suppressAlertsForTesting = true
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.2))

        let groupItem = TemplateGroupItem(
            name: "Cinematic",
            category: "Titles.localized",
            tier: .user,
            count: 3,
            totalSizeMB: 3.6,
            items: [item1, itemCorrupted, itemLink]
        )

        hub.allItems = [item1, itemCorrupted, itemLink]
        hub.groupItems = [groupItem]
        hub.plugins = [item1, itemCorrupted, itemLink]
        hub.reloadCardGrid(resetPaging: true)

        check(hub.cardViews.count == 3, "网格创建 3 张卡片", "cardCount=\(hub.cardViews.count)")
        check(hub.cardViews[0].alertBadgeLabel.isHidden, "初始态卡片 1 alertBadge 处于隐藏状态")

        // 4. 模拟卸载原装卷
        print("\n== 4. 模拟卸载原装卷，进入离线保护 ==")
        _ = runShell("/usr/bin/hdiutil detach '\(origVol)' -force >/dev/null 2>&1")
        TemplateMigrator.postVolumeChange(volumePath: origVol, isMounted: false, affectedCount: 3)
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))

        check(hub.allItems[0].isOffline, "卸载后 item1.isOffline == true")
        check(hub.allItems[1].isOffline, "卸载后 itemCorrupted.isOffline == true")
        check(hub.allItems[2].isOffline, "卸载后 itemLink.isOffline == true")
        check(hub.cardViews[0].alphaValue == 0.55, "卸载后卡片 1 alpha 降至 0.55")

        // 5. 场景 a: 同盘同路径重插恢复在线自愈
        print("\n== 5. 场景 a: 原盘同路径重新挂载自愈验证 ==")
        let remountRes = runShell("/usr/bin/hdiutil attach '\(origDmg)' -mountpoint '\(origVol)' -nobrowse")
        check(remountRes.exitCode == 0, "原盘重新挂载回 \(origVol)")
        TemplateMigrator.postVolumeChange(volumePath: origVol, isMounted: true, affectedCount: 3)
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))

        check(!hub.allItems[0].isOffline, "自愈：item1 成功恢复在线 isOffline == false")
        check(!hub.allItems[0].isCorrupted, "自愈：item1 isCorrupted == false")
        check(!hub.allItems[0].isMismatchedDisk, "自愈：item1 isMismatchedDisk == false")
        check(hub.cardViews[0].alphaValue == 1.0, "自愈：卡片 1 alpha 恢复为 1.0")
        check(hub.cardViews[0].toggleButton.isEnabled, "自愈：卡片 1 开启按钮恢复可用")

        // 6. 场景 d: 文件损坏/丢失标红告警
        print("\n== 6. 场景 d: 模板主文件缺失/损坏标红验证 ==")
        // 删除 CorruptedTitle 模板目录
        try? FileManager.default.removeItem(atPath: tplCorruptPath)
        check(!FileManager.default.fileExists(atPath: tplCorruptPath), "人为模拟物理文件被移除")

        // 触发自愈校验
        hub.handleVolumeStatusChange(volumePath: origVol, volumeName: "FCPX_Step3_SSD", isMounted: true)
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.25))

        let corruptedItem = hub.allItems.first(where: { $0.name == "CorruptedTitle" })!
        check(corruptedItem.isCorrupted == true, "文件缺失时标记 isCorrupted == true")
        check(corruptedItem.isOffline == false, "文件缺失时不标为纯离线，而是故障态")
        check(hub.allItems.count == 3, "【红线保全】损坏素材绝对未被从列表中删除！列表依然包含 3 项")

        // 检查卡片展示
        let corruptedCard = hub.cardViews.first(where: { $0.item.name == "CorruptedTitle" })!
        check(corruptedCard.alphaValue == 0.55, "损坏卡片 alpha 保持 0.55 灰化")
        check(!corruptedCard.alertBadgeLabel.isHidden, "损坏卡片显示红色状态角标")
        check(corruptedCard.alertBadgeLabel.stringValue == "损坏/丢失", "角标文本正确显示 [损坏/丢失]")
        check(corruptedCard.toggleButton.isEnabled, "损坏卡片切换按钮保持交互（点击弹保护告警）")
        check(corruptedCard.menuButton.isEnabled, "损坏卡片菜单按钮可用")
        let corruptedMenu = corruptedCard.menu(for: NSEvent())
        check(corruptedMenu != nil, "损坏卡片支持弹出容灾保护菜单")
        check(corruptedMenu?.items.contains(where: { $0.title.contains("素材损坏/丢失") }) == true, "菜单包含损坏提示项")
        check(corruptedMenu?.items.contains(where: { $0.title.contains("重新校验") }) == true, "菜单包含重新校验选项")

        // 7. 场景 b: 卷名漂移/改名重插自愈
        print("\n== 7. 场景 b: 卷名漂移/挂载点变更自愈验证 ==")
        // 卸载原卷，改挂载到 /Volumes/FCPX_Step3_Drift
        _ = runShell("/usr/bin/hdiutil detach '\(origVol)' -force >/dev/null 2>&1")
        TemplateMigrator.postVolumeChange(volumePath: origVol, isMounted: false, affectedCount: 3)
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))

        check(hub.allItems[0].isOffline, "卸载后进入离线态")

        let driftMountRes = runShell("/usr/bin/hdiutil attach '\(origDmg)' -mountpoint '\(driftVol)' -nobrowse")
        check(driftMountRes.exitCode == 0, "成功以新挂载点 \(driftVol) 挂载原盘")

        // 验证硬件 UUID 依然完全一致
        let driftedUUID = TemplateItem.getVolumeUUID(for: driftVol)
        check(driftedUUID == origUUID, "硬件 UUID 保持完全一致（原盘迁移）", driftedUUID ?? "")

        // 触发卷上线自愈
        TemplateMigrator.postVolumeChange(volumePath: driftVol, isMounted: true, affectedCount: 3)
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))

        let driftedItem1 = hub.allItems.first(where: { $0.name == "GlitchTitle" })!
        check(!driftedItem1.isOffline, "卷漂移自愈：item1 成功恢复在线")
        check(driftedItem1.volumePath == driftVol, "卷漂移自愈：volumePath 自动修正为新挂载点 \(driftVol)")
        check(driftedItem1.targetPath.hasPrefix(driftVol), "卷漂移自愈：targetPath 前缀自动变更为新挂载点")
        check(FileManager.default.fileExists(atPath: driftedItem1.targetPath), "新 targetPath 物理验证通过")

        // 卸载漂移卷，挂载回原挂载点完成闭环自愈
        _ = runShell("/usr/bin/hdiutil detach '\(driftVol)' -force >/dev/null 2>&1")
        TemplateMigrator.postVolumeChange(volumePath: driftVol, isMounted: false, affectedCount: 3)
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))

        let returnMountRes = runShell("/usr/bin/hdiutil attach '\(origDmg)' -mountpoint '\(origVol)' -nobrowse")
        check(returnMountRes.exitCode == 0, "原盘重新挂载回原挂载点 \(origVol)")
        TemplateMigrator.postVolumeChange(volumePath: origVol, isMounted: true, affectedCount: 3)
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        check(hub.allItems[0].volumePath == origVol, "自愈验证：item1 volumePath 成功恢复为 \(origVol)")

        // 卸载原卷，进入离线保护，准备模拟同名冒牌盘侵入
        _ = runShell("/usr/bin/hdiutil detach '\(origVol)' -force >/dev/null 2>&1")
        TemplateMigrator.postVolumeChange(volumePath: origVol, isMounted: false, affectedCount: 3)
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))

        // 8. 场景 c: 同名冒牌盘防线验证（同挂载点但 UUID 不符）
        print("\n== 8. 场景 c: 同名冒牌盘挂载防御验证 ==")
        // 创建另外一个独立的全新 APFS dmg（产生全新的不同 UUID），但挂载到同名路径 /Volumes/FCPX_Step3_SSD
        let resFake = runShell("/usr/bin/hdiutil create -size 30m -fs APFS -volname 'FCPX_Step3_SSD' -ov '\(fakeDmg)'")
        check(resFake.exitCode == 0, "创建全新冒牌 APFS dmg 镜像")
        let fakeMountRes = runShell("/usr/bin/hdiutil attach '\(fakeDmg)' -mountpoint '\(origVol)' -nobrowse")
        check(fakeMountRes.exitCode == 0, "将冒牌盘挂载到原同名挂载点 \(origVol)")

        let fakeUUID = TemplateItem.getVolumeUUID(for: origVol, bypassCache: true)
        check(fakeUUID != origUUID, "确认冒牌盘 UUID 与原装盘 UUID 绝对不同", "fake=\(fakeUUID ?? ""), orig=\(origUUID ?? "")")

        // 派发挂载事件，触发一致性校验
        TemplateMigrator.postVolumeChange(volumePath: origVol, isMounted: true, affectedCount: 3)
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.2))

        let mismatchedItem1 = hub.allItems.first(where: { $0.name == "GlitchTitle" })!
        check(mismatchedItem1.isMismatchedDisk == true, "【铁血防线】识别到同名异盘，标记 isMismatchedDisk == true")
        check(mismatchedItem1.isOffline == true, "冒牌盘挂载时严禁恢复在线，保持离线保全")

        let mismatchedCard = hub.cardViews.first(where: { $0.item.name == "GlitchTitle" })!
        check(mismatchedCard.alphaValue == 0.55, "冒牌盘卡片保持 0.55 灰化")
        check(!mismatchedCard.alertBadgeLabel.isHidden, "冒牌盘卡片显示红色状态角标")
        check(mismatchedCard.alertBadgeLabel.stringValue == "异盘同名", "角标文本正确显示 [异盘同名]")
        check(mismatchedCard.toggleButton.isEnabled, "冒牌盘卡片开启按钮可交互（点击引导强制绑定）")
        check(mismatchedCard.menuButton.isEnabled, "冒牌盘卡片菜单按钮可用")
        let mismatchedMenu = mismatchedCard.menu(for: NSEvent())
        check(mismatchedMenu != nil, "冒牌盘卡片支持弹出容灾保护菜单")
        check(mismatchedMenu?.items.contains(where: { $0.title.contains("异盘同名") }) == true, "菜单包含异盘同名提示项")
        check(mismatchedMenu?.items.contains(where: { $0.title.contains("信任并强制绑定") }) == true, "菜单包含强制绑定选项")
        check(hub.statusLabel?.stringValue.contains("UUID 不符，拒绝绑定") == true, "状态栏精准告警 UUID 不符并拒绝绑定")

        // 验证 I-12: 强制绑定外置卷功能 (forceBindVolume)
        let linkItem = hub.allItems.first(where: { $0.name == "GlitchTitleLink" })!
        hub.forceBindVolume(for: linkItem, skipConfirmation: true)
        let boundLink = hub.allItems.first(where: { $0.name == "GlitchTitleLink" })!
        check(boundLink.isMismatchedDisk == false, "强制绑定后 itemLink isMismatchedDisk 重置为 false")
        check(boundLink.volumeUUID == fakeUUID, "强制绑定后 itemLink volumeUUID 更新为当前挂载卷 UUID")

        // 9. 冒牌盘拔出，原装正品盘重新插回，全自动治愈
        print("\n== 9. 冒牌盘拔出，原盘归位全自动复原 ==")
        _ = runShell("/usr/bin/hdiutil detach '\(origVol)' -force >/dev/null 2>&1")
        TemplateMigrator.postVolumeChange(volumePath: origVol, isMounted: false, affectedCount: 3)
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))

        let origBackMountRes = runShell("/usr/bin/hdiutil attach '\(origDmg)' -mountpoint '\(origVol)' -nobrowse")
        check(origBackMountRes.exitCode == 0, "原装正品盘重新挂载回 \(origVol)")
        TemplateMigrator.postVolumeChange(volumePath: origVol, isMounted: true, affectedCount: 3)
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))

        let curedItem1 = hub.allItems.first(where: { $0.name == "GlitchTitle" })!
        check(curedItem1.isMismatchedDisk == false, "原盘归位：isMismatchedDisk 成功自愈复位为 false")
        check(curedItem1.isOffline == false, "原盘归位：isOffline 恢复为 false")
        check(curedItem1.isCorrupted == false, "原盘归位：isCorrupted 为 false")

        let curedCard = hub.cardViews.first(where: { $0.item.name == "GlitchTitle" })!
        check(curedCard.alertBadgeLabel.isHidden, "原盘归位：红色警告角标自动隐藏")
        check(curedCard.alphaValue == 1.0, "原盘归位：卡片透明度完全恢复 1.0")
        check(curedCard.toggleButton.isEnabled, "原盘归位：卡片操作完全恢复可用")

        // 10. 清理退出
        cleanupAll(disks: [origVol, driftVol], dmgs: [origDmg, fakeDmg])
        check(!FileManager.default.fileExists(atPath: origVol), "测试卷 1 已安全卸载")
        check(!FileManager.default.fileExists(atPath: driftVol), "测试卷 2 已安全卸载")
        check(!FileManager.default.fileExists(atPath: origDmg), "原装临时 dmg 已清理")
        check(!FileManager.default.fileExists(atPath: fakeDmg), "冒牌临时 dmg 已清理")

        print("==================================================================")
        print("  【P2 第 3 步自愈与一致性校验】检查点汇总: 全部 \(totalChecks) 项 | 失败 \(failedChecks) 项")
        print("==================================================================")

        if failedChecks == 0 {
            print("🎉 恭喜！P2 外置盘热插拔与断链容灾保护（第 3 步自愈与一致性校验）全项断言 100% 通过！\n")
            exit(0)
        } else {
            print("❌ 警告：存在 \(failedChecks) 项检查未通过，请排查！\n")
            exit(1)
        }
    }
}
