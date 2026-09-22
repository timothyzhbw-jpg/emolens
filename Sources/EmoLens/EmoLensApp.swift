import AppKit
import SwiftUI

@main
@MainActor
enum EmoLensMain {
    static let delegate = AppDelegate()

    static func main() {
        // EmoLens --render-previews <目录>：用示例数据把界面画成 PNG（开发 / README 截图用），不截屏。
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-previews"), i + 1 < args.count {
            _ = NSApplication.shared
            do {
                try PreviewRenderer.renderAll(to: URL(fileURLWithPath: args[i + 1]))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
                exit(1)
            }
        }
        // EmoLens --eval 输入.jsonl 输出.jsonl：批量分析，用来跑评测集。
        if let i = args.firstIndex(of: "--eval"), i + 2 < args.count {
            _ = NSApplication.shared
            let semaphore = DispatchSemaphore(value: 0)
            // 必须脱离主线程：main() 是 @MainActor，普通 Task 会继承它，和下面的 wait() 互相等待造成死锁。
            Task.detached {
                do { try await EvalRunner.run(input: URL(fileURLWithPath: args[i + 1]), output: URL(fileURLWithPath: args[i + 2])) }
                catch { FileHandle.standardError.write(Data("eval failed: \(error)\n".utf8)) }
                semaphore.signal()
            }
            semaphore.wait()
            exit(0)
        }
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let settings = AppSettings()
    private lazy var monitor = Monitor(settings: settings)
    private var panel: NSPanel?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMenu()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 372, height: 700),
                            styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "EmoLens 情绪透镜"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.styleMask.insert(.fullSizeContentView)
        panel.isMovableByWindowBackground = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        // .statusBar 而不是 .floating：普通浮动层级不会出现在别的应用的全屏空间之上。
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        // 跟着你走：切到别的桌面空间、或别的应用全屏时，面板都要跟过去。
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.sharingType = .none   // 自己的面板不出现在任何截图 / 共享屏幕里
        panel.contentView = Self.frosted(NSHostingView(rootView: PanelView(monitor: monitor, settings: settings)))
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - 392, y: screen.maxY - 720))
        }
        panel.delegate = self
        self.panel = panel
        setUpStatusItem()
        showPanel()
        monitor.start()
    }

    /// 把面板显示出来并置前。被隐藏过（⌘H）也能恢复，所以不会出现「应用在跑但看不到窗口」。
    @objc func showPanel() {
        guard let panel else { return }
        NSApp.unhide(nil)
        // 每次显示都重新声明一遍：切换空间或全屏后，这些行为偶尔会失效。
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.level = .statusBar
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 再次打开应用（比如点 Dock 图标）时，把面板叫回来而不是什么都不做。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showPanel()
        return true
    }

    /// 菜单栏图标：面板被关掉或隐藏后，从这里随时叫回来。
    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "eye.fill", accessibilityDescription: "情绪透镜")
        let menu = NSMenu()
        menu.addItem(withTitle: "显示面板", action: #selector(showPanel), keyEquivalent: "").target = self
        menu.addItem(withTitle: "暂停 / 继续监控", action: #selector(toggleMonitoring), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 EmoLens", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func toggleMonitoring() {
        monitor.isRunning ? monitor.pause() : monitor.start()
    }

    /// 毛玻璃底：半透明，能隐约看到后面的窗口。
    private static func frosted(_ content: NSView) -> NSView {
        let effect = NSVisualEffectView()
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .active
        content.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            content.topAnchor.constraint(equalTo: effect.topAnchor),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        return effect
    }

    // 主面板是 NSPanel，AppKit 判断「最后一个窗口」时不算它：设置页一关就会误退出。
    // 所以只在关掉主面板时退出。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSPanel) === panel { NSApp.terminate(nil) }
    }

    private static func makeMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "隐藏 EmoLens", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 EmoLens", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }
}
