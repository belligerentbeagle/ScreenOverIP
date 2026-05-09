import Foundation
import Combine
import ScreenCaptureKit
import CoreVideo

/// Top-level glue between the SwiftUI UI, ScreenCaptureKit, and the HTTP server.
@MainActor
final class StreamCoordinator: ObservableObject {

    // MARK: - Published UI state

    enum Status: Equatable {
        case idle
        case starting
        case running
        case error(String)
    }

    @Published var status: Status = .idle
    @Published var availableDisplays: [SCDisplay] = []
    @Published var availableWindows: [SCWindow] = []
    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published var selectedWindowID: CGWindowID?
    @Published var sourceKind: SourceKind = .display

    @Published var port: UInt16 = 8080
    @Published var frameRate: Int = 30
    @Published var quality: Double = 0.7
    @Published var maxDimension: Int = 1280
    @Published var publishBonjour: Bool = true

    // Auth (HTTP Basic).
    @Published var requireAuth: Bool = false
    @Published var username: String = "viewer"
    @Published var password: String = ""

    // Cloudflare Tunnel.
    enum TunnelStatus: Equatable {
        case off
        case starting
        case ready
        case error(String)
    }
    @Published var enableTunnel: Bool = false
    @Published var tunnelStatus: TunnelStatus = .off
    @Published var publicURL: URL?
    /// Whether cloudflared was found on disk. Populated asynchronously after
    /// init so we don't block the main thread spawning `which`.
    @Published var cloudflaredInstalled: Bool = false

    @Published var urls: [URL] = []
    @Published var viewerCount: Int = 0
    @Published var lastError: String?

    enum SourceKind: String, CaseIterable, Identifiable {
        case display = "Display"
        case window = "Window"
        var id: String { rawValue }
    }

    // MARK: - Private

    private var capture: AnyObject?
    private var server: HTTPServer?
    private var tunnel: CloudflaredTunnel?

    // MARK: - Lifecycle

    init() {
        Task { await refreshSources() }
        // Detect cloudflared off the main thread — `Process` + waitUntilExit
        // takes a few hundred ms and was triggering "deferral block timed out"
        // warnings when run synchronously during init.
        Task.detached(priority: .utility) { [weak self] in
            let installed = CloudflaredTunnel.isInstalled
            await MainActor.run { self?.cloudflaredInstalled = installed }
        }
    }

