#!/usr/bin/env swift

import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import Darwin

public enum PlaybackMode: Equatable {
    case video(URL)
    case fire
    case plasma
}

public struct RGBColor: Equatable {
    public let r: UInt8
    public let g: UInt8
    public let b: UInt8
    
    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }
}

public struct TerminalSize {
    public let cols: Int
    public let rows: Int
    
    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }
    
    public static func current() -> TerminalSize {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0 && ws.ws_row > 0 {
            return TerminalSize(cols: max(10, Int(ws.ws_col)), rows: max(4, Int(ws.ws_row)))
        }
        return TerminalSize(cols: 80, rows: 24)
    }
}

public struct PlayerConfig {
    public var mode: PlaybackMode
    public var targetFps: Double
    public var duration: Double?
    public var useHalfBlocks: Bool
    
    public init(mode: PlaybackMode = .fire, targetFps: Double = 60.0, duration: Double? = nil, useHalfBlocks: Bool = true) {
        self.mode = mode
        self.targetFps = targetFps
        self.duration = duration
        self.useHalfBlocks = useHalfBlocks
    }
    
    public static func parse(arguments: [String]) -> PlayerConfig {
        var mode: PlaybackMode = .fire
        var targetFps: Double = 60.0
        var duration: Double? = nil
        var useHalfBlocks = true
        var videoPath: String? = nil
        var explicitFire = false
        var explicitPlasma = false
        
        var i = 1
        while i < arguments.count {
            let arg = arguments[i]
            switch arg {
            case "--fps":
                if i + 1 < arguments.count, let fps = Double(arguments[i + 1]), fps > 0 {
                    targetFps = fps
                    i += 1
                }
            case "--duration":
                if i + 1 < arguments.count, let dur = Double(arguments[i + 1]), dur > 0 {
                    duration = dur
                    i += 1
                }
            case "--fire", "--demo":
                explicitFire = true
            case "--plasma":
                explicitPlasma = true
            case "--full", "--full-cells":
                useHalfBlocks = false
            case "--half", "--half-blocks":
                useHalfBlocks = true
            case "--help", "-h":
                printUsage()
                Darwin.exit(0)
            default:
                if !arg.hasPrefix("-") && videoPath == nil {
                    videoPath = arg
                }
            }
            i += 1
        }
        
        if explicitPlasma {
            mode = .plasma
        } else if explicitFire {
            mode = .fire
        } else if let path = videoPath {
            let url: URL
            if path.hasPrefix("file://") || path.hasPrefix("http://") || path.hasPrefix("https://") {
                url = URL(string: path) ?? URL(fileURLWithPath: path)
            } else {
                url = URL(fileURLWithPath: path)
            }
            mode = .video(url)
        } else {
            mode = .fire
        }
        
        return PlayerConfig(mode: mode, targetFps: targetFps, duration: duration, useHalfBlocks: useHalfBlocks)
    }
    
    private static func printUsage() {
        let msg = """
        Usage: term_video_player [<video_file>] [options]

        Modes:
          <video_file>          Play video file (.mp4, .mov, etc.) via AVFoundation
          --fire, --demo        Full-screen procedural DOOM-fire stress test (default)
          --plasma              Full-screen procedural plasma animation stress test

        Options:
          --fps <num>           Target framerate in FPS (default: 60)
          --duration <sec>      Auto-exit after specified duration in seconds
          --full                Use full cell blocks instead of half-blocks (2x throughput)
          --help, -h            Show this help information

        """
        print(msg)
    }
}

public struct TelemetryStats {
    public var targetFps: Double
    public var totalFrames: UInt64
    public var droppedFrames: UInt64
    public var totalRenderTimeNs: UInt64
    public var minFps: Double
    public var maxFps: Double
    
    public init(targetFps: Double) {
        self.targetFps = targetFps
        self.totalFrames = 0
        self.droppedFrames = 0
        self.totalRenderTimeNs = 0
        self.minFps = Double.infinity
        self.maxFps = 0.0
    }
    
    public mutating func recordFrame(renderDurationNs: UInt64, wasDropped: Bool) {
        totalFrames += 1
        if wasDropped {
            droppedFrames += 1
        }
        totalRenderTimeNs += renderDurationNs
        
        if renderDurationNs > 0 {
            let fps = 1_000_000_000.0 / Double(renderDurationNs)
            if fps < minFps { minFps = fps }
            if fps > maxFps { maxFps = fps }
        }
    }
    
