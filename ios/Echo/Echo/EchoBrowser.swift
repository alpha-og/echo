import Foundation
import Combine

/// A relay found via Bonjour (`_echo._tcp.`).
struct DiscoveredEcho: Identifiable, Equatable {
    /// Service instance name (stable identity for the list).
    let id: String
    let name: String
    let host: String
    let port: Int
}

/// Browses for echo relays. No pairing/auth here — that still happens
/// at `/pair` with the TOTP code after the user taps a Mac.
///
/// Threading: everything runs synchronously on the main runloop (the browser
/// is started from the main actor and NetService schedules callbacks there),
/// so no values ever cross isolation boundaries. This is what keeps
/// non-`Sendable` `NetService` objects out of `@Sendable` closures.
final class EchoBrowser: NSObject, ObservableObject {
    @Published var echoes: [DiscoveredEcho] = []
    @Published var browsing = false

    private var browser: NetServiceBrowser?
    private var resolving: [String: NetService] = [:]

    func start() {
        guard browser == nil else { return }
        let b = NetServiceBrowser()
        b.delegate = self
        browser = b
        browsing = true
        b.searchForServices(ofType: "_echo._tcp.", inDomain: "local.")
    }

    func stop() {
        for s in resolving.values { s.stop() }
        resolving.removeAll()
        browser?.stop()
        browser = nil
        browsing = false
    }

    private func resolve(_ service: NetService) {
        guard resolving[service.name] == nil else { return }
        service.delegate = self
        resolving[service.name] = service
        service.resolve(withTimeout: 8)
    }

    private func remove(_ service: NetService) {
        resolving[service.name]?.stop()
        resolving.removeValue(forKey: service.name)
        echoes.removeAll { $0.id == service.name }
    }
}

extension EchoBrowser: NetServiceBrowserDelegate {
    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        resolve(service)
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        remove(service)
    }
}

extension EchoBrowser: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard sender.port > 0, let host = sender.hostName else { return }
        let echo = DiscoveredEcho(
            id: sender.name,
            name: sender.name.replacingOccurrences(of: " echo$", with: "", options: .regularExpression),
            host: host,
            port: sender.port
        )
        resolving.removeValue(forKey: sender.name)
        if !echoes.contains(echo) { echoes.append(echo) }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolving.removeValue(forKey: sender.name)
    }
}
