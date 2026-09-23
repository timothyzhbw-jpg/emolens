import Foundation

/// 一轮对话（user / assistant）。system 单独传。
public struct ChatTurn: Sendable, Equatable {
    public var role: String
    public var content: String
    /// 附带的 PNG 图片（看表情、表情包时用）。模型要支持看图。
    public var images: [Data]

    public init(role: String, content: String, images: [Data] = []) {
        self.role = role
        self.content = content
        self.images = images
    }
}

/// 生成式大模型的后端：本地 Ollama、OpenAI 兼容服务、Anthropic Claude。
public protocol ChatBackend: Sendable {
    /// 界面上显示的名字，例如「Claude · claude-opus-5」。
    var name: String { get }
    /// 云端服务的名字；本地模型为 nil。选了云端时界面要提示消息会发出去。
    var cloudProvider: String? { get }
    /// 返回模型输出的文本（应当是一个 JSON 对象）。schema 为 JSON Schema 原文，支持时用于约束输出。
    func complete(system: String, turns: [ChatTurn], schema: String?) async throws -> String
}

// MARK: - 本地 Ollama

public struct OllamaBackend: ChatBackend {
    public var baseURL: URL
    public var model: String
    public var name: String { "本地大模型 · \(model)" }
    public var cloudProvider: String? { nil }
    public static let keepAlive = "30m"
    public static let contextLength = 6144

    public init(baseURL: URL = URL(string: "http://127.0.0.1:11434")!, model: String = "qwen3.5:4b") {
        self.baseURL = baseURL
        self.model = model
    }

    /// 模型能不能看图（Ollama 的 /api/show 里 capabilities 含 vision）。查不到时返回 nil。
    public func supportsVision() async -> Bool? {
        guard let response = try? await HTTP.post(baseURL.appending(path: "api/show"), body: ["model": model],
                                                  service: "Ollama", timeout: 5),
              let capabilities = response["capabilities"] as? [String] else { return nil }
        return capabilities.contains("vision")
    }

    public func complete(system: String, turns: [ChatTurn], schema: String?) async throws -> String {
        // qwen3.5 在 Ollama 里对 JSON Schema 约束不稳定，用通用的 json 模式，解析时再兜底修复。
        let body: [String: Any] = [
            "model": model, "stream": false, "think": false, "format": "json",
            // Ollama 默认闲置 5 分钟就卸载模型，下次要多等 8 秒以上；聊天常常隔一阵才来一条，留 30 分钟。
            "keep_alive": OllamaBackend.keepAlive,
            // Ollama 默认上下文只有 4096：提示词和示例就占了约 4000，再加上聊天和记忆，输出会被截成半个 JSON。
            // 实测 qwen3.5:4b 读 4000 字的提示：6144 时 0.8 秒，8192 时 1.6 秒，所以取 6144。
            "options": ["temperature": 0.2, "num_ctx": OllamaBackend.contextLength],
            "messages": [["role": "system", "content": system]] + turns.map { turn -> [String: Any] in
                var message: [String: Any] = ["role": turn.role, "content": turn.content]
                if !turn.images.isEmpty { message["images"] = turn.images.map { $0.base64EncodedString() } }
                return message
            },
        ]
        let response = try await HTTP.post(baseURL.appending(path: "api/chat"), body: body, service: "Ollama")
        if response["done_reason"] as? String == "length" {
            throw AnalyzerError.badResponse("本地模型的输出被截断了（上下文不够长）")
        }
        guard let content = (response["message"] as? [String: Any])?["content"] as? String else {
            throw AnalyzerError.badResponse("Ollama 返回里缺少 message.content")
        }
        return content
    }
}

// MARK: - OpenAI 兼容（OpenAI、DeepSeek、通义千问、OpenRouter …）

public struct OpenAICompatibleBackend: ChatBackend {
    public var baseURL: URL
    public var model: String
    public var apiKey: String
    /// 服务是否支持 response_format: json_schema（OpenAI 官方支持；很多兼容服务只支持 json_object）。
    public var supportsJSONSchema: Bool
    public var providerName: String

    public var name: String { "\(providerName) · \(model)" }
    public var cloudProvider: String? { providerName }

    public init(baseURL: URL = URL(string: "https://api.openai.com/v1")!, model: String = "gpt-5.5", apiKey: String,
                supportsJSONSchema: Bool = true, providerName: String = "OpenAI") {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.supportsJSONSchema = supportsJSONSchema
        self.providerName = providerName
    }

