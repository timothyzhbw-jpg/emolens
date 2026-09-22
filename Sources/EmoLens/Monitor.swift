import CoreGraphics
import EmoLensCore
import Foundation
import OSLog
import ScreenCaptureKit

private let log = Logger(subsystem: "io.github.emolens", category: "monitor")

/// 截图 → OCR → 解析消息 → 发现对方新消息 → 分析。整个循环跑在主 actor 上，重活放到后台。
@MainActor
final class Monitor: ObservableObject {
    enum Status: Equatable {
        case paused, watching, noWindow, needsPermission, failed(String)

        var text: String {
            switch self {
            case .paused: "已暂停"
            case .watching: "正在看微信"
            case .noWindow: "没找到微信窗口"
            case .needsPermission: "需要屏幕录制权限"
            case .failed(let message): message
            }
        }
    }

    @Published private(set) var status: Status = .paused
    @Published private(set) var reports: [EmotionReport] = []
    @Published private(set) var analyzing = false
    @Published private(set) var analysisError: String?
    @Published private(set) var preview: CGImage?
    @Published private(set) var windowName = ""

    let settings: AppSettings
    private var tracker = MessageTracker()
    private var loop: Task<Void, Never>?
    private var signature: FrameSignature?
    private var pending: (context: [ChatMessage], latest: ChatMessage)?
    private var failed: (context: [ChatMessage], latest: ChatMessage)?
    private var previewRunning = false
    private var analyzedKeys: [String] = []

    init(settings: AppSettings) {
        self.settings = settings
    }

    var isRunning: Bool { loop != nil || previewRunning }
    var canRetry: Bool { failed != nil && !analyzing }

    /// 重新分析上一条失败的消息。
    func retry() {
        guard let job = failed else { return }
        failed = nil
        analysisError = nil
        pending = job
        Task { await drain() }
    }

    func start() {
        guard loop == nil else { return }
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            status = .needsPermission
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                try? await Task.sleep(for: .seconds(max(0.5, self.settings.interval)))
            }
        }
    }

    func pause() {
        loop?.cancel()
        loop = nil
        status = .paused
    }

    /// 换了窗口或区域后，从头开始比对。
    func restart() {
        tracker = MessageTracker()
        signature = nil
        if isRunning { pause(); start() }
    }

    /// 预览渲染用：直接设定界面状态，不截图也不分析。
    func loadPreview(status: Status, reports: [EmotionReport], analyzing: Bool = false,
                     windowName: String = "微信", error: String? = nil, preview: CGImage? = nil) {
        self.status = status
        self.reports = reports
        self.analyzing = analyzing
        self.windowName = windowName
        self.analysisError = error
        self.preview = preview
        self.previewRunning = status == .watching
        if error != nil { failed = ([], ChatMessage(speaker: .them, text: "", top: 0)) }
    }

    func clearHistory() {
        reports.removeAll()
        analyzedKeys.removeAll()
    }

    private func tick() async {
        do {
            guard let window = try await WindowCapture.find(id: settings.windowID) else {
                if status != .noWindow { log.info("window not found, id=\(self.settings.windowID)") }
                status = .noWindow
                return
            }
            windowName = [window.owningApplication?.applicationName, window.title]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            let frame = try await WindowCapture.capture(window)
            preview = frame
            status = .watching
            guard let chat = WindowCapture.crop(frame, to: settings.region),
                  let current = FrameSignature(chat), current.differs(from: signature) else { return }
            signature = current
            let lines = try await Task.detached(priority: .userInitiated) { try TextRecognizer.recognize(chat) }.value
            let messages = ChatParser.parse(lines)
            let them = messages.filter { $0.speaker == .them }.count
            log.info("frame changed: \(chat.width)x\(chat.height)px, \(lines.count) OCR lines, \(messages.count) messages (\(them) from them)")
            handle(tracker.update(messages))
        } catch {
            log.error("tick failed: \(error.localizedDescription, privacy: .public)")
            status = Self.isPermissionError(error) ? .needsPermission : .failed(error.localizedDescription)
        }
    }

    private func handle(_ event: TrackerEvent) {
        let messages: [ChatMessage]
        switch event {
        case .unchanged: return
        case .appended(let new): messages = new
        case .reset(let visible): messages = visible
        }
        log.info("tracker \(String(describing: event).prefix(8), privacy: .public): \(messages.count) messages")
        if let latest = messages.last(where: { $0.speaker == .them }) { enqueue(latest) }
    }

    private func enqueue(_ latest: ChatMessage) {
        let context = contextBefore(latest)
        let key = MessageTracker.normalize((context.last?.text ?? "") + "|" + latest.text)
        guard !analyzedKeys.contains(key) else { return }
        log.info("queue analysis: \(latest.text, privacy: .private)")
        analyzedKeys = Array((analyzedKeys + [key]).suffix(100))
        pending = (context, latest)
        if !analyzing { Task { await drain() } }
    }

    private func contextBefore(_ latest: ChatMessage) -> [ChatMessage] {
        let history = tracker.context(limit: 12)
        let prefix = history.lastIndex(of: latest).map { Array(history[..<$0]) } ?? history
        return Array(prefix.suffix(10))
    }

    /// 一次只分析一条；分析期间来的新消息只保留最新的一条。
    private func drain() async {
        analyzing = true
        defer { analyzing = false }
        while let job = pending {
            pending = nil
            do {
                let report = SafetyNet.apply(to: try await settings.makeAnalyzer().analyze(context: job.context, latest: job.latest))
                reports.insert(report, at: 0)
                Self.debugLog(report)
                reports = Array(reports.prefix(30))
                analysisError = nil
                failed = nil
                log.info("analysis done in \(Int(report.latencyMs)) ms by \(report.engine, privacy: .public)")
            } catch {
                log.error("analysis failed: \(error.localizedDescription, privacy: .public)")
                analysisError = describe(error)
                failed = job
            }
        }
    }

    /// 仅当设置了环境变量 EMOLENS_LOG 时，把结果追加写进该文件（调试用，默认不落盘）。
    private static func debugLog(_ report: EmotionReport) {
        guard let path = ProcessInfo.processInfo.environment["EMOLENS_LOG"],
              var line = try? JSONEncoder().encode(report) else { return }
        line.append(0x0A)
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: line)
        }
    }

    /// 把常见的网络错误翻成用户看得懂、知道怎么办的话。
    private func describe(_ error: Error) -> String {
        let engine = settings.engine
        let fix = engine == .systemOne ? "请确认 Kev 服务在运行。"
            : engine == .combined ? "请确认 Ollama（ollama serve）和 Kev 都在运行。" : "请先在终端运行 ollama serve。"
        switch (error as? URLError)?.code {
        case .cannotConnectToHost?, .cannotFindHost?, .networkConnectionLost?, .notConnectedToInternet?:
            return "连不上分析引擎（\(engine.name)）。" + fix
        case .timedOut?:
            return "分析超时了：模型可能还在加载，或者内存不够。稍后点「重试」。"
        default:
            return error.localizedDescription
        }
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let e = error as NSError
        return e.domain == SCStreamErrorDomain && e.code == SCStreamError.userDeclined.rawValue
    }
}
