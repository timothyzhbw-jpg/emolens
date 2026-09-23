import Foundation
import CoreGraphics

/// 一行 OCR 文字，坐标原点在左上角。
public struct OCRLine: Equatable, Sendable {
    /// OCR 识别出的原始文字。
    public let text: String
    /// 归一化坐标中的文字边框。
    public let box: CGRect
    /// OCR 识别置信度。
    public let confidence: Float

    /// 创建带归一化坐标的 OCR 行。
    public init(text: String, box: CGRect, confidence: Float = 1) {
        self.text = text
        self.box = box
        self.confidence = confidence
    }
}

/// 聊天消息的说话人类型。
public enum Speaker: String, Codable, Sendable { case them, me, system }

/// 从 OCR 行还原的聊天消息。
public struct ChatMessage: Equatable, Codable, Sendable {
    /// 消息所属的说话人类型。
    public let speaker: Speaker
    /// 合并折行后的正文。
    public var text: String
    /// 群聊昵称，无昵称时为 nil。
    public var sender: String?
    /// 正文首行的 minY。
    public let top: Double
    /// 不是纯文字时（语音、表情、表情包、图片）的附加信息。
    public var attachment: Attachment?

    /// 创建消息，top 为正文首行的纵坐标。
    public init(speaker: Speaker, text: String, sender: String? = nil, top: Double, attachment: Attachment? = nil) {
        self.speaker = speaker
        self.text = text
        self.sender = sender
        self.top = top
        self.attachment = attachment
    }
}

/// 消息里不是纯文字的部分。
public struct Attachment: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case voice, emoji, sticker, image }

    public var kind: Kind
    /// 语音时长（秒）。
    public var seconds: Int?
    /// 语音是否已经在微信里转成了文字。
    public var transcribed: Bool
    /// 在聊天区域截图里的位置（归一化，原点左上）。看表情包、图片时按它截图给模型。
    public var box: CGRect?
    /// 文字里每个表情的位置，顺序和正文里的「[表情]」一致；挨着的同一个表情算一处，count 是个数。
    public var emoji: [LayoutBlock.Emoji]

    public init(kind: Kind, seconds: Int? = nil, transcribed: Bool = false, box: CGRect? = nil, emoji: [LayoutBlock.Emoji] = []) {
        self.kind = kind
        self.seconds = seconds
        self.transcribed = transcribed
        self.box = box
        self.emoji = emoji
    }

    /// 需要看图才能读懂（表情、表情包、图片）。
    public var isVisual: Bool { kind != .voice }
    /// 对方发了语音，但还没转文字：没有内容可分析。
    public var isUntranscribedVoice: Bool { kind == .voice && !transcribed }
}

/// 写进消息正文的占位符。模型看得懂；看图以后换成具体描述，比如「[表情：捂脸]」。
public enum Placeholder {
    public static let emoji = "[表情]"
    public static let sticker = "[表情包]"
    public static let image = "[图片]"
    public static let transcript = "[语音转文字]"
    public static func voice(_ seconds: Int?) -> String { seconds.map { "[语音 \($0)秒]" } ?? "[语音]" }
}

/// 气泡分类、昵称识别和折行合并的阈值。
public struct ParserConfig: Sendable {
    /// 保留 OCR 行所需的最低置信度。
    public var minConfidence: Float = 0.3
    /// 居中短行的左右边距差阈值。
    public var centerTolerance: Double = 0.06
    /// 合并间距相对于行高中位数的阈值。
    public var mergeGapFactor: Double = 0.6
    /// 同气泡对齐边的最大偏差阈值。
    public var alignTolerance: Double = 0.03
    /// 昵称行高相对于行高中位数的阈值。
    public var metaHeightRatio: Double = 0.8

    /// 使用默认的微信布局阈值。
    public init() {}
}

