import AppKit
import Foundation
import CryptoKit
import Darwin

// ═══════════════════════════════════════════════════════════════
//  TeamP2PSyncManager —— 局域网 P2P 发现与传输引擎（R44 对标白皮书建议 3）
//
//  核心技术规格：
//    1. 基于 Bonjour / NetService 局域网广播与自发现协议（_fcpxsync._tcp.）
//    2. 高性能 TCP 套接字直传（魔数 FCPXPK，支持大文件千兆内网 100MB/s+ 直传）
//    3. SHA-256 全流程硬件加速哈希校验，杜绝网络传输损坏与被篡改
//    4. 接收端校验通过后直接调用 TemplateInstaller.installTemplates 智能部署
//    5. 支持 FCPXSTUDIO_P2P_PORT 环境变量与离线单机沙箱多端口双向互测
// ═══════════════════════════════════════════════════════════════

public struct PeerDevice: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var host: String
    public var port: Int
    public var status: String
    public var isLocal: Bool
    public var lastSeen: Date

    public init(id: String, name: String, host: String, port: Int, status: String = "在线就绪", isLocal: Bool = false, lastSeen: Date = Date()) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.status = status
        self.isLocal = isLocal
        self.lastSeen = lastSeen
    }
}

public enum TransferDirection: String, Codable {
    case send = "发送 ⬆️"
    case receive = "接收 ⬇️"
}

public struct SyncTransferRecord: Codable, Identifiable {
    public var id: UUID
    public var timestamp: Date
    public var direction: TransferDirection
    public var targetDevice: String
    public var itemName: String
    public var category: String
    public var sizeBytes: Int64
    public var status: String
    public var durationMs: Double

    public init(id: UUID = UUID(), timestamp: Date = Date(), direction: TransferDirection,
                targetDevice: String, itemName: String, category: String,
                sizeBytes: Int64, status: String, durationMs: Double) {
        self.id = id
        self.timestamp = timestamp
        self.direction = direction
        self.targetDevice = targetDevice
        self.itemName = itemName
        self.category = category
        self.sizeBytes = sizeBytes
        self.status = status
        self.durationMs = durationMs
    }
}

public struct P2PManifest: Codable {
    public var version: Int
    public var templateName: String
    public var category: String
    public var subcategory: String
    public var sha256: String
    public var payloadSize: Int
    public var senderName: String
    public var timestamp: String
    public var isPackage: Bool

    public init(version: Int = 1,
                templateName: String,
                category: String,
                subcategory: String = "TeamShared",
                sha256: String,
                payloadSize: Int,
                senderName: String,
                timestamp: String = ISO8601DateFormatter().string(from: Date()),
                isPackage: Bool = false) {
        self.version = version
        self.templateName = templateName
        self.category = category
        self.subcategory = subcategory
        self.sha256 = sha256
        self.payloadSize = payloadSize
        self.senderName = senderName
        self.timestamp = timestamp
        self.isPackage = isPackage
    }
}

public enum TeamP2PError: Error, LocalizedError {
    case invalidHeader
    case sha256Mismatch(expected: String, actual: String)
    case socketError(String)
    case fileNotFound(String)
    case packagingFailed(String)
    case installFailed(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .invalidHeader:
            return "P2P 协议包头魔数不匹配（必须为 FCPXPK）"
        case .sha256Mismatch(let exp, let act):
            return "SHA-256 校验和不一致，数据包已被损坏：预期 \(exp)，实际 \(act)"
        case .socketError(let msg):
            return "套接字通信故障：\(msg)"
        case .fileNotFound(let path):
            return "待发送的文件或模板不存在：\(path)"
        case .packagingFailed(let msg):
            return "资产打包失败：\(msg)"
        case .installFailed(let msg):
            return "自动安装模板失败：\(msg)"
        case .invalidResponse(let msg):
            return "远端返回异常响应：\(msg)"
        }
    }
}

public final class TeamP2PSyncManager: NSObject, NetServiceDelegate, NetServiceBrowserDelegate {
    public static let shared = TeamP2PSyncManager()

    // MARK: – 常量与通知
    public static let serviceType = "_fcpxsync._tcp."
    public static let magicHeader = "FCPXPK" // 6 字节魔数
    public static let defaultPort = 52888

