import CoreGraphics
@testable import EmoLensCore
import XCTest

/// 有版面信息时按气泡解析：语音、转文字、引用、表情、表情包、昵称。坐标都是归一化的。
final class LayoutParserTests: XCTestCase {
    private let size = CGSize(width: 400, height: 800)

    private func line(_ text: String, _ x: Double, _ y: Double, _ w: Double, h: Double = 0.02) -> OCRLine {
        OCRLine(text: text, box: CGRect(x: x, y: y, width: w, height: h))
    }

    private func bubble(_ x: Double, _ y: Double, _ w: Double, _ h: Double = 0.045, emoji: [LayoutBlock.Emoji] = []) -> LayoutBlock {
        LayoutBlock(kind: .bubble, box: CGRect(x: x, y: y, width: w, height: h), emoji: emoji)
    }

    private func avatar(_ y: Double, left: Bool = true) -> LayoutBlock {
        LayoutBlock(kind: .avatar, box: CGRect(x: left ? 0.03 : 0.88, y: y, width: 0.09, height: 0.045))
    }

    private func parse(_ lines: [OCRLine], _ layout: [LayoutBlock]) -> [ChatMessage] {
        ChatParser.parse(lines, layout: layout, imageSize: size)
    }

    func testVoiceWithoutTranscript() {
        let messages = parse([line(#"1 5""#, 0.17, 0.11, 0.08)], [avatar(0.1), bubble(0.15, 0.1, 0.2)])
        XCTAssertEqual(messages.map(\.text), ["[语音 5秒]"])
        XCTAssertEqual(messages[0].speaker, .them)
        XCTAssertEqual(messages[0].attachment?.isUntranscribedVoice, true)
    }

    func testVoiceTranscriptBoxBelowIsMerged() {
        let messages = parse([line(#")) 12""#, 0.17, 0.11, 0.08), line("你到底什么时候回来", 0.17, 0.165, 0.4)],
                             [avatar(0.1), bubble(0.15, 0.1, 0.25), bubble(0.15, 0.152, 0.45)])
        XCTAssertEqual(messages.map(\.text), ["[语音转文字] 你到底什么时候回来"])
        XCTAssertEqual(messages[0].attachment?.transcribed, true)
        XCTAssertEqual(messages[0].attachment?.seconds, 12)
    }

    func testLongVoiceDurationOutsideBubbleBelongsToThem() {
        // 长语音的时长在气泡右边，位置已经过了中线
        let messages = parse([line(#"47"●"#, 0.64, 0.115, 0.09)], [avatar(0.1), bubble(0.15, 0.1, 0.45)])
        XCTAssertEqual(messages.map(\.text), ["[语音 47秒]"])
        XCTAssertEqual(messages[0].speaker, .them)
    }

    func testNextMessageWithItsOwnAvatarIsNotTranscript() {
        let messages = parse([line(#"5""#, 0.17, 0.11, 0.05), line("在吗", 0.17, 0.165, 0.1)],
                             [avatar(0.1), bubble(0.15, 0.1, 0.2), avatar(0.152), bubble(0.15, 0.152, 0.15)])
        XCTAssertEqual(messages.map(\.text), ["[语音 5秒]", "在吗"])
    }

    func testEmojiBetweenFragmentsKeepsOrder() {
        // OCR 把「哈哈哈哈😂😂 你真行」切成两段，右边那段的 minY 还更小
        let messages = parse([line("你真行", 0.40, 0.212, 0.11), line("哈哈哈哈", 0.177, 0.214, 0.17)],
                             [avatar(0.2), bubble(0.15, 0.2, 0.4, emoji: [LayoutBlock.Emoji(box: CGRect(x: 0.31, y: 0.211, width: 0.09, height: 0.022), count: 2)])])
        XCTAssertEqual(messages.map(\.text), ["哈哈哈哈[表情][表情]你真行"])
        XCTAssertEqual(messages[0].attachment?.kind, .emoji)
        XCTAssertEqual(messages[0].attachment?.emoji.first?.count, 2)
    }

    func testEmojiOnlyBubbleAndEmptyBubble() {
        let emoji = LayoutBlock.Emoji(box: CGRect(x: 0.18, y: 0.11, width: 0.04, height: 0.022))
        let messages = parse([], [avatar(0.1), bubble(0.15, 0.1, 0.1, emoji: [emoji]), avatar(0.2), bubble(0.15, 0.2, 0.1)])
        XCTAssertEqual(messages.map(\.text), ["[表情]"], "空气泡（什么都没认出来）不当成消息")
    }

    func testStickerWithCaption() {
        let sticker = LayoutBlock(kind: .media, box: CGRect(x: 0.15, y: 0.1, width: 0.3, height: 0.15))
        let messages = parse([line("我不听", 0.2, 0.22, 0.12)], [avatar(0.1), sticker])
        XCTAssertEqual(messages.map(\.text), ["[表情包：我不听]"])
        XCTAssertEqual(messages[0].attachment?.kind, .sticker)
        XCTAssertEqual(messages[0].attachment?.box, sticker.box)
    }

    func testTransparentStickerCaptionBelowImage() {
        let sticker = LayoutBlock(kind: .media, box: CGRect(x: 0.15, y: 0.1, width: 0.25, height: 0.12))
        let messages = parse([line("哼", 0.24, 0.23, 0.05)], [avatar(0.1), sticker])
        XCTAssertEqual(messages.map(\.text), ["[表情包：哼]"])
    }

    func testQuoteBoxIsAttachedWhenAvatarsAreVisible() {
        let messages = parse([line("那你到底几点回", 0.17, 0.11, 0.25), line("我：今晚加班", 0.17, 0.162, 0.2)],
                             [avatar(0.1), bubble(0.15, 0.1, 0.3), bubble(0.15, 0.152, 0.28, 0.035)])
        XCTAssertEqual(messages.map(\.text), ["那你到底几点回（引用：我：今晚加班）"])
    }

    func testGroupNicknameAndAvatarText() {
        // 头像上印着字（比如照片里的 logo）不能当成消息；气泡上面的小字是昵称
        let messages = parse([line("LOGO", 0.04, 0.105, 0.07), line("小美", 0.15, 0.1, 0.06, h: 0.014), line("大家好", 0.17, 0.13, 0.12)],
                             [avatar(0.1), bubble(0.15, 0.12, 0.2)])
        XCTAssertEqual(messages.map(\.text), ["大家好"])
        XCTAssertEqual(messages[0].sender, "小美")
    }

    func testMeAndSystem() {
        let messages = parse([line("21:05", 0.45, 0.02, 0.1), line("好呀", 0.7, 0.11, 0.1)],
                             [bubble(0.6, 0.1, 0.25), avatar(0.1, left: false)])
        XCTAssertEqual(messages.map(\.speaker), [.system, .me])
    }

    func testVoiceSecondsPattern() {
        XCTAssertEqual(ChatParser.voiceSeconds(#"5""#), 5)
        XCTAssertEqual(ChatParser.voiceSeconds(#"1 12""#), 12, "声波图标读成的 1 不算进时长")
        XCTAssertEqual(ChatParser.voiceSeconds("3” （（（"), 3)
        XCTAssertEqual(ChatParser.voiceSeconds(#"47"●"#), 47)
        XCTAssertNil(ChatParser.voiceSeconds(#"他说要 5" 的"#), "一句话里带引号不是语音")
        XCTAssertNil(ChatParser.voiceSeconds("12:30"))
        XCTAssertNil(ChatParser.voiceSeconds(#"99""#), "微信语音最长 60 秒")
    }

    func testTextOnlyPathJoinsSameRowLeftToRight() {
        let messages = ChatParser.parse([line("你真行", 0.40, 0.212, 0.11), line("哈哈哈哈", 0.177, 0.214, 0.17)])
        XCTAssertEqual(messages.map(\.text), ["哈哈哈哈 你真行"])
    }
}
