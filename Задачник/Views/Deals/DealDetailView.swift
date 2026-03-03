import SwiftUI
import SwiftData

struct DealDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Person.name) private var people: [Person]

    var deal: Deal? = nil
    var initialPersonId: UUID? = nil

    @State private var title = ""
    @State private var notes = ""
    @State private var percent: Double = 0
    @State private var amount: Double = 0
    @State private var currency = "RUB"
    @State private var hasDueDate = false
    @State private var dueDate = Date()
    @State private var status: DealStatus = .active
    @State private var selectedPersonId: UUID? = nil
    @State private var autoSaveWorkItem: DispatchWorkItem?
    @State private var didInitialLoad = false

    private var isEditing: Bool { deal != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Название") {
                    TextField("Название договорённости", text: $title, axis: .vertical)
                        .lineLimit(1...3)
                    TextField("Заметки...", text: $notes, axis: .vertical)
                        .lineLimit(1...6)
                        .foregroundStyle(.secondary)
                }

                Section("Прогресс") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Процент выполнения")
                            Spacer()
                            Text("\(Int(percent))%")
                                .fontWeight(.semibold)
                                .foregroundStyle(percent >= 100 ? .green : .blue)
                        }
                        Slider(value: $percent, in: 0...100, step: 5)
                            .tint(percent >= 100 ? .green : .blue)
                    }

                    HStack {
                        TextField("Сумма", value: $amount, format: .number)
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif

                        Picker("", selection: $currency) {
                            Text("RUB").tag("RUB")
                            Text("USD").tag("USD")
                            Text("EUR").tag("EUR")
                        }
                        .pickerStyle(.menu)
                        .frame(width: 80)
                    }
                }

                Section("Статус") {
                    Picker("Статус", selection: $status) {
                        ForEach(DealStatus.allCases) { s in
                            Label(s.label, systemImage: s.icon).tag(s)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("Сроки") {
                    Toggle("Дедлайн", isOn: $hasDueDate)
                    if hasDueDate {
                        DatePicker("Дата", selection: $dueDate, displayedComponents: .date)
                    }
                }

                Section("Контакт") {
                    Picker("Связать с контактом", selection: $selectedPersonId) {
                        Text("Не указан").tag(Optional<UUID>.none)
                        ForEach(people) { p in
                            Text(p.name).tag(Optional(p.id))
                        }
                    }
                    .pickerStyle(.menu)
                }

                if isEditing {
                    Section {
                        Button(role: .destructive) {
                            if let deal { modelContext.delete(deal) }
                            try? modelContext.save()
                            dismiss()
                        } label: {
                            HStack {
                                Spacer()
                                Label("Удалить договорённость", systemImage: "trash")
                                Spacer()
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isEditing ? "Договорённость" : "Новая договорённость")
            .navigationInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Готово" : "Создать") { save() }
                        .fontWeight(.semibold)
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                loadValues()
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

    private func loadValues() {
        if let d = deal {
            title = d.title
            notes = d.notes
            percent = d.percent
            amount = d.amount
            currency = d.currency
            hasDueDate = d.dueDate != nil
            dueDate = d.dueDate ?? Date()
            status = d.status
            selectedPersonId = d.personId
        } else {
            selectedPersonId = initialPersonId
        }
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let d = deal {
            d.title = trimmed
            d.notes = notes
            d.percent = percent
            d.amount = amount
            d.currency = currency
            d.dueDate = hasDueDate ? dueDate : nil
            d.status = status
            d.personId = selectedPersonId
        } else {
            let newDeal = Deal(
                title: trimmed,
                notes: notes,
                percent: percent,
                amount: amount,
                currency: currency,
                dueDate: hasDueDate ? dueDate : nil,
                status: status,
                personId: selectedPersonId
            )
            modelContext.insert(newDeal)
        }
        try? modelContext.save()
        dismiss()
    }

    private var autoSaveKey: String {
        [
            title, notes, "\(percent)", "\(amount)", currency,
            "\(hasDueDate)", hasDueDate ? "\(dueDate.timeIntervalSince1970)" : "nil",
            status.rawValue, selectedPersonId?.uuidString ?? "nil"
        ].joined(separator: "§")
    }

    private func scheduleAutoSaveIfNeeded() {
        guard didInitialLoad, deal != nil else { return }
        autoSaveWorkItem?.cancel()
        let work = DispatchWorkItem { autoSaveNowIfNeeded() }
        autoSaveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    private func autoSaveNowIfNeeded() {
        guard didInitialLoad, let d = deal else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        d.title = trimmed
        d.notes = notes
        d.percent = percent
        d.amount = amount
        d.currency = currency
        d.dueDate = hasDueDate ? dueDate : nil
        d.status = status
        d.personId = selectedPersonId
        try? modelContext.save()
    }
}
