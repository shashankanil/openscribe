import XCTest
@testable import OpenScribeContext

final class MCPServerTests: XCTestCase {
    private var fixture: FixtureProfile!
    private var server: MCPServer!

    override func setUpWithError() throws {
        fixture = try FixtureProfile()
        let now = fixture.now
        server = MCPServer(root: fixture.root, now: { now })
    }

    override func tearDown() { fixture.remove() }

    private func send(_ message: JSONValue) throws -> JSONValue? {
        guard let line = server.handle(line: message.serialized()) else { return nil }
        XCTAssertFalse(line.contains("\n"), "responses must be single lines")
        return try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
    }

    private func request(_ id: Int, _ method: String, _ params: JSONValue = [:]) throws -> JSONValue {
        try XCTUnwrap(send(["jsonrpc": "2.0", "id": .int(id), "method": .string(method), "params": params]))
    }

    private func initialize(_ version: String) throws -> JSONValue {
        try request(1, "initialize", ["protocolVersion": .string(version), "capabilities": [:], "clientInfo": ["name": "test", "version": "1"]])
    }

    func testInitializeNegotiatesVersion() throws {
        for version in MCPServer.supportedProtocolVersions {
            XCTAssertEqual(try MCPServer(root: fixture.root).handle(message: ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                                                                "params": ["protocolVersion": .string(version)]])?["result"]?["protocolVersion"]?.stringValue, version)
        }
        let response = try initialize("1999-01-01")
        XCTAssertEqual(response["id"], 1)
        XCTAssertEqual(response["result"]?["protocolVersion"], "2025-11-25")
        XCTAssertEqual(response["result"]?["serverInfo"]?["name"], "openscribe")
        XCTAssertEqual(response["result"]?["capabilities"]?["tools"]?["listChanged"], false)
    }

    func testNotificationsGetNoResponse() throws {
        XCTAssertNil(try send(["jsonrpc": "2.0", "method": "notifications/initialized"]))
        XCTAssertNil(try send(["jsonrpc": "2.0", "method": "notifications/whatever", "params": ["x": 1]]))
        XCTAssertNil(try send(["jsonrpc": "2.0", "id": 9, "result": [:]]), "client responses are ignored")
    }

    func testPingAndUnknownMethod() throws {
        XCTAssertEqual(try request(2, "ping")["result"], [:])
        let unknown = try request(3, "resources/list")
        XCTAssertEqual(unknown["error"]?["code"], -32601)
        XCTAssertEqual(unknown["id"], 3)
    }

    func testMalformedInput() throws {
        let parse = try JSONDecoder().decode(JSONValue.self, from: Data(XCTUnwrap(server.handle(line: "{oops")).utf8))
        XCTAssertEqual(parse["error"]?["code"], -32700)
        XCTAssertEqual(parse["id"], .null)
        XCTAssertEqual(try send(["jsonrpc": "2.0", "id": 4])?["error"]?["code"], -32600)
        XCTAssertNil(server.handle(line: "   "))
    }

    func testToolsListAdvertisesReadOnlyToolsWithSchemas() throws {
        _ = try initialize("2025-06-18")
        let tools = try XCTUnwrap(request(2, "tools/list")["result"]?["tools"]?.arrayValue)
        XCTAssertEqual(tools.compactMap { $0["name"]?.stringValue }, ["search", "fetch", "list_recent", "get_meeting", "list_action_items", "get_attachment"])
        XCTAssertTrue(tools.allSatisfy { $0["annotations"]?["readOnlyHint"] == true && $0["outputSchema"] != nil && $0["inputSchema"] != nil })

        _ = try initialize("2024-11-05")
        let legacy = try XCTUnwrap(request(3, "tools/list")["result"]?["tools"]?.arrayValue)
        XCTAssertTrue(legacy.allSatisfy { $0["outputSchema"] == nil && $0["inputSchema"] != nil })
    }

    func testToolsCall() throws {
        _ = try initialize("2025-06-18")
        let response = try request(5, "tools/call", ["name": "search", "arguments": ["query": "zurich offsite"]])
        let result = try XCTUnwrap(response["result"])
        XCTAssertEqual(result["content"]?.arrayValue?.first?["type"], "text")
        XCTAssertNil(result["isError"])
        let ids = result["structuredContent"]?["results"]?.arrayValue?.compactMap { $0["id"]?.stringValue } ?? []
        XCTAssertEqual(Set(ids), [FixtureProfile.dayNoteID, FixtureProfile.planningMeetingID])

        let toolError = try request(6, "tools/call", ["name": "fetch", "arguments": ["id": "missing"]])
        XCTAssertEqual(toolError["result"]?["isError"], true)

        XCTAssertEqual(try request(7, "tools/call", ["name": "nope", "arguments": [:]])["error"]?["code"], -32602)
        XCTAssertEqual(try request(8, "tools/call", ["arguments": [:]])["error"]?["code"], -32602)
        XCTAssertEqual(try request(9, "tools/call", ["name": "search", "arguments": "query"])["error"]?["code"], -32602)
    }

    func testStringIDsAndBatches() throws {
        let batch: JSONValue = [
            ["jsonrpc": "2.0", "id": "a", "method": "ping"],
            ["jsonrpc": "2.0", "method": "notifications/initialized"],
            ["jsonrpc": "2.0", "id": "b", "method": "tools/call", "params": ["name": "list_action_items", "arguments": [:]]],
        ]
        let responses = try XCTUnwrap(send(batch)?.arrayValue)
        XCTAssertEqual(responses.compactMap { $0["id"]?.stringValue }, ["a", "b"])
        XCTAssertEqual(responses[1]["result"]?["structuredContent"]?["actionItems"]?.arrayValue?.count, 2)
    }
}
