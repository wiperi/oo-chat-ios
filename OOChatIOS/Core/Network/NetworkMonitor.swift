import Foundation
import Network

protocol NetworkPathMonitoring: AnyObject {
    var onUpdate: (@MainActor (Bool) -> Void)? { get set }
    func start()
    func cancel()
}

final class NetworkMonitor: NetworkPathMonitoring {
    var onUpdate: (@MainActor (Bool) -> Void)?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "connectonion.native-ios.network-monitor")

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let isOnline = path.status == .satisfied
            Task { @MainActor in
                self?.onUpdate?(isOnline)
            }
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.cancel()
    }
}
