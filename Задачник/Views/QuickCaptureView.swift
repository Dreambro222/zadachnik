import SwiftUI
import SwiftData

struct QuickCaptureView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Project.sortOrder) private var projects: [Project]

    @StateObject private var cal = CalendarService.shared

    @State private var text = ""
    @State private var selectedProject: Project?
    @State private var createAsTask = false
    @State private var dueDate: Date = Date()
    @State private var showDatePicker = false
    @State private var includeTime = false
    @State private var addToCalendar = false
    @State private var priority: Priority = .none
    @FocusState private var textFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Input area
                VStack(alignment: .leading, spacing: 12) {
                    TextEditor(text: $text)
                        .focused($textFocused)
                        .font(.body)
                        .frame(minHeight: 80, maxHeight: 160)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text("Что нужно сделать?")
                                    .font(.body)
                                    .foregroundStyle(.tertiary)
                                    .allowsHitTesting(false)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                            }
                        }

                    Divider()

                    // Mode toggle
                    Picker("Тип", selection: $createAsTask) {
                        Label("Заметка", systemImage: "note.text").tag(false)
                        Label("Задача", systemImage: "checkmark.circle").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                .padding(16)
                .background(.background)

                if createAsTask {
                    taskOptions
                }

                Spacer()
            }
            .background(Color.groupedBackground)
            .navigationTitle("Быстрая запись")
            .navigationInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { save() }
                        .fontWeight(.semibold)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { textFocused = true }
        }
        .presentationDetents(createAsTask ? [.medium, .large] : [.height(280)])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Task Options

    private var taskOptions: some View {
        VStack(spacing: 1) {
            // Priority
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Приоритет")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    PriorityPicker(priority: $priority)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            // Project selector
            GroupBox {
                Picker("Проект", selection: $selectedProject) {
                    Text("Без проекта").tag(Optional<Project>.none)
                    ForEach(projects) { project in
                        Label(project.name, systemImage: project.icon)
                            .tag(Optional(project))
                    }
                }
                .pickerStyle(.menu)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            // Due date
            GroupBox {
                Toggle(isOn: $showDatePicker) {
                    Label("Дата выполнения", systemImage: "calendar")
                }
                .tint(.blue)
                .onChange(of: showDatePicker) { _, on in
                    if on {
                        // Default to tomorrow 10:00
                        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                        comps.day = (comps.day ?? 0) + 1
                        comps.hour = 10
                        comps.minute = 0
                        dueDate = Calendar.current.date(from: comps) ?? Date()
                    }
                }

                if showDatePicker {
                    DatePicker(
                        "",
                        selection: $dueDate,
                        in: Date()...,
                        displayedComponents: includeTime ? [.date, .hourAndMinute] : [.date]
                    )
                    .datePickerStyle(.compact)
                    .labelsHidden()

                    Divider()

                    // Time toggle
                    Toggle(isOn: $includeTime) {
                        HStack(spacing: 5) {
                            Image(systemName: "clock").foregroundStyle(.blue)
                            Text("Указать время")
                                .font(.subheadline)
                        }
                    }
                    .tint(.blue)
                    .onChange(of: includeTime) { _, hasTime in
                        addToCalendar = hasTime  // автовключить календарь при указании времени
                    }

                    // Auto calendar toggle
                    Toggle(isOn: $addToCalendar) {
                        HStack(spacing: 5) {
                            Image(systemName: "calendar.badge.plus").foregroundStyle(.green)
                            Text("Добавить в Календарь")
                                .font(.subheadline)
                        }
                    }
                    .tint(.green)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }

    // MARK: - Save

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if createAsTask {
            let task = TaskItem(
                title: trimmed,
                priority: priority,
                deadline: showDatePicker ? dueDate : nil,
                sortOrder: selectedProject?.tasks.count ?? 0
            )
            if let project = selectedProject { task.project = project }
            modelContext.insert(task)
            try? modelContext.save()

            if addToCalendar && showDatePicker {
                let taskRef = task
                let date = dueDate
                let isAllDay = !includeTime
                Task {
                    if !cal.isAuthorized { _ = await cal.requestAccess() }
                    if let eventId = try? await cal.createOrUpdateEvent(
                        title: "✅ \(trimmed)",
                        startDate: date,
                        notes: "",
                        isAllDay: isAllDay
                    ) {
                        await MainActor.run {
                            taskRef.googleCalendarEventId = eventId
                            try? modelContext.save()
                        }
                    }
                }
            }
        } else {
            let note = QuickNote(body: trimmed)
            modelContext.insert(note)
            try? modelContext.save()
        }

        dismiss()
    }
}
