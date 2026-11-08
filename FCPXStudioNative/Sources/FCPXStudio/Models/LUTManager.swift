import AppKit
import CoreImage
import Foundation

// ═══════════════════════════════════════════════════════════════
//  LUTManager —— 3D LUT 调色库发现、Cube 解析与 CoreImage 滤镜引擎
//  对标基准：/Applications/嘉星插件管理 2.app (FXLUT 架构)
// ═══════════════════════════════════════════════════════════════

public struct LUTItem: Identifiable, Equatable {
    public let id: UUID
    public let name: String
    public let path: String
    public let category: String
    public let thumbnailPath: String?
    public let fileSizeBytes: Int64
    public var dimension: Int

    public var fileSizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
    }

    public init(id: UUID = UUID(),
                name: String,
                path: String,
                category: String,
                thumbnailPath: String?,
                fileSizeBytes: Int64,
                dimension: Int = 33) {
        self.id = id
        self.name = name
        self.path = path
        self.category = category
        self.thumbnailPath = thumbnailPath
        self.fileSizeBytes = fileSizeBytes
        self.dimension = dimension
    }
}

public final class LUTManager {
    public static let shared = LUTManager()

    public private(set) var defaultSearchPaths: [String] = [
        ("~/Library/Containers/com.apple.FinalCut/Data/Library/Application Support/ProApps/Camera LUTs" as NSString).expandingTildeInPath,
        "/Library/Application Support/ProApps/Camera LUTs",
        ("~/Library/Application Support/ProApps/Camera LUTs" as NSString).expandingTildeInPath,
        "/Volumes/SD/LUTs"
    ]

    // UI-G061: 增加 cacheLock 保证并发访问 cubeCache 线程安全
    private let cacheLock = NSLock()
    private var cubeCache: [String: (dimension: Int, cubeData: Data)] = [:]
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    public init() {}

    // MARK: – 扫描发现

    /// 扫描指定目录或默认目录，发现所有 .cube 文件并提取元数据
    public func scan(customPaths: [String]? = nil) -> [LUTItem] {
        let fm = FileManager.default
        let pathsToScan = (customPaths ?? defaultSearchPaths).filter { fm.fileExists(atPath: $0) }
        var results: [LUTItem] = []
        var seenPaths = Set<String>()

        for root in pathsToScan {
            guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: root),
                                                 includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                                 options: [.skipsHiddenFiles]) else {
                continue
            }

