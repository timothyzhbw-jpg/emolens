@testable import EmoLensCore
import XCTest

/// 记下收到的请求，按顺序返回预设的回答。
final class ScriptedBackend: ChatBackend, @unchecked Sendable {
    var answers: [String]
    var received: [[ChatTurn]] = []
    let name = "测试模型"
    let cloudProvider: String? = nil

    init(_ answers: [String]) { self.answers = answers }

    func complete(system: String, turns: [ChatTurn], schema: String?) async throws -> String {
        received.append(turns)
        return answers.isEmpty ? "{}" : answers.removeFirst()
    }
}

final class VisualDescriberTests: XCTestCase {
    private func emojiMessage(_ text: String, counts: [Int]) -> ChatMessage {
        ChatMessage(speaker: .them, text: text, top: 0, attachment: Attachment(
            kind: .emoji, emoji: counts.map { LayoutBlock.Emoji(box: .zero, count: $0) }))
    }

    func testFillsEmojiNamesInOrderAndMergesRuns() {
        let message = emojiMessage("哈哈[表情][表情]你真行[表情]", counts: [2, 1])
        XCTAssertEqual(VisualDescriber.filling(message, emoji: ["笑哭", "捂脸"]).text, "哈哈[表情：笑哭×2]你真行[表情：捂脸]")
    }

    func testFillsDescriptionForSticker() {
        let sticker = ChatMessage(speaker: .them, text: "[表情包：我不听]", top: 0, attachment: Attachment(kind: .sticker))
        XCTAssertEqual(VisualDescriber.filling(sticker, description: "猫咪捂耳朵，写着我不听").text, "[表情包：猫咪捂耳朵，写着我不听]")
    }

    func testReadAsksOncePerNewImageAndSendsImages() async throws {
        let backend = ScriptedBackend([#"{"emoji": "捂脸"}"#])
        let image = Data([1, 2, 3])
        let known = [VisualDescriber.key(Data([9])): "微笑"]
        let message = emojiMessage("[表情][表情]", counts: [1, 1])
        let (result, learned) = try await VisualDescriber(backend: backend).read(message, images: [image, Data([9])], known: known)
        XCTAssertEqual(result.text, "[表情：捂脸][表情：微笑]")
        XCTAssertEqual(backend.received.count, 1, "认识的表情不再问")
        XCTAssertEqual(backend.received.first?.first?.images, [image])
        XCTAssertEqual(learned, [VisualDescriber.key(image): "捂脸"])
    }

    func testBadAnswerThrowsSoCallerKeepsPlaceholder() async {
        let backend = ScriptedBackend(["我看不清"])
        let message = emojiMessage("[表情]", counts: [1])
        do {
            _ = try await VisualDescriber(backend: backend).read(message, images: [Data([1])])
            XCTFail("应当抛错")
        } catch {}
    }

    func testCleanStripsBracketsAndLength() {
        XCTAssertEqual(VisualDescriber.clean(" [捂脸]。 "), "捂脸")
        XCTAssertEqual(VisualDescriber.clean(String(repeating: "长", count: 100)).count, 60)
    }
}
