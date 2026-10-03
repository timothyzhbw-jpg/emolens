import Foundation

/// 一次情感分析的结果，两种引擎共用。
public struct EmotionReport: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var message: ChatMessage
    public var emotion: String
    public var emotionProbability: Double?
    public var intensity: Double
    public var flags: [String: Double]
    public var bestResponse: String?
    /// 字面与真实想法是否一致：一致 / 反话 / 撒娇 / 没说完（仅生成式引擎）。
    public var consistency: String?
    /// 情绪指向：我 / 自己 / 别人 / 这件事（仅生成式引擎）。
    public var target: String?
    public var literal: String?
    public var realMeaning: String?
    public var suggestedReply: String?
    /// 模型建议记住的事（例如「TA 下周三面试」）；用户确认后才写进联系人记忆。
    public var memoryNote: String?
    /// 聊天对象的名字（识别出来的或手动设置的），用于联系人记忆。
    public var contact: String?
    public var engine: String
    public var latencyMs: Double
    public var date = Date()

    public init(message: ChatMessage, emotion: String, emotionProbability: Double? = nil, intensity: Double,
                flags: [String: Double], bestResponse: String? = nil, consistency: String? = nil,
                target: String? = nil, literal: String? = nil,
                realMeaning: String? = nil, suggestedReply: String? = nil, memoryNote: String? = nil,
                contact: String? = nil, engine: String, latencyMs: Double) {
        self.message = message
        self.emotion = emotion
        self.emotionProbability = emotionProbability
        self.intensity = intensity
        self.flags = flags
        self.bestResponse = bestResponse
        self.consistency = consistency
        self.target = target
        self.literal = literal
        self.realMeaning = realMeaning
        self.suggestedReply = suggestedReply
        self.memoryNote = memoryNote
        self.contact = contact
        self.engine = engine
        self.latencyMs = latencyMs
    }

    /// 概率达到阈值的标记，按固定顺序。
    public func activeFlags(threshold: Double = 0.5) -> [EmotionFlag] {
        EmotionFlag.allCases.filter { (flags[$0.rawValue] ?? 0) >= threshold }
    }
}

/// 关系与情绪信号。rawValue 与预设文件里的问题 id 一致。
public enum EmotionFlag: String, CaseIterable, Sendable {
    case angryAtMe = "angry_at_me"
    case sarcasm
    case perfunctory
    case needsComfort = "needs_comfort"
    case testing
    case coldDistance = "cold_distance"
    case conflict
    case manipulation
    case selfHarm = "self_harm"
    case asksMoney = "asks_money"

    public var title: String { title(in: .current) }

    public func title(in language: AppLanguage) -> String {
        switch self {
        case .angryAtMe: language.pick("在生我的气", "Upset with you")
        case .sarcasm: language.pick("反话 / 阴阳怪气", "Sarcastic / passive-aggressive")
        case .perfunctory: language.pick("敷衍 / 不想争了", "Brushing you off")
        case .needsComfort: language.pick("需要安慰", "Needs comfort")
        case .testing: language.pick("在试探我", "Testing you")
        case .coldDistance: language.pick("冷淡疏远", "Pulling away")
        case .conflict: language.pick("冷战 / 分手信号", "Fight / breakup signal")
        case .manipulation: language.pick("情感操控", "Emotional manipulation")
        case .selfHarm: language.pick("自伤风险", "Self-harm risk")
        case .asksMoney: language.pick("涉及钱或账号", "Money or account request")
        }
    }

    /// 需要用醒目颜色提醒的信号。
    public var isSerious: Bool { [.manipulation, .selfHarm, .conflict, .asksMoney].contains(self) }
}

/// 情感分析引擎。
public protocol EmotionAnalyzer: Sendable {
    var name: String { get }
    func analyze(context: [ChatMessage], latest: ChatMessage) async throws -> EmotionReport
}

