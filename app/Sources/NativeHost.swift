import Foundation

/// Chrome native-messaging host. Chrome launches mmco.app's binary with `chrome-extension://<id>/`
/// as its first argument and talks over stdin/stdout: a native-endian UInt32 length, then a JSON
/// object. Requests carry `id`, `type` and usually `repo`; the host answers with `run` messages that
/// hold the run's state.json, its log tail and a derived `status`, and keeps sending them while the
/// run is alive. Chrome closes stdin when the extension's port goes away, and the host exits.
final class NativeHost {
    private let queue = DispatchQueue(label: "mmco.native-host")
    private var watches: [String: DispatchSourceTimer] = [:]
    private var lastSent: [String: (fingerprint: String, at: Date)] = [:]
    private var launched: [String: (pid: pid_t, branch: String, at: Date)] = [:]
    private var stopping: Set<String> = []

    func run() -> Never {
        while true {
            guard let message = readMessage() else { exit(0) }
            queue.async { self.handle(message) }
        }
    }

    // MARK: requests

    private func handle(_ message: [String: Any]) {
        let id = message["id"]
        let type = message["type"] as? String ?? ""
        let repo = (message["repo"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case "ping":
            send(["type": "pong", "replyTo": id ?? NSNull(), "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? ""])
        case "checkout":
            guard !repo.isEmpty else { return sendError(id, repo, "checkout needs a repo") }
            let branch = (message["branch"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            stopCurrentRun(of: repo)
            do {
                let pid = try RunLauncher.launch(repo: repo, branch: branch)
                launched[key(repo)] = (pid, branch, Date())
                stopping.remove(key(repo))
                sendRun(repo, replyTo: id)
                watch(repo)
            } catch {
                sendError(id, repo, error.localizedDescription)
            }
        case "status":
            guard !repo.isEmpty else { return sendError(id, repo, "status needs a repo") }
            sendRun(repo, replyTo: id)
            if snapshot(repo)["status"] as? String == "running" { watch(repo) }
        case "stop":
            guard !repo.isEmpty else { return sendError(id, repo, "stop needs a repo") }
            stopCurrentRun(of: repo)
            sendRun(repo, replyTo: id)
        case "open-log":
            let runLog = RunPaths.logFile(for: repo)
            let target = !repo.isEmpty && FileManager.default.fileExists(atPath: runLog.path) ? runLog : RunPaths.globalLog
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = [target.path]
            try? process.run()
            send(["type": "ok", "replyTo": id ?? NSNull()])
        default:
            sendError(id, repo, "unknown message type \(type)")
        }
    }

    private func stopCurrentRun(of repo: String) {
        guard let state = RunLauncher.readState(repo: repo), state["status"] as? String == "running",
              let pid = (state["pid"] as? NSNumber)?.int32Value, RunLauncher.isAlive(pid) else { return }
        stopping.insert(key(repo))
        _ = RunLauncher.stop(pid: pid)
    }

    // MARK: state

    private func key(_ repo: String) -> String { repo.lowercased() }

    /// state.json plus what the file cannot know: whether the recorded pid is still alive. A run
    /// whose process died while the file still says `running` is reported as failed, or stopped when
    /// this host stopped it. Right after a launch the file may still belong to the previous run, so
    /// the launched pid wins until the CLI has written its own.
    private func snapshot(_ repo: String) -> [String: Any] {
        let k = key(repo)
        var state = RunLauncher.readState(repo: repo) ?? ["repo": repo, "status": "none"]
        let filePid = (state["pid"] as? NSNumber)?.int32Value ?? 0

        if let launch = launched[k] {
            if filePid == launch.pid {
                launched[k] = nil
            } else if RunLauncher.isAlive(launch.pid) {
                state = ["repo": repo, "branch": launch.branch, "status": "running", "phase": "start",
                         "pid": Int(launch.pid), "checkedOut": false, "warnings": [String](),
                         "startedAt": iso(launch.at)]
            } else {
                launched[k] = nil
                state = ["repo": repo, "branch": launch.branch, "status": "failed", "phase": "start",
                         "pid": Int(launch.pid), "checkedOut": false, "warnings": [String](),
                         "message": "the mmco CLI exited before recording a run (see the log)",
                         "startedAt": iso(launch.at)]
            }
        }

        let pid = (state["pid"] as? NSNumber)?.int32Value ?? 0
        let alive = RunLauncher.isAlive(pid)
        if state["status"] as? String == "running" && !alive {
            let stopped = stopping.contains(k)
            state["status"] = stopped ? "stopped" : "failed"
            state["message"] = stopped ? "stopped" : "the run ended without recording a result (see the log)"
        }
        if state["status"] as? String != "running" { stopping.remove(k) }
        state["alive"] = alive
        // Until the CLI has written its own state, run.log still belongs to the previous run.
        state["tail"] = launched[k] == nil ? RunLauncher.tail(repo: repo, lines: 12) : [String]()
        return state
    }

    private func sendRun(_ repo: String, replyTo id: Any?) {
        let state = snapshot(repo)
        var message: [String: Any] = ["type": "run", "repo": repo, "state": state]
        if let id { message["replyTo"] = id }
        send(message)
        lastSent[key(repo)] = (fingerprint(state), Date())
    }

    /// Polls the run folder twice a second and forwards every change. A message at least every
    /// eight seconds keeps the extension's service worker awake while a long block runs.
    private func watch(_ repo: String) {
        let k = key(repo)
        guard watches[k] == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let state = self.snapshot(repo)
            let print = self.fingerprint(state)
            let last = self.lastSent[k]
            let due = last == nil || last!.fingerprint != print || Date().timeIntervalSince(last!.at) >= 8
            if due {
                self.send(["type": "run", "repo": repo, "state": state])
                self.lastSent[k] = (print, Date())
            }
            if state["status"] as? String != "running" {
                self.watches[k]?.cancel()
                self.watches[k] = nil
            }
        }
        watches[k] = timer
        timer.resume()
    }

    private func fingerprint(_ state: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) else { return UUID().uuidString }
        return String(decoding: data, as: UTF8.self)
    }

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    // MARK: wire

    private func sendError(_ id: Any?, _ repo: String, _ message: String) {
        var payload: [String: Any] = ["type": "error", "repo": repo, "message": message]
        if let id { payload["replyTo"] = id }
        send(payload)
    }

    private func send(_ object: [String: Any]) {
        guard let body = try? JSONSerialization.data(withJSONObject: object) else { return }
        var length = UInt32(body.count)
        var out = Data(bytes: &length, count: 4)
        out.append(body)
        out.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(1, base.advanced(by: offset), buffer.count - offset)
                if written <= 0 { exit(0) }
                offset += written
            }
        }
    }

    private func readMessage() -> [String: Any]? {
        guard let header = readExactly(4) else { return nil }
        let length = Int(header.withUnsafeBytes { $0.load(as: UInt32.self) })
        guard length > 0, length <= 64 * 1024 * 1024, let body = readExactly(length) else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }

    private func readExactly(_ count: Int) -> Data? {
        var data = Data(count: count)
        var got = 0
        while got < count {
            let read = data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return Darwin.read(0, base.advanced(by: got), count - got)
            }
            if read <= 0 { return nil }
            got += read
        }
        return data
    }
}
