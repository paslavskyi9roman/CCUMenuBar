@testable import CCUMenuBar
import Foundation
import Testing

@Test func aggregatesDedupesAndSummarizesLocalClaudeLogs() throws {
    let tempDirectory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    let now = Date()
    let nowISO = fractionalISO8601String(from: now)
    let yesterdayISO = State.iso8601.string(from: Calendar.current.date(byAdding: .day, value: -1, to: now)!)

    try writeJSONL([
        assistantLine(
            requestID: "req-opus",
            timestamp: nowISO,
            model: "claude-opus-4-7",
            input: 1_000_000,
            output: 100_000,
            cacheCreation: 1_000_000,
            cache5m: 0,
            cache1h: 1_000_000,
            cacheRead: 1_000_000,
            webSearches: 1
        ),
        assistantLine(
            requestID: "req-opus",
            timestamp: nowISO,
            model: "claude-opus-4-7",
            input: 1_000_000,
            output: 100_000,
            cacheCreation: 1_000_000,
            cache5m: 0,
            cache1h: 1_000_000,
            cacheRead: 1_000_000,
            webSearches: 1
        ),
        assistantLine(
            requestID: "req-sonnet",
            timestamp: yesterdayISO,
            model: "claude-sonnet-4-5",
            input: 100_000,
            output: 10_000,
            cacheCreation: 0,
            cache5m: 0,
            cache1h: 0,
            cacheRead: 0,
            webSearches: 0
        ),
    ], in: tempDirectory)

    let summary = UsageSummaryStore(projectsDirectory: tempDirectory).refresh()

    #expect(summary.hasUsage)
    #expect(summary.latestTokens == 3_100_000)
    #expect(summary.thirtyDayTokens == 3_210_000)
    #expect(summary.todayTokens == 3_100_000)
    #expect(summary.topModel == "claude-opus-4-7")
}

@Test func excludesEventsOlderThanThirtyDayWindow() throws {
    let tempDirectory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    let now = Date()
    let oldISO = State.iso8601.string(from: Calendar.current.date(byAdding: .day, value: -40, to: now)!)

    try writeJSONL([
        assistantLine(
            requestID: "old",
            timestamp: oldISO,
            model: "claude-sonnet-4-5",
            input: 1_000_000,
            output: 0,
            cacheCreation: 0,
            cache5m: 0,
            cache1h: 0,
            cacheRead: 0,
            webSearches: 0
        ),
    ], in: tempDirectory)

    let summary = UsageSummaryStore(projectsDirectory: tempDirectory).refresh()

    #expect(!summary.hasUsage)
    #expect(summary.thirtyDayTokens == 0)
}

@Test func unknownModelContributesRealTokenData() throws {
    let tempDirectory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    let nowISO = State.iso8601.string(from: Date())

    try writeJSONL([
        assistantLine(
            requestID: "unknown",
            timestamp: nowISO,
            model: "claude-future-9",
            input: 50,
            output: 60,
            cacheCreation: 70,
            cache5m: nil,
            cache1h: nil,
            cacheRead: 80,
            webSearches: 0
        ),
    ], in: tempDirectory)

    let summary = UsageSummaryStore(projectsDirectory: tempDirectory).refresh()

    #expect(summary.hasUsage)
    #expect(summary.thirtyDayTokens == 260)
    #expect(summary.todayTokens == 260)
    #expect(summary.topModel == "claude-future-9")
}

private func makeTempDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("CCUMenuBarTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func fractionalISO8601String(from date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: date)
}

private func writeJSONL(_ lines: [String], in directory: URL) throws {
    let project = directory.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let file = project.appendingPathComponent("session.jsonl")
    try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
}

private func assistantLine(
    requestID: String,
    timestamp: String,
    model: String,
    input: Int,
    output: Int,
    cacheCreation: Int,
    cache5m: Int?,
    cache1h: Int?,
    cacheRead: Int,
    webSearches: Int
) -> String {
    var cacheCreationObject: [String: Any] = [:]
    if let cache5m {
        cacheCreationObject["ephemeral_5m_input_tokens"] = cache5m
    }
    if let cache1h {
        cacheCreationObject["ephemeral_1h_input_tokens"] = cache1h
    }

    var usage: [String: Any] = [
        "input_tokens": input,
        "output_tokens": output,
        "cache_creation_input_tokens": cacheCreation,
        "cache_read_input_tokens": cacheRead,
        "server_tool_use": ["web_search_requests": webSearches],
    ]
    if !cacheCreationObject.isEmpty {
        usage["cache_creation"] = cacheCreationObject
    }

    let object: [String: Any] = [
        "type": "assistant",
        "requestId": requestID,
        "timestamp": timestamp,
        "message": [
            "id": "msg-\(requestID)",
            "model": model,
            "usage": usage,
        ],
    ]
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(data: data, encoding: .utf8)!
}
