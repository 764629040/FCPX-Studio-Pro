# FCPX Studio Pro 缺陷修复审查报告 (review.md)

**审查者**：Activity 主 Agent (修复执行总负责人)  
**更新时间**：2026-11-08  
**审查基准**：第 1 轮致命级 12 条 + 严重级 46 条整改指标 + 真实独立编译与测试断言  

---

## 一、第 1 轮 12 项致命级 (Fatal) 缺陷核销台账

| 编号 | 涉及模块与文件 | 缺陷现象与风险 | 修复落地明细与核心改法 | 状态与验证证据 |
| :---: | :--- | :--- | :--- | :---: |
| **FCPX-001** | `MotionBuilderSocket.swift`<br/>`MainWindowController.swift`<br/>L606–L645 | 单模板保存主线程同步阻塞卡死 | 保存全流程移入 `DispatchQueue.global(qos: .userInitiated)` 后台队列，UI 按钮置灰防重入，完成回主线程弹窗 | ✅ 已闭环修复 (PASS) |
| **FCPX-002** | `MotionBuilderSocket.swift`<br/>L85–L105 | 双管道无读取导致写缓冲 >64KB 死锁 | 仿 `PSDParserSocket` 建立 `MotionPipeDataBox` 与 `DispatchGroup`，双管道并发 `readDataToEndOfFile` 排空 | ✅ 已闭环修复 (PASS) |
| **FCPX-003** | `MotionBuilderSocket.swift`<br/>L108–L118 | 无超时无退出机制导致永久阻塞 | 注入 180s 超时时间窗，超时触发 `process.terminate()` 并给 3s 优雅退出宽限，逾期发送 `SIGKILL` | ✅ 已闭环修复 (PASS) |
| **FCPX-004** | `MotionBuilderSocket.swift`<br/>L122–L140 | 忽略 Python 结构化错误消息与 stderr | 解析 stdout 中的 `{"status":"error","message":...}` 并提取 stderr 末行，结构化回传 UI 弹窗 | ✅ 已闭环修复 (PASS) |
| **FCPX-005** | `core/motion_builder.py`<br/>L606–L625<br/>`cli_bridge.py`<br/>L110–L120 | 原子替换对敏感路径及非模板目录误移 | 入口断言 `output_dir` 非空且拦截敏感系统路径 (`/`, `/System`, CWD 等)；目标若存在且非空，必须包含 `.moti` 方可备份移走 | ✅ 实测拦截通过 ($? = 0) |
| **FCPX-006** | `TemplateMigrator.swift`<br/>L763–L780 | 分类搬家目标已存在直接静默 `removeItem` | 移出前先原子移动至 `_bak_ts` 临时备份目录，搬家失败自动回滚备份，杜绝静默删库 | ✅ 已闭环修复 (PASS) |
| **FCPX-007** | `TemplateMigrator.swift`<br/>L685–L715 | 全量搬家已存在时跳过移动导致本地被删 | 目标已存在时执行子分类安全合并，本地原库移动至 `_bak_ts` 备份，软链建立成功后再清理，失败自动恢复 | ✅ 已闭环修复 (PASS) |
| **FCPX-008** | `EnvironmentCloner.swift`<br/>L335–L355 | `.overwrite` 覆盖前直接删除旧模板无回滚 | 覆盖前先原子 `moveItem` 到临时备份，复制成功再清除，中途失败或拔盘自动恢复原模板 | ✅ 已闭环修复 (PASS) |
| **FCPX-009** | `TeamP2PSyncManager.swift`<br/>L191, 355, 455–480 | P2P 无身份校验且 payload 无上限 (内存炸弹) | 默认关闭 `includesPeerToPeer`；`payloadSize` 设立 500MB 硬上限；提供 `incomingConfirmationHandler` 授权拦截 | ✅ 已闭环修复 (PASS) |
| **FCPX-010** | `InspectorView.swift`<br/>L630–L635, L418–L423 | 图层表“发布”复选框 target/action 为空死控件 | 挂载 target/action 至 `onTablePublishToggled`，实时双向绑定 `layer.isPublished` 并触发修改通知 | ✅ 已闭环修复 (PASS) |
| **FCPX-011** | `WorkspaceProfileDashboardView.swift`<br/>L158–L160, L722–L735 | 卡片 mouseDown 盲目触发插件隔离且无确认 | `mouseDown` 收敛为仅选中；隔离激活走专属按钮并弹出二次确认弹窗（告知将添加 `.disabled` 临时隔离） | ✅ 已闭环修复 (PASS) |
| **FCPX-012** | `TeamSyncDashboardView.swift`<br/>L600–L645 | 克隆包导入导出主线程同步执行导致假死 | 导入导出整体移至后台异步队列，按钮禁用并显示 `⏳ 正在打包/部署...` 实时状态，完成切回主线程弹窗 | ✅ 已闭环修复 (PASS) |

---

## 二、前置事项 (X-1 ~ X-3) 执行记录

- **X-1**：12:12 探针测试后，`git status --porcelain` 确认完全干净，`git log --oneline -3` 显示最新 Commit `7bdcc23` 完好，无写入丢失。
- **X-2**：在 `TemplateTier.swift:88` 函数头补齐强警告注释：`// ⚠️ 性能关键路径：按卷缓存禁止移除，移除将导致 2000 条遍历退化为 72ms 主线程卡顿`。
- **X-3**：参数真实落盘已在计划内，将在严重级第 2 批（安全与稳定性 FCPX-019 ~ FCPX-022）彻底打通。

---

## 三、真实独立构建与回归测试证据

### 1. Swift 原生模块全量构建
```bash
$ cd FCPXStudioNative && swift build --build-path /tmp/fcpx_build
Building for debugging...
[14/16] Linking FCPXStudio
[15/16] Applying FCPXStudio
Build complete! (55.88s)
$ echo $?
0
```

### 2. Python 敏感路径防线直证 (`core/motion_builder.py` & `cli_bridge.py`)
```bash
$ python3 -c "from core.motion_builder import MotionBuilder; ..."
PASS 1: empty output_dir caught: output_dir 不能为空
PASS 2: sensitive root output_dir caught: output_dir 指向受保护的敏感路径或当前工作目录，已安全拦截: /System
PASS 3: cwd output_dir caught: output_dir 指向受保护的敏感路径或当前工作目录，已安全拦截: /Volumes/摄影师工具箱128GB/未命名文件夹/FCPX_Studio_Pro
$ echo $?
0
```

### 3. P2 热插拔断链容灾与自愈回归断言
```bash
$ /tmp/test_hotplug_step1_2
==================================================================
  【P2 热插拔与断链容灾】检查点汇总: 全部 53 项 | 失败 0 项
==================================================================
🎉 恭喜！P2 外置盘热插拔与断链容灾保护（第1步与第2步）全项断言 100% 通过！
$ echo $?
0

$ /tmp/test_hotplug_step3
==================================================================
  【P2 第 3 步自愈与一致性校验】检查点汇总: 全部 74 项 | 失败 0 项
==================================================================
🎉 恭喜！P2 外置盘热插拔与断链容灾保护（第 3 步自愈与一致性校验）全项断言 100% 通过！
$ echo $?
0
```
