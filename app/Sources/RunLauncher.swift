import Foundation

/// Per-repo run folder written by the CLI: `~/Library/Application Support/mmco/runs/<slug>/`.
enum RunPaths {
    static let runsDir: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/mmco/runs")

    /// Same rule as `slug()` in bin/mmco: the two sides must agree on the folder name.
    static func slug(_ repo: String) -> String {
        repo.lowercased().unicodeScalars.map { s -> String in
            let ok = (s >= "a" && s <= "z") || (s >= "0" && s <= "9") || s == "." || s == "_" || s == "-"
            return ok ? String(s) : "__"
        }.joined()
    }

    static func dir(for repo: String) -> URL { runsDir.appendingPathComponent(slug(repo)) }
    static func stateFile(for repo: String) -> URL { dir(for: repo).appendingPathComponent("state.json") }
    static func logFile(for repo: String) -> URL { dir(for: repo).appendingPathComponent("run.log") }
    static let globalLog: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/mmco.log")
}

enum LaunchError: LocalizedError {
    case cliNotFound
    case spawn(Int32)

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            return "The mmco CLI was not found. Run install.sh, or set \"cli\" in \(Paths.config.path)."
        case .spawn(let code):
            return "Could not start the mmco CLI (posix_spawn error \(code))."
        }
    }
}

/// Starts and stops CLI runs. The CLI is spawned in its own session with its standard streams on
/// /dev/null: Chrome kills the native-messaging host about two seconds after the extension's port
/// closes, and the run has to outlive that. Progress goes through the run folder, not through pipes.
enum RunLauncher {
    private static let reapQueue = DispatchQueue(label: "mmco.reap")
    private static var reapers: [pid_t: DispatchSourceProcess] = [:]

    static func launch(repo: String, branch: String) throws -> pid_t {
        guard let cli = Paths.cli(from: CLIRunner.loadConfig()) else { throw LaunchError.cliNotFound }
        var args = [cli, repo]
        if !branch.isEmpty { args.append(branch) }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // POSIX_SPAWN_SETSID (0x0400) and POSIX_SPAWN_CLOEXEC_DEFAULT (0x4000) are Apple additions
        // from <sys/spawn.h> that Swift does not import.
        let flags = Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK) | 0x0400 | 0x4000
        posix_spawnattr_setflags(&attr, flags)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attr, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attr, &noSignals)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        let argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let envp: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment
            .map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { envp.forEach { free($0) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, cli, &actions, &attr, argv, envp)
        guard rc == 0 else { throw LaunchError.spawn(rc) }
        reap(pid)
        return pid
    }

    /// Reaps the child when it exits, so a finished run does not linger as a zombie while the host
    /// process is still alive.
    private static func reap(_ pid: pid_t) {
        reapQueue.sync {
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: reapQueue)
            source.setEventHandler {
                var status: Int32 = 0
                waitpid(pid, &status, WNOHANG)
                reapers[pid]?.cancel()
                reapers[pid] = nil
            }
            reapers[pid] = source
            source.resume()
        }
    }

    /// True when `pid` is a live zsh process. The zsh check guards against a stale state file
    /// whose pid has since been reused by an unrelated process.
    static func isAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) == pid { return false }
        guard kill(pid, 0) == 0 || errno == EPERM else { return false }
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return true }
        let path = String(cString: buffer)
        return path.hasSuffix("/zsh") || path.hasSuffix("/mmco")
    }

    /// SIGTERM to the run's process group (the CLI is its session leader), SIGKILL after five
    /// seconds if anything is still there. Blocks the calling thread while it polls.
    static func stop(pid: pid_t) -> Bool {
        guard isAlive(pid) else { return false }
        kill(-pid, SIGTERM)
        kill(pid, SIGTERM)
        for _ in 0..<25 {
            usleep(200_000)
            if !isAlive(pid) { return true }
        }
        kill(-pid, SIGKILL)
        kill(pid, SIGKILL)
        usleep(200_000)
        return true
    }

    static func readState(repo: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: RunPaths.stateFile(for: repo)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    /// The last `lines` lines of the run's log, read from at most the trailing 64 KB.
    static func tail(repo: String, lines: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: RunPaths.logFile(for: repo)) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 64 * 1024
        let start = size > window ? size - window : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        var all = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if start > 0, !all.isEmpty { all.removeFirst() }
        return Array(all.suffix(lines))
    }
}
