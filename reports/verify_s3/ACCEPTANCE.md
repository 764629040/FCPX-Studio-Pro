# S3 / P1 验收报告：虚拟滚动 + 缩略图多级异步缓存

> **本轮未接线。** 以下所有性能数字来自 `/tmp/s3_verify/s3_harness` 独立 harness 的合成负载，
> **不是真机 App 实测**。接线步骤见 `INTEGRATION.md`，由集成阶段统一执行。

---

## 0. 硬性验收结论（先看这条）

任务要求：「必须给前后同一份数据的滚动帧率或掉帧计数对比，不许只写『已优化』」。

**达成。** 同一份 1000 条 / 10000 条数据、同一段 240 帧滚动轨迹、各 5 轮冷启动复跑，
逐帧采样得到掉帧数、平均帧时、p95 帧时、视图实例数峰值等**具体数字**，
原始逐轮数据在 `results.csv`（20 行）、逐帧耗时序列在 `/tmp/s3_verify/frames_*.csv`（20 个文件，
索引见 `frames_manifest.txt`）、完整控制台输出在 `raw_console.txt`。
数字由 `tools/s3_run.sh` 一次跑出，无手工填写、无推算、无编造。

**但必须同时说明一个反向结果：1000 条场景新实现没有改善帧率，掉帧与帧时反而略高
（差异落在轮次噪声量级内）。收益只在 10000 条场景显著。见 §5 / §7。**

---

## 1. 交付物

### 1.1 新增组件（可编译、自包含、纯 Foundation）

| 文件 | 能力 |
|---|---|
| `FCPXStudioNative/Performance/S3GridLayout.swift` | 网格几何；由 `documentVisibleRect` 计算「可见 + 缓冲行」的 index 区间；列宽公式 1:1 复刻 `reloadCardGrid` |
| `.../Performance/S3ViewportReuseEngine.swift` | 视口复用：`active: [index: card]` 只留可见范围，离屏 detach 进有上限的 reusePool，进入视口优先复用；每帧布局 O(visible)，与数据总量无关 |
| `.../Performance/S3ThumbnailCache.swift` | 多级缓存：L1 内存 LRU（字节 costLimit，存**已解码**位图，主线程不再解码）／L2 磁盘 LRU（字节上限 + mtime 淘汰）／异步生成队列（`maxConcurrentGenerations` 硬上限）／in-flight 同 key 去重／离屏 cancel／deliveries 主线程 drain 后校验绑定再应用 |
| `.../Performance/S3PerformanceFacade.swift` | 一行接入门面 `S3GridPerformanceController.scrollDidChange(visibleRect:)`，把三者串起来；含完整接入注释 |

组件**不 import AppKit、不引用 `AssetHubView` / `ResourceCardView` / `TemplateItem`**，
因此 S1 同时编辑现有 Sources 文件时仍可用 `swiftc` 直编。视图层通过
`S3ReusableCard` / `S3CardHost` / `S3ThumbnailApplying` 三个协议注入（适配示例见 `INTEGRATION.md`）。

### 1.2 证据文件（本目录）

| 文件 | 内容 |
|---|---|
| `raw_console.txt` | harness 完整原始 stdout（每轮每场景全部数字） |
| `results.csv` | 20 行逐轮原始数字，40 列 |
| `results_summary.csv` | 4 行场景汇总（均值 / 样本标准差 / min / max） |
| `run_metadata.txt` | 机器、系统、编译器、磁盘、编译与运行命令、时间戳 |
| `dataset_manifest.txt` / `dataset_gen.txt` | /tmp 数据文件 SHA256 与生成输出 |
| `vsync_probe.txt` / `vsync_probe_compile.txt` / `period.txt` | CVDisplayLink 真实刷新周期探测 |
| `harness_compile.txt` | swiftc 编译输出（成功，无错误） |
| `frames_manifest.txt` | 20 个逐帧耗时 CSV 的 SHA256 索引（文件本体在 /tmp） |
| `chart_dropped_frames.png` / `chart_frame_time.png` / `chart_view_peak.png` / `chart_resources.png` | 由 `results_summary.csv` 实测数字绘制的 4 张图表 PNG，均带 `INDEPENDENT HARNESS - NOT APP MEASUREMENT` 水印 |
| `chart_gen.txt` | 图表生成输出 |
| `ACCEPTANCE.md` / `INTEGRATION.md` | 本报告 / 接入说明 |

