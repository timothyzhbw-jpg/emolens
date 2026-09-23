import AppKit
import EmoLensCore
import SwiftUI

struct PanelView: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var settings: AppSettings
    /// 预览渲染时关掉滚动视图（它由 AppKit 绘制，渲染不出来）。
    var scrolls = true
    @State private var showSettings = false
    @State private var memoryContact: String?
    @State private var selectedID: UUID?
    @State private var handledSuggestions: Set<UUID> = []
    @State private var transcript = ""

    private var shown: EmotionReport? {
        monitor.reports.first { $0.id == selectedID } ?? monitor.reports.first
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(monitor: monitor, manual: settings.manualMode, openSettings: { showSettings = true })
            ModeSwitch(monitor: monitor, manual: $settings.manualMode)
                .padding(.horizontal, 14).padding(.bottom, 8)
            ContactBar(monitor: monitor) { memoryContact = monitor.currentContact }
                .padding(.horizontal, 14).padding(.bottom, 8)
            RelationshipBar(selection: relationship)
                .padding(.horizontal, 14).padding(.bottom, 10)
            Hairline()
            if scrolls {
                ScrollView { content }
            } else {
                content.frame(maxHeight: .infinity, alignment: .top)
            }
            Hairline()
            PrivacyFooter(cloud: settings.cloudProviderName)
        }
        .frame(minWidth: 340, idealWidth: 372, minHeight: 540)
        .sheet(isPresented: $showSettings) { SettingsView(monitor: monitor, settings: settings) }
        .sheet(item: Binding(get: { memoryContact.map(ContactID.init) }, set: { memoryContact = $0?.name })) { item in
            MemoryView(monitor: monitor, settings: settings, contact: item.name)
        }
        .onChange(of: monitor.reports.first?.id) { selectedID = nil }
    }

    private var content: some View {
        VStack(spacing: 12) {
            Notices(monitor: monitor)
            if settings.manualMode {
                ManualView(monitor: monitor, settings: settings, transcript: $transcript, editable: scrolls)
            }
            if let report = shown {
                ReportView(report: report,
                           isLatest: report.id == monitor.reports.first?.id,
                           analyzing: monitor.analyzing,
                           suggestion: suggestion(for: report),
                           history: signalHistory(for: report))
                    .id(report.id)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                Onboarding(monitor: monitor, settings: settings, openSettings: { showSettings = true })
            }
            if monitor.reports.count > 1 {
                HistoryView(reports: monitor.reports, selectedID: $selectedID, shownID: shown?.id)
            }
        }
        .padding(14)
        .animation(.easeOut(duration: 0.25), value: shown?.id)
    }

    /// 认出联系人时，关系跟着联系人走；否则用全局选择。
    private var relationship: Binding<String> {
        Binding(
            get: { _ = monitor.memoryVersion; return monitor.relationship(for: monitor.currentContact) },
            set: { value in
                if let contact = monitor.currentContact {
                    monitor.editMemory(contact) { $0.relationship = value }
                } else {
                    settings.relationship = value
                }
            })
    }

    /// 这个联系人最近 14 天各信号出现的次数。
    private func signalHistory(for report: EmotionReport) -> [EmotionFlag: Int] {
        _ = monitor.memoryVersion
        guard let contact = report.contact ?? monitor.currentContact else { return [:] }
        return Dictionary(uniqueKeysWithValues: monitor.contactMemory(contact).counts(days: 14).signals)
    }

    private func suggestion(for report: EmotionReport) -> MemorySuggestion? {
        guard let note = report.memoryNote, !handledSuggestions.contains(report.id) else { return nil }
        let contact = report.contact ?? monitor.currentContact
        return MemorySuggestion(note: note, contact: contact,
                                remember: {
                                    if let contact { monitor.remember(note, for: contact) }
                                    handledSuggestions.insert(report.id)
                                },
                                dismiss: { handledSuggestions.insert(report.id) })
    }
}

/// 让联系人名字能用在 .sheet(item:) 上。
struct ContactID: Identifiable {
    let name: String
    var id: String { name }
}

// MARK: - Header

