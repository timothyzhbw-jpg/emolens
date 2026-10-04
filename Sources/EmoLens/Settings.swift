import CoreGraphics
import EmoLensCore
import Foundation

typealias EngineKind = Engine

extension Engine: Identifiable {
    public var id: String { rawValue }

    var name: String {
        switch self {
        case .llm: L("大模型", "Language model")
        case .combined: L("双引擎", "Dual engine")
        case .systemOne: L("决策模型", "Decision model")
        }
    }

    var detail: String {
        switch self {
        case .llm: L("读潜台词、给回复建议（推荐）", "Reads subtext and suggests a reply (recommended)")
        case .combined: L("大模型 + 决策模型（Kev 或 Jev）复核严重信号，更稳", "Language model + decision model (Kev or Jev) double-checks serious signals")
        case .systemOne: L("Kev / Jev · 校准概率，读不懂潜台词，没有回复建议", "Kev / Jev · calibrated probabilities, no subtext, no reply suggestion")
        }
    }
}

/// 大模型从哪来。
enum LLMProvider: String, CaseIterable, Identifiable {
    case ollama, openai, anthropic

    var id: String { rawValue }

    var name: String {
        switch self {
        case .ollama: L("本地 Ollama", "Local Ollama")
        case .openai: L("OpenAI 兼容", "OpenAI-compatible")
        case .anthropic: "Anthropic Claude"
        }
    }
}

/// 决策模型从哪来。
enum SystemOneProvider: String, CaseIterable, Identifiable {
    case kev, jev

    var id: String { rawValue }

    var name: String {
        switch self {
        case .kev: L("本机 Kev", "Kev on this Mac")
        case .jev: L("Jev（TypeSafe 云端）", "Jev (TypeSafe cloud)")
        }
    }
}

/// 聊天对象和我的关系，会写进给模型的上下文。保存的是中文规范值，显示时按语言翻译。
let relationships = ["不确定", "恋人", "家人", "朋友", "同事", "同学"]

