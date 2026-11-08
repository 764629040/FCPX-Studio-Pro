import AppKit
import Foundation

// ═══════════════════════════════════════════════════════════════
//  ResourceCardView —— 对标嘉星 FxXuResourceCardView 的现代化高质感卡片
//  视觉特性：
//    1. 暗色石墨圆角卡片 (#1a1b1f)，悬停外发光边框 (#3e64ff)；
//    2. 16:9 高清缩略图视口（自动加载模板包内图片或优雅矢量渐变占位）；
//    3. 中文友好别名（主标题）+ 英文原始标识（副标题）+ 容量胶囊徽章；
//    4. 三级归属徽章（🟡 内置 / 🟢 用户 / 🟣 系统）；
//    5. 精致「🟢 开启 / ⚪️ 禁用」胶囊 Toggle 开关 + 「⋯」操作菜单。
// ═══════════════════════════════════════════════════════════════

public final class ResourceCardView: NSView {

    // MARK: – R49 缩略图高速内存缓存
    public static let thumbnailCache = NSCache<NSString, NSImage>()

    public var item: TemplateItem {
        didSet {
            updateContent()
        }
    }

    public var onToggle: ((TemplateItem) -> Void)?
    public var onActionMenu: ((TemplateItem, NSView) -> Void)?
    public var onRequestContextMenu: ((TemplateItem, NSEvent) -> NSMenu?)?

    // MARK: – Subviews
    public private(set) var thumbnailContainer: NSView!
    public private(set) var thumbnailImageView: NSImageView!
    public private(set) var categoryIconLabel: NSTextField!
    public private(set) var titleLabel: NSTextField!
    public private(set) var subtitleLabel: NSTextField!
    public private(set) var tierBadgeLabel: NSTextField!
    public private(set) var subCategoryBadgeLabel: NSTextField!
    public private(set) var disabledBadgeLabel: NSTextField!
    public private(set) var offlineBadgeLabel: NSTextField!
    public private(set) var sizeBadgeLabel: NSTextField!
    public private(set) var toggleButton: NSButton!
    public private(set) var menuButton: NSButton!

    private var trackingArea: NSTrackingArea?

    // MARK: – Init
    public init(item: TemplateItem, frame: NSRect = NSRect(x: 0, y: 0, width: 230, height: 250)) {
        self.item = item
        super.init(frame: frame)
        wantsLayer = true
        setupUI()
        updateContent()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: – UI Layout
    private func setupUI() {
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.14, alpha: 1.0).cgColor
        layer?.borderWidth = 1.0
        layer?.borderColor = NSColor(calibratedWhite: 0.20, alpha: 1.0).cgColor

        // 1. 16:9 缩略图视口容器 (width: bounds.width - 16, height: ~120)
        let thumbW = bounds.width - 16
        let thumbH = round(thumbW * 9.0 / 16.0)
        let thumbY = bounds.height - 8 - thumbH

        thumbnailContainer = NSView(frame: NSRect(x: 8, y: thumbY, width: thumbW, height: thumbH))
        thumbnailContainer.wantsLayer = true
        thumbnailContainer.layer?.cornerRadius = 6
        thumbnailContainer.layer?.masksToBounds = true
        thumbnailContainer.layer?.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.11, alpha: 1.0).cgColor
        addSubview(thumbnailContainer)

        thumbnailImageView = NSImageView(frame: thumbnailContainer.bounds)
        thumbnailImageView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailImageView.autoresizingMask = [.width, .height]
        thumbnailContainer.addSubview(thumbnailImageView)

        categoryIconLabel = NSTextField(labelWithString: "")
        categoryIconLabel.font = .systemFont(ofSize: 12)
        categoryIconLabel.alignment = .center
        categoryIconLabel.frame = .zero
        categoryIconLabel.isHidden = true
        thumbnailContainer.addSubview(categoryIconLabel)

