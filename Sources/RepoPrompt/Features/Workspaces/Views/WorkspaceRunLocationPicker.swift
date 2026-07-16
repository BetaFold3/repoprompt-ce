import SwiftUI

struct WorkspaceRunLocationPicker: View {
    @Binding private var selectedHostID: String?

    init(selectedHostID: Binding<String?>) {
        _selectedHostID = selectedHostID
    }

    private var activeHosts: [PairedHostRecord] {
        ((try? RemoteHostRegistry.shared.listHosts()) ?? [])
            .filter { !$0.isRevokedByHost }
            .sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
    }

    private var selectedHost: PairedHostRecord? {
        guard let selectedHostID else { return nil }
        return activeHosts.first { $0.id == selectedHostID }
    }

    private var resolvedSelection: Binding<String?> {
        let activeHostIDs = Set(activeHosts.map(\.id))
        return Binding(
            get: {
                guard let selectedHostID, activeHostIDs.contains(selectedHostID) else {
                    return nil
                }
                return selectedHostID
            },
            set: { selectedHostID = $0 }
        )
    }

    var body: some View {
        if !activeHosts.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Picker("Runs on", selection: resolvedSelection) {
                    Text(
                        selectedHostID != nil && selectedHost == nil
                            ? "This Mac (previous host unpaired)"
                            : "This Mac"
                    )
                    .tag(nil as String?)
                    ForEach(activeHosts) { host in
                        Text(host.displayName)
                            .tag(Optional(host.id))
                    }
                }
                .pickerStyle(.menu)

                if let selectedHost {
                    Text("New sessions in this workspace will run on \(selectedHost.displayName). Existing sessions keep their current run location.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
