import SwiftData
import Foundation

@Model
final class QuickNote {
    var id: UUID
    var body: String
    var title: String
    var createdAt: Date
    var deadline: Date?
    var calendarEventId: String
    var deadlineIncludesTime: Bool
    var isPinned: Bool
    var convertedToTask: Bool
    var tags: [String]

    init(body: String, title: String = "", tags: [String] = []) {
        self.id = UUID()
        self.body = body
        self.title = title
        self.createdAt = Date()
        self.deadline = nil
        self.calendarEventId = ""
        self.deadlineIncludesTime = false
        self.isPinned = false
        self.convertedToTask = false
        self.tags = tags
    }
}
