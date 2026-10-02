import Foundation

/// Tracks delivery at the app's last point before handing a tool result to the SDK transport.
/// Finishing successfully commits attached reservations; every other exit releases them.
final class MCPToolResultDeliveryTransaction: @unchecked Sendable {
    private let lock = NSLock()
    private var delivered: Bool?
    private var handlers: [@Sendable (Bool) -> Void] = []

    func onFinish(_ handler: @escaping @Sendable (_ delivered: Bool) -> Void) {
        lock.lock()
        if let delivered {
            lock.unlock()
            handler(delivered)
        } else {
            handlers.append(handler)
            lock.unlock()
        }
    }

    /// The first finish wins. Callbacks run outside the lock and may register more callbacks.
    func finish(delivered: Bool) {
        lock.lock()
        guard self.delivered == nil else {
            lock.unlock()
            return
        }
        self.delivered = delivered
        let handlers = handlers
        self.handlers.removeAll()
        lock.unlock()

        for handler in handlers {
            handler(delivered)
        }
    }
}
