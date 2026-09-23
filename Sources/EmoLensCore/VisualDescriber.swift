import CryptoKit
import Foundation

/// 看图读懂表情和表情包：把截图交给分析用的同一个大模型（要能看图，默认的 qwen3.5:4b 可以），
/// 再把消息里的占位符换成具体描述，例如「[表情]」→「[表情：捂脸]」，「[表情包]」→「[表情包：猫咪翻白眼，写着「无语」]」。
/// 表情一个一个单独问：实测把整个气泡给 4B 模型看，🙄 会说成「疑惑」、🤦 说成「微笑」；只截表情、放大后就对了。
public struct VisualDescriber: Sendable {
    public var backend: ChatBackend

    public init(backend: ChatBackend) {
        self.backend = backend
    }

    static let system = "你帮用户看懂微信聊天截图里的表情和图片。只输出一个 JSON 对象，不要解释。"

    static let emojiQuestion = """
    这是对方在微信里发的一个表情（小图标），已经放大。用 2 到 6 个字说出它是什么表情、表达什么，\
    例如「捂脸」「翻白眼」「笑哭」「微笑」「流泪」「生气」。输出 JSON：{"emoji": "…"}
    """

    static func pictureQuestion(sticker: Bool) -> String {
        """
        截图是对方发来的一张\(sticker ? "表情包" : "图片")。用一句不超过 30 个字的话描述：画面是什么、上面写了什么字、\
        想表达什么情绪或态度。输出 JSON：{"description": "…"}
        """
    }

    /// 一个表情的名字（放大后的表情截图，PNG）。
    public func name(emoji image: Data) async throws -> String {
        try await ask(Self.emojiQuestion, image: image, key: "emoji")
    }

    /// 表情包或图片的一句话描述。
    public func describe(picture image: Data, sticker: Bool) async throws -> String {
        try await ask(Self.pictureQuestion(sticker: sticker), image: image, key: "description")
    }

    private func ask(_ question: String, image: Data, key: String) async throws -> String {
        let answer = try await backend.complete(system: Self.system,
                                                turns: [ChatTurn(role: "user", content: question, images: [image])], schema: nil)
        guard let json = LLMAnalyzer.parseObject(answer) else { throw AnalyzerError.badResponse(String(answer.prefix(200))) }
        let value = (json[key] as? String) ?? (json[key] as? [String])?.first ?? ""
        let cleaned = Self.clean(value)
        guard !cleaned.isEmpty else { throw AnalyzerError.badResponse("模型没有给出\(key)") }
        return cleaned
    }

    /// 看懂一条消息里的图：表情逐个问名字，表情包、图片问一句描述，再填回正文。
    /// known 是以前看过的（图片内容的哈希 → 答案），同一个表情不用再问；返回这次新学到的。
    public func read(_ message: ChatMessage, images: [Data], known: [String: String] = [:]) async throws
        -> (message: ChatMessage, learned: [String: String]) {
        guard let kind = message.attachment?.kind, kind != .voice, !images.isEmpty else { return (message, [:]) }
        var learned: [String: String] = [:]
        var answers: [String] = []
        for image in images {
            let key = Self.key(image)
            if let answer = known[key] ?? learned[key] {
                answers.append(answer)
                continue
            }
            let answer = kind == .emoji ? try await name(emoji: image) : try await describe(picture: image, sticker: kind == .sticker)
            learned[key] = answer
            answers.append(answer)
        }
        let filled = kind == .emoji ? Self.filling(message, emoji: answers) : Self.filling(message, description: answers[0])
        return (filled, learned)
    }

    public static func key(_ image: Data) -> String {
        SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
    }

    /// 按顺序把表情名字填进「[表情]」：每处表情有几个就占几个占位符，挨着的同一个表情合并成「[表情：捂脸×3]」。
    public static func filling(_ message: ChatMessage, emoji names: [String]) -> ChatMessage {
        guard !names.isEmpty else { return message }
        let counts = message.attachment?.emoji.map(\.count) ?? []
        var expanded: [String] = []
        for (index, name) in names.enumerated() {
            expanded += Array(repeating: name, count: index < counts.count ? counts[index] : 1)
        }
        var parts = message.text.components(separatedBy: Placeholder.emoji)
        var text = parts.removeFirst()
        var index = 0
        while index < parts.count {
            let name = index < expanded.count ? expanded[index] : expanded[expanded.count - 1]
            var run = 1
            while index + run < parts.count, parts[index + run - 1].isEmpty,
                  (index + run < expanded.count ? expanded[index + run] : expanded[expanded.count - 1]) == name {
                run += 1
            }
            text += "[表情：\(name)\(run > 1 ? "×\(run)" : "")]" + parts[index + run - 1]
            index += run
        }
        var result = message
        result.text = text
        return result
    }

    /// 把表情包、图片的描述填进去。
    public static func filling(_ message: ChatMessage, description: String) -> ChatMessage {
        var result = message
        result.text = "[\(message.attachment?.kind == .sticker ? "表情包" : "图片")：\(description)]"
        return result
    }

    /// 去掉方括号（免得和占位符混在一起）、句号和多余空白，限制长度。
    static func clean(_ text: String) -> String {
        let trimmed = text.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "。")))
        return String(trimmed.prefix(60))
    }
}
