import Foundation

package struct MCPToolObserverAttribution: Equatable {
    package let correlationPath: String
    package let scannedItemCount: Int
}

#if DEBUG
    package final class MCPToolObserverAttributionRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var attribution: MCPToolObserverAttribution?

        package init() {}

        func record(correlationPath: String, scannedItemCount: Int) {
            lock.lock()
            attribution = MCPToolObserverAttribution(
                correlationPath: correlationPath,
                scannedItemCount: max(0, scannedItemCount)
            )
            lock.unlock()
        }

        package func snapshot() -> MCPToolObserverAttribution? {
            lock.lock()
            defer { lock.unlock() }
            return attribution
        }
    }

    package enum MCPToolObserverAttributionContext {
        @TaskLocal package static var recorder: MCPToolObserverAttributionRecorder?

        static func record(correlationPath: String, scannedItemCount: Int) {
            recorder?.record(
                correlationPath: correlationPath,
                scannedItemCount: scannedItemCount
            )
        }
    }
#else
    package enum MCPToolObserverAttributionContext {
        static func record(correlationPath _: String, scannedItemCount _: Int) {}
    }
#endif
