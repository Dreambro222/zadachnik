import SwiftUI
import SwiftData

struct AddPersonView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Person.name) private var allPeople: [Person]

    var editingPerson: Person?

    @State private var name = ""
    @State private var role = ""
    @State private var company = ""
    @State private var email = ""
    @State private var phone = ""
    @State private var telegramUsername = ""
    @State private var notes = ""
    @State private var selectedColor = Person.avatarColors[0]
    @State private var tags: [String] = []
    @State private var newTag = ""
    @State private var selectedIntroducer: Person? = nil
    @State private var didChangeIntroducer = false
    @State private var introducerSearchText = ""
    @State private var showIntroducerPicker = false
    @State private var selectedSource: ContactSource = .other
    @State private var meetingPlace = ""
    @State private var hasBirthday = false
    @State private var birthday: Date = {
        // Default to "Jan 1, current year" as a neutral placeholder
        var c = Calendar.current.dateComponents([.year], from: Date())
        c.month = 1; c.day = 1
        return Calendar.current.date(from: c) ?? Date()
    }()
    @State private var importantDates: [ImportantDate] = []
    @State private var newDateLabel = ""
    @State private var newDateValue: Date = Date()
    @State private var showAddImportantDate = false
    @State private var autoSaveWorkItem: DispatchWorkItem?
    @State private var didInitialLoad = false

    @FocusState private var nameFocused: Bool

    private var isEditing: Bool { editingPerson != nil }

    private var filteredPeopleForIntroducer: [Person] {
        if introducerSearchText.isEmpty { return allPeople }
        return allPeople.filter {
            $0.name.localizedCaseInsensitiveContains(introducerSearchText)
                || $0.company.localizedCaseInsensitiveContains(introducerSearchText)
        }
    }

    private var introducerCandidates: [Person] {
        filteredPeopleForIntroducer.filter { $0.id != editingPerson?.id }
    }

    var body: some View {
        NavigationStack {
            Form {
                // Avatar preview
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 10) {
                            ZStack {
                                Circle()
                                    .fill(Color(hex: selectedColor).gradient)
                                    .frame(width: 72, height: 72)
                                Text(initials)
                                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white)
                            }
                            Text(name.isEmpty ? "Имя" : name)
                                .font(.headline)
                                .foregroundStyle(name.isEmpty ? .secondary : .primary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 6)
                    .listRowBackground(Color.clear)
                }

                // Basic info
                Section("Основное") {
                    TextField("Имя *", text: $name)
                        .focused($nameFocused)
                    TextField("Должность / Роль", text: $role)
                    TextField("Компания / Организация", text: $company)
                }

                // Contact
                Section("Контакты") {
                    HStack {
                        Image(systemName: "envelope.fill")
                            .foregroundStyle(.orange)
                            .frame(width: 22)
                        TextField("Email", text: $email)
                            .emailInputStyle()
                    }
                    HStack {
                        Image(systemName: "phone.fill")
                            .foregroundStyle(.green)
                            .frame(width: 22)
                        TextField("Телефон", text: $phone)
                            .phoneInputStyle()
                    }
                    HStack {
                        Image(systemName: "paperplane.fill")
                            .foregroundStyle(Color(red: 0.15, green: 0.56, blue: 0.88))
                            .frame(width: 22)
                        TextField("Telegram (@username)", text: $telegramUsername)
                            #if os(iOS)
                            .keyboardType(.twitter)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            #endif
                    }
                }

                // Tags
                Section {
                    // Existing tags
                    if !tags.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(tags, id: \.self) { tag in
                                    HStack(spacing: 4) {
                                        Text(tag)
                                            .font(.caption)
                                            .fontWeight(.medium)
                                        Button {
                                            tags.removeAll { $0 == tag }
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                                    .foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    // New tag input
                    HStack {
                        TextField("Добавить категорию (напр. «инвестор»)", text: $newTag)
                            .submitLabel(.done)
                            .onSubmit { addTag() }
                        if !newTag.isEmpty {
                            Button(action: addTag) {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Suggestions
                    let suggestions = commonTagSuggestions.filter { s in
                        !tags.contains(s) && (newTag.isEmpty || s.localizedCaseInsensitiveContains(newTag))
                    }
                    if !suggestions.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(suggestions.prefix(8), id: \.self) { suggestion in
                                    Button {
                                        tags.append(suggestion)
                                    } label: {
                                        Text("+ \(suggestion)")
                                            .font(.caption)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(.secondary.opacity(0.1), in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } header: {
                    Text("Категории / Чем занимается")
                }

                // Source & Meeting Place
                Section("Откуда знаем") {
                    Picker("Источник знакомства", selection: $selectedSource) {
                        ForEach(ContactSource.allCases) { src in
                            Label(src.label, systemImage: src.icon).tag(src)
                        }
                    }

                    HStack {
                        Image(systemName: "mappin.and.ellipse")
                            .foregroundStyle(.pink)
                            .frame(width: 22)
                        TextField("Место знакомства (конференция, кафе...)", text: $meetingPlace)
                    }
                }

                // Birthday & important dates
                Section("Важные даты") {
                    Toggle(isOn: $hasBirthday) {
                        Label("День рождения", systemImage: "birthday.cake.fill")
                    }
                    .tint(.pink)

                    if hasBirthday {
                        DatePicker(
                            "Дата",
                            selection: $birthday,
                            displayedComponents: [.date]
                        )
                        .datePickerStyle(.compact)
                    }

                    // Existing important dates
                    ForEach($importantDates) { $item in
                        HStack(spacing: 10) {
                            Image(systemName: "star.fill")
                                .foregroundStyle(.yellow)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.label)
                                    .font(.subheadline)
                                Text(item.date.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                importantDates.removeAll { $0.id == item.id }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Add important date inline
                    if showAddImportantDate {
                        VStack(spacing: 8) {
                            TextField("Название (напр. «Годовщина»)", text: $newDateLabel)
                            DatePicker("Дата", selection: $newDateValue, displayedComponents: [.date])
                                .datePickerStyle(.compact)
                            HStack {
                                Button("Отмена") {
                                    showAddImportantDate = false
                                    newDateLabel = ""
                                }
                                .foregroundStyle(.secondary)
                                .buttonStyle(.plain)
                                Spacer()
                                Button("Добавить") {
                                    let trimmed = newDateLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !trimmed.isEmpty {
                                        importantDates.append(ImportantDate(label: trimmed, date: newDateValue))
                                    }
                                    showAddImportantDate = false
                                    newDateLabel = ""
                                }
                                .fontWeight(.semibold)
                                .disabled(newDateLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .buttonStyle(.plain)
                            }
                            .font(.subheadline)
                        }
                        .padding(.vertical, 4)
                    } else {
                        Button {
                            showAddImportantDate = true
                        } label: {
                            Label("Добавить важную дату", systemImage: "plus.circle")
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Introducer
                Section("Кто познакомил") {
                    if let intro = selectedIntroducer {
                        HStack(spacing: 10) {
                            PersonAvatarView(person: intro, size: 32)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(intro.name)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                if !intro.displayRole.isEmpty {
                                    Text(intro.displayRole)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("Изменить") {
                                introducerSearchText = ""
                                showIntroducerPicker = true
                            }
                            .font(.caption)
                            .foregroundStyle(.blue)
                            .buttonStyle(.plain)
                            Button("Убрать") {
                                selectedIntroducer = nil
                                didChangeIntroducer = true
                            }
                            .font(.caption)
                            .foregroundStyle(.red)
                            .buttonStyle(.plain)
                        }
                    } else {
                        Button {
                            introducerSearchText = ""
                            showIntroducerPicker = true
                        } label: {
                            HStack {
                                Image(systemName: "person.line.dotted.person.fill")
                                    .foregroundStyle(.secondary)
                                Text("Выбрать контакт...")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Avatar color
                Section("Цвет аватара") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 10) {
                        ForEach(Person.avatarColors, id: \.self) { colorHex in
                            Button {
                                selectedColor = colorHex
                            } label: {
                                Circle()
                                    .fill(Color(hex: colorHex))
                                    .frame(width: 30, height: 30)
                                    .overlay(
                                        Circle()
                                            .strokeBorder(.white, lineWidth: 2.5)
                                            .opacity(selectedColor == colorHex ? 1 : 0)
                                    )
                                    .shadow(
                                        color: Color(hex: colorHex).opacity(0.5),
                                        radius: selectedColor == colorHex ? 4 : 0
                                    )
                                    .scaleEffect(selectedColor == colorHex ? 1.15 : 1.0)
                                    .animation(.spring(duration: 0.2), value: selectedColor)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Notes
                Section("Заметки") {
                    RichTextEditor(raw: $notes, placeholder: "Заметки, договоренности, чеклист...", minHeight: 100)
                        .listRowInsets(.init(top: 8, leading: 8, bottom: 8, trailing: 8))
                }

                // Delete (edit mode)
                if isEditing {
                    Section {
                        Button(role: .destructive) {
                            if let person = editingPerson {
                                modelContext.delete(person)
                                try? modelContext.save()
                            }
                            dismiss()
                        } label: {
                            HStack {
                                Spacer()
                                Label("Удалить контакт", systemImage: "trash")
                                Spacer()
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isEditing ? "Редактировать" : "Новый контакт")
            .navigationInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Сохранить" : "Добавить") {
                        savePerson()
                    }
                    .fontWeight(.semibold)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                if let p = editingPerson {
                    name = p.name
                    role = p.role
                    company = p.company
                    email = p.email
                    phone = p.phone
                    telegramUsername = p.telegramUsername
                    notes = p.notes
                    selectedColor = p.colorHex
                    tags = p.categoryTags
                    // Safety: avoid touching potentially stale relation while loading form.
                    selectedIntroducer = nil
                    selectedSource = p.source
                    meetingPlace = p.meetingPlace
                    if let bd = p.birthday {
                        hasBirthday = true
                        birthday = bd
                    }
                    importantDates = p.importantDates
                } else {
                    nameFocused = true
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
            .sheet(isPresented: $showIntroducerPicker) {
                introducerPickerSheet
            }
        }
    }

    // MARK: - Introducer Picker

    private var introducerPickerSheet: some View {
        NavigationStack {
            VStack(spacing: 12) {
                // Explicit search field is more stable than .searchable inside compact macOS sheets.
                TextField("Поиск контакта...", text: $introducerSearchText)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)

                if introducerCandidates.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.badge.questionmark")
                            .font(.system(size: 34))
                            .foregroundStyle(.secondary)
                        Text("Контактов для выбора пока нет")
                            .font(.headline)
                        Text("Добавь хотя бы один контакт или создай его прямо здесь.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)

                        if !introducerSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button {
                                createIntroducerFromSearch()
                            } label: {
                                Label("Создать «\(introducerSearchText.trimmingCharacters(in: .whitespacesAndNewlines))»", systemImage: "plus.circle.fill")
                                    .font(.subheadline)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(introducerCandidates) { person in
                                HStack {
                                    PersonRowView(person: person)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedIntroducer = person
                                    didChangeIntroducer = true
                                    showIntroducerPicker = false
                                }

                                Divider()
                                    .padding(.leading, 56)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Кто познакомил?")
            .navigationInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { showIntroducerPicker = false }
                }
            }
        }
    }

    private func createIntroducerFromSearch() {
        let trimmed = introducerSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let newIntroducer = Person(name: trimmed)
        modelContext.insert(newIntroducer)
        try? modelContext.save()
        selectedIntroducer = newIntroducer
        showIntroducerPicker = false
    }

    // MARK: - Helpers

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first }.map(String.init).joined().uppercased()
    }

    private func addTag() {
        let trimmed = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !tags.contains(trimmed) else { return }
        tags.append(trimmed)
        newTag = ""
    }

    private func savePerson() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let person = editingPerson {
            person.name = trimmed
            person.role = role
            person.company = company
            person.email = email
            person.phone = phone
            person.telegramUsername = telegramUsername.trimmingCharacters(in: .init(charactersIn: "@"))
            person.notes = notes
            person.colorHex = selectedColor
            person.categoryTags = tags
            if didChangeIntroducer {
                person.introducer = selectedIntroducer
            }
            person.source = selectedSource
            person.meetingPlace = meetingPlace
            person.birthday = hasBirthday ? birthday : nil
            person.importantDates = importantDates
        } else {
            let person = Person(
                name: trimmed,
                role: role,
                company: company,
                email: email,
                phone: phone,
                telegramUsername: telegramUsername.trimmingCharacters(in: .init(charactersIn: "@")),
                categoryTags: tags,
                notes: notes,
                colorHex: selectedColor,
                source: selectedSource,
                meetingPlace: meetingPlace,
                birthday: hasBirthday ? birthday : nil,
                importantDates: importantDates
            )
            person.introducer = selectedIntroducer
            modelContext.insert(person)
        }

        try? modelContext.save()
        dismiss()
    }

    private var autoSaveKey: String {
        [
            name, role, company, email, phone, telegramUsername, notes, selectedColor,
            tags.joined(separator: ","), selectedIntroducer?.id.uuidString ?? "nil",
            selectedSource.rawValue, meetingPlace, "\(hasBirthday)",
            hasBirthday ? "\(birthday.timeIntervalSince1970)" : "nil",
            importantDates.map { "\($0.id.uuidString)|\($0.label)|\($0.date.timeIntervalSince1970)" }.joined(separator: ",")
        ].joined(separator: "§")
    }

    private func scheduleAutoSaveIfNeeded() {
        guard didInitialLoad, editingPerson != nil else { return }
        autoSaveWorkItem?.cancel()
        let work = DispatchWorkItem { autoSaveNowIfNeeded() }
        autoSaveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    private func autoSaveNowIfNeeded() {
        guard didInitialLoad, let person = editingPerson else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        person.name = trimmed
        person.role = role
        person.company = company
        person.email = email
        person.phone = phone
        person.telegramUsername = telegramUsername.trimmingCharacters(in: .init(charactersIn: "@"))
        person.notes = notes
        person.colorHex = selectedColor
        person.categoryTags = tags
        if didChangeIntroducer {
            person.introducer = selectedIntroducer
        }
        person.source = selectedSource
        person.meetingPlace = meetingPlace
        person.birthday = hasBirthday ? birthday : nil
        person.importantDates = importantDates
        try? modelContext.save()
    }

    private let commonTagSuggestions = [
        "инвестор", "основатель", "предприниматель", "разработчик",
        "дизайнер", "маркетинг", "продажи", "партнёр", "ментор",
        "клиент", "коллега", "друг", "медиа", "технологии",
        "финансы", "юрист", "стартап", "VC", "бизнес-ангел"
    ]
}