    public func statusLine(currentFps: Double, frameDurationMs: Double) -> String {
        let dropRate = totalFrames > 0 ? (Double(droppedFrames) / Double(totalFrames)) * 100.0 : 0.0
        return String(
            format: "FPS: %5.1f / %-4.0f | Frames: %5llu | Dropped: %llu (%4.1f%%) | FrameTime: %5.2f ms",
            currentFps,
            targetFps,
            totalFrames,
            droppedFrames,
            dropRate,
            frameDurationMs
        )
    }
    
    public func summaryReport() -> String {
        let meanFps: Double
        if totalFrames > 0 && totalRenderTimeNs > 0 {
            meanFps = Double(totalFrames) / (Double(totalRenderTimeNs) / 1_000_000_000.0)
        } else {
            meanFps = 0.0
        }
        let safeMinFps = minFps.isInfinite ? 0.0 : minFps
        let dropRate = totalFrames > 0 ? (Double(droppedFrames) / Double(totalFrames)) * 100.0 : 0.0
        
        var report = "=== Video & TrueColor Telemetry Summary ===\n"
        report += String(format: "Target FPS:       %.1f\n", targetFps)
        report += String(format: "Total Frames:     %llu\n", totalFrames)
        report += String(format: "Dropped Frames:   %llu (%.2f%%)\n", droppedFrames, dropRate)
        report += String(format: "Mean FPS:         %.2f\n", meanFps)
        report += String(format: "Min FPS:          %.2f\n", safeMinFps)
        report += String(format: "Max FPS:          %.2f\n", maxFps)
        return report
    }
}

public final class VideoStreamer: @unchecked Sendable {
    public let url: URL
    private let asset: AVURLAsset
    private var videoTrack: AVAssetTrack?
    private var reader: AVAssetReader?
    private var trackOutput: AVAssetReaderTrackOutput?
    
    public init?(url: URL, targetSize: TerminalSize) {
        self.url = url
        self.asset = AVURLAsset(url: url)
        
        var foundTrack: AVAssetTrack? = nil
        let group = DispatchGroup()
        group.enter()
        self.asset.loadTracks(withMediaType: .video) { tracks, _ in
            foundTrack = tracks?.first
            group.leave()
        }
        group.wait()
        
        guard let track = foundTrack else {
            return nil
        }
        self.videoTrack = track
        
        if !setupReader() {
            return nil
        }
    }
    
    @discardableResult
    private func setupReader() -> Bool {
        guard let track = videoTrack else { return false }
        if let r = reader {
            r.cancelReading()
        }
        guard let r = try? AVAssetReader(asset: asset) else { return false }
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        if r.canAdd(out) {
            r.add(out)
        } else {
            return false
        }
        if !r.startReading() {
            return false
        }
        self.reader = r
        self.trackOutput = out
        return true
    }
    
    public func nextFrameRGB(targetSize: TerminalSize) -> [RGBColor]? {
        guard let output = trackOutput else { return nil }
        
        var sampleBuffer = output.copyNextSampleBuffer()
        if sampleBuffer == nil {
            // Loop video cleanly
            if !setupReader() { return nil }
            sampleBuffer = trackOutput?.copyNextSampleBuffer()
            if sampleBuffer == nil { return nil }
        }
        
        guard let sBuf = sampleBuffer,
              let imageBuffer = CMSampleBufferGetImageBuffer(sBuf) else {
            return nil
        }
        
        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(imageBuffer) else {
            return nil
        }
        
        let bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer)
        let bufferWidth = CVPixelBufferGetWidth(imageBuffer)
        let bufferHeight = CVPixelBufferGetHeight(imageBuffer)
        let ptr = baseAddress.assumingMemoryBound(to: UInt8.self)
        
        let outWidth = targetSize.cols
        let outHeight = targetSize.rows
        var result = [RGBColor]()
        result.reserveCapacity(outWidth * outHeight)
        
        for y in 0..<outHeight {
            let srcY = (y * bufferHeight) / outHeight
            let rowOffset = srcY * bytesPerRow
            for x in 0..<outWidth {
                let srcX = (x * bufferWidth) / outWidth
                let pixelOffset = rowOffset + (srcX * 4)
                let b = ptr[pixelOffset]
                let g = ptr[pixelOffset + 1]
                let r = ptr[pixelOffset + 2]
                result.append(RGBColor(r: r, g: g, b: b))
            }
        }
        return result
    }
}

