import Foundation

/// 界面和分析用的语言。中文是原版；English 用英文提示词、英文界面、英文的安全网词表和求助热线。
/// 情绪、信号、回应方式、关系在内部一律用中文规范值保存（记忆文件、配色、测试都按它），显示时再翻译。
public enum AppLanguage: String, CaseIterable, Sendable, Codable {
    case zh, en

    /// 当前语言：应用启动和切换语言时写入；单元测试默认中文。
    nonisolated(unsafe) public static var current: AppLanguage = .zh

    /// 系统首选语言是中文时用中文，否则用英文。
    public static var system: AppLanguage {
        (Locale.preferredLanguages.first ?? "").hasPrefix("zh") ? .zh : .en
    }

    public var name: String { self == .zh ? "中文" : "English" }

    public func pick(_ zh: String, _ en: String) -> String { self == .zh ? zh : en }
}

/// 按当前语言挑文字。
public func L(_ zh: String, _ en: String) -> String { AppLanguage.current.pick(zh, en) }

/// 一个规范值（中文）和它的英文：en 是英文提示词里让模型输出的标签，label 是英文界面上显示的文字，
/// aliases 是其他能认出来的写法（决策模型的选项 id、模型偶尔换的同义词）。
public struct Term: Sendable {
    public let zh: String
    public let en: String
    public let label: String
    public let aliases: [String]

    init(_ zh: String, _ en: String, label: String? = nil, aliases: [String] = []) {
        self.zh = zh
        self.en = en
        self.label = label ?? (en.prefix(1).uppercased() + String(en.dropFirst()))
        self.aliases = aliases
    }

    var keys: [String] { ([en] + aliases).map(Vocabulary.normalize) }
}

/// 情绪、字面与真实想法、情绪指向、建议回应、双方关系的中英对照。
public enum Vocabulary {
    public static let emotions = [
        Term("开心", "happy", aliases: ["joy", "joyful", "excited"]),
        Term("平静", "calm", aliases: ["neutral"]),
        Term("亲昵", "affectionate", aliases: ["affection", "loving"]),
        Term("难过", "sad", aliases: ["sadness", "upset"]),
        Term("委屈", "hurt", aliases: ["wronged", "aggrieved"]),
        Term("生气", "angry", aliases: ["anger", "mad", "annoyed"]),
        Term("失望", "disappointed", aliases: ["disappointment"]),
        Term("焦虑", "anxious", aliases: ["anxiety", "worried", "nervous"]),
        Term("冷淡", "cold", aliases: ["distant", "indifferent"]),
        Term("尴尬", "embarrassed", aliases: ["awkward", "shy"]),
        Term("未知", "unknown"),
    ]

    /// 顺序有讲究：模型偶尔写「不一致，反话」，按包含关系找时「一致」要放最后。
    public static let consistency = [
        Term("反话", "sarcastic", label: "Sarcastic", aliases: ["sarcasm", "ironic", "passive aggressive"]),
        Term("撒娇", "playful", label: "Playful sulking", aliases: ["teasing", "coy"]),
        Term("没说完", "holding back", label: "Holding back", aliases: ["unsaid", "hinting"]),
        Term("一致", "sincere", label: "Means it", aliases: ["consistent", "literal", "genuine"]),
    ]

    /// 「me」包含在「someone」里，按包含关系找时放最后。
    public static let targets = [
        Term("自己", "themselves", label: "at themselves", aliases: ["self", "himself", "herself"]),
        Term("别人", "someone else", label: "at someone else", aliases: ["others", "other people"]),
        Term("这件事", "the situation", label: "at the situation", aliases: ["situation", "the thing"]),
        Term("我", "me", label: "at you", aliases: ["you", "the user"]),
    ]

    public static let responses = [
        Term("安慰共情", "comfort", label: "Comfort them", aliases: ["empathize", "empathy"]),
        Term("真诚道歉", "apologize", label: "Apologize sincerely", aliases: ["apology"]),
        Term("解释澄清", "clarify", label: "Clarify calmly", aliases: ["explain"]),
        Term("给对方空间", "give space", label: "Give them space", aliases: ["space"]),
        Term("用行动关心", "show care", label: "Show up for them", aliases: ["act", "show up"]),
        Term("正常聊天", "chat normally", label: "Chat as usual", aliases: ["casual", "chat"]),
        Term("守住边界", "hold boundary", label: "Hold your boundary", aliases: ["boundary", "set boundary"]),
        Term("核实身份", "verify identity", label: "Verify it's them", aliases: ["verify"]),
        Term("寻求帮助", "get help", label: "Get help", aliases: ["seek help", "seek_help"]),
    ]

    public static let relationships = [
        Term("不确定", "not sure", label: "Not sure", aliases: ["unknown", "unsure"]),
        Term("恋人", "partner", aliases: ["romantic partner", "boyfriend", "girlfriend", "spouse", "couple", "dating"]),
        Term("家人", "family", aliases: ["parent", "mom", "dad", "sibling"]),
        Term("朋友", "friend", aliases: ["friends"]),
        Term("同事", "coworker", aliases: ["colleague", "boss", "work"]),
        Term("同学", "classmate", aliases: ["schoolmate", "school"]),
    ]

    /// 把模型（或用户）给的任意写法认成规范值：先找完全一致的，再找包含的。认不出返回 nil。
    public static func canonical(_ raw: String?, in terms: [Term]) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let key = normalize(raw)
        if let term = terms.first(where: { $0.zh == raw || $0.keys.contains(key) }) { return term.zh }
        return terms.first { term in raw.contains(term.zh) || term.keys.contains { key.contains($0) } }?.zh
    }

    /// 规范值在当前语言下的显示文字；不在表里的原样返回。
    public static func display(_ value: String?, in terms: [Term], language: AppLanguage = .current) -> String {
        guard let value else { return "" }
        guard language == .en else { return value }
        return terms.first { $0.zh == value }?.label ?? value
    }

    /// 写进英文提示词里的说法（小写的模型标签）。
    public static func english(_ value: String?, in terms: [Term]) -> String? {
        guard let value else { return nil }
        let zh = canonical(value, in: terms) ?? value
        return terms.first { $0.zh == zh }?.en ?? value
    }

    static func normalize(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }
}
