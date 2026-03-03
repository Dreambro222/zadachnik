import SwiftUI
import SwiftData

struct TaskDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Project.sortOrder) private var projects: [Project]
    @Query(sort: \Person.name) private var people: [Person]
    @Query(sort: \CustomField.sortOrder) private var customFields: [CustomField]
    @StateObject private var cal = CalendarService.shared

    var task: TaskItem?
    var project: Project?
    var initialColumn: String = "todo"
    var embedded: Bool = false
    var onClose: (() -> Void)? = nil
    var onSaved: ((TaskItem) -> Void)? = nil

    // ── Core ──────────────────────────────────────────────────────────────
    @State private var title = ""
    @State private var notes = ""
    @State private var taskResult = ""
    @State private var resourcesUsed = ""
    @State private var monthlyResults = ""
    @State private var linkURL = ""

    // ── Status / Priority ─────────────────────────────────────────────────
    @State private var priority: Priority = .none
    @State private var status: TaskStatus = .todo
    @State private var completionPercent: Int = 0
    @State private var taggedOnTask: Bool = false

    // ── Classification ────────────────────────────────────────────────────
    @State private var selectedProject: Project?
    @State private var airtableProjects: [String] = []
    @State private var direction: TaskDirection = .none
    @State private var taskType: TaskType = .none
    @State private var responsibles: [String] = []

    // ── Dates ─────────────────────────────────────────────────────────────
    @State private var hasStartDate = false
    @State private var startDate = Date()
    @State private var hasMidCheck = false
    @State private var midCheckDate = Date()
    @State private var hasDeadline = false
    @State private var deadline = Date()

    // ── Flags ─────────────────────────────────────────────────────────────
    @State private var bringToMeeting: MeetingFlag = .none
    @State private var top1: Top1Flag = .none

    // ── Local ─────────────────────────────────────────────────────────────
    @State private var tags: [String] = []
    @State private var kanbanColumn = "todo"
    @State private var estimatedMinutes = 0
    @State private var linkedPersonId: UUID? = nil

    // ── Calendar / Deadline header ────────────────────────────────────────
    @State private var showDeadlinePicker = false
    @State private var calendarSyncStatus: TaskCalendarSyncStatus = .idle
    @State private var addToCalendar = false        // автосинк при сохранении
    @State private var addedToCalendar = false
    @State private var calendarError: String? = nil
    @State private var deadlineIncludesTime = false // пользователь выбрал время

    enum TaskCalendarSyncStatus {
        case idle, syncing, synced, error(String)
    }

    // ── Custom fields ─────────────────────────────────────────────────────
    @State private var fieldValues: [UUID: String] = [:]

    // ── Airtable sync ─────────────────────────────────────────────────────
    @State private var isSyncing = false
    @State private var syncError: String? = nil
    @State private var autoSaveWorkItem: DispatchWorkItem?
    @State private var didInitialLoad = false

    @FocusState private var titleFocused: Bool

    private var isEditing: Bool { task != nil }
    private var navigationTitle: String { isEditing ? "Задача" : "Новая задача" }

    private var shareText: String {
        var parts: [String] = ["📋 \(title)"]
        if !notes.isEmpty { parts.append(notes) }
        if let due = task?.deadline { parts.append("📅 \(due.shortLabel)") }
        if !tags.isEmpty { parts.append(tags.map { "#\($0)" }.joined(separator: " ")) }
        return parts.joined(separator: "\n")
    }

    var body: some View {
        Group {
            if embedded {
                editorContent
            } else {
                NavigationStack {
                    editorContent
                }
            }
        }
    }

    private var editorContent: some View {
            VStack(spacing: 0) {
                // Deadline header — always visible at top
                taskDeadlineHeader
                Divider()
                Form {
                    coreSection
                    statusSection
                    classificationSection
                    datesSection
                    flagsSection
                    tagsSection
                    additionalTextSection
                    if !customFields.isEmpty { customFieldsSection }
                    if isEditing { actionsSection }
                }
                .formStyle(.grouped)
            }
        .navigationTitle(navigationTitle)
        .navigationInline()
        .toolbar {
            if !embedded || onClose != nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button(embedded ? "Закрыть" : "Отмена") { closeEditor() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                HStack(spacing: 12) {
                    if isEditing {
                        Button {
                            syncToAirtable()
                        } label: {
                            if isSyncing {
                                ProgressView().scaleEffect(0.8)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .foregroundStyle(.blue)
                            }
                        }
                        .disabled(isSyncing)
                    }
                    Button(isEditing ? "Готово" : "Создать") { saveTask() }
                        .fontWeight(.semibold)
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear {
            loadValues()
            didInitialLoad = true
        }
        .onDisappear {
            autoSaveWorkItem?.cancel()
            autoSaveNowIfNeeded()
        }
        .onChange(of: autoSaveKey) { _, _ in
            scheduleAutoSaveIfNeeded()
        }
        .onChange(of: notes) { _, _ in
            applyChecklistDerivedProgress()
        }
#if os(macOS)
        .onExitCommand {
            closeEditor()
        }
#endif
    }

    // MARK: - Sections

    private var coreSection: some View {
        Group {
            taskTitleSection
            taskDescriptionSection
        }
    }

    private var taskTitleSection: some View {
        Section("Задача") {
            TextField("Кратко о задаче", text: $title, axis: .vertical)
                .focused($titleFocused)
                .font(.body)
                .lineLimit(1...5)
        }
    }

    private var taskDescriptionSection: some View {
        Section("Описание задачи") {
#if os(macOS)
            taskNotesMiniToolbar
#endif
            RichTextEditor(raw: $notes, placeholder: "Описание, детали, контекст...", minHeight: 140)
                .frame(maxWidth: .infinity, minHeight: 320, alignment: .topLeading)
                .listRowInsets(.init(top: 8, leading: 2, bottom: 8, trailing: 2))
        }
    }

#if os(macOS)
    private var taskTitleWideBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Задача")
                .font(.headline)
            TextField("Кратко о задаче", text: $title, axis: .vertical)
                .focused($titleFocused)
                .font(.body)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func taskDescriptionWideBlock(minHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Описание задачи")
                    .font(.headline)
                Spacer()
            }
            taskNotesMiniToolbar
            RichTextEditor(raw: $notes, placeholder: "Описание, детали, контекст...", minHeight: minHeight)
                .frame(maxWidth: .infinity, minHeight: minHeight, maxHeight: .infinity, alignment: .topLeading)
        }
    }
#endif

#if os(macOS)
    private var taskNotesMiniToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                taskMiniButton("list.bullet") { insertTaskListPrefix("• ") }
                taskMiniButton("list.number") { insertTaskListPrefix("1. ") }
                taskMiniButton("checklist") { insertTaskListPrefix("○ ") }
                taskMiniButton("link") { insertTaskNotePrefix("https://") }
                taskMiniButton("paperclip") { insertTaskNotePrefix("📎 ") }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func taskMiniButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 24)
        }
        .buttonStyle(.plain)
    }

    private func insertTaskNotePrefix(_ prefix: String) {
        if TaskPlainTextView.insertAtCursor(prefix) {
            return
        }
        // Fallback when editor is not focused.
        if notes.isEmpty {
            notes = prefix
        } else if notes.hasSuffix("\n") {
            notes += prefix
        } else {
            notes += "\n" + prefix
        }
    }

    private func insertTaskListPrefix(_ prefix: String) {
        if TaskPlainTextView.insertListPrefixAtCursor(prefix) {
            return
        }
        if notes.isEmpty {
            notes = prefix
        } else if notes.hasSuffix("\n") {
            notes += prefix
        } else {
            notes += "\n" + prefix
        }
    }
