import SwiftUI
import SwiftData

struct KanbanView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var project: Project

    @State private var showAddTask     = false
    @State private var targetColumn    = "todo"
    @State private var dropTargetColumn: String?   // highlighted column during drag
    @State private var draggingTaskID: UUID?        // source card (dimmed)

    private var columnLabels: [(key: String, label: String)] {
        project.kanbanColumns.map { col in
            (key: col, label: Project.columnLabels[col] ?? col)
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(columnLabels, id: \.key) { col in
                    KanbanColumnView(
                        key:              col.key,
                        label:            col.label,
                        tasks:            tasksFor(column: col.key),
                        isDropTarget:     dropTargetColumn == col.key,
                        draggingTaskID:   draggingTaskID,
                        onAddTap: {
                            targetColumn = col.key
                            showAddTask  = true
                        },
                        onDrop: { items in
                            let result = handleDrop(items: items, intoColumn: col.key)
                            draggingTaskID = nil
                            return result
                        },
                        onTargeted: { targeted in
                            withAnimation(.easeInOut(duration: 0.15)) {
                                dropTargetColumn = targeted ? col.key : nil
                            }
                        },
                        onDragStart: { id in
                            draggingTaskID = id
                        }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .padding(.bottom, 20)
        }
        .background(Color.groupedBackground)
        .sheet(isPresented: $showAddTask) {
            TaskDetailView(project: project, initialColumn: targetColumn)
        }
    }

    // MARK: - Helpers

    private func tasksFor(column: String) -> [TaskItem] {
        project.tasks
            .filter { $0.kanbanColumn == column }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    private func handleDrop(items: [String], intoColumn column: String) -> Bool {
        guard let idString = items.first,
              let uuid     = UUID(uuidString: idString),
              let task     = project.tasks.first(where: { $0.id == uuid }),
              task.kanbanColumn != column else { return false }

        withAnimation(.spring(duration: 0.3)) {
            task.kanbanColumn = column
            // Sync status with column
            switch column {
            case "done":       task.status = .done
            case "inProgress": task.status = .inProgress
            default:           task.status = .todo
            }
            // Place at the end of the target column
            let maxOrder = project.tasks
                .filter { $0.kanbanColumn == column }
                .map { $0.sortOrder }
                .max() ?? -1
            task.sortOrder = maxOrder + 1
        }
        try? modelContext.save()
        return true
    }
}

// MARK: - Column View (extracted to avoid ViewBuilder limits)

private struct KanbanColumnView: View {
    let key:            String
    let label:          String
    let tasks:          [TaskItem]
    let isDropTarget:   Bool
    let draggingTaskID: UUID?
    let onAddTap:       () -> Void
    let onDrop:         ([String]) -> Bool
    let onTargeted:     (Bool) -> Void
    let onDragStart:    (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            columnHeader
            cardsArea
        }
        .frame(width: 240)
        .background(columnBackground, in: RoundedRectangle(cornerRadius: 16))
        .overlay(columnBorder)
        .animation(.easeInOut(duration: 0.15), value: isDropTarget)
        // Entire column is a drop target
        .dropDestination(for: String.self, action: { items, _ in
            onDrop(items)
        }, isTargeted: { targeted in
            onTargeted(targeted)
        })
    }

    // MARK: Header

    private var columnHeader: some View {
        HStack(spacing: 6) {
            // Status dot
            Circle()
                .fill(columnColor)
                .frame(width: 8, height: 8)

            Text(label)
                .font(.subheadline)
                .fontWeight(.semibold)

            Spacer()

            Text("\(tasks.count)")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.secondary.opacity(0.15), in: Capsule())

            Button(action: onAddTap) {
                Image(systemName: "plus")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .background(.secondary.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: Cards

    private var cardsArea: some View {
        VStack(spacing: 8) {
            if tasks.isEmpty {
                emptyPlaceholder
            } else {
                ForEach(tasks) { task in
                    KanbanCardView(task: task, onDragStart: onDragStart)
                        .opacity(draggingTaskID == task.id ? 0.35 : 1.0)
                        .animation(.easeInOut(duration: 0.2), value: draggingTaskID)
                }
            }

            // Drop indicator strip when targeted
            if isDropTarget {
                dropIndicator
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
    }

    private var emptyPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: isDropTarget ? "arrow.down.circle.fill" : "tray")
                .font(.system(size: isDropTarget ? 28 : 24))
                .foregroundStyle(isDropTarget ? columnColor : Color.secondary.opacity(0.5))
                .animation(.spring(duration: 0.3), value: isDropTarget)

            Text(isDropTarget ? "Переместить сюда" : "Пусто")
                .font(.caption)
                .foregroundStyle(isDropTarget ? columnColor : Color.secondary.opacity(0.4))
                .fontWeight(isDropTarget ? .medium : .regular)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var dropIndicator: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(columnColor.opacity(0.6))
            .frame(height: 3)
            .padding(.horizontal, 4)
            .transition(.opacity.combined(with: .scale))
    }

    // MARK: Styling

    private var columnBackground: some ShapeStyle {
        isDropTarget
            ? AnyShapeStyle(columnColor.opacity(0.08))
            : AnyShapeStyle(.background.secondary)
    }

    private var columnBorder: some View {
        RoundedRectangle(cornerRadius: 16)
            .strokeBorder(
                isDropTarget ? columnColor.opacity(0.6) : Color.secondary.opacity(0.1),
                lineWidth: isDropTarget ? 2 : 1
            )
    }

    private var columnColor: Color {
        switch key {
        case "todo":       return .secondary
        case "inProgress": return .blue
        case "done":       return .green
        default:           return .accentColor
        }
    }
}

// MARK: - Kanban Card

struct KanbanCardView: View {
    @Environment(\.modelContext) private var modelContext
    let task: TaskItem
    var onDragStart: ((UUID) -> Void)? = nil

    @State private var showDetail = false

    var body: some View {
        Button { showDetail = true } label: {
            cardContent
        }
        .buttonStyle(.plain)
        .draggable(task.id.uuidString) {
            // Drag preview
            cardContent
                .frame(width: 216)
                .scaleEffect(1.03)
                .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
                .onAppear { onDragStart?(task.id) }
        }
        .sheet(isPresented: $showDetail) {
            TaskDetailView(task: task)
        }
        .contextMenu {
            Button(role: .destructive) {
                modelContext.delete(task)
                try? modelContext.save()
            } label: {
                Label("Удалить", systemImage: "trash")
            }
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Project color bar
            if let project = task.project {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(hex: project.colorHex))
                    .frame(height: 3)
            }

            Text(task.title)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !task.notes.isEmpty {
                Text(task.notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 6) {
                if task.priority != .none {
                    PriorityBadge(priority: task.priority, compact: true)
                }

                Spacer()

                if let due = task.dueDate {
                    Label(due.shortLabel, systemImage: "calendar")
                        .font(.caption2)
                        .foregroundStyle(task.isOverdue ? .red : .secondary)
                }

                if !task.estimatedTimeLabel.isEmpty {
                    Label(task.estimatedTimeLabel, systemImage: "clock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 0.5)
        )
    }
}
