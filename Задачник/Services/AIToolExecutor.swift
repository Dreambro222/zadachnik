import Foundation
import SwiftData

// MARK: - Tool Call Result (shown in chat)

struct AIToolCall: Identifiable, Equatable {
    let id = UUID()
    let toolName: String
    let displayName: String
    let result: String
    let isError: Bool

    static func success(_ toolName: String, _ result: String) -> AIToolCall {
        AIToolCall(toolName: toolName, displayName: humanName(for: toolName), result: result, isError: false)
    }

    static func failure(_ toolName: String, _ error: String) -> AIToolCall {
        AIToolCall(toolName: toolName, displayName: humanName(for: toolName), result: error, isError: true)
    }

    static func humanName(for toolName: String) -> String {
        switch toolName {
        case "list_tasks":           return "Список задач"
        case "search_tasks":         return "Поиск задач"
        case "create_task":          return "Создание задачи"
        case "update_task":          return "Обновление задачи"
        case "complete_task":        return "Выполнение задачи"
        case "delete_task":          return "Удаление задачи"
        case "list_notes":           return "Список заметок"
        case "create_note":          return "Создание заметки"
        case "update_note":          return "Обновление заметки"
        case "delete_note":          return "Удаление заметки"
        case "convert_note_to_task": return "Заметка → задача"
        case "list_projects":        return "Список проектов"
        case "create_project":       return "Создание проекта"
        case "add_to_calendar":      return "Событие в Календарь"
        case "list_people":          return "Список людей"
        case "create_person":        return "Создание контакта"
        case "create_interaction":   return "Запись взаимодействия"
        case "get_today_summary":    return "Сводка на сегодня"
        case "list_call_recordings": return "Записи звонков"
        default:                     return toolName
        }
    }
}

// MARK: - Executor

@MainActor
final class AIToolExecutor {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Execute a tool call. Returns (resultJSON, toolCall) for the chat.
    func execute(name: String, args: [String: Any]) async -> (String, AIToolCall) {
        do {
            let result = try await dispatch(name: name, args: args)
            NSLog("[AIToolExecutor] ✅ \(name) → \(result.prefix(120))")
            return (result, .success(name, result))
        } catch {
            let msg = error.localizedDescription
            NSLog("[AIToolExecutor] ❌ \(name): \(msg)")
            return ("{\"error\": \"\(msg)\"}", .failure(name, msg))
        }
    }

    // MARK: - Dispatch

    private func dispatch(name: String, args: [String: Any]) async throws -> String {
        switch name {
        case "list_tasks":           return try listTasks(args: args)
        case "search_tasks":         return try searchTasks(args: args)
        case "create_task":          return try await createTask(args: args)
        case "update_task":          return try updateTask(args: args)
        case "complete_task":        return try completeTask(args: args)
        case "delete_task":          return try deleteTask(args: args)
        case "list_notes":           return try listNotes(args: args)
        case "create_note":          return try createNote(args: args)
        case "update_note":          return try updateNote(args: args)
        case "delete_note":          return try deleteNote(args: args)
        case "convert_note_to_task": return try convertNoteToTask(args: args)
        case "list_projects":        return try listProjects()
        case "create_project":       return try createProject(args: args)
        case "add_to_calendar":      return try await addToCalendar(args: args)
        case "list_people":          return try listPeople(args: args)
        case "create_person":        return try createPerson(args: args)
        case "create_interaction":   return try createInteraction(args: args)
        case "get_today_summary":       return try getTodaySummary()
        case "list_call_recordings":    return try listCallRecordings(args: args)
        default:
            throw ToolError.unknown(name)
        }
    }

    // MARK: - Tasks