/// 用户设置，存在 UserDefaults。
@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard
    /// 命令行 --language 指定的语言，优先于保存的设置（只影响这次运行，不改设置）。
    static var launchLanguage: AppLanguage?

    /// 界面和分析的语言；没设置过时跟随系统语言。
    @Published var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: "language")
            AppLanguage.current = language
        }
    }
    @Published var engine: EngineKind { didSet { defaults.set(engine.rawValue, forKey: "engine") } }
    @Published var ollamaURL: String { didSet { defaults.set(ollamaURL, forKey: "ollamaURL") } }
    @Published var ollamaModel: String { didSet { defaults.set(ollamaModel, forKey: "ollamaModel") } }
    @Published var systemOneURL: String { didSet { defaults.set(systemOneURL, forKey: "systemOneURL") } }
    @Published var systemOneProvider: SystemOneProvider { didSet { defaults.set(systemOneProvider.rawValue, forKey: "systemOneProvider") } }
    @Published var jevURL: String { didSet { defaults.set(jevURL, forKey: "jevURL") } }
    @Published var jevModel: String { didSet { defaults.set(jevModel, forKey: "jevModel") } }
    @Published var llmProvider: LLMProvider { didSet { defaults.set(llmProvider.rawValue, forKey: "llmProvider") } }
    @Published var openAIPreset: String { didSet { defaults.set(openAIPreset, forKey: "openAIPreset") } }
    @Published var openAIBaseURL: String { didSet { defaults.set(openAIBaseURL, forKey: "openAIBaseURL") } }
    @Published var openAIModel: String { didSet { defaults.set(openAIModel, forKey: "openAIModel") } }
    @Published var anthropicModel: String { didSet { defaults.set(anthropicModel, forKey: "anthropicModel") } }
    /// API Key 存在钥匙串里，不进 UserDefaults。
    @Published var openAIKey: String { didSet { Keychain.save(openAIKey, for: "openai") } }
    @Published var anthropicKey: String { didSet { Keychain.save(anthropicKey, for: "anthropic") } }
    @Published var jevKey: String { didSet { Keychain.save(jevKey, for: "typesafe") } }
    /// 用 deAPI 把语音转成文字（云端，按量计费）。默认关闭；打开后语音提示上多一个「听这条语音」。
    @Published var deapiEnabled: Bool { didSet { defaults.set(deapiEnabled, forKey: "deapiEnabled") } }
    @Published var deapiModel: String { didSet { defaults.set(deapiModel, forKey: "deapiModel") } }
    @Published var deapiKey: String { didSet { Keychain.save(deapiKey, for: "deapi") } }
    @Published var relationship: String { didSet { defaults.set(relationship, forKey: "relationship") } }
    @Published var interval: Double { didSet { defaults.set(interval, forKey: "interval") } }
    /// 分析时参考联系人记忆；把分析结果自动记进联系人记忆。
    /// 本地模型没在跑时自动执行 ollama serve（只对本机地址生效；永远不会自动改用云端模型）。
    @Published var autoStartOllama: Bool { didSet { defaults.set(autoStartOllama, forKey: "autoStartOllama") } }
    /// 手动模式：粘贴聊天记录分析，不截屏。
    @Published var manualMode: Bool { didSet { defaults.set(manualMode, forKey: "manualMode") } }
    @Published var useMemory: Bool { didSet { defaults.set(useMemory, forKey: "useMemory") } }
    @Published var autoRecordMemory: Bool { didSet { defaults.set(autoRecordMemory, forKey: "autoRecordMemory") } }
    /// 对方发表情、表情包时，把那一小块截图交给模型看懂。
    @Published var readImages: Bool { didSet { defaults.set(readImages, forKey: "readImages") } }
    @Published var windowID: CGWindowID { didSet { defaults.set(Int(windowID), forKey: "windowID") } }
    @Published var region: CGRect {
        didSet { defaults.set([region.minX, region.minY, region.width, region.height], forKey: "region") }
    }

    init() {
        let language = Self.launchLanguage ?? AppLanguage(rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .system
        self.language = language
        AppLanguage.current = language
        engine = EngineKind(rawValue: defaults.string(forKey: "engine") ?? "") ?? .llm
        ollamaURL = defaults.string(forKey: "ollamaURL") ?? "http://127.0.0.1:11434"
        ollamaModel = defaults.string(forKey: "ollamaModel") ?? "qwen3.5:4b"
        systemOneURL = defaults.string(forKey: "systemOneURL") ?? "http://127.0.0.1:8009"
        systemOneProvider = SystemOneProvider(rawValue: defaults.string(forKey: "systemOneProvider") ?? "") ?? .kev
        jevURL = defaults.string(forKey: "jevURL") ?? SystemOneSource.jevURL.absoluteString
        jevModel = defaults.string(forKey: "jevModel") ?? SystemOneSource.jevModel
        llmProvider = LLMProvider(rawValue: defaults.string(forKey: "llmProvider") ?? "") ?? .ollama
        let preset = OpenAIPreset.named(defaults.string(forKey: "openAIPreset") ?? "openai")
        openAIPreset = preset.id
        openAIBaseURL = defaults.string(forKey: "openAIBaseURL") ?? preset.baseURL
        openAIModel = defaults.string(forKey: "openAIModel") ?? preset.model
        anthropicModel = defaults.string(forKey: "anthropicModel") ?? AnthropicBackend.models[0]
        openAIKey = Keychain.read("openai")
        anthropicKey = Keychain.read("anthropic")
        jevKey = Keychain.read("typesafe")
        deapiEnabled = defaults.bool(forKey: "deapiEnabled")
        deapiModel = defaults.string(forKey: "deapiModel") ?? DeAPITranscriber.defaultModel
        deapiKey = Keychain.read("deapi")
        relationship = defaults.string(forKey: "relationship") ?? "不确定"
        interval = defaults.object(forKey: "interval") as? Double ?? 1.5
        autoStartOllama = defaults.object(forKey: "autoStartOllama") as? Bool ?? true
        manualMode = defaults.bool(forKey: "manualMode")
        useMemory = defaults.object(forKey: "useMemory") as? Bool ?? true
        autoRecordMemory = defaults.object(forKey: "autoRecordMemory") as? Bool ?? true
        readImages = defaults.object(forKey: "readImages") as? Bool ?? true
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

    /// 所有会收到聊天内容的云端服务（大模型和 Jev），全在本机时为 nil。界面据此提示消息会不会发出去。
    var cloudProviderName: String? {
        let names = [engine != .systemOne ? llmCloudName : nil,
                     engine != .llm && systemOneProvider == .jev ? L("TypeSafe（Jev）", "TypeSafe (Jev)") : nil,
                     deapiEnabled ? L("deAPI（你点「听这条语音」时）", "deAPI (when you tap Listen)") : nil].compactMap { $0 }
        return names.isEmpty ? nil : names.joined(separator: L("、", ", "))
    }

    /// 大模型的云端服务名；本地 Ollama 为 nil。
    var llmCloudName: String? {
        switch llmProvider {
        case .ollama: return nil
        case .openai:
            let preset = OpenAIPreset.named(openAIPreset)
            return preset.id == "custom" ? (URL(string: openAIBaseURL)?.host() ?? L("云端服务", "cloud service")) : preset.name
        case .anthropic: return "Anthropic"
        }
    }

    /// 当前设置对应的分析器配置。
    func analyzerConfig() throws -> AnalyzerConfig {
        var config = AnalyzerConfig()
        config.engine = engine
        config.language = language
        if engine != .llm {
            switch systemOneProvider {
            case .kev:
                config.systemOne = .kev(baseURL: try url(systemOneURL))
            case .jev:
                guard !jevKey.isEmpty else {
                    throw AnalyzerError.badResponse(L("还没填 Jev 的 API Key：设置 → 分析引擎 → 决策模型来源",
                                                      "No Jev API key yet: Settings → Analysis engine → Decision model source"))
                }
                config.systemOne = .jev(baseURL: try url(jevURL), model: jevModel.isEmpty ? SystemOneSource.jevModel : jevModel,
                                        apiKey: jevKey)
            }
        }
        // 只用决策模型时不需要大模型的配置（比如大模型选了云端但还没填密钥）
        guard engine != .systemOne else { return config }
        switch llmProvider {
        case .ollama:
            config.llm = .ollama(baseURL: try url(ollamaURL), model: ollamaModel)
        case .openai:
            guard !openAIKey.isEmpty else {
                throw AnalyzerError.badResponse(L("还没填 API Key：设置 → 分析引擎 → OpenAI 兼容", "No API key yet: Settings → Analysis engine → OpenAI-compatible"))
            }
            guard !openAIModel.isEmpty else { throw AnalyzerError.badResponse(L("还没填模型名", "No model name yet")) }
            let preset = OpenAIPreset.named(openAIPreset)
            config.llm = .openAICompatible(baseURL: try url(openAIBaseURL), model: openAIModel, apiKey: openAIKey,
                                           supportsJSONSchema: preset.supportsJSONSchema,
                                           providerName: llmCloudName ?? preset.name)
        case .anthropic:
            guard !anthropicKey.isEmpty else {
                throw AnalyzerError.badResponse(L("还没填 Claude 的 API Key：设置 → 分析引擎 → Anthropic Claude",
                                                  "No Claude API key yet: Settings → Analysis engine → Anthropic Claude"))
            }
            config.llm = .anthropic(model: anthropicModel, apiKey: anthropicKey)
        }
        return config
    }


    private func url(_ text: String) throws -> URL {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)), url.host() != nil else {
            throw AnalyzerError.badResponse(L("地址格式不对：\(text)", "That URL doesn't look right: \(text)"))
        }
        return url
    }

    /// 打开了「用 deAPI 听语音」并且填了密钥。测试和录演示时可以用环境变量 EMOLENS_DEAPI_KEY（不写进钥匙串）。
    var canListenToVoice: Bool {
        (deapiEnabled && !deapiKey.isEmpty) || ProcessInfo.processInfo.environment["EMOLENS_DEAPI_KEY"] != nil
    }

    /// EMOLENS_DEAPI_URL 可以指向别的兼容地址（测试用）。
    var transcriber: DeAPITranscriber {
        let env = ProcessInfo.processInfo.environment
        return DeAPITranscriber(apiKey: env["EMOLENS_DEAPI_KEY"] ?? deapiKey, model: deapiModel,
                                baseURL: env["EMOLENS_DEAPI_URL"].flatMap(URL.init(string:)) ?? DeAPITranscriber.defaultURL)
    }
}
