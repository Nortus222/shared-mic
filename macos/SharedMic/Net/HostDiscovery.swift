import Foundation

/// A Windows agent seen on the LAN (spec §12 Phase 4). `host` is whatever the
/// resolve produced — usually a dotted IP — and drops straight into the
/// pairing form's host field. Manual entry stays independent: discovery only
/// ever fills the form, never replaces it.
public struct DiscoveredHost: Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var host: String
    public var port: UInt16

    public init(name: String, host: String, port: UInt16) {
        self.name = name
        self.host = host
        self.port = port
    }
}

public protocol HostBrowserDelegate: AnyObject {
    func hostBrowser(_ browser: HostBrowser, didFind host: DiscoveredHost)
    func hostBrowser(_ browser: HostBrowser, didLoseHostNamed name: String)
}

/// Bonjour browse seam for `_sharedmic._tcp`. Tests inject a fake; the suite
/// never touches the network.
public protocol HostBrowser: AnyObject {
    var delegate: HostBrowserDelegate? { get set }
    func start()
    func stop()
}

/// Live `NetServiceBrowser` implementation. Created and driven on the main
/// thread (by `AppModel`), so all delegate callbacks already land on the
/// main run loop. Unresolvable services are dropped silently — a host that
/// cannot be resolved is indistinguishable from one that left, and the
/// manual form field is always there as fallback.
public final class BonjourHostBrowser: NSObject, HostBrowser, NetServiceBrowserDelegate, NetServiceDelegate {
    /// Must match the Windows advertiser's registration (Task 9).
    public static let serviceType = "_sharedmic._tcp."
    public static let serviceDomain = "local."
    private static let resolveTimeout: TimeInterval = 5.0

    public weak var delegate: HostBrowserDelegate?

    private let browser = NetServiceBrowser()
    private var pending: [String: NetService] = [:]
    private var running = false

    public override init() {
        super.init()
        browser.delegate = self
    }

    public func start() {
        guard !running else { return }
        running = true
        browser.searchForServices(ofType: Self.serviceType, inDomain: Self.serviceDomain)
    }

    public func stop() {
        guard running else { return }
        running = false
        browser.stop()
        for service in pending.values { service.stop() }
        pending.removeAll()
    }

    // MARK: - NetServiceBrowserDelegate

    public func netServiceBrowser(_ browser: NetServiceBrowser,
                                  didFind service: NetService,
                                  moreComing: Bool) {
        service.delegate = self
        pending[service.name] = service
        service.resolve(withTimeout: Self.resolveTimeout)
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser,
                                  didRemove service: NetService,
                                  moreComing: Bool) {
        pending.removeValue(forKey: service.name)
        service.stop()
        delegate?.hostBrowser(self, didLoseHostNamed: service.name)
    }

    // MARK: - NetServiceDelegate

    public func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = Self.displayAddress(for: sender) else { return }
        pending.removeValue(forKey: sender.name)
        delegate?.hostBrowser(self, didFind: DiscoveredHost(name: sender.name,
                                                             host: host,
                                                             port: UInt16(clamping: sender.port)))
    }

    public func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        pending.removeValue(forKey: sender.name)
    }

    /// First IPv4 address wins, then first IPv6. Anything else (or nothing)
    /// means the service is dropped — never surfaced as an unusable row.
    private static func displayAddress(for service: NetService) -> String? {
        guard let addresses = service.addresses, !addresses.isEmpty else { return nil }
        var ipv6Fallback: String?
        for data in addresses {
            let family = data.withUnsafeBytes { $0.load(as: sockaddr.self).sa_family }
            if family == sa_family_t(AF_INET),
               let text = stringForAddress(data, family: AF_INET, length: INET_ADDRSTRLEN) {
                return text
            }
            if family == sa_family_t(AF_INET6), ipv6Fallback == nil {
                ipv6Fallback = stringForAddress(data, family: AF_INET6, length: INET6_ADDRSTRLEN)
            }
        }
        return ipv6Fallback
    }

    private static func stringForAddress(_ data: Data, family: Int32, length: Int32) -> String? {
        // `inet_ntop` wants the address field, not the sockaddr: passing the
        // header reads sin_len/sin_family as address bytes.
        var buffer = [CChar](repeating: 0, count: Int(length))
        let result: UnsafePointer<CChar>?
        if family == AF_INET {
            guard data.count >= MemoryLayout<sockaddr_in>.size else { return nil }
            var addr = data.withUnsafeBytes { $0.load(as: sockaddr_in.self) }
            result = withUnsafePointer(to: &addr.sin_addr) { pointer in
                inet_ntop(family, pointer, &buffer, socklen_t(length))
            }
        } else {
            guard data.count >= MemoryLayout<sockaddr_in6>.size else { return nil }
            var addr = data.withUnsafeBytes { $0.load(as: sockaddr_in6.self) }
            result = withUnsafePointer(to: &addr.sin6_addr) { pointer in
                inet_ntop(family, pointer, &buffer, socklen_t(length))
            }
        }
        guard result != nil else { return nil }
        return String(cString: buffer)
    }
}
