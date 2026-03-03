import SwiftUI
import SwiftData

struct TaskCard: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let task: TaskItem
    var showProject: Bool = false
    var linkedPerson: Person? = nil
    var compact: Bool = false
    var isSelected: Bool = false
    var onOpen: ((TaskItem) -> Void)? = nil

    @State private var showDetail = false

    var body: some View {
        Button {
            if let onOpen {
                onOpen(task)
            } else {
                showDetail = true
            }
        } label: {
            cardContent
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .sheet(isPresented: $showDetail) {
            TaskDetailView(task: task)
        }
        .contextMenu {
            contextMenuItems
        }
    }

    private var cardContent: some View {
        let notesPreview = plainNotesPreview(task.notes)
        return HStack(alignment: .top, spacing: 12) {
            completionButton

            VStack(alignment: .leading, spacing: compact ? 3 : 5) {
                Text(task.title)
                    .font(compact ? .subheadline : .body)
                    .fontWeight(.medium)
                    .strikethrough(task.status == .done)
                    .foregroundStyle(task.status == .done ? .secondary : .primary)
                    .lineLimit(compact ? 1 : 2)
                    .multilineTextAlignment(.leading)

                if !notesPreview.isEmpty && !compact {
                    Text(notesPreview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 6) {
                    if task.priority != .none {
                        PriorityBadge(priority: task.priority, compact: true)
                    }

                    if let progress = task.checklistProgressPercent ?? (task.completionPercent > 0 ? task.completionPercent : nil) {
                        progressBadge(progress)
                    }

                    if let due = task.dueDate {
                        dueDateLabel(due)
                    }

                    if !task.estimatedTimeLabel.isEmpty {
                        Label(task.estimatedTimeLabel, systemImage: "clock")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if showProject, let project = task.project {
                        projectTag(project)
                    }
                    if let person = linkedPerson {
                        personTag(person)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(compact ? 10 : 12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Color.accentColor.opacity(0.8) : .clear, lineWidth: 1.5)
        )
    }

    private func plainNotesPreview(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("[") {
            return RichText.plainText(RichText.parse(trimmed))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    @ViewBuilder
    private func dueDateLabel(_ date: Date) -> some View {
        let color: Color = task.isOverdue ? .red : (task.isDueToday ? .orange : .secondary)
        Label(date.shortLabel, systemImage: "calendar")
            .font(.caption2)
            .foregroundStyle(color)
    }

    @ViewBuilder
    private func progressBadge(_ progress: Int) -> some View {
        let clamped = max(0, min(progress, 100))
        let color: Color = clamped >= 100 ? .green : (clamped >= 50 ? .blue : .orange)
        Label("\(clamped)%", systemImage: "chart.bar.fill")
            .font(.caption2)
            .foregroundStyle(color)
    }

    @ViewBuilder
    private func projectTag(_ project: Project) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(Color(hex: project.colorHex))
                .frame(width: 6, height: 6)
            Text(project.name)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func personTag(_ person: Person) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "person.fill")
                .font(.system(size: 7))
                .foregroundStyle(.secondary)
            Text(person.name)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var completionButton: some View {
        Button {
            let toggleStatus = {
                if task.status == .done {
                    task.status = .todo
                } else {
                    task.status = .done
                }
                try? modelContext.save()
            }

            if reduceMotion {
                toggleStatus()
            } else {
                withAnimation(.spring(duration: 0.3)) {
                    toggleStatus()
                }
            }
        } label: {
            Group {
                if reduceMotion {
                    Image(systemName: task.status == .done ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: compact ? 18 : 22, weight: .light))
                        .foregroundStyle(task.status == .done ? .green : .secondary)
                } else {
                    Image(systemName: task.status == .done ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: compact ? 18 : 22, weight: .light))
                        .foregroundStyle(task.status == .done ? .green : .secondary)
                        .symbolEffect(.bounce, value: task.status == .done)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(task.status == .done ? "Отметить как не выполнено" : "Отметить как выполнено")
        .accessibilityHint("Переключает статус задачи")
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        ForEach(Priority.allCases) { p in
            if p != task.priority {
                Button {
                    task.priority = p
                    try? modelContext.save()
                } label: {
                    Label(
                        p == .none ? "Без приоритета" : "Приоритет: \(p.label)",
                        systemImage: p == .none ? "flag" : "flag.fill"
                    )
                }
            }
        }

        Divider()

        Button(role: .destructive) {
            modelContext.delete(task)
            try? modelContext.save()
        } label: {
            Label("Удалить", systemImage: "trash")
        }
    }
}
