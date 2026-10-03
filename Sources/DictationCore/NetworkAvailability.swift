import Darwin
import Foundation
import Network
import SystemConfiguration

@MainActor
public protocol NetworkAvailabilityProviding: AnyObject {
    var onChange: (() -> Void)? { get set }
    func isAvailable(for url: URL) -> Bool
}

@MainActor
public final class SystemNetworkAvailability: NetworkAvailabilityProviding {
    public var onChange: (() -> Void)?
    private let monitor = NWPathMonitor()
    private var lastStatus: NWPath.Status?

    public init() {
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let previous = self.lastStatus
                self.lastStatus = self.monitor.currentPath.status
                if previous != nil { self.onChange?() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "queued-dictation-network-route"))
    }
    deinit { monitor.cancel() }

    public func isAvailable(for url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        var ipv4 = in_addr()
        let isIPv4 = host.withCString { inet_pton(AF_INET, $0, &ipv4) == 1 }
        if host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || host == "[::1]"
            || (isIPv4 && UInt32(bigEndian: ipv4.s_addr) >> 24 == 127) { return true }
        // 只检查路由，不探测 HTTP 服务是否成功；LAN 可有本地路由而无互联网路径。
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        let route = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { SCNetworkReachabilityCreateWithAddress(nil, $0) }
        }
        if isReachable(route) { return true }
        return isReachable(SCNetworkReachabilityCreateWithName(nil, host))
    }

    private func isReachable(_ route: SCNetworkReachability?) -> Bool {
        guard let route else { return false }
        var flags = SCNetworkReachabilityFlags()
        guard SCNetworkReachabilityGetFlags(route, &flags), flags.contains(.reachable) else { return false }
        return !flags.contains(.connectionRequired)
            || ((flags.contains(.connectionOnDemand) || flags.contains(.connectionOnTraffic)) && !flags.contains(.interventionRequired))
    }
}
