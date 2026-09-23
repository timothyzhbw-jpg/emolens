import AppKit
import EmoLensCore
import Foundation
import ImageIO

/// EmoLens --inspect 截图.png [--analyze]：离线看一张截图被识别成了什么。不截屏，不需要任何权限。
/// 加 --analyze 时，再用默认的本地模型看懂其中的表情和表情包，并分析对方最后一条（和应用里走同一条路）。
enum Inspector {
    static func run(_ url: URL, analyze: Bool = false) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            FileHandle.standardError.write(Data("打不开图片：\(url.path)\n".utf8))
            return false
        }
        do {
            _ = try TextRecognizer.recognize(image)   // 第一次调用要加载 OCR 模型，先热身，下面的计时才准
            let start = Date()
            let lines = try TextRecognizer.recognize(image)
            let ocr = Date()
            let layout = PixelBuffer(image).map { LayoutDetector.detect($0, textBoxes: lines.map(\.box)) } ?? []
            let ms = { (from: Date, to: Date) in Int(to.timeIntervalSince(from) * 1000) }
            print("图片 \(image.width)×\(image.height)，OCR \(lines.count) 行 \(ms(start, ocr)) ms，"
                  + "版面分析 \(layout.count) 块 \(ms(ocr, Date())) ms")
            let reading = Date()
            let result = try ChatReader.read(image)
            print("完整识别（含带表情气泡的重认）\(ms(reading, Date())) ms")
            print("\nOCR：")
            for line in result.lines.sorted(by: { $0.box.minY < $1.box.minY }) {
                print(String(format: "  y=%.3f–%.3f x=%.3f–%.3f 置信度 %.2f  ", line.box.minY, line.box.maxY, line.box.minX,
                             line.box.maxX, line.confidence) + line.text)
            }
            print("\n版面：")
            for block in result.layout {
                let b = block.box
                let emoji = block.emoji.map { e in
                    String(format: "  表情×%d(x=%.3f–%.3f h=%.3f)", e.count, e.box.minX, e.box.maxX, e.box.height)
                }.joined()
                print(String(format: "  %-6@ y=%.3f–%.3f x=%.3f–%.3f", block.kind.rawValue, b.minY, b.maxY, b.minX, b.maxX) + emoji)
            }
            print("\n消息：")
            for message in result.messages {
                let who = switch message.speaker { case .them: "对方"; case .me: "我"; case .system: "系统" }
                let sender = message.sender.map { "（\($0)）" } ?? ""
                print("  \(who)\(sender)：\(message.text)")
            }
            if analyze { runAnalysis(result.messages, image: image) }
            return true
        } catch {
            FileHandle.standardError.write(Data("识别失败：\(error.localizedDescription)\n".utf8))
            return false
        }
    }

    /// 同步等待异步分析（命令行用）。
    static func runAnalysis(_ messages: [ChatMessage], image: CGImage) {
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await analysis(messages, image: image)
            semaphore.signal()
        }
        semaphore.wait()
    }

    static func analysis(_ messages: [ChatMessage], image: CGImage) async {
        let config = EvalRunner.config()
        let describer = VisualDescriber(backend: config.llm.backend())
        var described = messages
        print("\n看图：")
        for (index, message) in messages.enumerated() where message.speaker == .them && message.attachment?.isVisual == true {
            let images = ChatReader.visualCrops(for: message, in: image).compactMap(Monitor.png)
            let start = Date()
            do {
                described[index] = try await describer.read(message, images: images).message
                print("  \(message.text) → \(described[index].text)（\(images.count) 张图，\(Int(Date().timeIntervalSince(start) * 1000)) ms）")
            } catch {
                print("  \(message.text) → 失败：\(error.localizedDescription)")
            }
        }
        guard let index = described.lastIndex(where: { $0.speaker == .them }) else { return }
        let latest = described[index]
        if latest.attachment?.isUntranscribedVoice == true {
            print("\n对方最后一条是没转文字的语音，应用里会提示用户先在微信里转文字。")
            return
        }
        let context = Array(described[..<index].filter { $0.speaker != .system }.suffix(10))
        do {
            let report = try await config.makeAnalyzer().analyze(context: context, latest: latest)
            print("\n分析「\(latest.text)」（\(Int(report.latencyMs)) ms）：")
            print("  情绪：\(report.emotion) \(Int(report.intensity))/3 · \(report.consistency ?? "")")
            print("  真实想法：\(report.realMeaning ?? "")")
            let flags = report.flags.filter { $0.value >= 0.5 }.map(\.key).sorted().joined(separator: "、")
            print("  信号：\(flags.isEmpty ? "无" : flags)")
            print("  建议回复：\(report.suggestedReply ?? "")")
        } catch {
            print("\n分析失败：\(error.localizedDescription)")
        }
    }

    /// 回放：每张图处理完，打印面板上此时会显示什么。
    @MainActor
    static func replay(_ urls: [URL]) async {
        let images = urls.compactMap { url in
            CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        }
        let monitor = Monitor(settings: AppSettings())
        var shown = 0
        await monitor.replay(images) { index in
            print("第 \(index + 1) 张 \(urls[index].lastPathComponent)：")
            if let voice = monitor.pendingVoice { print("  提示：对方发来一条 \(voice) 秒的语音，等转文字") }
            for report in monitor.reports.prefix(monitor.reports.count - shown).reversed() {
                let flags = report.flags.filter { $0.value >= 0.5 }.map(\.key).sorted().joined(separator: "、")
                print("  分析「\(report.message.text)」→ \(report.emotion) · \(report.consistency ?? "") · \(flags)（\(Int(report.latencyMs)) ms）")
            }
            if let error = monitor.analysisError { print("  出错：\(error)") }
            shown = monitor.reports.count
        }
    }
}

