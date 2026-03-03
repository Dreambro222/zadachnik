import SwiftUI
import SwiftData

struct ProjectsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Project.sortOrder) private var projects: [Project]
    @Query(filter: #Predicate<TaskItem> { $0.statusRaw != "Готово" })
    private var activeTasks: [TaskItem]

    @Binding var selectedProject: Project?
    @State private var showAddProject = false
    @State private var editingProject: Project?
    
    private var inboxCount: Int {
        activeTasks.filter { $0.project == nil }.count
    }

    var body: some View {
        Group {
            if projects.isEmpty {
                emptyState
            } else {
                projectList
            }
        }
        .navigationTitle("Проекты")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddProject = true
                } label: {
                    Label("Новый проект", systemImage: "plus")
                }
                .accessibilityHint("Открывает форму создания проекта")
            }
        }
        .sheet(isPresented: $showAddProject) {
            AddProjectView()
        }
        .sheet(item: $editingProject) { project in
            AddProjectView(editingProject: project)
        }
    }

    private var projectList: some View {
        List {
            NavigationLink {
                InboxTasksView()
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.secondary.opacity(0.14))
                            .frame(width: 40, height: 40)
                        Image(systemName: "tray")
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Без проекта")
                            .font(.headline)
                        Text("Inbox")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if inboxCount > 0 {
                        Text("\(inboxCount)")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .frame(minWidth: 20)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.secondary, in: Capsule())
                    }
                }
                .padding(.vertical, 4)
            }

            ForEach(projects) { project in
                NavigationLink {
                    ProjectDetailView(project: project)
                } label: {
                    ProjectRow(project: project)
                        .padding(.vertical, 4)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        modelContext.delete(project)
                        try? modelContext.save()
                    } label: {
                        Label("Удалить", systemImage: "trash")
                    }

                    Button {
                        editingProject = project
                    } label: {
                        Label("Изменить", systemImage: "pencil")
                    }
                    .tint(.blue)
                }
            }
            .onMove { source, dest in
                var sorted = projects
                sorted.move(fromOffsets: source, toOffset: dest)
                for (i, p) in sorted.enumerated() { p.sortOrder = i }
                try? modelContext.save()
            }
        }
        .adaptiveListStyle()
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 56))
                .foregroundStyle(.blue.gradient)

            Text("Нет проектов")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Создайте первый проект, чтобы начать организовывать задачи")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                showAddProject = true
            } label: {
                Label("Создать проект", systemImage: "plus")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct InboxTasksView: View {
    @Query(filter: #Predicate<TaskItem> { $0.statusRaw != "Готово" })
    private var activeTasks: [TaskItem]
    @Query(sort: \Person.name) private var people: [Person]

    private var inboxTasks: [TaskItem] {
        activeTasks
            .filter { $0.project == nil }
            .sorted { lhs, rhs in
                let lhsUrgent = lhs.isOverdue || lhs.isDueToday
                let rhsUrgent = rhs.isOverdue || rhs.isDueToday
                if lhsUrgent != rhsUrgent { return lhsUrgent && !rhsUrgent }
                if lhs.importanceScore != rhs.importanceScore { return lhs.importanceScore > rhs.importanceScore }
                return lhs.createdAt > rhs.createdAt
            }
    }

    private func linkedPerson(for task: TaskItem) -> Person? {
        guard let pid = task.linkedPersonId else { return nil }
        return people.first { $0.id == pid }
    }

    var body: some View {
        Group {
            if inboxTasks.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "tray")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text("Inbox пуст")
                        .font(.title3.weight(.semibold))
                    Text("Задачи без проекта будут появляться здесь")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(inboxTasks) { task in
                        NavigationLink {
                            TaskDetailView(task: task, project: nil)
                        } label: {
                            TaskCard(
                                task: task,
                                showProject: false,
                                linkedPerson: linkedPerson(for: task)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .adaptiveListStyle()
            }
        }
        .navigationTitle("Без проекта")
    }
}
