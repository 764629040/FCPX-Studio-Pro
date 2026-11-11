// ═══════════════════════════════════════════════════════════════════════════
// Models/PngRecolor.swift
// TR-024：PNG 像素层换色（保形状、改颜色）
//
// 背景：PNG 拆分产物是像素层（kind == "fallback_png"），颜色烧死在像素里，
// 改参数无效。形状（alpha）与颜色（RGB）本就分离，所以换色 = 只动 RGB、原样保留 alpha。
//
// 铁律：全部用 Core Image 滤镜链，本文件内【没有任何逐像素循环】。
//   · 唯一的「读像素」是 1×1 的 CIAreaAverage / AreaMaximum 结果（4 字节），
//     用于判断原图是否含多色，不是遍历整图。
//   · 四种模式各自一条固定滤镜链，见 apply(_:to:rgb:)。
//     其中「反相」是真反相（RGB 取反、alpha 原样），不使用目标色 —— 没设色也生效。
//
// 验收落点：
//   · 画布：InfiniteCanvasView.image(for:) 按 「路径 + 模式 + 颜色」缓存换色结果
//   · 导出：MotionBuilderSocket.buildTemplateResult 用 writePNG 落临时 PNG
// ═══════════════════════════════════════════════════════════════════════════

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers

/// 换色模式。`auto` 只是 UI 上的「自动」，落滤镜前一定解析成后四种之一。
public enum RecolorMode: Int, CaseIterable {
    case auto = 0        // 自动：按原图色彩分布自动选 direct / luminance
    case direct = 1      // 直接替换：整片墨色换成目标色，alpha 原样
    case luminance = 2   // 明暗上色（默认）：暗墨→目标色亮部，亮部→暗端，保留原图明暗梯度
    case invert = 3      // 反相：真反相（RGB 取反、alpha 原样），不使用目标色
    case hueRotate = 4   // 色相旋转：CIHueAdjust

    /// 新建位图层 / 解析缺省时的模式：明暗上色。
    /// （enum 顺序里 luminance 是 2，所以默认值取 2，跟 UI 下拉的第 3 项一致）
    public static let defaultRawValue = RecolorMode.luminance.rawValue

    public var title: String {
        switch self {
        case .auto:      return "自动"
        case .direct:    return "直接替换"
        case .luminance: return "明暗上色"
        case .invert:    return "反相"
        case .hueRotate: return "色相旋转"
        }
    }

    /// 落到具体模式（auto 解析成 direct / luminance）。永不返回 .auto。
    public func resolved(stats: PngRecolor.ColorStats?) -> RecolorMode {
        guard self == .auto else { return self }
        guard let s = stats else { return .direct }
        // 原图无彩 → 直接替换最忠实；原图本身有彩 → 用明暗上色保住亮度梯度，
        // 否则多色原图会被压成一坨同色块，细节全丢。
        return s.isAchromatic ? .direct : .luminance
    }
}

public enum PngRecolor {
    /// 色相旋转模式的旋转角：黑字源图没有色相可转，先按目标色建立色相基准再转 30°，
    /// 否则 CIHueAdjust 对无彩图是恒等变换，屏幕上画不出任何差异。
    public static let hueRotateDegrees: Double = 30.0

    /// 明暗上色的暗端系数：out = target*0.35 + (target - target*0.35) * luma
    private static let darkBaseFactor: Double = 0.35

