import SwiftUI
import SwiftData

struct AddProjectView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Project.sortOrder) private var projects: [Project]

    var editingProject: Project?

    @State private var name = ""
    @State private var selectedColor = Project.colorPalette[0]
    @State private var selectedIcon = Project.iconOptions[0]
    @State private var autoSaveWorkItem: DispatchWorkItem?
    @State private var didInitialLoad = false

    private var isEditing: Bool { editingProject != nil }

    var body: some View {
        NavigationStack {
            Form {
                // Preview
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(Color(hex: selectedColor).opacity(0.2))
                                    .frame(width: 64, height: 64)
                                Image(systemName: selectedIcon)
                                    .font(.system(size: 28, weight: .medium))
                                    .foregroundStyle(Color(hex: selectedColor))
                            }
                            Text(name.isEmpty ? "Название проекта" : name)
                                .font(.headline)
                                .foregroundStyle(name.isEmpty ? .secondary : .primary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }

                // Name
                Section("Название") {
                    TextField("Название проекта", text: $name)
                }

                // Color
                Section("Цвет") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 12) {
                        ForEach(Project.colorPalette, id: \.self) { colorHex in
                            Button {
                                selectedColor = colorHex
                            } label: {
                                Circle()
                                    .fill(Color(hex: colorHex))
                                    .frame(width: 32, height: 32)
                                    .overlay(
                                        Circle()
                                            .strokeBorder(.white, lineWidth: 2)
                                            .opacity(selectedColor == colorHex ? 1 : 0)
                                    )
                                    .shadow(color: Color(hex: colorHex).opacity(0.5), radius: 4)
                                    .scaleEffect(selectedColor == colorHex ? 1.15 : 1.0)
                                    .animation(.spring(duration: 0.2), value: selectedColor)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Icon
                Section("Иконка") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(Project.iconOptions, id: \.self) { icon in
                            Button {
                                selectedIcon = icon
                            } label: {
                                Image(systemName: icon)
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundStyle(selectedIcon == icon ? Color(hex: selectedColor) : .secondary)
                                    .frame(width: 44, height: 44)
                                    .background(
                                        selectedIcon == icon
                                            ? Color(hex: selectedColor).opacity(0.15)
                                            : Color.secondary.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 10)
                                    )
                                    .scaleEffect(selectedIcon == icon ? 1.1 : 1.0)
                                    .animation(.spring(duration: 0.2), value: selectedIcon)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isEditing ? "Изменить проект" : "Новый проект")
            .navigationInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Сохранить" : "Создать") {
                        saveProject()
                    }
                    .fontWeight(.semibold)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                if let p = editingProject {
                    name = p.name
                    selectedColor = p.colorHex
                    selectedIcon = p.icon
                }
                didInitialLoad = true
            }
            .onDisappear {
                autoSaveWorkItem?.cancel()
                autoSaveNowIfNeeded()
            }
            .onChange(of: autoSaveKey) { _, _ in
                scheduleAutoSaveIfNeeded()
            }
        }
    }

    private func saveProject() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let project = editingProject {
            project.name = trimmed
            project.colorHex = selectedColor
            project.icon = selectedIcon
        } else {
            let project = Project(
                name: trimmed,
                colorHex: selectedColor,
                icon: selectedIcon,
                sortOrder: projects.count
            )
            modelContext.insert(project)
        }

        try? modelContext.save()
        dismiss()
    }

    private var autoSaveKey: String {
        [name, selectedColor, selectedIcon].joined(separator: "§")
    }

    private func scheduleAutoSaveIfNeeded() {
        guard didInitialLoad, editingProject != nil else { return }
        autoSaveWorkItem?.cancel()
        let work = DispatchWorkItem { autoSaveNowIfNeeded() }
        autoSaveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func autoSaveNowIfNeeded() {
        guard didInitialLoad, let project = editingProject else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        project.name = trimmed
        project.colorHex = selectedColor
        project.icon = selectedIcon
        try? modelContext.save()
    }
}