    private func listTasks(args: [String: Any]) throws -> String {
        let filter = args["filter"] as? String ?? "all"
        let projectName = args["project_name"] as? String
        let statusFilter = args["status"] as? String
        let limit = args["limit"] as? Int ?? 20

        var descriptor = FetchDescriptor<TaskItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 100

        let all = try modelContext.fetch(descriptor)
        let today = Calendar.current.startOfDay(for: Date())
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!

        var result = all.filter { $0.status != .done }

        switch filter {
        case "today":
            result = result.filter { task in
                guard let due = task.deadline else { return false }
                return due < tomorrow || task.status == .inProgress
            }
        case "overdue":
            result = result.filter { $0.isOverdue }
        default:
            break
        }

        if let pName = projectName, !pName.isEmpty {
            result = result.filter { $0.project?.name.localizedCaseInsensitiveContains(pName) == true }
        }

        if let s = statusFilter, !s.isEmpty {
            result = result.filter { $0.statusRaw == s }
        }

        result = Array(result.prefix(limit))

        if result.isEmpty { return "{\"tasks\": [], \"message\": \"Задач не найдено\"}" }

        let items = result.map { taskJSON($0) }
        return "{\"tasks\": [\(items.joined(separator: ","))], \"count\": \(items.count)}"
    }

