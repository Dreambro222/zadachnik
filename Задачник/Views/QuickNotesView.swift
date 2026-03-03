import SwiftUI
import SwiftData

struct QuickNotesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \QuickNote.createdAt, order: .reverse) private var notes: [QuickNote]

    @State private var showCapture = false
    @State private var editingNote: QuickNote? = nil
    @State private var showNewNote = false
    @State private var convertingNote: QuickNote?
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var selectedTag: String? = nil
    @State private var selectedNoteID: UUID? = nil
    @State private var creatingNewInlineNote = false
    @State private var cachedTags: [String] = []

    private var allTags: [String] {
        cachedTags
    }

    private var filteredNotes: [QuickNote] {
        let query = debouncedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = notes.filter { note in
            let matchesSearch = query.isEmpty
                || note.body.localizedCaseInsensitiveContains(query)
                || note.title.localizedCaseInsensitiveContains(query)
                || note.tags.contains { $0.localizedCaseInsensitiveContains(query) }
            let matchesTag = selectedTag == nil || note.tags.contains(selectedTag!)
            return matchesSearch && matchesTag
        }

        // `notes` already come sorted by createdAt desc from @Query.
        // Keep that order and do a linear partition by pin flag.
        var pinned: [QuickNote] = []
        var regular: [QuickNote] = []
        pinned.reserveCapacity(filtered.count)
        regular.reserveCapacity(filtered.count)
        for note in filtered {
            if note.isPinned {
                pinned.append(note)
            } else {
                regular.append(note)
            }
        }
        return pinned + regular
    }

    private var selectedNote: QuickNote? {
        guard let selectedNoteID else { return nil }
        return notes.first { $0.id == selectedNoteID }
    }

    var body: some View {
        Group {
            if notes.isEmpty && !creatingNewInlineNote {
                QuickNotesEmptyState(
                    onCreate: { startCreatingNote() },
                    onQuickCapture: { showCapture = true }
                )
            } else {
                notesContent
            }
        }
        .navigationTitle("Заметки")
#if !os(macOS)
        .toolbar {
            ToolbarItem(id: "notes.back", placement: .navigation) {
                Button {
                    closeInlineEditor()
                } label: {
                    Label("К списку", systemImage: "chevron.left")
                }
                .disabled(!showingInlineEditor)
                .opacity(showingInlineEditor ? 1 : 0)
                .accessibilityHint("Закрывает редактор и возвращает к списку заметок")
            }
            ToolbarItem(id: "notes.add", placement: .primaryAction) {
                Button {
                    startCreatingNote()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Новая заметка")
                .accessibilityHint("Открывает создание заметки")
            }
            ToolbarItem(id: "notes.menu", placement: .secondaryAction) {
                Menu {
                    Button {
                        showCapture = true
                    } label: {
                        Label("Быстрая запись", systemImage: "bolt.fill")
                    }

                    if let note = selectedNote {
                        Button {
                            openNote(note)
                        } label: {
                            Label("Редактировать", systemImage: "pencil")
                        }

                        Button {
                            convertingNote = note
                        } label: {
                            Label("В задачу", systemImage: "checkmark.circle")
                        }

                        Button {
                            togglePin(note)
                        } label: {
                            Label(note.isPinned ? "Открепить" : "Закрепить", systemImage: note.isPinned ? "pin.slash" : "pin")
                        }

                        Divider()

                        Button(role: .destructive) {
                            deleteNote(note)
                        } label: {
                            Label("Удалить", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Меню заметок")
            }
        }
#endif
        .sheet(isPresented: $showCapture) {
            QuickCaptureView()
        }
#if !os(macOS)
        .sheet(isPresented: $showNewNote) {
            NoteEditView()
        }
        .sheet(item: $editingNote) { note in
            NoteEditView(note: note)
        }
#endif
        .sheet(item: $convertingNote) { note in
            TaskDetailView(task: nil, project: nil)
                .onDisappear {
                    note.convertedToTask = true
                    try? modelContext.save()
                }
        }
        .onAppear {
            debouncedSearchText = searchText
            refreshTagsCache()
            ensureValidSelection()
        }
        .onChange(of: searchText) { _, newValue in
            searchDebounceTask?.cancel()
            searchDebounceTask = Task {
                try? await Task.sleep(for: .milliseconds(280))
                if Task.isCancelled { return }
                await MainActor.run {
                    debouncedSearchText = newValue
                }
            }
        }
        .onChange(of: notes.map(\.id)) { _, _ in
            refreshTagsCache()
            ensureValidSelection()
        }
        .onChange(of: notes.map { "\($0.id.uuidString)|\($0.tags.joined(separator: "\u{1F}"))" }) { _, _ in
            refreshTagsCache()
        }
        .onChange(of: filteredNotes.map(\.id)) { _, _ in
            ensureValidSelection()
        }
    }

    @ViewBuilder
    private var notesContent: some View {
#if os(macOS)
        Group {
            if showingInlineEditor {
                noteDetailPane
            } else {
                VStack(spacing: 0) {
                    if !allTags.isEmpty {
                        TagFilterBar(availableTags: allTags, selectedTag: $selectedTag)
                        Divider()
                    }

                    List {
                        ForEach(filteredNotes) { note in
                            Button {
                                openNote(note)
                            } label: {
                                QuickNoteListRow(note: note)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { rowContextMenu(note) }
                        }
                        .onDelete(perform: deleteNotes)
                    }
                    .adaptiveListStyle()
                    .searchable(text: $searchText, prompt: "Поиск по заметкам")
                }
            }
        }
#else
        VStack(spacing: 0) {
            if !allTags.isEmpty {
                TagFilterBar(availableTags: allTags, selectedTag: $selectedTag)
                Divider()
            }

            List {
                ForEach(filteredNotes) { note in
                    noteRow(note)
                }
                .onDelete(perform: deleteNotes)
            }
            .adaptiveListStyle()
            .searchable(text: $searchText, prompt: "Поиск по заметкам")
        }
#endif
    }

    private var noteDetailPane: some View {
        Group {
            if creatingNewInlineNote {
                NoteEditView(
                    note: nil,
                    embedded: true,
                    onClose: { creatingNewInlineNote = false },
                    onSaved: { saved in
                        creatingNewInlineNote = false
                        selectedNoteID = saved.id
                    }
                )
                .background(Color.secondaryGroupedBackground)
            } else if let note = selectedNote {
                NoteEditView(
                    note: note,
                    embedded: true,
                    onSaved: { saved in
                        selectedNoteID = saved.id
                    }
                )
                .background(Color.secondaryGroupedBackground)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "note.text")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("Выбери заметку")
                        .font(.title3.weight(.semibold))
                    Text("Выбери заметку в списке слева или создай новую")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.groupedBackground)
            }
        }
    }

    private func noteRow(_ note: QuickNote) -> some View {
        Button { editingNote = note } label: {
            QuickNoteListRow(note: note)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Открывает заметку для редактирования")
        .swipeActions(edge: .leading) {
            Button {
                togglePin(note)
            } label: {
                Label(note.isPinned ? "Открепить" : "Закрепить", systemImage: note.isPinned ? "pin.slash" : "pin")
            }
            .tint(.orange)

            Button { editingNote = note } label: {
                Label("Открыть", systemImage: "pencil")
            }
            .tint(.blue)

            Button { convertingNote = note } label: {
                Label("В задачу", systemImage: "checkmark.circle")
            }
            .tint(.indigo)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                modelContext.delete(note)
                try? modelContext.save()
            } label: {
                Label("Удалить", systemImage: "trash")
            }
        }
        .contextMenu { rowContextMenu(note) }
    }

    @ViewBuilder
    private func rowContextMenu(_ note: QuickNote) -> some View {
        Button {
            togglePin(note)
        } label: {
            Label(note.isPinned ? "Открепить" : "Закрепить", systemImage: note.isPinned ? "pin.slash" : "pin")
        }
        Button {
            openNote(note)
        } label: {
            Label("Редактировать", systemImage: "pencil")
        }
        ShareLink(item: shareText(note)) {
            Label("Поделиться", systemImage: "square.and.arrow.up")
        }
        Button { convertingNote = note } label: {
            Label("Создать задачу", systemImage: "checkmark.circle")
        }
        Divider()
        Button(role: .destructive) {
            deleteNote(note)
        } label: {
            Label("Удалить", systemImage: "trash")
        }
    }

    private func deleteNote(_ note: QuickNote) {
        if selectedNoteID == note.id {
            selectedNoteID = nil
        }
        modelContext.delete(note)
        try? modelContext.save()
        ensureValidSelection()
    }

    private func togglePin(_ note: QuickNote) {
        note.isPinned.toggle()
        try? modelContext.save()
        ensureValidSelection()
    }

    private func ensureValidSelection() {
#if os(macOS)
        guard let currentSelectedNoteID = selectedNoteID else { return }
        let stillExists = filteredNotes.contains(where: { $0.id == currentSelectedNoteID })
        if !stillExists {
            selectedNoteID = nil
        }
#endif
    }

    private var showingInlineEditor: Bool {
#if os(macOS)
        return creatingNewInlineNote || selectedNote != nil
#else
        return false
#endif
    }

    private func startCreatingNote() {
#if os(macOS)
        creatingNewInlineNote = true
        selectedNoteID = nil
#else
        showNewNote = true
#endif
    }

    private func openNote(_ note: QuickNote) {
#if os(macOS)
        creatingNewInlineNote = false
        selectedNoteID = note.id
#else
        editingNote = note
#endif
    }

    private func closeInlineEditor() {
#if os(macOS)
        creatingNewInlineNote = false
        selectedNoteID = nil
#endif
    }

    private func refreshTagsCache() {
        cachedTags = Array(Set(notes.flatMap { $0.tags })).sorted()
    }

    private func shareText(_ note: QuickNote) -> String {
        let body = NoteRichTextCodec.plainText(from: note.body)
        return [note.title, body].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private func deleteNotes(at offsets: IndexSet) {
        for index in offsets {
            deleteNote(filteredNotes[index])
        }
    }
}

private struct QuickNoteListRow: View {
    let note: QuickNote

    private var plainBody: String {
        NoteRichTextCodec.plainText(from: note.body)
    }

    private var titleText: String {
        let trimmedTitle = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }
        let fallback = plainBody.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? "Без названия" : fallback
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(titleText)
                    .font(.headline)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if note.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                Text(note.createdAt.relativeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if note.body.hasPrefix("[") {
                RichTextPreview(raw: note.body, lineLimit: 2, font: .subheadline)
                    .foregroundStyle(.secondary)
            } else if !plainBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(plainBody)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 6) {
                if note.convertedToTask {
                    Label("В задачи", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }

                if let firstTag = note.tags.first {
                    Text("#\(firstTag)")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                    if note.tags.count > 1 {
                        Text("+\(note.tags.count - 1)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct QuickNotesEmptyState: View {
    let onCreate: () -> Void
    let onQuickCapture: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "note.text.badge.plus")
                .font(.system(size: 56))
                .foregroundStyle(.blue.gradient)

            Text("Нет заметок")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Создай первую заметку или добавь мысль через быструю запись")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            HStack(spacing: 10) {
                Button(action: onCreate) {
                    Label("Новая заметка", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Создает новую заметку")

                Button(action: onQuickCapture) {
                    Label("Быстрая запись", systemImage: "bolt.fill")
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Открывает быстрый ввод для заметки или задачи")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
