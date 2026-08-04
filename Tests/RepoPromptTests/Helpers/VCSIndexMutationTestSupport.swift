import Foundation
@testable import RepoPromptApp

/// A final-authority hook that always authorizes.
///
/// Production has exactly one caller of the index-mutation seam and it always supplies a real hook,
/// so the seam deliberately carries no default. Suites that are exercising something other than
/// revocation say so once, here, instead of repeating a closure at every call site.
let alwaysAuthorizedIndexMutation: VCSIndexMutationAuthorization = { true }

/// A final-authority hook that always refuses, for suites asserting nothing runs.
let neverAuthorizedIndexMutation: VCSIndexMutationAuthorization = { false }

extension VCSIndexMutationBackend {
    func stage(_ identities: [VCSIndexPathIdentity], at repoURL: URL) async throws {
        try await stage(identities, at: repoURL, authorize: alwaysAuthorizedIndexMutation)
    }

    func unstage(_ identities: [VCSIndexPathIdentity], at repoURL: URL) async throws {
        try await unstage(identities, at: repoURL, authorize: alwaysAuthorizedIndexMutation)
    }

    func applyCachedPatch(_ data: Data, reverse: Bool, at repoURL: URL) async throws {
        try await applyCachedPatch(
            data,
            reverse: reverse,
            at: repoURL,
            authorize: alwaysAuthorizedIndexMutation
        )
    }

    func markResolved(_ identity: VCSIndexPathIdentity, at repoURL: URL) async throws {
        try await markResolved(identity, at: repoURL, authorize: alwaysAuthorizedIndexMutation)
    }
}

extension GitService {
    func stageIndexPaths(_ identities: [VCSIndexPathIdentity], at repoURL: URL) async throws {
        try await stageIndexPaths(
            identities,
            at: repoURL,
            authorize: alwaysAuthorizedIndexMutation
        )
    }

    func unstageIndexPaths(_ identities: [VCSIndexPathIdentity], at repoURL: URL) async throws {
        try await unstageIndexPaths(
            identities,
            at: repoURL,
            authorize: alwaysAuthorizedIndexMutation
        )
    }

    func markIndexPathResolved(_ identity: VCSIndexPathIdentity, at repoURL: URL) async throws {
        try await markIndexPathResolved(
            identity,
            at: repoURL,
            authorize: alwaysAuthorizedIndexMutation
        )
    }

    func applyIndexPatch(data: Data, reverse: Bool, repoURL: URL) async throws {
        try await applyIndexPatch(
            data: data,
            reverse: reverse,
            repoURL: repoURL,
            authorize: alwaysAuthorizedIndexMutation
        )
    }
}
