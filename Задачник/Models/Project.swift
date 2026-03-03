import SwiftData
import Foundation

@Model
final class Project {
    var id: UUID
    var name: String
    var colorHex: String = "#4F8EF7"
    var icon: String = "folder.fill"
    var sortOrder: Int
    var createdAt: Date
    var kanbanColumns: [String]
    var dueDate: Date?
    var googleCalendarEventId: String = ""

    @Relationship(deleteRule: .cascade, inverse: \TaskItem.project)
    var tasks: [TaskItem]

    init(
        name: String,
        colorHex: String = "#4F8EF7",
        icon: String = "folder.fill",
        sortOrder: Int = 0
    ) {
        self.id = UUID()
        self.name = name
        self.colorHex = colorHex
        self.icon = icon
        self.sortOrder = sortOrder
        self.createdAt = Date()
        self.kanbanColumns = ["todo", "inProgress", "review", "done"]
        self.tasks = []
        self.dueDate = nil
        self.googleCalendarEventId = ""
    }

    var activeTasks: [TaskItem] {
        tasks.filter { $0.status != .done }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    var completedTasks: [TaskItem] {
        tasks.filter { $0.status == .done }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    static let columnLabels: [String: String] = [
        "todo": "К выполнению",
        "inProgress": "В работе",
        "review": "На проверке",
        "done": "Выполнено"
    ]

    static let colorPalette: [String] = [
        "#4F8EF7", "#FF6B6B", "#4ECDC4", "#FFD93D",
        "#6BCB77", "#C77DFF", "#FF9F43", "#A0C4FF"
    ]

    static let iconOptions: [String] = [
        "folder.fill", "star.fill", "heart.fill", "bolt.fill",
        "flame.fill", "briefcase.fill", "house.fill", "cart.fill",
        "book.fill", "gamecontroller.fill", "airplane", "bicycle"
    ]
}
