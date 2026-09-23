// 仿微信的演示聊天窗口：没有微信、或不想用真实聊天测试时，用它来试 EmoLens。
// 运行：swift run EmoLensDemo（每 DEMO_INTERVAL 秒收到一条新消息，默认 15 秒）
import AppKit
import SwiftUI

struct Line: Identifiable {
    enum Kind {
        case text
        /// 语音：秒数；转文字之后才有 transcript
        case voice(Int)
        /// 表情包：画一个卡通脸，下面配字
        case sticker
    }

    var id = UUID()
    let fromMe: Bool
    let text: String
    var kind = Kind.text
    var transcript: String?
}

let opening = [
    Line(fromMe: true, text: "今晚和同事聚餐，可能晚点回"),
    Line(fromMe: false, text: "哦"),
]

/// 每一步：追加几条消息；或者把最后一条语音「转文字」（模拟在微信里右键 → 转文字）。
enum Step {
    case add([Line])
    case transcribe(String)
}

let script: [Step] = [
    .add([Line(fromMe: false, text: "没关系呀，你工作最重要嘛，我算什么")]),
    .add([Line(fromMe: true, text: "别这样嘛，我十点前一定回来"), Line(fromMe: false, text: "好的🙂")]),
    .add([Line(fromMe: false, text: "", kind: .voice(6))]),
    .transcribe("那你到底几点回来啊，我都等困了"),
    .add([Line(fromMe: true, text: "给你带了你最爱的那家蛋糕"), Line(fromMe: false, text: "哼", kind: .sticker)]),
    .add([Line(fromMe: false, text: "对了，下周三是我生日，你可别忘了哦😘")]),
    .add([Line(fromMe: false, text: "你要是真在乎我，就把手机密码告诉我，不然就是心里有鬼")]),
]

@MainActor
final class Conversation: ObservableObject {
    @Published var lines = opening
    private var step = 0

    func advance() {
        guard step < script.count else { return }
        switch script[step] {
        case .add(let new):
            lines += new
        case .transcribe(let text):
            if let index = lines.lastIndex(where: { if case .voice = $0.kind { true } else { false } }) {
                lines[index].transcript = text
            }
        }
        step += 1
    }
}

struct ChatView: View {
    @ObservedObject var conversation: Conversation

    var body: some View {
        VStack(spacing: 0) {
            Text("小美").font(.system(size: 15, weight: .medium)).padding(.vertical, 12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 14) {
                        Text("昨天 21:05").font(.system(size: 12)).foregroundStyle(.secondary)
                        ForEach(conversation.lines) { Bubble(line: $0).id($0.id) }
                    }
                    .padding(16)
                }
                .onChange(of: conversation.lines.count) {
                    if let last = conversation.lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .frame(width: 520, height: 640)
        .background(Color(red: 0.93, green: 0.93, blue: 0.93))
    }
}

struct Bubble: View {
    let line: Line

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if line.fromMe { Spacer(minLength: 60) } else { avatar(.orange) }
            VStack(alignment: line.fromMe ? .trailing : .leading, spacing: 4) {
                content
                if let transcript = line.transcript {
                    // 转文字的结果：贴在语音下面的浅色框
                    Text(transcript)
                        .font(.system(size: 14))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(Color.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                }
            }
            if line.fromMe { avatar(.blue) } else { Spacer(minLength: 60) }
        }
    }

    @ViewBuilder private var content: some View {
        let fill = line.fromMe ? Color(red: 0.58, green: 0.93, blue: 0.41) : Color.white
        switch line.kind {
        case .text:
            Text(line.text)
                .font(.system(size: 14))
                .foregroundStyle(.black)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(fill, in: RoundedRectangle(cornerRadius: 5))
        case .voice(let seconds):
            HStack(spacing: 6) {
                Image(systemName: "wave.3.right").font(.system(size: 14))
                Text("\(seconds)\"").font(.system(size: 14))
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(width: 70 + CGFloat(seconds) * 3, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: 5))
        case .sticker:
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(Color(red: 1, green: 0.75, blue: 0.3)).frame(width: 80, height: 80)
                    HStack(spacing: 18) { Circle().fill(.black).frame(width: 9); Circle().fill(.black).frame(width: 9) }.offset(y: -8)
                    Capsule().fill(Color(red: 0.8, green: 0.2, blue: 0.2)).frame(width: 26, height: 7).offset(y: 16)
                }
                Text(line.text).font(.system(size: 22, weight: .black)).foregroundStyle(Color(red: 0.9, green: 0.2, blue: 0.3))
            }
            .frame(width: 110, height: 125)
        }
    }

    private func avatar(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.7)).frame(width: 36, height: 36)
    }
}

@MainActor
final class DemoDelegate: NSObject, NSApplicationDelegate {
    let conversation = Conversation()
    var window: NSWindow?
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 520, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "EmoLens 演示聊天"
        window.contentView = NSHostingView(rootView: ChatView(conversation: conversation))
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate()
        print("EmoLensDemo windowID=\(window.windowNumber)")
        fflush(stdout)
        let interval = Double(ProcessInfo.processInfo.environment["DEMO_INTERVAL"] ?? "") ?? 15
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in self.conversation.advance() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = DemoDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
