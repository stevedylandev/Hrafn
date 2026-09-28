import Foundation
import Network

/// The network as far as reconnection cares: usable or not, and over what.
public struct NetworkPath: Sendable, Hashable {
    public var isSatisfied: Bool
    /// Names of the interfaces in use. A change (Wi-Fi to cellular) leaves the
    /// path satisfied but usually kills existing TCP connections silently.
    public var interfaces: [String]

    public init(isSatisfied: Bool, interfaces: [String] = []) {
        self.isSatisfied = isSatisfied
        self.interfaces = interfaces
    }
}

public protocol NetworkPathMonitor: Sendable {
    /// Path updates, starting with the current path. Each call is a fresh
    /// subscription; it ends when the consuming task is cancelled.
    func paths() -> AsyncStream<NetworkPath>
}

/// `NWPathMonitor`, one per subscription.
public struct SystemPathMonitor: NetworkPathMonitor {
    public init() {}

    public func paths() -> AsyncStream<NetworkPath> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                continuation.yield(NetworkPath(isSatisfied: path.status == .satisfied,
                                               interfaces: path.availableInterfaces.map(\.name)))
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "hrafn.path-monitor"))
        }
    }
}
