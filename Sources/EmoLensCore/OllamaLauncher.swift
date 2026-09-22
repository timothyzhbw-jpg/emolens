import Foundation

/// 本地模型没在跑时，自动把 `ollama serve` 拉起来。
/// 只对本机地址生效；无论如何都不会自动改用云端模型——聊天内容要不要发出去，只能由用户自己决定。
public struct OllamaLauncher: Sendable {
    public enum Status: Equatable, Sendable {
        case running
        case started
        case notLocal
        case missingBinary
        case failed(String)

        public var isUsable: Bool { self == .running || self == .started }
    }

    /// Homebrew、官方安装包和 Intel Mac 的常见位置。
    public static let searchPaths = ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama", "/usr/bin/ollama",
                                     "/Applications/Ollama.app/Contents/Resources/ollama"]

    public var baseURL: URL
    var paths: [String]
    var fileExists: @Sendable (String) -> Bool
    var isHealthy: @Sendable (URL) async -> Bool
    var launch: @Sendable (String) throws -> Void
    var wait: @Sendable (Duration) async -> Void

    public init(baseURL: URL,
                paths: [String] = OllamaLauncher.searchPaths,
                fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
                isHealthy: @escaping @Sendable (URL) async -> Bool = OllamaLauncher.ping,
                launch: @escaping @Sendable (String) throws -> Void = OllamaLauncher.spawn,
                wait: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.baseURL = baseURL
        self.paths = paths
        self.fileExists = fileExists
        self.isHealthy = isHealthy
        self.launch = launch
        self.wait = wait
    }

    public var binary: String? { paths.first(where: fileExists) }

    /// 只在本机地址上自动启动：远程地址不是我们能管的。
    public var isLocal: Bool { ["127.0.0.1", "localhost", "::1"].contains(baseURL.host() ?? "") }

    /// 已经在跑就直接返回；否则启动并等它就绪。
    public func ensureRunning(timeout: Duration = .seconds(30)) async -> Status {
        if await isHealthy(baseURL) { return .running }
        guard isLocal else { return .notLocal }
        guard let binary else { return .missingBinary }
        do {
            try launch(binary)
        } catch {
            return .failed(error.localizedDescription)
        }
        var waited = Duration.zero
        let step = Duration.milliseconds(500)
        while waited < timeout {
            await wait(step)
            waited += step
            if await isHealthy(baseURL) { return .started }
        }
        return .failed("启动了 ollama serve，但 \(timeout.components.seconds) 秒内没有就绪")
    }

    @Sendable public static func ping(_ baseURL: URL) async -> Bool {
        var request = URLRequest(url: baseURL.appending(path: "api/version"), timeoutInterval: 2)
        request.httpMethod = "GET"
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    @Sendable public static func spawn(_ binary: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["serve"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()   // 不等它结束：EmoLens 退出后 ollama 继续留着，其他程序也能用
    }
}
