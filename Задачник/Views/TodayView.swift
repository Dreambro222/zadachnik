import SwiftUI
import SwiftData

extension Notification.Name {
    static let focusTodaySearch = Notification.Name("focusTodaySearch")
}

struct TodayView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(filter: #Predicate<TaskItem> { $0.statusRaw != "Готово" })
    private var activeTasks: [TaskItem]
    @Query(sort: \Person.name) private var people: [Person]

    @State private var showQuickCapture = false
    @State private var sortOption: SortOption = .importance
    @State private var ascending = false
    @State private var selectedTag: String? = nil
    @State private var searchText = ""
    @State private var isSearchPresented = false
    @State private var selectedTaskID: UUID? = nil
    @State private var creatingNewInlineTask = false

    private var allTags: [String] {
        Array(Set(activeTasks.flatMap { $0.tags })).sorted()
    }

    private func filtered(_ tasks: [TaskItem]) -> [TaskItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return tasks.filter { task in
            let matchesTag = selectedTag == nil || task.tags.contains(selectedTag!)
            let matchesSearch = query.isEmpty
                || task.title.localizedCaseInsensitiveContains(query)
                || task.notes.localizedCaseInsensitiveContains(query)
                || task.tags.contains { $0.localizedCaseInsensitiveContains(query) }
            return matchesTag && matchesSearch
        }
    }

    private var overdueTasks: [TaskItem] {
        filtered(activeTasks
            .filter { $0.isOverdue })
            .sorted(by: .importance, ascending: false)
    }

    private var todayTasks: [TaskItem] {
        filtered(activeTasks
            .filter { $0.isDueToday })
            .sorted(by: sortOption, ascending: ascending)
    }

    private var tomorrowTasks: [TaskItem] {
        filtered(activeTasks
            .filter { $0.isDueTomorrow })
            .sorted(by: sortOption, ascending: ascending)
    }

    private var backlogTasks: [TaskItem] {
        filtered(activeTasks
            .filter { $0.deadline == nil })
            .sorted(by: .importance, ascending: false)
    }

    private var totalCount: Int { overdueTasks.count + todayTasks.count }

    private var visibleTasks: [TaskItem] {
        overdueTasks + todayTasks + tomorrowTasks + backlogTasks
    }

    private var selectedTask: TaskItem? {
        guard let selectedTaskID else { return nil }
        return activeTasks.first { $0.id == selectedTaskID }
    }

    private var showingInlineEditor: Bool {
        creatingNewInlineTask || selectedTask != nil
    }

    private var subtitleText: String {
        let backlog = backlogTasks.count
        if totalCount == 0 && backlog == 0 { return "Задач нет" }
        var parts: [String] = []
        if totalCount > 0 { parts.append("На сегодня: \(totalCount)") }
        if backlog > 0 { parts.append("Бэклог: \(backlog)") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Group {
#if os(macOS)
            if showingInlineEditor {
                taskDetailPane
            } else {
                taskListPane
            }
#else
            taskListPane
#endif
        }
        .background(Color.groupedBackground)
        .navigationTitle("Сегодня")
        .searchable(text: $searchText, isPresented: $isSearchPresented, prompt: "Поиск задач")
        .toolbar {
#if os(macOS)
            if showingInlineEditor {
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
#if os(macOS)
                    startCreatingTask()
#else
                    showQuickCapture = true
#endif
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .font(.title3)
                }
                .accessibilityLabel("Новая задача")
                .accessibilityHint("Создает новую задачу")
            }
            ToolbarItem {
                SortToolbarButton(sortOption: $sortOption, ascending: $ascending)
            }
        }
        .sheet(isPresented: $showQuickCapture) {
            QuickCaptureView()
        }
        .onAppear {
            ensureValidSelection()
        }
        .onChange(of: activeTasks.map(\.id)) { _, _ in
            ensureValidSelection()
        }
        .onChange(of: visibleTasks.map(\.id)) { _, _ in
            ensureValidSelection()
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusTodaySearch)) { _ in
            isSearchPresented = true
        }
    }

    private var taskListPane: some View {
        VStack(spacing: 0) {
            if !allTags.isEmpty {
                TagFilterBar(availableTags: allTags, selectedTag: $selectedTag)
                Divider()
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    header

                    if overdueTasks.isEmpty && todayTasks.isEmpty && tomorrowTasks.isEmpty && backlogTasks.isEmpty {
                        emptyState
                    }

                    if !overdueTasks.isEmpty {
                        TaskSectionView(
                            title: "Просрочено",
                            icon: "exclamationmark.circle.fill",
                            color: .red,
                            tasks: overdueTasks,
                            people: people,
                            selectedTaskID: selectedTaskID,
                            onSelectTask: openTask
                        )
                    }

                    if !todayTasks.isEmpty {
                        TaskSectionView(
                            title: "Сегодня",
                            icon: "sun.max.fill",
                            color: .orange,
                            tasks: todayTasks,
                            people: people,
                            selectedTaskID: selectedTaskID,
                            onSelectTask: openTask
                        )
                    }

                    if !tomorrowTasks.isEmpty {
                        TaskSectionView(
                            title: "Завтра",
                            icon: "moon.stars.fill",
                            color: .indigo,
                            tasks: tomorrowTasks,
                            people: people,
                            selectedTaskID: selectedTaskID,
                            onSelectTask: openTask
                        )
                    }

                    if !backlogTasks.isEmpty {
                        CollapsibleTaskSection(
                            title: "Бэклог",
                            icon: "tray.full.fill",
                            color: .secondary,
                            tasks: backlogTasks,
                            people: people,
                            selectedTaskID: selectedTaskID,
                            onSelectTask: openTask
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
        }
    }

    private var taskDetailPane: some View {
        Group {
            if creatingNewInlineTask {
                TaskDetailView(
                    task: nil,
                    project: nil,
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
                    project: task.project,
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
                    Text("Выбери задачу в списке слева или создай новую")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.groupedBackground)
            }
        }
    }

    private func startCreatingTask() {
        selectedTaskID = nil
        creatingNewInlineTask = true
    }

    private func openTask(_ task: TaskItem) {
        creatingNewInlineTask = false
        selectedTaskID = task.id
    }

    private func closeInlineEditor() {
        creatingNewInlineTask = false
        selectedTaskID = nil
    }

    private func ensureValidSelection() {
        let ids = Set(visibleTasks.map(\.id))
        if let selectedTaskID, !ids.contains(selectedTaskID) {
            self.selectedTaskID = nil
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Date().relativeLabel)
                .font(.largeTitle)
                .fontWeight(.bold)

            Text(subtitleText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green.gradient)
                .padding(.top, 40)

            Text("Всё сделано!")
                .font(.title2)
                .fontWeight(.semibold)

            Text("На сегодня и завтра нет запланированных задач")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}

// MARK: - Task section (separate struct avoids opaque-type buildExpression issues)

struct TaskSectionView: View {
    let title: String
    let icon: String
    let color: Color
    let tasks: [TaskItem]
    var people: [Person] = []
    var selectedTaskID: UUID? = nil
    var onSelectTask: ((TaskItem) -> Void)? = nil

    private func linkedPerson(for task: TaskItem) -> Person? {
        guard let pid = task.linkedPersonId else { return nil }
        return people.first { $0.id == pid }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(title)
                    .font(.headline)
                    .fontWeight(.semibold)
                Text("(\(tasks.count))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                ForEach(tasks) { task in
                    TaskCard(
                        task: task,
                        showProject: true,
                        linkedPerson: linkedPerson(for: task),
                        isSelected: selectedTaskID == task.id,
                        onOpen: onSelectTask
                    )
                }
            }
        }
    }
}

// MARK: - Collapsible section (for backlog)

struct CollapsibleTaskSection: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let icon: String
    let color: Color
    let tasks: [TaskItem]
    var people: [Person] = []
    var selectedTaskID: UUID? = nil
    var onSelectTask: ((TaskItem) -> Void)? = nil

    @State private var isExpanded = false

    private func linkedPerson(for task: TaskItem) -> Person? {
        guard let pid = task.linkedPersonId else { return nil }
        return people.first { $0.id == pid }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                if reduceMotion {
                    isExpanded.toggle()
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .foregroundStyle(color)
                    Text(title)
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                    Text("(\(tasks.count))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 8) {
                    ForEach(tasks) { task in
                        TaskCard(
                            task: task,
                            showProject: true,
                            linkedPerson: linkedPerson(for: task),
                            isSelected: selectedTaskID == task.id,
                            onOpen: onSelectTask
                        )
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
