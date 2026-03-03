import SwiftUI
import SwiftData

struct PatternsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RecurringPattern.nextDate) private var patterns: [RecurringPattern]

    @State private var showAdd = false

    private var duePatterns: [RecurringPattern] {
        patterns.filter { $0.isActive && $0.isDueToday }
    }

    private var upcomingPatterns: [RecurringPattern] {
        patterns.filter { $0.isActive && !$0.isDueToday }
    }

    var body: some View {
        Group {
            if patterns.isEmpty {
                emptyState
            } else {
                List {
                    if !duePatterns.isEmpty {
                        Section {
                            ForEach(duePatterns) { pattern in
                                PatternRowView(pattern: pattern) {
                                    markDone(pattern)
                                }
                            }
                            .onDelete { idx in delete(at: idx, from: duePatterns) }
                        } header: {
                            Label("Сегодня", systemImage: "sun.max.fill")
                                .foregroundStyle(.orange)
                        }
                    }

                    if !upcomingPatterns.isEmpty {
                        Section("Предстоящие") {
                            ForEach(upcomingPatterns) { pattern in
                                PatternRowView(pattern: pattern) {
                                    markDone(pattern)
                                }
                            }
                            .onDelete { idx in delete(at: idx, from: upcomingPatterns) }
                        }
                    }
                }
                .adaptiveListStyle()
            }
        }
        .navigationTitle("Ритуалы")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAdd = true } label: { Image(systemName: "plus") }
                .accessibilityLabel("Новый ритуал")
                .accessibilityHint("Открывает форму добавления ритуала")
            }
        }
        .sheet(isPresented: $showAdd) {
            AddPatternView()
        }
    }

    private func markDone(_ pattern: RecurringPattern) {
        pattern.advance()
        try? modelContext.save()
    }

    private func delete(at offsets: IndexSet, from array: [RecurringPattern]) {
        for i in offsets { modelContext.delete(array[i]) }
        try? modelContext.save()
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.purple.gradient)

            Text("Нет ритуалов")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Добавляйте повторяющиеся дела и привычки, которые нужно делать регулярно")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button { showAdd = true } label: {
                Label("Добавить ритуал", systemImage: "plus")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Pattern Row

struct PatternRowView: View {
    let pattern: RecurringPattern
    let onDone: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onDone) {
                Image(systemName: pattern.isDueToday ? "checkmark.circle" : "circle")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(pattern.isDueToday ? .blue : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(pattern.isDueToday ? "Отметить ритуал как выполненный сегодня" : "Ритуал не запланирован на сегодня")

            VStack(alignment: .leading, spacing: 3) {
                Text(pattern.title)
                    .font(.body)
                    .fontWeight(.medium)

                HStack(spacing: 4) {
                    Image(systemName: pattern.interval.icon)
                        .font(.caption2)
                    Text(pattern.interval.label)
                        .font(.caption)

                    Text("·")
                        .foregroundStyle(.secondary)

                    Text("Следующий: \(pattern.nextDate.shortLabel)")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }

            Spacer()

            if pattern.isDueToday {
                Text("Сегодня")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.orange, in: Capsule())
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Add Pattern

struct AddPatternView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var notes = ""
    @State private var interval: RecurringInterval = .weekly
    @State private var customDays = 7
    @State private var startDate = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section("Название") {
                    TextField("Название ритуала", text: $title)
                    TextField("Заметки...", text: $notes, axis: .vertical)
                        .lineLimit(1...4)
                        .foregroundStyle(.secondary)
                }

                Section("Повторение") {
                    Picker("Интервал", selection: $interval) {
                        ForEach(RecurringInterval.allCases) { i in
                            Label(i.label, systemImage: i.icon).tag(i)
                        }
                    }
                    .pickerStyle(.menu)

                    if interval == .custom {
                        Stepper("Каждые \(customDays) дн.", value: $customDays, in: 1...365)
                    }

                    DatePicker("Первый раз", selection: $startDate, displayedComponents: .date)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Новый ритуал")
            .navigationInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Создать") { save() }
                        .fontWeight(.semibold)
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() {
        let pattern = RecurringPattern(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: notes,
            interval: interval,
            customDays: customDays,
            nextDate: startDate
        )
        modelContext.insert(pattern)
        try? modelContext.save()
        dismiss()
    }
}