#endif

    private var statusSection: some View {
        Section("Статус и приоритет") {
            // Статус
            Picker("Статус", selection: $status) {
                ForEach(TaskStatus.allCases) { s in
                    Label(s.rawValue, systemImage: s.icon).tag(s)
                }
            }
            .pickerStyle(.menu)

            // Приоритетность (звёзды 0–5)
            VStack(alignment: .leading, spacing: 6) {
                Text("Приоритетность").font(.caption).foregroundStyle(.secondary)
                PriorityPicker(priority: $priority)
                    .padding(.vertical, 2)
            }

            // Готовность в %
            HStack {
                Text("Готовность")
                Spacer()
                Text("\(completionPercent)%").foregroundStyle(.secondary)
                Stepper("", value: $completionPercent, in: 0...100, step: 10)
                    .labelsHidden()
            }

            // Тегнул по задаче
            Toggle("Тегнул по задаче", isOn: $taggedOnTask).tint(.blue)

            // ТОП1
            Picker("ТОП1", selection: $top1) {
                ForEach(Top1Flag.allCases) { f in Text(f.label).tag(f) }
            }
            .pickerStyle(.menu)
        }
    }

    private var classificationSection: some View {
        Section("Классификация") {
            // Проект (local SwiftData)
            Picker("Проект", selection: $selectedProject) {
                Text("Без проекта").tag(Optional<Project>.none)
                ForEach(projects) { proj in
                    Label(proj.name, systemImage: proj.icon).tag(Optional(proj))
                }
            }
            .pickerStyle(.menu)

            if let proj = selectedProject {
                Picker("Колонка канбан", selection: $kanbanColumn) {
                    ForEach(proj.kanbanColumns, id: \.self) { col in
                        Text(Project.columnLabels[col] ?? col).tag(col)
                    }
                }
                .pickerStyle(.menu)
            }

            // Направление
            Picker("Направление", selection: $direction) {
                ForEach(TaskDirection.allCases) { d in Text(d.label).tag(d) }
            }
            .pickerStyle(.menu)

            // Операционка / Развитие
            Picker("Тип", selection: $taskType) {
                ForEach(TaskType.allCases) { t in Text(t.label).tag(t) }
            }
            .pickerStyle(.menu)

            // Ответственный (из людей в CRM)
            Picker("Ответственный", selection: $linkedPersonId) {
                Text("Не указан").tag(Optional<UUID>.none)
                ForEach(people) { p in
                    Text(p.name).tag(Optional(p.id))
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var datesSection: some View {
        Section("Даты") {
            // Дата начала работы
            Toggle("Дата начала работы", isOn: $hasStartDate).tint(.blue)
            if hasStartDate {
                DatePicker("Начало", selection: $startDate, displayedComponents: .date)
                    .datePickerStyle(.compact)
            }

            // Промежуточная проверка
            Toggle("Промежуточная проверка", isOn: $hasMidCheck).tint(.blue)
            if hasMidCheck {
                DatePicker("Проверка", selection: $midCheckDate, displayedComponents: .date)
                    .datePickerStyle(.compact)
            }

            // Дедлайн управляется через шапку сверху

            estimatedTimePicker
        }
    }

    private var flagsSection: some View {
        Section("Флаги") {
            Picker("Вынести на звонок", selection: $bringToMeeting) {
                ForEach(MeetingFlag.allCases) { f in Text(f.label).tag(f) }
            }
            .pickerStyle(.menu)

            if !linkURL.isEmpty || true {
                HStack {
                    Text("Ссылка")
                    Spacer()
                    TextField("https://...", text: $linkURL)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.secondary)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.URL)
                        #endif
                }
            }
        }
    }

    private var tagsSection: some View {
        Section("Теги") {
            TagInputView(tags: $tags)
        }
    }

    private var additionalTextSection: some View {
        Group {
            Section("Результат выполнения") {
                RichTextEditor(raw: $taskResult, placeholder: "Что было сделано, итог...", minHeight: 100)
                    .listRowInsets(.init(top: 8, leading: 8, bottom: 8, trailing: 8))
            }

            Section("Используемые ресурсы") {
                RichTextEditor(raw: $resourcesUsed, placeholder: "Ссылки, инструменты, люди...", minHeight: 80)
                    .listRowInsets(.init(top: 8, leading: 8, bottom: 8, trailing: 8))
            }

            Section("Результаты за месяц") {
                RichTextEditor(raw: $monthlyResults, placeholder: "Итоги, метрики, выводы...", minHeight: 80)
                    .listRowInsets(.init(top: 8, leading: 8, bottom: 8, trailing: 8))
            }
        }
    }

    private var customFieldsSection: some View {
        Section("Доп. поля") {
            ForEach(customFields) { field in
                customFieldRow(field)
            }
        }
    }

    private var actionsSection: some View {
        Group {
            Section {
                if let err = syncError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
                if let t = task, !t.airtableId.isEmpty {
                    Label("Синхронизировано с Airtable", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                }
            }

            Section {
                ShareLink(item: shareText) {
                    Label("Поделиться задачей", systemImage: "square.and.arrow.up")
                }
            }

            Section {
                Button(role: .destructive) {
                    if let task {
                        modelContext.delete(task)
                        try? modelContext.save()
                    }
                    closeEditor()
                } label: {
                    HStack {
                        Spacer()
                        Label("Удалить задачу", systemImage: "trash")
                        Spacer()
                    }
                }
            }
        }
    }

    // MARK: - Custom Field Row

    @ViewBuilder
    private func customFieldRow(_ field: CustomField) -> some View {
        let binding = Binding(
            get: { fieldValues[field.id] ?? "" },
            set: { fieldValues[field.id] = $0 }
        )

        HStack {
            Text(field.name)
            Spacer()
            switch field.type {
            case .text:
                TextField("...", text: binding)
                    .multilineTextAlignment(.trailing).foregroundStyle(.secondary)
            case .number:
                TextField("0", text: binding)
                    .multilineTextAlignment(.trailing).foregroundStyle(.secondary)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
            case .toggle:
                Toggle("", isOn: Binding(
                    get: { binding.wrappedValue == "true" },
                    set: { binding.wrappedValue = $0 ? "true" : "false" }
                ))
            case .select:
                Menu {
                    ForEach(field.selectOptions, id: \.self) { opt in
                        Button(opt) { fieldValues[field.id] = opt }
                    }
                } label: {
                    Text(binding.wrappedValue.isEmpty ? "Выбрать" : binding.wrappedValue)
                        .foregroundStyle(.secondary)
                }
            case .date:
                DatePicker(
                    "",
                    selection: Binding(
                        get: {
                            if let ts = Double(binding.wrappedValue) { return Date(timeIntervalSince1970: ts) }
                            return Date()
                        },
                        set: { binding.wrappedValue = "\($0.timeIntervalSince1970)" }
                    ),
                    displayedComponents: .date
                )
                .labelsHidden()
            }
        }
    }

    // MARK: - Estimated Time

    private var estimatedTimePicker: some View {
        HStack {
            Text("Оценка времени")
            Spacer()
            Text(estimatedMinutes == 0 ? "—" : formatMinutes(estimatedMinutes))
                .foregroundStyle(.secondary)
            Menu {
                Button("Нет") { estimatedMinutes = 0 }
                Divider()
                ForEach([15, 30, 45, 60, 90, 120, 180, 240, 360, 480], id: \.self) { min in
                    Button(formatMinutes(min)) { estimatedMinutes = min }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
                    .foregroundStyle(.secondary).font(.caption)
            }
        }
    }

    // MARK: - Load / Save

    private func loadValues() {
        if let t = task {
            title = t.title
            let normalizedNotes = normalizeChecklistPlainText(t.notes)
            notes = normalizedNotes
            taskResult = t.taskResult
            resourcesUsed = t.resourcesUsed
            monthlyResults = t.monthlyResults
            linkURL = t.linkURL
            priority = t.priority
            status = t.status
            completionPercent = t.completionPercent
            taggedOnTask = t.taggedOnTask
            selectedProject = t.project
            airtableProjects = t.airtableProjects
            direction = t.direction
            taskType = t.taskType
            responsibles = t.responsibles
            hasStartDate = t.startDate != nil
            startDate = t.startDate ?? Date()
            hasMidCheck = t.midCheckDate != nil
            midCheckDate = t.midCheckDate ?? Date()
            hasDeadline = t.deadline != nil
            deadline = t.deadline ?? Date()
            // Detect if deadline has a non-midnight time (user set time)
            if let dl = t.deadline {
                let comps = Calendar.current.dateComponents([.hour, .minute], from: dl)
                deadlineIncludesTime = (comps.hour ?? 0) != 0 || (comps.minute ?? 0) != 0
            }
            addToCalendar = !t.googleCalendarEventId.isEmpty
            bringToMeeting = t.bringToMeeting
            top1 = t.top1
            tags = t.tags
            kanbanColumn = t.kanbanColumn
            estimatedMinutes = t.estimatedMinutes
            linkedPersonId = t.linkedPersonId

            for field in customFields {
                if let val = fetchFieldValue(fieldId: field.id, taskId: t.id) {
                    fieldValues[field.id] = val
                }
            }
            if normalizedNotes != t.notes {
                t.notes = normalizedNotes
                try? modelContext.save()
            }
            applyChecklistDerivedProgress()
        } else {
            selectedProject = project
            kanbanColumn = initialColumn
            titleFocused = true
        }
    }

    private func fetchFieldValue(fieldId: UUID, taskId: UUID) -> String? {
        let all = (try? modelContext.fetch(FetchDescriptor<CustomFieldValue>())) ?? []
        return all.first { $0.fieldId == fieldId && $0.taskId == taskId }?.textValue
    }

    private func saveTask() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        notes = normalizeChecklistPlainText(notes)

        // Keep completion/status in sync with checklist blocks when checklist is present.
        applyChecklistDerivedProgress()

        let taskToSave: TaskItem

        if let t = task {
            applyState(to: t, trimmedTitle: trimmed)
            taskToSave = t
        } else {
            let newTask = TaskItem(
                title: trimmed,
                notes: notes,
                taskResult: taskResult,
                resourcesUsed: resourcesUsed,
                monthlyResults: monthlyResults,
                linkURL: linkURL,
                priority: priority,
                status: status,
                completionPercent: completionPercent,
                taggedOnTask: taggedOnTask,
                airtableProjects: airtableProjects,
                direction: direction,
                taskType: taskType,
                responsibles: responsibles,
                startDate: hasStartDate ? startDate : nil,
                midCheckDate: hasMidCheck ? midCheckDate : nil,
                deadline: hasDeadline ? deadline : nil,
                bringToMeeting: bringToMeeting,
                top1: top1,
                tags: tags,
                kanbanColumn: kanbanColumn,
                estimatedMinutes: estimatedMinutes,
                sortOrder: selectedProject?.tasks.count ?? 0,
                linkedPersonId: linkedPersonId
            )
            newTask.project = selectedProject
            modelContext.insert(newTask)
            taskToSave = newTask
        }

        saveCustomFieldValues(for: taskToSave)

        try? modelContext.save()

        if addToCalendar && hasDeadline {
            let savedTask = taskToSave
            let deadlineDate = deadline
            let taskTitle = trimmed
            let taskNotes = notes
            Task {
                do {
                    if !cal.isAuthorized { _ = await cal.requestAccess() }
                    let eventId = try await cal.createOrUpdateEvent(
                        title: "✅ \(taskTitle)",
                        startDate: deadlineDate,
                        notes: taskNotes.isEmpty ? taskTitle : "\(taskTitle)\n\(taskNotes)",
                        existingEventId: savedTask.googleCalendarEventId,
                        isAllDay: !deadlineIncludesTime
                    )
                    await MainActor.run {
                        savedTask.googleCalendarEventId = eventId
                        try? modelContext.save()
                        addedToCalendar = true
                    }
                } catch {
                    await MainActor.run { calendarError = error.localizedDescription }
                }
            }
        }

        onSaved?(taskToSave)
        closeEditor()
    }

    private func applyChecklistDerivedProgress() {
        let stats = TaskItem.checklistStats(from: notes)
        guard stats.total > 0 else { return }

        let percent = Int((Double(stats.checked) / Double(stats.total) * 100.0).rounded())
        completionPercent = percent
    }

    private func normalizeChecklistPlainText(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Keep rich-json untouched.
        if trimmed.hasPrefix("["),
           let data = raw.data(using: .utf8),
           (try? JSONDecoder().decode([TextBlock].self, from: data)) != nil {
            return raw
        }

        return raw
            .replacingOccurrences(of: #"(?m)^([ \t]*)- \[ \] ?"#, with: "$1○ ", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^([ \t]*)- \[[xX]\] ?"#, with: "$1✅ ", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^([ \t]*)\[\] ?"#, with: "$1○ ", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^([ \t]*)\[ \] ?"#, with: "$1○ ", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^([ \t]*)\[[xX✓]\] ?"#, with: "$1✅ ", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^([ \t]*)☐ ?"#, with: "$1○ ", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^([ \t]*)☑ ?"#, with: "$1✅ ", options: .regularExpression)
    }

    private var autoSaveKey: String {
        let projectID = selectedProject?.id.uuidString ?? "nil"
        let linkedID = linkedPersonId?.uuidString ?? "nil"
        let start = hasStartDate ? "\(startDate.timeIntervalSince1970)" : "nil"
        let mid = hasMidCheck ? "\(midCheckDate.timeIntervalSince1970)" : "nil"
        let due = hasDeadline ? "\(deadline.timeIntervalSince1970)" : "nil"
        let fieldKV = fieldValues.keys
            .sorted(by: { $0.uuidString < $1.uuidString })
            .map { "\($0.uuidString)=\(fieldValues[$0] ?? "")" }
            .joined(separator: "|")

        return [
            title, notes, taskResult, resourcesUsed, monthlyResults, linkURL,
            "\(priority.rawValue)", status.rawValue, "\(completionPercent)", "\(taggedOnTask)",
            projectID, airtableProjects.joined(separator: ","), direction.rawValue, taskType.rawValue,
            responsibles.joined(separator: ","), start, mid, due, bringToMeeting.rawValue, top1.rawValue,
            tags.joined(separator: ","), kanbanColumn, "\(estimatedMinutes)", linkedID, fieldKV
        ].joined(separator: "§")
    }

    private func scheduleAutoSaveIfNeeded() {
        guard didInitialLoad, task != nil else { return }
        autoSaveWorkItem?.cancel()
        let work = DispatchWorkItem { autoSaveNowIfNeeded() }
        autoSaveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    private func autoSaveNowIfNeeded() {
        guard didInitialLoad, let t = task else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        applyChecklistDerivedProgress()
        applyState(to: t, trimmedTitle: trimmed)
        saveCustomFieldValues(for: t)
        try? modelContext.save()
        onSaved?(t)
    }

    private func applyState(to t: TaskItem, trimmedTitle: String) {
        t.title = trimmedTitle
        t.notes = notes
        t.taskResult = taskResult
        t.resourcesUsed = resourcesUsed
        t.monthlyResults = monthlyResults
        t.linkURL = linkURL
        t.priority = priority
        t.status = status
        t.completionPercent = completionPercent
        t.taggedOnTask = taggedOnTask
        t.project = selectedProject
        t.airtableProjects = airtableProjects
        t.direction = direction
        t.taskType = taskType
        t.responsibles = responsibles
        t.startDate = hasStartDate ? startDate : nil
        t.midCheckDate = hasMidCheck ? midCheckDate : nil
        t.deadline = hasDeadline ? deadline : nil
        t.bringToMeeting = bringToMeeting
        t.top1 = top1
        t.tags = tags
        t.kanbanColumn = kanbanColumn
        t.estimatedMinutes = estimatedMinutes
        t.linkedPersonId = linkedPersonId
    }

    private func saveCustomFieldValues(for taskToSave: TaskItem) {
        let allValues = (try? modelContext.fetch(FetchDescriptor<CustomFieldValue>())) ?? []
        for field in customFields {
            guard let val = fieldValues[field.id], !val.isEmpty else { continue }
            let fid = field.id
            let tid = taskToSave.id
            if let existing = allValues.first(where: { $0.fieldId == fid && $0.taskId == tid }) {
                existing.textValue = val
                existing.updatedAt = Date()
            } else {
                let cfv = CustomFieldValue(fieldId: fid, taskId: tid)
                cfv.textValue = val
                modelContext.insert(cfv)
            }
        }
    }

    // MARK: - Airtable sync

    private func syncToAirtable() {
        guard let t = task else { return }
        isSyncing = true
        syncError = nil
        Task {
            do {
                try await AirtableService.shared.pushTask(t)
                await MainActor.run { isSyncing = false }
            } catch {
                await MainActor.run {
                    isSyncing = false
                    syncError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Deadline Header (like ProjectDetailView)

    private var taskDeadlineHeader: some View {
        HStack(spacing: 12) {
            // Deadline picker button
            Button {
                showDeadlinePicker.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: hasDeadline ? "calendar.badge.clock" : "calendar.badge.plus")
                        .foregroundStyle(hasDeadline ? taskDeadlineColor : .secondary)
                        .font(.system(size: 16, weight: .medium))

                    if hasDeadline {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Дедлайн")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(deadline.formatted(date: .abbreviated, time: .omitted))
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(taskDeadlineColor)
                        }
                    } else {
                        Text("Установить дедлайн")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(taskDeadlineBackground, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showDeadlinePicker) {
                taskDeadlinePopover
            }

            Spacer()

            // Days left badge
            if hasDeadline {
                taskDaysLeftBadge(due: deadline)
            }

            // Calendar sync button
            if hasDeadline {
                Button {
                    Task { await syncTaskToCalendar() }
                } label: {
                    Group {
                        if case .syncing = calendarSyncStatus {
                            ProgressView().controlSize(.small)
                        } else if case .synced = calendarSyncStatus {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Image(systemName: "calendar.badge.plus").foregroundStyle(.blue)
                        }
                    }
                    .font(.system(size: 16))
                    .frame(width: 32, height: 32)
                    .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help("Добавить дедлайн в Календарь")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.groupedBackground)
    }

    private var taskDeadlinePopover: some View {
        VStack(spacing: 0) {
            Text("Дедлайн задачи")
                .font(.headline)
                .padding(.top, 16)
                .padding(.horizontal, 20)

            // Date picker
            DatePicker(
                "",
                selection: $deadline,
                displayedComponents: deadlineIncludesTime ? [.date, .hourAndMinute] : [.date]
            )
            .datePickerStyle(.graphical)
            .padding(.horizontal, 12)
            .onChange(of: deadline) { _, _ in
                hasDeadline = true
            }

            Divider()

            VStack(spacing: 8) {
                // Quick presets
                HStack(spacing: 8) {
                    taskPresetButton("3 дня", days: 3)
                    taskPresetButton("Неделя", days: 7)
                    taskPresetButton("Месяц", days: 30)
                }
                .padding(.horizontal, 16)

                // Time toggle + auto-calendar
                VStack(spacing: 6) {
                    // Include time
                    Toggle(isOn: $deadlineIncludesTime) {
                        HStack(spacing: 6) {
                            Image(systemName: "clock").foregroundStyle(.blue)
                            Text("Указать время")
                                .font(.subheadline)
                        }
                    }
                    .tint(.blue)
                    .padding(.horizontal, 16)
                    .onChange(of: deadlineIncludesTime) { _, hasTime in
                        if hasTime {
                            // Round to nearest hour
                            let cal = Calendar.current
                            var comps = cal.dateComponents([.year, .month, .day, .hour], from: deadline)
                            comps.minute = 0
                            if let rounded = cal.date(from: comps) {
                                deadline = rounded
                            }
                            // Auto-enable calendar sync when time is set
                            addToCalendar = true
                        }
                    }

                    // Auto sync toggle
                    Toggle(isOn: $addToCalendar) {
                        HStack(spacing: 6) {
                            Image(systemName: "calendar.badge.plus").foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Добавить в Календарь")
                                    .font(.subheadline)
                                Text("автоматически при сохранении")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .tint(.green)
                    .padding(.horizontal, 16)
                }
                .padding(.vertical, 4)
                .background(.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 16)

                // Calendar picker (shown when addToCalendar is on)
                if addToCalendar && cal.isAuthorized && !cal.availableCalendars.isEmpty {
                    Menu {
                        ForEach(cal.availableCalendars, id: \.calendarIdentifier) { calendar in
                            Button {
                                cal.selectCalendar(calendar)
                            } label: {
                                HStack {
                                    Text(calendar.title)
                                    if calendar.calendarIdentifier == cal.selectedCalendarId {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if let selected = cal.selectedCalendar {
                                Circle()
                                    .fill(Color(cgColor: selected.cgColor))
                                    .frame(width: 8, height: 8)
                                Text(selected.title)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                            } else {
                                Text("Выбрать календарь")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                }

                // Manual sync + Remove row
                HStack(spacing: 8) {
                    Button {
                        Task { await syncTaskToCalendar() }
                    } label: {
                        HStack(spacing: 6) {
                            if case .syncing = calendarSyncStatus {
                                ProgressView().controlSize(.small)
                            } else if case .synced = calendarSyncStatus {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            } else {
                                Image(systemName: "calendar").foregroundStyle(.blue)
                            }
                            Text(taskCalendarSyncLabel)
                                .font(.subheadline).fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasDeadline)

                    if hasDeadline {
                        Button {
                            hasDeadline = false
                            deadlineIncludesTime = false
                            addToCalendar = false
                            calendarSyncStatus = .idle
                        } label: {
                            Label("Убрать", systemImage: "xmark")
                                .font(.subheadline).foregroundStyle(.red)
                                .padding(.vertical, 10).padding(.horizontal, 14)
                                .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)

                if case .error(let msg) = calendarSyncStatus {
                    Text(msg)
                        .font(.caption).foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 12)
        }
        .frame(width: 340)
    }

    private func taskPresetButton(_ label: String, days: Int) -> some View {
        Button {
            deadline = Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
            hasDeadline = true
        } label: {
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.blue)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.blue.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func taskDaysLeftBadge(due: Date) -> some View {
        let days = Calendar.current.dateComponents(
            [.day],
            from: Calendar.current.startOfDay(for: Date()),
            to: Calendar.current.startOfDay(for: due)
        ).day ?? 0
        let label: String
        let color: Color
        if days < 0 {
            label = "просрочено \(-days)д"
            color = .red
        } else if days == 0 {
            label = "сегодня"
            color = .orange
        } else if days == 1 {
            label = "завтра"
            color = .orange
        } else {
            label = "ещё \(days)д"
            color = .green
        }
        return Text(label)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
    }

    private var taskDeadlineColor: Color {
        guard hasDeadline else { return .secondary }
        if deadline < Date() { return .red }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: deadline).day ?? 0
        return days <= 3 ? .orange : .blue
    }

    private var taskDeadlineBackground: some ShapeStyle {
        guard hasDeadline else { return AnyShapeStyle(Color.secondary.opacity(0.1)) }
        if deadline < Date() { return AnyShapeStyle(Color.red.opacity(0.12)) }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: deadline).day ?? 0
        return days <= 3
            ? AnyShapeStyle(Color.orange.opacity(0.12))
            : AnyShapeStyle(Color.blue.opacity(0.12))
    }

    private var taskCalendarSyncLabel: String {
        switch calendarSyncStatus {
        case .idle:    return addedToCalendar ? "Обновить в Календаре" : "Добавить в Календарь"
        case .syncing: return "Сохранение..."
        case .synced:  return "Добавлено ✓"
        case .error:   return "Попробовать снова"
        }
    }

    // MARK: - Calendar Sync for Task

    private func syncTaskToCalendar() async {
        guard hasDeadline else { return }
        calendarSyncStatus = .syncing

        if !cal.isAuthorized {
            let granted = await cal.requestAccess()
            guard granted else {
                calendarSyncStatus = .error("Нет доступа к Календарю.\nРазрешите в Системных настройках → Конфиденциальность → Kalendar")
                return
            }
        }

        do {
            let notesText = notes.isEmpty ? title : "\(title)\n\(notes)"
            let eventId = try await cal.createOrUpdateEvent(
                title: "✅ \(title)",
                startDate: deadline,
                notes: notesText,
                existingEventId: task?.googleCalendarEventId ?? "",
                isAllDay: false
            )
            // Save event ID back to task if editing
            if let t = task {
                t.googleCalendarEventId = eventId
                try? modelContext.save()
            }
            addedToCalendar = true
            calendarSyncStatus = .synced
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            calendarSyncStatus = .idle
        } catch {
            calendarSyncStatus = .error(error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private func formatMinutes(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m) мин" }
        if m == 0 { return "\(h) ч" }
        return "\(h) ч \(m) мин"
    }

    private func closeEditor() {
        if embedded {
            onClose?()
        } else {
            dismiss()
        }
    }
}
