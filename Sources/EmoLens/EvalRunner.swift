import EmoLensCore
import Foundation

/// 批量分析一个 JSONL 文件，走和应用里一样的代码路径（分析引擎 + 两层关键词兜底）。
/// 用法：EmoLens --eval 输入.jsonl 输出.jsonl
/// 输入每行：{"text": "对方说的话", "relationship": "恋人", "context": "我：…\n对方：…"}（后两项可选）
///
/// 默认用本地大模型。环境变量可以换引擎（变量名和 TypeSafe 官方 SDK 一致）：
///   EMOLENS_ENGINE=llm | combined | systemOne
///   TYPESAFE_API_KEY=…（设了就用 Jev）、TYPESAFE_BASE_URL、TYPESAFE_DEFAULT_MODEL
///   EMOLENS_KEV_URL=http://127.0.0.1:8009（本机 Kev 的地址）
enum EvalRunner {
    static func config(_ env: [String: String] = ProcessInfo.processInfo.environment) -> AnalyzerConfig {
        var config = AnalyzerConfig()
        if let engine = env["EMOLENS_ENGINE"].flatMap(Engine.init(rawValue:)) { config.engine = engine }
        if let key = env["TYPESAFE_API_KEY"], !key.isEmpty {
            config.systemOne = .jev(baseURL: env["TYPESAFE_BASE_URL"].flatMap(URL.init(string:)) ?? SystemOneSource.jevURL,
                                    model: env["TYPESAFE_DEFAULT_MODEL"] ?? SystemOneSource.jevModel, apiKey: key)
        } else if let kev = env["EMOLENS_KEV_URL"].flatMap(URL.init(string:)) {
            config.systemOne = .kev(baseURL: kev)
        }
        return config
    }

    struct Input: Decodable {
        var id: Int?
        var text: String
        var relationship: String?
        var context: String?
    }

    static func run(input: URL, output: URL) async throws {
        let lines = try String(contentsOf: input, encoding: .utf8).split(whereSeparator: \.isNewline)
        let config = config()
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var results: [Data] = []
        for (index, line) in lines.enumerated() {
            guard let item = try? decoder.decode(Input.self, from: Data(line.utf8)) else { continue }
            let context = (item.context ?? "").split(whereSeparator: \.isNewline).map { line -> ChatMessage in
                let text = String(line)
                return text.hasPrefix("我：")
                    ? ChatMessage(speaker: .me, text: String(text.dropFirst(2)), top: 0)
                    : ChatMessage(speaker: .them, text: text.replacingOccurrences(of: "对方：", with: ""), top: 0)
            }
            let latest = ChatMessage(speaker: .them, text: item.text, top: 1)
            let analyzer = try config.makeAnalyzer(relationship: item.relationship)
            do {
                let analyzed = try await analyzer.analyze(context: context, latest: latest)
                let report = MoneyNet.apply(to: SafetyNet.apply(to: analyzed))
                results.append(try encoder.encode(report))
                FileHandle.standardError.write(Data("\(index + 1)/\(lines.count) \(report.emotion)\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("\(index + 1)/\(lines.count) 失败：\(error.localizedDescription)\n".utf8))
                results.append(Data(#"{"error": true}"#.utf8))
            }
        }
        try Data(results.map { $0 + Data("\n".utf8) }.reduce(Data(), +)).write(to: output)
    }
}
