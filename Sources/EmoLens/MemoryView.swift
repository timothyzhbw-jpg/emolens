import AppKit
import EmoLensCore
import SwiftUI

/// 某个聊天对象的记忆：名字、关系、记下的事、情绪走势、最近记录。
struct MemoryView: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var settings: AppSettings
    let contact: String
    /// 预览渲染时关掉滚动视图（它由 AppKit 绘制，渲染不出来）。
    var scrolls = true
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var confirmForget = false

    private var memory: ContactMemory { _ = monitor.memoryVersion; return monitor.contactMemory(contact) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline()
            if scrolls {
                ScrollView { content.padding(18) }
            } else {
                content.padding(18)
            }
            Hairline()
            footer
        }
        .frame(width: 420, height: scrolls ? 600 : nil)
        .confirmationDialog("清空关于「\(contact)」的全部记忆？", isPresented: $confirmForget) {
            Button("清空", role: .destructive) { monitor.forget(contact); dismiss() }
        } message: {
            Text("记下的事、关系设置和情绪记录都会删除，不能恢复。")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Theme.brand.opacity(0.18)).frame(width: 36, height: 36)
                Image(systemName: "brain.head.profile").font(.system(size: 16)).foregroundStyle(Theme.brand)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("关于「\(contact)」的记忆").font(.system(size: 15, weight: .semibold))
                Text("分析时会作为背景参考，让判断更贴合你们的情况").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(18)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(symbol: "person.2", title: "你们的关系")
                RelationshipBar(selection: Binding(
                    get: { memory.relationship ?? settings.relationship },
                    set: { value in monitor.editMemory(contact) { $0.relationship = value } }))
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(symbol: "note.text", title: "记下的事") {
                    Text("\(memory.notes.count) 条").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                if memory.notes.isEmpty {
                    Text("还没有。比如「她最近在找工作」「不喜欢被说胖」「下周三生日」。分析时如果 TA 透露了值得记的事，面板也会问你要不要记。")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(memory.notes.reversed()) { note in NoteRow(note: note) { delete(note) } }
                HStack(spacing: 6) {
                    TextField("记一件关于 TA 的事", text: $draft).textFieldStyle(.roundedBorder).onSubmit(add)
                    Button("记下", action: add).buttonStyle(PillButtonStyle(filled: true)).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            trends

            if !memory.entries.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionTitle(symbol: "clock.arrow.circlepath", title: "最近的分析")
                    ForEach(Array(memory.entries.suffix(8).reversed().enumerated()), id: \.offset) { _, entry in EntryRow(entry: entry) }
                }
            }
        }
    }

    @ViewBuilder private var trends: some View {
        let (emotions, signals) = memory.counts(days: 14)
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(symbol: "chart.bar", title: "最近 14 天")
            if emotions.isEmpty {
                Text("还没有记录。开着 EmoLens 聊天，分析结果会自动累计在这里。").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                let total = max(1, emotions.map(\.1).reduce(0, +))
                ForEach(emotions.prefix(5), id: \.0) { emotion, count in
                    HStack(spacing: 8) {
                        Text("\(Theme.emoji(for: emotion)) \(emotion)").font(.system(size: 12)).frame(width: 70, alignment: .leading)
                        GeometryReader { geo in
                            Capsule().fill(Theme.color(for: emotion).opacity(0.75))
                                .frame(width: max(6, geo.size.width * CGFloat(count) / CGFloat(total)))
                        }
                        .frame(height: 8)
                        Text("\(count)").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
                    }
                }
                if !signals.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(signals.prefix(6), id: \.0) { flag, count in
                            Text("\(flag.title) × \(count)").font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .foregroundStyle(flag.tint).background(Capsule().fill(flag.tint.opacity(0.12)))
                        }
                    }
                }
            }
        }
        .padding(12)
        .card()
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(.tertiary).padding(.top, 2)
            Text("只存在本机（~/Library/Application Support/EmoLens）。\(settings.cloudProviderName.map { "用云端模型时，记忆摘要会随分析一起发送给 \($0)。" } ?? "")")
                .font(.system(size: 10.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("清空 TA 的记忆", role: .destructive) { confirmForget = true }
                .buttonStyle(PillButtonStyle(tint: Theme.danger))
                .disabled(memory.isEmpty)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private func add() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        monitor.remember(text, for: contact, source: .user)
        draft = ""
    }

    private func delete(_ note: ContactMemory.Note) {
        monitor.editMemory(contact) { $0.notes.removeAll { $0.id == note.id } }
    }
}

