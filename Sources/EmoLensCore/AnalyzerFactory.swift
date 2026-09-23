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

/// 决策模型（System One）从哪来：本机的 Kev，或 TypeSafe 云端的 Jev。接口相同，只是 Jev 要密钥、按量计费。
public enum SystemOneSource: Sendable, Equatable {
    case kev(baseURL: URL)
    case jev(baseURL: URL, model: String, apiKey: String)

    public static let localKev = SystemOneSource.kev(baseURL: URL(string: "http://127.0.0.1:8009")!)
    public static let jevURL = URL(string: "https://api.typesafe.ai")!
    public static let jevModel = "jev-latest"

    public var baseURL: URL {
        switch self {
        case .kev(let url), .jev(let url, _, _): url
        }
    }

    public var model: String {
        switch self {
        case .kev: "kev-latest"
        case .jev(_, let model, _): model
        }
    }

    public var apiKey: String? {
        if case .jev(_, _, let key) = self { key } else { nil }
    }

    /// 界面和结果里显示的名字。
    public var name: String {
        switch self {
        case .kev: "决策模型 · Kev"
        case .jev(_, let model, _): "决策模型 · Jev（\(model)）"
        }
    }

    /// 出错时说是哪个服务。
    var serviceName: String {
        if case .jev = self { "Jev（TypeSafe）" } else { "Kev" }
    }

    /// 云端服务名；本机 Kev 为 nil。
    public var cloudProvider: String? {
        if case .jev = self { "TypeSafe（Jev）" } else { nil }
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
    public var systemOne: SystemOneSource = .localKev
    public var presets: URL = Presets.directory

    public init() {}

    /// memory 为联系人记忆摘要（ContactMemory.promptSummary），会写进给模型的上下文。
    public func makeAnalyzer(engine: Engine? = nil, relationship: String? = nil, memory: String? = nil) throws -> EmotionAnalyzer {
        switch engine ?? self.engine {
        case .llm:
            return try llmAnalyzer(relationship, memory)
        case .combined:
            return CombinedAnalyzer(primary: try llmAnalyzer(relationship, memory),
                                    checker: try systemOne(relationship, memory, only: CombinedAnalyzer.seriousFlags.map(\.rawValue)))
        case .systemOne:
            return try systemOne(relationship, memory)
        }
    }

    private func llmAnalyzer(_ relationship: String?, _ memory: String?) throws -> LLMAnalyzer {
        let prompt = try LLMPrompt.load(from: presets.appending(path: "emotion.llm.zh.json"))
        return LLMAnalyzer(backend: llm.backend(), prompt: prompt, relationship: relationship, memory: memory)
    }

    private func systemOne(_ relationship: String?, _ memory: String?, only ids: [String]? = nil) throws -> SystemOneAnalyzer {
        var preset = try SystemOnePreset.load(from: presets.appending(path: "emotion.zh.json"))
        if let ids { preset = preset.subset(ids) }
        return SystemOneAnalyzer(source: systemOne, preset: preset, relationship: relationship, memory: memory)
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
