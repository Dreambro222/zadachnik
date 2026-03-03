import SwiftUI
import SwiftData

struct TimelineView: View {
    @Environment(\.modelContext) private var modelContext
    let project: Project

    @State private var scrollTarget: String?

    private var tasksByDate: [(date: Date, label: String, tasks: [TaskItem])] {
        let withDates = project.tasks.filter { $0.dueDate != nil && $0.status != .done }
        let grouped = Dictionary(grouping: withDates) {
            Calendar.current.startOfDay(for: $0.dueDate!)
        }
        return grouped.map { (date: $0.key, label: $0.key.relativeLabel, tasks: $0.value.sorted { $0.priorityRaw > $1.priorityRaw }) }
            .sorted { $0.date < $1.date }
    }

    private var noDueDateTasks: [TaskItem] {
        project.tasks.filter { $0.dueDate == nil && $0.status != .done }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if tasksByDate.isEmpty && noDueDateTasks.isEmpty {
                        emptyState
                    } else {
                        ForEach(tasksByDate, id: \.date) { group in
                            dateSection(
                                date: group.date,
                                label: group.label,
                                tasks: group.tasks
                            )
                            .id(group.date.startOfDay.description)
                        }

                        if !noDueDateTasks.isEmpty {
                            noDueDateSection
                        }
                    }
                }
                .padding(.vertical, 8)
                .padding(.bottom, 32)
            }
            .background(Color.groupedBackground)
            .onAppear {
                // Scroll to today's section
                let today = Date().startOfDay.description
                withAnimation(.easeOut(duration: 0.5)) {
                    proxy.scrollTo(today, anchor: .top)
                }
            }
        }
    }

    private func dateSection(date: Date, label: String, tasks: [TaskItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Date header with timeline indicator
            HStack(alignment: .top, spacing: 0) {
                // Timeline vertical line
                VStack(spacing: 0) {
                    Circle()
                        .fill(date.isToday ? Color(hex: project.colorHex) : .secondary)
                        .frame(width: 10, height: 10)
                        .overlay(
                            Circle()
                                .strokeBorder(date.isToday ? Color(hex: project.colorHex) : .secondary, lineWidth: 2)
                                .frame(width: 16, height: 16)
                        )
                    Rectangle()
                        .fill(.secondary.opacity(0.2))
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
                .frame(width: 40)
                .padding(.leading, 16)

                // Date label
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.headline)
                        .fontWeight(date.isToday ? .bold : .semibold)
                        .foregroundStyle(date.isPast && !date.isToday ? .red : (date.isToday ? Color(hex: project.colorHex) : .primary))

                    Text(DateFormatter.ruMedium.string(from: date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
                .padding(.leading, 12)
            }
            .frame(minHeight: 32)
            .padding(.top, 12)

            // Tasks under date
            HStack(alignment: .top, spacing: 0) {
                // Continuation line
                Rectangle()
                    .fill(.secondary.opacity(0.2))
                    .frame(width: 2)
                    .padding(.leading, 20)
                    .frame(width: 40)

                VStack(spacing: 8) {
                    ForEach(tasks) { task in
                        TaskCard(task: task, compact: true)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    modelContext.delete(task)
                                    try? modelContext.save()
                                } label: {
                                    Label("Удалить", systemImage: "trash")
                                }
                            }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
    }

    private var noDueDateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "calendar.badge.exclamationmark")
                    .foregroundStyle(.secondary)
                Text("Без даты")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)

            ForEach(noDueDateTasks) { task in
                TaskCard(task: task, compact: true)
                    .padding(.horizontal, 16)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(Color(hex: project.colorHex).gradient)
                .padding(.top, 48)

            Text("Нет задач с датами")
                .font(.title3)
                .fontWeight(.semibold)

            Text("Добавьте дату выполнения к задачам, чтобы они отображались в таймлайне")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}
