# S3 / P1 集成阶段接线说明

> ## ⚠️ 本轮未接线
> **本轮 S3 零修改 `Sources/` 下任何现有文件**，`AssetHubView.swift` / `ResourceCardView.swift`
> 一个字都没动（S1 正在同时编辑这两个文件）。
> **`ACCEPTANCE.md` 里的所有性能数字来自 `/tmp` 上的独立 harness 合成负载，
> 非真机 App 实测。** 集成阶段完成接线后必须重新做真机滚动测量，
> 本轮数字不得当作 App 内帧率承诺。

---

## 0. 本轮已有的文件（不需要再写）

```
FCPXStudioNative/Sources/FCPXStudio/Performance/
  S3GridLayout.swift              几何 / 可见 index 区间
  S3ViewportReuseEngine.swift     视口复用 + reusePool
  S3ThumbnailCache.swift          L1 内存 LRU / L2 磁盘 LRU / 并发上限 / 去重 / 取消
  S3PerformanceFacade.swift       一行门面 S3GridPerformanceController
```

这 4 个文件是纯 Foundation，**不含 AppKit 依赖**，因此独立 harness 可以用
`swiftc` 直编而不牵连 S1 正在编辑的半成品。

---

## 1. 前置：集成阶段需要新增一个 AppKit 适配文件

**本轮故意没有把适配文件放进 `Performance/`**：一旦 `Performance/*.swift` 里出现
`import AppKit`，harness 的 `swiftc` 直编就要连带链接 AppKit / 触发 `NSView` 的
`@MainActor` 隔离检查，破坏「harness 自包含」这条硬约束。

集成阶段请新增
`FCPXStudioNative/Sources/FCPXStudio/Performance/S3AppKitAdapters.swift`
（**新增文件，不改任何现有文件**），内容如下（示意代码，按实际 `TemplateItem` 字段微调）：

```swift
import AppKit
import Foundation
import ImageIO

// 包装 ResourceCardView，避免为了接线去改 S1 正在编辑的 ResourceCardView.swift
public final class S3ResourceCardBox: S3ReusableCard {
    public let view: ResourceCardView
    private let binder: (Int) -> TemplateItem?

    public var s3_boundIndex: Int?
    public var s3_boundIdentifier: String?
    public var s3_frame: S3Rect {
        get {
            let f = view.frame
            return S3Rect(x: f.minX, y: f.minY, width: f.width, height: f.height)
        }
        set {
            view.frame = NSRect(x: newValue.x, y: newValue.y,
                                width: newValue.width, height: newValue.height)
        }
    }

    public init(view: ResourceCardView, binder: @escaping (Int) -> TemplateItem?) {
        self.view = view
        self.binder = binder
    }

    public func s3_prepareForReuse() {
        view.thumbnailImageView.image = nil
        view.thumbnailImageView.contentTintColor = nil
    }

    public func s3_bind(index: Int, identifier: String) {
        guard let item = binder(index) else { return }
        view.item = item          // didSet -> updateContent()
    }
}

public final class S3GridHostAdapter: S3CardHost {
    private let container: NSView
    private let make: () -> S3ReusableCard
    public init(container: NSView, make: @escaping () -> S3ReusableCard) {
        self.container = container; self.make = make
    }
    public func s3_makeCard() -> S3ReusableCard { make() }
    public func s3_attach(_ card: S3ReusableCard) {
        (card as? S3ResourceCardBox).map { container.addSubview($0.view) }
    }
    public func s3_detach(_ card: S3ReusableCard) {
        (card as? S3ResourceCardBox)?.view.removeFromSuperview()
    }
}

public final class S3ThumbApplyAdapter: S3ThumbnailApplying {
    public weak var engine: S3ViewportReuseEngine?
    public func s3_shouldApply(at index: Int, identifier: String) -> Bool {
        guard let box = engine?.card(for: index) as? S3ResourceCardBox else { return false }
        return box.s3_boundIndex == index && box.s3_boundIdentifier == identifier
    }
    public func s3_applyThumbnail(_ bitmap: S3DecodedBitmap,
                                  at index: Int, identifier: String) {
        guard let box = engine?.card(for: index) as? S3ResourceCardBox else { return }
        // bitmap 是后台**已解码** RGBA，主线程只做一次赋值，不在主线程解码
        var px = bitmap.pixels
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &px, width: bitmap.width, height: bitmap.height,
                                  bitsPerComponent: 8, bytesPerRow: bitmap.width * 4,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cg = ctx.makeImage() else { return }
        box.view.thumbnailImageView.image =
            NSImage(cgImage: cg, size: NSSize(width: bitmap.width, height: bitmap.height))
    }
}
```

> `generator` 在后台线程把 `CGImage` 转成 `S3DecodedBitmap(width:height:pixels:)`，
> 生产接入时按实际缩略图来源（模板包内图片 / 占位渐变）实现；
> 返回 `nil` 表示走占位图。L1/L2/去重/取消逻辑在组件内部，无需适配层关心。

