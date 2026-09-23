import Foundation

struct Mapping: Identifiable, Codable, Equatable {
    var id = UUID()
    var repo: String
    var path: String
    var preCheckout: String
    var postCheckout: String
    /// Where the folder opens after the checkout: "vscode" (`code <folder>`) or "terminal" (a Terminal.app window).
    var openIn: String = "vscode"

    enum CodingKeys: String, CodingKey { case repo, path, preCheckout, postCheckout, openIn }

    init(repo: String, path: String, preCheckout: String, postCheckout: String, openIn: String = "vscode") {
        self.repo = repo
        self.path = path
        self.preCheckout = preCheckout
        self.postCheckout = postCheckout
        self.openIn = openIn
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repo = try c.decodeIfPresent(String.self, forKey: .repo) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        preCheckout = try c.decodeIfPresent(String.self, forKey: .preCheckout) ?? ""
        postCheckout = try c.decodeIfPresent(String.self, forKey: .postCheckout) ?? ""
        openIn = try c.decodeIfPresent(String.self, forKey: .openIn) ?? "vscode"
    }

    var opensInTerminal: Bool {
        get { openIn == "terminal" }
        set { openIn = newValue ? "terminal" : "vscode" }
    }
}

struct Config: Codable, Equatable {
    var version = 1
    var cli: String?
    var mappings: [Mapping] = []
}

enum Paths {
    static let configDir: URL = {
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        let base = xdg.map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("mmco")
    }()
    static let config = configDir.appendingPathComponent("config.json")

    /// The CLI is the single source of truth. Resolution order: `cli` in the config (written by
    /// install.sh), the copy bundled by build.sh, then the usual PATH locations.
    static func cli(from config: Config?) -> String? {
        var candidates: [String] = []
        if let cli = config?.cli, !cli.isEmpty { candidates.append(cli) }
        if let bundled = Bundle.main.path(forResource: "mmco", ofType: nil) { candidates.append(bundled) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        candidates += ["\(home)/tools/bin/mmco", "/opt/homebrew/bin/mmco", "/usr/local/bin/mmco"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

final class ConfigStore: ObservableObject {
    @Published var config: Config
    @Published var loadError: String?

    init() {
        config = Config()
        load()
    }

    func load() {
        do {
            let data = try Data(contentsOf: Paths.config)
            config = try JSONDecoder().decode(Config.self, from: data)
            loadError = nil
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            config = Config()
        } catch {
            loadError = "Could not read \(Paths.config.path): \(error.localizedDescription)"
        }
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: Paths.configDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(config).write(to: Paths.config, options: .atomic)
        } catch {
            loadError = "Could not write \(Paths.config.path): \(error.localizedDescription)"
        }
    }

    func defaultPre() -> String { CLIRunner.capture(["--default-pre"], config: config) }
    func defaultPost(for path: String) -> String { CLIRunner.capture(["--default-post", path], config: config) }
}
