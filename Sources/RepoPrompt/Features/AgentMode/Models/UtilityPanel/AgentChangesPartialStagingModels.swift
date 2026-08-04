import Foundation

/// Direction of an index-only partial mutation.
enum AgentChangesPartialAction: Equatable {
    case stage
    case unstage
}

/// Stable coordinate of one changed projected line.
enum AgentChangesDiffLineKey: Equatable, Hashable {
    case addition(newLine: Int)
    case deletion(oldLine: Int)
}

/// Opaque proof that the repository returned the exact visible patch being acted on.
///
/// Callers carry the token back unchanged. Its UUID is only a lookup key; all authority remains in
/// the repository's private artifact, which binds the bytes, target, revision, and visible lines.
struct AgentChangesPatchReviewToken: Equatable, Hashable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

enum AgentChangesPartialStagingUnavailableReason: Equatable {
    case readOnlyCompare
    case backendHasNoIndex
    case unsafeScope
    case conflicted
    case untrackedRequiresWholeFile
    case addedOrDeletedFile
    case structuralChange
    case binaryOrSubmodule
    case truncatedProjection
    case rawPatchUnavailable
    case malformedPatch
}

enum AgentChangesPartialStagingAvailability: Equatable {
    case available
    case unavailable(AgentChangesPartialStagingUnavailableReason)
}

/// The partial controls that are safe for one visible row/document pair.
///
/// `selectableChangedLineKeys` is deliberately a subset of `changedLineKeysByHunkID`'s union: a hunk
/// whose patch carries a `\ No newline at end of file` annotation keeps its reviewed line set (so the
/// hunk action still replays its bytes verbatim) while offering no per-line selection.
struct AgentChangesPartialStagingDescriptor: Equatable {
    let action: AgentChangesPartialAction?
    let reviewToken: AgentChangesPatchReviewToken?
    let selectableChangedLineKeys: Set<AgentChangesDiffLineKey>
    let changedLineKeysByHunkID: [String: Set<AgentChangesDiffLineKey>]
    let availability: AgentChangesPartialStagingAvailability

    static func unavailable(
        _ reason: AgentChangesPartialStagingUnavailableReason,
        action: AgentChangesPartialAction? = nil
    ) -> AgentChangesPartialStagingDescriptor {
        AgentChangesPartialStagingDescriptor(
            action: action,
            reviewToken: nil,
            selectableChangedLineKeys: [],
            changedLineKeysByHunkID: [:],
            availability: .unavailable(reason)
        )
    }
}

/// One hunk-scoped user selection.
///
/// A hunk request carries the hunk's complete reviewed line set. The repository verifies that set
/// against its token artifact rather than trusting the caller's label.
enum AgentChangesPartialMutationSelection: Equatable {
    case hunk(projectedHunkID: String, lines: Set<AgentChangesDiffLineKey>)
    case lines(projectedHunkID: String, lines: Set<AgentChangesDiffLineKey>)

    var projectedHunkID: String {
        switch self {
        case let .hunk(projectedHunkID, _), let .lines(projectedHunkID, _):
            projectedHunkID
        }
    }

    var lines: Set<AgentChangesDiffLineKey> {
        switch self {
        case let .hunk(_, lines), let .lines(_, lines):
            lines
        }
    }

    var selectsWholeHunk: Bool {
        if case .hunk = self { return true }
        return false
    }
}

/// A token-bound partial mutation request.
///
/// There is deliberately no stage/unstage Boolean. The repository derives direction from the
/// token's reviewed section, so a staged HEAD→index patch cannot accidentally be applied forward.
struct AgentChangesPartialMutationRequest: Equatable {
    let reviewToken: AgentChangesPatchReviewToken
    let rowID: String
    let fileKey: String
    let identity: VCSIndexPathIdentity
    let section: AgentChangesSectionKind
    let expectedContentRevision: UInt64
    let selection: AgentChangesPartialMutationSelection

    init(
        reviewToken: AgentChangesPatchReviewToken,
        row: AgentChangesFileRow,
        selection: AgentChangesPartialMutationSelection
    ) {
        self.reviewToken = reviewToken
        rowID = row.id
        fileKey = row.fileKey
        identity = row.identity
        section = row.section
        expectedContentRevision = row.contentRevision
        self.selection = selection
    }

    init(
        reviewToken: AgentChangesPatchReviewToken,
        rowID: String,
        fileKey: String,
        identity: VCSIndexPathIdentity,
        section: AgentChangesSectionKind,
        expectedContentRevision: UInt64,
        selection: AgentChangesPartialMutationSelection
    ) {
        self.reviewToken = reviewToken
        self.rowID = rowID
        self.fileKey = fileKey
        self.identity = identity
        self.section = section
        self.expectedContentRevision = expectedContentRevision
        self.selection = selection
    }
}
