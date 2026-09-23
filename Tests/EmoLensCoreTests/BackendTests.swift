@testable import EmoLensCore
import XCTest

/// 拦截 URLSession 请求：记录发出去的请求，返回预设的响应。
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var responseBody = Data()
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

final class BackendTests: XCTestCase {
    private let schema = #"{"type": "object", "properties": {"literal": {"type": "string"}, "suggested_reply": {"type": "string"}}, "required": ["literal", "suggested_reply"], "additionalProperties": false}"#
    private let turns = [ChatTurn(role: "user", content: "示例"), ChatTurn(role: "assistant", content: "{}"), ChatTurn(role: "user", content: "对方：嗯")]

    override func setUp() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        HTTP.session = URLSession(configuration: config)
        MockURLProtocol.status = 200
    }

    override func tearDown() {
        HTTP.session = .shared
    }

    private func respond(_ json: String, status: Int = 200) {
        MockURLProtocol.status = status
        MockURLProtocol.responseBody = Data(json.utf8)
    }

    private var sentText: String { String(decoding: MockURLProtocol.lastBody, as: UTF8.self) }
    private var sent: [String: Any] { (try? JSONSerialization.jsonObject(with: MockURLProtocol.lastBody) as? [String: Any]) ?? [:] }
    private func header(_ name: String) -> String? { MockURLProtocol.lastRequest?.value(forHTTPHeaderField: name) }

    // MARK: 图片（看表情、表情包）

    private let imageTurn = [ChatTurn(role: "user", content: "这是什么表情", images: [Data([0x89, 0x50])])]

    func testOllamaSendsImagesAndLargerContext() async throws {
        respond(#"{"message": {"content": "{\"emoji\": \"捂脸\"}"}, "done_reason": "stop"}"#)
        _ = try await OllamaBackend().complete(system: "只输出 JSON", turns: imageTurn, schema: nil)
        let messages = try XCTUnwrap(sent["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.last?["images"] as? [String], ["iVA="])
        XCTAssertEqual((sent["options"] as? [String: Any])?["num_ctx"] as? Int, OllamaBackend.contextLength)
    }

    func testOllamaTruncatedOutputIsReported() async {
        respond(#"{"message": {"content": "{\"literal\": \"好"}, "done_reason": "length"}"#)
        do {
            _ = try await OllamaBackend().complete(system: "", turns: turns, schema: nil)
            XCTFail("截断应当报错")
        } catch AnalyzerError.badResponse(let detail) {
            XCTAssertTrue(detail.contains("截断"))
        } catch {
            XCTFail("\(error)")
        }
    }

    func testOpenAISendsImageAsDataURL() async throws {
        respond(#"{"choices": [{"finish_reason": "stop", "message": {"content": "{}"}}]}"#)
        _ = try await OpenAICompatibleBackend(apiKey: "sk-test").complete(system: "只输出 JSON", turns: imageTurn, schema: nil)
        let messages = try XCTUnwrap(sent["messages"] as? [[String: Any]])
        let parts = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        XCTAssertEqual(parts.first?["type"] as? String, "text")
        XCTAssertEqual((parts.last?["image_url"] as? [String: Any])?["url"] as? String, "data:image/png;base64,iVA=")
    }

    func testAnthropicSendsImageBlockBeforeText() async throws {
        respond(#"{"stop_reason": "end_turn", "content": [{"type": "text", "text": "{}"}]}"#)
        _ = try await AnthropicBackend(apiKey: "k").complete(system: "只输出 JSON", turns: imageTurn, schema: nil)
        let messages = try XCTUnwrap(sent["messages"] as? [[String: Any]])
        let blocks = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.map { $0["type"] as? String }, ["image", "text"])
        let source = try XCTUnwrap(blocks.first?["source"] as? [String: Any])
        XCTAssertEqual(source["media_type"] as? String, "image/png")
        XCTAssertEqual(source["data"] as? String, "iVA=")
    }

    // MARK: OpenAI 兼容

    func testOpenAIRequestUsesStrictSchemaAndBearerKey() async throws {
        respond(#"{"choices": [{"finish_reason": "stop", "message": {"content": "{\"literal\": \"嗯\"}"}}]}"#)
        let backend = OpenAICompatibleBackend(apiKey: "sk-test")
        let content = try await backend.complete(system: "只输出 JSON", turns: turns, schema: schema)
        XCTAssertEqual(content, #"{"literal": "嗯"}"#)
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(header("Authorization"), "Bearer sk-test")
        XCTAssertEqual(sent["model"] as? String, "gpt-5.5")
        XCTAssertNil(sent["temperature"], "推理模型只接受默认 temperature，不应发送")
        let messages = try XCTUnwrap(sent["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"]! }, ["system", "user", "assistant", "user"])
        let format = try XCTUnwrap(sent["response_format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        let jsonSchema = try XCTUnwrap(format["json_schema"] as? [String: Any])
        XCTAssertEqual(jsonSchema["strict"] as? Bool, true)
        XCTAssertNotNil(jsonSchema["schema"] as? [String: Any], "schema 应当被原样嵌入为对象")
        let literal = try XCTUnwrap(sentText.range(of: "\"literal\""))
        let reply = try XCTUnwrap(sentText.range(of: "\"suggested_reply\""))
        XCTAssertLessThan(literal.lowerBound, reply.lowerBound, "schema 字段顺序要保留：先字面，后回复")
    }

    func testCompatibleServiceFallsBackToJSONObject() async throws {
        respond(#"{"choices": [{"message": {"content": "{}"}}]}"#)
        let backend = OpenAICompatibleBackend(baseURL: URL(string: "https://api.deepseek.com")!, model: "deepseek-chat",
                                              apiKey: "k", supportsJSONSchema: false, providerName: "DeepSeek")
        _ = try await backend.complete(system: "JSON", turns: turns, schema: schema)
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.absoluteString, "https://api.deepseek.com/chat/completions")
        XCTAssertEqual((sent["response_format"] as? [String: String])?["type"], "json_object")
        XCTAssertFalse(sentText.contains("@@EMOLENS_SCHEMA@@"))
        XCTAssertEqual(backend.cloudProvider, "DeepSeek")
    }

    func testOpenAIErrorsAreFriendly() async {
        respond(#"{"error": {"message": "Incorrect API key provided"}}"#, status: 401)
        do {
            _ = try await OpenAICompatibleBackend(apiKey: "bad").complete(system: "", turns: turns, schema: nil)
            XCTFail("应当抛错")
        } catch {
            XCTAssertEqual(error.localizedDescription, "OpenAI 的 API Key 无效或没填，请在设置里检查。")
        }
        respond(#"{"choices": [{"message": {"content": null, "refusal": "I can't help with that."}}]}"#)
        do {
            _ = try await OpenAICompatibleBackend(apiKey: "k").complete(system: "", turns: turns, schema: nil)
            XCTFail("应当抛错")
        } catch AnalyzerError.refused(let message) {
            XCTAssertTrue(message.contains("I can't help with that."))
        } catch {
            XCTFail("应当是 refused：\(error)")
        }
    }

    // MARK: Anthropic

    func testAnthropicRequestShape() async throws {
        respond(#"{"stop_reason": "end_turn", "content": [{"type": "thinking", "thinking": ""}, {"type": "text", "text": "{\"literal\": \"嗯\"}"}]}"#)
        let backend = AnthropicBackend(apiKey: "sk-ant-test")
        let content = try await backend.complete(system: "系统提示", turns: turns, schema: schema)
        XCTAssertEqual(content, #"{"literal": "嗯"}"#, "只取 text 块，跳过思考块")
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(header("x-api-key"), "sk-ant-test")
        XCTAssertEqual(header("anthropic-version"), "2023-06-01")
        XCTAssertEqual(header("anthropic-beta"), "server-side-fallback-2026-07-01")
        XCTAssertEqual(sent["model"] as? String, "claude-opus-5")
        XCTAssertEqual(sent["fallbacks"] as? String, "default")
        XCTAssertEqual(sent["system"] as? String, "系统提示")
        XCTAssertEqual((sent["messages"] as? [[String: String]])?.map { $0["role"]! }, ["user", "assistant", "user"])
        XCTAssertEqual(sent["max_tokens"] as? Int, 16000)
        XCTAssertNil(sent["temperature"])
        XCTAssertNil(sent["thinking"], "Opus 5 默认自适应思考，不需要显式设置")
        let format = try XCTUnwrap((sent["output_config"] as? [String: Any])?["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertNotNil(format["schema"] as? [String: Any])
    }

    func testFallbacksOnlyForModelsThatNeedThem() async throws {
        respond(#"{"stop_reason": "end_turn", "content": [{"type": "text", "text": "{}"}]}"#)
        _ = try await AnthropicBackend(model: "claude-haiku-4-5", apiKey: "k").complete(system: "", turns: turns, schema: nil)
        XCTAssertNil(sent["fallbacks"])
        XCTAssertNil(header("anthropic-beta"))
        XCTAssertNil(sent["output_config"], "没有 schema 时不发结构化输出")
    }

    func testAnthropicRefusalAndErrors() async {
        respond(#"{"stop_reason": "refusal", "stop_details": {"type": "refusal", "category": null}, "content": []}"#)
        do {
            _ = try await AnthropicBackend(apiKey: "k").complete(system: "", turns: turns, schema: nil)
            XCTFail("应当抛错")
        } catch AnalyzerError.refused {
        } catch {
            XCTFail("应当是 refused：\(error)")
        }
        respond(#"{"type": "error", "error": {"type": "overloaded_error", "message": "Overloaded"}}"#, status: 529)
        do {
            _ = try await AnthropicBackend(apiKey: "k").complete(system: "", turns: turns, schema: nil)
            XCTFail("应当抛错")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("服务暂时繁忙"), error.localizedDescription)
        }
    }

    // MARK: Ollama 与整体流程

    func testOllamaRequestShape() async throws {
        respond(#"{"message": {"content": "{}"}}"#)
        _ = try await OllamaBackend().complete(system: "s", turns: turns, schema: schema)
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.absoluteString, "http://127.0.0.1:11434/api/chat")
        XCTAssertEqual(sent["format"] as? String, "json")
        XCTAssertEqual(sent["think"] as? Bool, false)
        XCTAssertNil(OllamaBackend().cloudProvider)
    }

    func testLLMAnalyzerEndToEndWithClaude() async throws {
        let answer = #"{"literal": "没事", "consistency": "反话", "real_meaning": "其实很失落", "emotion": "委屈", "intensity": 2, "target": "我", "angry_at_me": true, "perfunctory": false, "needs_comfort": true, "testing": false, "cold_distance": false, "conflict": false, "manipulation": false, "self_harm": false, "best_response": "真诚道歉", "suggested_reply": "对不起，是我没顾上你"}"#
        let escaped = answer.replacingOccurrences(of: "\"", with: "\\\"")
        respond(#"{"stop_reason": "end_turn", "content": [{"type": "text", "text": "\#(escaped)"}]}"#)
        let prompt = LLMPrompt(system: "系统", examples: [.init(chat: "例子", answer: ["emotion": .string("开心")])], schema: schema)
        let analyzer = LLMAnalyzer(backend: AnthropicBackend(apiKey: "k"), prompt: prompt, relationship: "恋人")
        let report = try await analyzer.analyze(context: [ChatMessage(speaker: .me, text: "今晚加班", top: 0)],
                                                latest: ChatMessage(speaker: .them, text: "没事", top: 1))
        XCTAssertEqual(report.emotion, "委屈")
        XCTAssertEqual(report.consistency, "反话")
        XCTAssertEqual(report.flags["sarcasm"], 1)
        XCTAssertEqual(report.suggestedReply, "对不起，是我没顾上你")
        XCTAssertEqual(report.engine, "Claude · claude-opus-5")
        let lastUser = try XCTUnwrap((sent["messages"] as? [[String: String]])?.last?["content"])
        XCTAssertTrue(lastUser.hasPrefix("双方关系：恋人"))
        XCTAssertTrue(lastUser.contains("我：今晚加班"))
    }

    func testBundledSchemaIsValidForStructuredOutputs() throws {
        let presets = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../presets").standardized
        let prompt = try LLMPrompt.load(from: presets.appending(path: "emotion.llm.zh.json"))
        let schema = try XCTUnwrap(prompt.schema)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any])
        XCTAssertEqual(object["additionalProperties"] as? Bool, false)
        let properties = try XCTUnwrap(object["properties"] as? [String: Any])
        XCTAssertEqual(Set(object["required"] as? [String] ?? []), Set(properties.keys), "严格模式要求所有字段都必填")
        XCTAssertEqual(Set(properties.keys), Set(LLMAnalyzer.answerOrder), "schema 字段要和示例答案一致")
    }
}
