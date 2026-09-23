import XCTest
@testable import EmoLensCore

final class MessageTrackerTests: XCTestCase {
    private func message(_ text: String, _ speaker: Speaker = .them, top: Double = 0) -> ChatMessage {
        ChatMessage(speaker: speaker, text: text, top: top)
    }

    func testInitialResetUnchangedAndAppends() {
        let tracker = MessageTracker()
        let initial = [message("甲"), message("乙", .me)]
        XCTAssertEqual(tracker.update(initial), .reset(initial))
        XCTAssertEqual(tracker.update(initial), .unchanged)
        let one = message("丙")
        XCTAssertEqual(tracker.update(initial + [one]), .appended([one]))
        let two = [message("丁", .me), message("戊")]
        XCTAssertEqual(tracker.update([initial[1], one] + two), .appended(two))
        XCTAssertEqual(tracker.history, initial + [one] + two)
    }

    func testScrollUpAndChatSwitch() {
        let tracker = MessageTracker()
        let initial = [message("甲"), message("乙")]
        _ = tracker.update(initial)
        XCTAssertEqual(tracker.update([message("旧消息")] + initial), .unchanged)
        XCTAssertEqual(tracker.history, initial)
        let other = [message("另一段对话", .me)]
        XCTAssertEqual(tracker.update(other), .reset(other))
        XCTAssertEqual(tracker.history, other)
    }

    func testRepeatedShortMessageRequiresPredecessor() {
        let tracker = MessageTracker()
        let initial = [message("甲"), message("好")]
        _ = tracker.update(initial)
        let added = [message("乙"), message("好")]
        XCTAssertEqual(tracker.update(initial + added), .appended(added))
        XCTAssertEqual(tracker.update(initial + added), .unchanged)
    }

    func testOCRJitterTruncationAndPositionChanges() {
        let tracker = MessageTracker()
        _ = tracker.update([message("今天我们一起去公园散步吧")])
        XCTAssertEqual(tracker.update([message("今天我们一起去公园散步啊", top: 0.4)]), .unchanged)
        XCTAssertEqual(tracker.update([message("去公园散步吧", top: 0.1)]), .unchanged)
    }

    func testSpeakerMustMatchAndFirstVisibleAnchorIsAllowed() {
        let tracker = MessageTracker()
        _ = tracker.update([message("甲"), message("乙")])
        XCTAssertEqual(tracker.update([message("乙"), message("丙")]), .appended([message("丙")]))
        let changed = [message("丙", .me)]
        XCTAssertEqual(tracker.update(changed), .reset(changed))
    }

    func testHistoryCapOnResetAndAppend() {
        let tracker = MessageTracker()
        let initial = (0..<205).map { message("消息\($0)") }
        XCTAssertEqual(tracker.update(initial), .reset(initial))
        XCTAssertEqual(tracker.history, Array(initial.suffix(200)))
        let added = message("全新的回复", .me)
        XCTAssertEqual(tracker.update(Array(initial.suffix(2)) + [added]), .appended([added]))
        XCTAssertEqual(tracker.history.count, 200)
        XCTAssertEqual(tracker.history.first, initial[6])
        XCTAssertEqual(tracker.history.last, added)
    }

    func testSystemMessagesAndContextLimits() {
        let tracker = MessageTracker()
        let a = message("甲")
        let b = message("乙", .me)
        let system = message("12:30", .system)
        let initial = [a, system, b]
        XCTAssertEqual(tracker.update(initial), .reset(initial))
        XCTAssertEqual(tracker.history, [a, b])
        XCTAssertEqual(tracker.update([a, b, system]), .unchanged)
        XCTAssertEqual(tracker.context(limit: 1), [b])
        XCTAssertEqual(tracker.context(limit: 10), [a, b])
        XCTAssertEqual(tracker.context(limit: 0), [])
        XCTAssertEqual(tracker.context(limit: -1), [])
    }

    func testEmptyAndSystemOnlyScreens() {
        let tracker = MessageTracker()
        XCTAssertEqual(tracker.update([]), .reset([]))
        let system = [message("提示", .system)]
        XCTAssertEqual(tracker.update(system), .reset(system))
        _ = tracker.update([message("甲")])
        XCTAssertEqual(tracker.update([]), .reset([]))
        XCTAssertTrue(tracker.history.isEmpty)
    }

    func testNormalizationAndSimilarity() {
        XCTAssertEqual(MessageTracker.normalize(" Hello，世界！123 👋🚀\n"), "hello世界123")
        XCTAssertTrue(MessageTracker.similar("HELLO!", "hello"))
        XCTAssertTrue(MessageTracker.similar("abcdefghij", "abcdefghiX"))
        XCTAssertTrue(MessageTracker.similar("abcdefghij", "abcdefghi"))
        XCTAssertTrue(MessageTracker.similar("前面被截断的消息内容", "消息内容"))
        XCTAssertFalse(MessageTracker.similar("好", "坏"))
        XCTAssertFalse(MessageTracker.similar("你好", "你坏"))
        XCTAssertFalse(MessageTracker.similar("abc", "abcdef"))
        XCTAssertFalse(MessageTracker.similar("abcdefghij", "abcdefghXY"))
    }

    func testVoiceGettingTranscribedIsPickedUpAgain() {
        // 对方发了语音 → 用户在微信里点「转文字」→ 同一条消息变成了文字，应当被当成新内容重新分析
        let tracker = MessageTracker()
        let before = [ChatMessage(speaker: .me, text: "别这样嘛，我十点前一定回来", top: 0.1),
                      ChatMessage(speaker: .them, text: "[语音 6秒]", top: 0.3,
                                  attachment: Attachment(kind: .voice, seconds: 6))]
        _ = tracker.update(before)
        var after = before
        after[1] = ChatMessage(speaker: .them, text: "[语音转文字] 那你到底几点回来啊", top: 0.3,
                               attachment: Attachment(kind: .voice, seconds: 6, transcribed: true))
        let changed: [ChatMessage]
        switch tracker.update(after) {
        case .appended(let new), .reset(let new): changed = new
        case .unchanged: changed = []
        }
        let latest = changed.last { $0.speaker == .them }
        XCTAssertEqual(latest?.attachment?.transcribed, true)
        XCTAssertEqual(tracker.update(after), .unchanged, "转好之后画面不变，不再重复分析")
    }
}

