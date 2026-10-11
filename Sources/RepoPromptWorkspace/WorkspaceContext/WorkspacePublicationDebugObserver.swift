import Foundation

#if DEBUG
    /// DEBUG-only hooks that let diagnostics observe workspace file publications (service delta
    /// publications, store ingress, store modifications, applied-index batches) without the
    /// workspace services depending on the diagnostics that consume them.
    package enum WorkspacePublicationDebugObserver {
        package struct Hooks {
            var servicePublication: (_ rootToken: UUID, FileSystemDeltaPublicationSource, [FileSystemDelta]) -> Void
            var publisherIngress: (_ rootID: UUID, FileSystemDeltaPublicationSource, [FileSystemDelta]) -> Void
            var storeModification: (_ rootID: UUID, _ fileID: UUID, _ generation: UInt64) -> Void
            var appliedIndexModification: (_ rootID: UUID, _ fileIDs: [UUID], _ generation: UInt64) -> Void

            package init(
                servicePublication: @escaping (_ rootToken: UUID, FileSystemDeltaPublicationSource, [FileSystemDelta]) -> Void,
                publisherIngress: @escaping (_ rootID: UUID, FileSystemDeltaPublicationSource, [FileSystemDelta]) -> Void,
                storeModification: @escaping (_ rootID: UUID, _ fileID: UUID, _ generation: UInt64) -> Void,
                appliedIndexModification: @escaping (_ rootID: UUID, _ fileIDs: [UUID], _ generation: UInt64) -> Void
            ) {
                self.servicePublication = servicePublication
                self.publisherIngress = publisherIngress
                self.storeModification = storeModification
                self.appliedIndexModification = appliedIndexModification
            }
        }

        private static let lock = NSLock()
        private nonisolated(unsafe) static var hooks: Hooks?

        /// Installs the hooks. Later installs replace the previous hooks.
        package static func install(_ hooks: Hooks) {
            lock.lock()
            self.hooks = hooks
            lock.unlock()
        }

        /// Reads the hooks under the lock; each forwarder calls them synchronously after the lock
        /// is released, so hooks may take their own locks.
        private static func installedHooks() -> Hooks? {
            lock.lock()
            defer { lock.unlock() }
            return hooks
        }

        static func servicePublication(
            rootToken: UUID,
            source: FileSystemDeltaPublicationSource,
            deltas: [FileSystemDelta]
        ) {
            installedHooks()?.servicePublication(rootToken, source, deltas)
        }

        static func publisherIngress(
            rootID: UUID,
            source: FileSystemDeltaPublicationSource,
            deltas: [FileSystemDelta]
        ) {
            installedHooks()?.publisherIngress(rootID, source, deltas)
        }

        static func storeModification(rootID: UUID, fileID: UUID, generation: UInt64) {
            installedHooks()?.storeModification(rootID, fileID, generation)
        }

        static func appliedIndexModification(rootID: UUID, fileIDs: [UUID], generation: UInt64) {
            installedHooks()?.appliedIndexModification(rootID, fileIDs, generation)
        }
    }
#endif
