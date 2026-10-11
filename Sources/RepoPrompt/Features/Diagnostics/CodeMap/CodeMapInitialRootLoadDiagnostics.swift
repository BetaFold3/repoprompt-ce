import Foundation
import RepoPromptWorkspace

#if DEBUG
    enum CodeMapInitialRootLoadDiagnostics {
        static func start() -> Double? {
            WorkspaceRestorePerfLog.timestampMSIfEnabled()
        }

        static func cacheRebuild(rootCount: Int, requestCount: Int, startMS: Double?) {
            WorkspaceRestorePerfLog.event(
                "codemap.initialRootLoad.cacheRebuild",
                fields: [
                    "rootCount": "\(rootCount)",
                    "requestCount": "\(requestCount)",
                    "duration": durationField(since: startMS)
                ]
            )
        }

        static func cacheCheck(requestCount: Int, queueableRequests: Int, droppedRequests: Int, startMS: Double?) {
            WorkspaceRestorePerfLog.event(
                "codemap.initialRootLoad.cacheCheck",
                fields: [
                    "requestCount": "\(requestCount)",
                    "queueableRequests": "\(queueableRequests)",
                    "droppedRequests": "\(droppedRequests)",
                    "duration": durationField(since: startMS)
                ]
            )
        }

        static func prune(rootCount: Int, startMS: Double?) {
            WorkspaceRestorePerfLog.event(
                "codemap.initialRootLoad.prune",
                fields: [
                    "rootCount": "\(rootCount)",
                    "duration": durationField(since: startMS)
                ]
            )
        }

        static func enqueue(queueableRequests: Int, startMS: Double?) {
            WorkspaceRestorePerfLog.event(
                "codemap.initialRootLoad.enqueue",
                fields: [
                    "queueableRequests": "\(queueableRequests)",
                    "duration": durationField(since: startMS)
                ]
            )
        }

        private static func durationField(since startMS: Double?) -> String {
            startMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
        }
    }
#endif
