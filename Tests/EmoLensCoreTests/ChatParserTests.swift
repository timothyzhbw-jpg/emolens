import XCTest
import CoreGraphics
@testable import EmoLensCore

final class ChatParserTests: XCTestCase {
    private func line(_ text: String, _ x: Double, _ y: Double, _ width: Double,
                      height: Double = 0.04, confidence: Float = 1) -> OCRLine {
        OCRLine(text: text, box: CGRect(x: x, y: y, width: width, height: height),
                confidence: confidence)
    }

    func testClassificationAndUnorderedInput() {
        let messages = ChatParser.parse([
            line("我的回复", 0.7, 0.5, 0.2),
            line("12:30", 0.45, 0.1, 0.1),
            line("你好", 0.1, 0.3, 0.2),
        ])
        XCTAssertEqual(messages.map(\.speaker), [.system, .them, .me])
        XCTAssertEqual(messages.map(\.top), [0.1, 0.3, 0.5])
    }

    func testTimestampsRegardlessOfPositionAndSeparateSystemRows() {
        let texts = ["12:30", "昨天 21:05", "星期三 09:12", "2026年9月21日 13:40", "9月21日 下午3:05"]
        let messages = ChatParser.parse(texts.enumerated().map {
            line($0.element, 0.05, Double($0.offset) * 0.05, 0.3)
        })
        XCTAssertEqual(messages.map(\.text), texts)
        XCTAssertTrue(messages.allSatisfy { $0.speaker == .system })
        let notices = ChatParser.parse([
            line("以下为新消息", 0.4, 0.1, 0.2), line("张三撤回了一条消息", 0.35, 0.145, 0.3),
        ])
        XCTAssertEqual(notices.count, 2)
        XCTAssertTrue(notices.allSatisfy { $0.speaker == .system })
    }

    func testWrappedBubblesAndJoinSpacing() {
        let messages = ChatParser.parse([
            line("今天", 0.1, 0.1, 0.3), line("天气", 0.1, 0.15, 0.3),
            line("很好", 0.1, 0.2, 0.2),
            line("Hello", 0.7, 0.4, 0.2), line("world2", 0.6, 0.45, 0.3),
        ])
        XCTAssertEqual(messages.map(\.text), ["今天天气很好", "Hello world2"])
        XCTAssertEqual(messages.map(\.speaker), [.them, .me])
        XCTAssertEqual(messages.map(\.top), [0.1, 0.4])
    }

    func testDifferentAlignmentAndLargeGapPreventMerge() {
        let messages = ChatParser.parse([
            line("第一条", 0.1, 0.1, 0.2), line("第二条", 0.2, 0.15, 0.2),
            line("第三条", 0.2, 0.3, 0.2),
            line("右一", 0.7, 0.5, 0.2), line("右二", 0.6, 0.55, 0.2),
        ])
        XCTAssertEqual(messages.count, 5)
    }

    func testNicknameBelongsToFollowingBubble() {
        let messages = ChatParser.parse([
            line("之前的消息", 0.1, 0.05, 0.3),
            line("小明", 0.1, 0.2, 0.1, height: 0.02),
            line("大家好", 0.1, 0.23, 0.3), line("很高兴见到你们", 0.1, 0.28, 0.3),
        ])
        XCTAssertEqual(messages.count, 2)
        XCTAssertNil(messages[0].sender)
        XCTAssertEqual(messages[1].sender, "小明")
        XCTAssertEqual(messages[1].text, "大家好很高兴见到你们")
        XCTAssertEqual(messages[1].top, 0.23)
    }

    func testIsolatedSmallLineIsNotNickname() {
        let messages = ChatParser.parse([
            line("短行", 0.1, 0.1, 0.1, height: 0.02),
            line("正文", 0.1, 0.3, 0.2), line("回复", 0.7, 0.5, 0.2),
        ])
        XCTAssertEqual(messages.count, 3)
        XCTAssertTrue(messages.allSatisfy { $0.sender == nil })
    }

    func testFilteringAndWideBubble() {
        let messages = ChatParser.parse([
            line("噪声", 0.1, 0.1, 0.2, confidence: 0.29),
            line(" \n ", 0.1, 0.2, 0.2),
            line(" 很长的对方消息 ", 0.03, 0.3, 0.92, confidence: 0.3),
        ])
        XCTAssertEqual(messages, [ChatMessage(speaker: .them, text: "很长的对方消息", top: 0.3)])
        XCTAssertEqual(ChatParser.parse([]), [])
    }

    func testCustomConfig() {
        var config = ParserConfig()
        config.minConfidence = 0.9
        config.mergeGapFactor = 0.1
        XCTAssertEqual(ChatParser.parse([
            line("低", 0.1, 0, 0.2, confidence: 0.8),
            line("甲", 0.1, 0.1, 0.2), line("乙", 0.1, 0.15, 0.2),
        ], config: config).map(\.text), ["甲", "乙"])
    }
}