struct NoteRow: View {
    let note: ContactMemory.Note
    let delete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: note.source == .ai ? "sparkles" : "pencil")
                .font(.system(size: 10)).foregroundStyle(note.source == .ai ? Color.purple : Color.secondary)
                .help(note.source == .ai ? "AI 建议、你确认记下的" : "你手动记下的")
            Text(note.text).font(.system(size: 12.5)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Text(note.date.formatted(.dateTime.month().day())).font(.system(size: 10)).foregroundStyle(.tertiary)
            Button(action: delete) { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                .buttonStyle(.plain).opacity(hovering ? 1 : 0.35).help("删除")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hovering ? 0.06 : 0.035)))
        .onHover { hovering = $0 }
    }
}

struct EntryRow: View {
    let entry: ContactMemory.Entry

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Theme.color(for: entry.emotion)).frame(width: 7, height: 7)
            Text(entry.emotion).font(.system(size: 11.5, weight: .medium)).frame(width: 30, alignment: .leading)
            Text(entry.excerpt).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            Text(entry.date.formatted(.dateTime.month().day().hour().minute())).font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }
}

/// 面板上「正在和谁聊」的条：显示对方名字和记了几件事，点一下打开记忆。
struct ContactBar: View {
    @ObservedObject var monitor: Monitor
    let openMemory: () -> Void
    @State private var naming = false
    @State private var draft = ""

    var body: some View {
        let contact = monitor.currentContact
        let notes = contact.map { name -> Int in _ = monitor.memoryVersion; return monitor.contactMemory(name).notes.count } ?? 0
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle").font(.system(size: 13)).foregroundStyle(.secondary)
            if naming {
                TextField("对方的名字", text: $draft).textFieldStyle(.roundedBorder).frame(maxWidth: 160)
                    .onSubmit(commit)
                Button("好", action: commit).buttonStyle(PillButtonStyle(filled: true))
            } else if let contact {
                Text(contact).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Button { draft = contact; naming = true } label: { Image(systemName: "pencil").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundStyle(.tertiary).help("名字认错了？点这里改")
                Spacer(minLength: 4)
                Button(action: openMemory) {
                    Label(notes > 0 ? "记忆 · \(notes)" : "记忆", systemImage: "brain.head.profile")
                }
                .buttonStyle(PillButtonStyle(tint: .purple))
            } else {
                Text("没认出正在和谁聊").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("设置名字") { draft = ""; naming = true }.buttonStyle(PillButtonStyle(tint: .purple))
            }
        }
    }

    private func commit() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        monitor.manualContact = name.isEmpty ? nil : name
        naming = false
    }
}

/// 分析结果里模型建议记住的事：用户点「记住」才写进记忆。
struct MemorySuggestion: View {
    let note: String
    let contact: String?
    let remember: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles").font(.system(size: 12)).foregroundStyle(.purple).padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                Text(contact.map { "要记住关于「\($0)」的这件事吗？" } ?? "这件事值得记住（先设置对方名字才能记）")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text(note).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Button("记住", action: remember).buttonStyle(PillButtonStyle(tint: .purple, filled: true)).disabled(contact == nil)
                    Button("不用", action: dismiss).buttonStyle(PillButtonStyle(tint: .secondary))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .card(tint: .purple)
    }
}
