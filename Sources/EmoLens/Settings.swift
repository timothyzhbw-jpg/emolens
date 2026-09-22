import CoreGraphics
import EmoLensCore
import Foundation

typealias EngineKind = Engine

extension Engine: Identifiable {
    public var id: String { rawValue }

    var name: String {
        switch self {
        case .llm: "大模型"
        case .combined: "双引擎"
        case .systemOne: "决策模型"
        }
    }

    var detail: String {
        switch self {
        case .llm: "读潜台词、给回复建议（推荐）"
        case .combined: "大模型 + Kev 复核严重信号，更稳；需要同时运行 Kev"
        case .systemOne: "Kev · 校准概率，读不懂潜台词，较慢"
        }
    }
}

/// 大模型从哪来。
enum LLMProvider: String, CaseIterable, Identifiable {
    case ollama, openai, anthropic

    var id: String { rawValue }

    var name: String {
        switch self {
        case .ollama: "本地 Ollama"
        case .openai: "OpenAI 兼容"
        case .anthropic: "Anthropic Claude"
        }
    }
}

/// 聊天对象和我的关系，会写进给模型的上下文。
let relationships = ["不确定", "恋人", "家人", "朋友", "同事", "同学"]

/// 用户设置，存在 UserDefaults。
@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var engine: EngineKind { didSet { defaults.set(engine.rawValue, forKey: "engine") } }
    @Published var ollamaURL: String { didSet { defaults.set(ollamaURL, forKey: "ollamaURL") } }
    @Published var ollamaModel: String { didSet { defaults.set(ollamaModel, forKey: "ollamaModel") } }
    @Published var systemOneURL: String { didSet { defaults.set(systemOneURL, forKey: "systemOneURL") } }
    @Published var llmProvider: LLMProvider { didSet { defaults.set(llmProvider.rawValue, forKey: "llmProvider") } }
    @Published var openAIPreset: String { didSet { defaults.set(openAIPreset, forKey: "openAIPreset") } }
    @Published var openAIBaseURL: String { didSet { defaults.set(openAIBaseURL, forKey: "openAIBaseURL") } }
    @Published var openAIModel: String { didSet { defaults.set(openAIModel, forKey: "openAIModel") } }
    @Published var anthropicModel: String { didSet { defaults.set(anthropicModel, forKey: "anthropicModel") } }
    /// API Key 存在钥匙串里，不进 UserDefaults。
    @Published var openAIKey: String { didSet { Keychain.save(openAIKey, for: "openai") } }
    @Published var anthropicKey: String { didSet { Keychain.save(anthropicKey, for: "anthropic") } }
    @Published var relationship: String { didSet { defaults.set(relationship, forKey: "relationship") } }
    @Published var interval: Double { didSet { defaults.set(interval, forKey: "interval") } }
    /// 分析时参考联系人记忆；把分析结果自动记进联系人记忆。
    /// 本地模型没在跑时自动执行 ollama serve（只对本机地址生效；永远不会自动改用云端模型）。
    @Published var autoStartOllama: Bool { didSet { defaults.set(autoStartOllama, forKey: "autoStartOllama") } }
    /// 手动模式：粘贴聊天记录分析，不截屏。
    @Published var manualMode: Bool { didSet { defaults.set(manualMode, forKey: "manualMode") } }
    @Published var useMemory: Bool { didSet { defaults.set(useMemory, forKey: "useMemory") } }
    @Published var autoRecordMemory: Bool { didSet { defaults.set(autoRecordMemory, forKey: "autoRecordMemory") } }
    @Published var windowID: CGWindowID { didSet { defaults.set(Int(windowID), forKey: "windowID") } }
    @Published var region: CGRect {
        didSet { defaults.set([region.minX, region.minY, region.width, region.height], forKey: "region") }
    }

    init() {
        engine = EngineKind(rawValue: defaults.string(forKey: "engine") ?? "") ?? .llm
        ollamaURL = defaults.string(forKey: "ollamaURL") ?? "http://127.0.0.1:11434"
        ollamaModel = defaults.string(forKey: "ollamaModel") ?? "qwen3.5:4b"
        systemOneURL = defaults.string(forKey: "systemOneURL") ?? "http://127.0.0.1:8009"
        llmProvider = LLMProvider(rawValue: defaults.string(forKey: "llmProvider") ?? "") ?? .ollama
        let preset = OpenAIPreset.named(defaults.string(forKey: "openAIPreset") ?? "openai")
        openAIPreset = preset.id
        openAIBaseURL = defaults.string(forKey: "openAIBaseURL") ?? preset.baseURL
        openAIModel = defaults.string(forKey: "openAIModel") ?? preset.model
        anthropicModel = defaults.string(forKey: "anthropicModel") ?? AnthropicBackend.models[0]
        openAIKey = Keychain.read("openai")
        anthropicKey = Keychain.read("anthropic")
        relationship = defaults.string(forKey: "relationship") ?? "不确定"
        interval = defaults.object(forKey: "interval") as? Double ?? 1.5
        autoStartOllama = defaults.object(forKey: "autoStartOllama") as? Bool ?? true
        manualMode = defaults.bool(forKey: "manualMode")
        useMemory = defaults.object(forKey: "useMemory") as? Bool ?? true
        autoRecordMemory = defaults.object(forKey: "autoRecordMemory") as? Bool ?? true
        windowID = CGWindowID(defaults.integer(forKey: "windowID"))
        // 兼容数字被存成字符串的情况（例如用 defaults write 命令写入）。
        let r = (defaults.array(forKey: "region") ?? []).compactMap { ($0 as? NSNumber)?.doubleValue ?? Double("\($0)") }
        region = r.count == 4 ? CGRect(x: r[0], y: r[1], width: r[2], height: r[3]) : CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    /// 选一个 OpenAI 兼容预设：填好地址和常用模型。
    func applyOpenAIPreset(_ id: String) {
        let preset = OpenAIPreset.named(id)
        openAIPreset = preset.id
        if !preset.baseURL.isEmpty { openAIBaseURL = preset.baseURL }
        if !preset.model.isEmpty { openAIModel = preset.model }
    }

    /// 云端服务名；用本地模型或只用决策模型时为 nil。界面据此提示消息会不会发出去。
    var cloudProviderName: String? {
        guard engine != .systemOne else { return nil }
        switch llmProvider {
        case .ollama: return nil
        case .openai:
            let preset = OpenAIPreset.named(openAIPreset)
            return preset.id == "custom" ? (URL(string: openAIBaseURL)?.host() ?? "云端服务") : preset.name
        case .anthropic: return "Anthropic"
        }
    }

    /// 当前设置对应的分析器配置。
    func analyzerConfig() throws -> AnalyzerConfig {
        var config = AnalyzerConfig()
        config.engine = engine
        config.systemOneURL = try url(systemOneURL)
        switch llmProvider {
        case .ollama:
            config.llm = .ollama(baseURL: try url(ollamaURL), model: ollamaModel)
        case .openai:
            guard !openAIKey.isEmpty else { throw AnalyzerError.badResponse("还没填 API Key：设置 → 分析引擎 → OpenAI 兼容") }
            guard !openAIModel.isEmpty else { throw AnalyzerError.badResponse("还没填模型名") }
            let preset = OpenAIPreset.named(openAIPreset)
            config.llm = .openAICompatible(baseURL: try url(openAIBaseURL), model: openAIModel, apiKey: openAIKey,
                                           supportsJSONSchema: preset.supportsJSONSchema,
                                           providerName: cloudProviderName ?? preset.name)
        case .anthropic:
            guard !anthropicKey.isEmpty else { throw AnalyzerError.badResponse("还没填 Claude 的 API Key：设置 → 分析引擎 → Anthropic Claude") }
            config.llm = .anthropic(model: anthropicModel, apiKey: anthropicKey)
        }
        return config
    }


    private func url(_ text: String) throws -> URL {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)), url.host() != nil else {
            throw AnalyzerError.badResponse("地址格式不对：\(text)")
        }
        return url
    }
}