public final class DoomFireSim {
    public private(set) var width: Int
    public private(set) var height: Int
    private var firePixels: [UInt8]
    private var rngState: UInt32 = 0x87654321
    
    private static let firePalette: [RGBColor] = [
        RGBColor(r: 0x07, g: 0x07, b: 0x07),
        RGBColor(r: 0x1F, g: 0x07, b: 0x07),
        RGBColor(r: 0x2F, g: 0x0F, b: 0x07),
        RGBColor(r: 0x47, g: 0x0F, b: 0x07),
        RGBColor(r: 0x57, g: 0x17, b: 0x07),
        RGBColor(r: 0x67, g: 0x1F, b: 0x07),
        RGBColor(r: 0x77, g: 0x1F, b: 0x07),
        RGBColor(r: 0x8F, g: 0x27, b: 0x07),
        RGBColor(r: 0x9F, g: 0x2F, b: 0x07),
        RGBColor(r: 0xAF, g: 0x3F, b: 0x07),
        RGBColor(r: 0xBF, g: 0x47, b: 0x07),
        RGBColor(r: 0xC7, g: 0x47, b: 0x07),
        RGBColor(r: 0xDF, g: 0x4F, b: 0x07),
        RGBColor(r: 0xDF, g: 0x57, b: 0x07),
        RGBColor(r: 0xDF, g: 0x57, b: 0x07),
        RGBColor(r: 0xD7, g: 0x5F, b: 0x07),
        RGBColor(r: 0xD7, g: 0x67, b: 0x0F),
        RGBColor(r: 0xCF, g: 0x6F, b: 0x0F),
        RGBColor(r: 0xCF, g: 0x77, b: 0x0F),
        RGBColor(r: 0xCF, g: 0x7F, b: 0x0F),
        RGBColor(r: 0xCF, g: 0x87, b: 0x17),
        RGBColor(r: 0xC7, g: 0x87, b: 0x17),
        RGBColor(r: 0xC7, g: 0x8F, b: 0x17),
        RGBColor(r: 0xC7, g: 0x97, b: 0x1F),
        RGBColor(r: 0xBF, g: 0x9F, b: 0x1F),
        RGBColor(r: 0xBF, g: 0x9F, b: 0x1F),
        RGBColor(r: 0xBF, g: 0xA7, b: 0x27),
        RGBColor(r: 0xBF, g: 0xA7, b: 0x27),
        RGBColor(r: 0xBF, g: 0xAF, b: 0x2F),
        RGBColor(r: 0xB7, g: 0xAF, b: 0x2F),
        RGBColor(r: 0xB7, g: 0xB7, b: 0x2F),
        RGBColor(r: 0xB7, g: 0xB7, b: 0x37),
        RGBColor(r: 0xCF, g: 0xCF, b: 0x6F),
        RGBColor(r: 0xDF, g: 0xDF, b: 0x9F),
        RGBColor(r: 0xEF, g: 0xEF, b: 0xC7),
        RGBColor(r: 0xFF, g: 0xFF, b: 0xFF),
        RGBColor(r: 0xFF, g: 0xFF, b: 0xFF)
    ]
    
    public init(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
        let total = self.width * self.height
        self.firePixels = [UInt8](repeating: 0, count: total)
        resetBottomRow()
    }
    
    private func resetBottomRow() {
        let bottomStart = (height - 1) * width
        for x in 0..<width {
            firePixels[bottomStart + x] = 36
        }
    }
    
    public func resize(width: Int, height: Int) {
        let w = max(1, width)
        let h = max(1, height)
        if self.width == w && self.height == h { return }
        self.width = w
        self.height = h
        self.firePixels = [UInt8](repeating: 0, count: w * h)
        resetBottomRow()
    }
    
    @inline(__always)
    private func xorshift32() -> UInt32 {
        rngState ^= rngState << 13
        rngState ^= rngState >> 17
        rngState ^= rngState << 5
        return rngState
    }
    
    public func step() -> [RGBColor] {
        let total = firePixels.count
        for x in 0..<width {
            for y in 1..<height {
                let fromIdx = y * width + x
                let pixel = firePixels[fromIdx]
                if pixel == 0 {
                    let toIdx = fromIdx - width
                    if toIdx >= 0 {
                        firePixels[toIdx] = 0
                    }
                } else {
                    let rand = Int(xorshift32() & 3)
                    let decay = UInt8(rand & 1)
                    let toIdx = fromIdx - width - rand + 1
                    if toIdx >= 0 && toIdx < total {
                        firePixels[toIdx] = pixel > decay ? (pixel - decay) : 0
                    }
                }
            }
        }
        
        var result = [RGBColor]()
        result.reserveCapacity(total)
        let pal = Self.firePalette
        let maxIdx = pal.count - 1
        for p in firePixels {
            let idx = min(Int(p), maxIdx)
            result.append(pal[idx])
        }
        return result
    }
}

