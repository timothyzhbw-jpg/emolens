@testable import EmoLensCore
import XCTest

final class ContactMemoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func report(_ text: String, _ emotion: String, flags: [String: Double] = [:], consistency: String? = nil,
                        daysAgo: Double = 0) -> EmotionReport {
        var r = EmotionReport(message: ChatMessage(speaker: .them, text: text, top: 0), emotion: emotion, intensity: 2,
                              flags: flags, consistency: consistency, engine: "t", latencyMs: 1)
        r.date = now.addingTimeInterval(-daysAgo * 86_400)
        return r
    }

    func testEmptyMemoryHasNoSummary() {
        XCTAssertNil(ContactMemory(name: "小美").promptSummary(now: now))
        XCTAssertTrue(ContactMemory(name: "小美").isEmpty)
    }

    func testSummaryCombinesNotesTrendsAndRecentEntries() throws {
        var memory = ContactMemory(name: "小美")
        memory.notes = [.init(text: "最近在找工作", source: .user), .init(text: "下周三面试", source: .ai)]
        memory.record(report("没事，你开心就好", "委屈", flags: ["sarcasm": 1, "angry_at_me": 1], consistency: "反话", daysAgo: 1))
        memory.record(report("哦", "冷淡", flags: ["perfunctory": 1, "angry_at_me": 1], daysAgo: 2))
        memory.record(report("我拿到 offer 了", "开心", daysAgo: 30))   // 超过 7 天，不计入走势
        let summary = try XCTUnwrap(memory.promptSummary(now: now))
        XCTAssertTrue(summary.hasPrefix("关于对方的记忆"))
        XCTAssertTrue(summary.contains("最近在找工作；下周三面试"))
        XCTAssertTrue(summary.contains("委屈 1 次"))
        XCTAssertFalse(summary.contains("开心 1 次"), "30 天前的不算最近 7 天")
        XCTAssertTrue(summary.contains("在生我的气 2 次"), "出现两次以上的信号才算反复出现")
        XCTAssertFalse(summary.contains("反话 / 阴阳怪气 1 次"))
        XCTAssertTrue(summary.contains("「没事，你开心就好」→ 委屈，反话"))
    }

    func testEntriesAreCappedAndExcerpted() {
        var memory = ContactMemory(name: "a")
        for i in 0..<(ContactMemory.maxEntries + 5) { memory.record(report("第\(i)条" + String(repeating: "长", count: 60), "平静")) }
        XCTAssertEqual(memory.entries.count, ContactMemory.maxEntries)
        XCTAssertTrue(memory.entries.first!.excerpt.hasPrefix("第5条"))
        XCTAssertEqual(memory.entries.last!.excerpt.count, ContactMemory.excerptLength)
    }

    func testCountsAreSortedByFrequency() {
        var memory = ContactMemory(name: "a")
        ["冷淡", "委屈", "冷淡", "冷淡", "委屈", "开心"].forEach { memory.record(report("x", $0)) }
        let (emotions, _) = memory.counts(days: 7, now: now)
        XCTAssertEqual(emotions.map(\.0), ["冷淡", "委屈", "开心"])
        XCTAssertEqual(emotions.map(\.1), [3, 2, 1])
    }

    func testStorePersistsAndForgets() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "emolens-test-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ContactMemoryStore(fileURL: url)
        store.update("小美") { $0.relationship = "恋人"; $0.notes.append(.init(text: "怕冷", source: .user)) }
        store.record(report("嗯", "冷淡"), for: " 小美 ")   // 空格不同也是同一个人
        store.update("王经理") { $0.relationship = "同事" }

        let reloaded = ContactMemoryStore(fileURL: url)
        XCTAssertEqual(reloaded.memory(for: "小美").relationship, "恋人")
        XCTAssertEqual(reloaded.memory(for: "小美").notes.map(\.text), ["怕冷"])
        XCTAssertEqual(reloaded.memory(for: "小美").entries.count, 1)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600, "记忆文件只有自己能读")

        reloaded.forget("小美")
        XCTAssertTrue(ContactMemoryStore(fileURL: url).memory(for: "小美").isEmpty)
        XCTAssertEqual(ContactMemoryStore(fileURL: url).memory(for: "王经理").relationship, "同事")
        reloaded.forgetAll()
        XCTAssertTrue(ContactMemoryStore(fileURL: url).contacts.isEmpty)
    }

    func testEmptyContactsAreNotStored() {
        let url = FileManager.default.temporaryDirectory.appending(path: "emolens-test-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ContactMemoryStore(fileURL: url)
        store.update("路人") { _ in }
        XCTAssertTrue(store.contacts.isEmpty)
    }

    func testStateIncludesMemoryBeforeChat() {
        let latest = ChatMessage(speaker: .them, text: "嗯", top: 0)
        let text = ChatState.render(context: [], latest: latest, relationship: "恋人", memory: "关于对方的记忆：\n- 最近在找工作")
        XCTAssertTrue(text.hasPrefix("双方关系：恋人\n关于对方的记忆：\n- 最近在找工作\n\n以下是微信聊天记录"))
    }

    func testMemoryNoteIsParsedAndBlankIgnored() throws {
        let latest = ChatMessage(speaker: .them, text: "下周三面试，好紧张", top: 0)
        let withNote = try LLMAnalyzer.report(from: #"{"emotion": "焦虑", "memory_note": "下周三有面试"}"#, message: latest, engine: "t", latencyMs: 1)
        XCTAssertEqual(withNote.memoryNote, "下周三有面试")
        let blank = try LLMAnalyzer.report(from: #"{"emotion": "平静", "memory_note": "  "}"#, message: latest, engine: "t", latencyMs: 1)
        XCTAssertNil(blank.memoryNote)
    }
}

final class MemoryHintsTests: XCTestCase {
    private func report(_ text: String, note: String? = nil) -> EmotionReport {
        EmotionReport(message: ChatMessage(speaker: .them, text: text, top: 0), emotion: "平静", intensity: 0,
                      flags: [:], memoryNote: note, engine: "t", latencyMs: 0)
    }

    func testSuggestsWhenModelMissedAKeyDate() {
        XCTAssertEqual(MemoryHints.apply(to: report("对了，下周三是我生日，你可别忘了哦")).memoryNote, "下周三是我生日，你可别忘了哦")
    }

    func testKeepsTheModelsOwnNote() {
        XCTAssertEqual(MemoryHints.apply(to: report("下周三面试", note: "下周三要面试")).memoryNote, "下周三要面试")
    }

    func testIgnoresOrdinaryMessages() {
        XCTAssertNil(MemoryHints.apply(to: report("哈哈好的，明天见")).memoryNote)
        XCTAssertNil(MemoryHints.apply(to: report("嗯")).memoryNote)
    }
}

final class ContactNameDetectorTests: XCTestCase {
    private func line(_ text: String, height: CGFloat, y: CGFloat = 0.3) -> OCRLine {
        OCRLine(text: text, box: CGRect(x: 0.1, y: y, width: 0.3, height: height))
    }

    func testPicksTheLineClosestToTheChat() {
        // 实测：窗口标题栏连同左上角按钮被认成「••• EmoLens 演示朋天」，框还更大
        let titleBar = line("••• EmoLens 演示朋天", height: 0.30, y: 0.05)
        let name = line("小美", height: 0.16, y: 0.55)
        XCTAssertEqual(ContactNameDetector.detect([titleBar, name]), "小美")
    }

    func testSkipsTheWindowsOwnTitleAndButtonNoise() {
        XCTAssertEqual(ContactNameDetector.detect([line("小美", height: 0.2, y: 0.2), line("微信", height: 0.2, y: 0.6)],
                                                  excluding: ["微信"]), "小美")
        XCTAssertEqual(ContactNameDetector.detect([line("••• 小美", height: 0.2)]), "小美")
        XCTAssertNil(ContactNameDetector.detect([line("•••", height: 0.2)]))
    }

    func testStripsGroupMemberCount() {
        XCTAssertEqual(ContactNameDetector.detect([line("相亲相爱一家人(12)", height: 0.2)]), "相亲相爱一家人")
        XCTAssertEqual(ContactNameDetector.detect([line("项目组（8）", height: 0.2)]), "项目组")
    }

    func testIgnoresTimesIconsAndNoise() {
        XCTAssertNil(ContactNameDetector.detect([line("12:30", height: 0.2), line("…", height: 0.2), line("微信", height: 0.2)]))
        XCTAssertNil(ContactNameDetector.detect([OCRLine(text: "小美", box: .zero, confidence: 0.1)]))
        XCTAssertNil(ContactNameDetector.detect([line(String(repeating: "长", count: 31), height: 0.2)]))
    }
}
