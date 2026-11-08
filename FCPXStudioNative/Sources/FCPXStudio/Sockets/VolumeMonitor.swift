import AppKit
import Foundation

// ═══════════════════════════════════════════════════════════════
//  VolumeMonitor —— 外置卷热插拔监听插口（Sockets 层）
//  职责：将 AppKit 的 NSWorkspace 卷通知桥接至纯 Foundation 的 Model 层
// ═══════════════════════════════════════════════════════════════

public final class VolumeMonitor {
    public static let shared = VolumeMonitor()

    private let lock = NSRecursiveLock()
    private var isMonitoring = false
    private var observerTokens: [Any] = []

    public init() {}

    /// 启动卷挂载/卸载监听（通过 NSWorkspace.shared.notificationCenter，幂等安全）
    public func startMonitoring() {
        lock.lock()
        defer { lock.unlock() }
        guard !isMonitoring else { return }
        isMonitoring = true

        let center = NSWorkspace.shared.notificationCenter
        let unmountToken = center.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleVolumeNotification(notification, isMounted: false)
        }

        let mountToken = center.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleVolumeNotification(notification, isMounted: true)
        }

        observerTokens = [unmountToken, mountToken]
    }

    public func stopMonitoring() {
        lock.lock()
        defer { lock.unlock() }
        guard isMonitoring else { return }
        let center = NSWorkspace.shared.notificationCenter
        for token in observerTokens {
            center.removeObserver(token)
        }
        observerTokens.removeAll()
        isMonitoring = false
    }

    private func extractVolumePath(from notification: Notification) -> String? {
        if let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
            return (url.path as NSString).standardizingPath
        }
        if let urlStr = notification.userInfo?["NSWorkspaceVolumeURLUserInfoKey"] as? URL {
            return (urlStr.path as NSString).standardizingPath
        }
        if let path = notification.userInfo?["NSDevicePath"] as? String {
            return (path as NSString).standardizingPath
        }
        return nil
    }

    private func handleVolumeNotification(_ notification: Notification, isMounted: Bool) {
        guard let volumePath = extractVolumePath(from: notification) else { return }
        TemplateMigrator.handleVolumeEvent(volumePath: volumePath, isMounted: isMounted)
    }
}
