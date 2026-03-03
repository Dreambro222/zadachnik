import SwiftData
import Foundation
import SwiftUI

// MARK: - Priority (1–5 stars, как в Airtable rating)

enum Priority: Int, Codable, CaseIterable, Identifiable {
    case none = 0, low = 1, medium = 2, high = 3, critical = 4, top = 5

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .none:     return "Нет"
        case .low:      return "★"
        case .medium:   return "★★"
        case .high:     return "★★★"
        case .critical: return "★★★★"
        case .top:      return "★★★★★"
        }
    }

    var icon: String { "flag.fill" }

    var colorHex: String {
        switch self {
        case .none:     return "#8E8E93"
        case .low:      return "#34C759"
        case .medium:   return "#007AFF"
        case .high:     return "#FF9500"
        case .critical: return "#FF3B30"
        case .top:      return "#FF2D55"
        }
    }

    var color: Color { Color(hex: colorHex) }
}

// MARK: - TaskStatus (совпадает с Airtable singleSelect вариантами)

enum TaskStatus: String, Codable, CaseIterable, Identifiable {
    case todo       = "Надо сделать"
    case inProgress = "В работе"
    case done       = "Готово"
    case blocked    = "Заблокировано"
    case review     = "На проверке"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .todo:       return "circle"
        case .inProgress: return "circle.dotted"
        case .done:       return "checkmark.circle.fill"
        case .blocked:    return "xmark.circle.fill"
        case .review:     return "eye.circle"
        }
    }

    var color: Color {
        switch self {
        case .todo:       return .secondary
        case .inProgress: return .blue
        case .done:       return .green
        case .blocked:    return .red
        case .review:     return .orange
        }
    }
}

// MARK: - TaskDirection (Направление)

enum TaskDirection: String, Codable, CaseIterable, Identifiable {
    case none        = ""
    case product     = "Продукт"
    case marketing   = "Маркетинг"
    case operations  = "Операционка"
    case finance     = "Финансы"
    case hr          = "HR"
    case sales       = "Продажи"
    case development = "Разработка"
    case other       = "Другое"

    var id: String { rawValue }
    var label: String { rawValue.isEmpty ? "Не указано" : rawValue }
}

// MARK: - TaskType (Операционка \ Развитие)

enum TaskType: String, Codable, CaseIterable, Identifiable {
    case none        = ""
    case operations  = "Операционка"
    case development = "Развитие"

    var id: String { rawValue }
    var label: String { rawValue.isEmpty ? "Не указано" : rawValue }
}

// MARK: - MeetingFlag (Вынести на звонок)

enum MeetingFlag: String, Codable, CaseIterable, Identifiable {
    case none = ""
    case yes  = "Да"
    case no   = "Нет"

    var id: String { rawValue }
    var label: String { rawValue.isEmpty ? "—" : rawValue }
}

// MARK: - Top1Flag (ТОП1)

enum Top1Flag: String, Codable, CaseIterable, Identifiable {
    case none = ""
    case yes  = "Да"
    case no   = "Нет"

    var id: String { rawValue }
    var label: String { rawValue.isEmpty ? "—" : rawValue }
}

// MARK: - TaskItem

@Model
final class TaskItem {

    // ── Core (= Airtable) ──────────────────────────────────────────────────
    var id: UUID
    var title: String                   // Кратко о задаче
    var notes: String                   // Описание задачи
    var taskResult: String              // Результат выполнения задачи
    var resourcesUsed: String           // Используемые ресурсы
    var monthlyResults: String          // Результаты за месяц
    var linkURL: String                 // ссылка

    // ── Status / Priority ─────────────────────────────────────────────────
    var priorityRaw: Int                // Приоритетность 0–5 (rating)
    var statusRaw: String               // Статус (singleSelect rawValue)
    var completionPercent: Int          // Готовность в % 0–100
    var taggedOnTask: Bool              // Тегнул по задаче (checkbox)

    // ── Classification ────────────────────────────────────────────────────
    var airtableProjects: [String]      // Проект (multipleSelects)
    var directionRaw: String            // Направление (singleSelect)
    var typeRaw: String                 // Операционка \ Развитие (singleSelect)
    var responsibles: [String]          // Ответственный (multipleSelects)

    // ── Dates ─────────────────────────────────────────────────────────────
    var createdAt: Date                 // Дата создания (auto)
    var startDate: Date?                // Дата начала работы
    var midCheckDate: Date?             // Дата промежуточной проверки
    var deadline: Date?                 // Deadline

    // ── Flags ─────────────────────────────────────────────────────────────
    var bringToMeetingRaw: String       // Вынести на звонок
    var top1Raw: String                 // ТОП1

    // ── Local only ────────────────────────────────────────────────────────
    var tags: [String]
    var kanbanColumn: String
    var estimatedMinutes: Int
    var sortOrder: Int
    var completedAt: Date?
    var linkedPersonId: UUID?

    // ── SwiftData relation ────────────────────────────────────────────────
    var project: Project?

    // ── Airtable sync ─────────────────────────────────────────────────────
    var airtableId: String              // "rec..." record id
    var airtableUpdatedAt: Date?

    // ── Calendar sync ─────────────────────────────────────────────────────
    var googleCalendarEventId: String   // EventKit event identifier

    // MARK: - Computed

    var priority: Priority {
        get { Priority(rawValue: priorityRaw) ?? .none }
        set { priorityRaw = newValue.rawValue }
    }

    var status: TaskStatus {
        get { TaskStatus(rawValue: statusRaw) ?? .todo }
        set {
            statusRaw = newValue.rawValue
            if newValue == .done {
                if completedAt == nil { completedAt = Date() }
            } else {
                completedAt = nil
            }
        }
    }

