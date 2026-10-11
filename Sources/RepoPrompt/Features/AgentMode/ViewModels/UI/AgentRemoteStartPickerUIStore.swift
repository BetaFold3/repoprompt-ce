import Foundation
import RepoPromptAgentCore

@MainActor
final class AgentRemoteStartPickerUIStore: ObservableObject {
    @Published var pending: RemoteStartWindowPickerState?
}
