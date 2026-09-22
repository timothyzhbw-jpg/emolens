import Foundation

/// 把手动粘贴的聊天记录解析成消息列表。微信复制出来的格式有好几种，这里都尽量认：
///
///     小美：你在干嘛           // 名字：内容
///     我: 在忙                // 半角冒号也行
///     小美 2026-09-22 12:30   // 名字 + 时间单独一行，内容在下一行
///     在干嘛呀
///
/// 认不出说话人的行，算作上一条消息的下一行（长消息会折行）。
public enum ChatTranscript {
    public struct Parsed: Equatable, Sendable {
        public var messages: [ChatMessage]
        /// 出现过的对方名字，按出现次数从多到少，用来猜「对方是谁」。
        public var names: [String]
    }

    public static let defaultMyNames: Set<String> = ["我", "自己", "本人", "me", "i"]

    /// 名字 + 时间戳单独一行：「小美 2026-09-22 12:30:15」「小美 下午 3:05」。
    private static let header = regex(#"^(.{1,20}?)\s+(?:\d{4}[-年]\d{1,2}[-月]\d{1,2}日?\s+)?(?:上午|下午|凌晨|晚上)?\s*\d{1,2}:\d{2}(?::\d{2})?$"#)
    /// 「名字：内容」。名字里不能有冒号或斜杠，免得把网址当成说话人。
    private static let prefixed = regex(#"^([^：:/\\]{1,20})[：:]\s*(.+)$"#)
    /// 只有日期或时间的行（微信里的时间分隔），跳过。
    private static let timeOnly = regex(#"^(?:昨天|今天|前天|星期[一二三四五六日天]|周[一二三四五六日天]|(?:\d{4}年)?\d{1,2}月\d{1,2}日)?\s*(?:上午|下午|凌晨|晚上)?\s*(?:\d{1,2}:\d{2}(?::\d{2})?)?$"#)

    public static func parse(_ text: String, myNames: Set<String> = defaultMyNames) -> Parsed {
        var collected: [(name: String?, text: String)] = []
        var pendingName: String?

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let groups = capture(header, line) {
                pendingName = groups[0]
                continue
            }
            if capture(timeOnly, line) != nil { continue }
            // 「https://…」里的冒号不是说话人，冒号后面紧跟 // 就当普通内容
            if let groups = capture(prefixed, line), !groups[1].hasPrefix("//") {
                collected.append((groups[0], groups[1]))
                pendingName = nil
                continue
            }
            if let name = pendingName {
                collected.append((name, line))
                pendingName = nil
            } else if var last = collected.popLast() {
                last.text += "\n" + line
                collected.append(last)
            } else {
                collected.append((nil, line))   // 没有任何说话人信息：先当成对方说的
            }
        }

        var counts: [String: Int] = [:]
        for item in collected {
            if let name = item.name, !isMe(name, myNames) { counts[name, default: 0] += 1 }
        }
        let names = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
        let messages = collected.enumerated().map { index, item in
            ChatMessage(speaker: item.name.map { isMe($0, myNames) ? .me : .them } ?? .them,
                        text: item.text,
                        sender: item.name.flatMap { isMe($0, myNames) ? nil : $0 },
                        top: Double(index))
        }
        return Parsed(messages: messages, names: names)
    }

    private static func isMe(_ name: String, _ myNames: Set<String>) -> Bool {
        myNames.contains(name) || myNames.contains(name.lowercased())
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }

    /// 返回各个捕获组的文字；不匹配返回 nil。
    private static func capture(_ regex: NSRegularExpression, _ line: String) -> [String]? {
        guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: line).map { String(line[$0]).trimmingCharacters(in: .whitespaces) }
        }
    }
}
