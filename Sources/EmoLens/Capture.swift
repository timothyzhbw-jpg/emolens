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

    /// 指定了窗口就只找它（找不到返回 nil，不偷偷换成别的窗口）；没指定时取最大的微信窗口。
    static func find(id: CGWindowID) async throws -> SCWindow? {
        let all = try await windows()
        if id != 0 { return all.first { $0.windowID == id } }
        return all
            .filter { $0.owningApplication?.bundleIdentifier == weChatBundleID }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
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

    /// region 为归一化坐标（原点左上）。
    static func crop(_ image: CGImage, to region: CGRect) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let rect = CGRect(x: region.minX * w, y: region.minY * h, width: region.width * w, height: region.height * h)
        return image.cropping(to: rect.integral)
    }
}

/// 32×32 灰度缩略图，画面没变就跳过 OCR。
struct FrameSignature {
    private static let side = 32
    let pixels: [UInt8]

    init?(_ image: CGImage) {
        var buffer = [UInt8](repeating: 0, count: Self.side * Self.side)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: Self.side, height: Self.side,
                                          bitsPerComponent: 8, bytesPerRow: Self.side,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: Self.side, height: Self.side))
            return true
        }
        guard drawn else { return nil }
        pixels = buffer
    }

    func differs(from other: FrameSignature?, threshold: Double = 0.8) -> Bool {
        guard let other else { return true }
        let total = zip(pixels, other.pixels).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return Double(total) / Double(pixels.count) > threshold
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
