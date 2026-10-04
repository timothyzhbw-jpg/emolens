import AVFoundation
import OSLog
import ScreenCaptureKit

private let log = Logger(subsystem: "io.github.emolens", category: "voice")

/// 录下一个应用发出的声音，写成 16 kHz 单声道 WAV：用户在聊天软件里播放语音时，只录那个软件，
/// 不录麦克风、不录别的应用、也不录 EmoLens 自己。用的是屏幕录制权限里的「系统录音」部分。
final class VoiceListener: NSObject, SCStreamOutput, @unchecked Sendable {
    struct Recording {
        let url: URL
        let seconds: Double
        /// 有没有录到像样的声音（最大振幅超过阈值）；用户没点播放时是 false。
        let heardSomething: Bool
    }

    private let url: URL
    private let queue = DispatchQueue(label: "io.github.emolens.voice")
    private var stream: SCStream?
    private var file: AVAudioFile?
    private var frames: AVAudioFramePosition = 0
    private var sampleRate: Double = 16000
    private var loudest: Float = 0

    init(url: URL) {
        self.url = url
    }

    func start(app: SCRunningApplication, display: SCDisplay) async throws {
        try? FileManager.default.removeItem(at: url)
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 16000          // Whisper 用 16 kHz，文件也小
        config.channelCount = 1
        config.excludesCurrentProcessAudio = true
        config.width = 2                   // 画面用不到，给最小的
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        log.notice("listening to \(app.applicationName, privacy: .public)")
    }

    func stop() async -> Recording {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        return queue.sync {
            file = nil   // 释放即写完文件头
            let seconds = Double(frames) / sampleRate
            log.notice("listened \(String(format: "%.1f", seconds), privacy: .public) s, peak \(String(format: "%.3f", self.loudest), privacy: .public)")
            return Recording(url: url, seconds: seconds, heardSomething: loudest > 0.02 && seconds > 0.5)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let description = sampleBuffer.formatDescription,
              var asbd = description.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &asbd) else { return }
        let count = AVAudioFrameCount(sampleBuffer.numSamples)
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return }
        buffer.frameLength = count
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(count),
                                                           into: buffer.mutableAudioBufferList) == noErr else { return }
        if file == nil {
            sampleRate = format.sampleRate
            file = try? AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            ], commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        }
        try? file?.write(from: buffer)
        frames += AVAudioFramePosition(count)
        if let channel = buffer.floatChannelData?[0] {
            for i in 0..<Int(count) { loudest = max(loudest, abs(channel[i])) }
        }
    }
}