> 没有 UI 截图：本轮未接线、未运行 App，不存在可截的界面。提供的 4 张 PNG 是**数据图表**。

---

## 2. 测量方法（可复现）

### 2.1 同一份数据

`tools/s3_dataset_gen.py` 用固定 seed `0x53335031` 生成，全部落在 `/tmp`（外置卷仅剩 ~255Mi，未写入大数据）：

| 文件 | 条数 | 大小 | SHA256 |
|---|---|---|---|
| `/tmp/s3_verify/data/dataset_1000.json` | 1000 | 258,027 B | `db1b9dff45588bf8cf7e9375d1e40279d049ee2ce99d3ec7628e193814aca664` |
| `/tmp/s3_verify/data/dataset_10000.json` | 10000 | 2,586,453 B | `011d68aed448530f9b8398a0b27e11649e74e247ad6dd4ed8cd7b54b2a3be864` |
| `/tmp/s3_verify/data/track.json` | 240 帧 | 2,685 B | `a0b8727d937597a2bef111d86bcc16b362a0d0899f48e7df87386334eb23ef63` |

每条目含 `idx/path/name/sizeMB/tier/category/enabled/offline/corrupted/symlink/thumbSeed`，
`path` 唯一，作为缩略图缓存键。两份实现**从同一文件解码出同一个 `[SyntheticItem]` 数组实例**。

### 2.2 同一段滚动轨迹

`track.json`：视口 900×760 pt，3 列（与 `S3GridLayout` 公式一致），全量内容高 833,576 pt，
`maxOffset = 832,816 pt`；240 帧 = 去程 120 帧（smoothstep easing 到底）+ 回程 120 帧（回到顶）。
两份实现逐帧使用**同一个 `offsets` 数组**（`S3HarnessData.visibleRect(at:)`）。

### 2.3 两份实现

> 现场代码的行号与结构基于本轮 S3 读取时的 `AssetHubView.swift` / `ResourceCardView.swift`
> 快照。S1 正在并行编辑这两个文件，行号可能漂移；复刻依据是**函数名与算法行为**，
> 不是固定行号。

**「现状」`LegacyGridEngine`**（`tools/s3_harness.swift`）——忠实复刻读到的现场代码：

- `renderedChunkCount` 初始 48（`AssetHubView.defaultChunkSize`），触底 `+48`，**只增不减**；
- `cardViews` 全量常驻、永不回收；每次 `reloadCardGrid` 遍历 `0..<cardViews.count`
  全量重排 frame + 比较 6 个 item 字段（对应 `AssetHubView.swift` line 1528-1547）；
- 新建卡片 = `ResourceCardView.init → setupUI()(15 子视图) → updateContent()`，
  触发 `loadThumbnailAsync()`（line 440-474）与 `calculateSizeAsync()`；
- `calculateSizeAsync` 的 `DispatchQueue.main.asyncAfter(1.5s)` 回调会再次 `updateContent()`
  从而再次触发 `loadThumbnailAsync()`（line 343-352），harness 按 90 帧延迟如实复刻；
- 缩略图单层 `NSCache` 等价物：无 `costLimit`、无磁盘层、无淘汰；
- miss 时 `DispatchQueue.global(qos:.utility).async` **无并发上限、无 in-flight 去重**，
  完成后 `DispatchQueue.main.async` 无节流回主线程。

**「新实现」`S3GridEngine`**——直接调用本轮新增的 `S3GridPerformanceController`：
`bufferRows=2`、`maxConcurrentGenerations=4`、L1 `8 MiB`、L2 `16 MiB`（目录
`/tmp/s3_verify/l2cache`）、`executionMode = .manual`（见 §7 A4）。

