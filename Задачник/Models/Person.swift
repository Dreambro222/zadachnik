import SwiftData
import Foundation
import SwiftUI

// MARK: - Contact Source

enum ContactSource: String, Codable, CaseIterable, Identifiable {
    case realLife  = "real_life"
    case telegram  = "telegram"
    case linkedin  = "linkedin"
    case twitter   = "twitter"
    case instagram = "instagram"
    case email     = "email"
    case event     = "event"
    case other     = "other"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .realLife:  return "Вживую"
        case .telegram:  return "Telegram"
        case .linkedin:  return "LinkedIn"
        case .twitter:   return "Twitter / X"
        case .instagram: return "Instagram"
        case .email:     return "Email"
        case .event:     return "Мероприятие"
        case .other:     return "Другое"
        }
    }

    var icon: String {
        switch self {
        case .realLife:  return "person.fill"
        case .telegram:  return "paperplane.fill"
        case .linkedin:  return "network"
        case .twitter:   return "bird.fill"
        case .instagram: return "camera.fill"
        case .email:     return "envelope.fill"
        case .event:     return "calendar.badge.clock"
        case .other:     return "ellipsis.circle.fill"
        }
    }
}

enum InteractionType: String, Codable, CaseIterable, Identifiable {
    case meeting         = "meeting"
    case call            = "call"
    case message         = "message"
    case email           = "email"
    case coffee          = "coffee"
    case event           = "event"
    case misunderstanding = "misunderstanding"
    case conflict        = "conflict"
    case sorry           = "sorry"
    case other           = "other"

    var id: String { rawValue }

    var isConflict: Bool {
        [.misunderstanding, .conflict, .sorry].contains(self)
    }

    var label: String {
        switch self {
        case .meeting:          return "Встреча"
        case .call:             return "Звонок"
        case .message:          return "Сообщение"
        case .email:            return "Email"
        case .coffee:           return "Кофе"
        case .event:            return "Мероприятие"
        case .misunderstanding: return "Недопонимание"
        case .conflict:         return "Конфликт"
        case .sorry:            return "Извинение"
        case .other:            return "Другое"
        }
    }

    var icon: String {
        switch self {
        case .meeting:          return "person.2.fill"
        case .call:             return "phone.fill"
        case .message:          return "message.fill"
        case .email:            return "envelope.fill"
        case .coffee:           return "cup.and.saucer.fill"
        case .event:            return "calendar.badge.clock"
        case .misunderstanding: return "questionmark.bubble.fill"
        case .conflict:         return "bolt.fill"
        case .sorry:            return "heart.fill"
        case .other:            return "ellipsis.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .meeting:          return .blue
        case .call:             return .green
        case .message:          return .purple
        case .email:            return .orange
        case .coffee:           return .brown
        case .event:            return .pink
        case .misunderstanding: return .yellow
        case .conflict:         return .red
        case .sorry:            return .pink
        case .other:            return .secondary
        }
    }
}

// MARK: - Important Date

struct ImportantDate: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var label: String       // e.g. "Годовщина партнёрства", "Дата сделки"
    var date: Date

    /// Days until next occurrence of this annual date (same month/day, next year if needed)
    var daysUntilNext: Int {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var comps = cal.dateComponents([.month, .day], from: date)
        comps.year = cal.component(.year, from: today)
        var next = cal.date(from: comps) ?? date
        if next < today {
            next = cal.date(byAdding: .year, value: 1, to: next) ?? next
        }
        return cal.dateComponents([.day], from: today, to: next).day ?? 0
    }
}

// MARK: - Person

@Model
final class Person {
    var id: UUID
    var name: String
    var role: String
    var company: String
    var email: String
    var phone: String
    var telegramUsername: String  // without @
    var categoryTags: [String]
    var notes: String
    var colorHex: String
    var createdAt: Date
    var sourceRaw: String
    var meetingPlace: String
    var birthday: Date?
    var importantDates: [ImportantDate] = []

    /// Who introduced me to this person.
    var introducer: Person?

    @Relationship(deleteRule: .cascade, inverse: \Interaction.person)
    var interactions: [Interaction]

    var source: ContactSource {
        get { ContactSource(rawValue: sourceRaw) ?? .other }
        set { sourceRaw = newValue.rawValue }
    }

    init(
        name: String,
        role: String = "",
        company: String = "",
        email: String = "",
        phone: String = "",
        telegramUsername: String = "",
        categoryTags: [String] = [],
        notes: String = "",
        colorHex: String = "#4F8EF7",
        source: ContactSource = .other,
        meetingPlace: String = "",
        birthday: Date? = nil,
        importantDates: [ImportantDate] = []
    ) {
        self.id = UUID()
        self.name = name
        self.role = role
        self.company = company
        self.email = email
        self.phone = phone
        self.telegramUsername = telegramUsername
        self.categoryTags = categoryTags
        self.notes = notes
        self.colorHex = colorHex
        self.createdAt = Date()
        self.sourceRaw = source.rawValue
        self.meetingPlace = meetingPlace
        self.birthday = birthday
        self.importantDates = importantDates
        self.introductions = []
        self.interactions = []
    }

    var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first }.map(String.init).joined()
    }

    var displayRole: String {
        [role, company].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var lastInteraction: Interaction? {
        interactions.sorted { $0.date > $1.date }.first
    }

    var sortedInteractions: [Interaction] {
        interactions.sorted { $0.date > $1.date }
    }

    /// People this person introduced me to.
    var introductions: [Person]

    /// Days until next birthday (nil if birthday not set)
    var daysUntilBirthday: Int? {
        guard let bd = birthday else { return nil }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var comps = cal.dateComponents([.month, .day], from: bd)
        comps.year = cal.component(.year, from: today)
        var next = cal.date(from: comps) ?? bd
        if next < today {
            next = cal.date(byAdding: .year, value: 1, to: next) ?? next
        }
        return cal.dateComponents([.day], from: today, to: next).day
    }

    /// True if birthday is today
    var isBirthdayToday: Bool {
        guard let days = daysUntilBirthday else { return false }
        return days == 0
    }

    /// True if birthday is within the next 7 days
    var birthdaySoon: Bool {
        guard let days = daysUntilBirthday else { return false }
        return days <= 7
    }

    /// Upcoming important dates within 30 days, sorted by proximity
    var upcomingDates: [ImportantDate] {
        importantDates
            .filter { $0.daysUntilNext <= 30 }
            .sorted { $0.daysUntilNext < $1.daysUntilNext }
    }

    /// Formatted age string from birthday
    var ageString: String? {
        guard let bd = birthday else { return nil }
        let years = Calendar.current.dateComponents([.year], from: bd, to: Date()).year ?? 0
        return years > 0 ? "\(years) лет" : nil
    }

    static let avatarColors: [String] = [
        "#4F8EF7", "#FF6B6B", "#4ECDC4", "#FFD93D",
        "#6BCB77", "#C77DFF", "#FF9F43", "#F8B195"
    ]
}
