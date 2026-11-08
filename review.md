# P2 外置盘热插拔自愈与 16 项终审整改代码审查报告 (review.md)

**审查者**：Antigravity (Project Commander & Reviewer)  
**更新时间**：2026-11-08  
**审查基准**：上级终审 13 项缺陷台账 + A 组 3 项落地指标 + 真实独立编译与测试断言  

---

## 终审 13 项缺陷与 A 组落地核销台账

| 编号 | 模块与文件 | 缺陷/要求项 | 终审改法与逐行落地情况 | 验证证据与状态 |
| :---: | :--- | :--- | :--- | :---: |
| **A1** | `LicenseManager.swift`<br/>L24–L30<br/>`AssetHubView.swift`<br/>L617–L625 | 彻底移除顶部授权 UI 块，保留核心逻辑并永久解锁 | `isProLicensed` 恒定返回 `true`，`licenseCardView` 设为 `isHidden = true` 且不加入布局栈，解除依赖 | ✅ 已闭环修复 (PASS) |
| **A2** | `MainWindowController.swift`<br/>L363–L373 | 4 个画布视图按钮仅在设计器显示，素材中心隐藏 | `comparisonSegmentedControl?.isHidden = (index != 0)`；`InfiniteCanvasView` 卷帘/并排/透视实测功能具备 | ✅ 已闭环修复 (PASS) |
| **A3** | `ResourceCardView.swift`<br/>L115–L215 | 图标与尺寸全局收敛至 16pt / 20pt 档位，剔除大 emoji | 按钮统一使用 10pt / 12pt SF Symbol (`.imageLeading` / `.imageOnly`)，彻底剥离标题中的 emoji 字符 | ✅ 已闭环修复 (PASS) |
| **S-1** | `AssetHubView.swift`<br/>L3167–L3205 | 主线程逐个打盘导致冻结 | 主线程乐观置位恢复在线；物理 `fileExists` 移入 `DispatchQueue.global` 后台执行，完成后切回主线程批量染色 | ✅ 实测通过 ($? = 0) |
| **S-2** | `TemplateTier.swift`<br/>L85–L110 | `TemplateItem.init` 查磁盘导致 stat 风暴 | 建立静态 `volumeUUIDCache`（`volumeUUIDLock` 线程安全锁保护），`init` 内部零磁盘 IO | ✅ 实测通过 ($? = 0) |
| **S-3** | `TemplateTier.swift`<br/>L111–L135<br/>`AssetCacheManager.swift`<br/>L160–L185 | 索引兜底键导致跨子分类同名模板串卡片 | 彻底删除 `category\|name` 冲突兜底键，仅保留复合唯一键 `"\(path)\|\(targetPath)"` 与 `path` | ✅ 实测通过 ($? = 0) |
| **S-4** | `AssetHubView.swift`<br/>L2993, L3085 | 路径前缀缺分隔符误伤子串同名卷 | 卷路径前缀强制规范化为 `normVol.hasSuffix("/") ? normVol : normVol + "/"` | ✅ 实测通过 ($? = 0) |
| **M-5** | `AssetHubView.swift`<br/>L3015, L3135 | 状态切换前冗余调用 `markVolumeOffline` | 剔除冗余调用，统一收敛由 `AssetCacheManager.shared.syncItemsState(from:)` 一次性完成同步 | ✅ 代码已净化 (PASS) |
| **M-6** | `TemplateTier.swift`<br/>L111–L125 | 多处复制粘贴构建索引字典 | 抽取下沉为统一公开工具函数 `TemplateItem.buildItemIndex(from:)` | ✅ 代码已净化 (PASS) |
| **M-7** | `TemplateTier.swift`<br/>L118–L122 | 索引构建覆盖语义不确定 | `buildItemIndex` 显式维护 `if index[key] == nil`（首项优先语义） | ✅ 实测通过 ($? = 0) |
| **U-8** | `ResourceCardView.swift`<br/>L180–L215 | 按钮混用大 emoji，尺寸失控 | 统一用 SF Symbol（10pt/12pt），标题文案纯文本化（"开启"、"已停用"等） | ✅ 实测通过 (PASS) |
| **U-9** | `ResourceCardView.swift`<br/>L115–L150 | 角标宽度不齐导致切换时跳动，文字挤压 | 统一固定尺寸 `80x18 pt`，居右对齐（`x: thumbW - 84`），剔除 emoji 改用纯文本 | ✅ 实测通过 (PASS) |
| **U-10**| `TemplateTier.swift`<br/>L180–L205 | 界面同一语义出现多种杂乱颜色 | 建立集中调色板 `StatusPalette`（离线灰、警示红、琥珀橙、成功绿、停用灰） | ✅ 实测通过 (PASS) |
| **I-11**| `ResourceCardView.swift`<br/>L390–L440<br/>`AssetHubView.swift`<br/>L2045–L2075 | 故障卡片点击与菜单无响应静默 | 允许点击并弹出对应 NSAlert 说明卡，菜单挂载【重新校验】与【强制绑定】交互入口 | ✅ 实测通过 ($? = 0) |
| **I-12**| `AssetHubView.swift`<br/>L2120–L2155 | 拒绝绑定后缺乏人工修复出路 | 提供 `forceBindVolume` 二次确认弹窗，确认后更新 UUID 并重新验证，杜绝静默绑定 | ✅ 实测通过 ($? = 0) |
| **R-13**| `review.md` | 报告超出实测证据（如宣称无内存泄漏等） | 严格纠偏报告文风：仅记录受控镜像实测证据；多盘真机压力测试如实标注"未验证" | ✅ 已校准规范 |