**公平性共用项**：同一个 `SyntheticItem` 数组、同一段 `offsets`、同一个 `SyntheticCard`
类（真实分配 15 个子视图对象）、同一个 `S3ThumbnailWorkload.render(key:)` 逐像素生成函数、
同一个 vsync 节拍、同样的 240 帧与 5 轮。缩略图生成成本两边完全同一个函数，不是给某一方
人为塞 sleep。

### 2.4 帧采样（CVDisplayLink + 等价主线程 RunLoop 节拍）

1. `tools/s3_vsync_probe.swift` 调 `CVDisplayLinkCreateWithActiveCGDisplays` +
   `CVDisplayLinkGetNominalOutputVideoRefreshPeriod`，本轮实测
   **16.666000 ms**（`timeValue=399984 / timeScale=24000000`，即 60Hz），
   作为帧预算（证据：`vsync_probe.txt`）。
2. 主 harness 用**主线程 RunLoop + `mach_absolute_time` / `mach_wait_until`** 合成
   60Hz vsync 节拍（任务允许的「等价的主线程 RunLoop 采样」）：每帧在 vsync 起点执行
   该实现的全部工作，`deadline = frameStart + 16.666ms`。
3. 指标口径：
   - **掉帧数 `dropped_frames`** = Σ `ceil(slip / period)`，`slip = 工作结束时刻 − deadline`；
     一次卡顿后把下一 `frameStart` 重新对齐到工作结束时刻，避免同一卡顿在后续帧被连锁重复计数；
   - `deadline_miss_frames` = 越过 deadline 的帧数；`over_budget_frames` = 单帧工作耗时
     `> 16.666ms` 的帧数（与墙钟 slip 独立的工作量口径）；
   - `avg_frame_ms` / `p50` / `p95` / `max` = 该轮 240 个**逐帧工作耗时**的均值/分位数/最大值；
   - `effective_fps` = `60 × frames / (frames + dropped_frames)`（按掉帧折算的等效帧率）；
   - `avg_interval_ms` = 实测墙钟总时长 / 帧数（验证节拍对齐）；
   - **视图实例数峰值** = `SyntheticCard.init/deinit` 维护的真实 Swift 对象存活计数峰值
     （不是估算）；另报 `peak_mounted_views`（挂载数）与 `final_live_views`。

### 2.5 重复次数与样本量

- 每个场景（数据集 × 实现）**独立冷启动 5 轮**：每轮清空 L2 目录、新建 engine、
  重置对象计数器、缓存全空；轮与轮之间无状态残留。
- 样本量 = 2 数据集 × 2 实现 × 5 轮 × 240 帧 = **4,800 个逐帧样本**，
  **20 个独立轮次**。汇总报均值 ± 样本标准差（n=5）与 min/max。
- 一键复现：`./tools/s3_run.sh`（默认 `S3_ROUNDS=5 S3_FRAMES=240 S3_COUNTS=1000,10000`）。

---

## 3. 环境

| 项 | 值 |
|---|---|
| 机器 | Mac15,12 / Apple M3 / 8 CPU / 16 GB RAM |
| 系统 | macOS 26.5 (25F5058e), Darwin 25.5.0, arm64 |
| 编译器 | Apple Swift 6.2.3 (swift-driver 1.127.14.1), target `arm64-apple-macosx26.0` |
| 编译 | `swiftc -O -swift-version 5`（只编 4 个 Performance 组件 + 2 个 harness 文件 → `/tmp/s3_verify/s3_harness`，**未编译整个源码树、未跑 SwiftPM build**） |
| vsync | CVDisplayLink nominal 16.666000 ms / 60 Hz |
| 磁盘 | `/tmp` 14 Gi 可用；外置卷（项目根）255 Mi 可用 |
| 绘图 | Python 3.13.12 + Pillow 13.0.0（**只画图，不参与任何测量**） |
| 运行时间 | 2026-11-10 19:13–19:15 本地，全量约 90 秒 |