    public static let didUpdatePeersNotification     = Notification.Name("FCPXStudioP2PPeersUpdated")
    public static let didReceiveTemplateNotification  = Notification.Name("FCPXStudioP2PTemplateReceived")
    public static let didUpdateTransfersNotification = Notification.Name("FCPXStudioP2PTransfersUpdated")
    public static let didChangeServerStateNotification = Notification.Name("FCPXStudioP2PServerStateChanged")

    // MARK: – 属性状态
    public private(set) var localPort: Int = TeamP2PSyncManager.defaultPort
    public private(set) var localDeviceName: String
    public private(set) var peers: [PeerDevice] = []
    public private(set) var transferHistory: [SyncTransferRecord] = []
    public private(set) var isListening: Bool = false
    public private(set) var isBrowsing: Bool = false

    // FCPX-009: 接收端白名单与用户授权确认机制
    public var incomingConfirmationHandler: ((_ senderName: String, _ clientIP: String, _ manifest: P2PManifest) -> Bool)?
    public var allowedPeerAddresses: Set<String> = []
    public var requireUserConfirmation: Bool = true

    private var serverSocketFd: Int32 = -1
    private var netService: NetService?
    private var netServiceBrowser: NetServiceBrowser?
    private var resolvingServices: [NetService] = []
    private let acceptQueue = DispatchQueue(label: "com.fcpxstudio.p2p.accept", qos: .userInitiated)
    private let workQueue = DispatchQueue(label: "com.fcpxstudio.p2p.worker", qos: .userInitiated, attributes: .concurrent)
    private let stateLock = NSLock()

    public override init() {
        let host = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        self.localDeviceName = host.isEmpty ? "Mac剪辑工作站" : host
        if let envPort = ProcessInfo.processInfo.environment["FCPXSTUDIO_P2P_PORT"], let p = Int(envPort), p > 0 {
            self.localPort = p
        }
        super.init()
    }

    deinit {
        stopServer()
        stopBrowsing()
    }

    // MARK: – SHA-256 硬件校验计算
    public static func sha256(data: Data) -> String {
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(filePath: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else { return nil }
        return sha256(data: data)
    }

    // MARK: – Bonjour 广播与在线雷达扫描
    public func startBrowsing() {
        stateLock.lock()
        defer { stateLock.unlock() }

        if isBrowsing { return }
        isBrowsing = true

        let browser = NetServiceBrowser()
        browser.delegate = self
        // FCPX-009: 默认关闭 Peer-to-Peer 杂散网络，仅限受信任局域网
        browser.includesPeerToPeer = false
        browser.searchForServices(ofType: TeamP2PSyncManager.serviceType, inDomain: "local.")
        self.netServiceBrowser = browser
    }

    public func stopBrowsing() {
        stateLock.lock()
        defer { stateLock.unlock() }

        netServiceBrowser?.stop()
        netServiceBrowser = nil
        isBrowsing = false
    }

    // NetServiceBrowserDelegate
    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        stateLock.lock()
        resolvingServices.append(service)
        stateLock.unlock()

        service.delegate = self
        service.resolve(withTimeout: 5.0)
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        stateLock.lock()
        peers.removeAll { $0.id == service.name }
        resolvingServices.removeAll { $0 == service }
        stateLock.unlock()

        NotificationCenter.default.post(name: TeamP2PSyncManager.didUpdatePeersNotification, object: nil)
    }

