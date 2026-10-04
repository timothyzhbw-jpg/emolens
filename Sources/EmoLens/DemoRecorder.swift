import AppKit
import AVFoundation
import EmoLensCore
import OSLog
import ScreenCaptureKit

private let log = Logger(subsystem: "io.github.emolens", category: "recorder")

/// 录演示视频：EMOLENS_RECORD=输出.mov 时启用。先运行演示聊天窗口（EmoLensDemo），再用 `open` 启动 EmoLens。
/// 只录演示窗口和 EmoLens 面板这两个窗口，屏幕上别的东西不会进画面。
/// 演示窗口的消息按它自己的节奏到达（DEMO_INTERVAL）；之后切到粘贴模式，演示危机信号和一句玩笑话。
enum DemoRecording {
    static var requested: URL? {
        ProcessInfo.processInfo.environment["EMOLENS_RECORD"].map { URL(fileURLWithPath: $0) }
    }
}

@available(macOS 15, *)
@MainActor
final class DemoRecorder: NSObject, SCRecordingOutputDelegate {
    let output: URL
    let monitor: Monitor
    let settings: AppSettings
    let panel: NSPanel
    private var stream: SCStream?
    /// SCStreamConfiguration.backgroundColor 不持有颜色（assign），要自己留着，否则配置被复制时会崩溃。
    private let background = CGColor(red: 0.91, green: 0.92, blue: 0.94, alpha: 1)
    private var finished: CheckedContinuation<Void, Never>?

    init(output: URL, monitor: Monitor, settings: AppSettings, panel: NSPanel) {
        self.output = output
        self.monitor = monitor
        self.settings = settings
        self.panel = panel
    }

    private var environment: [String: String] { ProcessInfo.processInfo.environment }
    /// 实时部分录多久：演示脚本 7 步 × 间隔，再留一点时间给最后一条分析。
    private var liveSeconds: Double { Double(environment["EMOLENS_RECORD_LIVE_SECONDS"] ?? "") ?? 112 }

    func run() async {
        do {
            guard let demo = try await findDemoWindow() else {
                log.error("demo window not found")
                NSApp.terminate(nil)
                return
            }
            // 看演示窗口，框住聊天区域（去掉窗口标题栏和联系人名字那一条）
            settings.engine = .llm   // 演示默认引擎；录完由调用方恢复原来的设置
            panel.appearance = NSAppearance(named: .aqua)   // 和浅色的演示聊天窗口统一
            settings.windowID = demo.windowID
            settings.region = CGRect(x: 0, y: 0.11, width: 1, height: 0.89)
            monitor.restart()
            if !monitor.isRunning { monitor.start() }
            // 窗口刚打开时有缩放动画，这时读到的位置不准：等它停稳再读一次
            try await Task.sleep(for: .seconds(2))
            try await placePanel(besideWindow: demo.windowID)
            try await startRecording(demoID: demo.windowID)
            log.notice("recording started")

            try await Task.sleep(for: .seconds(liveSeconds))
            // 粘贴模式：一条危机信号，一条网络玩笑（不该被标成危机）
            settings.manualMode = true
            monitor.pause()
            for (text, hold) in [("Mia: sometimes i feel like nobody would even notice if i disappeared", 10.0),
                                 ("Mia: LMAO I'm dead 💀 that meme is too accurate", 9.0)] {
                monitor.manualTranscript = text
                try await Task.sleep(for: .seconds(2))
                monitor.analyzeManual(text)
                try await Task.sleep(for: .seconds(1))
                while monitor.analyzing { try await Task.sleep(for: .milliseconds(200)) }
                try await Task.sleep(for: .seconds(hold))
            }
            try await stopRecording()
            log.notice("recording finished: \(self.output.path, privacy: .public)")
        } catch {
            log.error("recording failed: \(error.localizedDescription, privacy: .public)")
        }
        NSApp.terminate(nil)
    }