/// 根据文字位置还原聊天气泡。
public enum ChatParser {
    /// 输入任意顺序的 OCR 行，输出按正文 top 排序的消息。
    /// layout 是从像素找出来的气泡、表情包和头像（LayoutDetector）；有它时按气泡分消息，
    /// 能认出只发了表情、表情包、语音这些 OCR 读不到字的消息。imageSize 是聊天区域截图的像素尺寸。
    public static func parse(_ lines: [OCRLine], layout: [LayoutBlock] = [], imageSize: CGSize = CGSize(width: 1, height: 1),
                             config: ParserConfig = .init()) -> [ChatMessage] {
        let rows = clean(lines, config: config)
        guard layout.contains(where: { $0.kind != .avatar }) else { return parseText(rows, config: config) }
        return parseBlocks(rows, layout: layout, imageSize: imageSize, config: config)
    }

    private static func clean(_ lines: [OCRLine], config: ParserConfig) -> [OCRLine] {
        lines.compactMap { line -> OCRLine? in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.confidence >= config.minConfidence, !text.isEmpty else { return nil }
            return OCRLine(text: text, box: line.box, confidence: line.confidence)
        }.sorted {
            if $0.box.minY != $1.box.minY { return $0.box.minY < $1.box.minY }
            if $0.box.minX != $1.box.minX { return $0.box.minX < $1.box.minX }
            return $0.text < $1.text
        }
    }

    private static func median(_ rows: [OCRLine]) -> Double {
        let heights = rows.map { Double($0.box.height) }.sorted()
        guard !heights.isEmpty else { return 0.03 }
        return (heights[(heights.count - 1) / 2] + heights[heights.count / 2]) / 2
    }

    /// 只有文字、没有版面信息时：按每行的左右位置判断说话人，再把折行合并。
    static func parseText(_ input: [OCRLine], config: ParserConfig) -> [ChatMessage] {
        guard !input.isEmpty else { return [] }
        let median = median(input)
        let rows = joinSameRow(input, median: median, config: config)
        let speakers = rows.map { speaker(for: $0, config: config) }
        var messages: [ChatMessage] = []
        var previous: OCRLine?
        var sender: String?

        for index in rows.indices {
            let row = rows[index]
            let kind = speakers[index]
            if kind == .them, row.box.height < config.metaHeightRatio * median,
               index + 1 < rows.count, speakers[index + 1] == .them,
               rows[index + 1].box.height >= config.metaHeightRatio * median,
               rows[index + 1].box.minY - row.box.maxY < config.mergeGapFactor * median {
                sender = row.text
                previous = nil
                continue
            }
            if let prev = previous, let last = messages.last,
               last.speaker == kind, kind != .system, last.attachment == nil,
               row.box.minY - prev.box.maxY < config.mergeGapFactor * median,
               abs(edge(row, kind) - edge(prev, kind)) < config.alignTolerance {
                messages[messages.count - 1].text += joiner(last.text, row.text) + row.text
            } else if kind != .system, let seconds = voiceSeconds(row.text) {
                messages.append(ChatMessage(speaker: kind, text: Placeholder.voice(seconds), sender: sender,
                                            top: Double(row.box.minY), attachment: Attachment(kind: .voice, seconds: seconds)))
            } else {
                messages.append(ChatMessage(speaker: kind, text: row.text, sender: sender,
                                            top: Double(row.box.minY)))
            }
            sender = nil
            previous = row
        }
        return messages
    }

    /// 同一行被 OCR 切成了几段（中间夹着表情时常见），按从左到右拼回一行。
    /// OCR 结果先按 minY 排序，这种情况下右边那段可能排在左边前面。
    static func joinSameRow(_ rows: [OCRLine], median: Double, config: ParserConfig) -> [OCRLine] {
        var result: [OCRLine] = []
        var used = Set<Int>()
        for i in rows.indices where !used.contains(i) {
            var group = [rows[i]]
            let side = speaker(for: rows[i], config: config)
            for j in rows.indices where j > i && !used.contains(j) {
                let other = rows[j]
                guard other.box.minY <= rows[i].box.maxY, sameRow(rows[i].box, other.box),
                      side != .system, speaker(for: other, config: config) == side else { continue }
                group.append(other)
                used.insert(j)
            }
            guard group.count > 1 else { result.append(rows[i]); continue }
            group.sort { $0.box.minX < $1.box.minX }
            let text = group.dropFirst().reduce(group[0].text) { $0 + " " + $1.text }
            let box = group.dropFirst().reduce(group[0].box) { $0.union($1.box) }
            result.append(OCRLine(text: text, box: box, confidence: group.map(\.confidence).min() ?? 1))
        }
        return result.sorted { $0.box.minY < $1.box.minY }
    }