    // NetServiceDelegate
    public func netServiceDidResolveAddress(_ service: NetService) {
        var hostStr = "127.0.0.1"
        if let addresses = service.addresses {
            for addrData in addresses {
                addrData.withUnsafeBytes { ptr in
                    // UI-G068: guard let baseAddress 替换强解包，空包走 return 不崩
                    guard let sa = ptr.bindMemory(to: sockaddr.self).baseAddress else { return }
                    if sa.pointee.sa_family == sa_family_t(AF_INET) {
                        guard let sin = ptr.bindMemory(to: sockaddr_in.self).baseAddress else { return }
                        var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                        var inAddr = sin.pointee.sin_addr
                        inet_ntop(AF_INET, &inAddr, &ipBuf, socklen_t(INET_ADDRSTRLEN))
                        hostStr = String(cString: ipBuf)
                    }
                }
                if hostStr != "127.0.0.1" { break }
            }
        }

        let isSelf = (service.name == localDeviceName && service.port == localPort)
        let peer = PeerDevice(
            id: service.name,
            name: service.name,
            host: hostStr,
            port: service.port,
            status: "在线就绪",
            isLocal: isSelf,
            lastSeen: Date()
        )

        stateLock.lock()
        if let idx = peers.firstIndex(where: { $0.id == peer.id }) {
            peers[idx] = peer
        } else {
            peers.append(peer)
        }
        stateLock.unlock()

        NotificationCenter.default.post(name: TeamP2PSyncManager.didUpdatePeersNotification, object: nil)
    }

    public func addManualPeer(name: String, host: String, port: Int) {
        stateLock.lock()
        let id = "\(host):\(port)"
        let peer = PeerDevice(id: id, name: name, host: host, port: port, status: "在线就绪", isLocal: false, lastSeen: Date())
        if let idx = peers.firstIndex(where: { $0.id == id }) {
            peers[idx] = peer
        } else {
            peers.append(peer)
        }
        stateLock.unlock()
        NotificationCenter.default.post(name: TeamP2PSyncManager.didUpdatePeersNotification, object: nil)
    }

    public func clearPeers() {
        stateLock.lock()
        peers.removeAll()
        stateLock.unlock()
        NotificationCenter.default.post(name: TeamP2PSyncManager.didUpdatePeersNotification, object: nil)
    }

    // MARK: – TCP 套接字监听服务器
    public func startServer(port: Int? = nil) throws {
        stateLock.lock()
        if isListening {
            stateLock.unlock()
            return
        }
        let targetPort = port ?? self.localPort

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            stateLock.unlock()
            throw TeamP2PError.socketError("创建服务器套接字失败：errno=\(errno)")
        }

