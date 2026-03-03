import Foundation

extension Date {
    var isToday: Bool { Calendar.current.isDateInToday(self) }
    var isTomorrow: Bool { Calendar.current.isDateInTomorrow(self) }
    var isYesterday: Bool { Calendar.current.isDateInYesterday(self) }

    var isPast: Bool { self < Calendar.current.startOfDay(for: Date()) }

    var startOfDay: Date { Calendar.current.startOfDay(for: self) }

    var relativeLabel: String {
        if isToday { return "Сегодня" }
        if isTomorrow { return "Завтра" }
        if isYesterday { return "Вчера" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        let days = Calendar.current.dateComponents([.day], from: startOfDay, to: Date().startOfDay).day ?? 0
        if days > 0 && days < 7 {
            formatter.dateFormat = "EEEE"
            return formatter.string(from: self).capitalized
        }
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: self)
    }

    var shortLabel: String {
        if isToday { return "Сегодня" }
        if isTomorrow { return "Завтра" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMM"
        return formatter.string(from: self)
    }

    static func startOfDay(for date: Date = Date()) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    static func tomorrow() -> Date {
        Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    }

    func daysUntil(_ other: Date) -> Int {
        Calendar.current.dateComponents([.day], from: startOfDay, to: other.startOfDay).day ?? 0
    }
}

extension DateFormatter {
    static let ruMedium: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}
