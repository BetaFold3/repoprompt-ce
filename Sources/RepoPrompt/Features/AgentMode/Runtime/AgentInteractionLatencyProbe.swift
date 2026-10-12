import Foundation

#if DEBUG || EDIT_FLOW_PERF
    import os

    /// Diagnostic identity of the user action that began an interaction.
    struct AgentInteractionLatencyAction: Equatable {
        let id: UUID
        let kind: AgentInteractionLatencyLedger.Kind
        let windowID: Int

        /// Bound only by `AgentInteractionLatencyProbe.run(as:_:)` inside the action's own Task.
        @TaskLocal static var current: AgentInteractionLatencyAction?
    }

    /// D0 interaction timing for Agent Mode (see
    /// `docs/context/plans/2026-10-12-agent-mode-transcript-refresh-performance-spec.md`).
    ///
    /// Two interactions are tracked, at most one pending of each kind:
    /// - **Tab activation:** sidebar click → VM tab-change handler → derived-transcript
    ///   refresh → first `publishTranscriptPresentation` for the target tab → SwiftUI
    ///   observing that presentation.
    /// - **New session:** new-session action → composer focus request → the composer text
    ///   view confirmed as first responder of the key window while it carries that
    ///   request's token.
    ///
    /// Marker honesty:
    /// - `tabActivation.firstPublish` means the VM assigned the target tab's presentation
    ///   snapshot. The UI store may update after an enclosing UI-sync suppression ends.
    /// - `tabActivation.presentationObservedBySwiftUI` means a SwiftUI `onChange`/`onAppear`
    ///   callback saw that revision during a view update. It is **not** frame or pixel
    ///   completion; leave real on-screen timing to Instruments (Hitches / SwiftUI).
    /// - `newSession.composerReady` means AppKit reported the composer text view as the key
    ///   window's first responder while the view carried the matching token. The `via` field
    ///   names the path that observed it (token attempt, responder change, or a view update).
    ///
    /// Stage timing on `tabActivation.firstPublish` (fields absent when not measured):
    /// - `queueWaitMS`: click → the click's own Task started running (scheduling wait only).
    /// - `clickToWorkStartMS` / `handlerToWorkStartMS`: click / handler → first refresh or
    ///   publication work for the tab; includes synchronous pre-work and asynchronous cold
    ///   session preparation, not just scheduling delay.
    /// - `refreshPath`: `applyBindings` when the active-binding catch-up refresh ran (the only
    ///   timed refresh), otherwise `none`.
    ///
    /// Attribution:
    /// - A tab activation is owned by the window that began it; other windows' tab changes and
    ///   milestones never advance or cancel it.
    /// - Each `begin*` returns an `AgentInteractionLatencyAction` that the action binds as a
    ///   task-local around its own asynchronous work. Callbacks reached synchronously from that
    ///   work (the `.activeComposeTabChanged` sink, composer focus requests) read it, so a
    ///   superseded action's late callbacks neither rebind nor cancel the current interaction.
    ///   Milestones carrying a superseded click's action are dropped even for the same tab, so a
    ///   repeat click whose own switch is a no-op records no stages and expires or is superseded.
    /// - Only the click's own handler (entered under its action) establishes ownership. Before
    ///   that, refresh and publication work without the click's action is ignored, so unrelated
    ///   streaming or derived refreshes never stamp or complete a click. Actionless SwiftUI
    ///   observation still completes a click after its owned first publish.
    ///
    /// Only UUIDs, revisions, durations and static labels are recorded; never payload text.
    /// No scheduling is introduced: stale interactions expire lazily on the next probe call.
    struct AgentInteractionLatencyLedger {
        enum Kind: String, Equatable {
            case tabActivation
            case newSession
        }

        enum Phase: Equatable {
            case begin
            case milestone
            case terminal
        }

        struct Event: Equatable {
            let interactionID: UUID
            let kind: Kind
            let name: String
            let phase: Phase
            let tabID: UUID?
            let elapsedMS: Double
            let fields: [String: String]
        }

        static let maxPendingAgeNanoseconds: UInt64 = 30_000_000_000

        private struct Activation {
            let id: UUID
            let tabID: UUID
            let windowID: Int
            let source: String
            let startNS: UInt64
            var lastMilestone = "begin"
            var taskEntryNS: UInt64?
            var handlerNS: UInt64?
            var refreshBeganNS: UInt64?
            var refreshEndedNS: UInt64?
            var didRefresh: Bool?
            var publishBeganNS: UInt64?
            var firstPublishAttemptNS: UInt64?
            var publishSkipCount = 0
            var firstPublishNS: UInt64?
            var firstPublishRevision: Int?
        }

        private struct NewSession {
            let id: UUID
            let source: String
            let startNS: UInt64
            var lastMilestone = "begin"
            var requestID: UUID?
            var tabID: UUID?
            var requestedNS: UInt64?
            var tokenAppliedNS: UInt64?
        }

        private var activation: Activation?
        private var newSession: NewSession?

        var hasPendingInteraction: Bool {
            activation != nil || newSession != nil
        }

        var isAwaitingComposerFocus: Bool {
            newSession?.requestID != nil
        }

        var pendingInteractionCount: Int {
            (activation == nil ? 0 : 1) + (newSession == nil ? 0 : 1)
        }

        // MARK: Tab activation

        mutating func beginTabActivation(
            tabID: UUID,
            windowID: Int,
            source: String,
            interactionID: UUID = UUID(),
            now: UInt64
        ) -> [Event] {
            var events = expireStale(now: now)
            if let previous = activation {
                events.append(event(previous, name: "tabActivation.superseded", phase: .terminal, now: now))
            }
            let next = Activation(id: interactionID, tabID: tabID, windowID: windowID, source: source, startNS: now)
            activation = next
            events.append(event(next, name: "tabActivation.begin", phase: .begin, now: now))
            return events
        }

        /// `action` is the task-local action whose work reached the handler, if any.
        mutating func tabActivationHandlerEntered(
            tabID: UUID,
            windowID: Int,
            action: AgentInteractionLatencyAction?,
            now: UInt64
        ) -> [Event] {
            var events = expireStale(now: now)
            guard var pending = activation, pending.windowID == windowID else { return events }
            let isOwnAction = action.map { $0.kind == .tabActivation && $0.id == pending.id } ?? false
            // A superseded click's delayed switch neither advances nor cancels this one.
            if let action, action.kind == .tabActivation, !isOwnAction { return events }
            guard pending.tabID == tabID else {
                // Another tab of this window became active first (new session, shortcut,
                // deep link): this click can no longer produce a first publish.
                activation = nil
                events.append(event(
                    pending,
                    name: "tabActivation.retargeted",
                    phase: .terminal,
                    now: now,
                    extra: ["retargetTabID": Self.shortID(tabID)]
                ))
                return events
            }
            // Only the click's own switch establishes ownership; an actionless handler for the
            // same tab (activation bootstrap, deferred workspace load) does not.
            guard isOwnAction, pending.handlerNS == nil, pending.firstPublishNS == nil else { return events }
            pending.handlerNS = now
            pending.lastMilestone = "handlerEntered"
            activation = pending
            events.append(event(pending, name: "tabActivation.handlerEntered", phase: .milestone, now: now))
            return events
        }

        /// The click's own Task began running; `queueWaitMS` ends here. No event.
        mutating func tabActivationTaskEntered(actionID: UUID, now: UInt64) -> [Event] {
            let events = expireStale(now: now)
            guard var pending = activation, pending.id == actionID, pending.taskEntryNS == nil else {
                return events
            }
            pending.taskEntryNS = now
            pending.lastMilestone = "taskEntered"
            activation = pending
            return events
        }

        /// Refresh, loading and publication milestones. Work under a tab-activation action counts
        /// only when it is the pending click's own (Tasks a superseded click spawned inherit its
        /// task-local and are dropped). Work without one (streaming, scheduled refreshes,
        /// main-queue callbacks) counts only after the click's own handler established ownership.
        func acceptsTabActivationWork(from action: AgentInteractionLatencyAction?) -> Bool {
            guard let pending = activation else { return false }
            if let action, action.kind == .tabActivation {
                return action.id == pending.id
            }
            return pending.handlerNS != nil
        }

        /// SwiftUI observation carries no action and completes a click only after its owned
        /// first publish; a superseded click's action is still dropped.
        func acceptsTabActivationObservation(from action: AgentInteractionLatencyAction?) -> Bool {
            guard let action, action.kind == .tabActivation else { return true }
            return action.id == activation?.id
        }

        mutating func transcriptRefreshBegan(tabID: UUID, windowID: Int, now: UInt64) -> [Event] {
            let events = expireStale(now: now)
            guard var pending = activation, pending.windowID == windowID, pending.tabID == tabID,
                  pending.firstPublishNS == nil, pending.refreshBeganNS == nil
            else { return events }
            pending.refreshBeganNS = now
            pending.lastMilestone = "refreshBegan"
            activation = pending
            return events
        }

        mutating func transcriptRefreshEnded(tabID: UUID, windowID: Int, didRefresh: Bool, now: UInt64) -> [Event] {
            let events = expireStale(now: now)
            guard var pending = activation, pending.windowID == windowID, pending.tabID == tabID,
                  pending.refreshBeganNS != nil, pending.refreshEndedNS == nil
            else { return events }
            pending.refreshEndedNS = now
            pending.didRefresh = didRefresh
            if pending.firstPublishNS == nil {
                pending.lastMilestone = "refreshEnded"
            }
            activation = pending
            return events
        }

        /// No event: only explains where an expired or superseded activation stalled.
        mutating func loadingPresentationPublished(tabID: UUID?, windowID: Int, now: UInt64) -> [Event] {
            let events = expireStale(now: now)
            guard let tabID, var pending = activation, pending.windowID == windowID, pending.tabID == tabID,
                  pending.firstPublishNS == nil
            else {
                return events
            }
            pending.lastMilestone = "loadingPublished"
            activation = pending
            return events
        }

        /// No event: counts no-op publish attempts before the first assignment.
        mutating func transcriptPublishSkipped(tabID: UUID, windowID: Int, now: UInt64) -> [Event] {
            let events = expireStale(now: now)
            guard var pending = activation, pending.windowID == windowID, pending.tabID == tabID,
                  pending.firstPublishNS == nil
            else {
                return events
            }
            pending.publishSkipCount += 1
            activation = pending
            return events
        }

        mutating func transcriptPublishBegan(tabID: UUID, windowID: Int, now: UInt64) -> [Event] {
            let events = expireStale(now: now)
            guard var pending = activation, pending.windowID == windowID, pending.tabID == tabID,
                  pending.firstPublishNS == nil
            else {
                return events
            }
            // Queue wait ends at the first attempt, including a no-op publication.
            if pending.firstPublishAttemptNS == nil { pending.firstPublishAttemptNS = now }
            // Latest attempt wins, so publishMS covers only the publish that assigned.
            pending.publishBeganNS = now
            activation = pending
            return events
        }

        mutating func transcriptPublished(
            tabID: UUID,
            windowID: Int,
            revision: Int,
            contentChanged: Bool,
            now: UInt64
        ) -> [Event] {
            var events = expireStale(now: now)
            guard var pending = activation, pending.windowID == windowID, pending.tabID == tabID,
                  pending.firstPublishNS == nil
            else {
                return events
            }
            pending.firstPublishNS = now
            pending.firstPublishRevision = revision
            pending.lastMilestone = "firstPublish"
            activation = pending

            var extra: [String: String] = [
                "revision": String(revision),
                "contentChanged": String(contentChanged),
                "publishSkipCount": String(pending.publishSkipCount)
            ]
            if let handlerNS = pending.handlerNS {
                extra["clickToHandlerMS"] = Self.formatMS(Self.ms(from: pending.startNS, to: handlerNS))
            }
            // Scheduling wait only: click until the click's own Task began running.
            if let taskEntryNS = pending.taskEntryNS {
                extra["queueWaitMS"] = Self.formatMS(Self.ms(from: pending.startNS, to: taskEntryNS))
            }
            // Click (and handler) until derivation or publication work for this tab begins,
            // including synchronous pre-work in between.
            if let workStart = [pending.refreshBeganNS, pending.firstPublishAttemptNS].compactMap(\.self).min() {
                extra["clickToWorkStartMS"] = Self.formatMS(Self.ms(from: pending.startNS, to: workStart))
                if let handlerNS = pending.handlerNS {
                    extra["handlerToWorkStartMS"] = Self.formatMS(Self.ms(from: handlerNS, to: workStart))
                }
            }
            extra["refreshPath"] = pending.refreshBeganNS == nil ? "none" : "applyBindings"
            if let refreshBegan = pending.refreshBeganNS {
                if let refreshEnded = pending.refreshEndedNS {
                    extra["refreshMS"] = Self.formatMS(Self.ms(from: refreshBegan, to: refreshEnded))
                    extra["didRefresh"] = String(pending.didRefresh ?? false)
                } else {
                    // The refresh published from inside itself.
                    extra["refreshUntilPublishMS"] = Self.formatMS(Self.ms(from: refreshBegan, to: now))
                }
            }
            if let publishBegan = pending.publishBeganNS {
                extra["publishMS"] = Self.formatMS(Self.ms(from: publishBegan, to: now))
            }
            events.append(event(pending, name: "tabActivation.firstPublish", phase: .milestone, now: now, extra: extra))
            return events
        }

        mutating func transcriptPresentationObservedBySwiftUI(
            tabID: UUID?,
            windowID: Int,
            revision: Int,
            now: UInt64
        ) -> [Event] {
            var events = expireStale(now: now)
            guard let tabID, let pending = activation, pending.windowID == windowID, pending.tabID == tabID,
                  let publishNS = pending.firstPublishNS,
                  let publishedRevision = pending.firstPublishRevision,
                  revision >= publishedRevision
            else { return events }
            activation = nil
            events.append(event(
                pending,
                name: "tabActivation.presentationObservedBySwiftUI",
                phase: .terminal,
                now: now,
                extra: [
                    "revision": String(revision),
                    "firstPublishMS": Self.formatMS(Self.ms(from: pending.startNS, to: publishNS)),
                    "publishToObservedMS": Self.formatMS(Self.ms(from: publishNS, to: now))
                ]
            ))
            return events
        }

        // MARK: New session

        mutating func beginNewSession(
            source: String,
            interactionID: UUID = UUID(),
            now: UInt64
        ) -> [Event] {
            var events = expireStale(now: now)
            if let previous = newSession {
                events.append(event(previous, name: "newSession.superseded", phase: .terminal, now: now))
            }
            let next = NewSession(id: interactionID, source: source, startNS: now)
            newSession = next
            events.append(event(next, name: "newSession.begin", phase: .begin, now: now))
            return events
        }

        /// Binds only a request made by the pending interaction's own action (`action`), so a
        /// superseded or unrelated action's request never rebinds it.
        mutating func composerFocusRequested(
            requestID: UUID,
            tabID: UUID,
            action: AgentInteractionLatencyAction?,
            now: UInt64
        ) -> [Event] {
            var events = expireStale(now: now)
            guard var pending = newSession, let action, action.kind == .newSession, action.id == pending.id else {
                return events
            }
            // The action's newest request owns the interaction; older tokens are ignored afterwards.
            pending.requestID = requestID
            pending.tabID = tabID
            pending.requestedNS = now
            pending.tokenAppliedNS = nil
            pending.lastMilestone = "focusRequested"
            newSession = pending
            events.append(event(pending, name: "newSession.focusRequested", phase: .milestone, now: now))
            return events
        }

        /// The input bar handed the token to the text field. This is not readiness.
        mutating func composerFocusTokenApplied(requestID: UUID, now: UInt64) -> [Event] {
            let events = expireStale(now: now)
            guard var pending = newSession, pending.requestID == requestID, pending.tokenAppliedNS == nil else {
                return events
            }
            pending.tokenAppliedNS = now
            pending.lastMilestone = "focusTokenApplied"
            newSession = pending
            return events
        }

        /// Callers must have confirmed key-window first-responder status for a view
        /// carrying `token`.
        mutating func composerFocusAcknowledged(token: UUID, via: String, now: UInt64) -> [Event] {
            var events = expireStale(now: now)
            guard let pending = newSession, pending.requestID == token else { return events }
            newSession = nil
            var extra: [String: String] = ["via": via]
            if let requestedNS = pending.requestedNS {
                extra["actionToRequestMS"] = Self.formatMS(Self.ms(from: pending.startNS, to: requestedNS))
                extra["requestToReadyMS"] = Self.formatMS(Self.ms(from: requestedNS, to: now))
            }
            if let appliedNS = pending.tokenAppliedNS {
                extra["tokenAppliedToReadyMS"] = Self.formatMS(Self.ms(from: appliedNS, to: now))
            }
            events.append(event(pending, name: "newSession.composerReady", phase: .terminal, now: now, extra: extra))
            return events
        }

        // MARK: Helpers

        private mutating func expireStale(now: UInt64) -> [Event] {
            var events: [Event] = []
            if let pending = activation, now &- pending.startNS > Self.maxPendingAgeNanoseconds {
                activation = nil
                events.append(event(pending, name: "tabActivation.expired", phase: .terminal, now: now))
            }
            if let pending = newSession, now &- pending.startNS > Self.maxPendingAgeNanoseconds {
                newSession = nil
                events.append(event(pending, name: "newSession.expired", phase: .terminal, now: now))
            }
            return events
        }

        private func event(
            _ pending: Activation,
            name: String,
            phase: Phase,
            now: UInt64,
            extra: [String: String] = [:]
        ) -> Event {
            Event(
                interactionID: pending.id,
                kind: .tabActivation,
                name: name,
                phase: phase,
                tabID: pending.tabID,
                elapsedMS: Self.ms(from: pending.startNS, to: now),
                fields: Self.fields(extra, source: pending.source, phase: phase, lastMilestone: pending.lastMilestone)
            )
        }

        private func event(
            _ pending: NewSession,
            name: String,
            phase: Phase,
            now: UInt64,
            extra: [String: String] = [:]
        ) -> Event {
            Event(
                interactionID: pending.id,
                kind: .newSession,
                name: name,
                phase: phase,
                tabID: pending.tabID,
                elapsedMS: Self.ms(from: pending.startNS, to: now),
                fields: Self.fields(extra, source: pending.source, phase: phase, lastMilestone: pending.lastMilestone)
            )
        }

        private static func fields(
            _ extra: [String: String],
            source: String,
            phase: Phase,
            lastMilestone: String
        ) -> [String: String] {
            var fields = extra
            fields["source"] = source
            if phase == .terminal {
                fields["lastMilestone"] = lastMilestone
            }
            return fields
        }

        static func ms(from start: UInt64, to end: UInt64) -> Double {
            guard end >= start else { return 0 }
            return Double(end - start) / 1_000_000
        }

        static func formatMS(_ value: Double) -> String {
            String(format: "%.1f", value)
        }

        static func shortID(_ id: UUID?) -> String {
            id.map { String($0.uuidString.prefix(8)) } ?? "nil"
        }
    }

    /// Main-actor façade: gates, timestamps, and emits ledger events as `os_signpost`
    /// intervals and events (subsystem `com.repoprompt.agent-perf`, category `interaction`)
    /// and, in DEBUG, mirrors them to `AgentModePerfDiagnostics` (`agent_perf_metrics`).
    ///
    /// Only `begin*` calls check enablement. Every other hook returns immediately when no
    /// interaction is pending, so hot paths such as publish stay near zero cost.
    @MainActor
    enum AgentInteractionLatencyProbe {
        private static let signposter = OSSignposter(subsystem: "com.repoprompt.agent-perf", category: "interaction")
        private static var ledger = AgentInteractionLatencyLedger()
        /// Open intervals by interaction; milestones reuse the interval's signpost ID.
        private static var intervals: [UUID: (id: OSSignpostID, state: OSSignpostIntervalState)] = [:]

        #if DEBUG
            static var enabledOverrideForTesting: Bool?
            static var eventSinkForTesting: ((AgentInteractionLatencyLedger.Event) -> Void)?
            static var nowOverrideForTesting: (() -> UInt64)?

            static func resetForTesting() {
                ledger = AgentInteractionLatencyLedger()
                intervals.removeAll()
                enabledOverrideForTesting = nil
                eventSinkForTesting = nil
                nowOverrideForTesting = nil
            }

            static var pendingInteractionCountForTesting: Int {
                ledger.pendingInteractionCount
            }
        #endif

        static var isEnabled: Bool {
            #if DEBUG
                if let enabledOverrideForTesting {
                    return enabledOverrideForTesting
                }
                return EditFlowPerf.isEnabled || AgentModePerfDiagnostics.isEnabled
            #else
                return EditFlowPerf.isEnabled
            #endif
        }

        /// Cheap pre-check for per-update composer observation.
        static var isAwaitingComposerFocus: Bool {
            ledger.isAwaitingComposerFocus
        }

        // MARK: Begin (enablement-gated)

        /// Returns the action to bind with `run(as:_:)` around the click's asynchronous switch,
        /// or nil when disabled.
        @discardableResult
        static func beginTabActivation(tabID: UUID, windowID: Int, source: StaticString) -> AgentInteractionLatencyAction? {
            guard isEnabled else { return nil }
            let action = AgentInteractionLatencyAction(id: UUID(), kind: .tabActivation, windowID: windowID)
            emit(ledger.beginTabActivation(
                tabID: tabID,
                windowID: windowID,
                source: String(describing: source),
                interactionID: action.id,
                now: now()
            ))
            return action
        }

        /// Returns the action to bind with `run(as:_:)` around session creation, or nil when disabled.
        @discardableResult
        static func beginNewSession(windowID: Int, source: StaticString) -> AgentInteractionLatencyAction? {
            guard isEnabled else { return nil }
            let action = AgentInteractionLatencyAction(id: UUID(), kind: .newSession, windowID: windowID)
            emit(ledger.beginNewSession(source: String(describing: source), interactionID: action.id, now: now()))
            return action
        }

        /// Runs `operation` with `action` as the task-local current action. Call it inside the
        /// action's own Task so synchronous callbacks reached from that work can attribute
        /// themselves; it adds no scheduling.
        /// For a tab activation, also stamps the Task's entry (end of `queueWaitMS`).
        static func run(as action: AgentInteractionLatencyAction?, _ operation: () async -> Void) async {
            guard let action else { return await operation() }
            if action.kind == .tabActivation, ledger.hasPendingInteraction {
                emit(ledger.tabActivationTaskEntered(actionID: action.id, now: now()))
            }
            await AgentInteractionLatencyAction.$current.withValue(action, operation: operation)
        }

        // MARK: Tab activation milestones (VM hooks)

        /// See `AgentInteractionLatencyLedger.acceptsTabActivationWork(from:)`.
        private static var acceptsCurrentWork: Bool {
            ledger.acceptsTabActivationWork(from: AgentInteractionLatencyAction.current)
        }

        static func tabActivationHandlerEntered(tabID: UUID, windowID: Int) {
            guard ledger.hasPendingInteraction else { return }
            emit(ledger.tabActivationHandlerEntered(
                tabID: tabID,
                windowID: windowID,
                action: AgentInteractionLatencyAction.current,
                now: now()
            ))
        }

        static func transcriptRefreshBegan(tabID: UUID, windowID: Int) {
            guard ledger.hasPendingInteraction, acceptsCurrentWork else { return }
            emit(ledger.transcriptRefreshBegan(tabID: tabID, windowID: windowID, now: now()))
        }

        static func transcriptRefreshEnded(tabID: UUID, windowID: Int, didRefresh: Bool) {
            guard ledger.hasPendingInteraction, acceptsCurrentWork else { return }
            emit(ledger.transcriptRefreshEnded(tabID: tabID, windowID: windowID, didRefresh: didRefresh, now: now()))
        }

        static func loadingPresentationPublished(tabID: UUID?, windowID: Int) {
            guard ledger.hasPendingInteraction, acceptsCurrentWork else { return }
            emit(ledger.loadingPresentationPublished(tabID: tabID, windowID: windowID, now: now()))
        }

        static func transcriptPublishSkipped(tabID: UUID, windowID: Int) {
            guard ledger.hasPendingInteraction, acceptsCurrentWork else { return }
            emit(ledger.transcriptPublishSkipped(tabID: tabID, windowID: windowID, now: now()))
        }

        static func transcriptPublishBegan(tabID: UUID, windowID: Int) {
            guard ledger.hasPendingInteraction, acceptsCurrentWork else { return }
            emit(ledger.transcriptPublishBegan(tabID: tabID, windowID: windowID, now: now()))
        }

        static func transcriptPublished(tabID: UUID, windowID: Int, revision: Int, contentChanged: Bool) {
            guard ledger.hasPendingInteraction, acceptsCurrentWork else { return }
            emit(ledger.transcriptPublished(
                tabID: tabID,
                windowID: windowID,
                revision: revision,
                contentChanged: contentChanged,
                now: now()
            ))
        }

        /// SwiftUI view-update observation; not frame or pixel completion.
        static func transcriptPresentationObservedBySwiftUI(tabID: UUID?, windowID: Int, revision: Int) {
            guard ledger.hasPendingInteraction,
                  ledger.acceptsTabActivationObservation(from: AgentInteractionLatencyAction.current)
            else { return }
            emit(ledger.transcriptPresentationObservedBySwiftUI(
                tabID: tabID,
                windowID: windowID,
                revision: revision,
                now: now()
            ))
        }

        // MARK: New-session milestones (UUID-only)

        static func composerFocusRequested(requestID: UUID, tabID: UUID) {
            guard ledger.hasPendingInteraction else { return }
            emit(ledger.composerFocusRequested(
                requestID: requestID,
                tabID: tabID,
                action: AgentInteractionLatencyAction.current,
                now: now()
            ))
        }

        static func composerFocusTokenApplied(requestID: UUID) {
            guard ledger.isAwaitingComposerFocus else { return }
            emit(ledger.composerFocusTokenApplied(requestID: requestID, now: now()))
        }

        /// Callers must have confirmed `window.isKeyWindow` and `window.firstResponder === textView`
        /// for the text view whose current token is `token`.
        static func composerFocusAcknowledged(token: UUID, via: StaticString) {
            guard ledger.isAwaitingComposerFocus else { return }
            emit(ledger.composerFocusAcknowledged(token: token, via: String(describing: via), now: now()))
        }

        // MARK: Emission

        private static func now() -> UInt64 {
            #if DEBUG
                if let nowOverrideForTesting {
                    return nowOverrideForTesting()
                }
            #endif
            return DispatchTime.now().uptimeNanoseconds
        }

        private static func emit(_ events: [AgentInteractionLatencyLedger.Event]) {
            for event in events {
                emitSignpost(event)
                #if DEBUG
                    eventSinkForTesting?(event)
                    var fields = event.fields
                    fields["interactionID"] = AgentInteractionLatencyLedger.shortID(event.interactionID)
                    fields["elapsedMS"] = AgentInteractionLatencyLedger.formatMS(event.elapsedMS)
                    AgentModePerfDiagnostics.event("interaction.\(event.name)", tabID: event.tabID, fields: fields)
                #endif
            }
        }

        private static func emitSignpost(_ event: AgentInteractionLatencyLedger.Event) {
            let message = renderedMessage(event)
            switch event.phase {
            case .begin:
                let id = signposter.makeSignpostID()
                let state: OSSignpostIntervalState = switch event.kind {
                case .tabActivation:
                    signposter.beginInterval("AgentTabActivation", id: id, "\(message, privacy: .public)")
                case .newSession:
                    signposter.beginInterval("AgentNewSession", id: id, "\(message, privacy: .public)")
                }
                intervals[event.interactionID] = (id, state)
            case .milestone:
                if let interval = intervals[event.interactionID] {
                    signposter.emitEvent("AgentInteractionMilestone", id: interval.id, "\(message, privacy: .public)")
                } else {
                    signposter.emitEvent("AgentInteractionMilestone", "\(message, privacy: .public)")
                }
            case .terminal:
                guard let interval = intervals.removeValue(forKey: event.interactionID) else {
                    signposter.emitEvent("AgentInteractionMilestone", "\(message, privacy: .public)")
                    return
                }
                switch event.kind {
                case .tabActivation:
                    signposter.endInterval("AgentTabActivation", interval.state, "\(message, privacy: .public)")
                case .newSession:
                    signposter.endInterval("AgentNewSession", interval.state, "\(message, privacy: .public)")
                }
            }
        }

        private static func renderedMessage(_ event: AgentInteractionLatencyLedger.Event) -> String {
            let fields = event.fields
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            return "\(event.name) id=\(AgentInteractionLatencyLedger.shortID(event.interactionID)) "
                + "tab=\(AgentInteractionLatencyLedger.shortID(event.tabID)) "
                + "elapsedMS=\(AgentInteractionLatencyLedger.formatMS(event.elapsedMS)) \(fields)"
        }
    }
#endif
