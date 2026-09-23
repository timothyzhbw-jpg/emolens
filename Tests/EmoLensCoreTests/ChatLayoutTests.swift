import CoreGraphics
@testable import EmoLensCore
import XCTest

/// 用 CoreGraphics 画一张仿微信的聊天截图（原点左上），检查版面检测认出的块。
final class ChatLayoutTests: XCTestCase {
    private let width = 400, height = 300

    private func draw(_ paint: (CGContext) -> Void) -> PixelBuffer {
        var data = [UInt8](repeating: 0, count: width * height * 4)
        data.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            // 翻成原点左上，和截图一致
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.setFillColor(red: 0.93, green: 0.93, blue: 0.93, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            paint(context)
        }
        return PixelBuffer(width: width, height: height, rgba: data)
    }

    private func fill(_ c: CGContext, _ rect: CGRect, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat) {
        c.setFillColor(red: r, green: g, blue: b, alpha: 1)
        c.fill(rect)
    }

    /// 一行「字」：几根深色竖条，像文字笔画。
    private func text(_ c: CGContext, x: CGFloat, y: CGFloat, chars: Int) {
        for i in 0..<chars { fill(c, CGRect(x: x + CGFloat(i) * 14, y: y, width: 10, height: 12), 0.1, 0.1, 0.1) }
    }

    private func normalized(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX / CGFloat(width), y: r.minY / CGFloat(height), width: r.width / CGFloat(width), height: r.height / CGFloat(height))
    }

    func testFindsAvatarsBubblesEmojiAndSticker() {
        let image = draw { c in
            // 对方：头像 + 白色气泡「好的🙂」
            fill(c, CGRect(x: 10, y: 10, width: 36, height: 36), 1, 0.6, 0.3)
            fill(c, CGRect(x: 56, y: 10, width: 90, height: 36), 1, 1, 1)
            text(c, x: 68, y: 22, chars: 2)
            c.setFillColor(red: 1, green: 0.8, blue: 0.1, alpha: 1)
            c.fillEllipse(in: CGRect(x: 100, y: 19, width: 18, height: 18))
            // 对方：头像 + 彩色表情包
            fill(c, CGRect(x: 10, y: 70, width: 36, height: 36), 1, 0.6, 0.3)
            for i in 0..<10 { fill(c, CGRect(x: 56, y: 70 + CGFloat(i) * 12, width: 110, height: 12), CGFloat(i) / 10, 0.3, 1 - CGFloat(i) / 10) }
            // 我：绿色气泡 + 头像
            fill(c, CGRect(x: 254, y: 210, width: 90, height: 36), 0.58, 0.93, 0.41)
            text(c, x: 266, y: 222, chars: 4)
            fill(c, CGRect(x: 354, y: 210, width: 36, height: 36), 0.3, 0.5, 1)
        }
        let lines = [CGRect(x: 68, y: 22, width: 24, height: 12), CGRect(x: 266, y: 222, width: 52, height: 12)].map(normalized)
        let blocks = LayoutDetector.detect(image, textBoxes: lines)
        XCTAssertEqual(blocks.map(\.kind), [.avatar, .bubble, .avatar, .media, .bubble, .avatar])
        XCTAssertEqual(blocks[1].emoji.count, 1, "黄色圆点是表情")
        XCTAssertEqual(blocks[4].emoji.count, 0, "绿色气泡上的黑字不是表情")
        XCTAssertFalse(blocks[1].uncoveredText)
        XCTAssertEqual(blocks[1].fill?.map { ($0 * 255).rounded() }, [255, 255, 255])
    }

    func testEmojiOnlyBubbleBesideAvatarIsNotAvatar() {
        // 只发一个表情的小气泡也是小方块：靠外的才是头像
        let image = draw { c in
            fill(c, CGRect(x: 10, y: 10, width: 36, height: 36), 1, 0.6, 0.3)
            fill(c, CGRect(x: 56, y: 10, width: 42, height: 36), 1, 1, 1)
            c.setFillColor(red: 1, green: 0.8, blue: 0.1, alpha: 1)
            c.fillEllipse(in: CGRect(x: 67, y: 19, width: 18, height: 18))
        }
        let blocks = LayoutDetector.detect(image, textBoxes: [normalized(CGRect(x: 0, y: 0, width: 20, height: 12))])
        XCTAssertEqual(blocks.map(\.kind), [.avatar, .bubble])
        XCTAssertEqual(blocks[1].emoji.count, 1)
    }

    func testRoundFlatCartoonIsStickerNotBubble() {
        // 一片纯色、但是圆的：卡通表情包，不是气泡
        let image = draw { c in
            c.setFillColor(red: 1, green: 0.75, blue: 0.3, alpha: 1)
            c.fillEllipse(in: CGRect(x: 60, y: 40, width: 90, height: 90))
        }
        let blocks = LayoutDetector.detect(image, textBoxes: [normalized(CGRect(x: 0, y: 0, width: 20, height: 12))])
        XCTAssertEqual(blocks.map(\.kind), [.media])
    }

    func testFaintBoxOnWhiteBackgroundIsFound() {
        // 新版微信：白底上的转文字框只比背景深几个色阶
        let image = draw { c in
            fill(c, CGRect(x: 0, y: 0, width: 400, height: 300), 1, 1, 1)
            fill(c, CGRect(x: 56, y: 60, width: 160, height: 36), 0.97, 0.97, 0.97)
            text(c, x: 68, y: 72, chars: 6)
        }
        let blocks = LayoutDetector.detect(image, textBoxes: [normalized(CGRect(x: 68, y: 72, width: 80, height: 12))])
        XCTAssertEqual(blocks.map(\.kind), [.bubble])
    }

    func testUnreadTextIsFlagged() {
        let image = draw { c in
            fill(c, CGRect(x: 56, y: 60, width: 200, height: 36), 1, 1, 1)
            text(c, x: 68, y: 72, chars: 8)
        }
        // OCR 一个字都没读到
        let blocks = LayoutDetector.detect(image, textBoxes: [normalized(CGRect(x: 0, y: 200, width: 20, height: 12))])
        XCTAssertEqual(blocks.first?.uncoveredText, true)
    }
}
