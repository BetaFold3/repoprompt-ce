import Foundation

struct WorkspaceCodemapArtifactDemandTicket: Hashable {
    let retainID: UUID
    let requestID: UUID
    let rootEpoch: WorkspaceCodemapRootEpoch
    let fileID: UUID
    let requestGeneration: UInt64
    let catalogGeneration: UInt64
    let pathGeneration: UInt64
    let ingressGeneration: UInt64
}

enum WorkspaceCodemapArtifactDemandUnavailableReason: Equatable {
    case rootNotLoaded
    case fileNotCataloged
    case unsupportedFileType
    case gitTerminal(WorkspaceCodemapGitTerminalUnavailableReason)
    case gitTransient(WorkspaceCodemapGitTransientUnavailableReason)
    case demandUnavailable(WorkspaceCodemapBindingDemandUnavailableReason)
    case busy(retryAfterMilliseconds: Int?)
    case rejected(WorkspaceCodemapBindingDemandRejection)
    case routeConflict
    case registrationFailed
    case runtimeFailure
    case runtimeFailureParked
    case staleCurrentness
    case cancelled
}

struct WorkspaceCodemapArtifactDemandReady {
    let ticket: WorkspaceCodemapArtifactDemandTicket
    let identity: WorkspaceCodemapArtifactBindingIdentity
    let snapshot: WorkspaceCodemapLiveReadySnapshot
    let handle: WorkspaceCodemapLiveFrozenArtifactHandle
}

enum WorkspaceCodemapArtifactDemandResult {
    case unavailable(WorkspaceCodemapArtifactDemandUnavailableReason)
    case pending(WorkspaceCodemapArtifactDemandTicket)
    case ready(WorkspaceCodemapArtifactDemandReady)
}

enum WorkspaceCodemapArtifactDemandRecovery: Equatable {
    case refreshCurrentness
    case retryFreshDemand
    case resetRootSession
    case terminal

    init(_ rejection: WorkspaceCodemapBindingDemandRejection) {
        switch rejection {
        case .rootNotRegistered, .capabilityUnavailable:
            self = .resetRootSession
        case .rootEpochMismatch, .rootPathMismatch, .catalogGenerationMismatch,
             .requestGenerationInvalid, .stalePathGeneration, .staleIngressGeneration,
             .staleCompletion:
            self = .refreshCurrentness
        case .sourceAuthorityUnavailable:
            self = .retryFreshDemand
        case .invalidIdentity, .languageMismatch, .classificationMismatch:
            self = .terminal
        case let .overlayRejected(reason):
            self = switch reason {
            case .rootNotRegistered, .rootAuthorityInvalid:
                .resetRootSession
            case .rootEpochMismatch, .catalogGenerationMismatch,
                 .repositoryAuthorityMismatch, .staleRequestGeneration,
                 .requestGenerationConflict:
                .refreshCurrentness
            case .invalidToken:
                .retryFreshDemand
            case .pathOutsideRoot, .admissionReservationInvalid:
                .terminal
            }
        }
    }

    var isRetryable: Bool {
        switch self {
        case .refreshCurrentness, .retryFreshDemand, .resetRootSession:
            true
        case .terminal:
            false
        }
    }
}

enum WorkspaceCodemapArtifactDemandOwnershipDisposition {
    case notAcquired
    case created(WorkspaceCodemapArtifactDemandTicket)
    case joined(WorkspaceCodemapArtifactDemandTicket)
}

struct WorkspaceCodemapArtifactDemandOwnedResult {
    let result: WorkspaceCodemapArtifactDemandResult
    let ownership: WorkspaceCodemapArtifactDemandOwnershipDisposition
}
