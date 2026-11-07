import AppKit
import CoreText
import Foundation

// ═══════════════════════════════════════════════════════════════
//  FontInstaller —— 字体一键补全与系统注册安装助手（R46）
//
//  核心能力：
//    1. 原生支持 .ttf / .otf / .ttc / .dfont 字体文件智能识别
//    2. 基于 CoreText CTFontManagerRegisterFontsForURL 实现免提权即刻用户级注册
//    3. 支持批量静默安装与提取 PostScript/Family 字体元数据
//    4. 注册成功后自动广播通知，驱动主窗口重新校验并消除缺字橙色警告
//    5. 具备 unregister 逆向清理能力，供测试与资源卸载使用
// ═══════════════════════════════════════════════════════════════

public struct FontInstallItemResult: Equatable {
    public let url: URL
    public let postscriptName: String?
    public let familyName: String?
    public let isSuccess: Bool
    public let errorMessage: String?

    public init(url: URL, postscriptName: String?, familyName: String?, isSuccess: Bool, errorMessage: String?) {
        self.url = url
        self.postscriptName = postscriptName
        self.familyName = familyName
        self.isSuccess = isSuccess
        self.errorMessage = errorMessage
    }
}

public struct FontBatchInstallReport {
    public let totalAttempted: Int
    public let successCount: Int
    public let failedCount: Int
    public let items: [FontInstallItemResult]

    public init(totalAttempted: Int, successCount: Int, failedCount: Int, items: [FontInstallItemResult]) {
        self.totalAttempted = totalAttempted
        self.successCount = successCount
        self.failedCount = failedCount
        self.items = items
    }
}

public final class FontInstaller {
    public static let shared = FontInstaller()

    public static let didRegisterFontNotification = NSNotification.Name("FCPXStudioDidRegisterFontNotification")
    public static let supportedExtensions: Set<String> = ["ttf", "otf", "ttc", "dfont"]

    public init() {}

    // MARK: – 格式判定与文件探测

    public static func isFontFile(at path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
    }

    public static func isFontURL(_ url: URL) -> Bool {
        return isFontFile(at: url.path)
    }

    /// 递归扫描指定目录下的全部字体文件
    public static func scanFonts(in directory: String) -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []
        guard let en = fm.enumerator(atPath: directory) else { return results }
        while let rel = en.nextObject() as? String {
            let full = (directory as NSString).appendingPathComponent(rel)
            if isFontFile(at: full) {
                results.append(URL(fileURLWithPath: full))
            }
        }
        return results
    }

    // MARK: – 元数据提取

    public func extractFontMetadata(at url: URL) -> (postscriptName: String?, familyName: String?) {
        if let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
           let first = descriptors.first {
            let psName = CTFontDescriptorCopyAttribute(first, kCTFontNameAttribute) as? String
            let famName = CTFontDescriptorCopyAttribute(first, kCTFontFamilyNameAttribute) as? String
            return (psName, famName)
        }
        return (nil, nil)
    }

    // MARK: – 字体注册与注销

    /// 单个字体注册（默认使用 .user 作用域，注册为当前用户全系统可用）
    @discardableResult
    public func registerFont(at url: URL, scope: CTFontManagerScope = .user) -> FontInstallItemResult {
        var cfError: Unmanaged<CFError>?
        let success = CTFontManagerRegisterFontsForURL(url as CFURL, scope, &cfError)
        let meta = extractFontMetadata(at: url)

        var errMsg: String? = nil
        if !success {
            if let err = cfError?.takeRetainedValue() {
                errMsg = CFErrorCopyDescription(err) as String
            } else {
                errMsg = "未知字体注册错误"
            }
        }

        let itemResult = FontInstallItemResult(
            url: url,
            postscriptName: meta.postscriptName,
            familyName: meta.familyName,
            isSuccess: success,
            errorMessage: errMsg
        )

        if success {
            NotificationCenter.default.post(name: FontInstaller.didRegisterFontNotification, object: url)
        }

        return itemResult
    }

    /// 批量字体注册
    @discardableResult
    public func registerFonts(at urls: [URL], scope: CTFontManagerScope = .user) -> FontBatchInstallReport {
        var items: [FontInstallItemResult] = []
        var successCount = 0
        var failedCount = 0

        for url in urls {
            let res = registerFont(at: url, scope: scope)
            items.append(res)
            if res.isSuccess {
                successCount += 1
            } else {
                failedCount += 1
            }
        }

        return FontBatchInstallReport(
            totalAttempted: urls.count,
            successCount: successCount,
            failedCount: failedCount,
            items: items
        )
    }

    /// 单个字体注销（支持测试与撤销清理）
    @discardableResult
    public func unregisterFont(at url: URL, scope: CTFontManagerScope = .user) -> Bool {
        var cfError: Unmanaged<CFError>?
        let success = CTFontManagerUnregisterFontsForURL(url as CFURL, scope, &cfError)
        return success
    }
}
