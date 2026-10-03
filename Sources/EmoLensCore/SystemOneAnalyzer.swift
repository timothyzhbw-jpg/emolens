import Foundation

/// System One 问题集（presets/emotion.zh.json）。questions 原样发给服务端。
public struct SystemOnePreset: @unchecked Sendable {
    public let questions: [String: Any]
    /// 问题集的语言，决定聊天记录用中文还是英文框架。
    public var language: AppLanguage = .zh

    public init(questions: [String: Any], language: AppLanguage = .zh) {
        self.questions = questions
        self.language = language
    }

    public static func load(from url: URL) throws -> SystemOnePreset {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        guard let questions = json?["questions"] as? [String: Any] else {
            throw AnalyzerError.badResponse(L("预设文件缺少 questions", "the preset file has no questions"))
        }
        let language = (json?["language"] as? String).flatMap(AppLanguage.init(rawValue:)) ?? .zh
        return SystemOnePreset(questions: questions, language: language)
    }

    /// choice 选项的界面标签：描述里冒号（「：」或英文的「:」）之前的部分。
    func label(question: String, key: String) -> String {
        let criteria = (questions[question] as? [String: Any])?["criteria"] as? [String: String]
        let text = criteria?[key] ?? key
        return text.components(separatedBy: CharacterSet(charactersIn: "：:")).first ?? text
    }
}

/// 调用兼容 TypeSafe System One API 的决策模型服务，返回校准过的概率：
/// 本机的 Kev（不需要密钥），或 TypeSafe 云端的 Jev（Authorization: Bearer 密钥）。两者请求和返回的格式相同。
public struct SystemOneAnalyzer: EmotionAnalyzer {
    public var source: SystemOneSource
    public var preset: SystemOnePreset
    public var relationship: String?
    public var memory: String?
    public var name: String { source.name }

    public init(source: SystemOneSource = .localKev, preset: SystemOnePreset,
                relationship: String? = nil, memory: String? = nil) {
        self.source = source
        self.preset = preset
        self.relationship = relationship
        self.memory = memory
    }

    public func analyze(context: [ChatMessage], latest: ChatMessage) async throws -> EmotionReport {
        let body: [String: Any] = [
            "state": ChatState.render(context: context, latest: latest, relationship: relationship, memory: memory,
                                      language: preset.language),
            "model": source.model,
            "questions": preset.questions,
        ]
        var headers: [String: String] = [:]
        if let key = source.apiKey { headers["Authorization"] = "Bearer \(key)" }
        let start = Date()
        // 本机 Kev 第一次请求要加载模型，可能要几分钟；云端 Jev 一般一秒内
        let response = try await HTTP.post(source.baseURL.appending(path: "v1/systemone"), body: body, headers: headers,
                                           service: source.serviceName, timeout: source.apiKey == nil ? 300 : 30)
        let latency = Date().timeIntervalSince(start) * 1000
        guard let answers = response["answers"] as? [String: [String: Any]] else {
            throw AnalyzerError.badResponse(L("缺少 answers", "missing answers"))
        }
        return report(answers: answers, message: latest, latencyMs: latency)
    }

    func report(answers: [String: [String: Any]], message: ChatMessage, latencyMs: Double) -> EmotionReport {
        let emotionKey = answers["emotion"]?["choice"] as? String ?? ""
        let probabilities = answers["emotion"]?["probabilities"] as? [String: Double]
        var flags: [String: Double] = [:]
        for flag in EmotionFlag.allCases {
            flags[flag.rawValue] = (answers[flag.rawValue]?["noul"] as? NSNumber)?.doubleValue ?? 0
        }
        // 反话不直接问：决策模型对「嘴上说没事、心里其实生气吗」只会答后半句（duxin 实测 34%）。
        // 改成问可观察的 says_fine，再按规则推出（同一测试 98%）。
        if let saysFine = (answers["says_fine"]?["noul"] as? NSNumber)?.doubleValue {
            let positive = ["joy", "affection"].contains(emotionKey)
            flags[EmotionFlag.sarcasm.rawValue] = saysFine >= 0.5 && !positive ? saysFine : 0
        }
        let responseKey = answers["best_response"]?["choice"] as? String
        // 标签按问题集的语言写（「委屈」或「Hurt」），统一换回中文规范值。
        let emotion = preset.label(question: "emotion", key: emotionKey)
        return EmotionReport(
            message: message,
            emotion: Vocabulary.canonical(emotion, in: Vocabulary.emotions) ?? Vocabulary.canonical(emotionKey, in: Vocabulary.emotions) ?? emotion,
            emotionProbability: probabilities?[emotionKey],
            intensity: (answers["intensity"]?["score"] as? NSNumber)?.doubleValue ?? 0,
            flags: flags,
            bestResponse: responseKey.map { key in
                let label = preset.label(question: "best_response", key: key)
                return Vocabulary.canonical(label, in: Vocabulary.responses) ?? Vocabulary.canonical(key, in: Vocabulary.responses) ?? label
            },
            engine: name,
            latencyMs: latencyMs
        )
    }
}

extension SystemOnePreset {
    /// 只保留部分问题，例如双引擎模式里只让决策模型判严重信号。
    public func subset(_ ids: [String]) -> SystemOnePreset {
        SystemOnePreset(questions: questions.filter { ids.contains($0.key) }, language: language)
    }
}

/// 双引擎：生成式模型读潜台词、写回复；决策模型并行判严重信号，两者取较高的概率。
/// 决策模型失败时退回单引擎结果。
public struct CombinedAnalyzer: EmotionAnalyzer {
    public static let seriousFlags: [EmotionFlag] = [.angryAtMe, .conflict, .manipulation, .selfHarm, .asksMoney]

    public var primary: EmotionAnalyzer
    public var checker: EmotionAnalyzer
    /// 复核引擎最多等这么久，超时就只用主引擎的结果，不拖慢整体。
    public var checkerTimeout: Duration
    public var name: String { "\(primary.name) + \(checker.name)" }

    public init(primary: EmotionAnalyzer, checker: EmotionAnalyzer, checkerTimeout: Duration = .seconds(12)) {
        self.primary = primary
        self.checker = checker
        self.checkerTimeout = checkerTimeout
    }

    public func analyze(context: [ChatMessage], latest: ChatMessage) async throws -> EmotionReport {
        async let main = primary.analyze(context: context, latest: latest)
        async let check = Self.withTimeout(checkerTimeout) { [checker] in
            try await checker.analyze(context: context, latest: latest)
        }
        var report = try await main
        guard let extra = await check else {
            report.engine = L("\(primary.name)（\(checker.name) 未响应）", "\(primary.name) (\(checker.name) didn't respond)")
            return report
        }
        for flag in Self.seriousFlags {
            report.flags[flag.rawValue] = max(report.flags[flag.rawValue] ?? 0, extra.flags[flag.rawValue] ?? 0)
        }
        report.engine = name
        report.latencyMs = max(report.latencyMs, extra.latencyMs)
        return report
    }

    /// 在时限内完成则返回结果；超时或出错返回 nil。
    static func withTimeout<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async throws -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { try? await work() }
            group.addTask { try? await Task.sleep(for: limit); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
