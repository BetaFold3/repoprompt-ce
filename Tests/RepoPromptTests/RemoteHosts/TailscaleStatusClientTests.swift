import Foundation
@testable import RepoPromptApp
import RepoPromptRemoteWire
import XCTest

final class TailscaleStatusClientTests: XCTestCase {
    func testResolverPrefersUppercaseAppBundleExecutableThenFindsLowercaseCLI() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TailscaleCommandResolverTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let appExecutable = root
            .appendingPathComponent("Tailscale.app/Contents/MacOS/Tailscale")
        try FileManager.default.createDirectory(
            at: appExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\n".utf8).write(to: appExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: appExecutable.path)

        let environment = ["HOME": root.path, "PATH": ""]
        XCTAssertEqual(
            TailscaleCommandResolver.resolve(
                environment: environment,
                bundledExecutablePath: appExecutable.path,
                additionalSearchPaths: []
            ),
            appExecutable.path
        )

        try FileManager.default.removeItem(at: appExecutable)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let lowercase = bin.appendingPathComponent("tailscale")
        try Data("#!/bin/sh\n".utf8).write(to: lowercase)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lowercase.path)
        XCTAssertEqual(
            TailscaleCommandResolver.resolve(
                environment: environment,
                bundledExecutablePath: appExecutable.path,
                additionalSearchPaths: [bin.path]
            ),
            lowercase.path
        )
    }

    func testUnknownFieldsDecodeAndCandidatePolicyIsDeterministic() async throws {
        let data = Data("""
        {
          "BackendState":"Running",
          "FutureField":{"ignored":true},
          "Self":{"ID":"self","HostName":"client","TailscaleIPs":["100.64.0.9","100.64.0.2"]},
          "Peer":{
            "b":{"ID":"b","DNSName":"offline.ts.net.","TailscaleIPs":["100.64.0.5"],"Online":false},
            "a":{"ID":"a","DNSName":"studio.ts.net.","TailscaleIPs":["fd7a:115c:a1e0::1","100.64.0.4"],"Online":true},
            "u":{"ID":"u","HostName":"unknown-online","TailscaleIPs":["100.64.0.3"]}
          }
        }
        """.utf8)
        let client = TailscaleStatusClient(run: {
            CLIProcessRunner.Result(stdout: data, stderr: Data(), status: 0, timedOut: false, resolvedCommand: "/usr/bin/tailscale")
        })

        let status = try await client.status()
        XCTAssertEqual(status.selectedSelfIPv4, "100.64.0.2")
        XCTAssertEqual(status.visiblePeers.flatMap(\.eligibleIPv4s), ["100.64.0.3", "100.64.0.4"])

        let candidates = try await client.candidates()
        XCTAssertEqual(candidates.map { "\($0.peerIPv4):\($0.channel.rawValue)" }, [
            "100.64.0.3:release", "100.64.0.3:debug",
            "100.64.0.4:release", "100.64.0.4:debug"
        ])
        XCTAssertEqual(candidates.map(\.origin.port), [47391, 47392, 47391, 47392])
    }

    func testStoppedMalformedFailedAndOversizedInputsAreTyped() async {
        let stopped = Data(#"{"BackendState":"Stopped","Self":{"TailscaleIPs":["100.64.0.2"]}}"#.utf8)
        await assertStatusError(data: stopped, expected: .backendUnavailable("Stopped"))
        await assertStatusError(data: Data("not-json".utf8), expected: .invalidJSON)

        let failed = TailscaleStatusClient(run: {
            CLIProcessRunner.Result(stdout: Data(), stderr: Data("no daemon".utf8), status: 1, timedOut: false, resolvedCommand: "/usr/bin/tailscale")
        })
        do {
            _ = try await failed.status()
            XCTFail("Expected process failure")
        } catch {
            XCTAssertEqual(error as? TailscaleStatusError, .processFailed(status: 1, message: "no daemon"))
        }

        let oversized = TailscaleStatusClient(run: {
            CLIProcessRunner.Result(
                stdout: Data(repeating: 0, count: TailscaleStatusClient.maximumCombinedOutputBytes + 1),
                stderr: Data(),
                status: 0,
                timedOut: false,
                resolvedCommand: "/usr/bin/tailscale"
            )
        })
        do {
            _ = try await oversized.status()
            XCTFail("Expected output bound")
        } catch {
            XCTAssertEqual(error as? TailscaleStatusError, .outputTooLarge)
        }
    }

    private func assertStatusError(data: Data, expected: TailscaleStatusError) async {
        let client = TailscaleStatusClient(run: {
            CLIProcessRunner.Result(stdout: data, stderr: Data(), status: 0, timedOut: false, resolvedCommand: "/usr/bin/tailscale")
        })
        do {
            _ = try await client.status()
            XCTFail("Expected \(expected)")
        } catch {
            XCTAssertEqual(error as? TailscaleStatusError, expected)
        }
    }
}
