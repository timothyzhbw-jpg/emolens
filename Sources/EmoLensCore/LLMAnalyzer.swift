import Foundation

/// 给生成式模型的提示词和示例，从 presets/emotion.llm.zh.json 读取，方便不改代码就调整。
public struct LLMPrompt: Codable, Sendable {
    public struct Example: Codable, Sendable {
        public var chat: String
        public var answer: [String: JSONValue]
    }

    public var system: String
    public var examples: [Example]
    /// 输出格式的 JSON Schema 原文（同目录的 emotion.schema.json），云端模型用它做结构化输出。
    public var schema: String?

    public static func load(from url: URL) throws -> LLMPrompt {
        var prompt = try JSONDecoder().decode(LLMPrompt.self, from: Data(contentsOf: url))
        let schemaURL = url.deletingLastPathComponent().appending(path: "emotion.schema.json")
        prompt.schema = try? String(contentsOf: schemaURL, encoding: .utf8)
        return prompt
    }
}

/// 用生成式大模型读潜台词、给回复建议。后端可以是本地 Ollama、OpenAI 兼容服务或 Claude。
public struct LLMAnalyzer: EmotionAnalyzer {
    public var backend: ChatBackend
    public var prompt: LLMPrompt
    public var relationship: String?
    public var name: String { backend.name }

    public init(backend: ChatBackend, prompt: LLMPrompt, relationship: String? = nil) {
        self.backend = backend
        self.prompt = prompt
        self.relationship = relationship
    }

    /// few-shot 示例在前，当前对话在最后。
    func turns(context: [ChatMessage], latest: ChatMessage) throws -> [ChatTurn] {
        var turns: [ChatTurn] = []
        for example in prompt.examples {
            turns.append(ChatTurn(role: "user", content: example.chat))
            turns.append(ChatTurn(role: "assistant", content: try Self.encodeInOrder(example.answer)))
        }
        turns.append(ChatTurn(role: "user", content: ChatState.render(context: context, latest: latest, relationship: relationship)))
        return turns
    }

    public func analyze(context: [ChatMessage], latest: ChatMessage) async throws -> EmotionReport {
        let start = Date()
        let content = try await backend.complete(system: prompt.system, turns: turns(context: context, latest: latest),
                                                 schema: prompt.schema)
        let latency = Date().timeIntervalSince(start) * 1000
        return try Self.report(from: content, message: latest, engine: name, latencyMs: latency)
    }

    /// 示例答案按提示词里的顺序输出：先字面、再真实想法、最后回复。字典本身是无序的。
    static let answerOrder = ["literal", "consistency", "real_meaning", "emotion", "intensity", "target",
                              "angry_at_me", "perfunctory", "needs_comfort", "testing", "cold_distance",
                              "conflict", "manipulation", "self_harm", "best_response", "suggested_reply"]

    static func encodeInOrder(_ answer: [String: JSONValue]) throws -> String {
        let keys = answerOrder.filter { answer[$0] != nil } + answer.keys.filter { !answerOrder.contains($0) }.sorted()
        let fields = try keys.map { key -> String in
            let value = try String(data: JSONEncoder().encode(answer[key]!), encoding: .utf8) ?? "null"
            return "\"\(key)\": \(value)"
        }
        return "{" + fields.joined(separator: ", ") + "}"
    }

    /// 取出模型输出里的 JSON 对象。小模型偶尔用中文引号「“ ”」当字符串的边界，解析失败时修一次再试。
    static func parseObject(_ content: String) -> [String: Any]? {
        guard let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}") else { return nil }
        let raw = String(content[start...end])
        for candidate in [raw, repairQuotes(raw)] {
            if let data = candidate.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return object }
        }
        return nil
    }

    static func repairQuotes(_ json: String) -> String {
        json.replacingOccurrences(of: #"([:\[,{]\s*)[“”]"#, with: "$1\"", options: .regularExpression)
            .replacingOccurrences(of: #"[“”](\s*[,}\]:])"#, with: "\"$1", options: .regularExpression)
    }

    /// 解析模型输出的 JSON，对类型宽容（"true" / 1 / 0.8 都能当布尔用）。
    public static func report(from content: String, message: ChatMessage, engine: String, latencyMs: Double) throws -> EmotionReport {
        guard let json = parseObject(content) else { throw AnalyzerError.badResponse(String(content.prefix(200))) }

        var flags: [String: Double] = [:]
        for flag in EmotionFlag.allCases {
            flags[flag.rawValue] = probability(json[flag.rawValue])
        }
        let consistency = canonicalConsistency(json["consistency"] as? String)
        if consistency == "反话" { flags[EmotionFlag.sarcasm.rawValue] = 1 }
        return EmotionReport(
            message: message,
            emotion: (json["emotion"] as? String) ?? "未知",
            intensity: min(3, max(0, number(json["intensity"]) ?? 0)),
            flags: flags,
            bestResponse: json["best_response"] as? String,
            consistency: consistency,
            target: json["target"] as? String,
            literal: json["literal"] as? String,
            realMeaning: json["real_meaning"] as? String,
            suggestedReply: json["suggested_reply"] as? String,
            engine: engine,
            latencyMs: latencyMs
        )
    }

    /// 小模型有时会把别的字段的说明填进来，只接受四个规范值。
    static func canonicalConsistency(_ raw: String?) -> String? {
        guard let raw else { return nil }
        return ["反话", "撒娇", "没说完", "一致"].first { raw.contains($0) }
    }

    static func number(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber: n.doubleValue
        case let s as String: Double(s)
        default: nil
        }
    }

    static func probability(_ value: Any?) -> Double {
        if let s = value as? String {
            return ["true", "yes", "是", "1"].contains(s.lowercased()) ? 1 : (Double(s) ?? 0)
        }
        guard let n = number(value) else { return 0 }
        return n > 1 ? min(1, n / 100) : max(0, n)
    }
}

/// 最小的 JSON 值类型，用来在预设文件里保存示例答案。
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String), number(Double), bool(Bool), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else { self = .string(try c.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): n == n.rounded() ? try c.encode(Int(n)) : try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        }
    }
}
