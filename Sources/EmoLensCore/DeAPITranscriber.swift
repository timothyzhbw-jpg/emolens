import Foundation

/// 用 deAPI（https://deapi.ai）把语音转成文字：EmoLens 自己听不懂声音，
/// 用户在聊天软件里播放一条语音时录下那个软件的声音，交给 deAPI 上的 Whisper 转写，再照常分析。
/// 用的是 deAPI 兼容 OpenAI 的接口：POST /v1/audio/transcriptions（multipart，连接会一直等到转写完成）。
/// 只在用户打开「用 deAPI 听语音」并点了「听这条语音」时才会调用：语音会发给 deAPI，按量计费。
public struct DeAPITranscriber: Sendable {
    public static let defaultURL = URL(string: "https://oai.deapi.ai/v1")!
    /// WhisperLargeV3：段落级时间戳，够用也便宜；WhisperLargeV3Ct2 多了逐词时间戳和说话人区分。
    public static let defaultModel = "WhisperLargeV3"

    public var baseURL: URL
    public var apiKey: String
    public var model: String

    public init(apiKey: String, model: String = DeAPITranscriber.defaultModel, baseURL: URL = DeAPITranscriber.defaultURL) {
        self.apiKey = apiKey
        self.model = model.isEmpty ? Self.defaultModel : model
        self.baseURL = baseURL
    }

    /// 返回转写出的文字；没听到人声时返回空字符串（deAPI 对静音返回空结果，不算错误）。
    /// language 是 ISO 639-1 代码（zh / en），不填让模型自己判断。
    public func transcribe(_ audio: Data, filename: String = "voice.wav", mimeType: String = "audio/wav",
                           language: String? = nil) async throws -> String {
        let boundary = "emolens-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", model)
        field("response_format", "json")
        if let language, !language.isEmpty { field("language", language) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        // 任务在分布式 GPU 上跑，网关会一直等到转写完成；短语音一般几秒，给足时间
        var request = URLRequest(url: baseURL.appending(path: "audio/transcriptions"), timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await HTTP.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (200..<300).contains(status) else {
            let error = object?["error"] as? [String: Any]
            let detail = (error?["message"] as? String) ?? (object?["message"] as? String)
                ?? String(decoding: data.prefix(200), as: UTF8.self)
            throw AnalyzerError.http(service: "deAPI", status: status, detail: detail)
        }
        guard let text = object?["text"] as? String else {
            throw AnalyzerError.badResponse("deAPI 返回里没有 text")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
