@testable import EmoLensCore
import XCTest

final class ChatTranscriptTests: XCTestCase {
    func testNameColonFormat() {
        let parsed = ChatTranscript.parse("""
        小美：你今晚几点回来
        我：可能要加班
        小美: 哦
        """)
        XCTAssertEqual(parsed.messages.map(\.speaker), [.them, .me, .them])
        XCTAssertEqual(parsed.messages.map(\.text), ["你今晚几点回来", "可能要加班", "哦"])
        XCTAssertEqual(parsed.messages.first?.sender, "小美")
        XCTAssertNil(parsed.messages[1].sender, "自己的消息不记名字")
        XCTAssertEqual(parsed.names, ["小美"])
    }

    func testNameAndTimestampOnItsOwnLine() {
        let parsed = ChatTranscript.parse("""
        小美 2026-09-22 12:30:15
        你在干嘛呀

        我 12:31
        在忙
        """)
        XCTAssertEqual(parsed.messages.map(\.speaker), [.them, .me])
        XCTAssertEqual(parsed.messages.map(\.text), ["你在干嘛呀", "在忙"])
    }

    func testWrappedLinesStayInOneMessage() {
        let parsed = ChatTranscript.parse("""
        小美：我今天真的很累
        公司那边一堆事
        回来还要收拾
        我：辛苦了
        """)
        XCTAssertEqual(parsed.messages.count, 2)
        XCTAssertEqual(parsed.messages[0].text, "我今天真的很累\n公司那边一堆事\n回来还要收拾")
    }

    func testSkipsTimeSeparators() {
        let parsed = ChatTranscript.parse("""
        昨天 21:05
        小美：睡了吗
        今天
        我：刚醒
        """)
        XCTAssertEqual(parsed.messages.map(\.text), ["睡了吗", "刚醒"])
    }

    func testLinksAreNotMistakenForSpeakers() {
        let parsed = ChatTranscript.parse("""
        小美：你看看这个
        https://example.com/a:b
        """)
        XCTAssertEqual(parsed.messages.count, 1)
        XCTAssertTrue(parsed.messages[0].text.contains("https://example.com/a:b"))
        XCTAssertEqual(parsed.names, ["小美"])
    }

    func testPlainLinesAreTreatedAsTheOtherPerson() {
        let parsed = ChatTranscript.parse("没事，你开心就好")
        XCTAssertEqual(parsed.messages.map(\.speaker), [.them])
        XCTAssertTrue(parsed.names.isEmpty)
    }

    func testMostFrequentNameComesFirst() {
        let parsed = ChatTranscript.parse("""
        小美：在吗
        我：在
        阿强：晚上一起吃饭
        小美：我也去
        """)
        XCTAssertEqual(parsed.names, ["小美", "阿强"])
        XCTAssertEqual(parsed.messages.filter { $0.speaker == .me }.count, 1)
    }

    func testEnglishMeIsRecognised() {
        let parsed = ChatTranscript.parse("Me: ok\nAmy: fine")
        XCTAssertEqual(parsed.messages.map(\.speaker), [.me, .them])
        XCTAssertEqual(parsed.names, ["Amy"])
    }
}