    /// 全局共用 CIContext：每次 draw 新建 CIContext 会拖垮画布帧率。
    private static let ciContext = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
        .cacheIntermediates: false
    ])

    private static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    // MARK: - 原图色彩分布（供 auto 判定 + 检查器提示，纯 CI 面积采样）

    /// 原图色彩分布统计。用 1/4/9 宫格 CIAreaAverage + 全图 AreaMaximum/Minimum 采样，
    /// 不遍历像素。
    public struct ColorStats {
        public let averageSaturation: Double
        public let maxSaturation: Double
        public let hueSpreadDegrees: Double
        /// 全图看不到任何有彩像素
        public let isAchromatic: Bool
        /// 可见像素里存在两撮明显不同的色相 → 换色后必然变单色
        public let isMultiColor: Bool
    }

    // MARK: - 对外：换色

    /// 换色主入口。alpha 原样保留（滤镜链不碰 alpha 通道）。
    /// - Parameters:
    ///   - image: 原始像素图
    ///   - mode: 用户选择的模式（可为 .auto）
    ///   - color: 目标色，内部统一转 sRGB。**反相不吃目标色**，可以传 nil；
    ///            其它模式传 nil 时直接返回 nil（调用方退回原图，不拿默认色冒充）。
    public static func recolor(_ image: CGImage, mode: RecolorMode, color: NSColor?) -> CGImage? {
        let resolved = mode.resolved(stats: analyze(image))
        // 闸门只对 .invert 放开：其余模式没有目标色就不出图，行为与 TR-024 完全一致。
        guard resolved == .invert || color != nil else { return nil }
        let rgb = color.map { srgbComponents($0) } ?? (r: 0, g: 0, b: 0)   // 反相路径不读这个值
        let ci = CIImage(cgImage: image)
        guard let out = apply(resolved, to: ci, rgb: rgb) else { return nil }
        return ciContext.createCGImage(out, from: ci.extent, format: .RGBA8, colorSpace: srgb)
    }

    /// 导出用：把换色后的像素写成 PNG。color 语义同 recolor。
    public static func writePNG(_ src: CGImage, mode: RecolorMode, color: NSColor?, to url: URL) -> Bool {
        guard let out = recolor(src, mode: mode, color: color) else { return false }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                         UTType.png.identifier as CFString,
                                                         1, nil) else { return false }
        CGImageDestinationAddImage(dest, out, nil)
        return CGImageDestinationFinalize(dest)
    }

    // MARK: - 磁盘读取

    public static func loadCGImage(path: String) -> CGImage? {
        guard !path.isEmpty, let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: true] as CFDictionary)
    }

    private static let statsCache = NSCache<NSString, StatsBox>()

    private final class StatsBox {
        let stats: ColorStats
        init(_ s: ColorStats) { stats = s }
    }

    /// 按文件路径取色彩分布（带缓存，检查器每次切图层都会问一遍）。
    public static func stats(forFileAt path: String) -> ColorStats? {
        guard !path.isEmpty else { return nil }
        let key = path as NSString
        if let box = statsCache.object(forKey: key) { return box.stats }
        guard let cg = loadCGImage(path: path) else { return nil }
        guard let s = analyze(cg) else { return nil }
        statsCache.setObject(StatsBox(s), forKey: key)
        return s
    }

    public static func analyze(_ image: CGImage) -> ColorStats? {
        let ci = CIImage(cgImage: image)
        let ext = ci.extent
        guard ext.width >= 1, ext.height >= 1 else { return nil }

        // 3×3 宫格平均色 + 极值色，全部走 CI 面积滤镜
        var samples: [(r: Double, g: Double, b: Double)] = []
        let cols = 3, rows = 3
        let cw = ext.width / CGFloat(cols)
        let ch = ext.height / CGFloat(rows)
        if cw >= 1, ch >= 1 {
            for row in 0..<rows {
                for col in 0..<cols {
                    let rect = CGRect(x: ext.minX + CGFloat(col) * cw,
                                      y: ext.minY + CGFloat(row) * ch,
                                      width: cw, height: ch)
                    if let px = areaPixel("CIAreaAverage", ci.clampedToExtent(), rect) {
                        samples.append((px.r, px.g, px.b))
                    }
                }
            }
        }
        for name in ["CIAreaMaximum", "CIAreaMinimum"] {
            if let px = areaPixel(name, ci.clampedToExtent(), ext) {
                samples.append((px.r, px.g, px.b))
            }
        }
        if let px = areaPixel("CIAreaAverage", ci.clampedToExtent(), ext) {
            samples.append((px.r, px.g, px.b))
        }
        guard !samples.isEmpty else { return nil }

        let sats = samples.map { saturation($0.r, $0.g, $0.b) }
        let avgSat = sats.reduce(0, +) / Double(sats.count)
        let maxSat = sats.max() ?? 0

        // 色相分布：只统计「看得出来有彩」的样本（饱和 ≥ 0.12），两两取最大夹角
        let chromatic = samples.filter { saturation($0.r, $0.g, $0.b) >= 0.12 }
            .map { hue($0.r, $0.g, $0.b) }
        var spread: Double = 0
        if chromatic.count >= 2 {
            for i in 0..<chromatic.count {
                for j in (i + 1)..<chromatic.count {
                    let d = abs(chromatic[i] - chromatic[j])
                    spread = max(spread, min(d, 360 - d))
                }
            }
        }

        return ColorStats(averageSaturation: avgSat,
                          maxSaturation: maxSat,
                          hueSpreadDegrees: spread,
                          isAchromatic: maxSat < 0.10,
                          isMultiColor: maxSat >= 0.15 && spread >= 25.0)
    }

    // MARK: - 滤镜链（四种模式，一条一个，全部 Core Image）

    /// 半透明背景色（CIBlendWithAlphaMask 的 background 输入）。
    private static let clearConstant = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))

    /// 返回 nil 表示该模式没有可用输出，调用方退回原图。
    ///
    /// 关于「直接替换」为什么不是 CIColorMonochrome：
    /// CIColorMonochrome 的语义是 `out = target * luma`（亮度乘色），纯黑墨 luma=0，
    /// 换完还是黑的 —— 对「黑字 PNG 换色」完全无效。实测反例见报告。
    /// 真正的「直接替换」= 每个像素的 RGB 换成目标色、alpha 原样保留，
    /// 用 CIConstantColorGenerator + CIBlendWithAlphaMask 一步到位，同样零像素循环。
    private static func apply(_ mode: RecolorMode,
                              to ci: CIImage,
                              rgb: (r: CGFloat, g: CGFloat, b: CGFloat)) -> CIImage? {
        switch mode {
        case .auto:
            return apply(.luminance, to: ci, rgb: rgb)

        case .direct:
            // 链：CIConstantColorGenerator(目标色) + CIBlendWithAlphaMask(mask = 原图 alpha)
            return flatColor(rgb, alphaMask: ci)

        case .luminance:
            // 链：CIColorControls(saturation=0) → CIColorMatrix(out = target - (target-dark)*luma)
            // 暗墨（luma≈0）落到目标色亮部 → 黑字换色后就是目标色本身；亮部落到暗端。
            return toneMapped(ci, rgb: rgb)

        case .invert:
            // 真反相：RGB 取反、alpha 原样，**不使用目标色**。
            // 黑墨 → 白墨、白墨 → 黑墨、灰阶连续反转、彩色 → 补色，一条 CIColorInvert 全包。
            let inv = CIFilter.colorInvert()
            inv.inputImage = ci
            return inv.outputImage

        case .hueRotate:
            // 链：CIConstantColorGenerator + CIBlendWithAlphaMask → CIHueAdjust(angle=+30°)
            // 黑墨源图没有色相可转，所以先做目标色平铺，再整体旋转色相。
            guard let flat = flatColor(rgb, alphaMask: ci) else { return nil }
            let hue = CIFilter.hueAdjust()
            hue.inputImage = flat
            hue.angle = Float(hueRotateDegrees * .pi / 180.0)
            return hue.outputImage
        }
    }

    /// 平铺目标色，alpha 取原图 alpha（形状完全不变）。
    private static func flatColor(_ rgb: (r: CGFloat, g: CGFloat, b: CGFloat), alphaMask: CIImage) -> CIImage? {
        let solid = CIImage(color: CIColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1.0))
            .cropped(to: alphaMask.extent)
        let blend = CIFilter.blendWithAlphaMask()
        blend.inputImage = solid
        blend.backgroundImage = clearConstant.cropped(to: alphaMask.extent)
        blend.maskImage = alphaMask
        return blend.outputImage
    }

    /// out = target - (target - dark) * gray，dark = target * 0.35
    ///   · gray = 传入图去饱和后的 luma（CIColorControls saturation=0，只取输入 G 通道）
    ///   · 只有「明暗上色」走这条公式；反相是纯 RGB 取反，跟这里无关
    private static func toneMapped(_ ci: CIImage,
                                   rgb: (r: CGFloat, g: CGFloat, b: CGFloat)) -> CIImage? {
        let gray = CIFilter.colorControls()
        gray.inputImage = ci
        gray.saturation = 0
        gray.brightness = 0
        gray.contrast = 1
        guard let g = gray.outputImage else { return nil }

        let dark = (r: rgb.r * darkBaseFactor, g: rgb.g * darkBaseFactor, b: rgb.b * darkBaseFactor)
        let m = CIFilter.colorMatrix()
        m.inputImage = g
        // 只吃输入 G（去饱和后它就是 luma），R/B 权重为 0；alpha 原样穿透
        m.rVector = CIVector(x: 0, y: -(rgb.r - dark.r), z: 0, w: 0)
        m.gVector = CIVector(x: 0, y: -(rgb.g - dark.g), z: 0, w: 0)
        m.bVector = CIVector(x: 0, y: -(rgb.b - dark.b), z: 0, w: 0)
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        m.biasVector = CIVector(x: rgb.r, y: rgb.g, z: rgb.b, w: 0)
        return m.outputImage
    }

    // MARK: - 采样辅助

    private static func areaPixel(_ filterName: String,
                                  _ image: CIImage,
                                  _ rect: CGRect) -> (r: Double, g: Double, b: Double, a: Double)? {
        guard let f = CIFilter(name: filterName, parameters: [
            kCIInputImageKey: image,
            kCIInputExtentKey: CIVector(cgRect: rect)
        ]), let out = f.outputImage else { return nil }

        var buf = [UInt8](repeating: 0, count: 4)
        ciContext.render(out,
                         toBitmap: &buf,
                         rowBytes: 4,
                         bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                         format: .RGBA8,
                         colorSpace: srgb)
        return (Double(buf[0]) / 255.0, Double(buf[1]) / 255.0, Double(buf[2]) / 255.0, Double(buf[3]) / 255.0)
    }

    /// HSV 饱和度：premultiplied 通道被 alpha 等比缩放，色相与饱和度不受影响。
    private static func saturation(_ r: Double, _ g: Double, _ b: Double) -> Double {
        let mx = max(r, g, b), mn = min(r, g, b)
        guard mx > 0.0001 else { return 0 }
        return (mx - mn) / mx
    }

    private static func hue(_ r: Double, _ g: Double, _ b: Double) -> Double {
        let mx = max(r, g, b), mn = min(r, g, b)
        let delta = mx - mn
        guard delta > 0.0001 else { return 0 }
        var h: Double
        if mx == r {
            h = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6))
        } else if mx == g {
            h = 60 * (((b - r) / delta) + 2)
        } else {
            h = 60 * (((r - g) / delta) + 4)
        }
        if h < 0 { h += 360 }
        return h
    }

    /// NSColor → sRGB 分量（0…1）。色彩空间不认识就按 sRGB 直读。
    public static func srgbComponents(_ color: NSColor) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let c = color.usingColorSpace(.sRGB) ?? color
        func clamp(_ v: CGFloat) -> CGFloat { max(0, min(1, v)) }
        return (clamp(c.redComponent), clamp(c.greenComponent), clamp(c.blueComponent))
    }
}