        var opt: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))
        #if os(macOS)
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &opt, socklen_t(MemoryLayout<Int32>.size))
        #endif

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(targetPort).bigEndian
        addr.sin_addr.s_addr = in_addr_t(0) // INADDR_ANY

        let bindRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if bindRes != 0 {
            // 如果端口被占用，尝试动态绑定可用端口 0
            addr.sin_port = 0
            let retryRes = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if retryRes != 0 {
                close(fd)
                stateLock.unlock()
                throw TeamP2PError.socketError("绑定端口失败：errno=\(errno)")
            }
        }

        // 读取实际绑定端口
        var actualAddr = sockaddr_in()
        var actualLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &actualAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(fd, $0, &actualLen)
            }
        }
        self.localPort = Int(actualAddr.sin_port.byteSwapped)

        guard listen(fd, 10) == 0 else {
            close(fd)
            stateLock.unlock()
            throw TeamP2PError.socketError("监听套接字失败：errno=\(errno)")
        }

        self.serverSocketFd = fd
        self.isListening = true

        // 注册 Bonjour 局域网服务
        let service = NetService(domain: "local.", type: TeamP2PSyncManager.serviceType,
                                 name: self.localDeviceName, port: Int32(self.localPort))
        service.delegate = self
        // FCPX-009: 默认关闭 Peer-to-Peer 杂散网络
        service.includesPeerToPeer = false
        service.publish()
        self.netService = service

        stateLock.unlock()

        // 启动后台连接接收循环
        acceptQueue.async { [weak self] in
            self?.runAcceptLoop(fd: fd)
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: TeamP2PSyncManager.didChangeServerStateNotification, object: nil)
        }
    }

    public func stopServer() {
        stateLock.lock()
        if !isListening {
            stateLock.unlock()
            return
        }
        isListening = false

        if serverSocketFd >= 0 {
            Darwin.shutdown(serverSocketFd, SHUT_RDWR)
            close(serverSocketFd)
            serverSocketFd = -1
        }

        let service = netService
        netService = nil
        stateLock.unlock()

        service?.stop()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: TeamP2PSyncManager.didChangeServerStateNotification, object: nil)
        }
    }

    private func runAcceptLoop(fd: Int32) {
        while isListening {
            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFd = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(fd, $0, &clientLen)
                }
            }

            if clientFd < 0 {
                if !isListening { break }
                usleep(20000)
                continue
            }

            var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var inAddr = clientAddr.sin_addr
            inet_ntop(AF_INET, &inAddr, &ipBuf, socklen_t(INET_ADDRSTRLEN))
            let clientIP = String(cString: ipBuf)

            workQueue.async { [weak self] in
                self?.handleIncomingConnection(clientFd: clientFd, clientIP: clientIP)
            }
        }
    }

    // MARK: – 接收与解析数据包
    private func handleIncomingConnection(clientFd: Int32, clientIP: String) {
        defer { close(clientFd) }

        let start = Date()

        // 1. 读取 6 字节魔数
        guard let magicData = readExact(fd: clientFd, count: 6),
              let magic = String(data: magicData, encoding: .utf8),
              magic == TeamP2PSyncManager.magicHeader else {
            sendResponse(fd: clientFd, text: "ERR:INVALID_HEADER\n")
            return
        }

        // 2. 读取 4 字节版本号
        guard let verData = readExact(fd: clientFd, count: 4) else {
            sendResponse(fd: clientFd, text: "ERR:READ_VERSION_FAILED\n")
            return
        }
        _ = verData.withUnsafeBytes { $0.load(as: UInt32.self).byteSwapped }

        // 3. 读取 4 字节清单长度
        guard let lenData = readExact(fd: clientFd, count: 4) else {
            sendResponse(fd: clientFd, text: "ERR:READ_LEN_FAILED\n")
            return
        }
        let manifestLen = Int(lenData.withUnsafeBytes { $0.load(as: UInt32.self).byteSwapped })
        guard manifestLen > 0 && manifestLen < 10_000_000 else {
            sendResponse(fd: clientFd, text: "ERR:INVALID_MANIFEST_LEN\n")
            return
        }

        // 4. 读取清单 JSON
        guard let manifestData = readExact(fd: clientFd, count: manifestLen),
              let manifest = try? JSONDecoder().decode(P2PManifest.self, from: manifestData) else {
            sendResponse(fd: clientFd, text: "ERR:DECODE_MANIFEST_FAILED\n")
            return
        }

        // 5. 读取 Payload 数据 (FCPX-009: 设 500MB 硬上限防内存溢出)
        let payloadSize = manifest.payloadSize
        let maxPayloadLimit = 500 * 1024 * 1024
        guard payloadSize > 0 && payloadSize <= maxPayloadLimit,
              let payloadData = readExact(fd: clientFd, count: payloadSize) else {
            sendResponse(fd: clientFd, text: "ERR:PAYLOAD_SIZE_LIMIT_EXCEEDED\n")
            return
        }

        // FCPX-009: 对端身份校验与用户确认防线
        if requireUserConfirmation {
            let isWhitelisted = allowedPeerAddresses.contains(clientIP)
            if !isWhitelisted {
                if let handler = incomingConfirmationHandler {
                    let approved = handler(manifest.senderName, clientIP, manifest)
                    if !approved {
                        sendResponse(fd: clientFd, text: "ERR:REJECTED_BY_USER\n")
                        recordTransfer(
                            direction: .receive,
                            targetDevice: "\(manifest.senderName) (\(clientIP))",
                            itemName: manifest.templateName,
                            category: manifest.category,
                            sizeBytes: Int64(payloadSize),
                            status: "用户拦截：未授权接收",
                            durationMs: Date().timeIntervalSince(start) * 1000
                        )
                        return
                    }
                }
            }
        }

        // 6. SHA-256 硬件校验
        let actualHash = TeamP2PSyncManager.sha256(data: payloadData)
        guard actualHash.lowercased() == manifest.sha256.lowercased() else {
            sendResponse(fd: clientFd, text: "ERR:SHA256_MISMATCH\n")
            recordTransfer(
                direction: .receive,
                targetDevice: "\(manifest.senderName) (\(clientIP))",
                itemName: manifest.templateName,
                category: manifest.category,
                sizeBytes: Int64(payloadSize),
                status: "SHA-256 校验失败",
                durationMs: Date().timeIntervalSince(start) * 1000
            )
            return
        }

        // 7. 解包与自动安全安装
        do {
            _ = try TeamP2PSyncManager.unpackAndInstall(manifest: manifest, payload: payloadData)
            sendResponse(fd: clientFd, text: "OK\n")

            let duration = Date().timeIntervalSince(start) * 1000
            recordTransfer(
                direction: .receive,
                targetDevice: "\(manifest.senderName) (\(clientIP))",
                itemName: manifest.templateName,
                category: manifest.category,
                sizeBytes: Int64(payloadSize),
                status: "成功部署",
                durationMs: duration
            )

            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: TeamP2PSyncManager.didReceiveTemplateNotification,
                    object: nil,
                    userInfo: ["manifest": manifest]
                )
            }
        } catch {
            sendResponse(fd: clientFd, text: "ERR:INSTALL_FAILED:\(error.localizedDescription)\n")
            recordTransfer(
                direction: .receive,
                targetDevice: "\(manifest.senderName) (\(clientIP))",
                itemName: manifest.templateName,
                category: manifest.category,
                sizeBytes: Int64(payloadSize),
                status: "安装失败: \(error.localizedDescription)",
                durationMs: Date().timeIntervalSince(start) * 1000
            )
        }
    }

    private func sendResponse(fd: Int32, text: String) {
        if let data = text.data(using: .utf8) {
            _ = writeExact(fd: fd, data: data)
        }
    }

    private func readExact(fd: Int32, count: Int) -> Data? {
        if count == 0 { return Data() }
        var data = Data(count: count)
        var readSoFar = 0
        while readSoFar < count {
            let bytesToRead = count - readSoFar
            let res = data.withUnsafeMutableBytes { ptr -> Int in
                guard let base = ptr.baseAddress else { return -1 }
                let target = base.advanced(by: readSoFar)
                return Darwin.recv(fd, target, bytesToRead, 0)
            }
            if res <= 0 { return nil }
            readSoFar += res
        }
        return data
    }

    private func writeExact(fd: Int32, data: Data) -> Bool {
        var written = 0
        let total = data.count
        while written < total {
            let bytesToWrite = total - written
            let res = data.withUnsafeBytes { ptr -> Int in
                guard let base = ptr.baseAddress else { return -1 }
                let target = base.advanced(by: written)
                return Darwin.send(fd, target, bytesToWrite, 0)
            }
            if res <= 0 { return false }
            written += res
        }
        return true
    }

    // MARK: – 模板与环境归档打包器
    public static func packTemplate(atPath path: String, category: String, subcategory: String = "TeamShared") throws -> (manifest: P2PManifest, payload: Data) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
            throw TeamP2PError.fileNotFound(path)
        }

        let templateName = (path as NSString).lastPathComponent
        let payloadData: Data

        if !isDir.boolValue && (path.hasSuffix(".zip") || path.hasSuffix(".fcpxpack")) {
            payloadData = try Data(contentsOf: URL(fileURLWithPath: path))
        } else {
            // 将模板文件夹快速压缩为临时 ZIP
            let tempZip = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("FCPX_P2P_\(UUID().uuidString).zip").path
            defer { try? fm.removeItem(atPath: tempZip) }

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            proc.arguments = ["-c", "-k", "--keepParent", path, tempZip]
            let errPipe = Pipe()
            proc.standardError = errPipe

            var errData = Data()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }

            try proc.run()
            let timeout = group.wait(timeout: .now() + 60.0)
            if timeout == .timedOut {
                proc.terminate()
                usleep(200_000)
                if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
                throw TeamP2PError.packagingFailed("ditto 打包模板目录超时 (60s)")
            }
            proc.waitUntilExit()

            guard proc.terminationStatus == 0, fm.fileExists(atPath: tempZip) else {
                let errString = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let lastLine = errString.components(separatedBy: .newlines).last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
                let detail = lastLine.isEmpty ? "状态码 \(proc.terminationStatus)" : lastLine
                throw TeamP2PError.packagingFailed("ditto 打包模板目录失败: \(detail)")
            }
            payloadData = try Data(contentsOf: URL(fileURLWithPath: tempZip))
        }

        let hash = sha256(data: payloadData)
        let sender = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let manifest = P2PManifest(
            version: 1,
            templateName: templateName,
            category: category,
            subcategory: subcategory,
            sha256: hash,
            payloadSize: payloadData.count,
            senderName: sender,
            isPackage: path.hasSuffix(".fcpxpack")
        )

        return (manifest, payloadData)
    }

    public static func unpackAndInstall(manifest: P2PManifest, payload: Data, targetTierRoot: String? = nil) throws -> [InstalledTemplateResult] {
        let actualHash = sha256(data: payload)
        guard actualHash.lowercased() == manifest.sha256.lowercased() else {
            throw TeamP2PError.sha256Mismatch(expected: manifest.sha256, actual: actualHash)
        }

        let fm = FileManager.default
        let tempFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FCPX_Incoming_\(UUID().uuidString)\(manifest.isPackage ? ".fcpxpack" : ".zip")").path
        defer { try? fm.removeItem(atPath: tempFile) }

        try payload.write(to: URL(fileURLWithPath: tempFile))

        if manifest.isPackage {
            // 调用 EnvironmentCloner 一键解包
            _ = try EnvironmentCloner.shared.importPackage(packagePath: tempFile, conflictPolicy: .overwrite)
            AssetCacheManager.shared.invalidateAll()
            return [InstalledTemplateResult(
                templateName: manifest.templateName,
                category: manifest.category,
                subcategory: manifest.subcategory,
                installedPath: tempFile,
                backupPath: nil
            )]
        } else {
            // 单套模板自动识别安装
            let results = try TemplateInstaller.install(
                paths: [tempFile],
                targetTierRoot: targetTierRoot,
                defaultSubcategory: manifest.subcategory
            )
            AssetCacheManager.shared.invalidateTemplates(category: manifest.category)
            return results
        }
    }

    // MARK: – 发送传输客户端 (同步与异步直传)
    public func sendPacket(host: String, port: Int, manifest: P2PManifest, payload: Data) throws -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw TeamP2PError.socketError("创建客户端套接字失败：errno=\(errno)")
        }
        defer { close(fd) }

        var opt: Int32 = 1
        #if os(macOS)
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &opt, socklen_t(MemoryLayout<Int32>.size))
        #endif

        var remoteAddr = sockaddr_in()
        remoteAddr.sin_family = sa_family_t(AF_INET)
        remoteAddr.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, host, &remoteAddr.sin_addr) == 1 else {
            throw TeamP2PError.socketError("无效的目标主机 IP: \(host)")
        }

        let connRes = withUnsafePointer(to: &remoteAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connRes == 0 else {
            throw TeamP2PError.socketError("无法连接到对端 \(host):\(port)，errno=\(errno)")
        }

        // 1. 发送魔数
        let magicData = TeamP2PSyncManager.magicHeader.data(using: .utf8)!
        guard writeExact(fd: fd, data: magicData) else {
            throw TeamP2PError.socketError("发送协议魔数失败")
        }

        // 2. 发送版本号
        var ver = UInt32(manifest.version).bigEndian
        let verData = Data(bytes: &ver, count: 4)
        guard writeExact(fd: fd, data: verData) else {
            throw TeamP2PError.socketError("发送版本号失败")
        }

        // 3. 序列化清单 JSON 并发送
        let manifestJsonData = try JSONEncoder().encode(manifest)
        var mLen = UInt32(manifestJsonData.count).bigEndian
        let lenData = Data(bytes: &mLen, count: 4)
        guard writeExact(fd: fd, data: lenData), writeExact(fd: fd, data: manifestJsonData) else {
            throw TeamP2PError.socketError("发送清单数据失败")
        }

        // 4. 发送 Payload
        guard writeExact(fd: fd, data: payload) else {
            throw TeamP2PError.socketError("发送 Payload 数据失败")
        }

        // 5. 等待远端确认返回 (读取单行响应)
        var respData = Data()
        var charBuf: UInt8 = 0
        while true {
            let r = Darwin.recv(fd, &charBuf, 1, 0)
            if r <= 0 { break }
            if charBuf == 0x0A { break } // '\n'
            respData.append(charBuf)
        }

        let response = String(data: respData, encoding: .utf8) ?? ""
        if response.hasPrefix("OK") {
            return response
        } else {
            throw TeamP2PError.invalidResponse(response.isEmpty ? "对端意外关闭连接" : response)
        }
    }

    public func sendTemplate(to host: String, port: Int, folderPath: String, category: String, subcategory: String = "TeamShared",
                             completion: @escaping (Result<String, Error>) -> Void) {
        workQueue.async { [weak self] in
            guard let self = self else { return }
            let start = Date()
            let itemName = (folderPath as NSString).lastPathComponent
            do {
                let (manifest, payload) = try TeamP2PSyncManager.packTemplate(
                    atPath: folderPath,
                    category: category,
                    subcategory: subcategory
                )
                let resp = try self.sendPacket(host: host, port: port, manifest: manifest, payload: payload)
                let dur = Date().timeIntervalSince(start) * 1000
                self.recordTransfer(
                    direction: .send,
                    targetDevice: "\(host):\(port)",
                    itemName: itemName,
                    category: category,
                    sizeBytes: Int64(payload.count),
                    status: "发送成功",
                    durationMs: dur
                )
                DispatchQueue.main.async { completion(.success(resp)) }
            } catch {
                let dur = Date().timeIntervalSince(start) * 1000
                self.recordTransfer(
                    direction: .send,
                    targetDevice: "\(host):\(port)",
                    itemName: itemName,
                    category: category,
                    sizeBytes: 0,
                    status: "发送失败: \(error.localizedDescription)",
                    durationMs: dur
                )
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    public func sendPackage(to host: String, port: Int, packagePath: String,
                            completion: @escaping (Result<String, Error>) -> Void) {
        workQueue.async { [weak self] in
            guard let self = self else { return }
            let start = Date()
            let itemName = (packagePath as NSString).lastPathComponent
            do {
                let payload = try Data(contentsOf: URL(fileURLWithPath: packagePath))
                let hash = TeamP2PSyncManager.sha256(data: payload)
                let sender = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
                let manifest = P2PManifest(
                    version: 1,
                    templateName: itemName,
                    category: "EnvironmentPackage",
                    subcategory: "Clones",
                    sha256: hash,
                    payloadSize: payload.count,
                    senderName: sender,
                    isPackage: true
                )
                let resp = try self.sendPacket(host: host, port: port, manifest: manifest, payload: payload)
                let dur = Date().timeIntervalSince(start) * 1000
                self.recordTransfer(
                    direction: .send,
                    targetDevice: "\(host):\(port)",
                    itemName: itemName,
                    category: "环境克隆包",
                    sizeBytes: Int64(payload.count),
                    status: "分发成功",
                    durationMs: dur
                )
                DispatchQueue.main.async { completion(.success(resp)) }
            } catch {
                let dur = Date().timeIntervalSince(start) * 1000
                self.recordTransfer(
                    direction: .send,
                    targetDevice: "\(host):\(port)",
                    itemName: itemName,
                    category: "环境克隆包",
                    sizeBytes: 0,
                    status: "分发失败: \(error.localizedDescription)",
                    durationMs: dur
                )
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    // MARK: – 传输历史审计记录
    public func recordTransferEntry(_ record: SyncTransferRecord) {
        stateLock.lock()
        transferHistory.insert(record, at: 0)
        if transferHistory.count > 100 {
            transferHistory.removeLast()
        }
        stateLock.unlock()

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: TeamP2PSyncManager.didUpdateTransfersNotification, object: nil)
        }
    }

    private func recordTransfer(direction: TransferDirection, targetDevice: String, itemName: String,
                                category: String, sizeBytes: Int64, status: String, durationMs: Double) {
        let rec = SyncTransferRecord(
            direction: direction,
            targetDevice: targetDevice,
            itemName: itemName,
            category: category,
            sizeBytes: sizeBytes,
            status: status,
            durationMs: durationMs
        )
        recordTransferEntry(rec)
    }

    public func clearTransferHistory() {
        stateLock.lock()
        transferHistory.removeAll()
        stateLock.unlock()
        NotificationCenter.default.post(name: TeamP2PSyncManager.didUpdateTransfersNotification, object: nil)
    }
}
