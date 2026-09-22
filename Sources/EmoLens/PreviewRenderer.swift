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
        for (name, setup) in scenarios {
            for dark in [false, true] {
                let monitor = Monitor(settings: settings)
                setup(monitor)
                let url = directory.appending(path: "\(name)\(dark ? "-dark" : "").png")
                try render(PanelView(monitor: monitor, settings: settings, scrolls: false), dark: dark, to: url)
                print(url.path)
            }
        }
    }

    private static func render(_ view: some View, dark: Bool, to url: URL) throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        var image: CGImage?
        appearance.performAsCurrentDrawingAppearance {
            let content = view
                .frame(width: 372)
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

    private static let scenarios: [(String, (Monitor) -> Void)] = [
        ("report", { $0.loadPreview(status: .watching, reports: [Sample.sarcasm, Sample.coy, Sample.perfunctory]) }),
        ("manipulation", { $0.loadPreview(status: .watching, reports: [Sample.manipulation, Sample.sarcasm]) }),
        ("safety", { $0.loadPreview(status: .watching, reports: [Sample.selfHarm]) }),
        ("analyzing", { $0.loadPreview(status: .watching, reports: [Sample.coy], analyzing: true) }),
        ("onboarding", { $0.loadPreview(status: .noWindow(chosen: false), reports: [], windowName: "") }),
        ("error", { $0.loadPreview(status: .watching, reports: [],
                                   error: "连不上分析引擎（本地大模型）。请先在终端运行 ollama serve。") }),
    ]
}

/// 示例分析结果（虚构的对话）。
enum Sample {
    static let llm = "本地大模型 · qwen3.5:4b"

    static func them(_ text: String) -> ChatMessage { ChatMessage(speaker: .them, text: text, top: 0.8) }

    static func report(_ text: String, emotion: String, intensity: Double, flags: [EmotionFlag: Double],
                       response: String, consistency: String = "一致", target: String = "我",
                       literal: String? = nil, meaning: String? = nil, reply: String? = nil,
                       engine: String = llm, latency: Double = 3400, minutesAgo: Double = 0) -> EmotionReport {
        var r = EmotionReport(message: them(text), emotion: emotion, intensity: intensity,
                              flags: Dictionary(uniqueKeysWithValues: flags.map { ($0.key.rawValue, $0.value) }),
                              bestResponse: response, consistency: consistency, target: target,
                              literal: literal, realMeaning: meaning, suggestedReply: reply,
                              engine: engine, latencyMs: latency)
        r.date = Date(timeIntervalSinceNow: -minutesAgo * 60)
        return r
    }

    static let sarcasm = report(
        "没关系呀，你工作最重要嘛，我算什么", emotion: "委屈", intensity: 2,
        flags: [.angryAtMe: 1, .sarcasm: 1, .needsComfort: 1], response: "真诚道歉", consistency: "反话",
        literal: "你工作重要，我不重要", meaning: "嘴上说没关系，其实很在意你没顾上 TA，想被你哄一哄",
        reply: "是我不好，今天忙到忘了回你。你在我这儿比工作重要多了，晚上早点回来陪你好不好？")

    static let coy = report(
        "哼，这还差不多，快点回来陪我", emotion: "亲昵", intensity: 1, flags: [:], response: "正常聊天",
        consistency: "撒娇", literal: "这还差不多", meaning: "已经消气了，在撒娇等你回去",
        reply: "遵命！二十分钟到家，蛋糕给你留着最大块", latency: 2900, minutesAgo: 2)

    static let perfunctory = report(
        "嗯", emotion: "冷淡", intensity: 1, flags: [.perfunctory: 1, .coldDistance: 1], response: "给对方空间",
        consistency: "没说完", literal: "嗯", meaning: "还有点不开心，不太想多说", reply: "好，那我先忙完，晚点好好跟你说",
        latency: 3100, minutesAgo: 6)

    static let manipulation = report(
        "你要是真在乎我，就把手机密码告诉我，不然就是心里有鬼", emotion: "生气", intensity: 2.4,
        flags: [.angryAtMe: 1, .manipulation: 0.93, .testing: 0.62], response: "守住边界",
        literal: "告诉我密码才算在乎我", meaning: "用「在不在乎」逼你交出隐私，想掌控你的生活",
        reply: "我在乎你，也愿意聊聊你为什么不安。但手机是我的隐私，我们换个方式建立信任好吗？",
        engine: "\(llm) + 决策模型 · Kev", latency: 4200)

    static let selfHarm = report(
        "有时候觉得我消失了也不会有人在意吧", emotion: "难过", intensity: 3,
        flags: [.needsComfort: 1, .selfHarm: 0.6], response: "寻求帮助", target: "自己",
        meaning: "感到孤独和不被在乎", reply: "我在乎你，一直都在。你现在还好吗？我现在给你打个电话好不好？")
}
