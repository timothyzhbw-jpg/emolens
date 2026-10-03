import Foundation

/// 把手动粘贴的聊天记录解析成消息列表。聊天软件复制出来的格式有好几种，这里都尽量认：
///
///     小美：你在干嘛           // 名字：内容
///     我: 在忙                // 半角冒号也行
///     小美 2026-09-22 12:30   // 名字 + 时间单独一行，内容在下一行
///     在干嘛呀
///     [10/3/26, 3:05 PM] Amy: hey      // 行首带时间戳的导出格式
///     Amy — Today at 3:05 PM           // 英文的「名字 + 时间」行
///
/// 认不出说话人的行，算作上一条消息的下一行（长消息会折行）。
public enum ChatTranscript {
    public struct Parsed: Equatable, Sendable {
        public var messages: [ChatMessage]
        /// 出现过的对方名字，按出现次数从多到少，用来猜「对方是谁」。
        public var names: [String]
    }

    public static let defaultMyNames: Set<String> = ["我", "自己", "本人", "me", "i", "you", "myself"]

    /// 名字 + 时间戳单独一行：「小美 2026-09-22 12:30:15」「小美 下午 3:05」。
    private static let header = regex(#"^(\S{1,20}?)\s+(?:\d{4}[-年]\d{1,2}[-月]\d{1,2}日?\s+)?(?:上午|下午|凌晨|晚上)?\s*\d{1,2}:\d{2}(?::\d{2})?$"#)
    /// 英文聊天软件复制出来的「名字 + 时间」行：「Alice — Today at 3:05 PM」「Alice, [10/3/2026 3:05 PM]」「Alice 3:05 PM」。
    /// 名字最多三个词、每个词大写开头，免得把「meet me at 3:05 PM」当成说话人。
    private static let englishHeader = regex(#"^((?:\p{Lu}[\p{L}'’.\-]*)(?:\s\p{Lu}[\p{L}'’.\-]*){0,2})\s*(?:,|—|–|-)?\s*\[?(?:(?:Today|Yesterday)(?:\s+at)?\s+|\d{1,2}/\d{1,2}/\d{2,4},?\s+)?\d{1,2}:\d{2}(?::\d{2})?\s?(?:[AaPp]\.?[Mm]\.?)?\]?$"#)
    /// 有些聊天软件导出的格式带行首时间戳：「[10/3/26, 3:05:12 PM] 」「10/3/26, 3:05 PM - 」，去掉后剩「名字: 内容」。
    private static let leadingStamp = regex(#"^\[?\d{1,4}[/.\-]\d{1,2}[/.\-]\d{1,4},?\s+\d{1,2}:\d{2}(?::\d{2})?\s?(?:[AaPp]\.?[Mm]\.?)?\]?\s*(?:-\s+)?"#)
    /// 英文的日期、时间分隔和「已送达 / 已读」状态行，跳过。
    private static let englishTimeOnly = regex(#"^(?i:(?:(?:Today|Yesterday|Mon(?:day)?|Tue(?:s|sday)?|Wed(?:nesday)?|Thu(?:rs|rsday)?|Fri(?:day)?|Sat(?:urday)?|Sun(?:day)?),?\s*)?(?:(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|June?|July?|Aug(?:ust)?|Sep(?:t|tember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\.?\s+\d{1,2}(?:,\s*\d{4})?,?\s*)?(?:\d{1,2}/\d{1,2}/\d{2,4},?\s*)?(?:(?:at\s+)?\d{1,2}:\d{2}(?::\d{2})?\s?(?:[ap]\.?m\.?)?)?|(?:Delivered|Seen|Read|Sent)(?:\s+(?:at\s+)?\d{1,2}:\d{2}\s?(?:[ap]m)?)?)$"#)
    /// 「名字：内容」。名字里不能有冒号或斜杠，免得把网址当成说话人；冒号前不能是数字，免得把「3:05」拆开。
    private static let prefixed = regex(#"^([^：:/\\]{1,20})(?<![0-9])[：:]\s*(.+)$"#)
    /// 只有日期或时间的行（微信里的时间分隔），跳过。
    private static let timeOnly = regex(#"^(?:昨天|今天|前天|星期[一二三四五六日天]|周[一二三四五六日天]|(?:\d{4}年)?\d{1,2}月\d{1,2}日)?\s*(?:上午|下午|凌晨|晚上)?\s*(?:\d{1,2}:\d{2}(?::\d{2})?)?$"#)

    public static func parse(_ text: String, myNames: Set<String> = defaultMyNames) -> Parsed {
        var collected: [(name: String?, text: String)] = []
        var pendingName: String?

        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            line = leadingStamp.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "")
            guard !line.isEmpty else { continue }
            // 先跳过纯时间行：「昨天 21:05」「Today 3:05 PM」不能被当成「名字 + 时间」
            if capture(timeOnly, line) != nil || capture(englishTimeOnly, line) != nil { continue }
            if let groups = capture(header, line) ?? capture(englishHeader, line) {
                pendingName = groups[0]
                continue
            }
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
