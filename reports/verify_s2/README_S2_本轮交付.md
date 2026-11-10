# S2｜真机验证代理 · 本轮交付总览（只跑不改）

- 会话时间：2026-11-10 18:49–19:0x CST
- 项目根：`/Volumes/摄影师工具箱128GB/未命名文件夹/FCPX_Studio_Pro`
- 现场事实（18:44 用户核实 + 本轮 18:51:59 只读复核）：**Final Cut Pro 在跑（PID 97387）、FCPX Studio Pro R2.app 在跑（PID 96268）**
- 硬约束：**「FCPX 在跑就不能动它的库；等用户主动退出再测」**
- **真机验证尚未执行，本轮未产出真机结论。**

> 本轮做的是「所有不触碰 FCPX 库的前置工作」：人工引导清单、静态盘点、计时口径与脚本、RSS 只读观测、真实屏幕截图。
> 没有点击任何真实库、没有碰 Render Files、没有启动/退出/重启任何 App、没有点 FCPX、没有等待 2 小时。

---

## 1. 产出文件清单（全部为新增，未修改任何现有文件）

### `reports/verify_s2/`（新增目录）

| # | 文件 | 大小 | 说明 |
|---|---|---|---|
| 1 | `README_S2_本轮交付.md` | 本文件 | 总览 / t0 / 四项状态 / 阻塞项 / 约束自检 |
| 2 | `看板高危动作_静态盘点与视觉核对表.md` | 10.3 KB | 任务 2：三个动作入口行号 + 代码层预期 + 空置的真机勾选表 |
| 3 | `乐观态_中间态计时口径.md` | ~11 KB | 任务 3：起止时刻、采样点、计时口径、行号漂移对照 |
| 4 | `optimistic_duration.py` | 11.6 KB | 任务 3：时长计算脚本（日志 / 截图 mtime / CSV 三种输入） |
| 5 | `rss_sample.py` | 9.7 KB | 任务 4：`sample_once` / `report` / `loop`（本轮禁用） |
| 6 | `rss_t0.txt` | 2.0 KB | 任务 4：**t0 数值写盘**（人可读） |
| 7 | `rss_samples.jsonl` | 345 B | 任务 4：t0 一条结构化记录，供脚本对比 |
| 8 | `screen_state_20261110_1849.png` | 2,646,979 B (2.6 MB) | 任务 5：当前屏幕真实截图 |

### `docs/`（新增引导清单）

| # | 文件 | 大小 | 说明 |
|---|---|---|---|
| 9 | `S2_TR008③_真机运行态_人工引导清单.md` | 13.0 KB | 任务 1：NSOpenPanel 精确点击序列 / 截图清单 / 崩溃判定 / 记录表 |

**写入总量：`2.6M`（`reports/verify_s2/` 全目录），远低于 50 MB 上限。**

---

## 2. t0 RSS 数值（只读观测，已写盘）

| 项 | 值 |
|---|---|
| 采集时间 | `2026-11-10T18:51:59+08:00` (CST) |
| 目标进程 | FCPX Studio Pro R2.app, PID 96268 |
| **t0 RSS（KB）** | **82016 KB** |
| **t0 RSS（MB）** | **80.09375 MB ≈ 80.09 MB** |
| 原始字节 | 83,984,384 bytes (`pti_resident_size`) |
| 旁路佐证 | Final Cut Pro PID 97387 = 284816 KB = 278.14 MB（仅证明在跑，不动它的库） |

**如实记录（不伪装）**：用户指定的 `ps -o rss= -p 96268` 在本会话被沙箱 exec 拒绝 —— `/bin/ps`、`top` 均报 `operation not permitted`，`python3 subprocess` 调 `/bin/ps` 报 `PermissionError: [Errno 1]`。
改用 **`libproc proc_pidinfo(PROC_PIDTASKINFO)`** 的 `pti_resident_size / 1024`，与 `ps -o rss=` 同为 KB 口径，纯只读、无需 `task_for_pid`、不 attach 进程、不触碰 FCPX 库。脚本里仍把 `ps` 作为首选、libproc 作为 fallback。

**不做、也不宣称做泄漏检测**：`leaks` / `footprint` 需 `task_for_pid`，沙箱已拒，本轮只有 RSS 观测。

**t1 尚未采集。** `report` 自检输出：采样点数 1、跨度 0.0 min / 目标 120 min、Δ = +0 KB、`t1 尚未采集，2 小时前后对比不成立`。
采样间隔设计 600 s，目标跨度 7200 s，共 13 个点（t0 + 12 个 10 分钟点，t1 = t0 + 120 min）。**本轮不等待 2 小时、不起 detach/nohup/后台进程。**
`sample_once --dry-run` 自检读到 82192 KB（19:04:55），**未写盘、不是 t1、不计入前后对比**。

> **t1 需会话后续或用户回来再采。** 若用户已主动退出 R2.app，t1 须在 R2 再次处于运行态的后续会话里采（本代理不启动/重启任何 App）。

