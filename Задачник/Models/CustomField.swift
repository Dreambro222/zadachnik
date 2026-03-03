import SwiftData
import Foundation
import SwiftUI

enum CustomFieldType: String, Codable, CaseIterable, Identifiable {
    case text   = "text"
    case number = "number"
    case date   = "date"
    case select = "select"
    case toggle = "toggle"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .text:   return "Текст"
        case .number: return "Число"
        case .date:   return "Дата"
        case .select: return "Выбор"
        case .toggle: return "Переключатель"
        }
    }

    var icon: String {
        switch self {
        case .text:   return "text.alignleft"
        case .number: return "number"
        case .date:   return "calendar"
        case .select: return "list.bullet"
        case .toggle: return "togglepower"
        }
    }
}

/// Defines a custom field schema (shared template)
@Model
final class CustomField {
    var id: UUID
    var name: String
    var typeRaw: String
    var selectOptions: [String]   // for .select type
    var sortOrder: Int
    var createdAt: Date

    var type: CustomFieldType {
        get { CustomFieldType(rawValue: typeRaw) ?? .text }
        set { typeRaw = newValue.rawValue }
    }

    init(name: String, type: CustomFieldType = .text, selectOptions: [String] = [], sortOrder: Int = 0) {
        self.id = UUID()
        self.name = name
        self.typeRaw = type.rawValue
        self.selectOptions = selectOptions
        self.sortOrder = sortOrder
        self.createdAt = Date()
    }
}

/// Stores the actual value for a specific task
@Model
final class CustomFieldValue {
    var id: UUID
    var fieldId: UUID
    var taskId: UUID
    var textValue: String
    var numberValue: Double
    var dateValue: Date?
    var boolValue: Bool
    var updatedAt: Date

    init(fieldId: UUID, taskId: UUID) {
        self.id = UUID()
        self.fieldId = fieldId
        self.taskId = taskId
        self.textValue = ""
        self.numberValue = 0
        self.dateValue = nil
        self.boolValue = false
        self.updatedAt = Date()
    }
}
