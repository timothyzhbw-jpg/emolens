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
                    Text("设置").font(.system(size: 17, weight: .semibold))
                    Text("选好窗口、框出聊天区域，再选分析引擎").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 4)

            Form {
                Section("要看的窗口") {
                    HStack {
                        Picker("窗口", selection: $settings.windowID) {
                            Text("自动：最大的微信窗口").tag(CGWindowID(0))
                            ForEach(windows) { option in
                                Text(option.name).tag(option.id)
                            }
                        }
                        Button("刷新") { Task { await loadWindows() } }
                    }
                }

                Section {
                    RegionPicker(image: monitor.preview, region: $settings.region)
                        .frame(maxWidth: .infinity)
                    HStack {
                        Text("只框住消息气泡那一栏，不要框左侧会话列表和底部输入框。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button("用整个窗口") { settings.region = CGRect(x: 0, y: 0, width: 1, height: 1) }
                    }
                } header: {
                    Text("聊天区域")
                }

                Section("分析引擎") {
                    Picker("引擎", selection: $settings.engine) {
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
                        Picker("大模型来源", selection: $settings.llmProvider) {
                            ForEach(LLMProvider.allCases) { Text($0.name).tag($0) }
                        }
                        .onChange(of: settings.llmProvider) { check = .idle }
                        providerFields
                    }
                    if settings.engine != .llm {
                        TextField("Kev（System One）地址", text: $settings.systemOneURL)
                    }
                    HStack {
                        Button("测试连接") { Task { await testConnection() } }
                            .disabled(check == .checking)
                        checkLabel
                    }
                }

                Section {
                    Toggle("看懂表情和表情包", isOn: $settings.readImages)
                } header: {
                    Text("表情")
                } footer: {
                    Text("对方发表情、表情包时，把那一小块截图交给分析模型看（每条多约 1 秒）。模型不支持看图时自动跳过，只按「[表情]」分析。用云端模型时，这块截图也会发送给服务商。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }

                Section {
                    Toggle("分析时参考联系人记忆", isOn: $settings.useMemory)
                    Toggle("自动记录每次的分析结果", isOn: $settings.autoRecordMemory)
                    let contacts = monitor.memory.contacts.values.sorted { $0.name < $1.name }
                    if !contacts.isEmpty {
                        ForEach(contacts, id: \.name) { memory in
                            LabeledContent(memory.name) {
                                HStack {
                                    Text("\(memory.notes.count) 件事 · \(memory.entries.count) 次记录").foregroundStyle(.secondary)
                                    Button("删除", role: .destructive) { monitor.forget(memory.name) }
                                }
                            }
                        }
                        Button("清空全部记忆", role: .destructive) { monitor.forgetAll() }
                    }
                } header: {
                    Text("联系人记忆")
                } footer: {
                    Text("只存在本机：~/Library/Application Support/EmoLens/memory.json。用云端模型时，当前联系人的记忆摘要会随分析一起发送。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }

                Section("其他") {
                    LabeledContent("截图间隔") {
                        HStack {
                            Slider(value: $settings.interval, in: 0.5...5, step: 0.5).frame(width: 160)
                            Text("\(settings.interval, specifier: "%.1f") 秒").monospacedDigit().frame(width: 44, alignment: .trailing)
                        }
                    }
                    LabeledContent("分析记录") {
                        Button("清空", role: .destructive) { monitor.clearHistory() }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Text("所有处理都在本机完成").font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                Button("完成") { monitor.restart(); dismiss() }
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
            TextField("Ollama 地址", text: $settings.ollamaURL)
            TextField("模型", text: $settings.ollamaModel)
            Toggle("没在运行时自动启动 Ollama", isOn: $settings.autoStartOllama)
            Text("只对本机地址生效。本地起不来时会如实报错，不会自动改用云端模型。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        case .openai:
            Picker("服务", selection: Binding(get: { settings.openAIPreset }, set: { settings.applyOpenAIPreset($0) })) {
                ForEach(OpenAIPreset.all) { Text($0.name).tag($0.id) }
            }
            TextField("接口地址", text: $settings.openAIBaseURL)
            TextField("模型", text: $settings.openAIModel, prompt: Text("例如 gpt-5.5"))
            SecureField("API Key", text: $settings.openAIKey)
            cloudNote
        case .anthropic:
            Picker("模型", selection: $settings.anthropicModel) {
                ForEach(AnthropicBackend.models, id: \.self) { Text($0).tag($0) }
            }
            SecureField("API Key", text: $settings.anthropicKey)
            cloudNote
        }
    }

    private var cloudNote: some View {
        Label("云端模式：对方的消息和最近约 10 条聊天（以及对方发的表情截图）会发送给 \(settings.cloudProviderName ?? "云端服务") 分析。API Key 只保存在本机钥匙串里。",
              systemImage: "icloud.and.arrow.up")
            .font(.system(size: 11)).foregroundStyle(.orange)
    }

    @ViewBuilder private var checkLabel: some View {
        switch check {
        case .idle: EmptyView()
        case .checking: Text("连接中…").foregroundStyle(.secondary)
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
                        check = .failed("Ollama 里没有 \(settings.ollamaModel)，先运行 ollama pull \(settings.ollamaModel)")
                        return
                    }
                    results.append("Ollama 正常")
                case .openai:
                    _ = try await get(settings.openAIBaseURL, path: "models",
                                      headers: ["Authorization": "Bearer \(settings.openAIKey)"])
                    results.append("\(settings.cloudProviderName ?? "服务") 连接正常")
                case .anthropic:
                    _ = try await get("https://api.anthropic.com", path: "v1/models",
                                      headers: ["x-api-key": settings.anthropicKey, "anthropic-version": "2023-06-01"])
                    results.append("Claude 连接正常")
                }
            }
            if settings.engine != .llm {
                _ = try await get(settings.systemOneURL, path: "v1/models")
                results.append("Kev 正常")
            }
            check = .ok(results.joined(separator: "，"))
        } catch let error as AnalyzerError {
            check = .failed(error.localizedDescription)
        } catch {
            check = .failed("连不上：\(error.localizedDescription)")
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
        let app = window.owningApplication?.applicationName ?? "未知应用"
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
                    Text("按住鼠标拖一个框")
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
                Text("还没有截图：确认微信开着，并已允许屏幕录制权限").font(.system(size: 11.5)).foregroundStyle(.secondary)
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
