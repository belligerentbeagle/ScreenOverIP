import Foundation
import Network

/// Minimal HTTP/1.1 server that serves an HTML viewer page and an MJPEG
/// multipart/x-mixed-replace stream. Built on Network.framework — no third-party deps.
final class HTTPServer {

    /// Boundary string used for multipart streams. Per RFC 2046, the value of
    /// the `boundary` Content-Type parameter does NOT include the leading "--";
    /// each part separator line in the body does.
    private let boundary = "screenoverip-frame"

    /// Page template loaded once.
    private let viewerHTML: String

    private let port: NWEndpoint.Port
    private var listener: NWListener?

    private let stateQueue = DispatchQueue(label: "com.screenoverip.http.state")
    private var subscribers: [Subscriber] = []
    private var lastFrame: Data?

    /// Optional HTTP Basic credentials. If set, every request must include
    /// `Authorization: Basic base64(user:pass)`.
    struct Credentials {
        let username: String
        let password: String
    }
    var credentials: Credentials?

    /// Called whenever the subscriber count changes (on `stateQueue`).
    var onSubscriberCountChange: ((Int) -> Void)?

    /// Lifecycle callback. Called when the listener becomes ready or fails.
    var onStateChange: ((NWListener.State) -> Void)?

    init(port: UInt16 = 8080) throws {
        guard let p = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "HTTPServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid port \(port)"])
        }
        self.port = p
        self.viewerHTML = HTTPServer.makeViewerHTML()
    }

    var subscriberCount: Int { stateQueue.sync { subscribers.count } }

    /// - Parameter bonjourName: If non-nil, publish an `_http._tcp` Bonjour record
    ///   so other devices on the LAN can resolve `<bonjourName>.local:<port>`.
    func start(bonjourName: String? = nil) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: port)
        if let name = bonjourName {
            listener.service = NWListener.Service(name: name, type: "_http._tcp")
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.handleNewConnection(conn)
        }
        listener.stateUpdateHandler = { [weak self] state in
            self?.onStateChange?(state)
        }
        listener.start(queue: DispatchQueue(label: "com.screenoverip.http.listener"))
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        stateQueue.sync {
            for s in subscribers { s.connection.cancel() }
            subscribers.removeAll()
        }
        onSubscriberCountChange?(0)
    }

    /// Push a new JPEG frame to all current MJPEG subscribers.
    /// Called from the capture thread.
    func pushFrame(_ jpeg: Data) {
        stateQueue.async {
            self.lastFrame = jpeg
            guard !self.subscribers.isEmpty else { return }
            let header = "\r\n--\(self.boundary)\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n"
            let headerData = header.data(using: .utf8) ?? Data()
            var part = Data()
            part.append(headerData)
            part.append(jpeg)

            // Drop subscribers that are no longer ready.
            self.subscribers.removeAll { sub in
                switch sub.connection.state {
                case .cancelled, .failed(_):
                    return true
                default:
                    return false
                }
            }
            for sub in self.subscribers {
                sub.write(part)
            }
            self.onSubscriberCountChange?(self.subscribers.count)
        }
    }

    // MARK: - Connection handling

    private func handleNewConnection(_ connection: NWConnection) {
        let queue = DispatchQueue(label: "com.screenoverip.http.conn.\(UUID().uuidString)")
        connection.start(queue: queue)
        receiveRequest(on: connection, accumulated: Data())
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self = self else { connection.cancel(); return }
            if let error = error {
                _ = error
                connection.cancel()
                return
            }
            var buffer = accumulated
            if let data = data, !data.isEmpty {
                buffer.append(data)
            }

            // Wait for full headers (CRLF CRLF).
            if let headerEnd = buffer.range(of: Data([0x0d, 0x0a, 0x0d, 0x0a])) {
                let headerData = buffer.subdata(in: 0..<headerEnd.lowerBound)
                if let headerString = String(data: headerData, encoding: .utf8) {
                    self.route(headerString: headerString, on: connection)
                } else {
                    self.respond404(on: connection)
                }
                return
            }
            if isComplete || buffer.count > 32 * 1024 {
                connection.cancel()
                return
            }
            self.receiveRequest(on: connection, accumulated: buffer)
        }
    }

    private func route(headerString: String, on connection: NWConnection) {
        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            respond404(on: connection); return
        }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { respond404(on: connection); return }
        let method = String(parts[0])
        let path = String(parts[1])

        guard method == "GET" || method == "HEAD" else {
            respondStatus(405, body: "Method Not Allowed", on: connection)
            return
        }

        // Parse remaining lines as headers (case-insensitive name lookup).
        var headers: [String: String] = [:]
        for raw in lines.dropFirst() {
            guard let colon = raw.firstIndex(of: ":") else { continue }
            let name = String(raw[..<colon])
                .lowercased()
                .trimmingCharacters(in: .whitespaces)
            let value = String(raw[raw.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        // Strip query string for routing.
        let pathOnly = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path

        // Enforce Basic auth if credentials are configured. /health is exempt
        // so external monitors can probe without credentials.
        if let creds = self.credentials, pathOnly != "/health" {
            if !Self.requestIsAuthorized(headers: headers, credentials: creds) {
                respondUnauthorized(on: connection)
                return
            }
        }

        switch pathOnly {
        case "/", "/index.html":
            respondHTML(viewerHTML, on: connection)
        case "/stream", "/stream.mjpg", "/video":
            startMJPEGStream(on: connection)
        case "/snapshot.jpg", "/snapshot":
            respondSnapshot(on: connection)
        case "/favicon.ico":
            respondStatus(404, body: "", on: connection)
        case "/health":
            respondStatus(200, body: "ok", on: connection, contentType: "text/plain; charset=utf-8")
        default:
            respondStatus(404, body: "Not Found", on: connection)
        }
    }

    private static func requestIsAuthorized(headers: [String: String],
                                            credentials: Credentials) -> Bool {
        guard let header = headers["authorization"] else { return false }
        let prefix = "Basic "
        guard header.hasPrefix(prefix) else { return false }
        let token = String(header.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        guard let data = Data(base64Encoded: token),
              let decoded = String(data: data, encoding: .utf8) else { return false }
        // Constant-time comparison against expected.
        let expected = "\(credentials.username):\(credentials.password)"
        return constantTimeEquals(decoded, expected)
    }

    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        if aBytes.count != bBytes.count { return false }
        var diff: UInt8 = 0
        for i in 0..<aBytes.count { diff |= aBytes[i] ^ bBytes[i] }
        return diff == 0
    }

    private func respondUnauthorized(on connection: NWConnection) {
        let body = Data("Authentication required.".utf8)
        let header = "HTTP/1.1 401 Unauthorized\r\n" +
            "WWW-Authenticate: Basic realm=\"ScreenOverIP\", charset=\"UTF-8\"\r\n" +
            "Content-Type: text/plain; charset=utf-8\r\n" +
            "Content-Length: \(body.count)\r\n" +
            "Connection: close\r\n\r\n"
        var data = Data(header.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Responses

    private func respondHTML(_ html: String, on connection: NWConnection) {
        let body = Data(html.utf8)
        let header = "HTTP/1.1 200 OK\r\n" +
            "Content-Type: text/html; charset=utf-8\r\n" +
            "Content-Length: \(body.count)\r\n" +
            "Cache-Control: no-store\r\n" +
            "Connection: close\r\n\r\n"
        var data = Data(header.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func respondStatus(_ code: Int, body: String, on connection: NWConnection,
                               contentType: String = "text/plain; charset=utf-8") {
        let reason: String = {
            switch code {
            case 200: return "OK"
            case 404: return "Not Found"
            case 405: return "Method Not Allowed"
            case 503: return "Service Unavailable"
            default:  return "Status"
            }
        }()
        let bodyData = Data(body.utf8)
        let header = "HTTP/1.1 \(code) \(reason)\r\n" +
            "Content-Type: \(contentType)\r\n" +
            "Content-Length: \(bodyData.count)\r\n" +
            "Connection: close\r\n\r\n"
        var data = Data(header.utf8)
        data.append(bodyData)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func respondSnapshot(on connection: NWConnection) {
        let frame = stateQueue.sync { self.lastFrame }
        guard let jpeg = frame else {
            respondStatus(503, body: "No frame yet", on: connection)
            return
        }
        let header = "HTTP/1.1 200 OK\r\n" +
            "Content-Type: image/jpeg\r\n" +
            "Content-Length: \(jpeg.count)\r\n" +
            "Cache-Control: no-store\r\n" +
            "Connection: close\r\n\r\n"
        var data = Data(header.utf8)
        data.append(jpeg)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func respond404(on connection: NWConnection) {
        respondStatus(404, body: "Not Found", on: connection)
    }

    private func startMJPEGStream(on connection: NWConnection) {
        let header = "HTTP/1.1 200 OK\r\n" +
            "Content-Type: multipart/x-mixed-replace; boundary=\(boundary)\r\n" +
            "Cache-Control: no-store, no-cache, must-revalidate, pre-check=0, post-check=0, max-age=0\r\n" +
            "Pragma: no-cache\r\n" +
            "Connection: close\r\n\r\n"
        // Multipart boundary in Content-Type omits the leading "--"; each pushed
        // part begins with "\r\n--<boundary>\r\n" per RFC 2046.

        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] err in
            guard err == nil, let self = self else { connection.cancel(); return }

            let sub = Subscriber(connection: connection)
            self.stateQueue.async {
                self.subscribers.append(sub)
                self.onSubscriberCountChange?(self.subscribers.count)

                // If we already have a frame, send it immediately.
                if let last = self.lastFrame {
                    let h = "\r\n--\(self.boundary)\r\nContent-Type: image/jpeg\r\nContent-Length: \(last.count)\r\n\r\n"
                    var part = Data(h.utf8)
                    part.append(last)
                    sub.write(part)
                }
            }

            // Watch for client disconnect.
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .cancelled, .failed(_):
                    self?.removeSubscriber(connection: connection)
                default:
                    break
                }
            }
        })
    }

    private func removeSubscriber(connection: NWConnection) {
        stateQueue.async {
            self.subscribers.removeAll { $0.connection === connection }
            self.onSubscriberCountChange?(self.subscribers.count)
        }
    }

    // MARK: - Subscriber

    private final class Subscriber {
        let connection: NWConnection
        private let writeQueue = DispatchQueue(label: "com.screenoverip.http.writer")
        private var inflight = 0
        private let inflightLimit = 2

        init(connection: NWConnection) {
            self.connection = connection
        }

        /// Send a frame. Drops the frame if too many writes are inflight (prevents
        /// memory blow-up for slow clients).
        func write(_ data: Data) {
            writeQueue.async {
                if self.inflight >= self.inflightLimit { return }
                self.inflight += 1
                self.connection.send(content: data, completion: .contentProcessed { [weak self] _ in
                    guard let self = self else { return }
                    self.writeQueue.async { self.inflight -= 1 }
                })
            }
        }
    }

    // MARK: - Embedded viewer HTML

    private static func makeViewerHTML() -> String {
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no" />
        <title>ScreenOverIP</title>
        <style>
            :root { color-scheme: dark; }
            html, body {
                margin: 0; padding: 0; height: 100%; background: #000;
                font: 13px -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
                color: #ddd; overflow: hidden;
            }
            #viewport {
                position: fixed; inset: 0;
                display: flex; align-items: center; justify-content: center;
                background: #000;
            }
            #stream {
                max-width: 100%; max-height: 100%;
                width: auto; height: auto;
                object-fit: contain;
                image-rendering: -webkit-optimize-contrast;
            }
            #hud {
                position: fixed; top: 8px; right: 8px;
                background: rgba(20,20,20,0.7);
                backdrop-filter: blur(8px);
                -webkit-backdrop-filter: blur(8px);
                padding: 6px 10px; border-radius: 6px;
                opacity: 0; transition: opacity 200ms ease;
                pointer-events: none;
                user-select: none;
                font-variant-numeric: tabular-nums;
            }
            #hud.show { opacity: 1; }
            #status {
                position: fixed; inset: 0;
                display: flex; align-items: center; justify-content: center;
                color: #888; font-size: 14px; pointer-events: none;
                text-align: center;
            }
            #status.hidden { display: none; }
            button.btn {
                position: fixed; bottom: 12px; right: 12px;
                background: rgba(40,40,40,0.7);
                color: #ddd; border: 1px solid #444; border-radius: 6px;
                padding: 6px 10px; cursor: pointer; font: inherit;
                opacity: 0; transition: opacity 200ms ease;
            }
            body.idle button.btn { opacity: 0; }
            body:not(.idle) button.btn { opacity: 1; }
            body:not(.idle) #hud { opacity: 1; }
        </style>
        </head>
        <body>
            <div id="viewport">
                <img id="stream" alt="Screen stream" />
            </div>
            <div id="status">Connecting…</div>
            <div id="hud"><span id="fps">— fps</span></div>
            <button class="btn" id="fullscreen">Fullscreen</button>

        <script>
        (function () {
            const img = document.getElementById('stream');
            const status = document.getElementById('status');
            const fps = document.getElementById('fps');
            const fullscreenBtn = document.getElementById('fullscreen');
            const body = document.body;

            let frames = 0;
            let lastTick = performance.now();

            function setStream() {
                // Cache-bust to force re-subscribe on retries.
                img.src = '/stream.mjpg?t=' + Date.now();
            }

            img.addEventListener('load', () => {
                status.classList.add('hidden');
            });
            img.addEventListener('error', () => {
                status.textContent = 'Stream interrupted. Retrying…';
                status.classList.remove('hidden');
                setTimeout(setStream, 1500);
            });

            // Approximate FPS by sampling decoded image size changes.
            // (The browser doesn't expose per-frame events for MJPEG.)
            let lastNaturalSize = 0;
            const sampleTimer = setInterval(() => {
                const sig = (img.naturalWidth << 16) ^ img.naturalHeight ^ Math.floor(performance.now() / 100);
                if (sig !== lastNaturalSize) {
                    lastNaturalSize = sig;
                    frames++;
                }
                const now = performance.now();
                if (now - lastTick >= 1000) {
                    const value = (frames * 1000 / (now - lastTick)).toFixed(0);
                    fps.textContent = value + ' fps approx';
                    frames = 0;
                    lastTick = now;
                }
            }, 100);

            fullscreenBtn.addEventListener('click', () => {
                if (document.fullscreenElement) {
                    document.exitFullscreen();
                } else {
                    document.documentElement.requestFullscreen();
                }
            });

            // Idle UI hiding.
            let idleTimer;
            function showUI() {
                body.classList.remove('idle');
                clearTimeout(idleTimer);
                idleTimer = setTimeout(() => body.classList.add('idle'), 2000);
            }
            ['mousemove','touchstart','keydown'].forEach(ev =>
                window.addEventListener(ev, showUI, { passive: true })
            );
            showUI();

            setStream();
        })();
        </script>
        </body>
        </html>
        """
    }
}
