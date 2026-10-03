import AppKit
import EmoLensCore
import SwiftUI

/// 用示例数据把面板渲染成 PNG：`EmoLens --render-previews <目录>`。不截屏、不读任何聊天。
@MainActor
enum PreviewRenderer {
    static func renderAll(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = AppSettings()
        settings.relationship = "恋人"
        // 用临时文件里的示例记忆，绝不碰用户真实的记忆。
        let memoryURL = FileManager.default.temporaryDirectory.appending(path: "emolens-preview-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: memoryURL) }
        let memory = ContactMemoryStore(fileURL: memoryURL)
        Sample.fillMemory(memory)
        for (name, setup) in scenarios {
            for dark in [false, true] {
                let monitor = Monitor(settings: settings, memory: memory)
                setup(monitor)
                let url = directory.appending(path: "\(name)\(dark ? "-dark" : "").png")
                try render(PanelView(monitor: monitor, settings: settings, scrolls: false), dark: dark, to: url)
                print(url.path)
            }
        }
        for dark in [false, true] {
            let monitor = Monitor(settings: settings, memory: memory)
            monitor.loadPreview(status: .paused, reports: [Sample.manual])
            let sample = L("小美：没事，你忙你的\n我：晚点补给你好不好\n小美 21:40\n算了，你开心就好",
                           "Mia: it's fine, do your thing\nMe: let me make it up to you later?\nMia — Today at 9:40 PM\nwhatever, as long as you're happy")
            let url = directory.appending(path: "manual\(dark ? "-dark" : "").png")
            try render(VStack(spacing: 12) {
                ManualView(monitor: monitor, settings: settings, transcript: .constant(sample), editable: false)
                ReportView(report: Sample.manual, isLatest: true, analyzing: false)
            }.padding(14), dark: dark, to: url)
            print(url.path)
        }
        for dark in [false, true] {
            let monitor = Monitor(settings: settings, memory: memory)
            let url = directory.appending(path: "memory-sheet\(dark ? "-dark" : "").png")
            try render(MemoryView(monitor: monitor, settings: settings, contact: Sample.contact, scrolls: false), dark: dark, to: url, width: 420)
            print(url.path)
        }
    }

    private static func render(_ view: some View, dark: Bool, to url: URL, width: CGFloat = 372) throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        var image: CGImage?
        appearance.performAsCurrentDrawingAppearance {
            let content = view
                .frame(width: width)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            image = renderer.cgImage
        }
        guard let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: url)
    }

    private static var scenarios: [(String, (Monitor) -> Void)] { [
        ("report", { $0.loadPreview(status: .watching, reports: [Sample.sarcasm, Sample.coy, Sample.perfunctory]) }),
        ("memory", { $0.loadPreview(status: .watching, reports: [Sample.withMemoryNote, Sample.coy]) }),
        ("manipulation", { $0.loadPreview(status: .watching, reports: [Sample.manipulation, Sample.sarcasm]) }),
        ("safety", { $0.loadPreview(status: .watching, reports: [Sample.selfHarm]) }),
        ("analyzing", { $0.loadPreview(status: .watching, reports: [Sample.coy], analyzing: true) }),
        ("voice-emoji", { $0.loadPreview(status: .watching, reports: [Sample.smileEmoji], pendingVoice: 6) }),
        ("onboarding", { $0.loadPreview(status: .noWindow(chosen: false), reports: [], windowName: "") }),
        ("error", { $0.loadPreview(status: .watching, reports: [],
                                   error: L("连不上分析引擎（本地大模型）。请先在终端运行 ollama serve。",
                                            "Can't reach the analysis engine (language model). Run ollama serve in Terminal first.")) }),
    ] }
}

/// 示例分析结果（虚构的对话）。情绪、回应方式等用中文规范值，界面按语言显示。
enum Sample {
    static var llm: String { L("本地大模型 · qwen3.5:4b", "Local model · qwen3.5:4b") }
    static var contact: String { L("小美", "Mia") }

    static func them(_ text: String) -> ChatMessage { ChatMessage(speaker: .them, text: text, top: 0.8) }

