#if os(Android)
import Foundation

// ScrobbleService wants one bit from the network stack: did we just come back
// online, so should the queue be flushed. Android answers that from
// ConnectivityManager on the Kotlin side, which calls AndroidNetworkStatus.update;
// this reproduces just enough of NWPathMonitor for the call site to stay shared.

public struct NWPath: Sendable {
    public enum Status: Sendable { case satisfied, unsatisfied }
    public let status: Status
}

public final class NWPathMonitor: @unchecked Sendable {
    public var pathUpdateHandler: ((NWPath) -> Void)?
    private var queue: DispatchQueue?

    public init() {}

    public func start(queue: DispatchQueue) {
        self.queue = queue
        AndroidNetworkStatus.register(self)
        deliver(AndroidNetworkStatus.isOnline)
    }

    public func cancel() {
        AndroidNetworkStatus.unregister(self)
        queue = nil
    }

    fileprivate func deliver(_ online: Bool) {
        let path = NWPath(status: online ? .satisfied : .unsatisfied)
        (queue ?? .main).async { [weak self] in self?.pathUpdateHandler?(path) }
    }
}

/// Until the Kotlin layer reports otherwise we assume the network is up: a wrong
/// "online" only costs a failed submit that the queue retries, while a wrong
/// "offline" would silently park every scrobble.
public enum AndroidNetworkStatus {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var monitors: [NWPathMonitor] = []
    nonisolated(unsafe) private static var online = true

    public static var isOnline: Bool {
        lock.lock(); defer { lock.unlock() }
        return online
    }

    public static func update(online newValue: Bool) {
        lock.lock()
        online = newValue
        let current = monitors
        lock.unlock()
        current.forEach { $0.deliver(newValue) }
    }

    fileprivate static func register(_ m: NWPathMonitor) {
        lock.lock(); defer { lock.unlock() }
        monitors.append(m)
    }

    fileprivate static func unregister(_ m: NWPathMonitor) {
        lock.lock(); defer { lock.unlock() }
        monitors.removeAll { $0 === m }
    }
}
#endif
