import EmoLensCore
import Foundation

/// 批量分析一个 JSONL 文件，走和应用里一样的代码路径（分析引擎 + 两层关键词兜底）。
/// 用法：EmoLens --eval 输入.jsonl 输出.jsonl
/// 输入每行：{"text": "对方说的话", "relationship": "恋人", "context": "我：…\n对方：…"}（后两项可选）
enum EvalRunner {
    struct Input: Decodable {
        var id: Int?
        var text: String
        var relationship: String?
        var context: String?
    }

    static func run(input: URL, output: URL) async throws {
        let lines = try String(contentsOf: input, encoding: .utf8).split(whereSeparator: \.isNewline)
        let config = AnalyzerConfig()
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
