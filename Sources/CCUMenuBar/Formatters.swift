import Foundation

enum Formatters {
    static func ago(since date: Date) -> String {
        let secs = max(0, Int(Date().timeIntervalSince(date)))
        if secs < 60 { return "\(secs)s ago" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        if secs < 86_400 { return "\(secs / 3600)h ago" }
        return "\(secs / 86_400)d ago"
    }

    static func resetInOrAt(unix: Int) -> String {
        let target = Date(timeIntervalSince1970: TimeInterval(unix))
        let now = Date()
        let remaining = target.timeIntervalSince(now)
        if remaining <= 0 {
            return "reset due"
        }
        if remaining < 86_400 {
            return "resets in " + humanDuration(remaining)
        }
        let f = DateFormatter()
        f.dateFormat = "EEE HH:mm"
        return "resets \(f.string(from: target))"
    }

    static func humanDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(s)s"
    }
}