struct PanelHeader: View {
    @ObservedObject var monitor: Monitor
    var manual = false
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.brand)
                Image(systemName: "eye.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text("情绪透镜").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 4) {
                    PulseDot(color: statusColor, active: monitor.status == .watching)
                        .frame(width: 10, height: 10)
                    Text(statusText).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if !manual {
                IconButton(symbol: monitor.isRunning ? "pause.fill" : "play.fill",
                           help: monitor.isRunning ? "暂停" : "开始") {
                    monitor.isRunning ? monitor.pause() : monitor.start()
                }
            }
            IconButton(symbol: "slider.horizontal.3", help: "设置", action: openSettings)
        }
        .padding(.leading, 30)   // 给窗口左上角的关闭按钮留位置
        .padding(.trailing, 12)
        .padding(.top, 8).padding(.bottom, 10)
    }

    private var statusText: String {
        if monitor.analyzing { return "正在分析…" }
        if manual { return "手动模式 · 不截屏" }
        if monitor.status == .watching, !monitor.windowName.isEmpty { return "正在看 · \(monitor.windowName)" }
        return monitor.status.text
    }

    private var statusColor: Color {
        if manual { return .purple }
        switch monitor.status {
        case .watching: return monitor.analyzing ? .blue : .green
        case .paused: return .gray
        default: return .orange
        }
    }
}

/// 选择双方关系：同一句话在不同关系里意思不同。
struct RelationshipBar: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(relationships, id: \.self) { item in
                let selected = item == selection
                Button { selection = item } label: {
                    Text(item)
                        .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(selected ? Color.primary.opacity(0.09) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.04)))
        .help("你和 TA 的关系，会影响对潜台词的判断")
    }
}

// MARK: - Report

struct ReportView: View {
    let report: EmotionReport
    let isLatest: Bool
    let analyzing: Bool
    var suggestion: MemorySuggestion? = nil
    /// 最近 14 天这些信号各出现过几次（来自联系人记忆），用来区分「偶尔一次」和「经常这样」。
    var history: [EmotionFlag: Int] = [:]

    private var selfHarm: Bool { report.activeFlags().contains(.selfHarm) }
    /// 有轻生信号时不显示「情感操控」：给说「我是累赘」的人贴操控标签是有害的，这时先确认 TA 的安全。
    private var flags: [EmotionFlag] { report.activeFlags().filter { !(selfHarm && $0 == .manipulation) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MessageQuote(message: report.message, date: report.date, isLatest: isLatest, analyzing: analyzing)
            if selfHarm { SafetyCard() }
            if flags.contains(.asksMoney) { MoneyCard() }
            EmotionHero(report: report)
            if !selfHarm, let meaning = report.realMeaning, !meaning.isEmpty {
                SubtextCard(literal: report.literal, meaning: meaning, consistency: report.consistency)
            }
            if !flags.isEmpty { SignalsCard(flags: flags, probabilities: report.flags) }
            if !selfHarm, flags.contains(.manipulation) { ManipulationNote(recent: history[.manipulation] ?? 0) }
            if report.bestResponse != nil || report.suggestedReply != nil {
                SuggestionCard(response: suggestedResponse, reply: report.suggestedReply)
            }
            if let suggestion { suggestion }
            Text("\(report.engine) · \(String(format: "%.1f", report.latencyMs / 1000)) 秒")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// 对方的原话，做成微信里「对方气泡」的样子。
struct MessageQuote: View {
    let message: ChatMessage
    let date: Date
    let isLatest: Bool
    let analyzing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(isLatest ? "TA 刚刚说" : "TA 之前说").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                if let sender = message.sender { Text(sender).font(.system(size: 11)).foregroundStyle(.tertiary) }
                Spacer()
                if isLatest && analyzing { Spinner(size: 10) }
                Text(date.formatted(date: .omitted, time: .shortened)).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(Color.primary.opacity(0.10)).frame(width: 26, height: 26)
                    .overlay(Image(systemName: "person.fill").font(.system(size: 11)).foregroundStyle(.secondary))
                Text(message.text)
                    .font(.system(size: 13.5))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 11).padding(.vertical, 8)
                    .background(BubbleShape(tailOnLeft: true).fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(BubbleShape(tailOnLeft: true).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                Spacer(minLength: 24)
            }
        }
    }
}

/// 主要情绪：大表情 + 名称 + 强度条 + 指向。
struct EmotionHero: View {
    let report: EmotionReport

