import Foundation

enum CLIError: LocalizedError {
    case notFound
    case failed(Int32, String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "The mmco CLI was not found. Run install.sh, or set \"cli\" in \(Paths.config.path)."
        case .failed(let code, let tail):
            return "mmco exited with status \(code).\n\n\(tail)"
        }
    }
}

enum CLIRunner {
    static func loadConfig() -> Config? {
        guard let data = try? Data(contentsOf: Paths.config) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data)
    }

    /// Short CLI actions the app waits for (`--config`, `--log`). Checkout runs go through
    /// RunLauncher instead, detached.
    static func run(arguments: [String], completion: @escaping (Result<Void, Error>) -> Void) {
        guard let cli = Paths.cli(from: loadConfig()) else { return completion(.failure(CLIError.notFound)) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.terminationHandler = { p in
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if p.terminationStatus == 0 {
                completion(.success(()))
            } else {
                let tail = output.split(separator: "\n").suffix(8).joined(separator: "\n")
                completion(.failure(CLIError.failed(p.terminationStatus, tail)))
            }
        }
        do { try process.run() } catch { completion(.failure(error)) }
    }

    /// Synchronous helper for the short read-only CLI calls (`--default-pre`, `--default-post`).
    static func capture(_ arguments: [String], config: Config?) -> String {
        guard let cli = Paths.cli(from: config) else { return "" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
}
