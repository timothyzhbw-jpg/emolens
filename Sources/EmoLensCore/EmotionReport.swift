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
    public var engine: String
    public var latencyMs: Double
    public var date = Date()

    public init(message: ChatMessage, emotion: String, emotionProbability: Double? = nil, intensity: Double,
                flags: [String: Double], bestResponse: String? = nil, consistency: String? = nil,
                target: String? = nil, literal: String? = nil,
                realMeaning: String? = nil, suggestedReply: String? = nil, engine: String, latencyMs: Double) {
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

    public var title: String {
        switch self {
        case .angryAtMe: "在生我的气"
        case .sarcasm: "反话 / 阴阳怪气"
        case .perfunctory: "敷衍 / 不想争了"
        case .needsComfort: "需要安慰"
        case .testing: "在试探我"
        case .coldDistance: "冷淡疏远"
        case .conflict: "冷战 / 分手信号"
        case .manipulation: "情感操控"
        case .selfHarm: "自伤风险"
        }
    }

    /// 需要用醒目颜色提醒的信号。
    public var isSerious: Bool { self == .manipulation || self == .selfHarm || self == .conflict }
}

/// 情感分析引擎。
public protocol EmotionAnalyzer: Sendable {
    var name: String { get }
    func analyze(context: [ChatMessage], latest: ChatMessage) async throws -> EmotionReport
}

public enum AnalyzerError: LocalizedError {
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .badResponse(let detail): "分析引擎返回了无法识别的结果：\(detail)"
        }
    }
}

/// 把聊天记录渲染成给模型看的文本。
public enum ChatState {
    public static func line(_ message: ChatMessage) -> String {
        switch message.speaker {
        case .me: "我：\(message.text)"
        case .them: message.sender.map { "对方（\($0)）：\(message.text)" } ?? "对方：\(message.text)"
        case .system: "［\(message.text)］"
        }
    }

    /// relationship 为「恋人」「家人」等；nil 或「不确定」时不写。
    public static func render(context: [ChatMessage], latest: ChatMessage, relationship: String? = nil) -> String {
        var text = ""
        if let relationship, !relationship.isEmpty, relationship != "不确定" { text += "双方关系：\(relationship)\n" }
        text += "以下是微信聊天记录（按时间顺序，「我」是用户，「对方」是聊天对象）：\n"
        text += context.map(line).joined(separator: "\n")
        text += "\n\n需要分析的是对方最新这条：\n" + line(latest)
        return text
    }
}

enum HTTP {
    static func postJSON(_ url: URL, body: Any, timeout: TimeInterval = 120) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw AnalyzerError.badResponse("HTTP \(http.statusCode) \(detail.prefix(200))")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AnalyzerError.badResponse("不是 JSON 对象")
        }
        return object
    }
}