    var body: some View {
        let color = Theme.color(for: report.emotion)
        HStack(spacing: 12) {
            Text(Theme.emoji(for: report.emotion))
                .font(.system(size: 30))
                .frame(width: 52, height: 52)
                .background(Circle().fill(color.opacity(0.16)))
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(report.emotion).font(.system(size: 20, weight: .bold)).foregroundStyle(color)
                    if let p = report.emotionProbability {
                        Text("\(Int(p * 100))%").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if let target = report.target, !target.isEmpty {
                        Text("冲着\(target)")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                            .foregroundStyle(.secondary)
                    }
                }
                IntensityMeter(value: report.intensity, color: color)
            }
        }
        .padding(12)
        .card(tint: color)
    }
}

struct IntensityMeter: View {
    let value: Double
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                ForEach(1...3, id: \.self) { level in
                    Capsule()
                        .fill(Double(level) <= value.rounded() ? color : Color.primary.opacity(0.10))
                        .frame(height: 5)
                }
            }
            .frame(width: 96)
            Text("强度 · \(Theme.intensityLabel(value))").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

/// 核心洞察：字面意思 vs 真实想法。
struct SubtextCard: View {
    let literal: String?
    let meaning: String
    let consistency: String?

    private var mismatched: Bool { (consistency ?? "一致") != "一致" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(symbol: "text.magnifyingglass", title: "潜台词", tint: .purple) {
                if mismatched, let consistency {
                    Text("字面 ≠ 真实 · \(consistency)")
                        .font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.purple.opacity(0.14)))
                        .foregroundStyle(.purple)
                }
            }
            if mismatched, let literal, !literal.isEmpty {
                row(label: "TA 说", text: literal, emphasized: false)
            }
            row(label: mismatched ? "TA 想" : "意思是", text: meaning, emphasized: true)
        }
        .padding(12)
        .card()
    }

    private func row(label: String, text: String, emphasized: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary).frame(width: 36, alignment: .leading)
            Text(text)
                .font(.system(size: 13, weight: emphasized ? .medium : .regular))
                .foregroundStyle(emphasized ? .primary : .secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SignalsCard: View {
    let flags: [EmotionFlag]
    let probabilities: [String: Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(symbol: "waveform.path.ecg", title: "关系信号")
            FlowLayout(spacing: 6) {
                ForEach(flags, id: \.self) { flag in
                    SignalChip(flag: flag, probability: probabilities[flag.rawValue] ?? 0)
                }
            }
        }
        .padding(12)
        .card()
    }
}

struct SignalChip: View {
    let flag: EmotionFlag
    let probability: Double

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: flag.symbol).font(.system(size: 10.5, weight: .semibold))
            Text(flag.title).font(.system(size: 11.5, weight: .medium))
            if probability < 0.995 {
                Text("\(Int(probability * 100))%").font(.system(size: 10.5)).opacity(0.7)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .foregroundStyle(flag.tint)
        .background(Capsule().fill(flag.tint.opacity(0.13)))
        .overlay(Capsule().strokeBorder(flag.tint.opacity(flag.isSerious ? 0.45 : 0), lineWidth: 0.8))
    }
}

/// 建议回应 + 一句可直接发送的回复，做成「我方气泡」的样子。
struct SuggestionCard: View {
    let response: String?
    let reply: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionTitle(symbol: Theme.responseSymbol(response ?? ""), title: "建议", tint: Theme.reply) {
                if let response { Text(response).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.reply) }
            }
            if let reply, !reply.isEmpty {
                HStack(alignment: .bottom, spacing: 8) {
                    Spacer(minLength: 20)
                    Text(reply)
                        .font(.system(size: 13.5))
                        .foregroundStyle(.black.opacity(0.88))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 11).padding(.vertical, 8)
                        .background(BubbleShape(tailOnLeft: false).fill(Color(red: 0.62, green: 0.91, blue: 0.47)))
                }
                HStack {
                    Text("可以这样回，按你的习惯改一改").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    Spacer()
                    CopyButton(text: reply)
                }
            }
        }
        .padding(12)
        .card(tint: Theme.reply)
    }
}

extension ReportView {
    /// 安全优先：有轻生信号时先接住人；涉及钱时先核实身份。
    var suggestedResponse: String? {
        if selfHarm { return "先接住 TA" }
        if flags.contains(.asksMoney) { return "先核实身份" }
        return report.bestResponse
    }
}

