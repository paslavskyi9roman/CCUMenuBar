import Foundation

struct UsageSummary: Equatable {
    struct Day: Equatable {
        var date: Date
        var tokens: Int
    }

    var todayTokens: Int
    var thirtyDayTokens: Int
    var latestTokens: Int?
    var topModel: String?
    var dailySeries: [Day]
    var hasUsage: Bool
}

struct UsageEvent: Equatable {
    var id: String
    var timestamp: Date
    var model: String
    var inputTokens: Int
    var outputTokens: Int
    var cacheCreationInputTokens: Int
    var cacheCreation5mInputTokens: Int?
    var cacheCreation1hInputTokens: Int?
    var cacheReadInputTokens: Int

    var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationInputTokens + cacheReadInputTokens
    }
}

final class UsageSummaryStore {
    private struct FileCache {
        var size: UInt64
        var modifiedAt: Date?
        var events: [UsageEvent]
    }

    private let projectsDirectory: URL
    private var cache: [String: FileCache] = [:]
    private let calendar = Calendar.current
    private static let fractionalISO8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(projectsDirectory: URL = AppPaths.claudeDirectory.appendingPathComponent("projects", isDirectory: true)) {
        self.projectsDirectory = projectsDirectory
    }

    func refresh() -> UsageSummary {
        let events = dedupedEvents(from: loadEvents())
        return summarize(events)
    }

    private func loadEvents() -> [UsageEvent] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: projectsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var result: [UsageEvent] = []
        var seenPaths = Set<String>()
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let path = url.path
            seenPaths.insert(path)

            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile != false else { continue }
            let size = UInt64(values?.fileSize ?? 0)
            let modifiedAt = values?.contentModificationDate

            if let cached = cache[path], cached.size == size, cached.modifiedAt == modifiedAt {
                result.append(contentsOf: cached.events)
                continue
            }

            let events = Self.parseJSONL(at: url)
            cache[path] = FileCache(size: size, modifiedAt: modifiedAt, events: events)
            result.append(contentsOf: events)
        }

        cache = cache.filter { seenPaths.contains($0.key) }
        return result
    }

    private func dedupedEvents(from events: [UsageEvent]) -> [UsageEvent] {
        var byID: [String: UsageEvent] = [:]
        for event in events {
            if let existing = byID[event.id] {
                if event.timestamp > existing.timestamp {
                    byID[event.id] = event
                }
            } else {
                byID[event.id] = event
            }
        }
        return Array(byID.values)
    }

    private func summarize(_ events: [UsageEvent]) -> UsageSummary {
        let now = Date()
        let todayStart = calendar.startOfDay(for: now)
        guard let windowStart = calendar.date(byAdding: .day, value: -29, to: todayStart),
              let windowEnd = calendar.date(byAdding: .day, value: 1, to: todayStart) else {
            return emptySummary()
        }

        let windowEvents = events.filter { $0.timestamp >= windowStart && $0.timestamp < windowEnd }
        var todayTokens = 0
        var thirtyDayTokens = 0
        var tokensByModel: [String: Int] = [:]
        var tokensByDay: [Date: Int] = [:]

        for event in windowEvents {
            let day = calendar.startOfDay(for: event.timestamp)
            let tokens = event.totalTokens

            if day == todayStart {
                todayTokens += tokens
            }
            thirtyDayTokens += tokens
            tokensByDay[day, default: 0] += tokens
            tokensByModel[event.model, default: 0] += tokens
        }

        let latest = windowEvents.max { $0.timestamp < $1.timestamp }?.totalTokens
        let topModel = tokensByModel.max { $0.value < $1.value }?.key
        let series = (0..<30).compactMap { offset -> UsageSummary.Day? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: windowStart) else { return nil }
            return UsageSummary.Day(date: date, tokens: tokensByDay[date, default: 0])
        }

        return UsageSummary(
            todayTokens: todayTokens,
            thirtyDayTokens: thirtyDayTokens,
            latestTokens: latest,
            topModel: topModel,
            dailySeries: series,
            hasUsage: !windowEvents.isEmpty
        )
    }

    private func emptySummary() -> UsageSummary {
        UsageSummary(
            todayTokens: 0,
            thirtyDayTokens: 0,
            latestTokens: nil,
            topModel: nil,
            dailySeries: [],
            hasUsage: false
        )
    }

    private static func parseJSONL(at url: URL) -> [UsageEvent] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var events: [UsageEvent] = []
        text.enumerateLines { line, _ in
            guard let event = parseLine(line) else { return }
            events.append(event)
        }
        return events
    }

    private static func parseLine(_ line: String) -> UsageEvent? {
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["type"] as? String) == "assistant",
              let message = root["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else {
            return nil
        }

        guard let timestampText = root["timestamp"] as? String,
              let timestamp = parseTimestamp(timestampText) else {
            return nil
        }

        let id = (root["requestId"] as? String)
            ?? (message["id"] as? String)
            ?? (root["uuid"] as? String)
        guard let id else { return nil }

        let model = (message["model"] as? String) ?? "unknown"
        let cacheCreation = usage["cache_creation"] as? [String: Any]
        let cache5m = intValue(cacheCreation?["ephemeral_5m_input_tokens"])
        let cache1h = intValue(cacheCreation?["ephemeral_1h_input_tokens"])

        return UsageEvent(
            id: id,
            timestamp: timestamp,
            model: model,
            inputTokens: intValue(usage["input_tokens"]) ?? 0,
            outputTokens: intValue(usage["output_tokens"]) ?? 0,
            cacheCreationInputTokens: intValue(usage["cache_creation_input_tokens"]) ?? 0,
            cacheCreation5mInputTokens: cache5m,
            cacheCreation1hInputTokens: cache1h,
            cacheReadInputTokens: intValue(usage["cache_read_input_tokens"]) ?? 0
        )
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        fractionalISO8601.date(from: value) ?? State.iso8601.date(from: value)
    }
}