---

## 4. 前后对比数字（R=5，均值 ± 样本标准差）

### 4.1 1000 条

| 指标 | 现状 Legacy | 新实现 S3 | Legacy/S3 |
|---|---|---|---|
| 掉帧数（240 帧累计） | **1.0 ± 1.0**（0–2） | **1.6 ± 1.8**（0–4） | 0.62x（新实现略差） |
| deadline miss 帧数（5 轮均值） | 1.0 | 1.2 | — |
| 单帧 > 16.666ms 的帧数（均值） | 0 | 0 | — |
| 平均帧时 | **0.2329 ± 0.0715 ms** | **0.3153 ± 0.0512 ms** | 0.74x（略差） |
| p95 帧时 | **2.1795 ms** | **2.6526 ms** | 0.82x（略差） |
| 最大单帧（5 轮范围） | 5.003–7.852 ms | 2.974–7.652 ms | — |
| 等效帧率（5 轮范围） | 59.5–60.0 fps | 59.0–60.0 fps | — |
| **视图实例数峰值** | **1000** | **24** | **41.67x** |
| 挂载视图峰值 | 1000 | 24 | 41.67x |
| **布局操作总数** | **10,080** | **1,107** | **9.11x** |
| **缩略图生成次数** | **1,000** | **92** | **10.87x** |
| 主线程缩略图应用次数 | 2,000 | 184 | 10.87x |
| 估算峰值内存 | **32.27 MiB** | **2.89 MiB** | **11.16x** |

逐轮 p50 帧时及其它字段见 `results.csv`（`p50_frame_ms` 等列）。

### 4.2 10000 条

| 指标 | 现状 Legacy | 新实现 S3 | Legacy/S3 |
|---|---|---|---|
| 掉帧数（240 帧累计） | **46.4 ± 14.3**（34–65） | **1.4 ± 1.3**（0–3） | **33.14x** |
| deadline miss 帧数（5 轮均值） | 43.0 | 0.8 | — |
| 单帧 > 16.666ms 的帧数（均值） | 40.8 | 0.6 | — |
| 平均帧时 | **6.3753 ± 1.1072 ms** | **1.9547 ± 0.2982 ms** | **3.26x** |
| p95 帧时 | **23.6329 ms** | **3.9603 ms** | **5.97x** |
| 最大单帧（5 轮范围） | 25.78–97.64 ms | 3.98–44.32 ms | — |
| 等效帧率（5 轮范围） | 47.2–52.6 fps | 59.3–60.0 fps | — |
| **视图实例数峰值** | **10,000** | **27** | **370.37x** |
| 挂载视图峰值 | 10,000 | 27 | 370.37x |
| **布局操作总数** | **1,043,328** | **5,732** | **182.02x** |
| **缩略图生成次数** | **10,000** | **488** | **20.49x** |
| 估算峰值内存 | **322.72 MiB** | **8.03 MiB** | **40.19x** |

> 上表「Legacy/S3」> 1 表示新实现数值更低（更好）。逐轮原始值见 `results.csv`。
> 10000 条现状 5 轮掉帧分别为 65 / 41 / 58 / 34 / 34；新实现为 0 / 0 / 2 / 2 / 3。

### 4.3 机制证据（10000 条，单轮实测值，逐轮见 `results.csv`）

- L1 命中 **244** 次、L2 磁盘命中 **231** 次、生成 **488** 次；
- 同 key 去重 **2,267** 次、离屏取消 **4,530** 次、主线程应用 **963** 次；
- **L1 8 MiB 上限生效**：单轮 L1 淘汰 **462** 次，`peak_l1_bytes = 8,388,480 B`（8.0 MiB）；
- **L2 淘汰本轮未触发**：`peak_l2_bytes = 15,936,128 B`（15.2 MiB）未触及 16 MiB 上限，
  `l2_evictions = 0`；跑完后 `/tmp/s3_verify/l2cache` 实为 15 MiB / 488 个文件。
  磁盘 LRU 淘汰代码路径存在，但**这段轨迹没有覆盖到**，如实记录，不宣称已验证；