public final class PlasmaSim {
    public private(set) var width: Int
    public private(set) var height: Int
    private var time: Double = 0.0
    
    public init(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
    }
    
    public func resize(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
    }
    
    public func step() -> [RGBColor] {
        time += 0.04
        let w = Double(width)
        let h = Double(height)
        var result = [RGBColor]()
        result.reserveCapacity(width * height)
        
        for y in 0..<height {
            let dy = Double(y)
            let v1 = sin(dy * 0.12 + time)
            for x in 0..<width {
                let dx = Double(x)
                let v2 = sin(dx * 0.12 + time * 1.5)
                let v3 = sin((dx + dy) * 0.08 + time)
                let cx = dx - w * 0.5
                let cy = dy - h * 0.5
                let dist = sqrt(cx * cx + cy * cy)
                let v4 = sin(dist * 0.1 + time * 1.8)
                
                let v = (v1 + v2 + v3 + v4) * 0.25
                let r = UInt8(clamping: Int((sin(v * .pi) * 0.5 + 0.5) * 255.0))
                let g = UInt8(clamping: Int((cos(v * .pi) * 0.5 + 0.5) * 255.0))
                let b = UInt8(clamping: Int((sin(v * .pi + 2.0) * 0.5 + 0.5) * 255.0))
                result.append(RGBColor(r: r, g: g, b: b))
            }
        }
        return result
    }
}

public struct ANSIFormatter {
    @inline(__always)
    private static func appendUInt8(_ val: UInt8, to bytes: inout [UInt8]) {
        if val >= 100 {
            bytes.append(48 + val / 100)
            bytes.append(48 + (val / 10) % 10)
            bytes.append(48 + val % 10)
        } else if val >= 10 {
            bytes.append(48 + val / 10)
            bytes.append(48 + val % 10)
        } else {
            bytes.append(48 + val)
        }
    }
    
    public static func formatHalfBlocks(pixels: [RGBColor], width: Int, height: Int, overlay: String?) -> String {
        let textRows = (height + 1) / 2
        var buffer = [UInt8]()
        buffer.reserveCapacity(width * textRows * 25 + 256)
        
        // Cursor home \033[H
        buffer.append(contentsOf: [0x1B, 0x5B, 0x48])
        
        var lastFg: RGBColor? = nil
        var lastBg: RGBColor? = nil
        
        for tr in 0..<textRows {
            let topY = tr * 2
            let botY = topY + 1
            let topRowOffset = topY * width
            let botRowOffset = botY * width
            
            for col in 0..<width {
                let topColor = (topRowOffset + col < pixels.count) ? pixels[topRowOffset + col] : RGBColor(r: 0, g: 0, b: 0)
                let botColor = (botY < height && botRowOffset + col < pixels.count) ? pixels[botRowOffset + col] : RGBColor(r: 0, g: 0, b: 0)
                
                if lastFg != topColor {
                    // \033[38;2;R;G;Bm
                    buffer.append(contentsOf: [0x1B, 0x5B, 0x33, 0x38, 0x3B, 0x32, 0x3B])
                    appendUInt8(topColor.r, to: &buffer)
                    buffer.append(0x3B)
                    appendUInt8(topColor.g, to: &buffer)
                    buffer.append(0x3B)
                    appendUInt8(topColor.b, to: &buffer)
                    buffer.append(0x6D)
                    lastFg = topColor
                }
                
                if lastBg != botColor {
                    // \033[48;2;R;G;Bm
                    buffer.append(contentsOf: [0x1B, 0x5B, 0x34, 0x38, 0x3B, 0x32, 0x3B])
                    appendUInt8(botColor.r, to: &buffer)
                    buffer.append(0x3B)
                    appendUInt8(botColor.g, to: &buffer)
                    buffer.append(0x3B)
                    appendUInt8(botColor.b, to: &buffer)
                    buffer.append(0x6D)
                    lastBg = botColor
                }
                
                // UTF-8 bytes for '▀' (U+2580)
                buffer.append(contentsOf: [0xE2, 0x96, 0x80])
            }
            
            // Reset at end of line \033[0m\n
            buffer.append(contentsOf: [0x1B, 0x5B, 0x30, 0x6D, 0x0A])
            lastFg = nil
            lastBg = nil
        }
        
        if let ov = overlay {
            // \033[0m + overlay + \033[K (no newline on last terminal line to avoid scrolling)
            buffer.append(contentsOf: [0x1B, 0x5B, 0x30, 0x6D])
            buffer.append(contentsOf: ov.utf8)
            buffer.append(contentsOf: [0x1B, 0x5B, 0x4B])
        }
        
        return String(decoding: buffer, as: UTF8.self)
    }
    
