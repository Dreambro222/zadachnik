import SwiftData
import Foundation
import SwiftUI

enum RecurringInterval: String, Codable, CaseIterable, Identifiable {
    case daily   = "daily"
    case weekly  = "weekly"
    case monthly = "monthly"
    case custom  = "custom"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .daily:   return "Ежедневно"
        case .weekly:  return "Еженедельно"
        case .monthly: return "Ежемесячно"
        case .custom:  return "Пользовательский"
        }
    }

    var icon: String {
        switch self {
        case .daily:   return "sun.max.fill"
        case .weekly:  return "calendar.badge.clock"
        case .monthly: return "calendar"
        case .custom:  return "slider.horizontal.3"
        }
    }

    func nextDate(from date: Date, customDays: Int = 1) -> Date {
        let cal = Calendar.current
        switch self {
        case .daily:   return cal.date(byAdding: .day,   value: 1,          to: date) ?? date
        case .weekly:  return cal.date(byAdding: .day,   value: 7,          to: date) ?? date
        case .monthly: return cal.date(byAdding: .month, value: 1,          to: date) ?? date
        case .custom:  return cal.date(byAdding: .day,   value: customDays, to: date) ?? date
        }
    }
}

@Model
final class RecurringPattern {
    var id: UUID
    var title: String
    var notes: String
    var intervalRaw: String
    var customDays: Int
    var nextDate: Date
    var isActive: Bool
    var createdAt: Date
    var lastTriggeredAt: Date?

    var interval: RecurringInterval {
        get { RecurringInterval(rawValue: intervalRaw) ?? .weekly }
        set { intervalRaw = newValue.rawValue }
    }

    var isDueToday: Bool {
        Calendar.current.isDateInToday(nextDate) || nextDate < Date()
    }

    func advance() {
        lastTriggeredAt = Date()
        nextDate = interval.nextDate(from: nextDate, customDays: customDays)
    }

    init(
        title: String,
        notes: String = "",
        interval: RecurringInterval = .weekly,
        customDays: Int = 7,
        nextDate: Date = Date()
    ) {
        self.id = UUID()
        self.title = title
        self.notes = notes
        self.intervalRaw = interval.rawValue
        self.customDays = customDays
        self.nextDate = nextDate
        self.isActive = true
        self.createdAt = Date()
        self.lastTriggeredAt = nil
    }
}
