import Foundation
import RepoPromptRemoteWire

struct RemoteControlBuildIdentity: Equatable {
    let channel: RemoteControlBuildChannel
    let bundleID: String
    let marketingVersion: String
    let buildVersion: String

    static var current: RemoteControlBuildIdentity {
        #if DEBUG
            let channel: RemoteControlBuildChannel = .debug
        #else
            let channel: RemoteControlBuildChannel = .release
        #endif
        let info = Bundle.main.infoDictionary ?? [:]
        return RemoteControlBuildIdentity(
            channel: channel,
            bundleID: Bundle.main.bundleIdentifier ?? "com.pvncher.repoprompt.ce",
            marketingVersion: info["CFBundleShortVersionString"] as? String ?? "0",
            buildVersion: info["CFBundleVersion"] as? String ?? "0"
        )
    }

    static func forTesting(channel: RemoteControlBuildChannel) -> RemoteControlBuildIdentity {
        RemoteControlBuildIdentity(
            channel: channel,
            bundleID: channel == .release
                ? "com.pvncher.repoprompt.ce"
                : "com.pvncher.repoprompt.ce.debug",
            marketingVersion: "0",
            buildVersion: "0"
        )
    }

    var fixedPort: Int {
        channel.fixedPort
    }

    var urlScheme: String {
        channel.urlScheme
    }
}

enum RemoteControlStorageNamespace {
    static let rootComponents = ["RepoPrompt CE", "RemoteControl"]

    static func rootURL(
        channel: RemoteControlBuildChannel = RemoteControlBuildIdentity.current.channel,
        fileManager: FileManager = .default
    ) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let remoteControlRoot = rootComponents.reduce(base) { partial, component in
            partial.appendingPathComponent(component, isDirectory: true)
        }
        return remoteControlRoot.appendingPathComponent(channel.storageNamespace, isDirectory: true)
    }

    static func hostRegistryURL(
        channel: RemoteControlBuildChannel = RemoteControlBuildIdentity.current.channel,
        fileManager: FileManager = .default
    ) -> URL {
        rootURL(channel: channel, fileManager: fileManager)
            .appendingPathComponent("remote-hosts-v1.json", isDirectory: false)
    }

    static func pairedDevicesURL(
        channel: RemoteControlBuildChannel = RemoteControlBuildIdentity.current.channel,
        fileManager: FileManager = .default
    ) -> URL {
        rootURL(channel: channel, fileManager: fileManager)
            .appendingPathComponent("paired-devices-v1.json", isDirectory: false)
    }

    static func gatewayRuntimeRootURL(
        channel: RemoteControlBuildChannel = RemoteControlBuildIdentity.current.channel,
        fileManager: FileManager = .default
    ) -> URL {
        rootURL(channel: channel, fileManager: fileManager)
            .appendingPathComponent("GatewayRuntime", isDirectory: true)
    }

    static func hostSigningKeyAccount(
        channel: RemoteControlBuildChannel = RemoteControlBuildIdentity.current.channel
    ) -> String {
        "remote-control-host-signing-key-v1-\(channel.storageNamespace)"
    }

    static func clientKeyAccountPrefix(
        channel: RemoteControlBuildChannel = RemoteControlBuildIdentity.current.channel
    ) -> String {
        "remote-client-device-key-v1-\(channel.storageNamespace)-"
    }
}
