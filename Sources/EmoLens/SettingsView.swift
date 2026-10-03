import AppKit
import CoreGraphics
import EmoLensCore
import ScreenCaptureKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var windows: [WindowOption] = []
    @State private var check: CheckState = .idle

    enum CheckState: Equatable { case idle, checking, ok(String), failed(String) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("设置", "Settings")).font(.system(size: 17, weight: .semibold))
                    Text(L("选好窗口、框出聊天区域，再选分析引擎", "Pick a window, select the chat area, then choose an engine"))
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 4)

            Form {
                Section {
                    Picker(L("语言", "Language"), selection: $settings.language) {
                        ForEach(AppLanguage.allCases, id: \.self) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(L("界面、分析用的提示词、关键词安全网和求助热线都会换成所选语言。",
                           "Switches the interface, the analysis prompts, the keyword safety nets and the crisis resources."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }

                Section(L("要看的窗口", "Window to watch")) {
                    HStack {
                        Picker(L("窗口", "Window"), selection: $settings.windowID) {
                            Text(L("自动：正在开着的聊天软件", "Automatic: the messaging app that's open")).tag(CGWindowID(0))
                            ForEach(windows) { option in
                                Text(option.name).tag(option.id)
                            }
                        }
                        Button(L("刷新", "Refresh")) { Task { await loadWindows() } }
                    }
                }

                Section {
                    RegionPicker(image: monitor.preview, region: $settings.region)
                        .frame(maxWidth: .infinity)
                    HStack {
                        Text(L("只框住消息气泡那一栏，不要框左侧会话列表和底部输入框。",
                               "Select only the column of message bubbles — not the conversation list or the input box."))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button(L("用整个窗口", "Use whole window")) { settings.region = CGRect(x: 0, y: 0, width: 1, height: 1) }
                    }
                } header: {
                    Text(L("聊天区域", "Chat area"))
                }

                Section(L("分析引擎", "Analysis engine")) {
                    Picker(L("引擎", "Engine"), selection: $settings.engine) {
                        ForEach(EngineKind.allCases) { kind in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(kind.name)
                                Text(kind.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            .tag(kind)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .onChange(of: settings.engine) { check = .idle }
                    if settings.engine != .systemOne {
                        Picker(L("大模型来源", "Language model source"), selection: $settings.llmProvider) {
                            ForEach(LLMProvider.allCases) { Text($0.name).tag($0) }
                        }
                        .onChange(of: settings.llmProvider) { check = .idle }
                        providerFields
                    }
                    if settings.engine != .llm {
                        Picker(L("决策模型来源", "Decision model source"), selection: $settings.systemOneProvider) {
                            ForEach(SystemOneProvider.allCases) { Text($0.name).tag($0) }
                        }
                        .onChange(of: settings.systemOneProvider) { check = .idle }
                        systemOneFields
                    }
                    HStack {
                        Button(L("测试连接", "Test connection")) { Task { await testConnection() } }
                            .disabled(check == .checking)
                        checkLabel
                    }
                }

                Section {
                    Toggle(L("看懂表情和表情包", "Read emoji and stickers"), isOn: $settings.readImages)
                } header: {
                    Text(L("表情", "Emoji"))
                } footer: {
                    Text(L("对方发表情、表情包时，把那一小块截图交给分析模型看（每条多约 1 秒）。模型不支持看图时自动跳过，只按「[表情]」分析。用云端模型时，这块截图也会发送给服务商。",
                           "When they send an emoji or sticker, that small crop is shown to the model (about 1 extra second). Skipped if the model can't read images. With a cloud model, the crop is sent to the provider too."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }

                Section {
                    Toggle(L("分析时参考联系人记忆", "Use contact memory when analyzing"), isOn: $settings.useMemory)
                    Toggle(L("自动记录每次的分析结果", "Record each analysis automatically"), isOn: $settings.autoRecordMemory)
                    let contacts = monitor.memory.contacts.values.sorted { $0.name < $1.name }
                    if !contacts.isEmpty {
                        ForEach(contacts, id: \.name) { memory in
                            LabeledContent(memory.name) {
                                HStack {
                                    Text(L("\(memory.notes.count) 件事 · \(memory.entries.count) 次记录", "\(memory.notes.count) notes · \(memory.entries.count) records"))
                                        .foregroundStyle(.secondary)
                                    Button(L("删除", "Delete"), role: .destructive) { monitor.forget(memory.name) }
                                }
                            }
                        }
                        Button(L("清空全部记忆", "Forget everyone"), role: .destructive) { monitor.forgetAll() }
                    }
                } header: {
                    Text(L("联系人记忆", "Contact memory"))
                } footer: {
                    Text(L("只存在本机：~/Library/Application Support/EmoLens/memory.json。用云端模型时，当前联系人的记忆摘要会随分析一起发送。",
                           "Stored only on this Mac: ~/Library/Application Support/EmoLens/memory.json. With a cloud model, the current contact's memory summary is sent along with each analysis."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }

                Section(L("其他", "Other")) {
                    LabeledContent(L("截图间隔", "Capture interval")) {
                        HStack {
                            Slider(value: $settings.interval, in: 0.5...5, step: 0.5).frame(width: 160)
                            Text(String(format: "%.1f", settings.interval) + L(" 秒", " s")).monospacedDigit().frame(width: 44, alignment: .trailing)
                        }
                    }
                    LabeledContent(L("分析记录", "Analysis history")) {
                        Button(L("清空", "Clear"), role: .destructive) { monitor.clearHistory() }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Text(settings.cloudProviderName.map { L("会发送给：\($0)", "Sent to: \($0)") } ?? L("所有处理都在本机完成", "Everything stays on this Mac"))
                    .font(.system(size: 11)).foregroundStyle(settings.cloudProviderName == nil ? Color.secondary : Color.orange)
                Spacer()
                Button(L("完成", "Done")) { monitor.restart(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 480, height: 720)
        .task { await loadWindows() }
    }

    @ViewBuilder private var providerFields: some View {
        switch settings.llmProvider {
        case .ollama:
            TextField(L("Ollama 地址", "Ollama URL"), text: $settings.ollamaURL)
            TextField(L("模型", "Model"), text: $settings.ollamaModel)
            Toggle(L("没在运行时自动启动 Ollama", "Start Ollama automatically if it isn't running"), isOn: $settings.autoStartOllama)
            Text(L("只对本机地址生效。本地起不来时会如实报错，不会自动改用云端模型。",
                   "Only for local addresses. If it can't start, EmoLens tells you — it never switches to a cloud model on its own."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        case .openai:
            Picker(L("服务", "Service"), selection: Binding(get: { settings.openAIPreset }, set: { settings.applyOpenAIPreset($0) })) {
                ForEach(OpenAIPreset.all) { Text($0.name).tag($0.id) }
            }
            TextField(L("接口地址", "Base URL"), text: $settings.openAIBaseURL)
            TextField(L("模型", "Model"), text: $settings.openAIModel, prompt: Text(L("例如 gpt-5.5", "e.g. gpt-5.5")))
            SecureField("API Key", text: $settings.openAIKey)
            cloudNote
        case .anthropic:
            Picker(L("模型", "Model"), selection: $settings.anthropicModel) {
                ForEach(AnthropicBackend.models, id: \.self) { Text($0).tag($0) }
            }
            SecureField("API Key", text: $settings.anthropicKey)
            cloudNote
        }
    }

    private var cloudNote: some View {
        Label(L("云端模式：对方的消息和最近约 10 条聊天（以及对方发的表情截图）会发送给 \(settings.llmCloudName ?? "云端服务") 分析。API Key 只保存在本机钥匙串里。",
                "Cloud mode: their message, the last ~10 messages (and any emoji crops) are sent to \(settings.llmCloudName ?? "the cloud service") for analysis. Your API key stays in this Mac's Keychain."),
              systemImage: "icloud.and.arrow.up")
            .font(.system(size: 11)).foregroundStyle(.orange)
    }

    @ViewBuilder private var systemOneFields: some View {
        switch settings.systemOneProvider {
        case .kev:
            TextField(L("Kev 地址", "Kev URL"), text: $settings.systemOneURL)
            Text(L("本机运行，不联网、不花钱；约占 10 GB 内存。启动方法见 README。", "Runs on this Mac, offline and free; uses about 10 GB of memory. See the README to start it."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        case .jev:
            SecureField("API Key", text: $settings.jevKey)
            TextField(L("模型", "Model"), text: $settings.jevModel, prompt: Text(SystemOneSource.jevModel))
            TextField(L("接口地址", "Base URL"), text: $settings.jevURL)
            Label(L("Jev 是 TypeSafe 的云端决策模型：对方的消息和最近约 10 条聊天会发送给 TypeSafe 分析，按量计费（很便宜）。它没有公开的中文评测。API Key 只保存在本机钥匙串里。",
                    "Jev is TypeSafe's hosted decision model: their message and the last ~10 messages are sent to TypeSafe, billed per use (cheap). Your API key stays in this Mac's Keychain."),
                  systemImage: "icloud.and.arrow.up")
                .font(.system(size: 11)).foregroundStyle(.orange)
        }
    }

    @ViewBuilder private var checkLabel: some View {
        switch check {
        case .idle: EmptyView()
        case .checking: Text(L("连接中…", "Connecting…")).foregroundStyle(.secondary)
        case .ok(let text): Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let text): Label(text, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    private func loadWindows() async {
        let found = (try? await WindowCapture.windows()) ?? []
        windows = found.map(WindowOption.init).sorted { $0.name < $1.name }
    }

    /// 只读地探测引擎：查模型列表（不消耗 token）。
    private func testConnection() async {
        check = .checking
        var results: [String] = []
        do {
            if settings.engine != .systemOne {
                switch settings.llmProvider {
                case .ollama:
                    let names = try await modelNames(settings.ollamaURL, path: "api/tags", key: "models", field: "name")
                    guard names.contains(settings.ollamaModel) else {
                        check = .failed(L("Ollama 里没有 \(settings.ollamaModel)，先运行 ollama pull \(settings.ollamaModel)",
                                          "\(settings.ollamaModel) isn't in Ollama yet — run ollama pull \(settings.ollamaModel)"))
                        return
                    }
                    results.append(L("Ollama 正常", "Ollama OK"))
                case .openai:
                    _ = try await get(settings.openAIBaseURL, path: "models",
                                      headers: ["Authorization": "Bearer \(settings.openAIKey)"])
                    results.append(L("\(settings.llmCloudName ?? "服务") 连接正常", "\(settings.llmCloudName ?? "Service") connected"))
                case .anthropic:
                    _ = try await get("https://api.anthropic.com", path: "v1/models",
                                      headers: ["x-api-key": settings.anthropicKey, "anthropic-version": "2023-06-01"])
                    results.append(L("Claude 连接正常", "Claude connected"))
                }
            }
            if settings.engine != .llm {
                switch settings.systemOneProvider {
                case .kev:
                    _ = try await get(settings.systemOneURL, path: "v1/models")
                    results.append(L("Kev 正常", "Kev OK"))
                case .jev:
                    guard !settings.jevKey.isEmpty else {
                        check = .failed(L("还没填 Jev 的 API Key", "No Jev API key yet"))
                        return
                    }
                    // 查模型列表，不做判断，不花钱
                    _ = try await get(settings.jevURL, path: "v1/models", headers: ["Authorization": "Bearer \(settings.jevKey)"])
                    results.append(L("Jev 连接正常", "Jev connected"))
                }
            }
            check = .ok(results.joined(separator: L("，", ", ")))
        } catch let error as AnalyzerError {
            check = .failed(error.localizedDescription)
        } catch {
            check = .failed(L("连不上：\(error.localizedDescription)", "Can't connect: \(error.localizedDescription)"))
        }
    }

    private func modelNames(_ base: String, path: String, key: String, field: String) async throws -> [String] {
        let data = try await get(base, path: path)
        let list = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?[key] as? [[String: Any]]
        return list?.compactMap { $0[field] as? String } ?? []
    }

    private func get(_ base: String, path: String, headers: [String: String] = [:]) async throws -> Data {
        guard let url = URL(string: base)?.appending(path: path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 15)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw AnalyzerError.http(service: URL(string: base)?.host() ?? base, status: status,
                                     detail: String(decoding: data.prefix(160), as: UTF8.self))
        }
        return data
    }
}

struct WindowOption: Identifiable {
    let id: CGWindowID
    let name: String

    init(window: SCWindow) {
        id = window.windowID
        let app = window.owningApplication?.applicationName ?? L("未知应用", "Unknown app")
        let title = window.title ?? ""
        name = title.isEmpty || title == app ? app : "\(app) · \(title)"
    }
}

/// 在窗口截图上拖框选择区域，结果为归一化坐标（原点左上）。
struct RegionPicker: View {
    let image: CGImage?
    @Binding var region: CGRect
    @State private var dragging: CGRect?

    private let width: CGFloat = 420

    var body: some View {
        if let image {
            let height = min(360, width * CGFloat(image.height) / CGFloat(image.width))
            let size = CGSize(width: height * CGFloat(image.width) / CGFloat(image.height), height: height)
            let shown = scaled(dragging ?? region, to: size)
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1).resizable().frame(width: size.width, height: size.height)
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: size))
                    path.addRect(shown)
                }
                .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: dragging == nil ? [] : [6, 4]))
                    .frame(width: shown.width, height: shown.height)
                    .offset(x: shown.minX, y: shown.minY)
                if dragging == nil && region == CGRect(x: 0, y: 0, width: 1, height: 1) {
                    Text(L("按住鼠标拖一个框", "Drag to draw a box"))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(Color.black.opacity(0.6)))
                        .frame(width: size.width, height: size.height)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { dragging = normalized(from: $0.startLocation, to: $0.location, in: size) }
                    .onEnded { _ in
                        if let rect = dragging, rect.width > 0.05, rect.height > 0.05 { region = rect }
                        dragging = nil
                    }
            )
        } else {
            VStack(spacing: 6) {
                Image(systemName: "rectangle.dashed").font(.system(size: 22)).foregroundStyle(.tertiary)
                Text(L("还没有截图：确认聊天软件开着，并已允许屏幕录制权限", "No screenshot yet: make sure your messaging app is open and Screen Recording is allowed"))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 140)
        }
    }

    private func scaled(_ rect: CGRect, to size: CGSize) -> CGRect {
        CGRect(x: rect.minX * size.width, y: rect.minY * size.height,
               width: rect.width * size.width, height: rect.height * size.height)
    }

    private func normalized(from a: CGPoint, to b: CGPoint, in size: CGSize) -> CGRect {
        func clamp(_ v: CGFloat) -> CGFloat { min(1, max(0, v)) }
        let x0 = clamp(min(a.x, b.x) / size.width), x1 = clamp(max(a.x, b.x) / size.width)
        let y0 = clamp(min(a.y, b.y) / size.height), y1 = clamp(max(a.y, b.y) / size.height)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}