---

## 2. 步骤 1：AssetHubView 增加属性

在 `AssetHubView` 类体内（`cardViews` 声明附近，约 line 170-173 区域）加：

```swift
private var s3Performance: S3GridPerformanceController?
private var s3HostAdapter: S3GridHostAdapter?
private var s3ThumbApplyAdapter: S3ThumbApplyAdapter?
```

---

## 3. 步骤 2：初始化（一次）

位置：`setupUI()` 中 `cardGridScrollView` 创建并挂好 `cardGridContentView`、
`NotificationCenter.addObserver(... onCardGridDidScroll ...)` **之后**（约 line 1008 之后）。

```swift
var cfg = S3ThumbnailCache.Config()
cfg.mode = .asynchronous                       // 生产路径：真实 OperationQueue 并发
cfg.memoryCostLimit = 8 * 1024 * 1024          // L1 8 MiB
cfg.diskByteLimit = 64 * 1024 * 1024           // L2 64 MiB
cfg.maxConcurrentGenerations = 4               // 并发上限
cfg.diskDirectory = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("FCPXStudioPro/S3ThumbCache", isDirectory: true)

let apply = S3ThumbApplyAdapter()
let host = S3GridHostAdapter(container: cardGridContentView) { [weak self] in
    guard let self else { return S3ResourceCardBox(view: ResourceCardView(item: TemplateItem()),
                                                  binder: { _ in nil }) }
    let item = self.plugins.first ?? TemplateItem()
    let card = ResourceCardView(item: item, frame: .zero)
    return S3ResourceCardBox(view: card) { [weak self] idx in
        guard let self, idx >= 0, idx < self.plugins.count else { return nil }
        return self.plugins[idx]
    }
}
let controller = S3GridPerformanceController(
    host: host,
    viewportWidth: cardGridScrollView.contentView.bounds.width,
    viewportHeight: cardGridScrollView.bounds.height,
    config: cfg,
    generator: { key in
        // 后台：读盘 + 解码 + 缩放，返回已解码 RGBA；失败返回 nil 走占位
        S3ProductionThumbnailBridge.decode(path: key.path, targetWidth: key.pixelWidth)
    },
    applyTarget: apply,
    bufferRows: 2)
apply.engine = controller.engine
s3Performance = controller
s3HostAdapter = host
s3ThumbApplyAdapter = apply
```

> `TemplateItem()` / `S3ProductionThumbnailBridge` 为占位写法，集成时替换为项目真实构造与缩略图读取函数。
> 初始化后不要在 `setupUI` 里立即 `scrollDidChange`，首帧由 `onCardGridDidScroll` / 首次
> `updateData` 后的布局刷新触发即可。

---

## 4. 步骤 3：数据变更后同步（筛选 / 排序 / 扫描完成 / reloadCardGrid 末尾）

在 `reloadCardGrid()` 里 `plugins` 确定之后（或每次 `plugins` 被重新赋值之后）调用：

```swift
s3Performance?.updateData(itemCount: plugins.count) { [weak self] idx in
    self?.plugins[idx].targetPath ?? ""
}
cardGridContentView.frame = NSRect(
    x: 0, y: 0,
    width: cardGridContentView.frame.width,
    height: s3Performance?.layout.contentHeight ?? cardGridContentView.frame.height)
```

`layout.contentHeight` 按**全量** `plugins.count` 计算，滚动条一次到位，
不再需要「加载更多」分页。视口宽度变化（`viewDidLayout` / 窗口 resize）时把
`viewportWidth` / `viewportHeight` 一并传进 `updateData(...)`。

---

## 5. 步骤 4：**确切要加的那一行**

**文件**：`FCPXStudioNative/Sources/FCPXStudio/Views/AssetHubView.swift`
**函数**：`@objc private func onCardGridDidScroll(_ notification: Notification)`（当前约 line 1697）
**位置**：函数体**首行**（现有 `guard renderedChunkCount < plugins.count else { return }` 之前）

> 行号按本轮 S3 读取时的快照；S1 正在并行编辑 `AssetHubView.swift`，
> **以函数名为准**，行号以集成时实际文件为准。

```swift
s3Performance?.scrollDidChange(visibleRect: cardGridScrollView.contentView.documentVisibleRect)
```

加完这一行后，该函数应等价于：

```swift
@objc private func onCardGridDidScroll(_ notification: Notification) {
    s3Performance?.scrollDidChange(visibleRect: cardGridScrollView.contentView.documentVisibleRect)
    // ↓↓↓ 以下为现状分页逻辑，集成阶段停用（见步骤 5）
    // guard renderedChunkCount < plugins.count else { return }
    // ...
}
```

