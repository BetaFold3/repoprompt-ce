import Foundation

enum CodexForkStructuralVerificationError: Error, Equatable {
    case repeatedCursor(String)
    case duplicateTurnID(String)
    case blankTurnID
    case incompletePagination
    case ledgerDoesNotEndAtCheckpoint
    case ledgerNotOrderedSubsequence
    case checkpointMissing
    case checkpointNotCompleted
    case inProgressTurn(String)
    case invalidChildThreadID
    case childMatchesSource
    case childTurnCountMismatch(expected: Int, actual: Int)
    case childRetainedPrefixMismatch
    case sourceManifestChanged
}

enum CodexForkStructuralVerifier {
    typealias Turn = CodexNativeSessionController.ThreadTurn
    typealias Page = CodexNativeSessionController.ThreadTurnsPage

    struct PageSlice: Equatable {
        let requestedCursor: String?
        let page: Page
    }

    struct Manifest: Equatable {
        /// Oldest-to-newest order, normalized from descending app-server pages.
        let turns: [Turn]
    }

    static func collectManifestFromDescendingPages(_ pages: [PageSlice]) throws -> Manifest {
        guard !pages.isEmpty else {
            throw CodexForkStructuralVerificationError.incompletePagination
        }

        var expectedCursor: String?
        var observedCursors: Set<String> = []
        var observedTurnIDs: Set<String> = []
        var descendingTurns: [Turn] = []

        for (index, slice) in pages.enumerated() {
            guard slice.requestedCursor == expectedCursor else {
                throw CodexForkStructuralVerificationError.incompletePagination
            }

            for turn in slice.page.data {
                guard !turn.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CodexForkStructuralVerificationError.blankTurnID
                }
                guard observedTurnIDs.insert(turn.id).inserted else {
                    throw CodexForkStructuralVerificationError.duplicateTurnID(turn.id)
                }
                descendingTurns.append(turn)
            }

            guard let nextCursor = slice.page.nextCursor else {
                guard index == pages.indices.last else {
                    throw CodexForkStructuralVerificationError.incompletePagination
                }
                expectedCursor = nil
                continue
            }
            guard observedCursors.insert(nextCursor).inserted else {
                throw CodexForkStructuralVerificationError.repeatedCursor(nextCursor)
            }
            guard index != pages.indices.last else {
                throw CodexForkStructuralVerificationError.incompletePagination
            }
            expectedCursor = nextCursor
        }

        guard expectedCursor == nil else {
            throw CodexForkStructuralVerificationError.incompletePagination
        }
        return Manifest(turns: descendingTurns.reversed())
    }

    static func validatePreFork(
        manifest: Manifest,
        ledgerTurnIDsThroughCheckpoint ledgerTurnIDs: [String],
        checkpointTurnID: String
    ) throws {
        guard ledgerTurnIDs.last == checkpointTurnID else {
            throw CodexForkStructuralVerificationError.ledgerDoesNotEndAtCheckpoint
        }
        if let inProgress = manifest.turns.first(where: { $0.status == .inProgress }) {
            throw CodexForkStructuralVerificationError.inProgressTurn(inProgress.id)
        }
        guard let checkpoint = manifest.turns.first(where: { $0.id == checkpointTurnID }) else {
            throw CodexForkStructuralVerificationError.checkpointMissing
        }
        guard checkpoint.status == .completed else {
            throw CodexForkStructuralVerificationError.checkpointNotCompleted
        }

        var ledgerIndex = ledgerTurnIDs.startIndex
        for turn in manifest.turns where ledgerIndex != ledgerTurnIDs.endIndex {
            if turn.id == ledgerTurnIDs[ledgerIndex] {
                ledgerIndex = ledgerTurnIDs.index(after: ledgerIndex)
            }
        }
        guard ledgerIndex == ledgerTurnIDs.endIndex else {
            throw CodexForkStructuralVerificationError.ledgerNotOrderedSubsequence
        }
    }

    static func validatePostFork(
        sourceManifest: Manifest,
        childManifest: Manifest,
        sourceThreadID: String,
        childThreadID: String,
        checkpointTurnID: String
    ) throws {
        guard !childThreadID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodexForkStructuralVerificationError.invalidChildThreadID
        }
        guard childThreadID != sourceThreadID else {
            throw CodexForkStructuralVerificationError.childMatchesSource
        }
        guard let checkpointIndex = sourceManifest.turns.firstIndex(where: { $0.id == checkpointTurnID }) else {
            throw CodexForkStructuralVerificationError.checkpointMissing
        }

        let retainedPrefix = Array(sourceManifest.turns[...checkpointIndex])
        guard childManifest.turns.count == retainedPrefix.count else {
            throw CodexForkStructuralVerificationError.childTurnCountMismatch(
                expected: retainedPrefix.count,
                actual: childManifest.turns.count
            )
        }
        guard retainedPrefix.elementsEqual(childManifest.turns, by: { sourceTurn, childTurn in
            sourceTurn.id == childTurn.id
                && sourceTurn.status == childTurn.status
                && structuralMarkers(in: sourceTurn) == structuralMarkers(in: childTurn)
        }) else {
            throw CodexForkStructuralVerificationError.childRetainedPrefixMismatch
        }
    }

    private static func structuralMarkers(in turn: Turn) -> [String] {
        turn.items.compactMap { item -> String? in
            let normalized = item.type
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .joined()
            switch normalized {
            case "contextcompaction":
                return "contextCompaction"
            default:
                return nil
            }
        }.sorted()
    }

    static func validateSourceReread(
        preFork: Manifest,
        reread: Manifest
    ) throws {
        guard preFork == reread else {
            throw CodexForkStructuralVerificationError.sourceManifestChanged
        }
    }
}