/// 涉及钱或账号：盗号后冒充熟人借钱很常见，先核实身份再说。
struct MoneyCard: View {
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "creditcard.trianglebadge.exclamationmark")
                .font(.system(size: 17)).foregroundStyle(EmotionFlag.asksMoney.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("这条消息在要钱或要账号信息").font(.system(size: 13, weight: .semibold))
                Text("先打电话或当面确认是不是本人。别急着转账，也别发验证码、支付密码和银行卡号。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(11)
        .card(tint: EmotionFlag.asksMoney.tint)
    }
}

/// 情感操控会误判（「反正我也不重要」这种委屈也常被判成操控），文案要做到误判了也不伤人。
struct ManipulationNote: View {
    let recent: Int

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.shield").font(.system(size: 12)).foregroundStyle(Theme.danger).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(recent >= 2 ? "这类施压最近 14 天出现了 \(recent) 次" : "这句话可能带有情感施压（偶尔一次不代表什么）")
                    .font(.system(size: 12, weight: .semibold))
                Text(recent >= 2
                     ? "一再让你内疚或妥协不是小事。先照顾好自己的感受，必要时找信任的人聊聊，不必急着让步。"
                     : "如果只是一时委屈，可以先回应 TA 的情绪；如果 TA 经常这样让你内疚或让步，先照顾好自己，不必急着妥协。")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .card(tint: Theme.danger)
    }
}

/// 自伤信号：克制、不诊断；先接住人，再给求助渠道。模型可能误判，提醒对照原话。
struct SafetyCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "heart.circle.fill").font(.system(size: 20)).foregroundStyle(Theme.danger)
                VStack(alignment: .leading, spacing: 1) {
                    Text("TA 可能撑得很辛苦").font(.system(size: 14, weight: .semibold))
                    Text("AI 判断不一定准，请对照原话").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                step("1", "先接住 TA：温和地问一句「你现在安全吗？」")
                step("2", "陪着 TA，认真听，不急着讲道理")
                step("3", "如果 TA 提到具体打算、正在伤害自己或突然联系不上，马上联系 TA 身边的人，或拨打 120 / 110")
            }
            HStack(spacing: 8) {
                Hotline(name: "心理援助热线", number: "12356")
                Hotline(name: "希望24热线", number: "400-161-9995")
            }
        }
        .padding(12)
        .card(tint: Theme.danger)
    }

    private func step(_ n: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(n).font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                .frame(width: 15, height: 15).background(Circle().fill(Theme.danger.opacity(0.85)))
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct Hotline: View {
    let name: String
    let number: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(number).font(.system(size: 13, weight: .semibold, design: .rounded)).textSelection(.enabled)
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

// MARK: - History, notices, onboarding, footer

struct HistoryView: View {
    let reports: [EmotionReport]
    @Binding var selectedID: UUID?
    let shownID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(symbol: "clock.arrow.circlepath", title: "最近") {
                if selectedID != nil {
                    Button("回到最新") { selectedID = nil }.buttonStyle(PillButtonStyle())
                }
            }
            VStack(spacing: 2) {
                ForEach(reports.prefix(10)) { report in
                    HistoryRow(report: report, selected: report.id == shownID) { selectedID = report.id }
                }
            }
        }
    }
}

