import Foundation
import OpenScribeContext

// openscribe-mcp: read-only MCP stdio server for OpenScribe notes and meetings.
// stdout carries only newline-delimited JSON-RPC messages; all logging goes to stderr.

func logError(_ message: String) {
    FileHandle.standardError.write(Data("[openscribe-mcp] \(message)\n".utf8))
}

func executablePath() -> String {
    let raw = Bundle.main.executablePath ?? CommandLine.arguments[0]
    let url = URL(fileURLWithPath: raw, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
    return url.standardizedFileURL.resolvingSymlinksInPath().path
}

let usage = """
openscribe-mcp \(MCPServer.serverVersion) — read-only MCP server for OpenScribe notes and meetings.

USAGE
  openscribe-mcp                 Serve MCP over stdio (newline-delimited JSON-RPC 2.0).
  openscribe-mcp --print-config  Print a Claude Desktop "mcpServers" snippet for this binary.
  openscribe-mcp --help          Show this help.
  openscribe-mcp --version       Show the version.

TOOLS
  search, fetch, list_recent, get_meeting, list_action_items (all read-only, offline).

DATA
  Reads ~/Library/Application Support/WhisperFlow (notes.json, Meetings/*/meeting.json).
  Set OPENSCRIBE_DATA_DIR to use another profile folder.

REGISTER
  Claude Code:     claude mcp add openscribe -- "\(executablePath())"
  Claude Desktop:  openscribe-mcp --print-config, then merge into
                   ~/Library/Application Support/Claude/claude_desktop_config.json
"""

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--help") || arguments.contains("-h") {
    print(usage)
    exit(0)
}
if arguments.contains("--version") {
    print(MCPServer.serverVersion)
    exit(0)
}
if arguments.contains("--print-config") {
    var server: [String: JSONValue] = ["command": .string(executablePath())]
    if let dataDir = ProcessInfo.processInfo.environment["OPENSCRIBE_DATA_DIR"], !dataDir.isEmpty {
        server["env"] = ["OPENSCRIBE_DATA_DIR": .string(dataDir)]
    }
    let config: JSONValue = ["mcpServers": ["openscribe": .object(server)]]
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let data = try? encoder.encode(config) { print(String(decoding: data, as: UTF8.self)) }
    exit(0)
}
if let unknown = arguments.first {
    logError("unknown argument \(unknown); see --help")
    exit(64)
}

signal(SIGPIPE, SIG_IGN)
setvbuf(stdout, nil, _IOFBF, 1 << 16)

let root = ContextLibrary.defaultRoot()
logError("serving \(root.path)")
let server = MCPServer(root: root, log: logError)

while let line = readLine(strippingNewline: true) {
    guard let response = server.handle(line: line) else { continue }
    // JSONEncoder never emits raw newlines in compact mode, so each message is one line.
    fputs(response + "\n", stdout)
    if fflush(stdout) != 0 {
        logError("stdout closed; exiting")
        exit(0)
    }
}
exit(0)
