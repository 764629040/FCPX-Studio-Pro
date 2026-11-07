import AppKit
import AVFoundation
import Foundation

// ═══════════════════════════════════════════════════════════════
//  AudioManager —— 影视级音效库扫描、PCM 波形提取与音频试听引擎
//  对标基准：/Applications/嘉星插件管理 2.app (FxAudioWaveformView & AudioList)
// ═══════════════════════════════════════════════════════════════

public struct AudioItem: Identifiable, Equatable {
    public let id: UUID
    public let name: String
    public let path: String
    public let category: String
    public let duration: Double
    public let sampleRate: Double
    public let channels: Int
    public let fileSizeBytes: Int64
    public var waveformAmplitudes: [Float]?

    public var durationFormatted: String {
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        let millis = Int((duration.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%02d:%02d.%01d", mins, secs, millis)
    }

    public var fileSizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
    }

    public init(id: UUID = UUID(),
                name: String,
                path: String,
                category: String,
                duration: Double,
                sampleRate: Double,
                channels: Int,
                fileSizeBytes: Int64,
                waveformAmplitudes: [Float]? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.category = category
        self.duration = duration
        self.sampleRate = sampleRate
        self.channels = channels
        self.fileSizeBytes = fileSizeBytes
        self.waveformAmplitudes = waveformAmplitudes
    }
}

public final class AudioManager: NSObject, AVAudioPlayerDelegate {
    public static let shared = AudioManager()

    public private(set) var defaultSearchPaths: [String] = [
        "/Library/Audio/Apple Loops/Apple/Final Cut Pro Sound Effects",
        "/Volumes/SD/音效库",
        "/System/Library/Sounds",
        ("~/Music/Audio Music Apps" as NSString).expandingTildeInPath
    ]

    private var player: AVAudioPlayer?
    private var progressTimer: Timer?

    public private(set) var currentPlayingItem: AudioItem?
    public var isPlaying: Bool {
        return player?.isPlaying ?? false
    }

    public var onPlaybackProgress: ((Double) -> Void)?
    public var onPlaybackFinished: (() -> Void)?

    private var waveformCache = [String: [Float]]()

    public override init() {
        super.init()
    }

    // MARK: – 扫描发现

    /// 扫描内置与外部音效库目录，提取音频元数据
    public func scan(customPaths: [String]? = nil) -> [AudioItem] {
        let fm = FileManager.default
        let pathsToScan = (customPaths ?? defaultSearchPaths).filter { fm.fileExists(atPath: $0) }
        var results: [AudioItem] = []
        var seenPaths = Set<String>()

        let supportedExts: Set<String> = ["caf", "wav", "m4a", "mp3", "aiff", "aif", "flac", "aac"]

        for root in pathsToScan {
            guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: root),
                                                 includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                                 options: [.skipsHiddenFiles]) else {
                continue
            }

            for case let fileURL as URL in enumerator {
                let ext = fileURL.pathExtension.lowercased()
                if supportedExts.contains(ext) {
                    let path = fileURL.path
                    if seenPaths.contains(path) { continue }
                    seenPaths.insert(path)

                    let name = fileURL.deletingPathExtension().lastPathComponent
                    let category = fileURL.deletingLastPathComponent().lastPathComponent
                    let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

                    let meta = extractMetadata(url: fileURL)

                    let item = AudioItem(
                        name: name,
                        path: path,
                        category: category.isEmpty ? "通用" : category,
                        duration: meta.duration,
                        sampleRate: meta.sampleRate,
                        channels: meta.channels,
                        fileSizeBytes: Int64(size)
                    )
                    results.append(item)
                }
            }
        }