public enum AnalyzerError: LocalizedError {
    case badResponse(String)
    case refused(String)
    case http(service: String, status: Int, detail: String)

    public var errorDescription: String? {
        switch self {
        case .badResponse(let detail): L("分析引擎返回了无法识别的结果：\(detail)", "The analysis engine returned something unreadable: \(detail)")
        case .refused(let detail): detail
        case .http(let service, let status, let detail): Self.describe(service: service, status: status, detail: detail)
        }
    }

    /// 把常见状态码翻成用户知道怎么办的话。
    static func describe(service: String, status: Int, detail: String) -> String {
        switch status {
        case 401: L("\(service) 的 API Key 无效或没填，请在设置里检查。", "The \(service) API key is missing or invalid. Check it in Settings.")
        case 402: L("\(service) 账户余额不足或未开通付费。", "Your \(service) account is out of credit or billing isn't set up.")
        case 403: L("这个 API Key 没有权限使用该模型。（\(detail)）", "This API key can't use that model. (\(detail))")
        case 404: L("\(service) 找不到这个模型或地址，请检查模型名和服务地址。（\(detail)）",
                    "\(service) can't find that model or URL. Check the model name and endpoint. (\(detail))")
        case 429: L("\(service) 请求太频繁或额度用完了，稍后再试。", "\(service) is rate-limiting you or your quota ran out. Try again shortly.")
        case 500, 502, 503, 529: L("\(service) 服务暂时繁忙（HTTP \(status)），稍后再试。", "\(service) is busy right now (HTTP \(status)). Try again shortly.")
        default: L("\(service) 返回错误（HTTP \(status)）：\(detail)", "\(service) returned an error (HTTP \(status)): \(detail)")
        }
    }
}

/// 把聊天记录渲染成给模型看的文本。language 跟着提示词走：英文提示词配英文的聊天记录框架。
public enum ChatState {
    public static func line(_ message: ChatMessage, language: AppLanguage = .zh) -> String {
        guard language == .en else {
            switch message.speaker {
            case .me: return "我：\(message.text)"
            case .them: return message.sender.map { "对方（\($0)）：\(message.text)" } ?? "对方：\(message.text)"
            case .system: return "［\(message.text)］"
            }
        }
        let text = Placeholder.localized(message.text, .en)
        switch message.speaker {
        case .me: return "Me: \(text)"
        case .them: return message.sender.map { "Them (\($0)): \(text)" } ?? "Them: \(text)"
        case .system: return "[\(text)]"
        }
    }

    /// relationship 为「恋人」「家人」等规范值（英文写法也认）；nil 或「不确定」时不写。memory 为联系人记忆摘要。
    public static func render(context: [ChatMessage], latest: ChatMessage, relationship: String? = nil, memory: String? = nil,
                              language: AppLanguage = .zh) -> String {
        let relation = Vocabulary.canonical(relationship, in: Vocabulary.relationships) ?? relationship
        let known = relation.map { !$0.isEmpty && $0 != "不确定" } ?? false
        var text = ""
        if language == .en {
            if known, let relation { text += "Relationship: \(Vocabulary.english(relation, in: Vocabulary.relationships) ?? relation)\n" }
            if let memory, !memory.isEmpty { text += memory + "\n\n" }
            text += "Chat log (oldest first; \"Me\" is the user, \"Them\" is the other person):\n"
            text += context.map { line($0, language: .en) }.joined(separator: "\n")
            text += "\n\nAnalyze only their latest message:\n" + line(latest, language: .en)
            return text
        }
        if known, let relation { text += "双方关系：\(relation)\n" }
        if let memory, !memory.isEmpty { text += memory + "\n\n" }
        text += "以下是微信聊天记录（按时间顺序，「我」是用户，「对方」是聊天对象）：\n"
        text += context.map { line($0) }.joined(separator: "\n")
        text += "\n\n需要分析的是对方最新这条：\n" + line(latest)
        return text
    }
}
