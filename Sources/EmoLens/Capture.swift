import CoreGraphics
import EmoLensCore
import ScreenCaptureKit
import Vision

/// 找窗口、截窗口、裁出聊天区域。截的是单个窗口本身，被别的窗口挡住也没关系。
enum WindowCapture {
    static let weChatBundleID = "com.tencent.xinWeChat"

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
        let weChat = all.filter { $0.owningApplication?.bundleIdentifier == weChatBundleID }
        if let window = weChat.filter(\.isOnScreen).max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
            return .found(window)
        }
        return weChat.isEmpty ? .missing : .hidden("微信")
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
    static func recognize(_ image: CGImage) throws -> [OCRLine] {
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