    public static func formatFullCells(pixels: [RGBColor], width: Int, height: Int, overlay: String?) -> String {
        var buffer = [UInt8]()
        buffer.reserveCapacity(width * height * 20 + 256)
        
        // Cursor home \033[H
        buffer.append(contentsOf: [0x1B, 0x5B, 0x48])
        
        var lastBg: RGBColor? = nil
        
        for y in 0..<height {
            let rowOffset = y * width
            for x in 0..<width {
                let color = (rowOffset + x < pixels.count) ? pixels[rowOffset + x] : RGBColor(r: 0, g: 0, b: 0)
                if lastBg != color {
                    // \033[48;2;R;G;Bm
                    buffer.append(contentsOf: [0x1B, 0x5B, 0x34, 0x38, 0x3B, 0x32, 0x3B])
                    appendUInt8(color.r, to: &buffer)
                    buffer.append(0x3B)
                    appendUInt8(color.g, to: &buffer)
                    buffer.append(0x3B)
                    appendUInt8(color.b, to: &buffer)
                    buffer.append(0x6D)
                    lastBg = color
                }
                buffer.append(0x20) // ' '
            }
            buffer.append(contentsOf: [0x1B, 0x5B, 0x30, 0x6D, 0x0A])
            lastBg = nil
        }
        
        if let ov = overlay {
            buffer.append(contentsOf: [0x1B, 0x5B, 0x30, 0x6D])
            buffer.append(contentsOf: ov.utf8)
            buffer.append(contentsOf: [0x1B, 0x5B, 0x4B])
        }
        
        return String(decoding: buffer, as: UTF8.self)
    }
}

public final class SignalHandler: @unchecked Sendable {
    nonisolated(unsafe) private static var cleanupCallback: (() -> Void)? = nil
    nonisolated(unsafe) private static var isRestored = false
    nonisolated(unsafe) public static var shouldExit = false
    
    public static func setup(cleanup: @escaping () -> Void) {
        cleanupCallback = cleanup
        
        Darwin.signal(SIGINT) { _ in
            SignalHandler.shouldExit = true
            SignalHandler.restoreTerminal()
            SignalHandler.cleanupCallback?()
            Darwin.exit(0)
        }
        Darwin.signal(SIGTERM) { _ in
            SignalHandler.shouldExit = true
            SignalHandler.restoreTerminal()
            SignalHandler.cleanupCallback?()
            Darwin.exit(0)
        }
    }
    
    public static func restoreTerminal() {
        if !isRestored {
            isRestored = true
            let resetSeq = "\u{1b}[?25h\u{1b}[0m\n"
            resetSeq.utf8CString.withUnsafeBufferPointer { buf in
                _ = Darwin.write(STDOUT_FILENO, buf.baseAddress!, buf.count - 1)
            }
        }
    }
    
    public static func clear() {
        cleanupCallback = nil
    }
}

private final class StatsBox: @unchecked Sendable {
    var stats: TelemetryStats
    init(stats: TelemetryStats) {
        self.stats = stats
    }
}

public final class Engine {
    public let config: PlayerConfig
    
    public init(config: PlayerConfig) {
        self.config = config
    }
    
