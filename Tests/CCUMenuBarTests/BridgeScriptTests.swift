@testable import CCUMenuBar
import Foundation
import Testing

/// Guards the critical invariant called out in CLAUDE.md: the bridge's `jq`
/// output must stay byte-compatible with `State`'s `Codable` shape. Runs the
/// actual bundled script (not a mock) against a fixture payload, writing to a
/// scratch `CCU_STATE_DIR` so it never touches a real state.json.
@Test func bridgeScriptOutputDecodesAsState() throws {
    let jq = try #require(BridgeInstaller.jqPath, "jq not found on PATH — required for this test")
    let script = try #require(BridgeInstaller.bundledScriptURL(), "bundled bridge script missing")

    let scratchDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ccu-bridge-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: scratchDir) }

    let payload = """
    {"rate_limits":{\
    "five_hour":{"used_percentage":12.5,"resets_at":1700000000},\
    "seven_day":{"used_percentage":54.0,"resets_at":1700100000}\
    }}
    """

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [script.path]
    var env = ProcessInfo.processInfo.environment
    env["CCU_STATE_DIR"] = scratchDir.path
    env["CCU_JQ"] = jq
    process.environment = env

    let stdinPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = Pipe()
    process.standardError = Pipe()

    try process.run()
    stdinPipe.fileHandleForWriting.write(Data(payload.utf8))
    try stdinPipe.fileHandleForWriting.close()
    process.waitUntilExit()

    #expect(process.terminationStatus == 0)

    let stateFile = scratchDir.appendingPathComponent("state.json")
    let data = try Data(contentsOf: stateFile)
    let state = try JSONDecoder().decode(State.self, from: data)

    #expect(state.schemaVersion == 1)
    #expect(state.source == "statusline")
    #expect(state.session?.usedPct == 12.5)
    #expect(state.session?.resetsAtUnix == 1_700_000_000)
    #expect(state.weekly?.usedPct == 54.0)
    #expect(state.weekly?.resetsAtUnix == 1_700_100_000)
    #expect(state.updatedAtDate != nil)
}

/// When `rate_limits` is absent from the input (e.g. Free plan, or before the
/// first API call in a session), the bridge must not write state.json at all —
/// the app relies on this to distinguish "no data yet" from "zeroed out."
@Test func bridgeScriptWithoutRateLimitsWritesNoState() throws {
    let jq = try #require(BridgeInstaller.jqPath, "jq not found on PATH — required for this test")
    let script = try #require(BridgeInstaller.bundledScriptURL(), "bundled bridge script missing")

    let scratchDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ccu-bridge-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: scratchDir) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [script.path]
    var env = ProcessInfo.processInfo.environment
    env["CCU_STATE_DIR"] = scratchDir.path
    env["CCU_JQ"] = jq
    process.environment = env

    let stdinPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = Pipe()
    process.standardError = Pipe()

    try process.run()
    stdinPipe.fileHandleForWriting.write(Data("{}".utf8))
    try stdinPipe.fileHandleForWriting.close()
    process.waitUntilExit()

    #expect(process.terminationStatus == 0)
    #expect(!FileManager.default.fileExists(atPath: scratchDir.appendingPathComponent("state.json").path))

    let statusFile = scratchDir.appendingPathComponent("bridge-status.json")
    let statusData = try Data(contentsOf: statusFile)
    let status = try JSONDecoder().decode(BridgeStatus.self, from: statusData)
    #expect(status.rateLimitsPresent == false)
}
