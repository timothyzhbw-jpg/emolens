import AppKit
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
        case paused, watching, noWindow(chosen: Bool), windowHidden(String), needsPermission, failed(String)

        var text: String {
            switch self {
            case .paused: "已暂停"
            case .watching: "正在看微信"
            case .noWindow(let chosen): chosen ? "选定的窗口不见了，请在设置里重新选" : "没找到微信窗口，请先打开微信"
            case .windowHidden(let name): "\(name) 被最小化了，点程序坞把它恢复"
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
    /// 本地模型的状态：是否正在启动，以及启动结果。
    @Published private(set) var startingOllama = false
    @Published private(set) var ollamaStatus: OllamaLauncher.Status?

    let settings: AppSettings
    let memory: ContactMemoryStore
    /// 从标题栏认出来的对方名字；换聊天时会变。
    @Published private(set) var detectedContact: String?
    /// 用户手动设置的名字，只对当前这个聊天有效。
    @Published var manualContact: String?
    /// 记忆有改动时加一，让界面刷新。
    @Published private(set) var memoryVersion = 0
    private var tracker = MessageTracker()
    private var loop: Task<Void, Never>?
    private var signature: FrameSignature?
    private typealias Job = (context: [ChatMessage], latest: ChatMessage, contact: String?)
    private var pending: Job?
    private var failed: Job?
    private var previewRunning = false
    private var analyzedKeys: [String] = []
    private var ollamaChecked = false
    private var ollamaRetried = false
    private var warmedUp = false
    /// 找到的窗口先缓存 10 秒：列举全部窗口比截一张图还贵，没必要每 1.5 秒做一次。
    private var cachedWindow: SCWindow?
    private var cachedAt = Date.distantPast
    /// 屏幕睡眠、锁屏或切换用户时暂停截屏。
    private var suspended = false
    private var observers: [NSObjectProtocol] = []
    /// 被监控窗口自己的应用名和标题（识别联系人时排除）。
    private var windowTitles: [String] = []

    init(settings: AppSettings, memory: ContactMemoryStore = ContactMemoryStore()) {
        self.settings = settings
        self.memory = memory
        let center = NSWorkspace.shared.notificationCenter
        for (name, value) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.sessionDidResignActiveNotification, true),
                              (NSWorkspace.screensDidWakeNotification, false), (NSWorkspace.sessionDidBecomeActiveNotification, false)] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspended = value }
            })
        }
    }

    /// 下一次截屏前等多久：找不到窗口、没权限、屏幕睡着时放慢，省电。
    private var nextDelay: Double {
        let base = max(0.5, settings.interval)
        switch status {
        case .watching: return suspended ? 5 : base
        default: return max(base, 4)
        }
    }

    var currentContact: String? { manualContact ?? detectedContact }

    // MARK: - 联系人记忆

    func contactMemory(_ name: String) -> ContactMemory { memory.memory(for: name) }

    func editMemory(_ name: String, _ change: (inout ContactMemory) -> Void) {
        memory.update(name, change)
        memoryVersion += 1
    }

    /// 用户确认记住 AI 建议的事。
    func remember(_ text: String, for name: String, source: ContactMemory.Note.Source = .ai) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        editMemory(name) { $0.notes.append(.init(text: trimmed, source: source)) }
    }

    func forget(_ name: String) {
        memory.forget(name)
        memoryVersion += 1
    }

    func forgetAll() {
        memory.forgetAll()
        memoryVersion += 1
    }

    /// 当前聊天对象的关系：先看联系人记忆里设的，没有就用面板上的全局选择。
    func relationship(for contact: String?) -> String {
        contact.flatMap { memory.memory(for: $0).relationship } ?? settings.relationship
    }

    var isRunning: Bool { loop != nil || previewRunning }

    /// 新手引导用：窗口是否就绪，以及没就绪时的短提示。
    var windowFound: Bool {
        switch status {
        case .noWindow, .windowHidden, .needsPermission: false
        default: !windowName.isEmpty
        }
    }

    var windowHint: String {
        switch status {
        case .noWindow: "没找到"
        case .windowHidden: "被最小化了"
        default: "查找中"
        }
    }
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
                if !self.suspended { await self.tick() }
                try? await Task.sleep(for: .seconds(self.nextDelay))
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
        cachedWindow = nil
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
        self.detectedContact = reports.first?.contact
        self.previewRunning = status == .watching
        if error != nil { failed = ([], ChatMessage(speaker: .them, text: "", top: 0), nil) }
    }

    func clearHistory() {
        reports.removeAll()
        analyzedKeys.removeAll()
    }

    private func tick() async {
        do {
            let window: SCWindow
            if let cached = cachedWindow, Date().timeIntervalSince(cachedAt) < 10 {
                window = cached
            } else {
                switch try await WindowCapture.find(id: settings.windowID) {
                case .found(let found):
                    window = found
                    cachedWindow = found
                    cachedAt = Date()
                case .hidden(let name):
                    if status != .windowHidden(name) { log.notice("window hidden: \(name, privacy: .private)") }
                    status = .windowHidden(name)
                    return
                case .missing:
                    let next = Status.noWindow(chosen: settings.windowID != 0)
                    if status != next { log.notice("window missing, id=\(self.settings.windowID)") }
                    status = next
                    return
                }
                windowName = WindowCapture.name(of: window)
                windowTitles = [window.owningApplication?.applicationName, window.title].compactMap { $0 }
            }
            let frame: CGImage
            do {
                frame = try await WindowCapture.capture(window)
            } catch {
                cachedWindow = nil   // 窗口可能被关掉或最小化了，下一轮重新找
                throw error
            }
            preview = frame
            status = .watching
            guard let chat = WindowCapture.crop(frame, to: settings.region),
                  let current = FrameSignature(chat), current.differs(from: signature) else { return }
            signature = current
            let lines = try await Task.detached(priority: .userInitiated) { try TextRecognizer.recognize(chat) }.value
            let messages = ChatParser.parse(lines)
            let them = messages.filter { $0.speaker == .them }.count
            log.notice("frame changed: \(chat.width)x\(chat.height)px, \(lines.count) OCR lines, \(messages.count) messages (\(them) from them)")
            let event = tracker.update(messages)
            if case .reset = event { await detectContact(in: frame) } else if detectedContact == nil { await detectContact(in: frame) }
            handle(event)
        } catch {
            log.error("tick failed: \(error.localizedDescription, privacy: .public)")
            status = Self.isPermissionError(error) ? .needsPermission : .failed(error.localizedDescription)
        }
    }

    /// 读聊天区域上方的标题栏，认出对方名字。换了人就清掉手动设置的名字。
    private func detectContact(in frame: CGImage) async {
        guard let rect = WindowCapture.headerRegion(above: settings.region),
              let header = WindowCapture.crop(frame, to: rect),
              let lines = try? await Task.detached(priority: .utility, operation: { try TextRecognizer.recognize(header) }).value
        else { return }
        let name = ContactNameDetector.detect(lines, excluding: windowTitles)
        if name != detectedContact {
            log.notice("contact changed: \(name ?? "nil", privacy: .private)")
            detectedContact = name
            manualContact = nil
        }
    }

    private func handle(_ event: TrackerEvent) {
        let messages: [ChatMessage]
        switch event {
        case .unchanged: return
        case .appended(let new): messages = new
        case .reset(let visible): messages = visible
        }
        let kind = if case .reset = event { "reset" } else { "appended" }
        log.notice("tracker \(kind, privacy: .public): \(messages.count) messages")
        if let latest = messages.last(where: { $0.speaker == .them }) { enqueue(latest) }
    }

    private func enqueue(_ latest: ChatMessage) {
        let context = contextBefore(latest)
        let key = MessageTracker.normalize((context.last?.text ?? "") + "|" + latest.text)
        guard !analyzedKeys.contains(key) else { return }
        log.notice("queue analysis: \(latest.text, privacy: .private)")
        analyzedKeys = Array((analyzedKeys + [key]).suffix(100))
        pending = (context, latest, currentContact)
        if !analyzing { Task { await drain() } }
    }

    private func contextBefore(_ latest: ChatMessage) -> [ChatMessage] {
        let history = tracker.context(limit: 12)
        let prefix = history.lastIndex(of: latest).map { Array(history[..<$0]) } ?? history
        return Array(prefix.suffix(10))
    }

    /// 本地模型没在跑就自动拉起来。绝不会自动改用云端模型：聊天内容发不发出去只能由用户决定。
    private func ensureLocalModel(force: Bool = false) async {
        guard settings.autoStartOllama, settings.engine != .systemOne, settings.llmProvider == .ollama else { return }
        guard force || !ollamaChecked else { return }
        ollamaChecked = true
        guard let url = URL(string: settings.ollamaURL.trimmingCharacters(in: .whitespaces)) else { return }
        if await OllamaLauncher.ping(url) { ollamaStatus = .running; return }
        startingOllama = true
        defer { startingOllama = false }
        log.notice("starting ollama serve")
        let status = await OllamaLauncher(baseURL: url).ensureRunning()
        ollamaStatus = status
        log.notice("ollama: \(String(describing: status), privacy: .public)")
    }

    /// 手动模式：分析粘贴进来的聊天记录，取其中对方最后说的那条。
    func analyzeManual(_ transcript: String) {
        let parsed = ChatTranscript.parse(transcript)
        guard let index = parsed.messages.lastIndex(where: { $0.speaker == .them }) else { return }
        let latest = parsed.messages[index]
        let context = Array(parsed.messages[..<index].suffix(10))
        analysisError = nil
        pending = (context, latest, manualContact ?? latest.sender)
        if !analyzing { Task { await drain() } }
    }

    /// 启动时把本地模型和提示词前缀预先加载好：冷启动第一次分析要 11.7 秒，预热后约 3 秒。
    /// 只对本地模型做——云端模型按次计费，绝不偷偷调用。
    func warmUpLocalModel() {
        guard !warmedUp, settings.llmProvider == .ollama, settings.engine != .systemOne else { return }
        warmedUp = true
        Task {
            await ensureLocalModel()
            guard let url = URL(string: settings.ollamaURL), await OllamaLauncher.ping(url),
                  let analyzer = try? settings.analyzerConfig().makeAnalyzer(engine: .llm, relationship: settings.relationship) else { return }
            let start = Date()
            _ = try? await analyzer.analyze(context: [], latest: ChatMessage(speaker: .them, text: "嗯", top: 0))
            log.notice("warm-up done in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        }
    }

    /// 一次只分析一条；分析期间来的新消息只保留最新的一条。
    private func drain() async {
        analyzing = true
        defer { analyzing = false }
        while let job = pending {
            pending = nil
            await ensureLocalModel()
            do {
                let contactMemory = job.contact.map(memory.memory(for:))
                let summary = settings.useMemory ? contactMemory?.promptSummary() : nil
                let analyzer = try settings.analyzerConfig().makeAnalyzer(relationship: relationship(for: job.contact), memory: summary)
                let analyzed = try await analyzer.analyze(context: job.context, latest: job.latest)
                var report = MemoryHints.apply(to: MoneyNet.apply(to: SafetyNet.apply(to: analyzed)))
                report.contact = job.contact
                if settings.autoRecordMemory, let contact = job.contact { editMemory(contact) { $0.record(report) } }
                reports.insert(report, at: 0)
                Self.debugLog(report)
                reports = Array(reports.prefix(30))
                analysisError = nil
                failed = nil
                log.notice("analysis done in \(Int(report.latencyMs)) ms by \(report.engine, privacy: .public)")
            } catch let error as URLError where Self.isConnectionError(error) && !ollamaRetried
                && settings.llmProvider == .ollama && settings.autoStartOllama {
                // 本地模型可能刚被关掉：拉起来再试一次这条。
                ollamaRetried = true
                await ensureLocalModel(force: true)
                pending = job
            } catch {
                // 错误信息里可能带着模型输出（即聊天内容），只公开类别，细节标为隐私。
                log.error("analysis failed: \(Self.category(error), privacy: .public) \(error.localizedDescription, privacy: .private)")
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

    static func isConnectionError(_ error: URLError) -> Bool {
        [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet].contains(error.code)
    }

    /// 可以公开写进系统日志的错误类别（不含任何聊天内容）。
    static func category(_ error: Error) -> String {
        switch error {
        case AnalyzerError.badResponse: "bad_response"
        case AnalyzerError.refused: "refused"
        case AnalyzerError.http(let service, let status, _): "http \(status) from \(service)"
        case let error as URLError: "url_error \(error.code.rawValue)"
        default: String(describing: type(of: error))
        }
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let e = error as NSError
        return e.domain == SCStreamErrorDomain && e.code == SCStreamError.userDeclined.rawValue
    }
}