    /// 两个框竖直方向重叠一半以上，算同一行。
    static func sameRow(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        return overlap >= 0.5 * min(a.height, b.height)
    }

    /// 拼接两段文字：两边都是英文字母或数字时加空格，中文直接连上。
    static func joiner(_ left: String, _ right: String) -> String {
        isASCIIAlphanumeric(left.last) && isASCIIAlphanumeric(right.first) ? " " : ""
    }

    // MARK: - 语音

    private static let voicePattern = try! NSRegularExpression(pattern: #"(\d{1,2})\s*["”“″'’‘〃]{1,2}"#)

    /// 语音气泡里的时长，比如 5"、12”。OCR 常把旁边的声波图标读成「1」「)))」「》」，
    /// 前后允许有几个这样的杂字，但剩下的不能是一句话。
    public static func voiceSeconds(_ text: String) -> Int? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard text.count <= 10,
              let match = voicePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let whole = Range(match.range, in: text), let digits = Range(match.range(at: 1), in: text),
              let seconds = Int(text[digits]), (1...60).contains(seconds) else { return nil }
        let rest = text.replacingCharacters(in: whole, with: "").filter { !$0.isWhitespace }
        guard rest.count <= 4, rest.range(of: #"\p{Han}{2}"#, options: .regularExpression) == nil else { return nil }
        return seconds
    }

    /// 语音气泡里只有声波图标时，OCR 会读出「)))」「》」「小))」这类杂字。
    static func isVoiceIconNoise(_ text: String) -> Bool {
        let chars = text.filter { !$0.isWhitespace }
        return !chars.isEmpty && chars.count <= 4 && chars.allSatisfy { ")）》»〉>]|l1小((《«〈<[".contains($0) }
    }

    // MARK: - 按气泡解析

    static func parseBlocks(_ rows: [OCRLine], layout: [LayoutBlock], imageSize: CGSize, config: ParserConfig) -> [ChatMessage] {
        let unit = median(rows)
        let avatars = layout.filter { $0.kind == .avatar }.map(\.box)
        let blocks = layout.filter { $0.kind != .avatar }.sorted { $0.box.minY < $1.box.minY }
        let pixelsPerUnitX = Double(imageSize.width), pixelsPerUnitY = Double(imageSize.height)

        // 每行 OCR 文字归到它所在的块里；头像上的字丢掉；不在任何块里的（时间、昵称、系统提示）另外处理。
        var inside = Array(repeating: [OCRLine](), count: blocks.count)
        var loose: [OCRLine] = []
        for row in rows {
            let center = CGPoint(x: row.box.midX, y: row.box.midY)
            if avatars.contains(where: { $0.contains(center) }) { continue }
            if let i = blocks.firstIndex(where: { $0.box.insetBy(dx: -0.004, dy: -0.004).contains(center) }) {
                inside[i].append(row)
            } else {
                loose.append(row)
            }
        }

        // 长语音的时长显示在气泡外面，归到同一行的气泡上。
        var outsideSeconds: [Int: Int] = [:]
        loose.removeAll { line in
            guard let seconds = voiceSeconds(line.text),
                  let i = blocks.indices.filter({ blocks[$0].kind == .bubble && sameRow(blocks[$0].box, line.box) })
                    .min(by: { horizontalGap(blocks[$0].box, line.box) < horizontalGap(blocks[$1].box, line.box) })
            else { return false }
            outsideSeconds[i] = seconds
            return true
        }
        // 透明底表情包下面的字，可能和图断开了。
        loose.removeAll { line in
            guard let i = blocks.indices.first(where: { blocks[$0].kind == .media
                && line.box.minY >= blocks[$0].box.minY && line.box.minY - blocks[$0].box.maxY <= unit
                && line.box.midX >= blocks[$0].box.minX && line.box.midX <= blocks[$0].box.maxX }) else { return false }
            inside[i].append(line)
            return true
        }
        // 群聊昵称：对方气泡正上方、左边对齐的一行短字（时间和系统提示是居中的）。
        var senders: [Int: String] = [:]
        loose.removeAll { line in
            guard !isTimestamp(line.text), line.text.count <= 24,
                  let i = blocks.indices.first(where: { i in
                      let box = blocks[i].box
                      let gap = Double(box.minY - line.box.maxY)
                      return side(of: box, avatars: avatars, unit: unit, config: config) == .them
                          && gap >= -0.004 && gap <= 1.0 * unit && abs(box.minX - line.box.minX) < 0.05
                  }) else { return false }
            senders[i] = line.text
            return true
        }

        var messages = parseText(loose, config: config)
        var lastBlock: (index: Int, side: Speaker, box: CGRect)?
        for (i, block) in blocks.enumerated() {
            let speaker = side(of: block.box, avatars: avatars, unit: unit, config: config)
            let lines = inside[i]
            var message: ChatMessage?
            switch block.kind {
            case .media:
                let text = lines.map(\.text).joined(separator: " ")
                let size = CGSize(width: block.box.width * pixelsPerUnitX, height: block.box.height * pixelsPerUnitY)
                let aspect = size.width / max(1, size.height)
                let unitPixels = unit * pixelsPerUnitY
                let sticker = (0.6...1.7).contains(aspect) && max(size.width, size.height) <= max(1, unitPixels) * 12
                let label = sticker ? "表情包" : "图片"
                let body = text.isEmpty ? "[\(label)]" : "[\(label)：\(String(text.prefix(40)))\(text.count > 40 ? "…" : "")]"
                message = ChatMessage(speaker: speaker, text: body, sender: senders[i], top: Double(block.box.minY),
                                      attachment: Attachment(kind: sticker ? .sticker : .image, box: block.box))
            case .bubble:
                let voiceLine = lines.firstIndex { voiceSeconds($0.text) != nil }
                let seconds = voiceLine.flatMap { voiceSeconds(lines[$0].text) } ?? outsideSeconds[i]
                if let seconds {
                    // 语音：去掉时长和声波图标，剩下的字是气泡里直接显示的转文字结果
                    let rest = lines.enumerated().filter { $0.offset != voiceLine && !isVoiceIconNoise($0.element.text) }.map(\.element)
                    let transcript = rowText(rest, emoji: [], unit: unit)
                    message = ChatMessage(speaker: speaker,
                                          text: transcript.isEmpty ? Placeholder.voice(seconds) : Placeholder.transcript + " " + transcript,
                                          sender: senders[i], top: Double(block.box.minY),
                                          attachment: Attachment(kind: .voice, seconds: seconds, transcribed: !transcript.isEmpty))
                } else if let last = lastBlock, last.side == speaker, speaker != .system,
                          let m = messages.lastIndex(where: { $0.top == Double(last.box.minY) && $0.speaker == speaker }),
                          isContinuation(block.box, after: last.box, side: speaker, avatars: avatars, unit: unit) {
                    // 语音下面的转文字框；或者引用框（新版微信把被引用的话放在消息下面）
                    let text = rowText(lines, emoji: block.emoji, unit: unit)
                    guard !text.isEmpty else { continue }
                    if messages[m].attachment?.kind == .voice {
                        messages[m].text = Placeholder.transcript + " " + text
                        messages[m].attachment?.transcribed = true
                    } else if !avatars.isEmpty || isQuote(text) {
                        messages[m].text += "（引用：\(text)）"
                    } else {
                        message = ChatMessage(speaker: speaker, text: text, sender: senders[i], top: Double(block.box.minY))
                    }
                } else {
                    let text = rowText(lines, emoji: block.emoji, unit: unit)
                    if !text.isEmpty {
                        message = ChatMessage(speaker: speaker, text: text, sender: senders[i], top: Double(block.box.minY),
                                              attachment: block.emoji.isEmpty ? nil : Attachment(kind: .emoji, box: block.box, emoji: block.emoji))
                    } else if lines.contains(where: { isVoiceIconNoise($0.text) }) {
                        // 只有声波图标、时长没读出来的语音
                        message = ChatMessage(speaker: speaker, text: Placeholder.voice(nil), sender: senders[i],
                                              top: Double(block.box.minY), attachment: Attachment(kind: .voice))
                    }
                }
            case .avatar:
                continue
            }
            if let message {
                messages.append(message)
                lastBlock = (i, speaker, block.box)
            }
        }
        return messages.sorted { $0.top < $1.top }
    }

    /// 块在左边是对方，在右边是我；居中又没有头像的是系统提示。
    static func side(of box: CGRect, avatars: [CGRect], unit: Double, config: ParserConfig) -> Speaker {
        let left = box.minX, right = 1 - box.maxX
        if abs(left - right) < config.centerTolerance,
           !avatars.contains(where: { Double(box.minY - $0.minY) > -0.8 * max(unit, 0.01) && Double(box.minY - $0.minY) < 2.2 * max(unit, 0.01) }) {
            return .system
        }
        return left < right ? .them : .me
    }

    /// 紧贴在上一个同侧气泡下面、自己没有头像的框：转文字结果或引用。
    static func isContinuation(_ box: CGRect, after previous: CGRect, side: Speaker, avatars: [CGRect], unit: Double) -> Bool {
        let gap = Double(box.minY - previous.maxY)
        guard gap >= -0.002, gap <= 0.6 * unit else { return false }
        let aligned = side == .them ? abs(box.minX - previous.minX) < 0.03 : abs(box.maxX - previous.maxX) < 0.03
        guard aligned else { return false }
        // 自己有头像（顶端对齐，或群聊里低一行昵称）的是一条新消息
        return !avatars.contains { Double(box.minY - $0.minY) > -0.6 * unit && Double(box.minY - $0.minY) < 2.2 * unit }
    }

    /// 一个气泡里的文字：同一行的几段从左到右拼起来，表情放在它所在的位置。
    static func rowText(_ lines: [OCRLine], emoji: [LayoutBlock.Emoji], unit: Double) -> String {
        let pieces = lines + emoji.map {
            OCRLine(text: String(repeating: Placeholder.emoji, count: $0.count), box: $0.box)
        }
        let sorted = pieces.sorted { $0.box.midY < $1.box.midY }
        var rows: [[OCRLine]] = []
        for piece in sorted {
            if let last = rows.last?.last, abs(Double(piece.box.midY - last.box.midY)) < 0.5 * max(unit, 0.005)
                || sameRow(last.box, piece.box) {
                rows[rows.count - 1].append(piece)
            } else {
                rows.append([piece])
            }
        }
        var text = ""
        for row in rows {
            for piece in row.sorted(by: { $0.box.minX < $1.box.minX }) {
                let isEmoji = piece.text.hasPrefix(Placeholder.emoji)
                text += (text.isEmpty || isEmoji || text.hasSuffix("]") ? "" : joiner(text, piece.text)) + piece.text
            }
        }
        return text
    }

    /// 引用框里是「名字：原话」。
    static func isQuote(_ text: String) -> Bool {
        text.range(of: #"^[^：:\s]{1,20}[：:]"#, options: .regularExpression) != nil
    }

    static func horizontalGap(_ a: CGRect, _ b: CGRect) -> Double {
        Double(max(0, max(a.minX, b.minX) - min(a.maxX, b.maxX)))
    }

    private static func speaker(for line: OCRLine, config: ParserConfig) -> Speaker {
        let left = line.box.minX
        let right = 1 - line.box.maxX
        if isTimestamp(line.text) || (abs(left - right) < config.centerTolerance && line.box.width < 0.5) {
            return .system
        }
        return left < right ? .them : .me
    }

    private static func isTimestamp(_ text: String) -> Bool {
        let pattern = #"^(?:(?:今天|昨天|前天|星期[一二三四五六日天]|周[一二三四五六日天]|(?:\d{4}年)?\d{1,2}月\d{1,2}日)\s*)?(?:凌晨|早上|上午|中午|下午|晚上)?\s*(?:[01]?\d|2[0-3])[:：][0-5]\d$"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func edge(_ line: OCRLine, _ speaker: Speaker) -> Double {
        Double(speaker == .them ? line.box.minX : line.box.maxX)
    }

    private static func isASCIIAlphanumeric(_ character: Character?) -> Bool {
        guard let character, character.unicodeScalars.count == 1,
              let value = character.unicodeScalars.first?.value else { return false }
        return (48...57).contains(value) || (65...90).contains(value) || (97...122).contains(value)
    }
}
