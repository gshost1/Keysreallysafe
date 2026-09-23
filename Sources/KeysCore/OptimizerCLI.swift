import ArgumentParser
import Foundation

struct OptimizerCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "optimizer",
        abstract: "Optional encrypted project memory, plan retrieval and optimization.",
        subcommands: [OptimizerStatusCommand.self, OptimizerRPCCommand.self, OptimizerMCPCommand.self])
}

struct OptimizerStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Read capability status without unlocking content.")
    func run() throws {
        let (status, response) = try ControlClient.connect().call(method: "GET", path: "/api/optimizer/status")
        guard status == 200 else { throw ControlClient.raise(status: status, body: response) }
        try OptimizerCLIOutput.write(response)
    }
}

struct OptimizerConnectionOptions: ParsableArguments {
    @Option(help: "The approved project UUID shown in the Optimizer pane.") var project: String
    @Option(help: "Presence-approved session lifetime (1–120 minutes).") var minutes: Int = 30
    @Flag(help: "Permit saving entries and recording task outcomes in this project.") var writable = false
    @Option(name: .customLong("jev-key"), help: "Optional stored Jev-compatible key name; authorize a bounded evaluation grant.") var jevKey: String?

    func connect() throws -> (ControlClient, [String: Any]) {
        guard UUID(uuidString: project) != nil, (1...120).contains(minutes) else {
            throw AppError.usage("project must be a UUID and minutes must be 1–120")
        }
        let client = try ControlClient.connect()
        var body: [String: Any] = ["project_id": project, "minutes": minutes, "writable": writable]
        if let jevKey { body["jev_key"] = jevKey }
        fputs("Approve optimizer project access in Keysrs…\n", stderr)
        let (status, response) = try client.call(method: "POST", path: "/api/optimizer/unlock", body: body)
        guard status == 200, let token = response["token"] as? String, token.hasPrefix("kso_") else {
            throw ControlClient.raise(status: status, body: response)
        }
        return (client, response)
    }
}

struct OptimizerRPCCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rpc", abstract: "Run one scoped operation; JSON payload from stdin, JSON result to stdout.")
    @OptionGroup var connection: OptimizerConnectionOptions
    @Option var operation: String

    func run() throws {
        let input = try FileHandle.standardInput.read(upToCount: 128_001) ?? Data()
        guard input.count <= 128_000, var payload = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else {
            throw AppError.usage("stdin must contain a JSON object no larger than 128 KB")
        }
        payload["project_id"] = connection.project
        let (client, session) = try connection.connect()
        let headers = ["X-KSF-Optimizer": session["token"] as! String]
        defer { _ = try? client.call(method: "POST", path: "/api/optimizer/close", body: [:], timeout: 5, extraHeaders: headers) }
        let (status, response) = try client.call(method: "POST", path: "/api/optimizer/rpc", body: ["operation": operation, "payload": payload], extraHeaders: headers)
        guard status == 200 else { throw ControlClient.raise(status: status, body: response) }
        try OptimizerCLIOutput.write(response)
    }
}

struct OptimizerMCPCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mcp", abstract: "Serve project-scoped memory and plan tools over MCP stdio.")
    @OptionGroup var connection: OptimizerConnectionOptions

    func run() throws {
        let script = try WebRoot.find().deletingLastPathComponent().appendingPathComponent("scripts/optimizer-mcp.py")
        guard FileManager.default.isReadableFile(atPath: script.path) else {
            throw AppError.usage("optimizer MCP script is missing from this installation")
        }
        let (client, session) = try connection.connect()
        let token = session["token"] as! String
        defer { _ = try? client.call(method: "POST", path: "/api/optimizer/close", body: [:], timeout: 5, extraHeaders: ["X-KSF-Optimizer": token]) }
        let config: [String: Any] = ["port": Int(client.info.port), "origin_token": client.info.token,
            "token": token, "project_id": connection.project, "writable": connection.writable,
            "task_id": session["task_id"] ?? NSNull(),
            "jev_enabled": session["jev_enabled"] as? Bool ?? false]
        let data = try JSONValue.data(config)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", script.path]
        process.environment = ["KEYS_OPTIMIZER_SESSION": String(decoding: data, as: UTF8.self)]
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 { throw AppError.usage("optimizer MCP session ended") }
    }
}

private enum OptimizerCLIOutput {
    static func write(_ object: [String: Any]) throws {
        try FileHandle.standardOutput.write(contentsOf: JSONValue.data(object))
        try FileHandle.standardOutput.write(contentsOf: Data("\n".utf8))
    }
}
