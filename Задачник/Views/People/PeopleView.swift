import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - Sort Order

enum PeopleSortOrder: String, CaseIterable, Identifiable {
    case name          = "name"
    case lastContact   = "lastContact"
    case hasTasks      = "hasTasks"
    case meetingPlace  = "meetingPlace"
    case source        = "source"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .name:         return "По имени"
        case .lastContact:  return "По взаимодействию"
        case .hasTasks:     return "По задачам"
        case .meetingPlace: return "По месту знакомства"
        case .source:       return "По источнику"
        }
    }

    var icon: String {
        switch self {
        case .name:         return "textformat.abc"
        case .lastContact:  return "clock.arrow.circlepath"
        case .hasTasks:     return "checkmark.circle.fill"
        case .meetingPlace: return "mappin.and.ellipse"
        case .source:       return "arrow.triangle.branch"
        }
    }
}

// MARK: - PeopleView

struct PeopleView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \Person.name) private var people: [Person]

    @State private var searchText = ""
    @State private var selectedTag: String? = nil
    @State private var selectedSource: ContactSource? = nil
    @State private var sortOrder: PeopleSortOrder = .name
    @State private var showAddPerson = false
    @State private var showGraph = false
    @State private var viewMode: PeopleViewMode = .list
    @State private var showSortSheet = false

    private enum PeopleViewMode { case list, grid }

    // Unique tags
    private var allTags: [String] {
        Array(Set(people.flatMap { $0.categoryTags })).sorted()
    }

    // Sources that are actually used
    private var usedSources: [ContactSource] {
        let raw = Set(people.map { $0.sourceRaw }.filter { !$0.isEmpty && $0 != ContactSource.other.rawValue })
        return ContactSource.allCases.filter { raw.contains($0.rawValue) }
    }

    private var filteredAndSortedPeople: [Person] {
        var result = people

        // Search
        if !searchText.isEmpty {
            result = result.filter { p in
                p.name.localizedCaseInsensitiveContains(searchText)
                || p.role.localizedCaseInsensitiveContains(searchText)
                || p.company.localizedCaseInsensitiveContains(searchText)
                || p.notes.localizedCaseInsensitiveContains(searchText)
                || p.meetingPlace.localizedCaseInsensitiveContains(searchText)
                || p.categoryTags.contains { $0.localizedCaseInsensitiveContains(searchText) }
            }
        }

        // Tag filter
        if let tag = selectedTag {
            result = result.filter { $0.categoryTags.contains(tag) }
        }

        // Source filter
        if let src = selectedSource {
            result = result.filter { $0.source == src }
        }

        // Sort
        switch sortOrder {
        case .name:
            result.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        case .lastContact:
            result.sort {
                let d0 = $0.lastInteraction?.date ?? .distantPast
                let d1 = $1.lastInteraction?.date ?? .distantPast
                return d0 > d1
            }
        case .hasTasks:
            // people with tasks first, then by name
            result.sort {
                let t0 = $0.interactions.count  // proxy; real task count via Query not available here
                let t1 = $1.interactions.count
                if t0 != t1 { return t0 > t1 }
                return $0.name.localizedCompare($1.name) == .orderedAscending
            }
        case .meetingPlace:
            result.sort {
                let p0 = $0.meetingPlace.isEmpty ? "я" : $0.meetingPlace
                let p1 = $1.meetingPlace.isEmpty ? "я" : $1.meetingPlace
                return p0.localizedCompare(p1) == .orderedAscending
            }
        case .source:
            result.sort {
                let s0 = $0.source.label
                let s1 = $1.source.label
                if s0 != s1 { return s0.localizedCompare(s1) == .orderedAscending }
                return $0.name.localizedCompare($1.name) == .orderedAscending
            }
        }

        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            // Filter strips
            filterBar
            Divider()

            // People list or grid
            Group {
                if filteredAndSortedPeople.isEmpty {
                    emptyState
                } else {
                    switch viewMode {
                    case .list: listContent
                    case .grid: gridContent
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.groupedBackground)
        .navigationTitle("Контакты")
        .searchable(text: $searchText, prompt: "Имя, компания, место знакомства...")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAddPerson = true } label: { Image(systemName: "person.badge.plus") }
            }
            ToolbarItem {
                Button { showGraph = true } label: {
                    Label("Граф связей", systemImage: "point.3.connected.trianglepath.dotted")
                }
            }
            ToolbarItem {
                Menu {
                    ForEach(PeopleSortOrder.allCases) { order in
                        Button {
                            if reduceMotion {
                                sortOrder = order
                            } else {
                                withAnimation { sortOrder = order }
                            }
                        } label: {
                            Label(order.label, systemImage: sortOrder == order ? "checkmark" : order.icon)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .symbolVariant(sortOrder == .name ? .none : .fill)
                }
            }
            ToolbarItem {
                Button {
                    if reduceMotion {
                        viewMode = viewMode == .list ? .grid : .list
                    } else {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            viewMode = viewMode == .list ? .grid : .list
                        }
                    }
                } label: {
                    Image(systemName: viewMode == .list ? "square.grid.2x2" : "list.bullet")
                }
            }
        }
        .sheet(isPresented: $showAddPerson) {
            AddPersonView()
        }
        .sheet(isPresented: $showGraph) {
            NavigationStack {
                PersonGraphView(people: people)
                    .navigationTitle("Граф знакомств")
                    .navigationInline()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Готово") { showGraph = false }
                        }
                    }
            }
            #if os(macOS)
            .frame(minWidth: 900, minHeight: 620)
            #else
            .presentationDetents([.large])
            #endif
        }
    }

    // MARK: - Filter Bar (tags + sources)

    @ViewBuilder
    private var filterBar: some View {
        let hasTags = !allTags.isEmpty
        let hasSources = !usedSources.isEmpty
        if hasTags || hasSources {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // Tag chips
                    if hasTags {
                        filterChip(label: "Все", icon: nil, selected: selectedTag == nil && selectedSource == nil) {
                            selectedTag = nil; selectedSource = nil
                        }
                        ForEach(allTags, id: \.self) { tag in
                            filterChip(label: tag, icon: nil, selected: selectedTag == tag) {
                                selectedTag = (selectedTag == tag) ? nil : tag
                            }
                        }
                    }

                    // Source chips (if any contacts have explicit sources)
                    if hasSources {
                        if hasTags { Divider().frame(height: 20) }
                        ForEach(usedSources) { src in
                            filterChip(label: src.label, icon: src.icon, selected: selectedSource == src) {
                                selectedSource = (selectedSource == src) ? nil : src
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
    }

    private func filterChip(label: String, icon: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon).font(.system(size: 11)) }
                Text(label)
                    .font(.subheadline)
                    .fontWeight(selected ? .semibold : .regular)
            }
            .foregroundStyle(selected ? .white : .primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                selected ? Color.accentColor : Color.secondary.opacity(0.12),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .spring(duration: 0.2), value: selected)
    }

    // MARK: - List

    private var listContent: some View {
        List {
            // Group by source or meeting place when those sorts are active
            if sortOrder == .source {
                sourceGroupedList
            } else if sortOrder == .meetingPlace {
                meetingPlaceGroupedList
            } else {
                ForEach(filteredAndSortedPeople) { person in
                    personRow(person)
                }
            }
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private var sourceGroupedList: some View {
        let grouped = Dictionary(grouping: filteredAndSortedPeople) { $0.source.label }
        let keys = grouped.keys.sorted()
        ForEach(keys, id: \.self) { key in
            Section(header: Text(key).font(.caption).foregroundStyle(.secondary)) {
                ForEach(grouped[key] ?? []) { personRow($0) }
            }
        }
    }

    @ViewBuilder
    private var meetingPlaceGroupedList: some View {
        let grouped = Dictionary(grouping: filteredAndSortedPeople) {
            $0.meetingPlace.isEmpty ? "Не указано" : $0.meetingPlace
        }
        let keys = grouped.keys.sorted()
        ForEach(keys, id: \.self) { key in
            Section(header: Text(key).font(.caption).foregroundStyle(.secondary)) {
                ForEach(grouped[key] ?? []) { personRow($0) }
            }
        }
    }

    private func personRow(_ person: Person) -> some View {
        NavigationLink {
            PersonDetailView(person: person)
        } label: {
            PersonRowView(person: person)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                modelContext.delete(person)
                try? modelContext.save()
            } label: {
                Label("Удалить", systemImage: "trash")
            }
        }
    }

    // MARK: - Grid

    private var gridContent: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 12)],
                spacing: 12
            ) {
                ForEach(filteredAndSortedPeople) { person in
                    NavigationLink {
                        PersonDetailView(person: person)
                    } label: {
                        PersonGridCard(person: person)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
                .padding(.top, 48)

            Text(searchText.isEmpty && selectedTag == nil && selectedSource == nil
                 ? "Нет контактов"
                 : "Никого не найдено")
                .font(.title2)
                .fontWeight(.semibold)

            if searchText.isEmpty && selectedTag == nil && selectedSource == nil {
                Text("Добавь первый контакт, чтобы начать строить сеть знакомств")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Button { showAddPerson = true } label: {
                    Label("Добавить контакт", systemImage: "person.badge.plus")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Person Row

struct PersonRowView: View {
    let person: Person
    @Environment(\.modelContext) private var modelContext
    @Query private var allTasks: [TaskItem]

    @State private var showAddTask   = false
    @State private var showAddNote   = false
    @State private var showAddFile   = false

    init(person: Person) {
        self.person = person
        let pid = person.id
        _allTasks = Query(filter: #Predicate<TaskItem> {
            $0.linkedPersonId == pid && $0.statusRaw != "Готово"
        })
    }

    private var linkedTasks: [TaskItem] { allTasks }

    private var taskCount: Int { linkedTasks.count }
    private var urgentCount: Int {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        return linkedTasks.filter { ($0.deadline ?? .distantFuture) <= tomorrow }.count
    }

    var body: some View {
        HStack(spacing: 12) {
            // Avatar with task indicator overlay (Variant A)
            ZStack(alignment: .topTrailing) {
                PersonAvatarView(person: person, size: 44)

                if taskCount > 0 {
                    ZStack {
                        Circle()
                            .fill(urgentCount > 0 ? Color.red : Color.blue)
                            .frame(width: 16, height: 16)
                        Text("\(taskCount)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .offset(x: 4, y: -4)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                // Row 1: name + task pill (Variant B) + last contact
                HStack(spacing: 6) {
                    Text(person.name)
                        .font(.body)
                        .fontWeight(.semibold)

                    // Variant B — inline pill next to name
                    if taskCount > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: urgentCount > 0 ? "exclamationmark.circle.fill" : "circle.fill")
                                .font(.system(size: 7))
                            Text("\(taskCount)")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(urgentCount > 0 ? .red : .blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            (urgentCount > 0 ? Color.red : Color.blue).opacity(0.12),
                            in: Capsule()
                        )
                    }

                    Spacer()

                    // Birthday indicator
                    if let days = person.daysUntilBirthday, days <= 7 {
                        HStack(spacing: 2) {
                            Image(systemName: days == 0 ? "gift.fill" : "gift")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(days <= 2 ? .pink : .orange)
                            if days > 0 {
                                Text("\(days)д")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(days <= 2 ? .pink : .orange)
                            }
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            (days == 0 ? Color.pink : Color.orange).opacity(0.12),
                            in: Capsule()
                        )
                    }

                    if let last = person.lastInteraction {
                        Text(last.date.shortLabel)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                // Row 2: role · company · source · place
                HStack(spacing: 4) {
                    if !person.role.isEmpty {
                        Text(person.role).font(.caption).foregroundStyle(.secondary)
                    }
                    if !person.role.isEmpty && !person.company.isEmpty {
                        Text("·").font(.caption).foregroundStyle(.tertiary)
                    }
                    if !person.company.isEmpty {
                        Text(person.company).font(.caption).foregroundStyle(.secondary)
                    }

                    if person.source != .other || !person.meetingPlace.isEmpty {
                        if !person.role.isEmpty || !person.company.isEmpty {
                            Text("·").font(.caption).foregroundStyle(.tertiary)
                        }
                        if person.source != .other {
                            Label(person.source.label, systemImage: person.source.icon)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .labelStyle(.iconOnly)
                        }
                        if !person.meetingPlace.isEmpty {
                            Text(person.meetingPlace)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .lineLimit(1)

                // Row 3: tags + action buttons
                HStack(spacing: 5) {
                    ForEach(person.categoryTags.prefix(2), id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                    if person.categoryTags.count > 2 {
                        Text("+\(person.categoryTags.count - 2)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    PersonActionButton(icon: "checkmark.circle.fill", label: "Задача",  color: .blue)   { showAddTask = true }
                    PersonActionButton(icon: "note.text",              label: "Заметка", color: .orange) { showAddNote = true }
                    PersonActionButton(icon: "paperclip",              label: "Файл",    color: .purple) { showAddFile = true }

                    if !person.telegramUsername.isEmpty {
                        PersonActionButton(icon: "paperplane.fill", label: "TG",
                                           color: Color(red: 0.15, green: 0.56, blue: 0.88)) {
                            let u = person.telegramUsername.trimmingCharacters(in: .init(charactersIn: "@"))
                            if let url = URL(string: "https://t.me/\(u)") {
                                #if os(macOS)
                                NSWorkspace.shared.open(url)
                                #else
                                UIApplication.shared.open(url)
                                #endif
                            }
                        }
                    }
                }

                // Row 4: task preview (up to 3 tasks)
                if !linkedTasks.isEmpty {
                    let sorted = linkedTasks.sorted {
                        let d0 = $0.deadline ?? .distantFuture
                        let d1 = $1.deadline ?? .distantFuture
                        return d0 < d1
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(sorted.prefix(3)) { task in
                            PersonTaskPreviewRow(task: task)
                        }
                        if linkedTasks.count > 3 {
                            Text("+ ещё \(linkedTasks.count - 3) задач")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 14)
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 6)
        // Quick task sheet
        .sheet(isPresented: $showAddTask) {
            PersonQuickTaskSheet(person: person)
        }
        // Quick note sheet
        .sheet(isPresented: $showAddNote) {
            PersonQuickNoteSheet(person: person)
        }
        // File picker
        .sheet(isPresented: $showAddFile) {
            PersonFilePicker(person: person)
        }
    }
}

// MARK: - Task preview row inside person card

struct PersonTaskPreviewRow: View {
    let task: TaskItem

    private var isOverdue: Bool {
        guard let d = task.deadline else { return false }
        return d < Calendar.current.startOfDay(for: Date())
    }
    private var isUrgent: Bool {
        guard let d = task.deadline else { return false }
        let soon = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        return d <= soon
    }

    private var dotColor: Color {
        if isOverdue { return .red }
        if isUrgent  { return .orange }
        return .secondary
    }

    private var progress: Int? {
        task.checklistProgressPercent ?? (task.completionPercent > 0 ? task.completionPercent : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 5, height: 5)

                Text(task.title)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                if let d = task.deadline {
                    Text(d, style: .date)
                        .font(.caption2)
                        .foregroundStyle(isOverdue ? Color.red : Color.secondary.opacity(0.6))
                }

                if task.priorityRaw > 0 {
                    HStack(spacing: 1) {
                        ForEach(0..<min(task.priorityRaw, 5), id: \.self) { _ in
                            Image(systemName: "star.fill")
                                .font(.system(size: 7))
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }

            if let progress {
                HStack(spacing: 6) {
                    GeometryReader { geo in
                        let clamped = max(0, min(progress, 100))
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.18))
                            Capsule()
                                .fill(clamped >= 100 ? Color.yellow : Color.accentColor)
                                .frame(width: geo.size.width * CGFloat(clamped) / 100.0)
                        }
                    }
                    .frame(height: 4)

                    Text("\(progress)%")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(height: 10)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Compact action button

struct PersonActionButton: View {
    let icon: String
    let label: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityHint("Быстрое действие для контакта")
    }
}

// MARK: - Quick Task Sheet

struct PersonQuickTaskSheet: View {
    let person: Person
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var deadline: Date = Calendar.current.date(byAdding: .day, value: 3, to: Date()) ?? Date()
    @State private var hasDeadline = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Что нужно сделать?", text: $title, axis: .vertical)
                        .lineLimit(2...5)
                        .focused($focused)
                }

                Section {
                    Toggle("Дедлайн", isOn: $hasDeadline)
                    if hasDeadline {
                        DatePicker("Дата", selection: $deadline, displayedComponents: .date)
                            .datePickerStyle(.compact)
                    }
                }

                Section {
                    HStack {
                        PersonAvatarView(person: person, size: 28)
                        Text(person.name)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.blue)
                    }
                } header: {
                    Text("Контакт")
                }
            }
            .navigationTitle("Задача по контакту")
            .navigationInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Добавить") { save() }
                        .fontWeight(.semibold)
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let task = TaskItem(
            title: t,
            notes: "Контакт: \(person.name)",
            deadline: hasDeadline ? deadline : nil,
            linkedPersonId: person.id
        )
        modelContext.insert(task)
        try? modelContext.save()
        dismiss()
    }
}

// MARK: - Quick Note Sheet

struct PersonQuickNoteSheet: View {
    let person: Person
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var noteText = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "person.fill")
                        .foregroundStyle(.secondary)
                    Text(person.name)
                }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 8)

                TextEditor(text: $noteText)
                    .focused($focused)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 16)
            }
            .background(Color.groupedBackground)
            .navigationTitle("Заметка")
            .navigationInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { save() }
                        .fontWeight(.semibold)
                        .disabled(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        let text = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let note = QuickNote(body: text, title: person.name)
        modelContext.insert(note)
        try? modelContext.save()
        dismiss()
    }
}

// MARK: - File Picker Sheet

struct PersonFilePicker: View {
    let person: Person
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var isImporting = false
    @State private var savedFiles: [String] = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "paperclip.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.purple.gradient)
                    .padding(.top, 32)

                Text("Прикрепить файл к контакту")
                    .font(.headline)

                Text(person.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button {
                    isImporting = true
                } label: {
                    Label("Выбрать файл", systemImage: "folder.badge.plus")
                        .fontWeight(.semibold)
                        .frame(maxWidth: 240)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)

                if !savedFiles.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(savedFiles, id: \.self) { name in
                            Label(name, systemImage: "doc.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 8)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Файлы")
            .navigationInline()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                saveFile(url: url)
            }
        }
        .presentationDetents([.medium])
    }

    private func saveFile(url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        let dir = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let destName = UUID().uuidString + "_" + url.lastPathComponent
        let dest = dir.appendingPathComponent(destName)
        try? FileManager.default.copyItem(at: url, to: dest)

        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
        let att = Attachment(
            fileName: destName,
            mimeType: "application/octet-stream",
            fileSize: size
        )
        att.displayName = url.lastPathComponent
        modelContext.insert(att)
        try? modelContext.save()

        savedFiles.append(url.lastPathComponent)
    }
}

// MARK: - Grid Card

struct PersonGridCard: View {
    let person: Person

    var body: some View {
        VStack(spacing: 10) {
            PersonAvatarView(person: person, size: 56)

            Text(person.name)
                .font(.subheadline)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            if !person.displayRole.isEmpty {
                Text(person.displayRole)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }

            if let tag = person.categoryTags.first {
                Text(tag)
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
    }
}

// MARK: - Avatar

struct PersonAvatarView: View {
    let person: Person
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(hex: person.colorHex).gradient)
                .frame(width: size, height: size)

            Text(person.initials)
                .font(.system(size: size * 0.36, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
    }
}
