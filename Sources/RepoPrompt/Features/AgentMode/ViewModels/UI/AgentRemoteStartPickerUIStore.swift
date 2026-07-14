import Foundation

@MainActor
final class AgentRemoteStartPickerUIStore: ObservableObject {
    @Published var pending: RemoteStartWindowPickerState?
}