- 1000 条场景 L1/L2 淘汰均为 0（生成仅 92 次，未达上限），同样如实记录；
- 视口复用：`peak_live_views` 恒为 24（1000 条）/ 27（10000 条），
  等于「(可见行 + 2×缓冲行) × 3 列」，**不随数据总量增长**。

---

## 5. 结论

1. **万级（10000 条）达成目标**：同一份数据、同一段轨迹、同样 5 轮下，
   掉帧 46.4 → 1.4、p95 帧时 23.63ms → 3.96ms、视图实例峰值 10000 → 27、
   布局操作数 1,043,328 → 5,732、缩略图生成 10000 → 488、估算内存 322.72 → 8.03 MiB。
   根因与现场代码一致：现状 `cardViews` 只增不减 + 每次 `reloadCardGrid` O(n) 全量重排；
   新实现只维护 O(visible) 个视图，并由 L1/L2 + 并发上限 + 去重 + 取消消除重复生成。
2. **千级（1000 条）未观测到帧率收益**：掉帧 1.0 → 1.6、平均帧时 0.233 → 0.315ms、
   p95 2.18 → 2.65ms，新实现反而略高。原因是该规模下现状的 O(n) 重排绝对成本还很小
   （累计 10,080 次布局操作），而新实现有 L1/L2 管理、`fileExists` 探测、磁盘写入与
   LRU 淘汰的固定开销；且两组标准差（±1.0 / ±1.8）大于均值差，差异**不具统计显著性**。
   但即便如此，千级场景的**视图数、布局操作数、生成次数、内存**仍分别改善
   41.67x / 9.11x / 10.87x / 11.16x —— 这些是结构性收益，只是尚未转化为帧率差异。
3. 因此不能笼统写「已优化」：本报告的适用结论是
   **「收益随数据规模增长；在万级模板下显著消除掉帧，在千级下主要体现为内存与工作量下降」**。

---

## 6. 是否达成「不许只写『已优化』」

**达成。** 提供了：4 项逐帧指标（掉帧数、平均帧时、p95 帧时、等效帧率）+ 视图实例数峰值
+ 布局操作数 + 缩略图生成次数 + 估算内存，全部为实测/真实对象计数，
含 5 轮逐轮值、标准差、min/max，并如实报告了千级场景的**反向结果**。
图表 4 张均由 `results_summary.csv` 读数绘制，不另造数字。

---

## 7. 适用边界与局限（必读）

