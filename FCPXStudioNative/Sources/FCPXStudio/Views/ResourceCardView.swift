import AppKit
import Foundation

// ═══════════════════════════════════════════════════════════════
//  ResourceCardView —— 对标嘉星 FxXuResourceCardView 的现代化高质感卡片
//  视觉特性：
//    1. 暗色石墨圆角卡片 (#1a1b1f)，悬停外发光边框 (#3e64ff)；
//    2. 16:9 高清缩略图视口（自动加载模板包内图片或优雅矢量渐变占位）；
//    3. 中文友好别名（主标题）+ 英文原始标识（副标题）+ 容量胶囊徽章；
//    4. 三级归属徽章（🟡 内置 / 🟢 用户 / 🟣 系统）；
//    5. 精致「开启 / 禁用」胶囊 Toggle 开关 + 更多操作菜单。
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
    public private(set) var alertBadgeLabel: NSTextField!
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
        layer?.cornerRadius = CornerRadius.card
        layer?.masksToBounds = true
        layer?.backgroundColor = StatusPalette.cardBg.cgColor
        layer?.borderWidth = 1.0
        layer?.borderColor = StatusPalette.cardBorderNormal.cgColor

        // 1. 16:9 缩略图视口容器 (width: bounds.width - 16, height: ~120)
        let thumbW = bounds.width - 16
        let thumbH = round(thumbW * 9.0 / 16.0)
        let thumbY = bounds.height - 8 - thumbH

        thumbnailContainer = NSView(frame: NSRect(x: 8, y: thumbY, width: thumbW, height: thumbH))
        thumbnailContainer.wantsLayer = true
        thumbnailContainer.layer?.cornerRadius = CornerRadius.card
        thumbnailContainer.layer?.masksToBounds = true
        thumbnailContainer.layer?.backgroundColor = NSColor.black.cgColor
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
        tierBadgeLabel = NSTextField(labelWithString: "用户")
        tierBadgeLabel.font = TypeScale.captionMedium
        tierBadgeLabel.textColor = .white
        tierBadgeLabel.wantsLayer = true
        tierBadgeLabel.layer?.backgroundColor = StatusPalette.disabledBg.cgColor
        tierBadgeLabel.layer?.cornerRadius = CornerRadius.badge
        tierBadgeLabel.layer?.masksToBounds = true
        tierBadgeLabel.alignment = .center
        tierBadgeLabel.frame = NSRect(x: 4, y: thumbH - 22, width: 56, height: 18)
        thumbnailContainer.addSubview(tierBadgeLabel)

        // 2a. 子分类标签悬浮在缩略图左下角 (TR-003: 低饱和蓝底 + 白字，提升对比度)
        subCategoryBadgeLabel = NSTextField(labelWithString: "")
        subCategoryBadgeLabel.font = TypeScale.captionMedium
        subCategoryBadgeLabel.textColor = .white
        subCategoryBadgeLabel.wantsLayer = true
        subCategoryBadgeLabel.layer?.backgroundColor = ColorToken.softBlue.cgColor
        subCategoryBadgeLabel.layer?.borderColor = ColorToken.primaryBlue.withAlphaComponent(0.4).cgColor
        subCategoryBadgeLabel.layer?.borderWidth = 0.5
        subCategoryBadgeLabel.layer?.cornerRadius = CornerRadius.badge
        subCategoryBadgeLabel.layer?.masksToBounds = true
        subCategoryBadgeLabel.alignment = .center
        subCategoryBadgeLabel.frame = NSRect(x: 4, y: 4, width: 70, height: 18)
        subCategoryBadgeLabel.isHidden = true
        thumbnailContainer.addSubview(subCategoryBadgeLabel)

        // 2b. 停用状态徽章（.disabled 状态感知）悬浮在缩略图右上角 (U-9: 统一尺寸 80x18, 右对齐 thumbW - 84)
        disabledBadgeLabel = NSTextField(labelWithString: "已停用")
        disabledBadgeLabel.font = TypeScale.captionMedium
        disabledBadgeLabel.textColor = StatusPalette.textPrimary
        disabledBadgeLabel.wantsLayer = true
        disabledBadgeLabel.layer?.backgroundColor = StatusPalette.disabledBg.cgColor
        disabledBadgeLabel.layer?.cornerRadius = CornerRadius.badge
        disabledBadgeLabel.layer?.masksToBounds = true
        disabledBadgeLabel.alignment = .center
        disabledBadgeLabel.frame = NSRect(x: thumbW - 84, y: thumbH - 22, width: 80, height: 18)
        disabledBadgeLabel.isHidden = true
        thumbnailContainer.addSubview(disabledBadgeLabel)

        // 2c. 离线状态徽章（磁盘断链）悬浮在缩略图右上角 (U-9: 统一尺寸 80x18, 右对齐 thumbW - 84)
        offlineBadgeLabel = NSTextField(labelWithString: "磁盘离线")
        offlineBadgeLabel.font = TypeScale.captionMedium
        offlineBadgeLabel.textColor = StatusPalette.textPrimary
        offlineBadgeLabel.wantsLayer = true
        offlineBadgeLabel.layer?.backgroundColor = StatusPalette.offlineBg.cgColor
        offlineBadgeLabel.layer?.cornerRadius = CornerRadius.badge
        offlineBadgeLabel.layer?.masksToBounds = true
        offlineBadgeLabel.alignment = .center
        offlineBadgeLabel.frame = NSRect(x: thumbW - 84, y: thumbH - 22, width: 80, height: 18)
        offlineBadgeLabel.isHidden = true
        thumbnailContainer.addSubview(offlineBadgeLabel)

        // 2d. 警告/损坏/异盘同名状态徽章 (U-9: 统一尺寸 80x18, 右对齐 thumbW - 84)
        alertBadgeLabel = NSTextField(labelWithString: "损坏/丢失")
        alertBadgeLabel.font = .systemFont(ofSize: 10, weight: .bold)
        alertBadgeLabel.textColor = .white
        alertBadgeLabel.wantsLayer = true
        alertBadgeLabel.layer?.backgroundColor = StatusPalette.alertRedBg.cgColor
        alertBadgeLabel.layer?.cornerRadius = 4
        alertBadgeLabel.layer?.masksToBounds = true
        alertBadgeLabel.alignment = .center
        alertBadgeLabel.frame = NSRect(x: thumbW - 84, y: thumbH - 22, width: 80, height: 18)
        alertBadgeLabel.isHidden = true
        thumbnailContainer.addSubview(alertBadgeLabel)

        // 3. 容量标签悬浮在缩略图右下角
        sizeBadgeLabel = NSTextField(labelWithString: "0 MB")
        sizeBadgeLabel.font = TypeScale.caption
        sizeBadgeLabel.textColor = StatusPalette.textSecondary
        sizeBadgeLabel.wantsLayer = true
        sizeBadgeLabel.layer?.backgroundColor = StatusPalette.disabledBg.cgColor
        sizeBadgeLabel.layer?.cornerRadius = CornerRadius.badge
        sizeBadgeLabel.layer?.masksToBounds = true
        sizeBadgeLabel.alignment = .center
        sizeBadgeLabel.frame = NSRect(x: thumbW - 64, y: 4, width: 60, height: 18)
        thumbnailContainer.addSubview(sizeBadgeLabel)

        // 4. 主标题区（中文别名或原名）
        let infoY = thumbY - 8
        titleLabel = NSTextField(labelWithString: item.name)
        titleLabel.font = TypeScale.bodyBold
        titleLabel.textColor = StatusPalette.textPrimary
        titleLabel.cell?.lineBreakMode = .byTruncatingTail
        titleLabel.frame = NSRect(x: 10, y: infoY - 20, width: bounds.width - 20, height: 20)
        addSubview(titleLabel)

        // 5. 副标题区（英文原名或路径特征）
        subtitleLabel = NSTextField(labelWithString: item.name)
        subtitleLabel.font = TypeScale.footnote
        subtitleLabel.textColor = StatusPalette.textSecondary
        subtitleLabel.cell?.lineBreakMode = .byTruncatingTail
        subtitleLabel.frame = NSRect(x: 10, y: infoY - 40, width: bounds.width - 20, height: 18)
        addSubview(subtitleLabel)

        // 6. 底部操作区：精致胶囊 Toggle 开关 + 「⋯」更多菜单 (标准档位 20pt 收敛)
        let bottomY: CGFloat = 8
        toggleButton = NSButton(title: " 开启", target: self, action: #selector(onToggleClicked))
        toggleButton.bezelStyle = .regularSquare
        toggleButton.isBordered = false
        toggleButton.imagePosition = .imageLeading
        toggleButton.wantsLayer = true
        toggleButton.layer?.cornerRadius = CornerRadius.capsule
        toggleButton.layer?.masksToBounds = true
        toggleButton.layer?.borderWidth = 1.0
        toggleButton.font = TypeScale.footnoteMedium
        toggleButton.frame = NSRect(x: 10, y: bottomY, width: 88, height: 28)
        addSubview(toggleButton)

        menuButton = NSButton(title: "", target: self, action: #selector(onMenuClicked))
        menuButton.bezelStyle = .regularSquare
        menuButton.isBordered = false
        menuButton.imagePosition = .imageOnly
        let menuConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
        menuButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "更多")?.withSymbolConfiguration(menuConfig)
        menuButton.contentTintColor = StatusPalette.textPrimary
        menuButton.wantsLayer = true
        menuButton.layer?.cornerRadius = CornerRadius.capsule
        menuButton.layer?.masksToBounds = true
        menuButton.layer?.backgroundColor = StatusPalette.disabledBg.cgColor
        menuButton.layer?.borderWidth = 1.0
        menuButton.layer?.borderColor = StatusPalette.disabledBorder.cgColor
        menuButton.frame = NSRect(x: bounds.width - 42, y: bottomY, width: 32, height: 28)
        addSubview(menuButton)
    }

    // FCPX-038: 基于 bounds 实时动态排版，适配卡片尺寸伸缩
    public override func layout() {
        super.layout()
        let w = bounds.width
        let h = bounds.height
        let thumbW = max(50.0, w - 16)
        let thumbH = round(thumbW * 9.0 / 16.0)
        let thumbY = max(0.0, h - 8 - thumbH)

        thumbnailContainer?.frame = NSRect(x: 8, y: thumbY, width: thumbW, height: thumbH)
        tierBadgeLabel?.frame = NSRect(x: 4, y: max(0.0, thumbH - 22), width: 56, height: 18)
        subCategoryBadgeLabel?.frame = NSRect(x: 4, y: 4, width: min(100, max(20, thumbW - 80)), height: 18)
        sizeBadgeLabel?.frame = NSRect(x: max(10, thumbW - 68), y: 4, width: 64, height: 18)
        disabledBadgeLabel?.frame = NSRect(x: max(10, thumbW - 84), y: max(0.0, thumbH - 22), width: 80, height: 18)

        let infoY = max(42.0, thumbY - 50.0)
        titleLabel?.frame = NSRect(x: 10, y: infoY + 20, width: max(50, w - 20), height: 20)
        subtitleLabel?.frame = NSRect(x: 10, y: infoY + 2, width: max(50, w - 20), height: 16)

        let bottomY: CGFloat = 8
        let toggleW = max(50.0, w - 16 - 32 - 8)
        toggleButton?.frame = NSRect(x: 8, y: bottomY, width: toggleW, height: 28)
        menuButton?.frame = NSRect(x: max(10, w - 42), y: bottomY, width: 32, height: 28)
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

        updateTierBadge()

        if !item.subCategory.isEmpty {
            subCategoryBadgeLabel.stringValue = item.subCategory
            subCategoryBadgeLabel.isHidden = false
            let fit = subCategoryBadgeLabel.sizeThatFits(NSSize(width: 140, height: 18))
            let w = max(36, min(100, fit.width + 10))
            subCategoryBadgeLabel.frame = NSRect(x: 4, y: 4, width: w, height: 18)
        } else {
            subCategoryBadgeLabel.isHidden = true
        }

        if item.isMismatchedDisk {
            self.alphaValue = 0.7
            alertBadgeLabel.stringValue = "异盘同名"
            alertBadgeLabel.layer?.backgroundColor = StatusPalette.amberOrangeBg.cgColor
            alertBadgeLabel.isHidden = false
            offlineBadgeLabel.isHidden = true
            disabledBadgeLabel.isHidden = true
            thumbnailContainer.alphaValue = 1.0
            titleLabel.textColor = StatusPalette.amberOrange
            layer?.borderColor = StatusPalette.amberOrangeBorder.cgColor
            toggleButton.isEnabled = false
            menuButton.isEnabled = true
        } else if item.isCorrupted {
            self.alphaValue = 0.7
            alertBadgeLabel.stringValue = "损坏/丢失"
            alertBadgeLabel.layer?.backgroundColor = StatusPalette.alertRedBg.cgColor
            alertBadgeLabel.isHidden = false
            offlineBadgeLabel.isHidden = true
            disabledBadgeLabel.isHidden = true
            thumbnailContainer.alphaValue = 1.0
            titleLabel.textColor = StatusPalette.alertRed
            layer?.borderColor = StatusPalette.alertRedBorder.cgColor
            toggleButton.isEnabled = false
            menuButton.isEnabled = true
        } else if item.isOffline {
            self.alphaValue = 0.7
            alertBadgeLabel.isHidden = true
            offlineBadgeLabel.stringValue = "磁盘离线"
            offlineBadgeLabel.layer?.backgroundColor = StatusPalette.offlineBg.cgColor
            offlineBadgeLabel.isHidden = false
            disabledBadgeLabel.isHidden = true
            thumbnailContainer.alphaValue = 1.0
            titleLabel.textColor = StatusPalette.offlineGray
            layer?.borderColor = StatusPalette.cardBorderNormal.cgColor
            toggleButton.isEnabled = false
            menuButton.isEnabled = true
        } else {
            self.alphaValue = 1.0
            alertBadgeLabel.isHidden = true
            offlineBadgeLabel.isHidden = true
            disabledBadgeLabel.stringValue = "已停用"
            disabledBadgeLabel.layer?.backgroundColor = StatusPalette.disabledBg.cgColor
            disabledBadgeLabel.isHidden = item.isEnabled
            thumbnailContainer.alphaValue = item.isEnabled ? 1.0 : 0.65
            titleLabel.textColor = item.isEnabled ? StatusPalette.textPrimary : StatusPalette.textSecondary
            layer?.borderColor = StatusPalette.cardBorderNormal.cgColor
            toggleButton.isEnabled = true
            menuButton.isEnabled = true
        }

        // TR-001: 优先从 AssetCacheManager 提取已缓存体积，消除无谓计算中
        if item.sizeMB <= 0 {
            if let cached = AssetCacheManager.shared.getTemplateSize(category: item.category, name: item.name), cached > 0 {
                item.sizeMB = cached
            }
        }

        if item.isSymlink {
            sizeBadgeLabel.stringValue = "软链接"
        } else if item.sizeMB > 0 {
            sizeBadgeLabel.stringValue = String(format: "%.1f MB", item.sizeMB)
        } else {
            // TR-001 & UI-O004: 主动触发一次体积计算，<=2s 超时或无法计算时回退为 "--"，绝不永久停留
            sizeBadgeLabel.stringValue = "计算中…"
            let currentPath = item.path
            let category = item.category
            let name = item.name
            DispatchQueue.global(qos: .utility).async { [weak self, currentPath, category, name] in
                var calculatedMB: Double = 0
                if let cached = AssetCacheManager.shared.getTemplateSize(category: category, name: name), cached > 0 {
                    calculatedMB = cached
                } else if let attr = try? FileManager.default.attributesOfItem(atPath: currentPath),
                   let sz = attr[.size] as? Int64 {
                    calculatedMB = Double(sz) / (1024.0 * 1024.0)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self = self, self.item.path == currentPath else { return }
                    if self.item.sizeMB > 0 {
                        self.sizeBadgeLabel.stringValue = String(format: "%.1f MB", self.item.sizeMB)
                    } else if calculatedMB > 0 {
                        self.item.sizeMB = calculatedMB
                        self.sizeBadgeLabel.stringValue = String(format: "%.1f MB", calculatedMB)
                    } else {
                        self.sizeBadgeLabel.stringValue = "--"
                    }
                }
            }
        }

        updateToggleAppearance()
        if !item.isOffline && !item.isCorrupted && !item.isMismatchedDisk {
            loadThumbnailAsync()
        } else if item.isOffline {
            let fallback = NSImage(systemSymbolName: "externaldrive.badge.xmark", accessibilityDescription: nil) ?? NSImage(systemSymbolName: "film", accessibilityDescription: nil)
            thumbnailImageView.image = fallback
            thumbnailImageView.contentTintColor = StatusPalette.textMuted
        } else {
            let fallback = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil) ?? NSImage(systemSymbolName: "film", accessibilityDescription: nil)
            thumbnailImageView.image = fallback
            thumbnailImageView.contentTintColor = StatusPalette.alertRed
        }
    }

    private func updateTierBadge() {
        let (tierColor, tierTitle): (NSColor, String) = {
            switch item.tier {
            case .user:
                return (ColorToken.successGreen, "用户")
            case .builtin:
                return (ColorToken.warningAmber, "内置")
            case .system:
                return (StatusPalette.tierSystem, "系统")
            }
        }()

        // TR-003: 统一使用 ColorToken，移除多余圆点附着物，提升文字与色板对比度
        tierBadgeLabel.stringValue = tierTitle
        tierBadgeLabel.textColor = tierColor
        tierBadgeLabel.font = TypeScale.captionMedium
        tierBadgeLabel.layer?.backgroundColor = ColorToken.tableRowBg.cgColor
        tierBadgeLabel.layer?.borderColor = tierColor.withAlphaComponent(0.45).cgColor
        tierBadgeLabel.layer?.borderWidth = 0.8
    }

    public func updateToggleAppearance() {
        let iconConfig = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        toggleButton.imagePosition = .imageLeading

        if item.isMismatchedDisk {
            toggleButton.title = " 异盘"
            toggleButton.image = NSImage(systemSymbolName: "xmark.octagon.fill", accessibilityDescription: nil)?.withSymbolConfiguration(iconConfig)
            toggleButton.contentTintColor = StatusPalette.amberOrange
            toggleButton.layer?.backgroundColor = StatusPalette.amberOrangeBgSemi.cgColor
            toggleButton.layer?.borderColor = StatusPalette.amberOrangeBorder.cgColor
            toggleButton.isEnabled = false
        } else if item.isCorrupted {
            toggleButton.title = " 损坏"
            toggleButton.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?.withSymbolConfiguration(iconConfig)
            toggleButton.contentTintColor = StatusPalette.alertRed
            toggleButton.layer?.backgroundColor = StatusPalette.alertRedBgSemi.cgColor
            toggleButton.layer?.borderColor = StatusPalette.alertRedBorder.cgColor
            toggleButton.isEnabled = false
        } else if item.isOffline {
            toggleButton.title = " 离线"
            toggleButton.image = NSImage(systemSymbolName: "externaldrive.badge.xmark", accessibilityDescription: nil)?.withSymbolConfiguration(iconConfig)
            toggleButton.contentTintColor = StatusPalette.offlineGray
            toggleButton.layer?.backgroundColor = StatusPalette.offlineBgSemi.cgColor
            toggleButton.layer?.borderColor = StatusPalette.offlineBorder.cgColor
            toggleButton.isEnabled = false
        } else if item.isEnabled {
            // TR-003: 统一绿系为 ColorToken.successGreen
            let unifiedGreen = ColorToken.successGreen
            toggleButton.title = " 开启"
            toggleButton.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "开启")?.withSymbolConfiguration(
                iconConfig.applying(NSImage.SymbolConfiguration(hierarchicalColor: unifiedGreen))
            )
            toggleButton.contentTintColor = unifiedGreen
            toggleButton.layer?.backgroundColor = unifiedGreen.withAlphaComponent(0.18).cgColor
            toggleButton.layer?.borderColor = unifiedGreen.withAlphaComponent(0.5).cgColor
            toggleButton.isEnabled = true
        } else {
            toggleButton.title = " 已停用"
            toggleButton.image = NSImage(systemSymbolName: "circle", accessibilityDescription: nil)?.withSymbolConfiguration(
                iconConfig.applying(NSImage.SymbolConfiguration(hierarchicalColor: StatusPalette.textSecondary))
            )
            toggleButton.contentTintColor = StatusPalette.textSecondary
            toggleButton.layer?.backgroundColor = StatusPalette.disabledBg.cgColor
            toggleButton.layer?.borderColor = StatusPalette.disabledBorder.cgColor
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
                guard !self.item.isOffline && !self.item.isCorrupted && !self.item.isMismatchedDisk else { return }
                guard self.item.targetPath == targetPath else { return }
                if let img = image {
                    self.thumbnailImageView.image = img
                    self.thumbnailImageView.contentTintColor = nil
                } else {
                    let fallback = NSImage(systemSymbolName: "film", accessibilityDescription: nil)
                    self.thumbnailImageView.image = fallback
                    self.thumbnailImageView.contentTintColor = StatusPalette.textDim
                }
            }
        }
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        if item.isOffline && !item.isMismatchedDisk && !item.isCorrupted {
            let offlineMenu = NSMenu(title: "离线提示")
            let tipItem = NSMenuItem(title: "⚠️ 磁盘离线，重新挂载后可操作", action: nil, keyEquivalent: "")
            tipItem.isEnabled = false
            offlineMenu.addItem(tipItem)
            return offlineMenu
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
        // FCPX-033: 故障与离线态点击弹窗说明并指引操作，杜绝静默零反馈
        if item.isOffline {
            let alert = NSAlert()
            alert.messageText = "素材处于离线状态"
            alert.informativeText = "该模板所在的外置存储卷尚未挂载或连接中断，无法切换启用状态。请重新连接外置盘后再试。"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "知道了")
            alert.runModal()
            return
        }
        if item.isCorrupted || item.isMismatchedDisk {
            let alert = NSAlert()
            alert.messageText = item.isMismatchedDisk ? "素材存储卷不匹配" : "素材软链接破损"
            alert.informativeText = item.isMismatchedDisk
                ? "该模板当前指向不同 UUID 的外置存储卷。如需恢复使用，请点击卡片右下角更多菜单选择【重新校验 / 强制绑定】。"
                : "该模板指向的目标文件已丢失或软链接损坏。请点击卡片右下角更多菜单进入【幽灵插件医生】执行智能自愈。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "知道了")
            alert.runModal()
            return
        }

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
        if item.isOffline && !item.isMismatchedDisk && !item.isCorrupted { return }
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
            if self.item.isMismatchedDisk {
                self.layer?.borderColor = StatusPalette.amberOrange.cgColor
            } else if self.item.isCorrupted {
                self.layer?.borderColor = StatusPalette.alertRed.cgColor
            } else {
                self.layer?.borderColor = StatusPalette.cardSelectedBorder.cgColor
            }
            self.layer?.backgroundColor = StatusPalette.cardSelectedBg.cgColor
        }
    }

    public override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            if self.item.isMismatchedDisk {
                self.layer?.borderColor = StatusPalette.amberOrangeBorder.cgColor
            } else if self.item.isCorrupted {
                self.layer?.borderColor = StatusPalette.alertRedBorder.cgColor
            } else {
                self.layer?.borderColor = StatusPalette.cardBorderNormal.cgColor
            }
            self.layer?.backgroundColor = StatusPalette.cardBg.cgColor
        }
    }
}