这一行完成：可见区间计算 → 离屏卡片回收/复用 → 新进入卡片的缩略图请求（L1/L2/生成）→
离屏请求取消 → 主线程 drain 并校验绑定后贴图。**每帧只处理 O(visible) 个视图。**

---

## 6. 步骤 5：停用现状分页与全量重排逻辑

以下现状代码保持文件存在但不参与网格渲染（集成阶段决定删除或注释，S3 本轮一律未动）：

- `reloadCardGrid()` 里 `cardViews` 的创建/全量重排/追加（line 1527-1580）由
  `S3ViewportReuseEngine` 接管；`cardViews` 数组可保留供其它函数读取，但不再由它驱动网格；
- `loadNextCardChunk()` / `loadAllCards()` / `onLoadMoreClicked()` / `onLoadAllClicked()`
  与底部 `loadMoreFooterView` 在虚拟滚动下不再需要（内容高度按全量计算，无需触底追加）；
- `onCardGridDidScroll` 里 `if visibleRect.maxY >= contentHeight - 160 { loadNextCardChunk() }`
  必须停用，否则会与复用引擎重复加载；
- `ResourceCardView.thumbnailCache`（单层 `NSCache`）与 `loadThumbnailAsync()` 的
  全局队列生成路径，改由 `S3ThumbnailCache` 的 `generator` 提供；
  现有 `AssetHubView.swift:1870-1871` 的 `thumbnailCache.removeObject(forKey:)` 失效调用
  需改为 `s3Performance?.didReceiveMemoryWarning()` 或新增的 `invalidate(key:)`。

> 注意 `AssetHubView.swift:1805 / 2038 / 2083 / 2962 / 3067 / 3122` 等处仍在遍历
> `cardViews` 做批量操作（选中、启用/禁用、刷新）。集成阶段必须把这些遍历改成
> 遍历 `plugins` 数据源 + 调用 `s3Performance?.engine.invalidateAll()` 触发可见卡片重绑定，
> 否则 `cardViews` 只剩 24~27 个时批量操作会漏掉不可见条目。**这是接线时最容易踩的坑。**

---

## 7. 步骤 6：内存告警

在 App 的 `didReceiveMemoryWarning` / 对应通知里加：

```swift
s3Performance?.didReceiveMemoryWarning()
```

L2 磁盘层保留，L1 与在途请求清空。

---

## 8. 配置建议（生产）

| 配置 | harness 取值 | 生产建议 | 说明 |
|---|---|---|---|
| `bufferRows` | 2 | 1–2 | 上下预取行数，越大越抗快速滚动、视图数越多 |
| `maxPoolSize` | 64 | 32–64 | reusePool 上限，超出即释放 |
| `memoryCostLimit` | 8 MiB | 16–32 MiB | L1 存已解码 RGBA（32,640 B/张 @120×68） |
| `diskByteLimit` | 16 MiB | 64–128 MiB | L2 按 mtime LRU 淘汰 |
| `maxConcurrentGenerations` | 4 | 2–4 | 避免解码任务挤占主线程/磁盘 |
| `mode` | `.manual`（harness 确定性） | **`.asynchronous`** | 生产必须异步 |

---

## 9. 集成后必须做的验证（本轮未做）

1. 用 `swift build -c release --build-path /tmp/fcpx_wd` 完整编译（**本轮禁止跑**），
   确认 `Performance/*.swift` 与 S1 改动后的 `AssetHubView.swift` / `ResourceCardView.swift` 无冲突。
2. 真机 App 用 **同一份 1000 / 10000 条数据**跑 `Quartz Debug` / `Instruments Core Animation`
   或本项目既有帧率 harness，复测掉帧数与 p95 帧时；本轮数字**不能**替代。
3. 检查 §6 提到的所有 `for card in cardViews` 批量操作路径是否漏改。
4. 检查快速来回滚动时缩略图不错位（`S3ThumbApplyAdapter.s3_shouldApply` 的绑定校验）。
5. 检查窄窗 1 列 / 4 列、窗口 resize 后 `updateData` 是否重算布局。
6. 检查 L2 目录在多次启动后的淘汰与清理。

---

## 10. 隔离约束复核

- 本轮**零修改** `Sources/` 下任何现有文件；只新增 `Performance/*.swift`、`tools/s3_*`、`reports/verify_s3/*`。
- 未编译整个源码树，未跑 SwiftPM build，未覆盖 `/tmp/fcpx_wd`。
- 未碰 `.app` 包、真实模板库、`docs/`、`tools/` 既有文件。
- 未 `git add` / `commit` / `push`。
- 合成数据与 L2 缓存全部在 `/tmp`；外置卷新增内容合计 **< 0.5 MB**
  （`reports/verify_s3/` 264 KB + `Performance/*.swift` 与 `tools/s3_*` 约 75 KB），
  远低于 50 MB 上限。
