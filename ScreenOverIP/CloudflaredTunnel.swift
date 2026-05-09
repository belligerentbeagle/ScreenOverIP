import Foundation

/// Wraps Cloudflare's `cloudflared` binary as a managed subprocess.
///
/// Runs `cloudflared tunnel --url http://localhost:<port>`, watches stderr for
/// the published `*.trycloudflare.com` URL, and surfaces the result via
/// callbacks. Free quick-tunnels — no Cloudflare account required, but the
/// URL is ephemeral (changes every run).
final class CloudflaredTunnel {

    enum TunnelError: LocalizedError {
        case binaryNotFound
        case alreadyRunning
        case spawnFailed(Error)
        case terminated(code: Int32, reason: String?)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                return "cloudflared isn't installed. Run: brew install cloudflared"
            case .alreadyRunning:
                return "Tunnel is already running."
            case .spawnFailed(let err):
                return "Couldn't start cloudflared: \(err.localizedDescription)"
            case .terminated(let code, let reason):
                if let r = reason, !r.isEmpty {
                    return "cloudflared exited (\(code)): \(r)"
                }
                return "cloudflared exited with status \(code)."
            case .timedOut:
                return "cloudflared didn't print a public URL within 60 seconds."
            }
        }
    }

    /// Fires when the public URL is first observed.
    var onPublicURL: ((URL) -> Void)?

    /// Fires when the subprocess terminates (cleanly or with error).
    var onStop: ((TunnelError?) -> Void)?

    /// Fires for each line emitted to stderr — useful for debug.
    var onLog: ((String) -> Void)?

    private var process: Process?
    private var stderrPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var didReportURL = false
    private var bufferedLog = ""
    private let lock = NSLock()
    private var lastLogLines: [String] = []          // tail buffer for diagnostics
    private let logBufferSize = 30

    /// Standard install locations to try in order.
    private static let candidatePaths = [
        "/opt/homebrew/bin/cloudflared",   // Apple Silicon Homebrew
        "/usr/local/bin/cloudflared",      // Intel Homebrew / manual install
        "/opt/local/bin/cloudflared",      // MacPorts
        "/usr/bin/cloudflared"
    ]

    /// Returns the absolute path to the first cloudflared binary we can find.
    static func findBinary() -> String? {
        let fm = FileManager.default
        for path in candidatePaths where fm.isExecutableFile(atPath: path) {
            return path
        }
        // Fall back to PATH lookup via `/usr/bin/which`.
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = ["cloudflared"]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = Pipe()
        do {
            try which.run()
            which.waitUntilExit()
            if which.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let path = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let p = path, !p.isEmpty, fm.isExecutableFile(atPath: p) {
                    return p
                }
            }
        } catch { /* ignore */ }
        return nil
    }

    /// Returns true if cloudflared is installed and runnable on this system.
    static var isInstalled: Bool { findBinary() != nil }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return process?.isRunning ?? false
    }

    /// Start the tunnel pointing at `http://localhost:<port>`.
    /// Throws synchronously if the binary is missing or process spawn fails.
    func start(localPort: UInt16) throws {
        lock.lock()
        if process?.isRunning == true {
            lock.unlock()
            throw TunnelError.alreadyRunning
        }
        lock.unlock()

        guard let binary = Self.findBinary() else {
            throw TunnelError.binaryNotFound
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = [
            "tunnel",
            "--no-autoupdate",
            "--url", "http://localhost:\(localPort)"
        ]

        // Detach from the launching app's controlling terminal.
        proc.standardInput = FileHandle.nullDevice

        let stderrPipe = Pipe()
        let stdoutPipe = Pipe()
        proc.standardError = stderrPipe
        proc.standardOutput = stdoutPipe

        // Both streams may carry the URL line — cloudflared is inconsistent
        // across versions about which one it logs to. Read both.
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.handleOutput(handle.availableData)
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.handleOutput(handle.availableData)
        }

        proc.terminationHandler = { [weak self] terminated in
            guard let self = self else { return }
            // Drain remaining buffered output.
            self.handleOutput(stderrPipe.fileHandleForReading.readDataToEndOfFile())
            self.handleOutput(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            stdoutPipe.fileHandleForReading.readabilityHandler = nil

            let code = terminated.terminationStatus
            let reason = self.tailLog()

            self.lock.lock()
            self.process = nil
            self.stderrPipe = nil
            self.stdoutPipe = nil
            self.lock.unlock()

            // Exit status 0 = clean stop; SIGTERM (15) shows up as terminationReason=.uncaughtSignal
            if code == 0 || terminated.terminationReason == .uncaughtSignal {
                self.onStop?(nil)
            } else {
                self.onStop?(.terminated(code: code, reason: reason))
            }
        }

        do {
            try proc.run()
        } catch {
            throw TunnelError.spawnFailed(error)
        }

        lock.lock()
        self.process = proc
        self.stderrPipe = stderrPipe
        self.stdoutPipe = stdoutPipe
        self.didReportURL = false
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let p = self.process
        lock.unlock()
        guard let p = p, p.isRunning else { return }
        p.terminate()
        // Force-kill if it doesn't exit within 3s.
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak p] in
            if let p = p, p.isRunning {
                kill(p.processIdentifier, SIGKILL)
            }
        }
    }

    // MARK: - Output parsing

    private func handleOutput(_ data: Data) {
        guard !data.isEmpty,
              let chunk = String(data: data, encoding: .utf8) else { return }

        lock.lock()
        bufferedLog += chunk
        // Emit complete lines.
        var emit: [String] = []
        while let nl = bufferedLog.firstIndex(of: "\n") {
            let line = String(bufferedLog[..<nl])
            bufferedLog.removeSubrange(...nl)
            emit.append(line)
            lastLogLines.append(line)
            if lastLogLines.count > logBufferSize {
                lastLogLines.removeFirst(lastLogLines.count - logBufferSize)
            }
        }
        let alreadyReported = didReportURL
        lock.unlock()

        for line in emit {
            onLog?(line)
            if !alreadyReported, let url = Self.extractTryCloudflareURL(from: line) {
                lock.lock()
                let firstReport = !didReportURL
                if firstReport { didReportURL = true }
                lock.unlock()
                if firstReport { onPublicURL?(url) }
            }
        }
    }

    private func tailLog() -> String? {
        lock.lock(); defer { lock.unlock() }
        return lastLogLines.suffix(8).joined(separator: "\n")
    }

    /// Pulls a `https://*.trycloudflare.com` URL out of a log line, if present.
    static func extractTryCloudflareURL(from line: String) -> URL? {
        // cloudflared formats vary. The URL always contains "trycloudflare.com".
        guard let range = line.range(of: #"https?://[A-Za-z0-9._-]+\.trycloudflare\.com[A-Za-z0-9./?=&_-]*"#,
                                     options: .regularExpression) else { return nil }
        let urlString = String(line[range])
        return URL(string: urlString)
    }
}
