# 任务 12 审计：卡片虚拟滚动 + 缩略图多级异步缓存（只读复核，未改源码）

**日期**：2026-11-12　**范围**：`AssetHubView.swift`、`ResourceCardView.swift`、`AssetCacheManager.swift`、`core/thumbnail.py`
**规模基线**：全库扫描 1241 个可用模板（`reports/verify_moti_damage/全库扫描_修复后.txt`），非万级；缺口按千级卡片评估。

## 1. 现状：已有机制（勿重复造）

### 1.1 卡片分块渲染 + 就地复用（`AssetHubView.swift`）

- 初始块 `defaultChunkSize = 48`（`:1522-1523`）；`reloadCardGrid` 只渲染 `countToRender = min(renderedChunkCount, items.count)`（`:1549`）。
- 滚动到底部 160pt 内自动加载下一块：`onCardGridDidScroll`（`:1733-1740`）；另有「加载更多」按钮 `loadNextCardChunk`（`:1721`）与 `loadAllCards`（`:1727`）。
- 卡片就地复用：步骤 2 对已有 `cardViews` 重排 frame、仅在条目标识变化时刷新 `card.item`（`:1567-1578`）；超出所需才 `removeFromSuperview` 并裁剪数组（`:1559-1563`）；不足才 `new ResourceCardView`（`:1581-1615`）。
- 体积后台异步计算：`calculateSizeAsync` 回写 `sizeMB`（`:1608-1613`）。

### 1.2 缩略图：内存缓存 + 后台异步解码（`ResourceCardView.swift`）

- 内存缓存 `static thumbnailCache = NSCache<NSString, NSImage>()`（`:17`）；命中 0ms 直取（`:452-456`）。
- 未命中走 `DispatchQueue.global(qos: .utility).async` 后台探测解码，回主线程赋值，带失效守卫 `item.targetPath == targetPath`、离线/损坏态不贴图（`:459-477`）。
- 取图候选 `large/small/thumbnail/preview.png|jpg`，包内兜底第一张图（`:494-524`）；无图回退 `film` 占位符号（`:472-474`）。
- `AssetCacheManager` 已有模板 / LUT / 音频 / 资源库 / 医生报告多级内存字典缓存（`:21-25`）。

## 2. 真实缺口（按严重度）

| # | 缺口 | 证据 | 影响 |
|---|---|---|---|
| G1 | **卡片无离屏回收**：滚动遍历全部后，`cardViews` 持有所有已实例化 `ResourceCardView`，离屏卡片不被释放；现有裁剪只在 `countToRender` 缩小时发生。 | `:1559-1563` 仅按数量裁剪；无按可视区回收的池化/复用队列 | 千级卡片滚到底后实例数≈全量，卡片视图对象常驻 |
| G2 | **缩略图不按视口降采样**：后台直接 `NSImage(contentsOfFile:)` 解码原图即入缓存，未按卡片 210×~118 槽位缩放；`large.png` 全分辨率位图常驻内存。 | `:509` / `:518` 直接解码；无 `resizing` 到槽位 | 内存占用随大图原始分辨率放大；与 `core/thumbnail.py` 两档缩略图（长边等比）未在 Swift 侧衔接 |
| G3 | **内存缓存未设上限**：`thumbnailCache` 未设 `totalCostLimit` / `countLimit`；对照 `InfiniteCanvasView.swift:123-124` 已设 200MB / 40 条。 | 本文件全仓检索无 cost/count 限制 | 高压下无系统回收预算上限，极端情况内存不可控 |
| G4 | **无磁盘级缩略图缓存**：重启后全部重新解码；`NSCache` 纯内存。 | 无 `writeFile` / 缓存目录 / 持久化键 | 冷启动每张图重新 I/O 解码 |

## 3. 可选收口口径（需拍板，未自行开工）

- **方案 A（增量、低风险，沿用现有分块）**：给 `thumbnailCache` 补 `countLimit` / `totalCostLimit`（对齐画布缓存口径）；后台解码后按卡片槽位长边等比降采样再入缓存。不改视图结构。
- **方案 B（结构改造，大改）**：把平铺 `cardViews` 换成 `NSCollectionView` + 复用队列，真正按可视区回收（治 G1）；工作量集中在 `AssetHubView` 网格布局与卡片数据源，属结构性重写，需单独排期与回归。
- **方案 C（磁盘缓存）**：在 `AssetCacheManager` 或专用目录落第二档缩略图缓存，命中跳过解码；涉及缓存目录清理策略与版本失效口径。

> 红线约束不变：0 联网、0 模型权重；文字层位图；不自动重启 FCPX。方案 B 触及 4133 行视图，须先确认再动。

## 4. 本轮未做

- 未改任何 `.swift`；未启动 App；未跑千级压测（真机规模与掉帧需运行态观测）。
- 缺一项真机度量：当前没有千级卡片滚动的 FPS / RSS 基线，G1 是否真掉帧需运行态采样后再定是否上方案 B。