    /// Re-query the system for displays and windows. Call when the popup opens
    /// or when the user wants to refresh.
    func refreshSources() async {
        guard #available(macOS 13.0, *) else {
            self.lastError = "macOS 13 (Ventura) or later is required."
            return
        }
        do {
            let content = try await ScreenCapture.availableContent()
            let displays = content.displays
            // Filter windows: skip our own app and tiny/system windows.
            let windows = content.windows
                .filter { $0.isOnScreen }
                .filter { ($0.frame.width * $0.frame.height) > 5000 }
                .filter { $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier }
                .sorted { ($0.title ?? "") < ($1.title ?? "") }

            self.availableDisplays = displays
            self.availableWindows = windows
            if selectedDisplayID == nil { selectedDisplayID = displays.first?.displayID }
            if selectedWindowID == nil { selectedWindowID = windows.first?.windowID }
            self.lastError = nil
        } catch {
            // Surface the underlying error code so we can tell apart "no permission"
            // from a stale TCC entry from some unrelated SCK failure.
            let nsError = error as NSError
            let detail = "\(error.localizedDescription) [\(nsError.domain) \(nsError.code)]"
            self.lastError = """
            Couldn't list capture sources: \(detail)

            If you've already granted Screen Recording permission, your build's signature has likely changed and TCC is rejecting it silently. Fix:
              1. In Terminal: tccutil reset ScreenCapture com.screenoverip.app
              2. Re-run the app and click Allow on the new prompt.

            (Or: System Settings → Privacy & Security → Screen Recording, click − to remove ScreenOverIP, then re-run.)
            """
        }
    }

    func start() {
        guard status != .running, status != .starting else { return }
        status = .starting
        lastError = nil

        Task { @MainActor in
            do {
                try await self.startInternal()
                self.status = .running
            } catch {
                let message = (error as NSError).localizedDescription
                self.status = .error(message)
                self.lastError = message
            }
        }
    }

    func stop() {
        Task { @MainActor in
            await self.stopInternal()
            self.status = .idle
            self.viewerCount = 0
        }
    }

    // MARK: - Internals

    @available(macOS 13.0, *)
    private func resolveSource() -> ScreenCapture.Source? {
        switch sourceKind {
        case .display:
            guard let id = selectedDisplayID,
                  let d = availableDisplays.first(where: { $0.displayID == id })
            else { return nil }
            return .display(d)
        case .window:
            guard let id = selectedWindowID,
                  let w = availableWindows.first(where: { $0.windowID == id })
            else { return nil }
            return .window(w)
        }
    }

    private func startInternal() async throws {
        guard #available(macOS 13.0, *) else {
            throw NSError(domain: "ScreenOverIP", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "macOS 13+ required"])
        }
        guard let source = resolveSource() else {
            throw NSError(domain: "ScreenOverIP", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Pick a display or window first."])
        }

        // Auto-generate a password if auth is on but the user hasn't set one.
        if requireAuth && password.isEmpty {
            password = Self.makeRandomPassword()
        }
        if requireAuth && username.isEmpty {
            username = "viewer"
        }

        // Snapshot settings up-front (we're MainActor; reads are safe).
        let port = self.port
        let publishBonjour = self.publishBonjour
        let qualityValue = self.quality
        let frameRateValue = self.frameRate
        let maxDimValue = self.maxDimension
        let creds: HTTPServer.Credentials? = requireAuth
            ? .init(username: username, password: password)
            : nil
        let wantTunnel = self.enableTunnel

        // 1. Build server.
        let server = try HTTPServer(port: port)
        server.credentials = creds
        server.onSubscriberCountChange = { [weak self] count in
            Task { @MainActor in self?.viewerCount = count }
        }
        server.onStateChange = { [weak self] state in
            Task { @MainActor in
                if case .failed(let error) = state {
                    self?.status = .error(error.localizedDescription)
                    self?.lastError = error.localizedDescription
                }
            }
        }
        try server.start(bonjourName: publishBonjour ? "ScreenOverIP" : nil)
        self.server = server

        // 2. Build capture. Frame callback fires off-main; jpeg encode + push are
        // both thread-safe.
        let capture = ScreenCapture()
        capture.onFrame = { [weak server] pixelBuffer in
            guard let server = server else { return }
            if let jpeg = JPEGEncoder.shared.encode(pixelBuffer, quality: qualityValue) {
                server.pushFrame(jpeg)
            }
        }
        capture.onStop = { [weak self] error in
            Task { @MainActor in
                if let error = error {
                    self?.status = .error(error.localizedDescription)
                    self?.lastError = error.localizedDescription
                } else {
                    self?.status = .idle
                }
            }
        }
        try await capture.start(source: source, frameRate: frameRateValue, maxDimension: maxDimValue)
        self.capture = capture

        // 3. Compute URLs for the UI.
        self.urls = NetworkHelper.candidateURLs(port: port)

        // 4. Optionally start a Cloudflare quick tunnel.
        if wantTunnel {
            self.tunnelStatus = .starting
            self.publicURL = nil
            do {
                let tunnel = CloudflaredTunnel()
                tunnel.onPublicURL = { [weak self] url in
                    Task { @MainActor in
                        self?.publicURL = url
                        self?.tunnelStatus = .ready
                    }
                }
                tunnel.onStop = { [weak self] err in
                    Task { @MainActor in
                        self?.publicURL = nil
                        if let err = err {
                            self?.tunnelStatus = .error(err.localizedDescription)
                            self?.lastError = err.localizedDescription
                        } else {
                            self?.tunnelStatus = .off
                        }
                    }
                }
                try tunnel.start(localPort: port)
                self.tunnel = tunnel
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                self.tunnelStatus = .error(message)
                self.lastError = message
            }
        }
    }

    private func stopInternal() async {
        // Stop tunnel first so cloudflared cleans up the upstream registration
        // before we close the local listener.
        tunnel?.stop()
        tunnel = nil
        publicURL = nil
        tunnelStatus = .off

        if #available(macOS 13.0, *) {
            if let cap = capture as? ScreenCapture {
                await cap.stop()
            }
        }
        capture = nil
        server?.stop()
        server = nil
    }

    // MARK: - Helpers

    /// 12-character alphanumeric password — plenty of entropy for casual use.
    private static func makeRandomPassword(length: Int = 12) -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789")
        return String((0..<length).map { _ in alphabet.randomElement()! })
    }
}
