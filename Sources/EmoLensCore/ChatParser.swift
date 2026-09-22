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

    /// 创建消息，top 为正文首行的纵坐标。
    public init(speaker: Speaker, text: String, sender: String? = nil, top: Double) {
        self.speaker = speaker
        self.text = text
        self.sender = sender
        self.top = top
    }
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
    public static func parse(_ lines: [OCRLine], config: ParserConfig = .init()) -> [ChatMessage] {
        let rows = lines.compactMap { line -> OCRLine? in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.confidence >= config.minConfidence, !text.isEmpty else { return nil }
            return OCRLine(text: text, box: line.box, confidence: line.confidence)
        }.sorted {
            if $0.box.minY != $1.box.minY { return $0.box.minY < $1.box.minY }
            if $0.box.minX != $1.box.minX { return $0.box.minX < $1.box.minX }
            return $0.text < $1.text
        }
        guard !rows.isEmpty else { return [] }
        let heights = rows.map { Double($0.box.height) }.sorted()
        let median = (heights[(heights.count - 1) / 2] + heights[heights.count / 2]) / 2
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
               last.speaker == kind, kind != .system,
               row.box.minY - prev.box.maxY < config.mergeGapFactor * median,
               abs(edge(row, kind) - edge(prev, kind)) < config.alignTolerance {
                let space = isASCIIAlphanumeric(last.text.last) && isASCIIAlphanumeric(row.text.first)
                messages[messages.count - 1].text += (space ? " " : "") + row.text
            } else {
                messages.append(ChatMessage(speaker: kind, text: row.text, sender: sender,
                                            top: Double(row.box.minY)))
            }
            sender = nil
            previous = row
        }
        return messages
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
