import SwiftUI
import SwiftData

enum ProjectViewMode: String, CaseIterable {
    case list    = "Список"
    case kanban  = "Канбан"
    case timeline = "Таймлайн"

    var icon: String {
        switch self {
        case .list:     return "list.bullet"
        case .kanban:   return "square.split.2x1"
        case .timeline: return "calendar"
        }
    }
}

struct ProjectDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var project: Project
    @StateObject private var cal = CalendarService.shared

    @State private var viewMode: ProjectViewMode = .list
    @State private var showHistory = true
    @State private var newTaskTitle = ""
    @State private var sortOption: SortOption = .priority
    @State private var ascending = false
    @State private var searchText = ""
    @State private var showDeadlinePicker = false
    @State private var calendarSyncStatus: CalendarSyncStatus = .idle
    @FocusState private var quickAddFocused: Bool
    @State private var selectedTaskID: UUID? = nil
    @State private var creatingNewInlineTask = false

    enum CalendarSyncStatus {
        case idle, syncing, synced, error(String)
    }

    var activeTasks: [TaskItem] {
        let base = project.tasks.filter { $0.status != .done }
        let searched = searchText.isEmpty ? base : base.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
            || $0.notes.localizedCaseInsensitiveContains(searchText)
            || $0.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
        }
        return searched.sorted(by: sortOption, ascending: ascending)
    }

    var completedTasks: [TaskItem] {
        project.completedTasks
    }

    private var selectedTask: TaskItem? {
        guard let selectedTaskID else { return nil }
        return project.tasks.first { $0.id == selectedTaskID }
    }

    private var showingInlineTaskEditor: Bool {
        creatingNewInlineTask || selectedTask != nil
    }

    var body: some View {
        contentForCurrentMode
            .navigationTitle(project.name)
            .navigationLarge()
            .searchable(text: $searchText, prompt: "Поиск задач")
            .toolbar { projectToolbar }
            .onAppear {
                ensureValidTaskSelection()
            }
            .onChange(of: project.tasks.map(\.id)) { _, _ in
                ensureValidTaskSelection()
            }
            .onChange(of: activeTasks.map(\.id)) { _, _ in
                ensureValidTaskSelection()
            }
    }

    @ViewBuilder
    private var contentForCurrentMode: some View {
#if os(macOS)
        if viewMode == .list && showingInlineTaskEditor {
            taskDetailPane
        } else {
            mainProjectContent
        }
#else
        mainProjectContent
#endif
    }

    @ToolbarContentBuilder
    private var projectToolbar: some ToolbarContent {
#if os(macOS)
        if viewMode == .list && showingInlineTaskEditor {
            ToolbarItem(placement: .navigation) {
                Button {
                    closeInlineEditor()
                } label: {
                    Label("К списку", systemImage: "chevron.left")
                }
            }
        }
#endif
        ToolbarItem(placement: .primaryAction) {
            Button {
                startCreatingTask()
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Новая задача в проекте")
            .accessibilityHint("Открывает создание задачи для текущего проекта")
        }
        ToolbarItem {
            SortToolbarButton(sortOption: $sortOption, ascending: $ascending)
        }
        ToolbarItem(placement: .secondaryAction) {
            Button {
                showHistory.toggle()
            } label: {
                Label(
                    showHistory ? "Скрыть историю" : "История",
                    systemImage: showHistory ? "clock.fill" : "clock"
                )
            }
        }
    }

    private var mainProjectContent: some View {
        VStack(spacing: 0) {
            // Deadline header
            deadlineHeader

            Divider()

            // Mode switcher
            Picker("Вид", selection: $viewMode) {
                ForEach(ProjectViewMode.allCases, id: \.self) { mode in
                    Label(mode.rawValue, systemImage: mode.icon).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // Content
            Group {
                switch viewMode {
                case .list:     listView
                case .kanban:   KanbanView(project: project)
                case .timeline: TimelineView(project: project)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - List View

    private var listView: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                // Quick add inline
                quickAddRow

                // Active tasks
                if activeTasks.isEmpty && !showHistory {
                    emptyActive
                } else {
                    ForEach(activeTasks) { task in
                        TaskCard(
                            task: task,
                            isSelected: selectedTaskID == task.id,
                            onOpen: openTask
                        )
                            .padding(.horizontal, 16)
                    }
                }

                // Completed section
                if showHistory && !completedTasks.isEmpty {
                    historySection
                }

                // Files section
                LinkedAttachmentSection(entity: .project(project.id))
                    .padding(.horizontal, 16)
            }
            .padding(.vertical, 12)
            .padding(.bottom, 32)
        }
        .background(Color.groupedBackground)
    }

    private var quickAddRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle")
                .foregroundStyle(.blue)
                .font(.title3)

            TextField("Добавить задачу...", text: $newTaskTitle)
                .focused($quickAddFocused)
                .submitLabel(.done)
                .onSubmit { submitQuickTask() }

            if !newTaskTitle.isEmpty {
                Button(action: submitQuickTask) {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundStyle(.blue)
                        .font(.title3)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
    }

    private func submitQuickTask() {
        let title = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let task = TaskItem(title: title, sortOrder: project.tasks.count)
        task.project = project
        modelContext.insert(task)
        try? modelContext.save()
        newTaskTitle = ""
        selectedTaskID = task.id
    }

    private var emptyActive: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green.gradient)
                .padding(.top, 32)
            Text("Все задачи выполнены!")
                .font(.headline)
            Text("Добавьте новую задачу выше")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Выполнено (\(completedTasks.count))", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            ForEach(completedTasks) { task in
                TaskCard(
                    task: task,
                    isSelected: selectedTaskID == task.id,
                    onOpen: openTask
                )
                    .padding(.horizontal, 16)
                    .opacity(0.7)
            }
        }
    }

    private var taskDetailPane: some View {
        Group {
            if creatingNewInlineTask {
                TaskDetailView(
                    task: nil,
                    project: project,
                    embedded: true,
                    onClose: { creatingNewInlineTask = false },
                    onSaved: { saved in
                        creatingNewInlineTask = false
                        selectedTaskID = saved.id
                    }
                )
                .background(Color.secondaryGroupedBackground)
            } else if let task = selectedTask {
                TaskDetailView(
                    task: task,
                    project: project,
                    embedded: true,
                    onSaved: { saved in
                        selectedTaskID = saved.id
                    }
                )
                .background(Color.secondaryGroupedBackground)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "checklist")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("Выбери задачу")
                        .font(.title3.weight(.semibold))
                    Text("Выбери задачу в списке проекта или создай новую")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.groupedBackground)
            }
        }
    }

    private func startCreatingTask() {
        if viewMode != .list {
            viewMode = .list
        }
        selectedTaskID = nil
        creatingNewInlineTask = true
        quickAddFocused = false
    }

    private func openTask(_ task: TaskItem) {
        creatingNewInlineTask = false
        selectedTaskID = task.id
    }

    private func closeInlineEditor() {
        creatingNewInlineTask = false
        selectedTaskID = nil
    }

    private func ensureValidTaskSelection() {
        let visibleIDs = Set(activeTasks.map(\.id) + completedTasks.map(\.id))
        if let selectedTaskID, !visibleIDs.contains(selectedTaskID) {
            self.selectedTaskID = nil
        }
    }

    // MARK: - Deadline Header

    private var deadlineHeader: some View {
        HStack(spacing: 12) {
            // Deadline button / picker
            Button {
                showDeadlinePicker.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "calendar.badge.clock")
                        .foregroundStyle(deadlineColor)
                        .font(.system(size: 15, weight: .medium))

                    if let due = project.dueDate {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Дедлайн")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(due.formatted(date: .abbreviated, time: .shortened))
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(deadlineColor)
                        }
                    } else {
                        Text("Установить дедлайн")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(deadlineBackground, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showDeadlinePicker) {
                deadlinePickerPopover
            }
            .accessibilityLabel("Дедлайн проекта")
            .accessibilityHint("Открывает настройки дедлайна и синхронизации с календарем")

            Spacer()

            // Days left badge
            if let due = project.dueDate {
                daysLeftBadge(due: due)
            }

            // Google Calendar sync button
            calendarSyncButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.groupedBackground)
    }

    // Compact calendar sync button shown in header (only when deadline is set)
    @ViewBuilder
    private var calendarSyncButton: some View {
        if project.dueDate != nil {
            Button {
                Task { await syncToCalendar() }
            } label: {
                Group {
                    if case .syncing = calendarSyncStatus {
                        ProgressView().controlSize(.small)
                    } else if case .synced = calendarSyncStatus {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Image(systemName: "calendar.badge.plus")
                            .foregroundStyle(.blue)
                    }
                }
                .font(.system(size: 16))
                .frame(width: 32, height: 32)
                .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("Добавить в Календарь (Google Calendar)")
        }
    }

    private var deadlineColor: Color {
        guard let due = project.dueDate else { return .secondary }
        if due < Date() { return .red }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: due).day ?? 0
        return days <= 3 ? .orange : .blue
    }

    private var deadlineBackground: some ShapeStyle {
        guard let due = project.dueDate else {
            return AnyShapeStyle(Color.secondary.opacity(0.1))
        }
        if due < Date() { return AnyShapeStyle(Color.red.opacity(0.12)) }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: due).day ?? 0
        return days <= 3
            ? AnyShapeStyle(Color.orange.opacity(0.12))
            : AnyShapeStyle(Color.blue.opacity(0.12))
    }

    private func daysLeftBadge(due: Date) -> some View {
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: Calendar.current.startOfDay(for: due)).day ?? 0
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

    // MARK: - Deadline Picker Popover

    private var deadlinePickerPopover: some View {
        VStack(spacing: 0) {
            Text("Дедлайн проекта")
                .font(.headline)
                .padding(.top, 16)
                .padding(.horizontal, 20)

            DatePicker(
                "",
                selection: Binding(
                    get: { project.dueDate ?? Date() },
                    set: { newDate in
                        project.dueDate = newDate
                        try? modelContext.save()
                    }
                ),
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.graphical)
            .padding(.horizontal, 12)

            Divider()

            VStack(spacing: 8) {
                // Quick presets
                HStack(spacing: 8) {
                    quickPresetButton("3 дня", days: 3)
                    quickPresetButton("Неделя", days: 7)
                    quickPresetButton("Месяц", days: 30)
                }
                .padding(.horizontal, 16)

                // Calendar selector
                if cal.isAuthorized && !cal.availableCalendars.isEmpty {
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
                            if let selectedCal = cal.selectedCalendar {
                                Circle()
                                    .fill(Color(cgColor: selectedCal.cgColor))
                                    .frame(width: 8, height: 8)
                                Text(selectedCal.title)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                            } else {
                                Text("Выбрать календарь")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                }

                HStack(spacing: 8) {
                    // Add to Calendar button
                    Button {
                        Task { await syncToCalendar() }
                    } label: {
                        HStack(spacing: 6) {
                            if case .syncing = calendarSyncStatus {
                                ProgressView().controlSize(.small)
                            } else if case .synced = calendarSyncStatus {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            } else {
                                Image(systemName: "calendar.badge.plus").foregroundStyle(.blue)
                            }
                            Text(calendarSyncLabel)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .disabled(project.dueDate == nil)

                    // Remove deadline
                    if project.dueDate != nil {
                        Button {
                            // Delete event from calendar if exists
                            if !project.googleCalendarEventId.isEmpty {
                                cal.deleteEvent(eventId: project.googleCalendarEventId)
                                project.googleCalendarEventId = ""
                            }
                            project.dueDate = nil
                            try? modelContext.save()
                            calendarSyncStatus = .idle
                        } label: {
                            Label("Убрать", systemImage: "xmark")
                                .font(.subheadline)
                                .foregroundStyle(.red)
                                .padding(.vertical, 10)
                                .padding(.horizontal, 14)
                                .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)

                if case .error(let msg) = calendarSyncStatus {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 12)
        }
        .frame(width: 340)
    }

    private var calendarSyncLabel: String {
        switch calendarSyncStatus {
        case .idle:    return !project.googleCalendarEventId.isEmpty ? "Обновить в Календаре" : "Добавить в Календарь"
        case .syncing: return "Сохранение..."
        case .synced:  return "Добавлено ✓"
        case .error:   return "Попробовать снова"
        }
    }

    private func quickPresetButton(_ label: String, days: Int) -> some View {
        Button {
            let newDate = Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
            project.dueDate = newDate
            try? modelContext.save()
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
        .accessibilityLabel("Установить дедлайн через \(days) дней")
    }

    // MARK: - EventKit Sync (no OAuth, works with Google Calendar via system accounts)

    private func syncToCalendar() async {
        guard let due = project.dueDate else { return }
        calendarSyncStatus = .syncing

        // Request access if needed
        if !cal.isAuthorized {
            let granted = await cal.requestAccess()
            guard granted else {
                calendarSyncStatus = .error("Нет доступа к Календарю.\nРазрешите в Системных настройках → Конфиденциальность → Календарь")
                return
            }
        }

        do {
            let activeCount = project.tasks.filter { $0.status != .done }.count
            let notes = "Проект: \(project.name)\nАктивных задач: \(activeCount)\nСоздан в приложении Задачник"

            let eventId = try await cal.createOrUpdateEvent(
                title: "📁 \(project.name)",
                startDate: due,
                notes: notes,
                existingEventId: project.googleCalendarEventId,
                isAllDay: false
            )
            project.googleCalendarEventId = eventId
            try? modelContext.save()
            calendarSyncStatus = .synced

            try? await Task.sleep(nanoseconds: 3_000_000_000)
            calendarSyncStatus = .idle
        } catch {
            calendarSyncStatus = .error(error.localizedDescription)
        }
    }
}