---

## 3. 四项准备状态（逐项）

| 任务 | 产出 | 准备状态 | 是否真机结论 |
|---|---|---|---|
| **1. TR-008③ 真机运行态 trash Render Files** | `docs/S2_TR008③_真机运行态_人工引导清单.md` | ✅ 纸面准备完成：NSOpenPanel 精确点击序列（含 `CleanerDashboardView.swift:347-365` 面板配置、`选择资源库` 按钮）、11 张截图清单（文件名/截什么/何时）、5 级崩溃判定、含「是否崩溃 / FCPX 版本号 / Render Files 子项数量 / Original Media 是否保留」四项的空记录表 | ❌ 否。**真机运行态从未验过**；前情只有 `/tmp` 假库结果（3 子项进废纸篓、Original Media 保留、0 错误、不崩），见 `reports/verify_20261110/TR-008_四项核验证据.md:66-84` |
| **2. 看板高危动作确认弹窗** | `reports/verify_s2/看板高危动作_静态盘点与视觉核对表.md` | ✅ **静态盘点完成**（只读 grep）：三个动作入口 + NSAlert 精确行号 + 代码层预期。逐行 `🛡️ 隔离`（`PluginDoctorDashboardView.swift:433 → :460-471`）**无 NSAlert**；情境卡片激活（`:728-740`）**有**；一键智能自愈（`:103 → :326-352`, NSAlert `:339-345`）**有**；一键隔离破损（`:107 → :354-374`, NSAlert `:361-367`）**有**；单项搬家（`StorageMigrationDashboardView.swift:223 → :526-564`, NSAlert `:532-538` / `:550-556`）**有**。视觉核对表全部空置 | ❌ 否。**纯静态盘点，不是真机结论**，代码证据未被写成视觉确认 |
| **3. 乐观态「已恢复在线 → 部分损坏」持续多久** | `乐观态_中间态计时口径.md` + `optimistic_duration.py` | ✅ 完成：起点 = `AssetHubView.swift:3084`（乐观文案写入），终点 = `:3129`（部分损坏）/ `:3134`（校验完成）；Δ = T_END − T_START，按卷名配对、未配对不许补值。脚本支持日志 / 截图 mtime / CSV 三种输入，`--selftest` **PASS**（内置合成数据 4.25s / 2.5s，非观测值），`--print-log-command` 只打印未执行。另发现两件事：① `:3082`「已恢复在线」与 `:3128`「部分损坏」在当前源码互斥；② `:3084-3134` 全段**无 os_log/NSLog/print 埋点**，现在没有自动日志源 | ❌ 否。**未运行真机、未采任何真机时间戳、未给出任何时长数值** |
| **4. 内存占用** | `rss_t0.txt` + `rss_samples.jsonl` + `rss_sample.py` | ✅ 完成：t0 = **82016 KB / 80.09 MB** 已写盘；`report` / `sample_once --dry-run` 自检通过；`loop --interval 600 --duration 7200` 能力写好但**本轮禁用**，且强制 `--i-accept-foreground`、禁止后台 | ❌ 否。**t1 未采、2 小时对比不成立**；只观测 RSS，非泄漏检测 |

**附加产出（任务 5）**：`screen_state_20261110_1849.png` 已落地，`screencapture -x`（静默、不抢焦点、不激活任何 App）。

### 3.1 屏幕证据说明（如实，不美化）

- 文件名里的 `1849` 是**本轮批次编号**；文件 mtime = `2026-11-10 18:52:00`，截图内右上角菜单栏显示 `18:52`、`11月10日 周二`。
- 可见内容：左侧一个笔记/备忘录窗口（记录 S2/S3/S4 并行编排、两份未提交文档、FCPX 与 R2 PID 等信息），右侧 WorkBuddy 对话窗口（对话里明确写着「FCPX (PID 97387) 和 R2.app (PID 96268) 都还在跑」「只读 grep」「不碰正在跑的 FCPX / R2.app」）。
- **未见 FCPX 主窗口、未见活动监视器** —— 这是刻意的：不为了截图去前置/激活 FCPX、不抢焦点。截图为真实屏幕、非黑屏、非合成。
- 截图只作为「两进程在跑 + 本轮未触碰」的旁证，**不是任何真机验证结论**。

### 3.2 并行改动发现（重要，行号已复核）

本轮期间**其他并行代理**改了文件，S2 只做只读观察、未写这些路径：

| 文件 | mtime | git status | 影响 |
|---|---|---|---|
| `FCPXStudioNative/Sources/FCPXStudio/Views/AssetHubView.swift` | `2026-11-10 19:04:59` | `M` | 任务 3 的行号整体漂移：用户点名的 `:3084 / :3129 / :3134` 在当前 HEAD 为 **`:3109 / :3154 / :3159`**（该区间 +25；`updateStatusLine` `:3340 → :3410`，+70）。**文案逐字未变、互斥关系未变**；计时脚本按文案正则匹配，不受影响。完整对照表见 `乐观态_中间态计时口径.md §1.2` |
| `tools/bundle_standalone_runtime.sh` (19:02:12)、`tools/s3_dataset_gen.py` (18:59:40)、`FCPXStudioNative/Sources/FCPXStudio/Performance/` | 本轮期间 | `M` / `??` | 与 S2 产出无关 |