---

## 真实测试与编译证据

### 1. 全量独立干净构建 (Clean Build)
```bash
$ cd FCPXStudioNative && rm -rf /tmp/fcpx_clean_build && swift build --build-path /tmp/fcpx_clean_build
Building for debugging...
[42/45] Linking FCPXStudio
[43/45] Applying FCPXStudio
Build complete! (33.77s)
$ echo $?
0
```

### 2. P2 第 1、2 步热插拔与离线保全套件 (`tools/test_hotplug_step1_2.swift`)
```bash
$ /tmp/test_hotplug_step1_2
==================================================================
  【P2 热插拔与断链容灾】检查点汇总: 全部 53 项 | 失败 0 项
==================================================================
🎉 恭喜！P2 外置盘热插拔与断链容灾保护（第1步与第2步）全项断言 100% 通过！
$ echo $?
0
```

### 3. P2 第 3 步卷重连自愈与一致性校验套件 (`tools/test_hotplug_step3.swift`)
```bash
$ /tmp/test_hotplug_step3
==================================================================
  【P2 第 3 步自愈与一致性校验】检查点汇总: 全部 74 项 | 失败 0 项
==================================================================
🎉 恭喜！P2 外置盘热插拔与断链容灾保护（第 3 步自愈与一致性校验）全项断言 100% 通过！
$ echo $?
0
```

---

## 边界与未验证范围声明 (R-13 约束)
1. **已实测验证**：
   - 场景 a：同一物理卷（UUID 匹配）重新挂载，状态自愈清零。
   - 场景 b：卷名漂移（新挂载点但 UUID 一致），路径自动改写且软链接完成重建。
   - 场景 c：异盘同名（同名挂载点但 UUID 不符），冒牌盘拦截告警、拒绝绑定、提供人工强制绑定入口。
   - 场景 d：模板物理文件损坏/丢失，标记故障红标，禁止物理删除。
2. **明确未验证**：
   - macOS 真机多块物理外置机械硬盘（HDD）瞬时休眠与多线程同时拔插的极限 IO 压力测试。
   - 生产环境长时间运行的内存泄漏与 Instruments 内存分析（暂未做专项 profile 分析，标注为：**未验证**）。

---

## 打包真实性说明 (P4)
当前本地安装的 `/Applications/FCPX Studio Pro.app`（构建时间为今日凌晨 02:04）尚未包含今日完成的 P2 热插拔断链容灾与自愈代码。待本轮代码终审完全通过后，需执行标准化重打包流程更新二进制与安装包。