| 编号 | 局限 | 影响 |
|---|---|---|
| **A1** | **本轮未接线**；数字来自独立 harness 合成负载，**非真机 App 实测**，未运行 FCPX Studio Pro，未编译整个源码树 | 不能作为 App 内实际滚动帧率的承诺；集成后必须真机复测 |
| **A2** | 为保证「同一段轨迹覆盖同一份万级数据」，把现状「用户反复滚到底 +48」压缩成每帧 `while` 追赶加载循环 | 现状在少数帧集中承担了约 209 次 `reloadCardGrid`，放大了它的峰值卡顿；真实 App 里这些加载分散在用户多次触底操作中。若不做追赶，现状根本无法在同一轨迹上到达万级数据位置（会停在已加载的几百条），两种口径都不代表真机完整体验 |
| **A3** | 用 `SyntheticCard`（15 个 Swift 子视图对象）+ `S3ThumbnailWorkload.render` 逐像素运算**模拟**卡片创建与缩略图生成/解码；不是真实 `NSView` 层级、`NSImage` 解码、CoreAnimation 提交、GPU 合成 | 帧时只反映**算法复杂度与 CPU 工作量密度**，不含 AppKit/WindowServer/GPU 成本；真机绝对帧时会不同 |
| **A4** | 为单线程确定性，缩略图后台工作用 `executionMode = .manual` 折算为**同帧等效 CPU 工作量**（每帧最多 `maxConcurrentGenerations` 个）；生产路径 `.asynchronous` 是真实 `OperationQueue` 并发 | 未测量真实多线程的 CPU 争抢、线程切换与主线程 RunLoop 回调排队；并发上限的收益以「每帧完成数」量化，不是真实并行吞吐 |
| **A5** | vsync 用 `CVDisplayLink` **仅探测周期**（16.666ms），节拍由主线程 RunLoop + `mach_wait_until` 合成；未用 CVDisplayLink 回调驱动帧 | 掉帧是「帧预算模型」下的 deadline miss，不是屏幕实际未提交的帧；无真实 vsync 相位抖动 |
| **A6** | 千级场景新实现帧率/帧时略差（§5.2） | 小规模下不要宣称帧率提升 |
| **A7** | 「估算峰值内存」= 缓存实际字节 + 卡片对象数 × **估算常数 1200 B/张**；缓存字节为实测，卡片字节为估算，非 Instruments / malloc 实测 | 内存数字只作数量级对比，不作精确承诺 |
| **A8** | L2 存 RGBA 原始位图字节（120×68×4 = 32,640 B/张），不是压缩 PNG/JPEG；磁盘 LRU 上限 16 MiB，但**本轮轨迹峰值仅 15.2 MiB，`l2_evictions = 0`，淘汰路径未被实测覆盖**（见 §4.3） | 生产接入换压缩编码后，磁盘命中率与 I/O 成本会变化；L2 淘汰分支需另造数据复测 |
| **A9** | 单机（M3 / macOS 26.5）、单编译器、单 seed、单条轨迹、单视口尺寸（900×760 / 3 列） | 未覆盖窄窗 1 列、Retina 缩放、不同刷新率（ProMotion 120Hz）、不同磁盘（外置卷 vs 内置 SSD）、不同机器 |
| **A10** | 每轮冷启动（缓存全空）；未测热缓存、未测快速反复来回滚动、未测筛选/排序后 `updateData` 重建 | 热缓存下新实现可能更好；数据重建路径未量化 |

---

## 8. 原始证据索引

- 完整原始输出：`raw_console.txt`
- 逐轮 40 列原始数字：`results.csv`（20 行数据 + 表头）
- 场景汇总：`results_summary.csv`
- 逐帧耗时序列（240 行/文件 × 20）：`/tmp/s3_verify/frames_<dataset>_<impl>_r<round>.csv`，
  SHA256 索引见 `frames_manifest.txt`
- 数据文件：`/tmp/s3_verify/data/*.json`，SHA256 见 `dataset_manifest.txt`
- L2 磁盘缓存产物：`/tmp/s3_verify/l2cache/`（最后一轮残留，约 15 MiB / 488 文件）
- 编译产物：`/tmp/s3_verify/s3_harness`、`/tmp/s3_verify/s3_vsync_probe`
- 编译/运行命令：`run_metadata.txt`、`tools/s3_run.sh`

---

## 9. 未做到项（如实列出）

1. **真机 App 实测未做** —— 本轮未接线，且受隔离约束禁止编译整个源码树；见 `INTEGRATION.md`。
2. **UI 截图未提供** —— 没有运行中的 App 界面可截；4 张 PNG 是数据图表，不是界面截图。
3. **CVDisplayLink 回调驱动帧未做** —— 只用其周期校准，节拍由主线程 RunLoop 合成（§2.4 / A5）。
4. **跨机型 / 跨刷新率 / 热缓存 / 数据重建场景未测**（A9 / A10）。
5. **1000 条场景未达成帧率改善**，且该差异不具统计显著性（§5.2 / A6）。
6. **内存为估算**（A7）。
7. **L2 磁盘淘汰路径未被本轮轨迹触发**（`l2_evictions = 0`），该分支未获实测验证（§4.3 / A8）。
