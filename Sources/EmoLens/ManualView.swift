import AppKit
import EmoLensCore
import SwiftUI

/// 手动模式：把聊天记录粘贴进来分析，不用截屏，也不用开着微信。
struct ManualView: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var settings: AppSettings
    @Binding var transcript: String
    /// 预览渲染时用普通文字代替输入框（系统输入框画不出来）。
    var editable = true

    private var parsed: ChatTranscript.Parsed { ChatTranscript.parse(transcript) }
    private var latest: ChatMessage? { parsed.messages.last { $0.speaker == .them } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(symbol: "doc.on.clipboard", title: "粘贴聊天记录") {
                if !parsed.messages.isEmpty {
                    Text("\(parsed.messages.count) 条 · 对方 \(parsed.messages.filter { $0.speaker == .them }.count) 条")
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            }
            editor
            if transcript.isEmpty {
                Text("在微信里选中几条消息复制，粘贴到这里。支持「小美：内容」和「小美 12:30」换行两种格式；认不出名字的行会算作对方说的。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if latest == nil {
                Text("没找到对方发的消息。如果整段都是你自己说的，就没什么可分析的。")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            controls
        }
        .padding(12)
        .card()
    }

    @ViewBuilder private var editor: some View {
        if editable {
            TextEditor(text: $transcript)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .frame(height: 120)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        } else {
            Text(transcript.isEmpty ? " " : transcript)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            Button("粘贴") {
                transcript = NSPasteboard.general.string(forType: .string) ?? transcript
            }
            .buttonStyle(PillButtonStyle())
            if !transcript.isEmpty {
                Button("清空") { transcript = "" }.buttonStyle(PillButtonStyle(tint: .secondary))
            }
            if parsed.names.count > 1 {
                Picker("", selection: Binding(get: { monitor.manualContact ?? parsed.names[0] },
                                              set: { monitor.manualContact = $0 })) {
                    ForEach(parsed.names, id: \.self) { Text("对方：\($0)").tag($0) }
                }
                .labelsHidden().frame(maxWidth: 130)
            }
            Spacer()
            Button(monitor.analyzing ? "分析中…" : "分析这段") {
                monitor.manualContact = monitor.manualContact ?? parsed.names.first
                monitor.analyzeManual(transcript)
            }
            .buttonStyle(PillButtonStyle(filled: true))
            .disabled(latest == nil || monitor.analyzing)
        }
    }
}

/// 顶部的「实时 / 手动」切换。
struct ModeSwitch: View {
    @ObservedObject var monitor: Monitor
    @Binding var manual: Bool

    var body: some View {
        HStack(spacing: 4) {
            tab("实时看微信", symbol: "eye", selected: !manual) {
                manual = false
                monitor.start()
            }
            tab("手动粘贴", symbol: "doc.on.clipboard", selected: manual) {
                manual = true
                monitor.pause()   // 手动模式不截屏
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private func tab(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
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
