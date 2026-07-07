@testable import CCUMenuBar
import Foundation
import Testing

private func freshDefaults() -> UserDefaults {
    let suite = "ccu.tests.\(UUID().uuidString)"
    return UserDefaults(suiteName: suite)!
}

@Test func quietHoursSpansMidnight() {
    let settings = Settings(defaults: freshDefaults())
    settings.quietHoursEnabled = true
    settings.quietHoursStart = 22
    settings.quietHoursEnd = 8

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!

    let lateNight = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 23))!
    let earlyMorning = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 6))!
    let midDay = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 10))!

    #expect(settings.isInQuietHours(now: lateNight, calendar: calendar))
    #expect(settings.isInQuietHours(now: earlyMorning, calendar: calendar))
    #expect(!settings.isInQuietHours(now: midDay, calendar: calendar))
}

@Test func quietHoursDisabledWhenTurnedOff() {
    let settings = Settings(defaults: freshDefaults())
    settings.quietHoursEnabled = false
    settings.quietHoursStart = 22
    settings.quietHoursEnd = 8

    #expect(!settings.isInQuietHours(now: Date()))
}

@Test func quietHoursDisabledWhenStartEqualsEnd() {
    let settings = Settings(defaults: freshDefaults())
    settings.quietHoursEnabled = true
    settings.quietHoursStart = 5
    settings.quietHoursEnd = 5

    #expect(!settings.isInQuietHours())
}