    public func complete(system: String, turns: [ChatTurn], schema: String?) async throws -> String {
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system]] + turns.map { turn -> [String: Any] in
                guard !turn.images.isEmpty else { return ["role": turn.role, "content": turn.content] }
                let images = turn.images.map { ["type": "image_url", "image_url": ["url": "data:image/png;base64," + $0.base64EncodedString()]] }
                return ["role": turn.role, "content": [["type": "text", "text": turn.content]] + images]
            },
        ]
        // 不传 temperature：推理类模型（如 gpt-5.5）只接受默认值。
        if supportsJSONSchema, schema != nil {
            body["response_format"] = ["type": "json_schema",
                                       "json_schema": ["name": "emotion_report", "strict": true, "schema": HTTP.rawSchema]]
        } else {
            body["response_format"] = ["type": "json_object"]
        }
        let response = try await HTTP.post(baseURL.appending(path: "chat/completions"), body: body,
                                           headers: ["Authorization": "Bearer \(apiKey)"], rawSchema: schema, service: providerName)
        guard let choice = (response["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any] else {
            throw AnalyzerError.badResponse("\(providerName) 返回里缺少 choices[0].message")
        }
        if let refusal = message["refusal"] as? String, !refusal.isEmpty {
            throw AnalyzerError.refused("\(providerName) 拒绝了这次请求：\(refusal)")
        }
        if choice["finish_reason"] as? String == "length" {
            throw AnalyzerError.badResponse("\(providerName) 的输出被截断了（finish_reason: length）")
        }
        guard let content = message["content"] as? String else {
            throw AnalyzerError.badResponse("\(providerName) 返回里缺少 message.content")
        }
        return content
    }
}

// MARK: - Anthropic Claude（Messages API，原始 HTTP）

public struct AnthropicBackend: ChatBackend {
    public static let models = ["claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5"]

    public var baseURL: URL
    public var model: String
    public var apiKey: String

    public var name: String { "Claude · \(model)" }
    public var cloudProvider: String? { "Anthropic" }

    public init(model: String = "claude-opus-5", apiKey: String, baseURL: URL = URL(string: "https://api.anthropic.com")!) {
        self.model = model
        self.apiKey = apiKey
        self.baseURL = baseURL
    }

    /// Opus 5 / Fable 这类带安全分类器的模型，误拦时由服务端按类别自动换模型重跑。
    var usesServerFallbacks: Bool { model.hasPrefix("claude-opus-5") || model.hasPrefix("claude-fable") }

    public func complete(system: String, turns: [ChatTurn], schema: String?) async throws -> String {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,   // 思考也计入 max_tokens，留足空间避免截断
            "system": system,
            "messages": turns.map { turn -> [String: Any] in
                guard !turn.images.isEmpty else { return ["role": turn.role, "content": turn.content] }
                let images: [[String: Any]] = turn.images.map {
                    ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": $0.base64EncodedString()]]
                }
                return ["role": turn.role, "content": images + [["type": "text", "text": turn.content]]]
            },
            "cache_control": ["type": "ephemeral"],   // system + 示例是固定前缀，自动缓存
        ]
        if schema != nil {
            body["output_config"] = ["format": ["type": "json_schema", "schema": HTTP.rawSchema]]
        }
        var headers = ["x-api-key": apiKey, "anthropic-version": "2023-06-01"]
        if usesServerFallbacks {
            body["fallbacks"] = "default"
            headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
        }
        let response = try await HTTP.post(baseURL.appending(path: "v1/messages"), body: body, headers: headers,
                                           rawSchema: schema, service: "Anthropic")
        return try Self.text(from: response)
    }

    /// 先看 stop_reason 再读内容；只拼接 text 块（思考块跳过）。
    static func text(from response: [String: Any]) throws -> String {
        switch response["stop_reason"] as? String {
        case "refusal":
            throw AnalyzerError.refused("Claude 拒绝了这次请求（安全策略）。换一个模型，或改用本地模型分析。")
        case "max_tokens":
            throw AnalyzerError.badResponse("Claude 的输出被截断了（max_tokens）")
        default: break
        }
        let blocks = response["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw AnalyzerError.badResponse("Claude 返回里没有文本内容") }
        return text
    }
}

// MARK: - HTTP

enum HTTP {
    /// 测试时替换成带 mock 协议的 session。
    static var session: URLSession = .shared
    /// 请求体里这个占位字符串会被替换成 JSON Schema 原文，保留字段顺序（字典会打乱顺序）。
    static let rawSchema = "@@EMOLENS_SCHEMA@@"

    static func post(_ url: URL, body: [String: Any], headers: [String: String] = [:], rawSchema schema: String? = nil,
                     service: String, timeout: TimeInterval = 120) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        var data = try JSONSerialization.data(withJSONObject: body)
        if let schema {
            let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"\(rawSchema)\"", with: schema)
            data = Data(text.utf8)
        }
        request.httpBody = data
        let (responseData, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        guard (200..<300).contains(status) else {
            // 各家的错误格式不一样：{"error": {"message"}}、{"error": "…"}、{"message"}、{"detail"}
            let detail = ((object?["error"] as? [String: Any])?["message"] as? String) ?? (object?["error"] as? String)
                ?? (object?["message"] as? String) ?? (object?["detail"] as? String)
                ?? String(decoding: responseData.prefix(200), as: UTF8.self)
            throw AnalyzerError.http(service: service, status: status, detail: detail)
        }
        guard let object else { throw AnalyzerError.badResponse("\(service) 返回的不是 JSON 对象") }
        return object
    }
}
