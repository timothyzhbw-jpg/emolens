import Foundation

/// 自伤信号的关键词兜底：小模型可能漏判，这类信号宁可多提醒。
/// 刻意不收「笑死」「气死」「我要死了」这类口头禅。
public enum SafetyNet {
    public static let phrases = [
        "不想活", "活着没意思", "活着没什么意思", "活着好累", "不想醒来", "一睡不醒", "消失了也", "消失算了",
        "离开这个世界", "结束生命", "结束自己", "自杀", "轻生", "割腕", "跳楼", "跳下去", "安眠药",
        "撑不下去了", "没有我会更好", "我不在了", "不如死了", "想去死", "活不下去",
    ]

    /// 命中时给的概率：明显低于模型确信的 1.0，界面会显示为「可能」。
    public static let probability = 0.6

    public static func matches(_ text: String) -> Bool {
        let compact = text.filter { !$0.isWhitespace }
        return phrases.contains { compact.contains($0) }
    }

    /// 命中关键词且模型没标出时，把自伤概率提到 probability。
    public static func apply(to report: EmotionReport) -> EmotionReport {
        guard matches(report.message.text) else { return report }
        var report = report
        let key = EmotionFlag.selfHarm.rawValue
        report.flags[key] = max(report.flags[key] ?? 0, probability)
        return report
    }
}