        results.sort {
            if $0.category != $1.category {
                return $0.category.localizedStandardCompare($1.category) == .orderedAscending
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return results
    }

    /// 异步扫描音效库，切入后台 GCD 线程，自动命中/填充 AssetCacheManager
    public func scanAsync(customPaths: [String]? = nil, completion: @escaping ([AudioItem]) -> Void) {
        if let cached = AssetCacheManager.shared.getAudios() {
            DispatchQueue.main.async {
                completion(cached)
            }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let items = self.scan(customPaths: customPaths)
            AssetCacheManager.shared.setAudios(items)
            DispatchQueue.main.async {
                completion(items)
            }
        }
    }

    /// 提取音频元数据（时长、采样率、声道数）
    public func extractMetadata(url: URL) -> (duration: Double, sampleRate: Double, channels: Int) {
        if let audioFile = try? AVAudioFile(forReading: url) {
            let format = audioFile.processingFormat
            let frameCount = Double(audioFile.length)
            let rate = format.sampleRate
            let duration = rate > 0 ? (frameCount / rate) : 0
            return (duration, rate, Int(format.channelCount))
        }

        // 备选方案：使用 AVURLAsset 读取
        let asset = AVURLAsset(url: url)
        let duration = CMTimeGetSeconds(asset.duration)
        return (duration.isNaN ? 0 : duration, 44100.0, 2)
    }

    // MARK: – 声学波形图提取 (PCM Peak Downsampling)

    /// 提取 128 点归一化对称波形振幅数组
    public func extractWaveform(from url: URL, samplesCount: Int = 128) -> [Float] {
        let path = url.path
        if let cached = waveformCache[path] {
            return cached
        }

        guard let file = try? AVAudioFile(forReading: url) else {
            return generateSyntheticWaveform(count: samplesCount)
        }

        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return generateSyntheticWaveform(count: samplesCount)
        }

        do {
            try file.read(into: buffer)
        } catch {
            return generateSyntheticWaveform(count: samplesCount)
        }

        guard let channelData = buffer.floatChannelData else {
            return generateSyntheticWaveform(count: samplesCount)
        }

        let channel0 = channelData[0]
        let channelCount = Int(format.channelCount)
        let samplesPerBucket = max(1, Int(frameCount) / samplesCount)
        var amplitudes = [Float]()
        amplitudes.reserveCapacity(samplesCount)

        for bucket in 0..<samplesCount {
            let start = bucket * samplesPerBucket
            let end = min(Int(frameCount), (bucket + 1) * samplesPerBucket)
            var maxVal: Float = 0

            if start < end {
                for i in start..<end {
                    let v0 = abs(channel0[i])
                    if v0 > maxVal { maxVal = v0 }

                    if channelCount > 1 {
                        let v1 = abs(channelData[1][i])
                        if v1 > maxVal { maxVal = v1 }
                    }
                }
            }
            amplitudes.append(maxVal)
        }

        let peak = amplitudes.max() ?? 1.0
        let normalized = (peak > 0.0001) ? amplitudes.map { min(1.0, $0 / peak) } : amplitudes
        waveformCache[path] = normalized
        return normalized
    }

    private func generateSyntheticWaveform(count: Int) -> [Float] {
        return (0..<count).map { i in
            let phase = Float(i) / Float(count) * .pi * 4
            return abs(sin(phase) * 0.7 + 0.2)
        }
    }

    // MARK: – 播放控制

    /// 播放指定音频项，并启动实时进度回调
    public func play(item: AudioItem,
                     onProgress: ((Double) -> Void)? = nil,
                     onFinish: (() -> Void)? = nil) {
        stop()

        self.currentPlayingItem = item
        self.onPlaybackProgress = onProgress
        self.onPlaybackFinished = onFinish

        let fileURL = URL(fileURLWithPath: item.path)
        do {
            player = try AVAudioPlayer(contentsOf: fileURL)
            player?.delegate = self
            player?.prepareToPlay()
            player?.play()

            startProgressTimer()
        } catch {
            print("播放失败: \(error)")
            stop()
        }
    }

    public func pause() {
        player?.pause()
        stopProgressTimer()
    }

    public func resume() {
        player?.play()
        startProgressTimer()
    }

    public func stop() {
        player?.stop()
        player = nil
        currentPlayingItem = nil
        stopProgressTimer()
        onPlaybackProgress?(0.0)
    }

    public func seek(to ratio: Double) {
        guard let p = player else { return }
        let targetTime = p.duration * max(0.0, min(1.0, ratio))
        p.currentTime = targetTime
        onPlaybackProgress?(max(0.0, min(1.0, ratio)))
    }

    // MARK: – Progress Timer

    private func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            guard let self = self, let p = self.player, p.duration > 0 else { return }
            let progress = p.currentTime / p.duration
            self.onPlaybackProgress?(progress)
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    // MARK: – AVAudioPlayerDelegate

    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        stopProgressTimer()
        onPlaybackProgress?(1.0)
        onPlaybackFinished?()
        currentPlayingItem = nil
    }
}
