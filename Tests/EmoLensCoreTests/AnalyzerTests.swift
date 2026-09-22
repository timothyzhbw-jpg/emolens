@testable import EmoLensCore
import XCTest

final class AnalyzerTests: XCTestCase {
    private let latest = ChatMessage(speaker: .them, text: "没事，你玩得开心就好", top: 0.8)

    func testLLMOutputIsParsedLeniently() throws {
        let content = """
        好的，结果如下：{"emotion":"委屈","intensity":"2","consistency":"反话","target":"我",
        "angry_at_me":"true","needs_comfort":1,"self_harm":false,"testing":85,
        "real_meaning":"其实很失落","best_response":"真诚道歉","suggested_reply":"对不起"}
        """
        let r = try OllamaAnalyzer.report(from: content, message: latest, engine: "t", latencyMs: 1)
        XCTAssertEqual(r.emotion, "委屈")
        XCTAssertEqual(r.intensity, 2)
        XCTAssertEqual(r.consistency, "反话")
        XCTAssertEqual(r.target, "我")
        XCTAssertEqual(r.flags["angry_at_me"], 1)
        XCTAssertEqual(r.flags["needs_comfort"], 1)
        XCTAssertEqual(r.flags["testing"], 0.85)
        XCTAssertEqual(r.flags["self_harm"], 0)
        XCTAssertEqual(r.flags["sarcasm"], 1, "反话应自动带上阴阳怪气标记")
        XCTAssertEqual(r.activeFlags(), [.angryAtMe, .sarcasm, .needsComfort, .testing])
    }

    func testLLMOutputWithoutJSONThrows() {
        XCTAssertThrowsError(try OllamaAnalyzer.report(from: "抱歉，我无法回答", message: latest, engine: "t", latencyMs: 1))
    }

    func testConsistencyIsNormalized() throws {
        let messy = #"{"emotion":"冷淡","consistency":"敷衍或不想争了（「哦」「都行」「你看着办」）"}"#
        XCTAssertNil(try OllamaAnalyzer.report(from: messy, message: latest, engine: "t", latencyMs: 1).consistency)
        let wrapped = #"{"emotion":"委屈","consistency":"反话（嘴上说没事）"}"#
        XCTAssertEqual(try OllamaAnalyzer.report(from: wrapped, message: latest, engine: "t", latencyMs: 1).consistency, "反话")
    }

    func testCurlyQuoteDelimitersAreRepaired() throws {
        let broken = #"{"emotion": "生气", "real_meaning": “想控制我”, "suggested_reply": "我们聊聊“信任”这件事吧”}"#
        let r = try OllamaAnalyzer.report(from: broken, message: latest, engine: "t", latencyMs: 1)
        XCTAssertEqual(r.realMeaning, "想控制我")
        XCTAssertEqual(r.suggestedReply, "我们聊聊“信任”这件事吧", "字符串内部的中文引号要保留")
    }

