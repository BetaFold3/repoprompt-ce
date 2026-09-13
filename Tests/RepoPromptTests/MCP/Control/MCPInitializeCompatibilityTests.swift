import Darwin
import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

final class MCPInitializeCompatibilityTests: XCTestCase {
    private static let codexInitialize = Data(#"""
    {"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"experimental":{"codex/auth-change":{}},"elicitation":{"form":{},"url":{}}},"clientInfo":{"name":"codex-mcp-client","title":"Codex","version":"0.154.0-alpha.6.2"}}}
    """#.utf8)

    func testCodexInitializeSurvivesSocketIngressAndSDKDecoding() async throws {
        // Captured from the installed Codex client's initialize request; no
        // prompts, tool bodies or credentials are present.
        // SDK upgrade tripwire: when raw decoding succeeds, remove the adapter.
        XCTAssertThrowsError(try JSONDecoder().decode(Request<Initialize>.self, from: Self.codexInitialize))

        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        let transport = try UnixSocketMCPTransport(connectedFD: descriptors[0])
        defer { Darwin.close(descriptors[1]) }
        do {
            try await transport.connect()
            let stream = await transport.receive()
            let framed = Self.codexInitialize + Data([0x0A])
            let written = framed.withUnsafeBytes { Darwin.write(descriptors[1], $0.baseAddress, $0.count) }
            XCTAssertEqual(written, framed.count)
            XCTAssertEqual(Darwin.shutdown(descriptors[1], SHUT_WR), 0)
            var iterator = stream.makeAsyncIterator()
            let received = try await iterator.next()
            let request = try JSONDecoder().decode(Request<Initialize>.self, from: XCTUnwrap(received))
            XCTAssertEqual(request.id, .number(0))
            XCTAssertEqual(request.params.clientInfo.name, "codex-mcp-client")
            XCTAssertEqual(request.params.clientInfo.version, "0.154.0-alpha.6.2")
            XCTAssertEqual(request.params.protocolVersion, "2025-06-18")
            XCTAssertNotNil(request.params.capabilities.elicitation?.form)
            XCTAssertNotNil(request.params.capabilities.elicitation?.url)
            XCTAssertEqual(request.params.capabilities.experimental, [:])
            await transport.disconnect()
        } catch {
            await transport.disconnect()
            throw error
        }
    }

    func testUnknownExperimentalValuesDoNotAlterStandardCapabilitiesOrIdentity() throws {
        let frame = Data(#"""
        {"jsonrpc":"2.0","id":"handshake","method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"experimental":{"object":{},"array":[1],"boolean":true,"number":42,"null":null,"legacy":"value"},"roots":{"listChanged":true},"sampling":{},"elicitation":{"form":{},"url":{}}},"clientInfo":{"name":"test-client","version":"1","title":"Test"}}}
        """#.utf8)
        let adapted = MCPInitializeCompatibility.sdkCompatibleFrame(frame)
        let request = try JSONDecoder().decode(Request<Initialize>.self, from: adapted)
        XCTAssertEqual(request.id, .string("handshake"))
        XCTAssertEqual(request.params.capabilities.experimental, ["legacy": "value"])
        XCTAssertEqual(request.params.capabilities.roots?.listChanged, true)
        XCTAssertNotNil(request.params.capabilities.sampling)
        XCTAssertNotNil(request.params.capabilities.elicitation?.form)
        XCTAssertNotNil(request.params.capabilities.elicitation?.url)
        XCTAssertEqual(request.params.clientInfo, .init(name: "test-client", version: "1", title: "Test"))
        XCTAssertEqual(MCPInitializeCompatibility.sdkCompatibleFrame(adapted), adapted)
    }

    func testOtherMessagesAndMalformedInitializeRemainByteIdentical() {
        let frames = [
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"initialize","capabilities":{"experimental":{"object":{}}}}}"#,
            #"{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"experimental":{"object":{}}}}}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"experimental":{"legacy":"value"}}}}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"experimental":[]}}}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":false}}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#,
            #"{"jsonrpc":"2.0","method":"initialize","params":{"capabilities":{"experimental":{"object":{}}}}}"#,
            #"{"jsonrpc":"2.0","method":"initialize""#
        ]
        for frame in frames {
            let data = Data(frame.utf8)
            XCTAssertEqual(MCPInitializeCompatibility.sdkCompatibleFrame(data), data, frame)
        }
    }
}
