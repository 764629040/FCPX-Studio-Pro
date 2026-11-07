import AppKit
import Foundation

// ═══════════════════════════════════════════════════════════════
//  r43_harness.swift
//  开发任务单 R43 —— 多工作区情境隔离配置系统（Workspace Context Isolation）直证套件
// ═══════════════════════════════════════════════════════════════

@main
final class R43Harness {
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
        print("  FCPX Studio Pro —— R43 多工作区情境隔离配置系统直证")
        print("==================================================")

        test1_ProfileManager_BuiltinsAndPersistence()
        test2_ContextIsolation_BatchDisabledAndMatching()
        test3_ContextSwitching_Reversibility()
        test4_ManualTemplateAssignment_FineGrainedToggle()
        test5_DashboardUI_AndSidebarIntegration()
        test6_Performance_BatchOperationSpeed()

        print("\n==================================================")
        print("  总计检查点: \(totalChecks) | 失败: \(failedChecks)")
        print("==================================================")

        if failedChecks > 0 {
            exit(1)
        }
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 1：情境数据模型、出厂四大预置与沙盒化 JSON 持久化 CRUD
    // ─────────────────────────────────────────────────────────────
    static func test1_ProfileManager_BuiltinsAndPersistence() {
        print("\n── 判据 1：情境数据模型与持久化 CRUD (WorkspaceProfileManager) ──")
        let tempProfilesDir = NSTemporaryDirectory() + "fcpx_r43_profiles_test_\(UUID().uuidString)"
        setenv("FCPXSTUDIO_PROFILES_DIR", tempProfilesDir, 1)
        defer {
            try? FileManager.default.removeItem(atPath: tempProfilesDir)
        }

        let mgr = WorkspaceProfileManager.shared
        mgr.reload()

        let builtins = mgr.profiles
        check(builtins.count >= 4, "已载入出厂四大预置情境", "count=\(builtins.count)")

        let allActive = mgr.profiles.first(where: { $0.id == WorkspaceProfile.allActiveId })
        check(allActive != nil, "全量模式存在", "id=\(WorkspaceProfile.allActiveId)")
        check(allActive?.isDefault == true, "全量模式 isDefault 为 true")
        check(allActive?.isBuiltin == true, "全量模式 isBuiltin 为 true")
        check(allActive?.icon == "🌟", "全量模式图标正确", "\(allActive?.icon ?? "")")

        let wedding = mgr.profiles.first(where: { $0.id == WorkspaceProfile.weddingId })
        check(wedding != nil, "婚礼纪实情境存在", "id=\(WorkspaceProfile.weddingId)")
        check(wedding?.icon == "💍", "婚礼情境图标正确", "\(wedding?.icon ?? "")")
        check(wedding?.category == "行业专属", "婚礼情境分类为行业专属")

        let commercial = mgr.profiles.first(where: { $0.id == WorkspaceProfile.commercialId })
        check(commercial != nil, "商业广告与宣传片情境存在", "id=\(WorkspaceProfile.commercialId)")
        check(commercial?.icon == "📺", "商业情境图标正确", "\(commercial?.icon ?? "")")

        let vlog = mgr.profiles.first(where: { $0.id == WorkspaceProfile.shortVideoId })
        check(vlog != nil, "短视频与自媒体情境存在", "id=\(WorkspaceProfile.shortVideoId)")
        check(vlog?.icon == "📱", "短视频情境图标正确", "\(vlog?.icon ?? "")")

        // 验证文件实际持久化至沙盒目录
        let jsonPath = WorkspaceProfileManager.profilesFilePath
        check(FileManager.default.fileExists(atPath: jsonPath), "配置文件成功落盘", jsonPath)

        // 测试创建自定义情境
        let custom = mgr.addProfile(
            name: "纪录片影视包装",
            icon: "📽️",
            category: "自定义情境",
            description: "人文纪录片调色与大字片头",
            includedTemplateIDs: ["纪录片", "Film", "Cinema"]
        )
        check(mgr.profiles.contains(where: { $0.id == custom.id }), "新情境添加成功", "\(custom.name)")
        check(!custom.isBuiltin, "自定义情境 isBuiltin 为 false")

        // 测试重新从磁盘读取持久化
        mgr.reload()
        check(mgr.profiles.contains(where: { $0.id == custom.id }), "磁盘重新加载后自定义情境依然存在")

        // 测试复制情境
        let copy = mgr.duplicateProfile(id: custom.id)
        check(copy != nil && copy?.name.contains("副本") == true, "情境复制成功", "\(copy?.name ?? "")")

        // 测试删除：内置情境受保护禁止删除
        let deleteBuiltinResult = mgr.deleteProfile(id: WorkspaceProfile.weddingId)
        check(deleteBuiltinResult == false, "出厂内置情境拒绝删除保护生效")

        // 测试删除自定义情境
        let deleteCustomResult = mgr.deleteProfile(id: custom.id)
        check(deleteCustomResult == true, "自定义情境删除成功")
        check(!mgr.profiles.contains(where: { $0.id == custom.id }), "自定义情境已从列表移除")
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 2：一键激活情境时磁盘 .disabled 批量启停隔离与命中精度
    // ─────────────────────────────────────────────────────────────
    static func test2_ContextIsolation_BatchDisabledAndMatching() {
        print("\n── 判据 2：磁盘 .disabled 批量隔离与白名单精准匹配 ──")
        let tempProfilesDir = NSTemporaryDirectory() + "fcpx_r43_prof_\(UUID().uuidString)"
        let tempTemplatesDir = NSTemporaryDirectory() + "fcpx_r43_templates_\(UUID().uuidString)"
        setenv("FCPXSTUDIO_PROFILES_DIR", tempProfilesDir, 1)
        setenv("FCPXSTUDIO_USER_TEMPLATES_ROOT", tempTemplatesDir, 1)
        defer {
            try? FileManager.default.removeItem(atPath: tempProfilesDir)
            try? FileManager.default.removeItem(atPath: tempTemplatesDir)
        }

        let fm = FileManager.default
        let titlesDir = "\(tempTemplatesDir)/Titles.localized"
        let effectsDir = "\(tempTemplatesDir)/Effects.localized"
        let transDir = "\(tempTemplatesDir)/Transitions.localized"
        let genDir = "\(tempTemplatesDir)/Generators.localized"
        try? fm.createDirectory(atPath: titlesDir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: effectsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: transDir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: genDir, withIntermediateDirectories: true)

        // 模拟生成 10 个跨类别模板（4个婚礼，3个商业，3个短视频）
        let mockTemplates = [
            ("\(titlesDir)/唯美浪漫婚礼片头", "婚礼片头"),
            ("\(titlesDir)/PSD婚礼字幕", "婚礼字幕"),
            ("\(titlesDir)/科技感商业HUD字幕条", "商业字幕"),
            ("\(titlesDir)/短视频爆款Vlog花字", "短视频花字"),
            ("\(effectsDir)/婚礼柔光浪漫滤镜", "婚礼特效"),
            ("\(effectsDir)/赛博朋克商业特效", "商业特效"),
            ("\(transDir)/光晕婚礼唯美转场", "婚礼转场"),
            ("\(transDir)/商业快节奏故障转场", "商业转场"),
            ("\(genDir)/短视频动感卡点背景", "短视频生成器"),
            ("\(genDir)/抖音快手网感爆款背景", "自媒体生成器")
        ]
        for (path, _) in mockTemplates {
            try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            try? "mock".write(toFile: "\(path)/template.txt", atomically: true, encoding: .utf8)
        }

        let mgr = WorkspaceProfileManager.shared
        mgr.reload()

        let roots = TemplateTierRoots(builtin: nil, user: tempTemplatesDir, system: "/tmp/nonexistent", builtinNote: "测试环境")

        // 1. 激活婚礼纪实情境 (weddingId)
        do {
            let stats = try mgr.activateProfileSync(id: WorkspaceProfile.weddingId, roots: roots)
            check(stats.profileId == WorkspaceProfile.weddingId, "激活目标 ID 正确")
            check(stats.totalTemplates == 10, "模板总数正确 (10)", "total=\(stats.totalTemplates)")
            check(stats.activeTemplates == 4, "婚礼情境活跃数精准为 4", "active=\(stats.activeTemplates)")
            check(stats.disabledTemplates == 6, "非婚礼模板精准休眠 6 个", "disabled=\(stats.disabledTemplates)")
            check(stats.reductionPercentage == 60.0, "节省 FCPX 启动项比例为 60.0%", "\(stats.reductionPercentage)%")
            check(stats.estimatedSpeedup >= 2.5, "预估启动提速倍率 >= 2.5x", "\(stats.estimatedSpeedup)x")

            // 磁盘物理验证：婚礼模板应无 .disabled，非婚礼模板应重命名为 .disabled
            check(fm.fileExists(atPath: "\(titlesDir)/唯美浪漫婚礼片头"), "婚礼片头保持激活")
            check(fm.fileExists(atPath: "\(titlesDir)/PSD婚礼字幕"), "PSD婚礼字幕保持激活")
            check(fm.fileExists(atPath: "\(effectsDir)/婚礼柔光浪漫滤镜"), "婚礼柔光特效保持激活")
            check(fm.fileExists(atPath: "\(transDir)/光晕婚礼唯美转场"), "婚礼唯美转场保持激活")

            check(fm.fileExists(atPath: "\(titlesDir)/科技感商业HUD字幕条.disabled"), "商业字幕已物理置为 .disabled")
            check(fm.fileExists(atPath: "\(titlesDir)/短视频爆款Vlog花字.disabled"), "短视频花字已物理置为 .disabled")
            check(fm.fileExists(atPath: "\(effectsDir)/赛博朋克商业特效.disabled"), "商业特效已物理置为 .disabled")
            check(fm.fileExists(atPath: "\(transDir)/商业快节奏故障转场.disabled"), "商业转场已物理置为 .disabled")
            check(fm.fileExists(atPath: "\(genDir)/短视频动感卡点背景.disabled"), "短视频背景已物理置为 .disabled")
            check(fm.fileExists(atPath: "\(genDir)/抖音快手网感爆款背景.disabled"), "自媒体背景已物理置为 .disabled")
        } catch {
            check(false, "婚礼情境激活失败", error.localizedDescription)
        }
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 3：情境切换可逆性（婚礼 -> 商业 -> 短视频 -> 全量恢复）
    // ─────────────────────────────────────────────────────────────
    static func test3_ContextSwitching_Reversibility() {
        print("\n── 判据 3：情境切换可逆性与全量恢复 (Reversibility) ──")
        let tempProfilesDir = NSTemporaryDirectory() + "fcpx_r43_rev_p_\(UUID().uuidString)"
        let tempTemplatesDir = NSTemporaryDirectory() + "fcpx_r43_rev_t_\(UUID().uuidString)"
        setenv("FCPXSTUDIO_PROFILES_DIR", tempProfilesDir, 1)
        setenv("FCPXSTUDIO_USER_TEMPLATES_ROOT", tempTemplatesDir, 1)
        defer {
            try? FileManager.default.removeItem(atPath: tempProfilesDir)
            try? FileManager.default.removeItem(atPath: tempTemplatesDir)
        }

        let fm = FileManager.default
        let titlesDir = "\(tempTemplatesDir)/Titles.localized"
        try? fm.createDirectory(atPath: titlesDir, withIntermediateDirectories: true)

        let templates = ["唯美婚礼片头", "商业科技HUD", "Vlog短视频花字"]
        for t in templates {
            let p = "\(titlesDir)/\(t)"
            try? fm.createDirectory(atPath: p, withIntermediateDirectories: true)
            try? "mock".write(toFile: "\(p)/content.txt", atomically: true, encoding: .utf8)
        }

        let mgr = WorkspaceProfileManager.shared
        mgr.reload()
        let roots = TemplateTierRoots(builtin: nil, user: tempTemplatesDir, system: "/tmp/nonexistent", builtinNote: "测试环境")

        // 步骤 1：激活婚礼模式
        _ = try? mgr.activateProfileSync(id: WorkspaceProfile.weddingId, roots: roots)
        check(fm.fileExists(atPath: "\(titlesDir)/唯美婚礼片头"), "婚礼模式：婚礼片头激活")
        check(fm.fileExists(atPath: "\(titlesDir)/商业科技HUD.disabled"), "婚礼模式：商业HUD休眠")
        check(fm.fileExists(atPath: "\(titlesDir)/Vlog短视频花字.disabled"), "婚礼模式：短视频花字休眠")

        // 步骤 2：切换为商业广告模式（验证即时反转）
        _ = try? mgr.activateProfileSync(id: WorkspaceProfile.commercialId, roots: roots)
        check(fm.fileExists(atPath: "\(titlesDir)/唯美婚礼片头.disabled"), "商业模式：婚礼片头反转休眠")
        check(fm.fileExists(atPath: "\(titlesDir)/商业科技HUD"), "商业模式：商业HUD唤醒激活")
        check(fm.fileExists(atPath: "\(titlesDir)/Vlog短视频花字.disabled"), "商业模式：短视频花字维持休眠")

        // 步骤 3：切换为短视频自媒体模式
        _ = try? mgr.activateProfileSync(id: WorkspaceProfile.shortVideoId, roots: roots)
        check(fm.fileExists(atPath: "\(titlesDir)/唯美婚礼片头.disabled"), "短视频模式：婚礼片头休眠")
        check(fm.fileExists(atPath: "\(titlesDir)/商业科技HUD.disabled"), "短视频模式：商业HUD休眠")
        check(fm.fileExists(atPath: "\(titlesDir)/Vlog短视频花字"), "短视频模式：短视频花字唤醒激活")

        // 步骤 4：一键恢复全量模式 (Default - All Active)
        let allStats = try? mgr.activateProfileSync(id: WorkspaceProfile.allActiveId, roots: roots)
        check(allStats?.activeTemplates == 3, "全量恢复后活跃数恢复为 3")
        check(allStats?.disabledTemplates == 0, "全量恢复后休眠数为 0")
        check(fm.fileExists(atPath: "\(titlesDir)/唯美婚礼片头"), "全量恢复：婚礼片头恢复")
        check(fm.fileExists(atPath: "\(titlesDir)/商业科技HUD"), "全量恢复：商业HUD恢复")
        check(fm.fileExists(atPath: "\(titlesDir)/Vlog短视频花字"), "全量恢复：短视频花字恢复")

        // 确认磁盘中没有任何 .disabled 残留
        let entries = (try? fm.contentsOfDirectory(atPath: titlesDir)) ?? []
        let hasDisabled = entries.contains(where: { $0.hasSuffix(".disabled") })
        check(!hasDisabled, "磁盘完全洁净无任何 .disabled 残留", "entries=\(entries)")
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 4：细粒度手动矩阵勾选 (Custom Assignment & Exclusion)
    // ─────────────────────────────────────────────────────────────
    static func test4_ManualTemplateAssignment_FineGrainedToggle() {
        print("\n── 判据 4：细粒度手动矩阵勾选与显式排除 ──")
        let tempProfilesDir = NSTemporaryDirectory() + "fcpx_r43_toggle_\(UUID().uuidString)"
        setenv("FCPXSTUDIO_PROFILES_DIR", tempProfilesDir, 1)
        defer {
            try? FileManager.default.removeItem(atPath: tempProfilesDir)
        }

        let mgr = WorkspaceProfileManager.shared
        mgr.reload()

        let profile = mgr.profiles.first(where: { $0.id == WorkspaceProfile.weddingId })!

        // 初始状态下，“唯美婚礼片头”自然命中
        check(profile.matches(templateName: "唯美婚礼片头"), "自然命中出厂婚礼关键字")

        // 手动在婚礼情境中将“唯美婚礼片头”反勾选（排除）
        mgr.toggleTemplate(named: "唯美婚礼片头", in: profile.id)
        let updatedProfile = mgr.profiles.first(where: { $0.id == profile.id })!
        check(!updatedProfile.matches(templateName: "唯美婚礼片头"), "反勾选后该模板被排除")

        // 手动把不相关的“企业发布会开场”强制加入婚礼情境
        check(!updatedProfile.matches(templateName: "企业发布会开场"), "初始企业模板不匹配婚礼")
        mgr.toggleTemplate(named: "企业发布会开场", in: profile.id)
        let updatedProfile2 = mgr.profiles.first(where: { $0.id == profile.id })!
        check(updatedProfile2.matches(templateName: "企业发布会开场"), "强制添加后企业模板成功归属婚礼情境")
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 5：UI 控制面板、侧边栏接入与 MainWindowController 联动
    // ─────────────────────────────────────────────────────────────
    static func test5_DashboardUI_AndSidebarIntegration() {
        print("\n── 判据 5：UI 控制面板、侧边栏与 MainWindowController 联动 ──")
        let tempProfilesDir = NSTemporaryDirectory() + "fcpx_r43_ui_\(UUID().uuidString)"
        setenv("FCPXSTUDIO_PROFILES_DIR", tempProfilesDir, 1)
        defer {
            try? FileManager.default.removeItem(atPath: tempProfilesDir)
        }

        let mwc = MainWindowController()
        check(mwc.assetHubView != nil, "AssetHubView 实例化成功")
        check(mwc.profileBadgeButton != nil, "MainWindowController 顶部情境胶囊状态栏已创建")

        // 验证胶囊文字初始匹配
        let activeProfile = WorkspaceProfileManager.shared.getActiveProfile()
        check(mwc.profileBadgeButton.title.contains(activeProfile.icon), "情境胶囊显示活跃图标", mwc.profileBadgeButton.title)

        // 验证侧边栏项数量与第 9 项为【🗂️  工作区情境】
        let sidebarBtns = mwc.assetHubView.sidebarButtons
        check(sidebarBtns.count >= 10, "侧边栏按钮包含全部超级模块与情境项", "count=\(sidebarBtns.count)")

        let profileBtn = sidebarBtns.first(where: { $0.tag == 9 })
        check(profileBtn != nil, "侧边栏存在 Tag 9 的情境入口")
        check(profileBtn?.title.contains("工作区情境") == true, "侧边栏标题包含工作区情境", "\(profileBtn?.title ?? "")")

        // 测试主控制器一键跳转 `showWorkspaceProfiles()`
        mwc.showWorkspaceProfiles()
        check(mwc.segmentedControl.selectedSegment == 1, "主引擎切换至引擎二素材中心")
        check(mwc.assetHubView.currentSidebarIndex == 9, "侧边栏当前选中索引为 9")
        check(mwc.assetHubView.profileContainerView.isHidden == false, "情境管理看板容器处于显示状态")
        check(mwc.assetHubView.templateContainerView.isHidden == true, "模板普通视图隐藏")

        // 验证看板内部卡片流构建
        let dashboard = mwc.assetHubView.profileDashboardView!
        dashboard.refreshData()
        let cards = dashboard.profileCardsStackView.arrangedSubviews
        check(cards.count >= 4, "顶部情境卡片流成功渲染四大情境卡片", "cards=\(cards.count)")

        // 验证看板指标行标签存在且非空
        check(!dashboard.activeProfileValueLabel.stringValue.isEmpty, "指标行活跃情境标签有效", dashboard.activeProfileValueLabel.stringValue)
        check(!dashboard.activeCountValueLabel.stringValue.isEmpty, "指标行活跃数标签有效", dashboard.activeCountValueLabel.stringValue)

        // 切换情境验证顶部胶囊实时刷新
        WorkspaceProfileManager.shared.activateProfile(id: WorkspaceProfile.weddingId) { _ in }
        waitOnMainRunLoop(timeout: 2.0) {
            mwc.profileBadgeButton.title.contains("💍")
        }
        check(mwc.profileBadgeButton.title.contains("💍"), "情境切换后主窗口顶部胶囊自动更新为婚礼图标", mwc.profileBadgeButton.title)
    }

    // ─────────────────────────────────────────────────────────────
    // 判据 6：毫秒级高性能批处理压测（50个模板秒级隔离 < 50ms）
    // ─────────────────────────────────────────────────────────────
    static func test6_Performance_BatchOperationSpeed() {
        print("\n── 判据 6：毫秒级高性能批处理压测 ──")
        let tempTemplatesDir = NSTemporaryDirectory() + "fcpx_r43_perf_t_\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(atPath: tempTemplatesDir)
        }

        let fm = FileManager.default
        let titlesDir = "\(tempTemplatesDir)/Titles.localized"
        try? fm.createDirectory(atPath: titlesDir, withIntermediateDirectories: true)

        // 模拟生成 50 个模板
        for i in 1...50 {
            let name = (i % 2 == 0) ? "婚礼片头_\(i)" : "商业包装_\(i)"
            let p = "\(titlesDir)/\(name)"
            try? fm.createDirectory(atPath: p, withIntermediateDirectories: true)
            try? "ok".write(toFile: "\(p)/file.txt", atomically: true, encoding: .utf8)
        }

        let mgr = WorkspaceProfileManager.shared
        let roots = TemplateTierRoots(builtin: nil, user: tempTemplatesDir, system: "/tmp/nonexistent", builtinNote: "测试环境")

        let startTime = CFAbsoluteTimeGetCurrent()
        let stats = try? mgr.activateProfileSync(id: WorkspaceProfile.weddingId, roots: roots)
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0

        print("⚡️ 50 个模板批量隔离耗时: String(format: \"%.2f\", elapsedMs) ms")
        check(stats != nil, "批处理完成并返回有效统计")
        check(stats?.totalTemplates == 50, "50 个模板全部参与调度")
        check(stats?.activeTemplates == 25, "25 个婚礼模板激活")
        check(stats?.disabledTemplates == 25, "25 个商业模板精准置为 .disabled")
        check(elapsedMs < 150.0, "50 个模板批量调度耗时处于毫秒级区间 (<150ms)", String(format: "%.2f ms", elapsedMs))
    }
}
