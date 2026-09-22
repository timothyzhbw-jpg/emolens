import Foundation

/// 关于一个聊天对象的记忆：你记下的事、每个人自己的关系、最近的情绪记录。只存在本机。
public struct ContactMemory: Codable, Equatable, Sendable {
    public struct Note: Codable, Equatable, Identifiable, Sendable {
        public enum Source: String, Codable, Sendable { case user, ai }

        public var id = UUID()
        public var text: String
        public var source: Source
        public var date: Date

        public init(text: String, source: Source, date: Date = Date()) {
            self.text = text
            self.source = source
            self.date = date
        }
    }

    /// 一次分析的摘要（原话只留前 40 字）。
    public struct Entry: Codable, Equatable, Sendable {
        public var date: Date
        public var excerpt: String
        public var emotion: String
        public var intensity: Double
        public var signals: [String]
        public var consistency: String?

        public init(date: Date, excerpt: String, emotion: String, intensity: Double, signals: [String], consistency: String?) {
            self.date = date
            self.excerpt = excerpt
            self.emotion = emotion
            self.intensity = intensity
            self.signals = signals
            self.consistency = consistency
        }
    }

    public static let maxEntries = 200
    public static let excerptLength = 40

    public var name: String
    public var relationship: String?
    public var notes: [Note] = []
    public var entries: [Entry] = []

    public init(name: String) {
        self.name = name
    }

    public var isEmpty: Bool { notes.isEmpty && entries.isEmpty && relationship == nil }

    public mutating func record(_ report: EmotionReport) {
        let signals = report.activeFlags().map(\.rawValue)
        entries.append(Entry(date: report.date, excerpt: String(report.message.text.prefix(Self.excerptLength)),
                             emotion: report.emotion, intensity: report.intensity, signals: signals,
                             consistency: report.consistency))
        entries = Array(entries.suffix(Self.maxEntries))
    }

    /// 最近 days 天里各情绪 / 信号出现的次数，按次数从多到少。
    public func counts(days: Int, now: Date = Date()) -> (emotions: [(String, Int)], signals: [(EmotionFlag, Int)]) {
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        let recent = entries.filter { $0.date >= since }
        let emotions = Dictionary(grouping: recent, by: \.emotion).mapValues(\.count)
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        let signalCounts = Dictionary(grouping: recent.flatMap(\.signals), by: { $0 }).mapValues(\.count)
        let signals = EmotionFlag.allCases.compactMap { flag in signalCounts[flag.rawValue].map { (flag, $0) } }
            .sorted { $0.1 > $1.1 }
        return (emotions.map { ($0.key, $0.value) }, signals)
    }

    /// 给模型看的简短记忆摘要；没有可说的内容时返回 nil。
    public func promptSummary(now: Date = Date()) -> String? {
        var lines: [String] = []
        if !notes.isEmpty {
            lines.append("- 我记下的关于 TA 的事：" + notes.suffix(8).map(\.text).joined(separator: "；"))
        }
        let (emotions, signals) = counts(days: 7, now: now)
        if !emotions.isEmpty {
            lines.append("- 最近 7 天 TA 的情绪：" + emotions.prefix(4).map { "\($0.0) \($0.1) 次" }.joined(separator: "、"))
        }
        let repeated = signals.filter { $0.1 >= 2 }
        if !repeated.isEmpty {
            lines.append("- 反复出现的信号：" + repeated.prefix(3).map { "\($0.0.title) \($0.1) 次" }.joined(separator: "、"))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        let recent = entries.suffix(3).map { entry -> String in
            let tone = entry.consistency.flatMap { $0 == "一致" ? nil : $0 }.map { "，\($0)" } ?? ""
            return "\(formatter.string(from: entry.date))「\(entry.excerpt)」→ \(entry.emotion)\(tone)"
        }
        if !recent.isEmpty { lines.append("- 之前几次：" + recent.joined(separator: "；")) }
        guard !lines.isEmpty else { return nil }
        return "关于对方的记忆（来自之前的聊天，仅供参考，以这次的原话为准）：\n" + lines.joined(separator: "\n")
    }
}

/// 值得记住的事的关键词兜底：小模型常漏掉夹在撒娇里的日子和计划。
/// 只用来提出「要记住吗？」，用户确认后才会写进记忆，所以宁可多问一次。
public enum MemoryHints {
    public static let keywords = ["生日", "纪念日", "过敏", "面试", "考试", "考研", "搬家", "出差", "手术", "住院",
                                  "体检", "入职", "辞职", "离职", "怀孕", "结婚", "毕业", "答辩", "航班", "回国"]

