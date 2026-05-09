import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit
import ScreenCaptureKit

struct ContentView: View {
    @EnvironmentObject var coordinator: StreamCoordinator
    @State private var copiedURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sourceSection
                    settingsSection
                    securitySection
                    publicAccessSection
                    if coordinator.status == .running {
                        urlSection
                    }
                    if let err = coordinator.lastError {
                        errorBox(err)
                    }
                }
                .padding(20)
            }
            Divider()
            footer
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "display.and.arrow.down")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Screen Over IP")
                    .font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            statusDot
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var statusText: String {
        switch coordinator.status {
        case .idle:        return "Stopped"
        case .starting:    return "Starting…"
        case .running:     return "Streaming · \(coordinator.viewerCount) viewer\(coordinator.viewerCount == 1 ? "" : "s")"
        case .error(let m): return "Error: \(m)"
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 10, height: 10)
            .overlay(Circle().stroke(Color.black.opacity(0.15), lineWidth: 0.5))
    }

    private var statusColor: Color {
        switch coordinator.status {
        case .idle:        return .secondary
        case .starting:    return .yellow
        case .running:     return .green
        case .error(_):    return .red
        }
    }

    // MARK: - Source picker

    private var sourceSection: some View {
        section(title: "What to stream") {
            Picker("Source", selection: $coordinator.sourceKind) {
                ForEach(StreamCoordinator.SourceKind.allCases) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(coordinator.status == .running || coordinator.status == .starting)

            Group {
                if coordinator.sourceKind == .display {
                    displayPicker
                } else {
                    windowPicker
                }
            }
            .padding(.top, 6)
        }
    }

    @ViewBuilder
    private var displayPicker: some View {
        if coordinator.availableDisplays.isEmpty {
            emptyState("No displays found.")
        } else {
            Picker("Display", selection: Binding(
                get: { coordinator.selectedDisplayID ?? coordinator.availableDisplays.first?.displayID ?? 0 },
                set: { coordinator.selectedDisplayID = $0 }
            )) {
                ForEach(coordinator.availableDisplays, id: \.displayID) { d in
                    Text("Display \(d.displayID) · \(d.width)×\(d.height)")
                        .tag(d.displayID)
                }
            }
            .labelsHidden()
            .disabled(coordinator.status == .running || coordinator.status == .starting)
        }
    }

    @ViewBuilder
    private var windowPicker: some View {
        if coordinator.availableWindows.isEmpty {
            emptyState("No windows available. Try refreshing or grant Screen Recording permission.")
        } else {
            Picker("Window", selection: Binding(
                get: { coordinator.selectedWindowID ?? coordinator.availableWindows.first?.windowID ?? 0 },
                set: { coordinator.selectedWindowID = $0 }
            )) {
                ForEach(coordinator.availableWindows, id: \.windowID) { w in
                    let app = w.owningApplication?.applicationName ?? "Unknown"
                    let title = w.title ?? "Untitled"
                    Text("\(app) — \(title)").tag(w.windowID)
                }
            }
            .labelsHidden()
            .disabled(coordinator.status == .running || coordinator.status == .starting)
        }
    }

    // MARK: - Settings

    private var settingsSection: some View {
        section(title: "Stream settings") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Frame rate")
                    Spacer()
                    Text("\(coordinator.frameRate) fps").foregroundStyle(.secondary).font(.caption)
                }
                Slider(value: Binding(
                    get: { Double(coordinator.frameRate) },
                    set: { coordinator.frameRate = Int($0) }
                ), in: 5...60, step: 1)
                .disabled(coordinator.status == .running)

                HStack {
                    Text("JPEG quality")
                    Spacer()
                    Text("\(Int(coordinator.quality * 100))%").foregroundStyle(.secondary).font(.caption)
                }
                Slider(value: $coordinator.quality, in: 0.3...0.95, step: 0.05)

                HStack {
                    Text("Max width")
                    Spacer()
                    Text("\(coordinator.maxDimension) px").foregroundStyle(.secondary).font(.caption)
                }
                Slider(value: Binding(
                    get: { Double(coordinator.maxDimension) },
                    set: { coordinator.maxDimension = Int($0) }
                ), in: 480...2560, step: 80)
                .disabled(coordinator.status == .running)

                HStack {
                    Text("Port")
                    Spacer()
                    TextField("Port", value: $coordinator.port, format: .number.grouping(.never))
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                        .disabled(coordinator.status == .running)
                }

                Toggle("Publish via Bonjour (.local)", isOn: $coordinator.publishBonjour)
                    .disabled(coordinator.status == .running)
            }
        }
    }

    // MARK: - Security

    private var securitySection: some View {
        section(title: "Security") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Require password", isOn: $coordinator.requireAuth)
                    .disabled(coordinator.status == .running)

                if coordinator.requireAuth {
                    HStack {
                        Text("Username").frame(width: 80, alignment: .leading)
                        TextField("viewer", text: $coordinator.username)
                            .textFieldStyle(.roundedBorder)
                            .disabled(coordinator.status == .running)
                    }
                    HStack {
                        Text("Password").frame(width: 80, alignment: .leading)
                        SecureField("Auto-generated if blank",
                                    text: $coordinator.password)
                            .textFieldStyle(.roundedBorder)
                            .disabled(coordinator.status == .running)
                        Button {
                            coordinator.password = randomPassword()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Generate random password")
                        .disabled(coordinator.status == .running)
                    }
                    Text("Browser will prompt for these the first time it opens the stream.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func randomPassword() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789")
        return String((0..<12).map { _ in alphabet.randomElement()! })
    }

    // MARK: - Public access (Cloudflare Tunnel)

    private var publicAccessSection: some View {
        section(title: "Public URL (over the internet)") {
            VStack(alignment: .leading, spacing: 10) {
                if !coordinator.cloudflaredInstalled {
                    notInstalledHint
                } else {
                    Toggle("Expose via Cloudflare Tunnel", isOn: $coordinator.enableTunnel)
                        .disabled(coordinator.status == .running)
                    Text("Spawns cloudflared and gives you a public https://*.trycloudflare.com URL — works on networks not joined to your LAN. Strongly recommended to also enable a password above.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if coordinator.status == .running && coordinator.enableTunnel {
                        tunnelStatusView
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var tunnelStatusView: some View {
        switch coordinator.tunnelStatus {
        case .off:
            EmptyView()
        case .starting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Starting cloudflared… (can take 5–15 seconds)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .ready:
            EmptyView() // public URL appears in URL section
        case .error(let m):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(m).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var notInstalledHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("cloudflared isn't installed.")
                .font(.callout)
            HStack {
                Text("brew install cloudflared")
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.15)))
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install cloudflared", forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy install command")
            }
            Text("After installing, restart this app.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - URLs

    @ViewBuilder
    private var urlSection: some View {
        section(title: "Open in any browser") {
            VStack(alignment: .leading, spacing: 12) {
                if let pub = coordinator.publicURL {
                    publicURLRow(pub)
                }
                ForEach(coordinator.urls, id: \.self) { url in
                    urlRow(url)
                }
                if let qrTarget = coordinator.publicURL ?? coordinator.urls.first {
                    qrCode(for: qrTarget)
                        .padding(.top, 4)
                }
                if coordinator.requireAuth {
                    Text("Login: \(coordinator.username) / \(coordinator.password)")
                        .font(.system(.caption, design: .monospaced))
                        .padding(.top, 4)
                }
                Text(coordinator.publicURL == nil
                     ? "Anyone on your local network with this URL can view the stream."
                     : "Public URL works from anywhere on the internet. Keep the password handy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func publicURLRow(_ url: URL) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .foregroundStyle(.tint)
                .frame(width: 16)
            Text(url.absoluteString)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .fontWeight(.medium)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                copiedURL = url
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if copiedURL == url { copiedURL = nil }
                }
            } label: {
                Image(systemName: copiedURL == url ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy")
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Image(systemName: "safari")
            }
            .buttonStyle(.borderless)
            .help("Open in browser")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.1)))
    }

    private func urlRow(_ url: URL) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(url.absoluteString)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                copiedURL = url
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if copiedURL == url { copiedURL = nil }
                }
            } label: {
                Image(systemName: copiedURL == url ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy")
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Image(systemName: "safari")
            }
            .buttonStyle(.borderless)
            .help("Open in browser")
        }
    }

    @ViewBuilder
    private func qrCode(for url: URL) -> some View {
        if let img = QRCodeGenerator.generate(string: url.absoluteString, size: 160) {
            HStack {
                Spacer()
                Image(nsImage: img)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 160, height: 160)
                    .background(Color.white)
                    .cornerRadius(6)
                Spacer()
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Refresh sources") {
                Task { await coordinator.refreshSources() }
            }
            .disabled(coordinator.status == .running || coordinator.status == .starting)

            Spacer()

            if coordinator.status == .running {
                Button(role: .destructive) {
                    coordinator.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .keyboardShortcut(".", modifiers: [.command])
            } else {
                Button {
                    coordinator.start()
                } label: {
                    Label("Start streaming", systemImage: "play.fill")
                        .frame(minWidth: 120)
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .buttonStyle(.borderedProminent)
                .disabled(coordinator.status == .starting)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Helpers

    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func emptyState(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
    }

    private func errorBox(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.12)))
    }
}

// MARK: - QR helper

enum QRCodeGenerator {
    static func generate(string: String, size: CGFloat) -> NSImage? {
        let data = Data(string.utf8)
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: NSSize(width: size, height: size))
        img.addRepresentation(rep)
        return img
    }
}

#Preview {
    ContentView().environmentObject(StreamCoordinator())
}
