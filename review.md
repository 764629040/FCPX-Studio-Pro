# P2 外置盘热插拔与断链容灾保护（第 1 步与第 2 步）代码审查报告 (review.md)

**审查者**：Antigravity (Project Commander & Reviewer)  
**更新时间**：2026-11-08  
**审查基准**：上级终审意见指令闭环核对与逐行 diff 验证  

---

## 逐行审查结论与终审整改核销台账

| 编号 | 文件与行号 | 缺陷/风险项 | 严重级别 | 终审改法与落地情况 | 状态 |
| :---: | :--- | :--- | :---: | :--- | :---: |
| **01** | `AssetHubView.swift`<br/>L2850–L2940 | 主线程平方级匹配：`handleVolumeStatusChange` 循环内多处嵌套调用 `allItems.first(where:)`，导致 O(n²) 暴力线性扫描，上万素材主线程会卡死 | **严重 (Critical)** | **已落地**：预先为 `allItems` 建立复合键 `itemMap` 字典，`plugins`、`groupItems`、`cardViews` 全部转为 O(1) 字典查表，整体降为严格 O(n) | ✅ 已闭环修复 (Resolved) |
| **02** | `TemplateMigrator.swift`<br/>L202–L235 | `isPathOffline` 非纯函数：内含 `FileManager.fileExists` 磁盘 IO 与全局写锁写入副作用，切组切列表引发主线程磁盘 stat 风暴 | **严重 (Critical)** | **已落地**：彻底剔除所有磁盘与文件系统 IO，改为基于内存集合 `_offlineVolumes` 的纯前缀查表函数，状态单向由通知回调维护 | ✅ 已闭环修复 (Resolved) |
| **03** | `review.md` | 审查报告与实际代码状态不同步问题 | **中等 (Medium)** | **已校正**：报告版本已全面核实并与代码实际一致性完成 1:1 对齐校正 | ✅ 已校正 (Synchronized) |
| **04** | `ResourceCardView.swift`<br/>L225–L270 | 离线卡片 0.55 半透明灰化、黄色角标、开关/菜单禁用，杜绝离线删除与启停 | 合规通过 | 离线容灾防护与视觉反馈完备 | ✅ PASS |
| **05** | `TemplateTier.swift`<br/>L78–L125 | `TemplateItem` 扩展 `isOffline` 与 `volumePath`，构造器智能解析外置卷 | 合规通过 | 兼容历史调用，外置卷路径提取准确 | ✅ PASS |

---

## 技术债备忘（待第 3 步开工前清理）
1. Model 层依赖 AppKit；`TemplateMigrator.init()` 隐式启动全局监听，需解耦为显式生命周期注入。
2. SPM 外置盘 I/O 规避：外置盘构建需指定本地 `--build-path` 避免 SQLite attach 锁死。

---

## 本地 Commit 记录
- 本地提交已由指挥官完成：`83316ab` - `feat(storage): P2 volume hotplug notification & offline graying safety protection (steps 1 & 2)`
- **严格遵守纪律：未向 GitHub 远端 push，静待所有者审核拍板**。
