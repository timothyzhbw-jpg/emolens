@testable import EmoLensCore
import XCTest

final class OllamaLauncherTests: XCTestCase {
    private final class Spy: @unchecked Sendable {
        var launched: [String] = []
        var healthy = false
        var healthyAfter: Int?
        var checks = 0
    }

    private func launcher(_ spy: Spy, url: String = "http://127.0.0.1:11434", paths: [String] = ["/opt/homebrew/bin/ollama"],
                          exists: Set<String> = ["/opt/homebrew/bin/ollama"], launchFails: Bool = false) -> OllamaLauncher {
        OllamaLauncher(
            baseURL: URL(string: url)!,
            paths: paths,
            fileExists: { exists.contains($0) },
            isHealthy: { _ in
                spy.checks += 1
                if let after = spy.healthyAfter, spy.checks > after { return true }
                return spy.healthy
            },
            launch: { binary in
                spy.launched.append(binary)
                if launchFails { throw CocoaError(.fileNoSuchFile) }
            },
            wait: { _ in })
    }

    func testAlreadyRunningDoesNotLaunch() async {
        let spy = Spy(); spy.healthy = true
        let status = await launcher(spy).ensureRunning()
        XCTAssertEqual(status, .running)
        XCTAssertTrue(spy.launched.isEmpty, "已经在跑就不该再启动一个")
    }

    func testStartsAndWaitsUntilReady() async {
        let spy = Spy(); spy.healthyAfter = 3   // 第 4 次检查才就绪
        let status = await launcher(spy).ensureRunning()
        XCTAssertEqual(status, .started)
        XCTAssertEqual(spy.launched, ["/opt/homebrew/bin/ollama"])
    }

    func testMissingBinaryIsReportedNotLaunched() async {
        let spy = Spy()
        let status = await launcher(spy, exists: []).ensureRunning()
        XCTAssertEqual(status, .missingBinary)
        XCTAssertTrue(spy.launched.isEmpty)
    }

    func testRemoteHostIsLeftAlone() async {
        let spy = Spy()
        let status = await launcher(spy, url: "http://192.168.1.20:11434").ensureRunning()
        XCTAssertEqual(status, .notLocal, "远程地址上的服务不归我们管")
        XCTAssertTrue(spy.launched.isEmpty)
    }

    func testTimeoutIsReported() async {
        let spy = Spy()
        let status = await launcher(spy).ensureRunning(timeout: .seconds(2))
        guard case .failed = status else { return XCTFail("应当返回失败：\(status)") }
        XCTAssertFalse(status.isUsable)
    }

    func testLaunchFailureIsReported() async {
        let spy = Spy()
        let status = await launcher(spy, launchFails: true).ensureRunning()
        guard case .failed = status else { return XCTFail("应当返回失败：\(status)") }
    }

    func testPicksTheFirstInstalledPath() {
        let spy = Spy()
        let found = launcher(spy, paths: ["/nope", "/usr/local/bin/ollama", "/opt/homebrew/bin/ollama"],
                             exists: ["/usr/local/bin/ollama", "/opt/homebrew/bin/ollama"]).binary
        XCTAssertEqual(found, "/usr/local/bin/ollama")
    }
}