    public func start() {
        let box = StatsBox(stats: TelemetryStats(targetFps: config.targetFps))
        
        SignalHandler.setup { [box] in
            print("\n" + box.stats.summaryReport())
        }
        
        // Hide cursor and clear screen
        let initSeq = "\u{1b}[?25l\u{1b}[2J\u{1b}[H"
        initSeq.utf8CString.withUnsafeBufferPointer { buf in
            _ = Darwin.write(STDOUT_FILENO, buf.baseAddress!, buf.count - 1)
        }
        
        let initialSize = TerminalSize.current()
        let initialTextRows = max(1, initialSize.rows - 1)
        let initialCols = max(1, initialSize.cols)
        let initialPixelHeight = config.useHalfBlocks ? (initialTextRows * 2) : initialTextRows
        
        var streamer: VideoStreamer? = nil
        var fireSim: DoomFireSim? = nil
        var plasmaSim: PlasmaSim? = nil
        
        switch config.mode {
        case .video(let url):
            streamer = VideoStreamer(url: url, targetSize: TerminalSize(cols: initialCols, rows: initialPixelHeight))
            if streamer == nil {
                SignalHandler.restoreTerminal()
                FileHandle.standardError.write(Data("Error: Unable to load video at \(url.path)\n".utf8))
                Darwin.exit(1)
            }
        case .fire:
            fireSim = DoomFireSim(width: initialCols, height: initialPixelHeight)
        case .plasma:
            plasmaSim = PlasmaSim(width: initialCols, height: initialPixelHeight)
        }
        
        let targetIntervalSec = 1.0 / config.targetFps
        let targetIntervalNs = UInt64(targetIntervalSec * 1_000_000_000.0)
        let startTimeNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        var smoothedFps = config.targetFps
        var lastOverlayUpdateNs = startTimeNs
        var cachedOverlay = box.stats.statusLine(currentFps: config.targetFps, frameDurationMs: 0.0)
        
        while !SignalHandler.shouldExit {
            let nowNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
            if let dur = config.duration {
                let elapsedSec = Double(nowNs - startTimeNs) / 1_000_000_000.0
                if elapsedSec >= dur {
                    break
                }
            }
            
            let currentSize = TerminalSize.current()
            let textRows = max(1, currentSize.rows - 1)
            let cols = max(1, currentSize.cols)
            let pixelHeight = config.useHalfBlocks ? (textRows * 2) : textRows
            
            if let fire = fireSim, (fire.width != cols || fire.height != pixelHeight) {
                fire.resize(width: cols, height: pixelHeight)
            }
            if let plasma = plasmaSim, (plasma.width != cols || plasma.height != pixelHeight) {
                plasma.resize(width: cols, height: pixelHeight)
            }
            
            let frameStartNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
            
            let framePixels: [RGBColor]?
            switch config.mode {
            case .video:
                framePixels = streamer?.nextFrameRGB(targetSize: TerminalSize(cols: cols, rows: pixelHeight))
                if framePixels == nil {
                    SignalHandler.shouldExit = true
                    break
                }
            case .fire:
                framePixels = fireSim?.step()
            case .plasma:
                framePixels = plasmaSim?.step()
            }
            
            guard let pixels = framePixels else { break }
            
            let workNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - frameStartNs
            let workMs = Double(workNs) / 1_000_000.0
            
            let frameString: String
            if config.useHalfBlocks {
                frameString = ANSIFormatter.formatHalfBlocks(pixels: pixels, width: cols, height: pixelHeight, overlay: cachedOverlay)
            } else {
                frameString = ANSIFormatter.formatFullCells(pixels: pixels, width: cols, height: pixelHeight, overlay: cachedOverlay)
            }
            
            frameString.utf8CString.withUnsafeBufferPointer { buf in
                _ = Darwin.write(STDOUT_FILENO, buf.baseAddress!, buf.count - 1)
            }
            
            let computeAndWriteNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - frameStartNs
            let wasDropped = computeAndWriteNs > targetIntervalNs
            
            if computeAndWriteNs < targetIntervalNs {
                let sleepNs = targetIntervalNs - computeAndWriteNs
                var ts = timespec(tv_sec: Int(sleepNs / 1_000_000_000), tv_nsec: Int(sleepNs % 1_000_000_000))
                nanosleep(&ts, nil)
            }
            
            let totalFrameNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - frameStartNs
            box.stats.recordFrame(renderDurationNs: totalFrameNs, wasDropped: wasDropped)
            
            let endNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
            let instantFps = totalFrameNs > 0 ? (1_000_000_000.0 / Double(totalFrameNs)) : config.targetFps
            smoothedFps = (smoothedFps * 0.85) + (instantFps * 0.15)
            
            if endNs - lastOverlayUpdateNs >= 100_000_000 {
                cachedOverlay = box.stats.statusLine(currentFps: smoothedFps, frameDurationMs: workMs)
                lastOverlayUpdateNs = endNs
            }
        }
        
        SignalHandler.clear()
        SignalHandler.restoreTerminal()
        print("\n" + box.stats.summaryReport())
    }
}

// Entrypoint
let config = PlayerConfig.parse(arguments: CommandLine.arguments)
let engine = Engine(config: config)
engine.start()
