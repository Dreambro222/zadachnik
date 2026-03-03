import SwiftUI
import SwiftData

struct GlobalSearchView: View {
    @Query(sort: \TaskItem.createdAt, order: .reverse) private var tasks: [TaskItem]
    @Query(sort: \QuickNote.createdAt, order: .reverse) private var notes: [QuickNote]
    @Query(sort: \Person.name) private var people: [Person]
    @Query(sort: \Deal.createdAt, order: .reverse) private var deals: [Deal]
    @Query(sort: \MaterialLink.createdAt, order: .reverse) private var materials: [MaterialLink]
    @Query(sort: \VoiceMemo.createdAt, order: .reverse) private var memos: [VoiceMemo]

    @State private var searchText = ""

    private var matchedTasks: [TaskItem] {
        guard !searchText.isEmpty else { return [] }
        return tasks.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
            || $0.notes.localizedCaseInsensitiveContains(searchText)
            || $0.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
        }
    }

    private var matchedNotes: [QuickNote] {
        guard !searchText.isEmpty else { return [] }
        return notes.filter {
            $0.body.localizedCaseInsensitiveContains(searchText)
            || $0.title.localizedCaseInsensitiveContains(searchText)
            || $0.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
        }
    }

    private var matchedPeople: [Person] {
        guard !searchText.isEmpty else { return [] }
        return people.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
            || $0.company.localizedCaseInsensitiveContains(searchText)
            || $0.role.localizedCaseInsensitiveContains(searchText)
            || $0.notes.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var matchedDeals: [Deal] {
        guard !searchText.isEmpty else { return [] }
        return deals.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
            || $0.notes.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var matchedMaterials: [MaterialLink] {
        guard !searchText.isEmpty else { return [] }
        return materials.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
            || $0.url.localizedCaseInsensitiveContains(searchText)
            || $0.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
        }
    }

    private var matchedMemos: [VoiceMemo] {
        guard !searchText.isEmpty else { return [] }
        return memos.filter {
            $0.transcription.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var totalCount: Int {
        matchedTasks.count + matchedNotes.count + matchedPeople.count
        + matchedDeals.count + matchedMaterials.count + matchedMemos.count
    }

    var body: some View {
        Group {
            if searchText.isEmpty {
                searchTips
            } else if totalCount == 0 {
                noResults
            } else {
                List {
                    if !matchedTasks.isEmpty {
                        Section("Задачи (\(matchedTasks.count))") {
                            ForEach(matchedTasks.prefix(10)) { task in
                                NavigationLink {
                                    TaskDetailView(task: task, project: task.project)
                                } label: {
                                    taskResult(task)
                                }
                            }
                        }
                    }

                    if !matchedNotes.isEmpty {
                        Section("Заметки (\(matchedNotes.count))") {
                            ForEach(matchedNotes.prefix(10)) { note in
                                NavigationLink {
                                    NoteEditView(note: note)
                                } label: {
                                    noteResult(note)
                                }
                            }
                        }
                    }

                    if !matchedPeople.isEmpty {
                        Section("Люди (\(matchedPeople.count))") {
                            ForEach(matchedPeople.prefix(10)) { person in
                                NavigationLink { PersonDetailView(person: person) } label: {
                                    HStack {
                                        PersonAvatarView(person: person, size: 32)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(person.name).font(.body).fontWeight(.medium)
                                            if !person.displayRole.isEmpty {
                                                Text(person.displayRole).font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    if !matchedDeals.isEmpty {
                        Section("Договорённости (\(matchedDeals.count))") {
                            ForEach(matchedDeals.prefix(5)) { deal in
                                HStack {
                                    Image(systemName: "handshake.fill")
                                        .foregroundStyle(.blue)
                                    Text(deal.title)
                                    Spacer()
                                    Text("\(Int(deal.percent))%").foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    if !matchedMaterials.isEmpty {
                        Section("Материалы (\(matchedMaterials.count))") {
                            ForEach(matchedMaterials.prefix(5)) { mat in
                                HStack {
                                    Image(systemName: mat.type.icon).foregroundStyle(.blue)
                                    Text(mat.displayTitle).lineLimit(1)
                                }
                            }
                        }
                    }

                    if !matchedMemos.isEmpty {
                        Section("Голосовые (\(matchedMemos.count))") {
                            ForEach(matchedMemos.prefix(5)) { memo in
                                HStack {
                                    Image(systemName: "waveform").foregroundStyle(.blue)
                                    VStack(alignment: .leading) {
                                        Text(memo.createdAt.relativeLabel).font(.body)
                                        Text(memo.transcription).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                            }
                        }
                    }
                }
                .adaptiveListStyle()
            }
        }
        .navigationTitle("Поиск")
        .searchable(text: $searchText, prompt: "Поиск по всему приложению")
    }

    // MARK: - Result rows

    private func taskResult(_ task: TaskItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: task.status == .done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(task.status == .done ? .green : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.body)
                    .fontWeight(.medium)
                    .strikethrough(task.status == .done)

                if !task.notes.isEmpty {
                    Text(task.notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if !task.tags.isEmpty {
                    Text(task.tags.map { "#\($0)" }.joined(separator: " "))
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
            }
        }
    }

    private func noteResult(_ note: QuickNote) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if !note.title.isEmpty {
                Text(note.title).font(.body).fontWeight(.semibold)
            }
            Text(note.body)
                .font(.body)
                .lineLimit(2)
                .foregroundStyle(note.title.isEmpty ? .primary : .secondary)
        }
    }

    // MARK: - Empty states

    private var searchTips: some View {
        VStack(spacing: 20) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
                .padding(.top, 60)

            Text("Поиск по всему")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 8) {
                tipRow(icon: "checkmark.circle", text: "Задачи — по названию, заметкам, тегам")
                tipRow(icon: "note.text", text: "Заметки — по тексту и тегам")
                tipRow(icon: "person.2", text: "Люди — по имени, компании, роли")
                tipRow(icon: "handshake", text: "Договорённости — по названию")
                tipRow(icon: "waveform", text: "Голосовые — по транскрипции")
            }
            .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tipRow(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.blue)
                .frame(width: 20)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var noResults: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .padding(.top, 60)
            Text("Ничего не найдено")
                .font(.title3)
                .fontWeight(.semibold)
            Text("Попробуйте другой запрос")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