    private func findDemoWindow() async throws -> SCWindow? {
        for _ in 0..<40 {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            // 只认像窗口那么大的（同一个进程还有菜单栏之类的小窗口）；DEMO_ON_TOP 时演示窗口在浮动层级
            if let window = content.windows.first(where: {
                (0...8).contains($0.windowLayer) && $0.frame.width > 240 && $0.frame.height > 240
                    && (($0.owningApplication?.applicationName ?? "").contains("EmoLensDemo") || ($0.title ?? "").hasPrefix("EmoLens Demo"))
            }) {
                return window
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }

    /// 面板放在演示窗口右边，顶端对齐。SCWindow 的坐标原点在主屏左上，NSWindow 的在左下。
    /// 放好后再核对一遍，两个窗口不能叠在一起（叠了就录不清楚聊天内容）。
    private func placePanel(besideWindow id: CGWindowID) async throws {
        guard let main = NSScreen.screens.first else { return }
        for attempt in 1...3 {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let demo = content.windows.first(where: { $0.windowID == id }) else { return }
            let frame = demo.frame
            let top = main.frame.height - frame.minY
            panel.setFrame(NSRect(x: frame.maxX + 20, y: top - 700, width: 372, height: 700), display: true)
            panel.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(800))
            let check = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let demoNow = check.windows.first { $0.windowID == id }?.frame ?? frame
            let panelNow = check.windows.first { $0.windowID == CGWindowID(panel.windowNumber) }?.frame ?? .zero
            log.notice("place panel (try \(attempt)): demo \(NSStringFromRect(demoNow), privacy: .public), panel \(NSStringFromRect(panelNow), privacy: .public)")
            if panelNow.minX >= demoNow.maxX { return }
        }
        throw RecorderError("面板和演示窗口叠在一起，放不开")
    }

    private func startRecording(demoID: CGWindowID) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let ids: Set<CGWindowID> = [demoID, CGWindowID(panel.windowNumber)]
        let windows = content.windows.filter { ids.contains($0.windowID) }
        guard windows.count == 2 else { throw RecorderError("没找到两个窗口（找到 \(windows.count) 个）") }
        let area = windows.map(\.frame).reduce(windows[0].frame) { $0.union($1) }.insetBy(dx: -28, dy: -28)
        log.notice("windows \(windows.map { "\($0.windowID) \(NSStringFromRect($0.frame))" }.joined(separator: ", "), privacy: .public); displays \(content.displays.map { NSStringFromRect($0.frame) }.joined(separator: ", "), privacy: .public)")
        guard let display = content.displays.first(where: { $0.frame.intersects(area) }) ?? content.displays.first else {
            throw RecorderError("没找到屏幕")
        }

        let config = SCStreamConfiguration()
        let scale = NSScreen.screens.first(where: { $0.frame.width == display.frame.width })?.backingScaleFactor ?? 2
        let source = area.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY).intersection(
            CGRect(origin: .zero, size: display.frame.size))
        config.sourceRect = source
        config.width = Int(source.width * scale) / 2 * 2
        config.height = Int(source.height * scale) / 2 * 2
        config.showsCursor = false
        config.backgroundColor = background
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.capturesAudio = false

        let stream = SCStream(filter: SCContentFilter(display: display, including: windows), configuration: config, delegate: nil)
        let recording = SCRecordingOutputConfiguration()
        recording.outputURL = output
        recording.outputFileType = .mov
        recording.videoCodecType = .h264
        try? FileManager.default.removeItem(at: output)
        try stream.addRecordingOutput(SCRecordingOutput(configuration: recording, delegate: self))
        try await stream.startCapture()
        self.stream = stream
    }

    private func stopRecording() async throws {
        guard let stream else { return }
        await withCheckedContinuation { continuation in
            finished = continuation
            Task { try? await stream.stopCapture() }
        }
        self.stream = nil
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            self.finished?.resume()
            self.finished = nil
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        log.error("recording output failed: \(error.localizedDescription, privacy: .public)")
        Task { @MainActor in
            self.finished?.resume()
            self.finished = nil
        }
    }
}

struct RecorderError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
