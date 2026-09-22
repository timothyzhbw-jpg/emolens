import CoreGraphics
import EmoLensCore
import Foundation

enum EngineKind: String, CaseIterable, Identifiable {
    case llm, combined, systemOne

    var id: String { rawValue }

    var name: String {
        switch self {
        case .llm: "本地大模型"
        case .combined: "双引擎"
        case .systemOne: "决策模型"
        }
    }

    var detail: String {
        switch self {
        case .llm: "Ollama · 能读潜台词、给回复建议（推荐）"
        case .combined: "大模型 + Kev 复核严重信号，更稳，约多占 10 GB 内存"
        case .systemOne: "Kev · 校准概率，读不懂潜台词，较慢"
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
    @Published var relationship: String { didSet { defaults.set(relationship, forKey: "relationship") } }
    @Published var interval: Double { didSet { defaults.set(interval, forKey: "interval") } }
    @Published var windowID: CGWindowID { didSet { defaults.set(Int(windowID), forKey: "windowID") } }
    @Published var region: CGRect {
        didSet { defaults.set([region.minX, region.minY, region.width, region.height], forKey: "region") }
    }

    init() {
        engine = EngineKind(rawValue: defaults.string(forKey: "engine") ?? "") ?? .llm
        ollamaURL = defaults.string(forKey: "ollamaURL") ?? "http://127.0.0.1:11434"
        ollamaModel = defaults.string(forKey: "ollamaModel") ?? "qwen3.5:4b"
        systemOneURL = defaults.string(forKey: "systemOneURL") ?? "http://127.0.0.1:8009"
        relationship = defaults.string(forKey: "relationship") ?? "不确定"
        interval = defaults.object(forKey: "interval") as? Double ?? 1.5
        windowID = CGWindowID(defaults.integer(forKey: "windowID"))
        let r = defaults.array(forKey: "region") as? [Double] ?? [0, 0, 1, 1]
        region = r.count == 4 ? CGRect(x: r[0], y: r[1], width: r[2], height: r[3]) : CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    func makeAnalyzer() throws -> EmotionAnalyzer {
        switch engine {
        case .llm: return try llmAnalyzer()
        case .combined:
            let serious = CombinedAnalyzer.seriousFlags.map(\.rawValue)
            return CombinedAnalyzer(primary: try llmAnalyzer(), checker: try systemOneAnalyzer(only: serious))
        case .systemOne: return try systemOneAnalyzer()
        }
    }

    private func llmAnalyzer() throws -> OllamaAnalyzer {
        let prompt = try LLMPrompt.load(from: Presets.url("emotion.llm.zh.json"))
        return OllamaAnalyzer(baseURL: try url(ollamaURL), model: ollamaModel, prompt: prompt, relationship: relationship)
    }

    private func systemOneAnalyzer(only ids: [String]? = nil) throws -> SystemOneAnalyzer {
        var preset = try SystemOnePreset.load(from: Presets.url("emotion.zh.json"))
        if let ids { preset = preset.subset(ids) }
        return SystemOneAnalyzer(baseURL: try url(systemOneURL), preset: preset, relationship: relationship)
    }

    private func url(_ text: String) throws -> URL {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)), url.host() != nil else {
            throw AnalyzerError.badResponse("地址格式不对：\(text)")
        }
        return url
    }
}

/// 预设文件位置：环境变量 EMOLENS_PRESETS > .app 内 Resources/presets > 当前目录 presets/。
enum Presets {
    static var directory: URL {
        if let env = ProcessInfo.processInfo.environment["EMOLENS_PRESETS"] {
            return URL(fileURLWithPath: env)
        }
        if let bundled = Bundle.main.resourceURL?.appending(path: "presets"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "presets")
    }

    static func url(_ name: String) -> URL { directory.appending(path: name) }
}