    private func searchTasks(args: [String: Any]) throws -> String {
        guard let query = args["query"] as? String, !query.isEmpty else {
            throw ToolError.missingArg("query")
        }
        let descriptor = FetchDescriptor<TaskItem>()
        let all = try modelContext.fetch(descriptor)
        let found = all.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
            $0.notes.localizedCaseInsensitiveContains(query)
        }.prefix(20)
        if found.isEmpty { return "{\"tasks\": [], \"message\": \"Ничего не найдено по запросу: \(query)\"}" }
        let items = found.map { taskJSON($0) }
        return "{\"tasks\": [\(items.joined(separator: ","))], \"count\": \(items.count)}"
    }

    private func createTask(args: [String: Any]) async throws -> String {
        guard let title = args["title"] as? String, !title.isEmpty else {
            throw ToolError.missingArg("title")
        }
        let notes    = args["notes"] as? String ?? ""
        let priority = Priority(rawValue: args["priority"] as? Int ?? 0) ?? .none
        let tags     = args["tags"] as? [String] ?? []

        var deadline: Date?
        if let ds = args["deadline"] as? String {
            deadline = parseDate(ds)
        }

        var project: Project?
        if let pName = args["project_name"] as? String, !pName.isEmpty {
            project = try findProject(named: pName)
        }

        let task = TaskItem(
            title: title,
            notes: notes,
            priority: priority,
            deadline: deadline,
            tags: tags
        )
        task.project = project
        modelContext.insert(task)
        try modelContext.save()

        var calMsg = ""
        if args["add_to_calendar"] as? Bool == true, let due = deadline {
            if let eventId = try? await CalendarService.shared.createOrUpdateEvent(
                title: title,
                startDate: due,
                notes: notes,
                isAllDay: false
            ) {
                task.googleCalendarEventId = eventId
                try? modelContext.save()
                calMsg = ", добавлено в Календарь"
            }
        }

        return "{\"success\": true, \"task_id\": \"\(task.id)\", \"message\": \"Задача '\(title)' создана\(calMsg)\"}"
    }

    private func updateTask(args: [String: Any]) throws -> String {
        guard let idStr = args["task_id"] as? String,
              let uuid = UUID(uuidString: idStr) else {
            throw ToolError.missingArg("task_id")
        }

        var descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == uuid })
        descriptor.fetchLimit = 1
        guard let task = try modelContext.fetch(descriptor).first else {
            throw ToolError.notFound("Задача \(idStr)")
        }

        if let title = args["title"] as? String, !title.isEmpty { task.title = title }
        if let notes = args["notes"] as? String { task.notes = notes }
        if let pRaw = args["priority"] as? Int, let p = Priority(rawValue: pRaw) { task.priority = p }
        if let sRaw = args["status"] as? String, let s = TaskStatus(rawValue: sRaw) { task.status = s }
        if let tags = args["tags"] as? [String] { task.tags = tags }
        if let pct = args["completion_percent"] as? Int { task.completionPercent = max(0, min(100, pct)) }
        if let ds = args["deadline"] as? String { task.deadline = parseDate(ds) }

        try modelContext.save()
        return "{\"success\": true, \"message\": \"Задача '\(task.title)' обновлена\"}"
    }

    private func completeTask(args: [String: Any]) throws -> String {
        guard let idStr = args["task_id"] as? String,
              let uuid = UUID(uuidString: idStr) else {
            throw ToolError.missingArg("task_id")
        }
        var descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == uuid })
        descriptor.fetchLimit = 1
        guard let task = try modelContext.fetch(descriptor).first else {
            throw ToolError.notFound("Задача \(idStr)")
        }
        task.status = .done
        try modelContext.save()
        return "{\"success\": true, \"message\": \"Задача '\(task.title)' отмечена выполненной\"}"
    }

    private func deleteTask(args: [String: Any]) throws -> String {
        guard let idStr = args["task_id"] as? String,
              let uuid = UUID(uuidString: idStr) else {
            throw ToolError.missingArg("task_id")
        }
        var descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == uuid })
        descriptor.fetchLimit = 1
        guard let task = try modelContext.fetch(descriptor).first else {
            throw ToolError.notFound("Задача \(idStr)")
        }
        let title = task.title
        modelContext.delete(task)
        try modelContext.save()
        return "{\"success\": true, \"message\": \"Задача '\(title)' удалена\"}"
    }

    // MARK: - Notes

    private func listNotes(args: [String: Any]) throws -> String {
        let tag    = args["tag"] as? String
        let search = args["search"] as? String
        let limit  = args["limit"] as? Int ?? 20

        var descriptor = FetchDescriptor<QuickNote>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 100

        var notes = try modelContext.fetch(descriptor)

        if let t = tag, !t.isEmpty {
            notes = notes.filter { $0.tags.contains(t) }
        }
        if let s = search, !s.isEmpty {
            notes = notes.filter {
                $0.title.localizedCaseInsensitiveContains(s) ||
                $0.body.localizedCaseInsensitiveContains(s)
            }
        }
        notes = Array(notes.prefix(limit))

        if notes.isEmpty { return "{\"notes\": [], \"message\": \"Заметок не найдено\"}" }

        let items = notes.map { n in
            "{\"id\":\"\(n.id)\",\"title\":\(jsonStr(n.title.isEmpty ? n.body.prefix(50).description : n.title)),\"body_preview\":\(jsonStr(String(n.body.prefix(120)))),\"tags\":\(jsonArr(n.tags)),\"created_at\":\"\(isoDate(n.createdAt))\"}"
        }
        return "{\"notes\": [\(items.joined(separator: ","))], \"count\": \(items.count)}"
    }

    private func createNote(args: [String: Any]) throws -> String {
        guard let body = args["body"] as? String, !body.isEmpty else {
            throw ToolError.missingArg("body")
        }
        let title = args["title"] as? String ?? ""
        let tags  = args["tags"] as? [String] ?? []

        NSLog("[AIToolExecutor] createNote — title='\(title)' body='\(body.prefix(60))'")
        let note = QuickNote(body: body, title: title, tags: tags)
        modelContext.insert(note)
        do {
            try modelContext.save()
            NSLog("[AIToolExecutor] createNote — saved OK, id=\(note.id)")
        } catch {
            NSLog("[AIToolExecutor] createNote — save FAILED: \(error)")
            throw error
        }
        return "{\"success\": true, \"note_id\": \"\(note.id)\", \"message\": \"Заметка '\(title.isEmpty ? String(body.prefix(40)) : title)' создана\"}"
    }

    private func updateNote(args: [String: Any]) throws -> String {
        guard let idStr = args["note_id"] as? String,
              let uuid = UUID(uuidString: idStr) else {
            throw ToolError.missingArg("note_id")
        }
        var descriptor = FetchDescriptor<QuickNote>(predicate: #Predicate { $0.id == uuid })
        descriptor.fetchLimit = 1
        guard let note = try modelContext.fetch(descriptor).first else {
            throw ToolError.notFound("Заметка \(idStr)")
        }
        if let title = args["title"] as? String { note.title = title }
        if let body  = args["body"]  as? String { note.body  = body }
        if let tags  = args["tags"]  as? [String] { note.tags = tags }
        try modelContext.save()
        return "{\"success\": true, \"message\": \"Заметка обновлена\"}"
    }

    private func deleteNote(args: [String: Any]) throws -> String {
        guard let idStr = args["note_id"] as? String,
              let uuid = UUID(uuidString: idStr) else {
            throw ToolError.missingArg("note_id")
        }
        var descriptor = FetchDescriptor<QuickNote>(predicate: #Predicate { $0.id == uuid })
        descriptor.fetchLimit = 1
        guard let note = try modelContext.fetch(descriptor).first else {
            throw ToolError.notFound("Заметка \(idStr)")
        }
        modelContext.delete(note)
        try modelContext.save()
        return "{\"success\": true, \"message\": \"Заметка удалена\"}"
    }

    private func convertNoteToTask(args: [String: Any]) throws -> String {
        guard let idStr = args["note_id"] as? String,
              let uuid = UUID(uuidString: idStr) else {
            throw ToolError.missingArg("note_id")
        }
        var descriptor = FetchDescriptor<QuickNote>(predicate: #Predicate { $0.id == uuid })
        descriptor.fetchLimit = 1
        guard let note = try modelContext.fetch(descriptor).first else {
            throw ToolError.notFound("Заметка \(idStr)")
        }

        let taskTitle = (args["task_title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (note.title.isEmpty ? String(note.body.prefix(80)) : note.title)

        let task = TaskItem(title: taskTitle, notes: note.body, tags: note.tags)
        modelContext.insert(task)
        note.convertedToTask = true
        try modelContext.save()
        return "{\"success\": true, \"task_id\": \"\(task.id)\", \"message\": \"Заметка конвертирована в задачу '\(taskTitle)'\"}"
    }

    // MARK: - Projects

    private func listProjects() throws -> String {
        let descriptor = FetchDescriptor<Project>(sortBy: [SortDescriptor(\.sortOrder)])
        let projects = try modelContext.fetch(descriptor)
        if projects.isEmpty { return "{\"projects\": [], \"message\": \"Нет проектов\"}" }
        let items = projects.map { p in
            "{\"id\":\"\(p.id)\",\"name\":\(jsonStr(p.name)),\"task_count\":\(p.tasks.filter { $0.status != .done }.count),\"icon\":\"\(p.icon)\"}"
        }
        return "{\"projects\": [\(items.joined(separator: ","))], \"count\": \(items.count)}"
    }

    private func createProject(args: [String: Any]) throws -> String {
        guard let name = args["name"] as? String, !name.isEmpty else {
            throw ToolError.missingArg("name")
        }
        let colors = Project.colorPalette
        let color = args["color"] as? String ?? colors[Int.random(in: 0..<colors.count)]
        let icon  = args["icon"]  as? String ?? "folder.fill"

        let descriptor = FetchDescriptor<Project>()
        let count = (try? modelContext.fetch(descriptor).count) ?? 0

        let project = Project(name: name, colorHex: color, icon: icon, sortOrder: count)
        modelContext.insert(project)
        try modelContext.save()
        return "{\"success\": true, \"project_id\": \"\(project.id)\", \"message\": \"Проект '\(name)' создан\"}"
    }

    // MARK: - Calendar

    private func addToCalendar(args: [String: Any]) async throws -> String {
        guard let title = args["title"] as? String, !title.isEmpty else {
            throw ToolError.missingArg("title")
        }
        guard let dateStr = args["date"] as? String, let date = parseDate(dateStr) else {
            throw ToolError.missingArg("date (ISO 8601)")
        }
        let notes    = args["notes"] as? String ?? ""
        let isAllDay = args["all_day"] as? Bool ?? false
        var endDate: Date? = nil
        if let endStr = args["end_date"] as? String { endDate = parseDate(endStr) }

        let eventId = try await CalendarService.shared.createOrUpdateEvent(
            title: title,
            startDate: date,
            endDate: endDate,
            notes: notes,
            isAllDay: isAllDay
        )
        return "{\"success\": true, \"event_id\": \"\(eventId)\", \"message\": \"Событие '\(title)' добавлено в Календарь\"}"
    }

    // MARK: - People

    private func listPeople(args: [String: Any]) throws -> String {
        let search = args["search"] as? String
        let descriptor = FetchDescriptor<Person>(sortBy: [SortDescriptor(\.name)])
        var people = try modelContext.fetch(descriptor)
        if let s = search, !s.isEmpty {
            people = people.filter {
                $0.name.localizedCaseInsensitiveContains(s) ||
                $0.company.localizedCaseInsensitiveContains(s)
            }
        }
        if people.isEmpty { return "{\"people\": [], \"message\": \"Никого не найдено\"}" }
        let items = people.prefix(30).map { p in
            "{\"id\":\"\(p.id)\",\"name\":\(jsonStr(p.name)),\"role\":\(jsonStr(p.role)),\"company\":\(jsonStr(p.company))}"
        }
        return "{\"people\": [\(items.joined(separator: ","))], \"count\": \(items.count)}"
    }

    private func createPerson(args: [String: Any]) throws -> String {
        guard let name = args["name"] as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ToolError.missingArg("name")
        }

        // Check duplicate
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let existing = try modelContext.fetch(FetchDescriptor<Person>())
        if let dup = existing.first(where: { $0.name.localizedCaseInsensitiveCompare(trimmedName) == .orderedSame }) {
            return "{\"status\":\"already_exists\",\"id\":\"\(dup.id)\",\"name\":\(jsonStr(dup.name)),\"message\":\"Контакт уже существует\"}"
        }

        let source: ContactSource = {
            guard let raw = args["source"] as? String else { return .other }
            return ContactSource(rawValue: raw) ?? .other
        }()

        let telegram = (args["telegram"] as? String ?? "")
            .trimmingCharacters(in: .init(charactersIn: "@"))

        let tags = args["tags"] as? [String] ?? []

        // Pick avatar color deterministically from name hash
        let colorIndex = abs(trimmedName.hashValue) % Person.avatarColors.count
        let color = Person.avatarColors[colorIndex]

        let person = Person(
            name: trimmedName,
            role:             args["role"]          as? String ?? "",
            company:          args["company"]       as? String ?? "",
            email:            args["email"]         as? String ?? "",
            phone:            args["phone"]         as? String ?? "",
            telegramUsername: telegram,
            categoryTags:     tags,
            notes:            args["notes"]         as? String ?? "",
            colorHex:         color,
            source:           source,
            meetingPlace:     args["meeting_place"] as? String ?? ""
        )

        modelContext.insert(person)
        try modelContext.save()

        NSLog("[AIToolExecutor] ✅ create_person: \(trimmedName) id=\(person.id)")
        return "{\"status\":\"created\",\"id\":\"\(person.id)\",\"name\":\(jsonStr(trimmedName)),\"message\":\"Контакт '\(trimmedName)' добавлен\"}"
    }

    private func createInteraction(args: [String: Any]) throws -> String {
        guard let personName = args["person_name"] as? String, !personName.isEmpty else {
            throw ToolError.missingArg("person_name")
        }
        guard let typeStr = args["type"] as? String,
              let interactionType = InteractionType(rawValue: typeStr) else {
            throw ToolError.missingArg("type")
        }

        let descriptor = FetchDescriptor<Person>()
        let people = try modelContext.fetch(descriptor)
        guard let person = people.first(where: {
            $0.name.localizedCaseInsensitiveContains(personName)
        }) else {
            throw ToolError.notFound("Человек '\(personName)'")
        }

        let notes  = args["notes"]  as? String ?? ""
        let result = args["result"] as? String ?? ""

        let interaction = Interaction(type: interactionType, notes: notes, result: result)
        interaction.person = person
        modelContext.insert(interaction)
        try modelContext.save()
        return "{\"success\": true, \"message\": \"Записано взаимодействие '\(interactionType.label)' с \(person.name)\"}"
    }

    // MARK: - Today Summary

    private func getTodaySummary() throws -> String {
        let taskDesc = FetchDescriptor<TaskItem>()
        let allTasks = try modelContext.fetch(taskDesc)

        let today = Calendar.current.startOfDay(for: Date())
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!

        let todayTasks   = allTasks.filter { t in
            guard t.status != .done, let due = t.deadline else { return false }
            return due >= today && due < tomorrow
        }
        let overdueTasks = allTasks.filter { $0.isOverdue }
        let inProgress   = allTasks.filter { $0.status == .inProgress }

        let noteDesc = FetchDescriptor<QuickNote>()
        let recentNotes = try modelContext.fetch(noteDesc)

        let df = DateFormatter()
        df.locale = Locale(identifier: "ru_RU")
        df.dateStyle = .full
        let dateStr = df.string(from: Date())

        return """
        {
          "date": "\(dateStr)",
          "today_tasks": [\(todayTasks.map { taskJSON($0) }.joined(separator: ","))],
          "overdue_tasks": [\(overdueTasks.map { taskJSON($0) }.joined(separator: ","))],
          "in_progress_tasks": [\(inProgress.map { taskJSON($0) }.joined(separator: ","))],
          "total_notes": \(recentNotes.count),
          "counts": {
            "today": \(todayTasks.count),
            "overdue": \(overdueTasks.count),
            "in_progress": \(inProgress.count)
          }
        }
        """
    }

    // MARK: - Call Recordings

    private func listCallRecordings(args: [String: Any]) throws -> String {
        let callerNameFilter = args["caller_name"] as? String
        let sourceFilter = args["source"] as? String
        let limit = args["limit"] as? Int ?? 10

        var descriptor = FetchDescriptor<VoiceMemo>(
            predicate: #Predicate { $0.isCallRecording == true },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit

        let memos = try modelContext.fetch(descriptor)

        let filtered = memos.filter { memo in
            if let caller = callerNameFilter, !caller.isEmpty {
                guard memo.callerName.localizedCaseInsensitiveContains(caller) else { return false }
            }
            if let src = sourceFilter, !src.isEmpty {
                guard memo.callSourceRaw == src else { return false }
            }
            return true
        }

        if filtered.isEmpty {
            return "{\"recordings\": [], \"message\": \"Записей звонков не найдено\"}"
        }

        let items = filtered.map { m -> String in
            let transcription = m.transcription.isEmpty ? "" : m.transcription
            let truncated = transcription.count > 300 ? String(transcription.prefix(300)) + "..." : transcription
            return """
            {"id":"\(m.id)","caller":"\(m.callerName)","source":"\(m.callSourceRaw)","duration":"\(m.durationLabel)","date":"\(isoDate(m.createdAt))","transcription":\(jsonStr(truncated)),"whisper_used":\(m.whisperUsed)}
            """
        }.joined(separator: ",")

        return "{\"recordings\": [\(items)], \"total\": \(filtered.count)}"
    }

    // MARK: - Helpers

    private func findProject(named name: String) throws -> Project? {
        let descriptor = FetchDescriptor<Project>()
        let projects = try modelContext.fetch(descriptor)
        return projects.first { $0.name.localizedCaseInsensitiveContains(name) }
    }

    private func taskJSON(_ t: TaskItem) -> String {
        let due = t.deadline.map { "\"\(isoDate($0))\"" } ?? "null"
        return "{\"id\":\"\(t.id)\",\"title\":\(jsonStr(t.title)),\"status\":\(jsonStr(t.statusRaw)),\"priority\":\(t.priorityRaw),\"deadline\":\(due),\"project\":\(jsonStr(t.project?.name ?? "")),\"tags\":\(jsonArr(t.tags))}"
    }

    private func parseDate(_ string: String) -> Date? {
        let formatters = [
            ISO8601DateFormatter(),
            {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withFullDate]
                return f
            }()
        ]
        for f in formatters {
            if let d = f.date(from: string) { return d }
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            df.dateFormat = fmt
            if let d = df.date(from: string) { return d }
        }
        return nil
    }

    private func isoDate(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func jsonStr(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    private func jsonArr(_ arr: [String]) -> String {
        "[" + arr.map { jsonStr($0) }.joined(separator: ",") + "]"
    }
}

// MARK: - Errors

enum ToolError: LocalizedError {
    case missingArg(String)
    case notFound(String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .missingArg(let a): return "Отсутствует аргумент: \(a)"
        case .notFound(let e):   return "Не найдено: \(e)"
        case .unknown(let t):    return "Неизвестный инструмент: \(t)"
        }
    }
}
