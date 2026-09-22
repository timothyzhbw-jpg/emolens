import Foundation

/// 当前画面相对历史消息的变化。
public enum TrackerEvent: Equatable {
    /// 没有检测到新增消息。
    case unchanged
    /// 按画面顺序检测到的新增非系统消息。
    case appended([ChatMessage])
    /// 无历史匹配时返回当前完整可见消息。
    case reset([ChatMessage])
}

/// 使用最近消息的重叠部分检测新增消息。
public final class MessageTracker {
    /// 最多保存 200 条非系统消息。
    public private(set) var history: [ChatMessage] = []

    /// 创建空的消息历史。
    public init() {}

    /// 更新可见消息并返回新增、重置或未变化事件。
    public func update(_ visible: [ChatMessage]) -> TrackerEvent {
        let current = visible.filter { $0.speaker != .system }
        guard let last = history.last else { return reset(visible, current: current) }
        let match = current.indices.reversed().first { index in
            guard Self.matches(current[index], last) else { return false }
            return history.count < 2 || index == 0
                || Self.matches(current[index - 1], history[history.count - 2])
        }
        guard let index = match else { return reset(visible, current: current) }
        let added = Array(current.dropFirst(index + 1))
        guard !added.isEmpty else { return .unchanged }
        history = Array((history + added).suffix(200))
        return .appended(added)
    }

    /// 返回最近 limit 条非系统历史消息，负数按零处理。
    public func context(limit: Int) -> [ChatMessage] {
        Array(history.suffix(max(0, limit)))
    }

    /// 转为小写并仅保留 Unicode 字母和数字（包括汉字）。
    public static func normalize(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// 容忍标点变化、少量 OCR 错字和顶部文字截断。
    public static func similar(_ a: String, _ b: String) -> Bool {
        let a = normalize(a)
        let b = normalize(b)
        if a == b { return true }
        let left = Array(a)
        let right = Array(b)
        let shorter = left.count <= right.count ? a : b
        let longer = left.count <= right.count ? b : a
        if shorter.count >= 4, longer.contains(shorter) { return true }
        guard min(left.count, right.count) >= 2 else { return false }
        return 1 - Double(distance(left, right)) / Double(max(left.count, right.count)) >= 0.85
    }

    private func reset(_ visible: [ChatMessage], current: [ChatMessage]) -> TrackerEvent {
        history = Array(current.suffix(200))
        return .reset(visible)
    }

    private static func matches(_ a: ChatMessage, _ b: ChatMessage) -> Bool {
        a.speaker == b.speaker && similar(a.text, b.text)
    }

    private static func distance(_ a: [Character], _ b: [Character]) -> Int {
        var previous = Array(0...b.count)
        for (i, left) in a.enumerated() {
            var row = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, right) in b.enumerated() {
                row[j + 1] = min(row[j] + 1, previous[j + 1] + 1,
                                 previous[j] + (left == right ? 0 : 1))
            }
            previous = row
        }
        return previous[b.count]
    }
}