    static func report(_ text: String, emotion: String, intensity: Double, flags: [EmotionFlag: Double],
                       response: String, consistency: String = "一致", target: String = "我",
                       literal: String? = nil, meaning: String? = nil, reply: String? = nil,
                       engine: String? = nil, latency: Double = 3400, minutesAgo: Double = 0) -> EmotionReport {
        var r = EmotionReport(message: them(text), emotion: emotion, intensity: intensity,
                              flags: Dictionary(uniqueKeysWithValues: flags.map { ($0.key.rawValue, $0.value) }),
                              bestResponse: response, consistency: consistency, target: target,
                              literal: literal, realMeaning: meaning, suggestedReply: reply,
                              engine: engine ?? llm, latencyMs: latency)
        r.date = Date(timeIntervalSinceNow: -minutesAgo * 60)
        r.contact = contact
        return r
    }

    static var withMemoryNote: EmotionReport {
        var r = report(L("这周要准备期末，可能没空出去了，别生气哈", "finals are this week so I prob can't go out, don't be mad ok"),
                       emotion: "焦虑", intensity: 1,
                       flags: [.needsComfort: 1], response: "安慰共情", consistency: "一致", target: "自己",
                       meaning: L("压力很大，怕你失望，希望你能理解", "Really stressed and worried you'll be let down — hoping you understand"),
                       reply: L("没事，考试最重要！需要的话我给你带奶茶，考完我们再去玩", "Of course, exams come first! Want me to drop off coffee? We'll celebrate after"))
        r.memoryNote = L("这周在准备期末考试", "Studying for finals this week")
        return r
    }

    /// 预览用的示例记忆（虚构）。
    static func fillMemory(_ store: ContactMemoryStore) {
        store.update(contact) { memory in
            memory.relationship = "恋人"
            memory.notes = [
                .init(text: L("最近在准备考研，压力很大", "Studying for grad school entrance exams, very stressed"), source: .user,
                      date: Date(timeIntervalSinceNow: -9 * 86_400)),
                .init(text: L("不喜欢被说「你想多了」", "Hates being told \"you're overthinking it\""), source: .user,
                      date: Date(timeIntervalSinceNow: -6 * 86_400)),
                .init(text: L("10 月 12 日生日", "Birthday is Oct 12"), source: .ai, date: Date(timeIntervalSinceNow: -2 * 86_400)),
            ]
            let history: [(String, String, [String: Double], Double)] = [
                (L("今天好累啊", "so tired today"), "难过", [:], 9),
                (L("你怎么又不回消息", "why do you never text back"), "委屈", ["angry_at_me": 1], 6),
                (L("哦", "k"), "冷淡", ["perfunctory": 1, "cold_distance": 1], 5),
                (L("没事，你忙吧", "it's fine, go be busy"), "失望", ["sarcasm": 1], 3),
                (L("哼，这还差不多", "hmph. that's more like it"), "亲昵", [:], 2),
                (L("哈哈哈你好笨", "lol you're such a dork"), "开心", [:], 1),
                (L("嗯", "ok"), "冷淡", ["perfunctory": 1], 0.5),
            ]
            for (text, emotion, flags, days) in history {
                var r = report(text, emotion: emotion, intensity: 1, flags: [:], response: "正常聊天")
                r.flags = flags
                r.date = Date(timeIntervalSinceNow: -days * 86_400)
                memory.record(r)
            }
        }
    }

    static var sarcasm: EmotionReport { report(
        L("没关系呀，你工作最重要嘛，我算什么", "no it's fine, work is obviously more important. who am i anyway"),
        emotion: "委屈", intensity: 2,
        flags: [.angryAtMe: 1, .sarcasm: 1, .needsComfort: 1], response: "真诚道歉", consistency: "反话",
        literal: L("你工作重要，我不重要", "Your work matters, I don't"),
        meaning: L("嘴上说没关系，其实很在意你没顾上 TA，想被你哄一哄", "Says it's fine, but really hurt you didn't make time — wants you to reassure them"),
        reply: L("是我不好，今天忙到忘了回你。你在我这儿比工作重要多了，晚上早点回来陪你好不好？",
                 "That's on me, I got buried and forgot to text back. You matter way more than work — I'll be home early tonight, ok?")) }

