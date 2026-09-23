import CoreGraphics
import EmoLensCore
import ScreenCaptureKit
import Vision

/// 找窗口、截窗口、裁出聊天区域。截的是单个窗口本身，被别的窗口挡住也没关系。
enum WindowCapture {
    /// 「自动」模式认得的聊天软件，按优先级排。都是「对方靠左、我靠右」的界面；
    /// Slack、Discord 这类所有人都靠左的不放进来（分不清谁是谁），想用可以在设置里手动选窗口。
    static let chatApps = [
        "com.tencent.xinWeChat", "com.tencent.qq", "com.tencent.WeWorkMac",   // 微信、QQ、企业微信
        "com.alibaba.DingTalkMac", "com.bytedance.macos.feishu",              // 钉钉、飞书
        "ru.keepcoder.Telegram", "org.telegram.desktop", "net.whatsapp.WhatsApp",
        "jp.naver.line.mac", "org.whispersystems.signal-desktop", "com.apple.MobileSMS",
    ]

    static func windows() async throws -> [SCWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        return content.windows.filter {
            $0.windowLayer == 0 && $0.frame.width > 240 && $0.frame.height > 240
                && $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
        }
    }

    enum Lookup {
        case found(SCWindow)
        case hidden(String)    // 窗口还在，但被最小化或不在屏幕上
        case missing
    }

    /// 指定了窗口就只找它（不偷偷换成别的窗口）；没指定时取最大的微信窗口。
    static func find(id: CGWindowID) async throws -> Lookup {
        let all = try await windows()
        if id != 0 {
            if let window = all.first(where: { $0.windowID == id }) {
                return window.isOnScreen ? .found(window) : .hidden(name(of: window))
            }
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            return content.windows.first { $0.windowID == id }.map { .hidden(name(of: $0)) } ?? .missing
        }
        // 按优先级找第一个有窗口在屏幕上的聊天软件，取它最大的窗口
        var hidden: SCWindow?
        for app in chatApps {
            let windows = all.filter { $0.owningApplication?.bundleIdentifier == app }
            if let window = windows.filter(\.isOnScreen).max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
                return .found(window)
            }
            hidden = hidden ?? windows.first
        }
        return hidden.map { .hidden($0.owningApplication?.applicationName ?? "聊天软件") } ?? .missing
    }

    static func name(of window: SCWindow) -> String {
        [window.owningApplication?.applicationName, window.title].compactMap { $0 }.filter { !$0.isEmpty }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: " · ")
    }

    static func capture(_ window: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        config.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// 聊天区域正上方的一条（微信在这里显示对方名字）。区域贴着窗口顶部时没有标题栏可读，返回 nil。
    static func headerRegion(above region: CGRect) -> CGRect? {
        let top = max(0, region.minY - 0.12)
        guard region.minY - top >= 0.02 else { return nil }
        return CGRect(x: region.minX, y: top, width: region.width, height: region.minY - top)
    }

    /// region 为归一化坐标（原点左上）。
    static func crop(_ image: CGImage, to region: CGRect) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let rect = CGRect(x: region.minX * w, y: region.minY * h, width: region.width * w, height: region.height * h)
        return image.cropping(to: rect.integral)
    }
}

/// 64×64 灰度缩略图，画面没变就跳过 OCR。只看「明显变化的点数」，多出一个小气泡也能察觉。
struct FrameSignature {
    private static let side = 64
    let pixels: [UInt8]

    init?(_ image: CGImage) {
        var buffer = [UInt8](repeating: 0, count: Self.side * Self.side)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: Self.side, height: Self.side,
                                          bitsPerComponent: 8, bytesPerRow: Self.side,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: Self.side, height: Self.side))
            return true
        }
        guard drawn else { return nil }
        pixels = buffer
    }

    /// 至少 minChanged 个点的灰度差超过 delta 才算变了。
    func differs(from other: FrameSignature?, delta: Int = 16, minChanged: Int = 3) -> Bool {
        guard let other else { return true }
        var changed = 0
        for (a, b) in zip(pixels, other.pixels) where abs(Int(a) - Int(b)) > delta {
            changed += 1
            if changed >= minChanged { return true }
        }
        return false
    }
}

/// Apple Vision 本地中英文 OCR。
enum TextRecognizer {
    /// Vision 在又高又窄的图上会整行漏字（实测 880×1611 的聊天截图漏掉 3 行，其中一条是语音时长），
    /// 所以高的截图切成几条接近方形、互相重叠的横条分别识别，再按每条的中间部分拼回来。
    static func recognize(_ image: CGImage) throws -> [OCRLine] {
        let w = image.width, h = image.height
        let stripHeight = Int(Double(w) * 1.1)
        guard h > Int(Double(w) * 1.3) else { return try recognizeWhole(image) }
        let overlap = max(80, w / 6)
        let count = Int((Double(h - overlap) / Double(stripHeight - overlap)).rounded(.up))
        let step = Double(h - stripHeight) / Double(max(1, count - 1))
        let starts = (0..<count).map { Int((Double($0) * step).rounded()) }
        var lines: [OCRLine] = []
        for (i, start) in starts.enumerated() {
            let end = min(h, start + stripHeight)
            guard let strip = image.cropping(to: CGRect(x: 0, y: start, width: w, height: end - start)) else { continue }
            // 相邻两条重叠部分的中线为界：每行字只从离边缘更远的那一条里取，不重复也不漏
            let top = i == 0 ? 0 : Double(starts[i - 1] + stripHeight + start) / 2
            let bottom = i == count - 1 ? Double(h) : Double(end + starts[i + 1]) / 2
            let scale = Double(end - start) / Double(h)
            for line in try recognizeWhole(strip) {
                let box = CGRect(x: line.box.minX, y: Double(start) / Double(h) + line.box.minY * scale,
                                 width: line.box.width, height: line.box.height * scale)
                let center = box.midY * Double(h)
                guard center >= top, center < bottom else { continue }
                lines.append(OCRLine(text: line.text, box: box, confidence: line.confidence))
            }
        }
        return lines
    }