        // 2. 归属标签悬浮在缩略图左上角
        tierBadgeLabel = NSTextField(labelWithString: "🟢 用户")
        tierBadgeLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        tierBadgeLabel.textColor = .white
        tierBadgeLabel.wantsLayer = true
        tierBadgeLabel.layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 0.85).cgColor
        tierBadgeLabel.layer?.cornerRadius = 4
        tierBadgeLabel.layer?.masksToBounds = true
        tierBadgeLabel.alignment = .center
        tierBadgeLabel.frame = NSRect(x: 4, y: thumbH - 22, width: 56, height: 18)
        thumbnailContainer.addSubview(tierBadgeLabel)

        // 2a. 子分类标签悬浮在缩略图左下角 (R48)
        subCategoryBadgeLabel = NSTextField(labelWithString: "")
        subCategoryBadgeLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        subCategoryBadgeLabel.textColor = NSColor(calibratedWhite: 0.92, alpha: 1.0)
        subCategoryBadgeLabel.wantsLayer = true
        subCategoryBadgeLabel.layer?.backgroundColor = NSColor(calibratedRed: 0.12, green: 0.22, blue: 0.38, alpha: 0.85).cgColor
        subCategoryBadgeLabel.layer?.borderColor = NSColor(calibratedRed: 0.28, green: 0.48, blue: 0.78, alpha: 0.7).cgColor
        subCategoryBadgeLabel.layer?.borderWidth = 0.5
        subCategoryBadgeLabel.layer?.cornerRadius = 4
        subCategoryBadgeLabel.layer?.masksToBounds = true
        subCategoryBadgeLabel.alignment = .center
        subCategoryBadgeLabel.frame = NSRect(x: 4, y: 4, width: 70, height: 18)
        subCategoryBadgeLabel.isHidden = true
        thumbnailContainer.addSubview(subCategoryBadgeLabel)

        // 2b. 停用状态徽章（.disabled 状态感知）悬浮在缩略图右上角
        disabledBadgeLabel = NSTextField(labelWithString: "⚪️ 已停用")
        disabledBadgeLabel.font = .systemFont(ofSize: 10, weight: .bold)
        disabledBadgeLabel.textColor = NSColor(calibratedWhite: 0.95, alpha: 1.0)
        disabledBadgeLabel.wantsLayer = true
        disabledBadgeLabel.layer?.backgroundColor = NSColor(calibratedRed: 0.45, green: 0.16, blue: 0.16, alpha: 0.90).cgColor
        disabledBadgeLabel.layer?.cornerRadius = 4
        disabledBadgeLabel.layer?.masksToBounds = true
        disabledBadgeLabel.alignment = .center
        disabledBadgeLabel.frame = NSRect(x: thumbW - 68, y: thumbH - 22, width: 64, height: 18)
        disabledBadgeLabel.isHidden = true
        thumbnailContainer.addSubview(disabledBadgeLabel)

        // 2c. 离线状态徽章（磁盘断链）悬浮在缩略图右上角
        offlineBadgeLabel = NSTextField(labelWithString: "⚠️ 磁盘离线")
        offlineBadgeLabel.font = .systemFont(ofSize: 10, weight: .bold)
        offlineBadgeLabel.textColor = NSColor(calibratedRed: 0.20, green: 0.14, blue: 0.02, alpha: 1.0)
        offlineBadgeLabel.wantsLayer = true
        offlineBadgeLabel.layer?.backgroundColor = NSColor(calibratedRed: 0.98, green: 0.78, blue: 0.16, alpha: 0.95).cgColor
        offlineBadgeLabel.layer?.cornerRadius = 4
        offlineBadgeLabel.layer?.masksToBounds = true
        offlineBadgeLabel.alignment = .center
        offlineBadgeLabel.frame = NSRect(x: thumbW - 84, y: thumbH - 22, width: 80, height: 18)
        offlineBadgeLabel.isHidden = true
        thumbnailContainer.addSubview(offlineBadgeLabel)

        // 3. 容量标签悬浮在缩略图右下角
        sizeBadgeLabel = NSTextField(labelWithString: "0 MB")
        sizeBadgeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        sizeBadgeLabel.textColor = NSColor(calibratedWhite: 0.85, alpha: 1.0)
        sizeBadgeLabel.wantsLayer = true
        sizeBadgeLabel.layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 0.85).cgColor
        sizeBadgeLabel.layer?.cornerRadius = 4
        sizeBadgeLabel.layer?.masksToBounds = true
        sizeBadgeLabel.alignment = .center
        sizeBadgeLabel.frame = NSRect(x: thumbW - 64, y: 4, width: 60, height: 18)
        thumbnailContainer.addSubview(sizeBadgeLabel)

        // 4. 主标题区（中文别名或原名）
        let infoY = thumbY - 8
        titleLabel = NSTextField(labelWithString: item.name)
        titleLabel.font = .systemFont(ofSize: 13, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.cell?.lineBreakMode = .byTruncatingTail
        titleLabel.frame = NSRect(x: 10, y: infoY - 20, width: bounds.width - 20, height: 20)
        addSubview(titleLabel)

        // 5. 副标题区（英文原名或路径特征）
        subtitleLabel = NSTextField(labelWithString: item.name)
        subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = NSColor(calibratedWhite: 0.60, alpha: 1.0)
        subtitleLabel.cell?.lineBreakMode = .byTruncatingTail
        subtitleLabel.frame = NSRect(x: 10, y: infoY - 40, width: bounds.width - 20, height: 18)
        addSubview(subtitleLabel)

        // 6. 底部操作区：精致胶囊 Toggle 开关 + 「⋯」更多菜单
        let bottomY: CGFloat = 8
        toggleButton = NSButton(title: "🟢 开启", target: self, action: #selector(onToggleClicked))
        toggleButton.bezelStyle = .regularSquare
        toggleButton.isBordered = false
        toggleButton.wantsLayer = true
        toggleButton.layer?.cornerRadius = 14
        toggleButton.layer?.masksToBounds = true
        toggleButton.layer?.borderWidth = 1.0
        toggleButton.font = .systemFont(ofSize: 11, weight: .medium)
        toggleButton.frame = NSRect(x: 10, y: bottomY, width: 88, height: 28)
        addSubview(toggleButton)

        menuButton = NSButton(title: "⋯", target: self, action: #selector(onMenuClicked))
        menuButton.bezelStyle = .regularSquare
        menuButton.isBordered = false
        menuButton.wantsLayer = true
        menuButton.layer?.cornerRadius = 14
        menuButton.layer?.masksToBounds = true
        menuButton.layer?.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 1.0).cgColor
        menuButton.layer?.borderWidth = 1.0
        menuButton.layer?.borderColor = NSColor(calibratedWhite: 0.25, alpha: 1.0).cgColor
        menuButton.font = .systemFont(ofSize: 15, weight: .bold)
        menuButton.frame = NSRect(x: bounds.width - 42, y: bottomY, width: 32, height: 28)
        addSubview(menuButton)
    }

    // MARK: – Update Content
    public func updateContent() {
        let localizedAlias = TemplateRenameManager.shared.getDisplayName(for: item)
        titleLabel.stringValue = localizedAlias

        let catClean = item.category.replacingOccurrences(of: ".localized", with: "")
        if localizedAlias != item.name {
            subtitleLabel.stringValue = item.subCategory.isEmpty ? item.name : "\(item.subCategory) · \(item.name)"
            subtitleLabel.isHidden = false
        } else {
            subtitleLabel.stringValue = item.subCategory.isEmpty ? catClean : "\(item.subCategory) · \(catClean)"
        }

        tierBadgeLabel.stringValue = item.tier.badgeText

        if !item.subCategory.isEmpty {
            subCategoryBadgeLabel.stringValue = item.subCategory
            subCategoryBadgeLabel.isHidden = false
            let fit = subCategoryBadgeLabel.sizeThatFits(NSSize(width: 140, height: 18))
            let w = max(36, min(100, fit.width + 10))
            subCategoryBadgeLabel.frame = NSRect(x: 4, y: 4, width: w, height: 18)
        } else {
            subCategoryBadgeLabel.isHidden = true
        }

        if item.isOffline {
            self.alphaValue = 0.55
            offlineBadgeLabel.isHidden = false
            disabledBadgeLabel.isHidden = true
            thumbnailContainer.alphaValue = 0.50
            titleLabel.textColor = NSColor(calibratedWhite: 0.65, alpha: 1.0)
            toggleButton.isEnabled = false
            menuButton.isEnabled = false
        } else {
            self.alphaValue = 1.0
            offlineBadgeLabel.isHidden = true
            disabledBadgeLabel.isHidden = item.isEnabled
            thumbnailContainer.alphaValue = item.isEnabled ? 1.0 : 0.50
            titleLabel.textColor = item.isEnabled ? .white : NSColor(calibratedWhite: 0.60, alpha: 1.0)
            toggleButton.isEnabled = true
            menuButton.isEnabled = true
        }

        if item.isSymlink {
            sizeBadgeLabel.stringValue = "软链接"
        } else if item.sizeMB > 0 {
            sizeBadgeLabel.stringValue = String(format: "%.1f MB", item.sizeMB)
        } else {
            sizeBadgeLabel.stringValue = "计算中…"
        }

        updateToggleAppearance()
        if !item.isOffline {
            loadThumbnailAsync()
        } else {
            let fallback = NSImage(systemSymbolName: "externaldrive.badge.xmark", accessibilityDescription: nil) ?? NSImage(systemSymbolName: "film", accessibilityDescription: nil)
            thumbnailImageView.image = fallback
            thumbnailImageView.contentTintColor = NSColor(calibratedWhite: 0.45, alpha: 1.0)
        }
    }

    public func updateToggleAppearance() {
        if item.isOffline {
            toggleButton.title = "⚠️ 离线"
            toggleButton.layer?.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 0.6).cgColor
            toggleButton.layer?.borderColor = NSColor(calibratedWhite: 0.28, alpha: 0.6).cgColor
            toggleButton.isEnabled = false
        } else if item.isEnabled {
            toggleButton.title = "🟢 开启"
            toggleButton.layer?.backgroundColor = NSColor(calibratedRed: 0.12, green: 0.32, blue: 0.18, alpha: 0.9).cgColor
            toggleButton.layer?.borderColor = NSColor(calibratedRed: 0.25, green: 0.65, blue: 0.35, alpha: 1.0).cgColor
            toggleButton.isEnabled = true
        } else {
            toggleButton.title = "⚪️ 禁用"
            toggleButton.layer?.backgroundColor = NSColor(calibratedWhite: 0.18, alpha: 0.9).cgColor
            toggleButton.layer?.borderColor = NSColor(calibratedWhite: 0.32, alpha: 1.0).cgColor
            toggleButton.isEnabled = true
        }
    }

    private func loadThumbnailAsync() {
        categoryIconLabel.stringValue = ""
        categoryIconLabel.isHidden = true

        let targetPath = item.targetPath
        let cacheKey = targetPath as NSString

        // 1. 优先从内存缓存高速读取 (0ms 瞬时命中，杜绝反复 I/O 与掉帧)
        if let cachedImage = ResourceCardView.thumbnailCache.object(forKey: cacheKey) {
            thumbnailImageView.image = cachedImage
            thumbnailImageView.contentTintColor = nil
            return
        }

        // 2. 缓存未命中时，后台 GCD 异步探测并解码
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let image = self.discoverThumbnailImage(path: targetPath)
            if let img = image {
                ResourceCardView.thumbnailCache.setObject(img, forKey: cacheKey)
            }
            DispatchQueue.main.async {
                guard self.item.targetPath == targetPath else { return }
                if let img = image {
                    self.thumbnailImageView.image = img
                    self.thumbnailImageView.contentTintColor = nil
                } else {
                    let fallback = NSImage(systemSymbolName: "film", accessibilityDescription: nil)
                    self.thumbnailImageView.image = fallback
                    self.thumbnailImageView.contentTintColor = NSColor(calibratedWhite: 0.35, alpha: 1.0)
                }
            }
        }
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        if item.isOffline {
            return nil
        }
        if let customMenu = onRequestContextMenu?(item, event) {
            return customMenu
        }
        return super.menu(for: event)
    }

    private func discoverThumbnailImage(path: String) -> NSImage? {
        let fm = FileManager.default
        let candidates = [
            "\(path)/large.png",
            "\(path)/Large.png",
            "\(path)/small.png",
            "\(path)/Small.png",
            "\(path)/thumbnail.png",
            "\(path)/Thumbnail.png",
            "\(path)/preview.png",
            "\(path)/Preview.png",
            "\(path)/preview.jpg",
            "\(path)/Preview.jpg"
        ]
        for c in candidates {
            if fm.fileExists(atPath: c), let img = NSImage(contentsOfFile: c) {
                return img
            }
        }
        // 查找包内任意第一张 png / jpg
        if let entries = try? fm.contentsOfDirectory(atPath: path) {
            for entry in entries.sorted() where entry.hasSuffix(".png") || entry.hasSuffix(".jpg") || entry.hasSuffix(".jpeg") {
                if entry.hasPrefix(".") { continue }
                let p = "\(path)/\(entry)"
                if let img = NSImage(contentsOfFile: p) {
                    return img
                }
            }
        }
        return nil
    }

    // MARK: – Actions
    @objc private func onToggleClicked() {
        guard !item.isOffline else { return }
        if let onToggle = onToggle {
            onToggle(item)
        } else {
            do {
                let updated = try TemplateInstaller.shared.toggleTemplate(item: item)
                self.item = updated
            } catch {
                print("[ResourceCardView] Toggle template failed: \(error.localizedDescription)")
            }
        }
    }

    @objc private func onMenuClicked() {
        guard !item.isOffline else { return }
        onActionMenu?(item, menuButton)
    }

    // MARK: – Hover Effects
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseEntered(with event: NSEvent) {
        if item.isOffline { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            layer?.borderColor = NSColor(calibratedRed: 0.28, green: 0.48, blue: 0.95, alpha: 0.9).cgColor
            layer?.backgroundColor = NSColor(calibratedRed: 0.14, green: 0.15, blue: 0.18, alpha: 1.0).cgColor
        }
    }

    public override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            layer?.borderColor = NSColor(calibratedWhite: 0.20, alpha: 1.0).cgColor
            layer?.backgroundColor = NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.14, alpha: 1.0).cgColor
        }
    }
}