- 看板核对表涉及的 4 个 Views 文件本轮未被改动（mtime 仍为 11-08 等），行号稳定。
- 两份禁改文档 `docs/项目终审报告_20261110.md`（18:07:48）、`docs/待办清单_20261110.md`（18:31:49）mtime 未变，**未被触碰**。

---

## 4. 唯一阻塞项

> **用户需主动退出 Final Cut Pro（PID 97387）与 FCPX Studio Pro R2.app（PID 96268），之后才能跑真机验证。**

补充两条（不额外制造阻塞，只把话说死，免得后续误判）：

1. **TR-008③ 的口径冲突**：题面要验「**FCPX 运行态** trash Render Files」，而用户硬约束是「FCPX 在跑就不能动它的库」。两者同一时刻互斥 —— 退出后 FCPX 已不在运行态，该判定项就不成立。执行前需用户按 `docs/S2_TR008③_真机运行态_人工引导清单.md §0.1` 裁决口径 A（退出后验，承认运行态未覆盖）或口径 C（用户新授权 + 指定专用测试库、FCPX 由用户自己启动）。**本代理不自行解除硬约束、不自动重启 FCPX（用户永久否决）。**
2. **NSOpenPanel 必须由人手动点**，自动化驱动不了，也不允许自动化驱动。FCPX 版本号由人从「关于 Final Cut Pro」读取填写，本轮不读任何 `.app` 包、不预填。

---

## 5. 硬约束逐条自检

| 约束 | 结果 |
|---|---|
| 不动真实模板库 `~/Movies/Motion Templates.localized` | ✅ 未触碰 |
| 不动 FCPX 缓存 / Render Files | ✅ 未触碰 |
| 不启动 / 退出 / 重启任何 App | ✅ 未执行（连 `open -a` 都没用） |
| 不在 FCPX 里点任何东西 | ✅ 未点击 |
| 不调用 NSOpenPanel 选真实库 | ✅ 未调用（只写了「人怎么点」的引导） |
| 不抢 FCPX 焦点 | ✅ `screencapture -x` 静默，未前置任何 App |
| 无任何自动重启 FCPX 的功能 | ✅ 引导清单与脚本均不含 |
| 不修改任何现有文件 | ✅ `git status --short` 只显示新增 `?? reports/verify_s2/`、`?? docs/S2_TR008③_…md`；Sources/tools 的 `M`/`??` 为并行代理本轮期间产生，S2 未写 |
| 不改两份未提交文档 | ✅ mtime 未变（见 §3.2） |
| 不碰 `.app` 包 | ✅ 未读未写 |
| 不 git add / commit / push | ✅ 只跑了只读 `git status` |
| 不等 2 小时 / 不起 detach·nohup 后台进程 | ✅ `loop` 未运行；`dry-run` 未写盘 |
| 外置卷写入 < 50 MB | ✅ 2.6 MB |
| `leaks` / `footprint` 被挡 → 只观测、不宣称泄漏检测 | ✅ 如实记录 |

---

## 6. 集成方交接（怎么接着干）

```bash
cd "/Volumes/摄影师工具箱128GB/未命名文件夹/FCPX_Studio_Pro/reports/verify_s2"

# 内存：看当前状态（本轮已跑）
python3 rss_sample.py report
# 后续会话 / 用户回来后采 t1（本轮未跑）
python3 rss_sample.py sample_once --label t1
python3 rss_sample.py report

# 乐观态：脚本自检（本轮已跑）/ 后续用真机数据
python3 optimistic_duration.py --selftest
python3 optimistic_duration.py --print-log-command        # 只打印，不执行
python3 optimistic_duration.py --csv /path/to/points.csv --json
python3 optimistic_duration.py --shots /path/to/shots     # 截图 mtime 打点，秒级精度
```

真机部分：等用户主动退出两个 App → 按 `docs/S2_TR008③_真机运行态_人工引导清单.md` 与 `看板高危动作_静态盘点与视觉核对表.md` 由人执行、截图、勾选 → 另写带截图哈希的真机记录。**S2 本轮不产出该记录。**

---

## 7. 结论

**真机验证尚未执行，本轮未产出真机结论。**

本轮交付的全部是「纸面准备 + 只读观测 + 静态盘点 + 一张真实屏幕截图」：
t0 RSS 82016 KB / 80.09 MB 已写盘；四项前置工作全部就绪；唯一阻塞项是用户主动退出 FCPX 与 R2.app。
没有空转等两小时，没有把代码证据包装成视觉确认，没有把假库结果包装成真机结果。
