import Foundation

/// 自伤信号的关键词兜底，和模型判断取并集：小模型会漏判，这类信号宁可多提醒。
/// 只收特异性高的说法（手段、计划、道别、自伤行为、以死相逼）；「笑死」「想死」「去死」这类日常夸张不收。
/// 名单来自 duxin 项目的实测（Kev 对「我已经把药都攒够了，谢谢你这几年对我好」给出 0.00）。
public enum SafetyNet {
    public static let patterns = [
        #"自杀"#, #"轻生"#, #"不想活"#, #"活不下去"#, #"活着没(有|什么)?意思"#, #"活着(真的)?好累"#,
        #"结束(自己|我)的?生命"#, #"了结自己"#, #"一了百了"#, #"遗书"#, #"遗言"#,
        #"跳楼"#, #"跳河"#, #"割腕"#, #"烧炭"#, #"上吊"#, #"划(了)?自己"#, #"伤害自己"#, #"安眠药"#,
        #"(攒|囤)[了够好齐多]{0,3}(安眠)?药"#, #"药.{0,2}(攒|囤)"#,
        #"永别"#, #"下辈子再见"#, #"再也不(用)?醒"#, #"不想(再)?醒来"#, #"一睡不醒"#,
        #"没有我.{0,6}(更好|轻松)"#, #"我(就)?是(个)?累赘"#, #"消失了也"#, #"消失算了"#, #"离开这个世界"#,
        #"撑不下去了"#, #"我不在了"#, #"我就去死"#,
        #"(?i:suicid)"#, #"(?i:kill myself)"#, #"(?i:end (it all|my life))"#, #"(?i:(cut|hurt|harm)(ting)? myself)"#,
        #"(?i:self[- ]harm)"#, #"(?i:better off without me)"#,
    ]

    private static let regex = try! NSRegularExpression(pattern: patterns.map { "(?:\($0))" }.joined(separator: "|"))

    /// 命中时给的概率：明显低于模型确信的 1.0，界面会显示为「可能」。
    public static let probability = 0.6

    /// 返回命中的片段；没有命中返回 nil。去掉空白后再匹配一次，防止「不 想 活」这类写法漏掉。
    public static func match(_ text: String) -> String? {
        for candidate in [text, text.filter { !$0.isWhitespace }] {
            let range = NSRange(candidate.startIndex..., in: candidate)
            if let hit = regex.firstMatch(in: candidate, range: range), let found = Range(hit.range, in: candidate) {
                return String(candidate[found])
            }
        }
        return nil
    }

    public static func matches(_ text: String) -> Bool { match(text) != nil }

    /// 命中关键词且模型没标出时，把自伤概率提到 probability。
    public static func apply(to report: EmotionReport) -> EmotionReport {
        guard matches(report.message.text) else { return report }
        var report = report
        let key = EmotionFlag.selfHarm.rawValue
        report.flags[key] = max(report.flags[key] ?? 0, probability)
        return report
    }
}
