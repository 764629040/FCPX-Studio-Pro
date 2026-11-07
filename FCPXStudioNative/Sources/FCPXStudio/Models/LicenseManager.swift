import Foundation
import IOKit
import CommonCrypto
import AppKit

// ═══════════════════════════════════════════════════════════════
//  LicenseManager
//  FCPX Studio Pro 硬件唯一特征码与商用授权分级管理核心引擎 (R52)
// ═══════════════════════════════════════════════════════════════

public final class LicenseManager {
    public static let shared = LicenseManager()

    public static let didChangeLicenseStatusNotification = Notification.Name("LicenseManagerDidChangeLicenseStatusNotification")

    public static let masterSecretSalt = "FCPX_STUDIO_PRO_R52_COMMERCIAL_EDITION_2026_MASTER_SECRET_KEY"
    public static let devBypassKeys: Set<String> = [
        "DEV-TEST-PASS-2026",
        "DEVELOPER-PRO-LICENSE-TESTING",
        "FCPX-DEV-PRO-UNLIMITED"
    ]
    private let userDefaultsKey = "FCPX_Studio_Pro_Commercial_License_Key"

    public private(set) var machineCode: String = ""
    public private(set) var activeLicenseKey: String?
    public private(set) var isProLicensed: Bool = false

    public init() {
        self.machineCode = Self.generateMachineCode()
        loadPersistedLicense()
    }

    // MARK: - 硬件特征码提取与格式化 (MAC-XXXX-XXXX-XXXX)

    public static func generateMachineCode() -> String {
        let uuid = getPlatformUUID() ?? "FCPX-FALLBACK-UUID-2026"
        let mac = getPrimaryMACAddress() ?? "00:00:00:00:00:00"
        let raw = "\(uuid):\(mac)".trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let hash = sha256(raw)
        let cleanHex = String(hash.prefix(12)).uppercased()
        
        let p1 = cleanHex.prefix(4)
        let p2 = cleanHex.dropFirst(4).prefix(4)
        let p3 = cleanHex.dropFirst(8).prefix(4)
        return "MAC-\(p1)-\(p2)-\(p3)"
    }

    public static func getPlatformUUID() -> String? {
        let dev = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard dev != 0 else { return nil }
        defer { IOObjectRelease(dev) }
        guard let property = IORegistryEntryCreateCFProperty(dev, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String else {
            return nil
        }
        return property.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func getPrimaryMACAddress() -> String? {
        var masterPort: mach_port_t = 0
        guard IOMainPort(mach_port_t(MACH_PORT_NULL), &masterPort) == KERN_SUCCESS else { return nil }
        guard let matchingDict = IOBSDNameMatching(masterPort, 0, "en0") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(masterPort, matchingDict, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            var parent: io_object_t = 0
            if IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS {
                defer { IOObjectRelease(parent) }
                if let data = IORegistryEntryCreateCFProperty(parent, "IOMACAddress" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data {
                    return data.map { String(format: "%02X", $0) }.joined(separator: ":")
                }
            }
        }
        return nil
    }

    // MARK: - 签名与校验算法

    public static func computeLicenseKey(forMachine machine: String, salt: String = masterSecretSalt) -> String {
        let cleanMachine = machine.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let hmacStr = hmacSHA256(key: salt, data: cleanMachine)
        let cleanSig = String(hmacStr.prefix(12)).uppercased()
        let p1 = cleanSig.prefix(4)
        let p2 = cleanSig.dropFirst(4).prefix(4)
        let p3 = cleanSig.dropFirst(8).prefix(4)
        return "FCPX-LIC-\(p1)-\(p2)-\(p3)"
    }

    public func verifyLicense(key: String, forMachine machine: String) -> Bool {
        let cleanKey = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let cleanMachine = machine.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        if Self.devBypassKeys.contains(cleanKey) {
            return true
        }

        guard cleanKey.hasPrefix("FCPX-LIC-") else { return false }
        let expected = Self.computeLicenseKey(forMachine: cleanMachine, salt: Self.masterSecretSalt)
        return cleanKey == expected
    }

    // MARK: - 激活与状态管理

    @discardableResult
    public func activate(key: String) -> (success: Bool, message: String) {
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if verifyLicense(key: clean, forMachine: machineCode) {
            self.activeLicenseKey = clean
            self.isProLicensed = true
            UserDefaults.standard.set(clean, forKey: userDefaultsKey)
            UserDefaults.standard.synchronize()
            NotificationCenter.default.post(name: Self.didChangeLicenseStatusNotification, object: self)
            return (true, "商业旗舰版已成功激活！全量高级功能已全数解锁。")
        } else {
            return (false, "授权代码校验未通过，请检查机器码与许可证代码是否匹配。")
        }
    }

    public func deactivate() {
        self.activeLicenseKey = nil
        self.isProLicensed = false
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        UserDefaults.standard.synchronize()
        NotificationCenter.default.post(name: Self.didChangeLicenseStatusNotification, object: self)
    }

    public func setDeveloperProOverride(_ enabled: Bool) {
        if enabled {
            _ = activate(key: "DEV-TEST-PASS-2026")
        } else {
            deactivate()
        }
    }

    private func loadPersistedLicense() {
        if let key = UserDefaults.standard.string(forKey: userDefaultsKey), !key.isEmpty {
            if verifyLicense(key: key, forMachine: machineCode) {
                self.activeLicenseKey = key
                self.isProLicensed = true
                return
            }
        }
        self.activeLicenseKey = nil
        self.isProLicensed = false
    }

    // MARK: - 分级权限拦截网关 (Feature Gate)

    public func checkPermission(feature: ProFeature) -> (allowed: Bool, message: String) {
        if isProLicensed {
            return (true, "功能已解锁")
        }
        return (false, "未激活商业授权，\(feature.displayName)已锁定。请先激活商业授权。")
    }

    public enum ProFeature {
        case deleteTemplate
        case batchExport
        case storageMigration
        case workspaceProfileSwitch
        case teamSyncP2P

        public var displayName: String {
            switch self {
            case .deleteTemplate: return "模板与分组移入废纸篓"
            case .batchExport: return "全套模板批量渲染导出"
            case .storageMigration: return "外置存储一键搬家与软链接迁移"
            case .workspaceProfileSwitch: return "多工作区情境隔离快速切换"
            case .teamSyncP2P: return "局域网 P2P 团队资产分发与克隆"
            }
        }
    }

    // MARK: - 内部辅助方法

    private static func sha256(_ input: String) -> String {
        guard let data = input.data(using: .utf8) else { return "" }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02X", $0) }.joined()
    }

    private static func hmacSHA256(key: String, data: String) -> String {
        guard let keyData = key.data(using: .utf8),
              let dataToSign = data.data(using: .utf8) else { return "" }
        var macData = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
        macData.withUnsafeMutableBytes { macBytes in
            keyData.withUnsafeBytes { keyBytes in
                dataToSign.withUnsafeBytes { dataBytes in
                    CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256),
                           keyBytes.baseAddress,
                           keyData.count,
                           dataBytes.baseAddress,
                           dataToSign.count,
                           macBytes.baseAddress)
                }
            }
        }
        return macData.map { String(format: "%02X", $0) }.joined()
    }
}