    var direction: TaskDirection {
        get { TaskDirection(rawValue: directionRaw) ?? .none }
        set { directionRaw = newValue.rawValue }
    }

    var taskType: TaskType {
        get { TaskType(rawValue: typeRaw) ?? .none }
        set { typeRaw = newValue.rawValue }
    }

    var bringToMeeting: MeetingFlag {
        get { MeetingFlag(rawValue: bringToMeetingRaw) ?? .none }
        set { bringToMeetingRaw = newValue.rawValue }
    }

    var top1: Top1Flag {
        get { Top1Flag(rawValue: top1Raw) ?? .none }
        set { top1Raw = newValue.rawValue }
    }

    // ── Legacy helpers ───────────────────────────────────────────────────

    /// Удобный алиас для UI, показывающего одну дату
    var dueDate: Date? {
        get { deadline }
        set { deadline = newValue }
    }

    var isOverdue: Bool {
        guard let due = deadline, status != .done else { return false }
        return due < Calendar.current.startOfDay(for: Date())
    }

    var isDueToday: Bool {
        guard let due = deadline else { return false }
        return Calendar.current.isDateInToday(due)
    }

    var isDueTomorrow: Bool {
        guard let due = deadline else { return false }
        return Calendar.current.isDateInTomorrow(due)
    }

    var overdueDays: Int {
        guard let due = deadline, status != .done, due < Date() else { return 0 }
        return Calendar.current.dateComponents([.day], from: due, to: Date()).day ?? 0
    }

    var importanceScore: Int {
        let pScore = priorityRaw * 3
        let oScore = min(overdueDays * 2, 20)
        let todayBonus = isDueToday ? 5 : 0
        return pScore + oScore + todayBonus
    }

    var estimatedTimeLabel: String {
        guard estimatedMinutes > 0 else { return "" }
        let h = estimatedMinutes / 60
        let m = estimatedMinutes % 60
        if h == 0 { return "\(m)м" }
        if m == 0 { return "\(h)ч" }
        return "\(h)ч \(m)м"
    }

    // MARK: - Checklist progress

    /// Returns checklist progress derived from `notes` rich-text blocks or plain text markdown-like checkboxes.
    /// If there are no checklist items, `total` is 0.
    static func checklistStats(from raw: String) -> (checked: Int, total: Int) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (0, 0) }

        // 1) RichText JSON format: [{ type: "checklist", checked: Bool, ... }]
        if let data = trimmed.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            let checklistItems = arr.filter { ($0["type"] as? String) == "checklist" }
            if !checklistItems.isEmpty {
                let checked = checklistItems.reduce(into: 0) { acc, item in
                    if (item["checked"] as? Bool) == true { acc += 1 }
                }
                return (checked, checklistItems.count)
            }
        }

        // 2) Plain text fallback: [ ]/[x], - [ ]/- [x], and unicode/emoji checklist formats
        var total = 0
        var checked = 0
        for line in trimmed.components(separatedBy: .newlines) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("○ ") || l.hasPrefix("☐ ") || l.hasPrefix("[ ]") || l.hasPrefix("[]") || l.hasPrefix("- [ ] ") {
                total += 1
            } else if l.hasPrefix("✅ ") || l.hasPrefix("☑ ") || l.hasPrefix("[x]") || l.hasPrefix("[X]") || l.hasPrefix("[✓]") || l.hasPrefix("- [x] ") || l.hasPrefix("- [X] ") {
                total += 1
                checked += 1
            }
        }
        return (checked, total)
    }

    var checklistStats: (checked: Int, total: Int) {
        Self.checklistStats(from: notes)
    }

    var checklistProgressPercent: Int? {
        let stats = checklistStats
        guard stats.total > 0 else { return nil }
        return Int((Double(stats.checked) / Double(stats.total) * 100.0).rounded())
    }

    // MARK: - Init

    init(
        title: String,
        notes: String = "",
        taskResult: String = "",
        resourcesUsed: String = "",
        monthlyResults: String = "",
        linkURL: String = "",
        priority: Priority = .none,
        status: TaskStatus = .todo,
        completionPercent: Int = 0,
        taggedOnTask: Bool = false,
        airtableProjects: [String] = [],
        direction: TaskDirection = .none,
        taskType: TaskType = .none,
        responsibles: [String] = [],
        startDate: Date? = nil,
        midCheckDate: Date? = nil,
        deadline: Date? = nil,
        bringToMeeting: MeetingFlag = .none,
        top1: Top1Flag = .none,
        tags: [String] = [],
        kanbanColumn: String = "todo",
        estimatedMinutes: Int = 0,
        sortOrder: Int = 0,
        linkedPersonId: UUID? = nil
    ) {
        self.id = UUID()
        self.title = title
        self.notes = notes
        self.taskResult = taskResult
        self.resourcesUsed = resourcesUsed
        self.monthlyResults = monthlyResults
        self.linkURL = linkURL
        self.priorityRaw = priority.rawValue
        self.statusRaw = status.rawValue
        self.completionPercent = completionPercent
        self.taggedOnTask = taggedOnTask
        self.airtableProjects = airtableProjects
        self.directionRaw = direction.rawValue
        self.typeRaw = taskType.rawValue
        self.responsibles = responsibles
        self.createdAt = Date()
        self.startDate = startDate
        self.midCheckDate = midCheckDate
        self.deadline = deadline
        self.bringToMeetingRaw = bringToMeeting.rawValue
        self.top1Raw = top1.rawValue
        self.tags = tags
        self.kanbanColumn = kanbanColumn
        self.estimatedMinutes = estimatedMinutes
        self.sortOrder = sortOrder
        self.completedAt = nil
        self.linkedPersonId = linkedPersonId
        self.airtableId = ""
        self.airtableUpdatedAt = nil
        self.googleCalendarEventId = ""
    }
}
