import Foundation

/// Local-network helpers — discovers a usable IP and `<host>.local` name to
/// build URLs you can copy/paste into a remote browser.
///
/// Bonjour publishing itself is attached directly to `HTTPServer`'s NWListener
/// (see `HTTPServer.start(bonjourName:)`).
enum NetworkHelper {

    /// Returns the system's `<hostname>.local` name (e.g. "Eths-MacBook.local").
    static func localHostname() -> String {
        var name = ProcessInfo.processInfo.hostName
        if !name.contains(".") { name += ".local" }
        return name
    }

    /// Best non-loopback IPv4 address on the host. Returns nil if not on a network.
    static func primaryIPv4() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            let interface = p.pointee
            guard let addr = interface.ifa_addr else { continue }
            let family = addr.pointee.sa_family
            guard family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            // Skip loopback, tunnels, AWDL/llw.
            if name.hasPrefix("lo") || name.hasPrefix("utun") || name.hasPrefix("awdl") || name.hasPrefix("llw") {
                continue
            }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let ok = getnameinfo(addr,
                                 socklen_t(addr.pointee.sa_len),
                                 &hostname, socklen_t(hostname.count),
                                 nil, 0, NI_NUMERICHOST)
            if ok == 0 {
                let candidate = String(cString: hostname)
                if !candidate.isEmpty {
                    address = candidate
                    if name == "en0" { return candidate }
                }
            }
        }
        return address
    }

    /// Build URLs the user can share. Order: LAN IP first, then `<host>.local`.
    static func candidateURLs(port: UInt16) -> [URL] {
        var urls: [URL] = []
        if let ip = primaryIPv4(), let url = URL(string: "http://\(ip):\(port)/") {
            urls.append(url)
        }
        let host = localHostname()
        if !host.isEmpty, let url = URL(string: "http://\(host):\(port)/") {
            urls.append(url)
        }
        return urls
    }
}
