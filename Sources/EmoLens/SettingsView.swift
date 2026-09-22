import CoreGraphics
import EmoLensCore
import ScreenCaptureKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var windows: [WindowOption] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("设置").font(.title3.weight(.semibold))

            GroupBox("要看的窗口") {
                HStack {
                    Picker("", selection: $settings.windowID) {
                        Text("自动（最大的微信窗口）").tag(CGWindowID(0))
                        ForEach(windows) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    Button("刷新") { Task { await loadWindows() } }
                }
            }

            GroupBox("聊天区域：在截图上拖一个框，只框住消息气泡那一栏") {
                VStack(alignment: .leading, spacing: 6) {
                    RegionPicker(image: monitor.preview, region: $settings.region)
                    HStack {
                        Text("左侧的会话列表和底部输入框不要框进去，识别会更准。").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button("整个窗口") { settings.region = CGRect(x: 0, y: 0, width: 1, height: 1) }
                    }
                }
            }

            GroupBox("分析引擎") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("", selection: $settings.engine) {
                        ForEach(EngineKind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.radioGroup).labelsHidden()
                    if settings.engine != .systemOne {
                        TextField("Ollama 地址", text: $settings.ollamaURL)
                        TextField("模型", text: $settings.ollamaModel)
                    }
                    if settings.engine != .llm {
                        TextField("System One（Kev）服务地址", text: $settings.systemOneURL)
                    }
                }
                .textFieldStyle(.roundedBorder)
            }

            HStack {
                Text("截图间隔 \(settings.interval, specifier: "%.1f") 秒")
                Slider(value: $settings.interval, in: 0.5...5, step: 0.5)
            }

            HStack {
                Button("清空记录") { monitor.clearHistory() }
                Spacer()
                Button("完成") { monitor.restart(); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 440)
        .task { await loadWindows() }
    }

    private func loadWindows() async {
        let found = (try? await WindowCapture.windows()) ?? []
        windows = found.map { WindowOption(window: $0) }.sorted { $0.name < $1.name }
    }
}

struct WindowOption: Identifiable {
    let id: CGWindowID
    let name: String

    init(window: SCWindow) {
        id = window.windowID
        let app = window.owningApplication?.applicationName ?? "未知应用"
        let title = window.title ?? ""
        name = title.isEmpty ? app : "\(app) · \(title)"
    }
}


/// 在窗口截图上拖框选择区域，结果为归一化坐标（原点左上）。
struct RegionPicker: View {
    let image: CGImage?
    @Binding var region: CGRect
    @State private var dragging: CGRect?

    private let width: CGFloat = 404

    var body: some View {
        if let image {
            let height = width * CGFloat(image.height) / CGFloat(image.width)
            let size = CGSize(width: width, height: height)
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1).resizable().frame(width: width, height: height)
                let shown = scaled(dragging ?? region, to: size)
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: size))
                    path.addRect(shown)
                }
                .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                Rectangle().stroke(Color.accentColor, lineWidth: 2)
                    .frame(width: shown.width, height: shown.height)
                    .offset(x: shown.minX, y: shown.minY)
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { dragging = normalized(from: $0.startLocation, to: $0.location, in: size) }
                    .onEnded { _ in
                        if let rect = dragging, rect.width > 0.05, rect.height > 0.05 { region = rect }
                        dragging = nil
                    }
            )
        } else {
            Text("还没有截图。确认微信开着，并已允许屏幕录制权限。")
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: width, height: 120)
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
