import AppKit
import EmoLensCore
import SwiftUI

struct PanelView: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var settings: AppSettings
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Picker("和 TA 的关系", selection: $settings.relationship) {
                ForEach(relationships, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented)
            if monitor.status == .needsPermission { PermissionHint() }
            if let error = monitor.analysisError { Banner(text: error, color: .orange) }
            if let report = monitor.reports.first {
                ReportCard(report: report, analyzing: monitor.analyzing)
            } else {
                EmptyHint(analyzing: monitor.analyzing)
            }
            if monitor.reports.count > 1 { HistoryList(reports: Array(monitor.reports.dropFirst().prefix(8))) }
            Spacer(minLength: 0)
            Text("截图、识别和分析都在本机完成，不上传任何聊天内容。结果仅供参考，不能代替沟通。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(minWidth: 320, idealWidth: 360, minHeight: 460)
        .sheet(isPresented: $showSettings) { SettingsView(monitor: monitor, settings: settings) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(monitor.status.text).font(.subheadline.weight(.medium))
                if !monitor.windowName.isEmpty {
                    Text(monitor.windowName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Button(monitor.isRunning ? "暂停" : "开始") { monitor.isRunning ? monitor.pause() : monitor.start() }
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .help("选择窗口、聊天区域和分析引擎")
        }
    }

    private var statusColor: Color {
        switch monitor.status {
        case .watching: monitor.analyzing ? .blue : .green
        case .paused: .gray
        default: .orange
        }
    }
}

struct ReportCard: View {
    let report: EmotionReport
    let analyzing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ChatState.line(report.message))
                .font(.callout).lineLimit(3).textSelection(.enabled)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Mood.emoji(report.emotion)).font(.system(size: 30))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(report.emotion).font(.title3.weight(.semibold))
                        if let p = report.emotionProbability {
                            Text("\(Int(p * 100))%").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    IntensityBar(value: report.intensity)
                }
                Spacer()
                if analyzing { ProgressView().controlSize(.small) }
            }

            let flags = report.activeFlags()
            let selfHarm = flags.contains(.selfHarm)
            if selfHarm { SafetyBanner() }
            HStack(spacing: 6) {
                if let c = report.consistency, !c.isEmpty, c != "一致" { Tag(text: "字面≠真实：\(c)", color: .purple) }
                if let t = report.target, !t.isEmpty { Tag(text: "冲着：\(t)", color: .secondary) }
            }
            if !flags.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(flags, id: \.self) { FlagChip(flag: $0, probability: report.flags[$0.rawValue] ?? 0) }
                }
            }
            if !selfHarm, let meaning = report.realMeaning, !meaning.isEmpty {
                Field(title: "潜台词", text: meaning)
            }
            if !selfHarm, let response = report.bestResponse, !response.isEmpty {
                Field(title: "建议回应", text: response)
            }
            if let reply = report.suggestedReply, !reply.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("可以这样回").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("复制") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(reply, forType: .string)
                        }
                        .buttonStyle(.link).font(.caption)
                    }
                    Text(reply).textSelection(.enabled)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            Text("\(report.engine) · \(Int(report.latencyMs)) ms · \(report.date.formatted(date: .omitted, time: .shortened))")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

struct Field: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(text).textSelection(.enabled)
        }
    }
}

struct IntensityBar: View {
    let value: Double

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Capsule().fill(Double(i) < value.rounded() ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: 18, height: 5)
            }
            Text("强度 \(value, specifier: "%.1f") / 3").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct FlagChip: View {
    let flag: EmotionFlag
    let probability: Double

    var body: some View {
        let color: Color = flag.isSerious ? .red : .orange
        HStack(spacing: 4) {
            Text(flag.title)
            if probability < 1 { Text("\(Int(probability * 100))%").foregroundStyle(.secondary) }
        }
        .font(.caption)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(0.15), in: Capsule())
        .foregroundStyle(color)
    }
}

/// 自伤信号：措辞克制、不下诊断，先接住人，再给求助渠道。模型可能误判，所以提醒对照原句。
struct SafetyBanner: View {
    var body: some View {
        Banner(text: "这句话里，对方可能撑得很辛苦（AI 判断不一定准，请对照原句）。先接住 TA，问一句「你现在安全吗？」，陪着 TA。"
            + "如果 TA 提到具体的打算、正在伤害自己或突然联系不上，请马上联系 TA 身边的人，或拨打 120 / 110。"
            + "心理援助热线：12356（多数地区已开通），希望24热线 400-161-9995。", color: .red)
    }
}

struct Tag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text).font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
            .foregroundStyle(color)
    }
}

struct PermissionHint: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Banner(text: "请在「系统设置 → 隐私与安全性 → 录屏与系统录音」里允许 EmoLens，然后重新打开应用。", color: .orange)
            Button("打开系统设置") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
        }
    }
}

struct Banner: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text).font(.caption).textSelection(.enabled)
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct EmptyHint: View {
    let analyzing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text("等对方发来新消息…").font(.headline); if analyzing { ProgressView().controlSize(.small) } }
            Text("打开微信里的一个聊天，EmoLens 会读取对方最新的消息并分析情绪。第一次使用请点右上角齿轮，框出聊天区域。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 20)
    }
}

struct HistoryList: View {
    let reports: [EmotionReport]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("之前").font(.caption).foregroundStyle(.secondary)
            ForEach(reports) { report in
                HStack(spacing: 6) {
                    Text(Mood.emoji(report.emotion))
                    Text(report.message.text).lineLimit(1).foregroundStyle(.secondary)
                    Spacer()
                    if report.activeFlags().contains(where: \.isSerious) { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }
                .font(.caption)
            }
        }
    }
}

enum Mood {
    static func emoji(_ emotion: String) -> String {
        let table = ["开心": "😊", "平静": "🙂", "亲昵": "🥰", "难过": "😢", "委屈": "🥺", "生气": "😠",
                     "失望": "😞", "焦虑": "😟", "冷淡": "😶", "尴尬": "😳"]
        return table[emotion] ?? "💬"
    }
}