    static func recognizeWhole(_ image: CGImage) throws -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let b = observation.boundingBox   // Vision 原点在左下
            return OCRLine(text: candidate.string,
                           box: CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height),
                           confidence: candidate.confidence)
        }
    }
}

/// 一张聊天区域截图 → 消息：OCR 读字，LayoutDetector 从像素里找气泡、表情和表情包，ChatParser 拼成消息。
enum ChatReader {
    struct Result {
        var lines: [OCRLine]
        var layout: [LayoutBlock]
        var messages: [ChatMessage]
    }

    static func read(_ image: CGImage) throws -> Result {
        var lines = try TextRecognizer.recognize(image)
        let layout = PixelBuffer(image).map { LayoutDetector.detect($0, textBoxes: lines.map(\.box)) } ?? []
        // 挨着表情的字 Vision 常读错（「好的🙂」读成「好」，「嘛😂」读成「嘛包」），小气泡里的语音时长也常漏。
        // 对带表情、有字没读到、或者一个字都没读到的气泡，把表情涂成底色后单独再认一遍。
        // 只做最下面几个：新消息在下面。
        let redo = layout.filter { block in
            block.kind == .bubble && (!block.emoji.isEmpty || block.uncoveredText
                || !lines.contains { block.box.contains(CGPoint(x: $0.box.midX, y: $0.box.midY)) })
        }.suffix(4)
        for block in redo {
            guard let again = try? reread(block, in: image) else { continue }
            let inBlock = { (line: OCRLine) in block.box.contains(CGPoint(x: line.box.midX, y: line.box.midY)) }
            let before = lines.filter(inBlock)
            // 只数字母、数字和汉字：表情被读成的「（）」这类杂字不算
            let count = { (lines: [OCRLine]) in lines.reduce(0) { $0 + $1.text.filter { $0.isLetter || $0.isNumber }.count } }
            // 重认的结果不能比原来少太多（小图偶尔整个认不出来）
            guard !again.isEmpty, Double(count(again)) >= Double(count(before)) * 0.75 else { continue }
            lines = lines.filter { !inBlock($0) } + again
        }
        let messages = ChatParser.parse(lines, layout: layout, imageSize: CGSize(width: image.width, height: image.height))
        return Result(lines: lines, layout: layout, messages: messages)
    }

    /// 截出一个气泡，把表情涂成气泡底色、放大一倍，再 OCR；返回的坐标换算回整张图。
    /// Vision 在只有两三个字的小图上常常什么都认不出（「好的」），放大一倍就好了。
    static func reread(_ block: LayoutBlock, in image: CGImage) throws -> [OCRLine]? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let rect = CGRect(x: block.box.minX * w, y: block.box.minY * h, width: block.box.width * w, height: block.box.height * h).integral
        guard rect.width > 4, rect.height > 4, let crop = image.cropping(to: rect),
              let context = CGContext(data: nil, width: crop.width * 2, height: crop.height * 2, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.scaleBy(x: 2, y: 2)
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        if let fill = block.fill, fill.count == 3 {
            context.setFillColor(red: fill[0], green: fill[1], blue: fill[2], alpha: 1)
            for emoji in block.emoji {
                // 归一化（原点左上）→ 这张小图的像素（CGContext 原点左下）
                let x = (emoji.box.minX * w - rect.minX), y = (emoji.box.minY * h - rect.minY)
                let r = CGRect(x: x, y: CGFloat(crop.height) - y - emoji.box.height * h,
                               width: emoji.box.width * w, height: emoji.box.height * h)
                context.fill(r.insetBy(dx: -3, dy: -3))
            }
        }
        guard let painted = context.makeImage() else { return nil }
        return try TextRecognizer.recognizeWhole(painted).map { line in
            OCRLine(text: line.text,
                    box: CGRect(x: (rect.minX + line.box.minX * rect.width) / w, y: (rect.minY + line.box.minY * rect.height) / h,
                                width: line.box.width * rect.width / w, height: line.box.height * rect.height / h),
                    confidence: line.confidence)
        }
    }

    /// 给模型看的截图：表情一个一张（只截表情本身、放大到约 128 像素）；表情包、图片截整块。
    static func visualCrops(for message: ChatMessage, in image: CGImage) -> [CGImage] {
        guard let attachment = message.attachment, attachment.isVisual else { return [] }
        if attachment.kind == .emoji {
            return attachment.emoji.compactMap { part in
                // 一处挨着好几个同样的表情时，只截第一个
                var box = part.box
                if part.count > 1 { box.size.width /= CGFloat(part.count) }
                return WindowCapture.crop(image, to: box.insetBy(dx: -0.004, dy: -0.002)).flatMap { scaled($0, toSide: 128) }
            }
        }
        guard let box = attachment.box,
              let crop = WindowCapture.crop(image, to: box.insetBy(dx: -0.01, dy: -0.005).intersection(CGRect(x: 0, y: 0, width: 1, height: 1)))
        else { return [] }
        return [crop.width > 512 || crop.height > 512 ? scaled(crop, toSide: 512) ?? crop : crop]
    }

    /// 等比缩放，让长边变成 side。
    static func scaled(_ image: CGImage, toSide side: Int) -> CGImage? {
        let scale = Double(side) / Double(max(image.width, image.height))
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }
}
