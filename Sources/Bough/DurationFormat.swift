import Foundation

enum DurationFormat {
    case compact   // 45m / 5h / 5h 23m / 4d 5h 23m (zeros elided)
    case fullDHM   // always Xd Yh Zm even when components are 0

    static func format(until date: Date, now: Date, _ format: DurationFormat) -> String {
        let totalMinutes = max(0, Int(date.timeIntervalSince(now) / 60))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let mins = totalMinutes % 60

        switch format {
        case .fullDHM:
            return "\(days)d \(hours)h \(mins)m"

        case .compact:
            if totalMinutes < 60 { return "\(mins)m" }

            let totalHours = totalMinutes / 60
            if totalHours < 72 {
                return mins == 0 ? "\(totalHours)h" : "\(totalHours)h \(mins)m"
            }

            var parts = ["\(days)d"]
            if hours > 0 { parts.append("\(hours)h") }
            if mins > 0 { parts.append("\(mins)m") }
            return parts.joined(separator: " ")
        }
    }
}