    /// 消息里有这些词、模型又没给出要记的事时，把这句话（去掉客套尾巴）作为候选。
    public static func suggestion(for text: String) -> String? {
        guard keywords.contains(where: text.contains) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^(对了|哦对|话说|顺便说一下)[，,、\s]*"#, with: "", options: .regularExpression)
        return String(trimmed.prefix(ContactMemory.excerptLength))
    }

    public static func apply(to report: EmotionReport) -> EmotionReport {
        guard report.memoryNote == nil, let hint = suggestion(for: report.message.text) else { return report }
        var report = report
        report.memoryNote = hint
        return report
    }
}

/// 所有联系人的记忆，存成一个 JSON 文件。只在主线程使用。
public final class ContactMemoryStore {
    public private(set) var contacts: [String: ContactMemory] = [:]
    public let fileURL: URL

    /// 默认位置：~/Library/Application Support/EmoLens/memory.json；环境变量 EMOLENS_MEMORY 可以指定别的文件（测试用）。
    public static var defaultURL: URL {
        if let path = ProcessInfo.processInfo.environment["EMOLENS_MEMORY"] { return URL(fileURLWithPath: path) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "EmoLens/memory.json")
    }

    public init(fileURL: URL = ContactMemoryStore.defaultURL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? Self.decoder.decode([String: ContactMemory].self, from: data) {
            contacts = saved
        }
    }

    public func memory(for name: String) -> ContactMemory {
        contacts[Self.key(name)] ?? ContactMemory(name: name)
    }

    public func update(_ name: String, _ change: (inout ContactMemory) -> Void) {
        var entry = self.memory(for: name)
        change(&entry)
        contacts[Self.key(name)] = entry.isEmpty ? nil : entry
        save()
    }

    public func record(_ report: EmotionReport, for name: String) {
        update(name) { $0.record(report) }
    }

    public func forget(_ name: String) {
        contacts[Self.key(name)] = nil
        save()
    }

    public func forgetAll() {
        contacts.removeAll()
        save()
    }

    /// 同一个人不同写法（空格、大小写）视为同一人。
    static func key(_ name: String) -> String {
        name.lowercased().filter { !$0.isWhitespace }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? Self.encoder.encode(contacts) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)   // 只有自己能读
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// 从聊天窗口顶部标题栏的文字里认出对方的名字。
public enum ContactNameDetector {
    /// lines 为聊天区域上方那一条的 OCR 结果（坐标原点在左上）。
    /// 取离聊天区域最近（最靠下）的一行：窗口自己的标题栏在最上面，对方名字紧挨着聊天区域。
    /// excluding 为窗口自己的标题（如「微信」），和它一样的行跳过。
    public static func detect(_ lines: [OCRLine], excluding titles: [String] = []) -> String? {
        let skip = Set(titles.compactMap(clean))
        let candidates = lines.compactMap { line -> (String, CGFloat)? in
            guard line.confidence >= 0.3, let name = clean(line.text), !skip.contains(name) else { return nil }
            return (name, line.box.maxY)
        }
        return candidates.max { $0.1 < $1.1 }?.0
    }

    static func clean(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 窗口左上角的三个按钮常被认成「•••」「···」「...」，去掉开头这类杂字
        text = text.replacingOccurrences(of: #"^[•·.。…\s]+"#, with: "", options: .regularExpression)
        // 群聊标题「家人群(12)」「工作群（8）」去掉人数
        if let range = text.range(of: #"\s*[（(]\d+[)）]$"#, options: .regularExpression) {
            text.removeSubrange(range)
        }
        guard (1...30).contains(text.count),
              text.range(of: #"^[\d\s:：/.\-]+$"#, options: .regularExpression) == nil,   // 纯数字 / 时间
              !["…", "...", "···", "微信", "WeChat"].contains(text) else { return nil }
        return text
    }
}
