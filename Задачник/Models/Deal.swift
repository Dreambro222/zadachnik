import SwiftData
import Foundation
import SwiftUI

enum DealStatus: String, Codable, CaseIterable, Identifiable {
    case active    = "active"
    case completed = "completed"
    case cancelled = "cancelled"
    case paused    = "paused"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .active:    return "Активна"
        case .completed: return "Выполнена"
        case .cancelled: return "Отменена"
        case .paused:    return "Пауза"
        }
    }

    var color: Color {
        switch self {
        case .active:    return .blue
        case .completed: return .green
        case .cancelled: return .red
        case .paused:    return .orange
        }
    }

    var icon: String {
        switch self {
        case .active:    return "circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .cancelled: return "xmark.circle.fill"
        case .paused:    return "pause.circle.fill"
        }
    }
}

@Model
final class Deal {
    var id: UUID
    var title: String
    var notes: String
    var percent: Double       // 0–100
    var amount: Double        // сумма в валюте
    var currency: String      // "RUB", "USD", "EUR"
    var dueDate: Date?
    var statusRaw: String
    var createdAt: Date
    var personId: UUID?       // привязка к контакту

    var status: DealStatus {
        get { DealStatus(rawValue: statusRaw) ?? .active }
        set { statusRaw = newValue.rawValue }
    }

    var amountFormatted: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        let str = formatter.string(from: NSNumber(value: amount)) ?? "\(Int(amount))"
        return "\(str) \(currency)"
    }

    init(
        title: String,
        notes: String = "",
        percent: Double = 0,
        amount: Double = 0,
        currency: String = "RUB",
        dueDate: Date? = nil,
        status: DealStatus = .active,
        personId: UUID? = nil
    ) {
        self.id = UUID()
        self.title = title
        self.notes = notes
        self.percent = percent
        self.amount = amount
        self.currency = currency
        self.dueDate = dueDate
        self.statusRaw = status.rawValue
        self.createdAt = Date()
        self.personId = personId
    }
}
