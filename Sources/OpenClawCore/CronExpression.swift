import Foundation

/// Five-field cron expression (`minute hour day-of-month month day-of-week`).
///
/// Supports `*`, `?`, lists, ranges, steps (`*/15`, `1-30/5`), month names (`jan`–`dec`), weekday
/// names (`sun`–`sat`, `0` and `7` both Sunday) and the macros `@yearly`, `@annually`, `@monthly`,
/// `@weekly`, `@daily`, `@midnight`, `@hourly`. When both day fields are restricted a date matches if
/// either matches (Vixie cron semantics).
///
/// Next-fire computation runs on wall-clock time in the job's time zone: nonexistent local times
/// (spring-forward gaps) fire at the transition, and repeated local times (fall-back) fire once.
public struct CronExpression: Sendable, Equatable {
    /// Allowed minutes.
    public let minutes: [Int]
    /// Allowed hours.
    public let hours: [Int]
    /// Allowed days of month.
    public let daysOfMonth: Set<Int>
    /// Allowed months (1–12).
    public let months: Set<Int>
    /// Allowed weekdays (0 = Sunday).
    public let daysOfWeek: Set<Int>
    /// Whether the day-of-month field was `*` / `?`.
    public let dayOfMonthUnrestricted: Bool
    /// Whether the day-of-week field was `*` / `?`.
    public let dayOfWeekUnrestricted: Bool
    /// Source expression.
    public let source: String

    private static let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let dayNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
    private static let macros: [String: String] = [
        "@yearly": "0 0 1 1 *",
        "@annually": "0 0 1 1 *",
        "@monthly": "0 0 1 * *",
        "@weekly": "0 0 * * 0",
        "@daily": "0 0 * * *",
        "@midnight": "0 0 * * *",
        "@hourly": "0 * * * *",
    ]

    /// Parses an expression.
    /// - Parameter expression: Cron expression.
    /// - Throws: ``OpenClawCoreError/invalidConfiguration(_:)`` for malformed expressions.
    public init(_ expression: String) throws {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = Self.macros[trimmed.lowercased()] ?? trimmed
        let fields = expanded.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 5 else {
            throw OpenClawCoreError.invalidConfiguration("cron expression must have 5 fields: \(expression)")
        }
        self.source = trimmed
        self.minutes = try Self.parseField(fields[0], range: 0...59, names: nil).sorted()
        self.hours = try Self.parseField(fields[1], range: 0...23, names: nil).sorted()
        self.daysOfMonth = Set(try Self.parseField(fields[2], range: 1...31, names: nil))
        self.months = Set(try Self.parseField(fields[3], range: 1...12, names: Self.monthNames, nameOffset: 1))
        let weekdays = try Self.parseField(fields[4], range: 0...7, names: Self.dayNames, nameOffset: 0)
        self.daysOfWeek = Set(weekdays.map { $0 == 7 ? 0 : $0 })
        self.dayOfMonthUnrestricted = fields[2] == "*" || fields[2] == "?"
        self.dayOfWeekUnrestricted = fields[4] == "*" || fields[4] == "?"
    }

    /// Whether a local calendar day matches the day fields.
    /// - Parameters:
    ///   - day: Day of month.
    ///   - month: Month (1–12).
    ///   - weekday: Weekday (0 = Sunday).
    /// - Returns: `true` when the day is eligible.
    public func matchesDay(day: Int, month: Int, weekday: Int) -> Bool {
        guard self.months.contains(month) else { return false }
        let domMatch = self.daysOfMonth.contains(day)
        let dowMatch = self.daysOfWeek.contains(weekday)
        if self.dayOfMonthUnrestricted && self.dayOfWeekUnrestricted { return true }
        if self.dayOfMonthUnrestricted { return dowMatch }
        if self.dayOfWeekUnrestricted { return domMatch }
        return domMatch || dowMatch
    }

