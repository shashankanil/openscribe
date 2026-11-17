import XCTest
import OpenScribeContext

/// Runs the built `openscribe-mcp` executable over stdio pipes.
final class BinaryRoundTripTests: XCTestCase {
    private var fixture: FixtureProfile!

    override func setUpWithError() throws { fixture = try FixtureProfile() }
    override func tearDown() { fixture.remove() }

    private func binaryURL() throws -> URL {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let url = products.appendingPathComponent("openscribe-mcp")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw XCTSkip("openscribe-mcp not built at \(url.path); run `swift build` first")
        }
        return url
    }

    private func run(_ arguments: [String] = [], input: String) throws -> (stdout: String, stderr: String, status: Int32) {
        let process = Process()
        process.executableURL = try binaryURL()
        process.arguments = arguments
        process.environment = ["OPENSCRIBE_DATA_DIR": fixture.root.path, "PATH": "/usr/bin:/bin"]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self), process.terminationStatus)
    }

    func testStdioHandshakeRoundTrip() throws {
        let messages: [JSONValue] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": ["protocolVersion": "2025-03-26", "capabilities": [:], "clientInfo": ["name": "xctest", "version": "1"]]],
            ["jsonrpc": "2.0", "method": "notifications/initialized"],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/list"],
            ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "search", "arguments": ["query": "launch date"]]],
            ["jsonrpc": "2.0", "id": 4, "method": "bogus/method"],
        ]
        let result = try run(input: messages.map { $0.serialized() }.joined(separator: "\n") + "\n")
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("serving \(fixture.root.path)"), result.stderr)

        let lines = result.stdout.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 4, result.stdout)
        let responses = try lines.map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        XCTAssertTrue(responses.allSatisfy { $0["jsonrpc"] == "2.0" })
        XCTAssertEqual(responses.map { $0["id"] }, [1, 2, 3, 4])
        XCTAssertEqual(responses[0]["result"]?["protocolVersion"], "2025-03-26")
        XCTAssertEqual(responses[1]["result"]?["tools"]?.arrayValue?.count, 6)
        let text = try XCTUnwrap(responses[2]["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        XCTAssertTrue(text.contains(FixtureProfile.planningMeetingID), text)
        XCTAssertEqual(responses[3]["error"]?["code"], -32601)
    }

    func testPrintConfigAndHelp() throws {
        let config = try run(["--print-config"], input: "")
        XCTAssertEqual(config.status, 0)
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(config.stdout.utf8))
        let server = try XCTUnwrap(json["mcpServers"]?["openscribe"])
        XCTAssertEqual(server["command"]?.stringValue, try binaryURL().resolvingSymlinksInPath().path)
        XCTAssertEqual(server["env"]?["OPENSCRIBE_DATA_DIR"]?.stringValue, fixture.root.path)

        let help = try run(["--help"], input: "")
        XCTAssertEqual(help.status, 0)
        XCTAssertTrue(help.stdout.contains("--print-config"))
        XCTAssertNotEqual(try run(["--frobnicate"], input: "").status, 0)
    }
}