    func testExamplesAreEncodedInPromptOrder() throws {
        let text = try OllamaAnalyzer.encodeInOrder([
            "suggested_reply": .string("好"), "emotion": .string("开心"), "literal": .string("嗯"), "intensity": .number(1),
        ])
        XCTAssertEqual(text, #"{"literal": "嗯", "emotion": "开心", "intensity": 1, "suggested_reply": "好"}"#)
    }

    func testIntensityIsClamped() throws {
        let r = try OllamaAnalyzer.report(from: #"{"emotion":"生气","intensity":9}"#, message: latest, engine: "t", latencyMs: 1)
        XCTAssertEqual(r.intensity, 3)
        XCTAssertTrue(r.activeFlags().isEmpty)
    }

    func testSystemOneAnswersMapToReport() {
        let preset = SystemOnePreset(questions: [
            "emotion": ["type": "choice", "criteria": ["hurt": "委屈：觉得被忽视", "calm": "平静：没有情绪"]],
            "best_response": ["type": "choice", "criteria": ["apologize": "真诚道歉：承认问题"]],
        ])
        let analyzer = SystemOneAnalyzer(preset: preset)
        let answers: [String: [String: Any]] = [
            "emotion": ["choice": "hurt", "probabilities": ["hurt": 0.7, "calm": 0.3]],
            "intensity": ["score": 2.4],
            "manipulation": ["noul": 0.9],
            "sarcasm": ["noul": 0.2],
            "best_response": ["choice": "apologize"],
        ]
        let r = analyzer.report(answers: answers, message: latest, latencyMs: 5)
        XCTAssertEqual(r.emotion, "委屈")
        XCTAssertEqual(r.emotionProbability, 0.7)
        XCTAssertEqual(r.intensity, 2.4)
        XCTAssertEqual(r.bestResponse, "真诚道歉")
        XCTAssertEqual(r.activeFlags(), [.manipulation])
    }

    func testStateIncludesRelationshipAndSpeakers() {
        let context = [
            ChatMessage(speaker: .me, text: "今晚聚餐", top: 0.1),
            ChatMessage(speaker: .them, text: "哦", sender: "小美", top: 0.3),
        ]
        let text = ChatState.render(context: context, latest: latest, relationship: "恋人")
        XCTAssertTrue(text.hasPrefix("双方关系：恋人\n"))
        XCTAssertTrue(text.contains("我：今晚聚餐\n对方（小美）：哦"))
        XCTAssertTrue(text.hasSuffix("需要分析的是对方最新这条：\n对方：没事，你玩得开心就好"))
        XCTAssertFalse(ChatState.render(context: [], latest: latest, relationship: "不确定").contains("双方关系"))
    }

    func testBundledPresetsLoad() throws {
        let presets = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../../presets").standardized
        let prompt = try LLMPrompt.load(from: presets.appending(path: "emotion.llm.zh.json"))
        XCTAssertGreaterThanOrEqual(prompt.examples.count, 6)
        for example in prompt.examples {
            XCTAssertNotNil(example.answer["consistency"], example.chat)
            XCTAssertNotNil(example.answer["suggested_reply"], example.chat)
        }
        let preset = try SystemOnePreset.load(from: presets.appending(path: "emotion.zh.json"))
        for flag in EmotionFlag.allCases {
            XCTAssertNotNil(preset.questions[flag.rawValue], "Kev 问题集缺少 \(flag.rawValue)")
        }
    }
}

final class SafetyNetTests: XCTestCase {
    func testPassiveIdeationIsCaught() {
        XCTAssertTrue(SafetyNet.matches("有时候觉得我消失了也不会有人在意吧"))
        XCTAssertTrue(SafetyNet.matches("真的 撑不下去了"))
        XCTAssertTrue(SafetyNet.matches("活着没什么意思"))
    }

    func testHyperboleIsIgnored() {
        XCTAssertFalse(SafetyNet.matches("啊啊啊我要死了，明天就due了"))
        XCTAssertFalse(SafetyNet.matches("哈哈哈笑死，气死我了"))
    }

    func testApplyRaisesButNeverLowers() {
        let message = ChatMessage(speaker: .them, text: "我不在了大家会更好", top: 0)
        let low = EmotionReport(message: message, emotion: "难过", intensity: 3, flags: ["self_harm": 0.1], engine: "t", latencyMs: 0)
        XCTAssertEqual(SafetyNet.apply(to: low).flags["self_harm"], SafetyNet.probability)
        let high = EmotionReport(message: message, emotion: "难过", intensity: 3, flags: ["self_harm": 1], engine: "t", latencyMs: 0)
        XCTAssertEqual(SafetyNet.apply(to: high).flags["self_harm"], 1)
    }
}

final class CombinedAnalyzerTests: XCTestCase {
    struct Fake: EmotionAnalyzer {
        var name: String
        var flags: [String: Double]
        var fails = false

        func analyze(context: [ChatMessage], latest: ChatMessage) async throws -> EmotionReport {
            if fails { throw AnalyzerError.badResponse("down") }
            return EmotionReport(message: latest, emotion: "难过", intensity: 2, flags: flags,
                                 suggestedReply: name, engine: name, latencyMs: 10)
        }
    }

    private let latest = ChatMessage(speaker: .them, text: "你敢去就分手", top: 0)

    func testSeriousFlagsTakeTheMaxAndTextComesFromPrimary() async throws {
        let combined = CombinedAnalyzer(
            primary: Fake(name: "llm", flags: ["manipulation": 0, "needs_comfort": 1]),
            checker: Fake(name: "kev", flags: ["manipulation": 0.93, "needs_comfort": 0]))
        let r = try await combined.analyze(context: [], latest: latest)
        XCTAssertEqual(r.flags["manipulation"], 0.93)
        XCTAssertEqual(r.flags["needs_comfort"], 1, "非严重信号不被复核引擎改动")
        XCTAssertEqual(r.suggestedReply, "llm")
        XCTAssertEqual(r.engine, "llm + kev")
    }

    struct Slow: EmotionAnalyzer {
        var name = "slow"
        func analyze(context: [ChatMessage], latest: ChatMessage) async throws -> EmotionReport {
            try await Task.sleep(for: .seconds(5))
            return EmotionReport(message: latest, emotion: "生气", intensity: 3, flags: ["manipulation": 1], engine: name, latencyMs: 5000)
        }
    }

    func testSlowCheckerTimesOutWithoutBlocking() async throws {
        let combined = CombinedAnalyzer(primary: Fake(name: "llm", flags: ["manipulation": 0]),
                                        checker: Slow(), checkerTimeout: .milliseconds(100))
        let start = Date()
        let r = try await combined.analyze(context: [], latest: latest)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertEqual(r.flags["manipulation"], 0)
        XCTAssertEqual(r.engine, "llm（slow 未响应）")
    }

    func testCheckerFailureFallsBackToPrimary() async throws {
        let combined = CombinedAnalyzer(primary: Fake(name: "llm", flags: ["conflict": 0.2]),
                                        checker: Fake(name: "kev", flags: [:], fails: true))
        let r = try await combined.analyze(context: [], latest: latest)
        XCTAssertEqual(r.flags["conflict"], 0.2)
        XCTAssertEqual(r.engine, "llm（kev 未响应）")
    }
}