    static var coy: EmotionReport { report(
        L("哼，这还差不多，快点回来陪我", "hmph. that's more like it. now hurry home"), emotion: "亲昵", intensity: 1, flags: [:], response: "正常聊天",
        consistency: "撒娇", literal: L("这还差不多", "That's more like it"),
        meaning: L("已经消气了，在撒娇等你回去", "Not mad anymore — playfully waiting for you to come home"),
        reply: L("遵命！二十分钟到家，蛋糕给你留着最大块", "Yes ma'am! Home in 20, saving you the biggest slice of cake"), latency: 2900, minutesAgo: 2) }

    static var smileEmoji: EmotionReport { report(
        "\(L("好的", "ok"))[表情：\(L("微笑", "slight smile"))]", emotion: "失望", intensity: 2, flags: [.angryAtMe: 1, .sarcasm: 1, .perfunctory: 1],
        response: "真诚道歉", consistency: "反话", literal: L("好的，配了一个微笑表情", "\"ok\" with a slight-smile emoji"),
        meaning: L("又被放鸽子了，心里不高兴，用微笑表情表示无语", "Got stood up again and is annoyed — the 🙂 means \"I'm done\", not happy"),
        reply: L("对不起，又让你等了。周六我空出来，带你去吃你想吃的那家，好不好？",
                 "I'm sorry I kept you waiting again. I'm clearing Saturday — let's go to that place you've been wanting to try?"),
        latency: 4300, minutesAgo: 0) }

    static var perfunctory: EmotionReport { report(
        L("嗯", "ok"), emotion: "冷淡", intensity: 1, flags: [.perfunctory: 1, .coldDistance: 1], response: "给对方空间",
        consistency: "没说完", literal: L("嗯", "ok"), meaning: L("还有点不开心，不太想多说", "Still a bit upset and doesn't feel like talking"),
        reply: L("好，那我先忙完，晚点好好跟你说", "Ok, I'll wrap up here and we can talk properly later"),
        latency: 3100, minutesAgo: 6) }

    static var manipulation: EmotionReport { report(
        L("你要是真在乎我，就把手机密码告诉我，不然就是心里有鬼", "if you really cared about me you'd give me your phone passcode. otherwise you're obviously hiding something"),
        emotion: "生气", intensity: 2.4,
        flags: [.angryAtMe: 1, .manipulation: 0.93, .testing: 0.62], response: "守住边界",
        literal: L("告诉我密码才算在乎我", "Give me your passcode or you don't care"),
        meaning: L("用「在不在乎」逼你交出隐私，想掌控你的生活", "Using \"do you care\" to pressure you into giving up your privacy — trying to control you"),
        reply: L("我在乎你，也愿意聊聊你为什么不安。但手机是我的隐私，我们换个方式建立信任好吗？",
                 "I do care, and I want to hear why you're feeling insecure. But my phone is my privacy — let's find another way to build trust."),
        engine: "\(llm) + \(L("决策模型 · Kev", "Decision model · Kev"))", latency: 4200) }

    static var manual: EmotionReport {
        report(L("算了，你开心就好", "whatever, as long as you're happy"), emotion: "失望", intensity: 2,
               flags: [.angryAtMe: 1, .sarcasm: 1, .needsComfort: 1],
               response: "真诚道歉", consistency: "反话", literal: L("算了，你开心就好", "Never mind, do what makes you happy"),
               meaning: L("等了很久没等到答复，已经不想再争，但心里在意", "Waited a long time for an answer, done arguing — but still cares"),
               reply: L("对不起，是我一直拖着。现在就给你打电话，好不好？", "I'm sorry I kept putting it off. Can I call you right now?"))
    }

    static var selfHarm: EmotionReport { report(
        L("有时候觉得我消失了也不会有人在意吧", "sometimes i feel like nobody would even notice if i disappeared"), emotion: "难过", intensity: 3,
        flags: [.needsComfort: 1, .selfHarm: 0.6], response: "寻求帮助", target: "自己",
        meaning: L("感到孤独和不被在乎", "Feeling lonely and like nobody cares"),
        reply: L("我在乎你，一直都在。你现在还好吗？我现在给你打个电话好不好？", "I care about you, and I'm here. Are you ok right now? Can I call you?")) }
}