            for case let fileURL as URL in enumerator {
                if fileURL.pathExtension.lowercased() == "cube" {
                    let path = fileURL.path
                    if seenPaths.contains(path) { continue }
                    seenPaths.insert(path)

                    let name = fileURL.deletingPathExtension().lastPathComponent
                    let category = fileURL.deletingLastPathComponent().lastPathComponent
                    let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

                    guard let dimension = peekDimension(at: path) else {
                        // 忽略非标准或损坏的文件（如误下载为 HTML 的文件）
                        continue
                    }

                    let thumb = findThumbnail(for: fileURL)

                    let item = LUTItem(
                        name: name,
                        path: path,
                        category: category,
                        thumbnailPath: thumb,
                        fileSizeBytes: Int64(size),
                        dimension: dimension
                    )
                    results.append(item)
                }
            }
        }

        results.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return results
    }

    /// 异步扫描 3D LUT 库，切入后台 GCD 线程，自动命中/填充 AssetCacheManager
    public func scanAsync(customPaths: [String]? = nil, completion: @escaping ([LUTItem]) -> Void) {
        if let cached = AssetCacheManager.shared.getLUTs() {
            DispatchQueue.main.async {
                completion(cached)
            }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let items = self.scan(customPaths: customPaths)
            AssetCacheManager.shared.setLUTs(items)
            DispatchQueue.main.async {
                completion(items)
            }
        }
    }

    /// 寻找同名或邻近的缩略图 (.cube.jpg, .jpg, .png)
    public func findThumbnail(for fileURL: URL) -> String? {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let fullFilename = fileURL.lastPathComponent // 例如 MyLut.cube

        let candidates = [
            dir.appendingPathComponent("\(fullFilename).jpg").path,
            dir.appendingPathComponent("\(fullFilename).png").path,
            dir.appendingPathComponent("\(baseName).jpg").path,
            dir.appendingPathComponent("\(baseName).png").path,
            dir.appendingPathComponent("\(baseName).jpeg").path
        ]

        for cand in candidates {
            if fm.fileExists(atPath: cand) {
                return cand
            }
        }
        return nil
    }

    /// 快速探测 .cube 文件的 LUT_3D_SIZE，避免全量解析或误读 HTML 文件
    public func peekDimension(at path: String) -> Int? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let headerData = handle.readData(ofLength: 4096)
        guard let header = String(data: headerData, encoding: .utf8) else { return nil }

        if header.contains("<!DOCTYPE") || header.contains("<html") {
            return nil
        }

        for rawLine in header.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("LUT_3D_SIZE") {
                let parts = line.split(whereSeparator: { $0.isWhitespace })
                if parts.count >= 2, let d = Int(parts[1]), d >= 2 && d <= 128 {
                    return d
                }
            }
        }
        return nil
    }

    // MARK: – Cube 解析与 CIColorCube 构建

    /// 严格解析 .cube 文件生成 CoreImage 规范的 RGBA 32-bit float Data
    public func parseCube(at path: String) throws -> (dimension: Int, cubeData: Data) {
        cacheLock.lock()
        if let cached = cubeCache[path] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let content = try String(contentsOfFile: path, encoding: .utf8)
        var dimension = 0
        var floats = [Float]()

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("LUT_3D_SIZE") {
                let parts = line.split(whereSeparator: { $0.isWhitespace })
                if parts.count >= 2, let d = Int(parts[1]) {
                    dimension = d
                    floats.reserveCapacity(dimension * dimension * dimension * 4)
                }
                continue
            }

            if line.hasPrefix("TITLE") || line.hasPrefix("DOMAIN_") || line.hasPrefix("LUT_1D_SIZE") {
                continue
            }

            let parts = line.split(whereSeparator: { $0.isWhitespace })
            if parts.count >= 3,
               let r = Float(parts[0]),
               let g = Float(parts[1]),
               let b = Float(parts[2]) {
                floats.append(r)
                floats.append(g)
                floats.append(b)
                floats.append(1.0) // Alpha 恒为 1.0
            }
        }

        // UI-O025: 强制要求 LUT_3D_SIZE 头，缺失即报错，严禁浮点推算产生尺寸误差
        if dimension == 0 {
            throw NSError(domain: "LUTManager", code: 1003,
                          userInfo: [NSLocalizedDescriptionKey: "无效的 3D LUT 文件: 缺少必需的 LUT_3D_SIZE 头部定义"])
        }

        if dimension < 2 || dimension > 128 {
            throw NSError(domain: "LUTManager", code: 1002,
                          userInfo: [NSLocalizedDescriptionKey: "无效的 3D LUT 文件: LUT_3D_SIZE 必须在 2 至 128 之间，实际读入 \(dimension)"])
        }

        let expectedCount = dimension * dimension * dimension * 4
        if floats.count != expectedCount {
            throw NSError(domain: "LUTManager", code: 1001,
                          userInfo: [NSLocalizedDescriptionKey: "Cube 数据大小与尺寸不匹配: 读入 \(floats.count), 预期 \(expectedCount)"])
        }

        let cubeData = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        cacheLock.lock()
        cubeCache[path] = (dimension, cubeData)
        cacheLock.unlock()
        return (dimension, cubeData)
    }

    /// 构建 CIColorCube 硬件加速滤镜
    public func makeColorCubeFilter(dimension: Int, cubeData: Data) -> CIFilter? {
        guard let filter = CIFilter(name: "CIColorCube") else { return nil }
        filter.setValue(dimension, forKey: "inputCubeDimension")
        filter.setValue(cubeData, forKey: "inputCubeData")
        return filter
    }

    /// 对 CIImage 应用 LUT 滤镜
    public func applyLUT(to image: CIImage, dimension: Int, cubeData: Data) -> CIImage? {
        guard let filter = makeColorCubeFilter(dimension: dimension, cubeData: cubeData) else {
            return nil
        }
        filter.setValue(image, forKey: kCIInputImageKey)
        return filter.outputImage
    }

    /// 对 NSImage 应用 LUT 渲染生成新 NSImage
    public func renderLUTImage(input: NSImage, dimension: Int, cubeData: Data) -> NSImage? {
        guard let tiffData = input.tiffRepresentation,
              let ciImage = CIImage(data: tiffData) else {
            return nil
        }
        guard let outputCI = applyLUT(to: ciImage, dimension: dimension, cubeData: cubeData) else {
            return nil
        }

        let rect = CGRect(origin: .zero, size: input.size)
        guard let cgImage = ciContext.createCGImage(outputCI, from: rect.isEmpty ? outputCI.extent : rect) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: input.size)
    }

    // MARK: – 内置电影级基准参考样张

    /// 生成带有色彩渐变、肤色卡、高光阴影宽容度色块的基准参考图像（用于分屏对比）
    public static func makeCinematicReferenceImage(width: CGFloat = 960, height: CGFloat = 540) -> NSImage {
        let size = NSSize(width: width, height: height)
        let image = NSImage(size: size)
        image.lockFocus()

        // 1. 底层天空与暖阳微反差对角渐变
        let startColor = NSColor(red: 0.18, green: 0.28, blue: 0.38, alpha: 1.0)
        let endColor = NSColor(red: 0.82, green: 0.62, blue: 0.45, alpha: 1.0)
        if let gradient = NSGradient(starting: startColor, ending: endColor) {
            gradient.draw(in: NSRect(origin: .zero, size: size), angle: 35)
        }

        // 2. 电影色彩校准色块矩阵 (Color Checker Swatches)
        let colors: [NSColor] = [
            NSColor(red: 0.45, green: 0.30, blue: 0.24, alpha: 1.0), // 深肤色
            NSColor(red: 0.77, green: 0.58, blue: 0.50, alpha: 1.0), // 浅肤色
            NSColor(red: 0.38, green: 0.48, blue: 0.61, alpha: 1.0), // 天空蓝
            NSColor(red: 0.35, green: 0.43, blue: 0.26, alpha: 1.0), // 树叶绿
            NSColor(red: 0.52, green: 0.49, blue: 0.68, alpha: 1.0), // 丁香紫
            NSColor(red: 0.39, green: 0.74, blue: 0.66, alpha: 1.0), // 青蓝
            NSColor(red: 0.84, green: 0.47, blue: 0.18, alpha: 1.0), // 橙色
            NSColor(red: 0.28, green: 0.34, blue: 0.65, alpha: 1.0), // 蓝调
            NSColor(red: 0.76, green: 0.32, blue: 0.39, alpha: 1.0), // 红紫
            NSColor(red: 0.36, green: 0.22, blue: 0.42, alpha: 1.0), // 紫色
            NSColor(red: 0.62, green: 0.74, blue: 0.28, alpha: 1.0), // 黄绿
            NSColor(red: 0.89, green: 0.64, blue: 0.16, alpha: 1.0), // 橙黄
            NSColor(white: 0.95, alpha: 1.0),                         // 白场
            NSColor(white: 0.75, alpha: 1.0),                         // 中浅灰
            NSColor(white: 0.50, alpha: 1.0),                         // 18% 灰
            NSColor(white: 0.30, alpha: 1.0),                         // 深灰
            NSColor(white: 0.08, alpha: 1.0)                          // 黑场
        ]

        let swatchW: CGFloat = 44
        let swatchH: CGFloat = 44
        let marginX: CGFloat = 36
        let marginY: CGFloat = 40

        for (i, c) in colors.enumerated() {
            let row = CGFloat(i / 6)
            let col = CGFloat(i % 6)
            let rect = NSRect(x: marginX + col * (swatchW + 8),
                              y: marginY + row * (swatchH + 8),
                              width: swatchW, height: swatchH)
            c.setFill()
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            path.fill()
            NSColor(white: 0.2, alpha: 0.6).setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        // 3. 电影画幅与水印提示
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 22, weight: .bold),
            .foregroundColor: NSColor(white: 1.0, alpha: 0.9)
        ]
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor(white: 0.85, alpha: 0.8)
        ]

        ("FCPX Studio Pro 3D LUT 对比基准样张" as NSString).draw(at: NSPoint(x: marginX, y: height - 60), withAttributes: titleAttrs)
        ("Rec.709 / Log 动态宽容度色彩测试基准 · 支持直接拖入外部原片测试" as NSString).draw(at: NSPoint(x: marginX, y: height - 85), withAttributes: subAttrs)

        image.unlockFocus()
        return image
    }
}