struct HistoryRow: View {
    let report: EmotionReport
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle().fill(Theme.color(for: report.emotion)).frame(width: 7, height: 7)
                Text(report.emotion).font(.system(size: 11.5, weight: .medium)).frame(width: 30, alignment: .leading)
                Text(report.message.text).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                if report.activeFlags().contains(where: \.isSerious) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(Theme.danger)
                }
                Text(report.date.formatted(date: .omitted, time: .shortened)).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(selected ? 0.08 : (hovering ? 0.04 : 0))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct Notices: View {
    @ObservedObject var monitor: Monitor

    var body: some View {
        if monitor.status == .needsPermission {
            Notice(symbol: "lock.shield", tint: .orange, title: "需要屏幕录制权限",
                   text: "在「系统设置 → 隐私与安全性 → 录屏与系统录音」里打开 EmoLens，然后重新打开应用。") {
                Button("打开系统设置") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
                .buttonStyle(PillButtonStyle(tint: .orange))
            }
        } else if case .failed(let message) = monitor.status {
            Notice(symbol: "exclamationmark.triangle", tint: .orange, title: "截图出错了", text: message) { EmptyView() }
        }
        if monitor.startingOllama {
            Notice(symbol: "hourglass", tint: .blue, title: "正在启动本地模型",
                   text: "第一次启动 Ollama 要几秒，之后就一直在后台跑了。") { EmptyView() }
        } else if monitor.ollamaStatus == .missingBinary {
            Notice(symbol: "shippingbox", tint: .orange, title: "没找到 ollama 命令",
                   text: "装好 Ollama 就能自动启动本地模型。也可以在设置里换成云端模型——但那样聊天内容会发送给服务商。") {
                Button("去下载 Ollama") { NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!) }
                    .buttonStyle(PillButtonStyle(tint: .orange))
            }
        } else if case .failed(let message) = monitor.ollamaStatus {
            Notice(symbol: "exclamationmark.triangle", tint: .orange, title: "本地模型没能启动", text: message) { EmptyView() }
        }
        if let seconds = monitor.pendingVoice {
            Notice(symbol: "waveform", tint: .blue, title: seconds > 0 ? "对方发来一条 \(seconds) 秒的语音" : "对方发来一条语音",
                   text: "EmoLens 听不到语音内容。在微信里把它转成文字（右键语音 →「转文字」；新版微信也可以在设置里打开语音自动转文字），转好后会自动接着分析。") { EmptyView() }
        }
        if let error = monitor.analysisError {
            Notice(symbol: "bolt.horizontal.circle", tint: .orange, title: "这条消息没分析成功", text: error) {
                if monitor.canRetry {
                    Button("重试") { monitor.retry() }.buttonStyle(PillButtonStyle(tint: .orange))
                }
            }
        }
    }
}

struct Notice<Action: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let text: String
    @ViewBuilder var action: Action

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                action
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .card(tint: tint)
    }
}

/// 还没有结果时：告诉用户在等什么，以及三步准备是否就绪。
struct Onboarding: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var settings: AppSettings
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Theme.brand.opacity(0.18)).frame(width: 64, height: 64)
                Image(systemName: "bubble.left.and.text.bubble.right.fill")
                    .font(.system(size: 26)).foregroundStyle(Theme.brand)
            }
            .padding(.top, 10)
            VStack(spacing: 4) {
                Text(monitor.analyzing ? "正在读 TA 的消息…" : "等 TA 发来新消息").font(.system(size: 15, weight: .semibold))
                Text("打开微信里的一个聊天，对方一发消息，这里就会告诉你 TA 的情绪、潜台词和怎么回。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                check("屏幕录制权限", done: monitor.status != .needsPermission && monitor.preview != nil,
                      hint: monitor.status == .needsPermission ? "未授权" : "检查中")
                Hairline().padding(.leading, 34)
                check("找到聊天窗口", done: monitor.windowFound, hint: monitor.windowHint)
                Hairline().padding(.leading, 34)
                check("框出聊天区域", done: settings.region != CGRect(x: 0, y: 0, width: 1, height: 1),
                      hint: "建议设置")
            }
            .card()
            Button("打开设置", action: openSettings).buttonStyle(PillButtonStyle(filled: true))
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 6)
    }

    private func check(_ title: String, done: Bool, hint: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 15)).foregroundStyle(done ? Color.green : Color.secondary)
            Text(title).font(.system(size: 12.5))
            Spacer()
            if !done { Text(hint).font(.system(size: 11)).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }
}

struct PrivacyFooter: View {
    /// 用云端模型时的服务名；本地为 nil。
    var cloud: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let cloud {
                Image(systemName: "icloud.and.arrow.up").font(.system(size: 9)).foregroundStyle(.orange)
                Text("云端分析：消息会发送给 \(cloud) · 结果仅供参考").foregroundStyle(.orange)
            } else {
                Image(systemName: "lock.fill").font(.system(size: 9))
                Text("只在本机分析，不上传聊天内容 · 结果仅供参考")
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

/// 聊天气泡形状，带一个小尖角。
struct BubbleShape: Shape {
    let tailOnLeft: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: 8, style: .continuous)
        let y = min(rect.minY + 14, rect.midY)
        if tailOnLeft {
            path.move(to: CGPoint(x: rect.minX, y: y - 5))
            path.addLine(to: CGPoint(x: rect.minX - 5, y: y))
            path.addLine(to: CGPoint(x: rect.minX, y: y + 5))
        } else {
            path.move(to: CGPoint(x: rect.maxX, y: y - 5))
            path.addLine(to: CGPoint(x: rect.maxX + 5, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y + 5))
        }
        path.closeSubpath()
        return path
    }
}
