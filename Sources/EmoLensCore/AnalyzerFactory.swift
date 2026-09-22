import Foundation

/// 分析引擎。rawValue 与应用设置里保存的值一致。
public enum Engine: String, CaseIterable, Sendable {
    case llm, combined, systemOne
}

/// 生成式大模型从哪来。
public enum LLMSource: Sendable {
    case ollama(baseURL: URL, model: String)
    case openAICompatible(baseURL: URL, model: String, apiKey: String, supportsJSONSchema: Bool, providerName: String)
    case anthropic(model: String, apiKey: String)

    public static let localDefault = LLMSource.ollama(baseURL: URL(string: "http://127.0.0.1:11434")!, model: "qwen3.5:4b")

    public func backend() -> ChatBackend {
        switch self {
        case .ollama(let url, let model):
            OllamaBackend(baseURL: url, model: model)
        case .openAICompatible(let url, let model, let key, let schema, let provider):
            OpenAICompatibleBackend(baseURL: url, model: model, apiKey: key, supportsJSONSchema: schema, providerName: provider)
        case .anthropic(let model, let key):
            AnthropicBackend(model: model, apiKey: key)
        }
    }
}

/// OpenAI 兼容服务的预设：选一个就自动填好地址和常用模型（模型名可以改）。
public struct OpenAIPreset: Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let baseURL: String
    public let model: String
    public let supportsJSONSchema: Bool

    public static let all = [
        OpenAIPreset(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "gpt-5.5", supportsJSONSchema: true),
        OpenAIPreset(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com", model: "deepseek-chat", supportsJSONSchema: false),
        OpenAIPreset(id: "qwen", name: "通义千问", baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen-plus", supportsJSONSchema: false),
        OpenAIPreset(id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", model: "", supportsJSONSchema: false),
        OpenAIPreset(id: "custom", name: "自定义", baseURL: "", model: "", supportsJSONSchema: false),
    ]

    public static func named(_ id: String) -> OpenAIPreset { all.first { $0.id == id } ?? all[0] }
}

/// 创建分析器所需的全部配置。
public struct AnalyzerConfig: Sendable {
    public var engine: Engine = .llm
    public var llm: LLMSource = .localDefault
    public var systemOneURL = URL(string: "http://127.0.0.1:8009")!
    public var presets: URL = Presets.directory

    public init() {}

    public func makeAnalyzer(engine: Engine? = nil, relationship: String? = nil) throws -> EmotionAnalyzer {
        switch engine ?? self.engine {
        case .llm:
            return try llmAnalyzer(relationship)
        case .combined:
            return CombinedAnalyzer(primary: try llmAnalyzer(relationship),
                                    checker: try systemOne(relationship, only: CombinedAnalyzer.seriousFlags.map(\.rawValue)))
        case .systemOne:
            return try systemOne(relationship)
        }
    }

    private func llmAnalyzer(_ relationship: String?) throws -> LLMAnalyzer {
        let prompt = try LLMPrompt.load(from: presets.appending(path: "emotion.llm.zh.json"))
        return LLMAnalyzer(backend: llm.backend(), prompt: prompt, relationship: relationship)
    }

    private func systemOne(_ relationship: String?, only ids: [String]? = nil) throws -> SystemOneAnalyzer {
        var preset = try SystemOnePreset.load(from: presets.appending(path: "emotion.zh.json"))
        if let ids { preset = preset.subset(ids) }
        return SystemOneAnalyzer(baseURL: systemOneURL, preset: preset, relationship: relationship)
    }
}

/// 预设文件位置：环境变量 EMOLENS_PRESETS > .app 内 Resources/presets > 当前目录 presets/。
public enum Presets {
    public static var directory: URL {
        if let env = ProcessInfo.processInfo.environment["EMOLENS_PRESETS"] {
            return URL(fileURLWithPath: env)
        }
        if let bundled = Bundle.main.resourceURL?.appending(path: "presets"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "presets")
    }
}