    /// First fire time strictly after `date`.
    /// - Parameters:
    ///   - date: Reference instant.
    ///   - timeZone: Evaluation time zone.
    ///   - horizonYears: Search horizon.
    /// - Returns: The next fire time, or `nil` within the horizon (for example `0 0 30 2 *`).
    public func nextDate(after date: Date, in timeZone: TimeZone = .current, horizonYears: Int = 8) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard var day = calendar.dateInterval(of: .day, for: date)?.start else { return nil }
        let limit = horizonYears * 366
        var visited = 0
        while visited <= limit {
            visited += 1
            let components = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
            guard let year = components.year, let month = components.month, let dayOfMonth = components.day, let weekday = components.weekday else {
                return nil
            }
            if !self.months.contains(month) {
                guard let nextMonth = calendar.date(from: DateComponents(year: year, month: month + 1, day: 1)) else { return nil }
                day = calendar.startOfDay(for: nextMonth)
                continue
            }
            if self.matchesDay(day: dayOfMonth, month: month, weekday: weekday - 1) {
                for hour in self.hours {
                    for minute in self.minutes {
                        guard let candidate = self.resolveWallTime(hour: hour, minute: minute, on: day, calendar: calendar) else { continue }
                        if candidate > date {
                            return candidate
                        }
                    }
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = calendar.startOfDay(for: next)
        }
        return nil
    }

    /// Wall-clock time on a local day; gaps resolve to the transition, repeats to the first instant.
    private func resolveWallTime(hour: Int, minute: Int, on day: Date, calendar: Calendar) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = hour
        components.minute = minute
        components.second = 0
        guard let exact = calendar.date(from: components) else { return nil }
        let resolved = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: exact)
        if resolved.hour == hour && resolved.minute == minute && resolved.day == components.day {
            // Repeated local time: prefer the earlier instant when it maps to the same wall clock.
            let earlier = exact.addingTimeInterval(-3_600)
            let earlierComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: earlier)
            if earlierComponents.hour == hour && earlierComponents.minute == minute && earlierComponents.day == components.day {
                return earlier
            }
            return exact
        }
        // Nonexistent local time (spring forward): fire at the transition, the first instant of the next hour.
        var transition = components
        transition.hour = hour + 1
        transition.minute = 0
        guard let afterGap = calendar.date(from: transition) else { return exact }
        let gapStart = calendar.dateComponents([.hour, .minute], from: afterGap)
        if gapStart.minute == 0 {
            return afterGap
        }
        return exact
    }

    private static func parseField(_ field: String, range: ClosedRange<Int>, names: [String]?, nameOffset: Int = 0) throws -> [Int] {
        var values = Set<Int>()
        for part in field.split(separator: ",") {
            let piece = String(part)
            var step = 1
            var body = piece
            if let slash = piece.firstIndex(of: "/") {
                body = String(piece[..<slash])
                guard let parsed = Int(piece[piece.index(after: slash)...]), parsed > 0 else {
                    throw OpenClawCoreError.invalidConfiguration("invalid cron step in \(field)")
                }
                step = parsed
            }
            var lower: Int
            var upper: Int
            if body == "*" || body == "?" {
                lower = range.lowerBound
                upper = range.upperBound
                if range.upperBound == 7 { upper = 6 }
            } else if let dash = body.firstIndex(of: "-") {
                lower = try self.value(String(body[..<dash]), range: range, names: names, nameOffset: nameOffset)
                upper = try self.value(String(body[body.index(after: dash)...]), range: range, names: names, nameOffset: nameOffset)
            } else {
                lower = try self.value(body, range: range, names: names, nameOffset: nameOffset)
                upper = piece.contains("/") ? range.upperBound : lower
            }
            guard lower <= upper else {
                throw OpenClawCoreError.invalidConfiguration("invalid cron range in \(field)")
            }
            for value in stride(from: lower, through: upper, by: step) {
                values.insert(value)
            }
        }
        guard !values.isEmpty else {
            throw OpenClawCoreError.invalidConfiguration("empty cron field: \(field)")
        }
        return Array(values)
    }

    private static func value(_ raw: String, range: ClosedRange<Int>, names: [String]?, nameOffset: Int) throws -> Int {
        let lower = raw.lowercased()
        if let names, let index = names.firstIndex(of: String(lower.prefix(3))), lower.count >= 3 {
            return index + nameOffset
        }
        guard let number = Int(raw), range.contains(number) else {
            throw OpenClawCoreError.invalidConfiguration("cron value \(raw) is outside \(range.lowerBound)-\(range.upperBound)")
        }
        return number
    }
}
