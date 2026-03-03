import SwiftUI
import SwiftData

struct CustomFieldsSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CustomField.sortOrder) private var fields: [CustomField]

    @State private var showAdd = false

    var body: some View {
        List {
            if fields.isEmpty {
                ContentUnavailableView(
                    "Нет кастомных полей",
                    systemImage: "slider.horizontal.3",
                    description: Text("Добавьте поля для хранения дополнительной информации в задачах")
                )
            } else {
                ForEach(fields) { field in
                    HStack {
                        Image(systemName: field.type.icon)
                            .foregroundStyle(.blue)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(field.name)
                                .font(.body)
                            Text(field.type.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !field.selectOptions.isEmpty {
                                Text(field.selectOptions.joined(separator: ", "))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                    }
                }
                .onDelete { idx in
                    for i in idx { modelContext.delete(fields[i]) }
                    try? modelContext.save()
                }
                .onMove { from, to in
                    var sorted = fields
                    sorted.move(fromOffsets: from, toOffset: to)
                    for (i, f) in sorted.enumerated() { f.sortOrder = i }
                    try? modelContext.save()
                }
            }
        }
        .adaptiveListStyle()
        .navigationTitle("Поля задач")
        .navigationInline()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAdd = true } label: { Image(systemName: "plus") }
            }
            #if os(iOS)
            ToolbarItem(placement: .navigationBarLeading) {
                EditButton()
            }
            #endif
        }
        .sheet(isPresented: $showAdd) {
            AddCustomFieldView(sortOrder: fields.count)
        }
    }
}

struct AddCustomFieldView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let sortOrder: Int

    @State private var name = ""
    @State private var type: CustomFieldType = .text
    @State private var optionsText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Название поля") {
                    TextField("Например: Бюджет, Статус, Тег", text: $name)
                }

                Section("Тип") {
                    Picker("Тип", selection: $type) {
                        ForEach(CustomFieldType.allCases) { t in
                            Label(t.label, systemImage: t.icon).tag(t)
                        }
                    }
                    .pickerStyle(.menu)
                }

                if type == .select {
                    Section {
                        TextField("Вариант 1, Вариант 2, ...", text: $optionsText, axis: .vertical)
                            .lineLimit(3...6)
                    } header: {
                        Text("Варианты выбора")
                    } footer: {
                        Text("Разделяйте запятой")
                            .font(.caption)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Новое поле")
            .navigationInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Создать") { save() }
                        .fontWeight(.semibold)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() {
        let options = optionsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let field = CustomField(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            type: type,
            selectOptions: options,
            sortOrder: sortOrder
        )
        modelContext.insert(field)
        try? modelContext.save()
        dismiss()
    }
}
