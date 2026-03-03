import SwiftUI
import SwiftData

struct PersonDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var person: Person

    @State private var showEdit = false
    @State private var showAddInteraction = false
    @State private var showIntroducedBy: Person? = nil
    @State private var showAddTask = false
    @State private var showAddDeal = false
    @State private var showAttachFile = false
    @State private var selectedTab = 0  // 0=Задачи, 1=Сделки, 2=Медиа, 3=Конфликты, 4=История

    // Temporary safety fallback: relationship traversal via introducer can crash
    // when stale references exist in local store. Keep UI stable while data repair
    // path is prepared.
    private var theyIntroduced: [Person] { [] }

    private var personTasks: [TaskItem] {
        let id = person.id
        let descriptor = FetchDescriptor<TaskItem>(
            predicate: #Predicate<TaskItem> { task in
                task.linkedPersonId == id && task.statusRaw != "Готово"
            },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private var personDeals: [Deal] {
        let id = person.id
        let descriptor = FetchDescriptor<Deal>(
            predicate: #Predicate<Deal> { deal in deal.personId == id },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private var conflictInteractions: [Interaction] {
        person.sortedInteractions.filter { $0.type.isConflict }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerPanel

            // Tab bar
            Picker("", selection: $selectedTab) {
                Text(personTasks.isEmpty ? "Задачи" : "Задачи (\(personTasks.count))").tag(0)
                Text(personDeals.isEmpty ? "Сделки" : "Сделки (\(personDeals.count))").tag(1)
                Text("Медиа").tag(2)
                Text("Конфликты").tag(3)
                Text("История").tag(4)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            // Tab content takes all remaining space.
            tabContentPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.groupedBackground)
        .navigationTitle(person.name)
        .navigationInline()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Редактировать") { showEdit = true }
            }
            ToolbarItem {
                Menu {
                    Button { showAddInteraction = true } label: {
                        Label("Добавить встречу", systemImage: "plus.circle")
                    }
                    Button { showAddTask = true } label: {
                        Label("Добавить задачу", systemImage: "checkmark.circle")
                    }
                } label: {
                    Image(systemName: "plus.circle")
                }
            }
        }
        .sheet(isPresented: $showEdit) {
            AddPersonView(editingPerson: person)
        }
        .sheet(isPresented: $showAddInteraction) {
            AddInteractionView(person: person)
        }
        .sheet(item: $showIntroducedBy) { p in
            NavigationStack { PersonDetailView(person: p) }
        }
        .sheet(isPresented: $showAddTask) {
            TaskDetailView(task: nil, project: nil)
                .onDisappear {
                    // Link the last created task to this person
                    let descriptor = FetchDescriptor<TaskItem>(
                        predicate: #Predicate<TaskItem> { $0.linkedPersonId == nil },
                        sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
                    )
                    if let last = (try? modelContext.fetch(descriptor))?.first {
                        last.linkedPersonId = person.id
                        try? modelContext.save()
                    }
                }
        }
        .sheet(isPresented: $showAddDeal) {
            DealDetailView(deal: nil, initialPersonId: person.id)
        }
        .sheet(isPresented: $showAttachFile) {
            PersonFilePicker(person: person)
        }
    }

    private var headerPanel: some View {
        ScrollView {
            VStack(spacing: 12) {
                profileHeader
                quickActionsStrip

                // Always-visible info strip (contacts, notes, introducer)
                if !person.email.isEmpty || !person.phone.isEmpty || !person.telegramUsername.isEmpty
                    || person.source != .other || !person.meetingPlace.isEmpty
                    || !person.notes.isEmpty {
                    VStack(spacing: 10) {
                        if !person.email.isEmpty || !person.phone.isEmpty || !person.telegramUsername.isEmpty
                            || person.source != .other || !person.meetingPlace.isEmpty {
                            contactSection
                        }
                        if !person.notes.isEmpty { notesSection }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
                }
            }
        }
        .frame(minHeight: 220, maxHeight: 340)
    }

    private var quickActionsStrip: some View {
        HStack(spacing: 10) {
            quickActionButton(title: "Сделка", icon: "handshake", tint: .orange) {
                showAddDeal = true
            }
            quickActionButton(title: "Медиа", icon: "photo.on.rectangle", tint: .blue) {
                selectedTab = 2
            }
            quickActionButton(title: "Файл", icon: "paperclip", tint: .purple) {
                showAttachFile = true
            }
            quickActionButton(title: "Задача", icon: "checkmark.circle", tint: .green) {
                showAddTask = true
            }
        }
        .padding(.horizontal, 16)
    }

    private func quickActionButton(title: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
                    .fontWeight(.semibold)
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var tabContentPanel: some View {
        switch selectedTab {
        case 0:
            ScrollView {
                VStack(spacing: 16) { tasksTab }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 40)
            }
        case 1:
            ScrollView {
                VStack(spacing: 16) { dealsTab }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 40)
            }
        case 2:
            filesTab
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
        case 3:
            ScrollView {
                VStack(spacing: 16) { conflictsTab }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 40)
            }
        default:
            ScrollView {
                VStack(spacing: 16) { historyTab }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 40)
            }
        }
    }

    // MARK: - Header

    private var profileHeader: some View {
        VStack(spacing: 12) {
            PersonAvatarView(person: person, size: 80)
                .shadow(color: Color(hex: person.colorHex).opacity(0.4), radius: 12)

            VStack(spacing: 4) {
                Text(person.name)
                    .font(.title2)
                    .fontWeight(.bold)

                if !person.displayRole.isEmpty {
                    Text(person.displayRole)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if !person.categoryTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(person.categoryTags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(Color(hex: person.colorHex))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    Color(hex: person.colorHex).opacity(0.12),
                                    in: Capsule()
                                )
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            // Quick stats
            HStack(spacing: 0) {
                statBadge(
                    value: "\(person.interactions.count)",
                    label: "встреч"
                )
                Divider().frame(height: 32)
                statBadge(
                    value: theyIntroduced.isEmpty ? "—" : "\(theyIntroduced.count)",
                    label: "познакомил"
                )
                Divider().frame(height: 32)
                statBadge(
                    value: person.lastInteraction.map { $0.date.shortLabel } ?? "—",
                    label: "последний раз"
                )
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 16)

            // Birthday banner
            if let days = person.daysUntilBirthday {
                birthdayBanner(days: days)
                    .padding(.horizontal, 16)
            }

        }
        .padding(.top, 16)
    }

    private func birthdayBanner(days: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: days == 0 ? "gift.fill" : "gift")
                .font(.title2)
                .foregroundStyle(days == 0 ? .pink : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(days == 0
                     ? "Сегодня день рождения!"
                     : days == 1 ? "Завтра день рождения"
                     : "День рождения через \(days) дн.")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                if let bd = person.birthday {
                    HStack(spacing: 4) {
                        Text(bd.formatted(.dateTime.day().month(.wide)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let age = person.ageString {
                            Text("· \(age)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            (days == 0 ? Color.pink : days <= 3 ? Color.orange : Color.blue).opacity(0.12),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    (days == 0 ? Color.pink : days <= 3 ? Color.orange : Color.blue).opacity(0.25),
                    lineWidth: 1
                )
        )
    }

    private func statBadge(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3)
                .fontWeight(.bold)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    // MARK: - Contact

    private var contactSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if !person.email.isEmpty {
                    contactRow(icon: "envelope.fill", text: person.email, color: .orange)
                }
                if !person.phone.isEmpty {
                    contactRow(icon: "phone.fill", text: person.phone, color: .green)
                }
                if !person.telegramUsername.isEmpty {
                    Button {
                        let username = person.telegramUsername.trimmingCharacters(in: .init(charactersIn: "@"))
                        if let url = URL(string: "https://t.me/\(username)") {
                            #if os(macOS)
                            NSWorkspace.shared.open(url)
                            #else
                            UIApplication.shared.open(url)
                            #endif
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "paperplane.fill")
                                .foregroundStyle(Color(red: 0.15, green: 0.56, blue: 0.88))
                                .frame(width: 20)
                            Text("@\(person.telegramUsername)")
                                .font(.body)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }

                // Source & meeting place
                if person.source != .other || !person.meetingPlace.isEmpty {
                    Divider()
                    HStack(spacing: 10) {
                        Image(systemName: person.source.icon)
                            .foregroundStyle(.purple)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            if person.source != .other {
                                Text(person.source.label)
                                    .font(.body)
                            }
                            if !person.meetingPlace.isEmpty {
                                Text(person.meetingPlace)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                }

                // Birthday
                if let bd = person.birthday {
                    Divider()
                    HStack(spacing: 10) {
                        Image(systemName: "gift.fill")
                            .font(.body)
                            .foregroundStyle(.pink)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(bd.formatted(.dateTime.day().month(.wide)))
                                .font(.body)
                            if let age = person.ageString {
                                Text(age)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if let days = person.daysUntilBirthday, days <= 30 {
                            Text(days == 0 ? "Сегодня 🎉"
                                 : days == 1 ? "Завтра"
                                 : "через \(days) дн.")
                                .font(.caption)
                                .foregroundStyle(days <= 3 ? .pink : .secondary)
                                .fontWeight(days <= 3 ? .semibold : .regular)
                        }
                    }
                }

            }
        } label: {
            Label("Контакты", systemImage: "person.crop.circle")
                .font(.subheadline)
                .fontWeight(.semibold)
        }
    }

    private func contactRow(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 20)
            Text(text)
                .font(.body)
            Spacer()
        }
    }

    // MARK: - Notes

    private var notesSection: some View {
        GroupBox {
            RichTextPreview(raw: person.notes, lineLimit: 12, font: .body)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Заметки", systemImage: "note.text")
                .font(.subheadline)
                .fontWeight(.semibold)
        }
    }

    // MARK: - Tab content

    private var historyTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            interactionsSection(interactions: person.sortedInteractions.filter { !$0.type.isConflict })
        }
    }

    private var tasksTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            if personTasks.isEmpty {
                Text("Нет связанных задач")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 16)
                    .frame(maxWidth: .infinity)

                Button { showAddTask = true } label: {
                    Label("Создать задачу", systemImage: "plus.circle")
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
            } else {
                ForEach(personTasks) { task in
                    TaskCard(task: task, showProject: true, linkedPerson: person)
                }
            }
        }
        .padding(.top, 8)
    }

    private var dealsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            if personDeals.isEmpty {
                Text("Нет договорённостей")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 16)
                    .frame(maxWidth: .infinity)

                Button { showAddDeal = true } label: {
                    Label("Создать сделку", systemImage: "plus.circle")
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
            } else {
                ForEach(personDeals) { deal in
                    DealRowView(deal: deal, person: person)
                }
            }
        }
        .padding(.top, 8)
    }

    private var conflictsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            if conflictInteractions.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.green.gradient)
                        .padding(.top, 24)
                    Text("Конфликтов нет")
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text("Здесь появятся недопонимания и конфликты")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            } else {
                interactionsSection(interactions: conflictInteractions)
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Media tab

    private var filesTab: some View {
        PersonMediaView(person: person)
    }

    // MARK: - Interactions

    private func interactionsSection(interactions: [Interaction]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("История", systemImage: "clock.arrow.circlepath")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Button {
                    showAddInteraction = true
                } label: {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(Color.accentColor)
                }
            }

            if interactions.isEmpty {
                Text("Нет записей.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(interactions) { interaction in
                    InteractionRowView(interaction: interaction, person: person)
                        .contextMenu {
                            Button(role: .destructive) {
                                modelContext.delete(interaction)
                                try? modelContext.save()
                            } label: {
                                Label("Удалить", systemImage: "trash")
                            }
                        }
                }
            }
        }
    }
}

// MARK: - Interaction Row

struct InteractionRowView: View {
    @Bindable var interaction: Interaction
    let person: Person

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.modelContext) private var modelContext
    @StateObject private var recorder = VoiceRecorderService.shared
    @State private var isPlaying = false
    @State private var isTranscribing = false
    @State private var showTranscription = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Timeline dot + line
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(interaction.type.color.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: interaction.type.icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(interaction.type.color)
                }
                Rectangle()
                    .fill(.separator)
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 36)

            VStack(alignment: .leading, spacing: 6) {
                // Header
                HStack {
                    Text(interaction.type.label)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    Text(interaction.date.relativeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !interaction.notes.isEmpty {
                    Text(interaction.notes)
                        .font(.body)
                        .foregroundStyle(.primary)
                }

                if !interaction.result.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                        Text(interaction.result)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.green)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }

                // Audio panel (if recording attached)
                if interaction.audioFileName != nil {
                    audioPanelView
                }
            }
            .padding(.bottom, 16)
        }
    }

    // MARK: - Audio panel

    private var audioPanelView: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Playback + transcription controls
            HStack(spacing: 8) {
                // Play button
                Button {
                    togglePlayback()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                            .foregroundStyle(isPlaying ? .red : .blue)
                        Text(isPlaying ? "Стоп" : "Слушать")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(isPlaying ? .red : .blue)

                // Transcribe button
                if interaction.transcription.isEmpty {
                    Button {
                        transcribeAudio()
                    } label: {
                        if isTranscribing {
                            HStack(spacing: 4) {
                                ProgressView().scaleEffect(0.65)
                                Text("Транскрибирую...")
                                    .font(.caption)
                            }
                        } else {
                            Label("Транскрибировать", systemImage: "waveform")
                                .font(.caption)
                                .fontWeight(.semibold)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(.purple)
                    .disabled(isTranscribing)
                } else {
                    // Show/hide transcription toggle
                    Button {
                        if reduceMotion {
                            showTranscription.toggle()
                        } else {
                            withAnimation(.spring(duration: 0.2)) { showTranscription.toggle() }
                        }
                    } label: {
                        Label(showTranscription ? "Скрыть" : "Текст", systemImage: showTranscription ? "chevron.up" : "text.alignleft")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)

                    // AI summary button
                    SummarizeButton(
                        transcript: interaction.transcription,
                        person: person,
                        interaction: interaction
                    )
                }
            }

            // Transcription text
            if showTranscription && !interaction.transcription.isEmpty {
                Text(interaction.transcription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Actions

    private func togglePlayback() {
        guard let url = interaction.audioFileURL else { return }
        if isPlaying {
            recorder.stopPlayback()
            isPlaying = false
        } else {
            do {
                try recorder.play(url: url) { isPlaying = false }
                isPlaying = true
            } catch {
                NSLog("[InteractionRow] Playback error: \(error)")
            }
        }
    }

    private func transcribeAudio() {
        guard let url = interaction.audioFileURL else { return }
        isTranscribing = true
        Task {
            let result = await WhisperService.shared.transcribe(url: url)
            interaction.transcription = result.text
            try? modelContext.save()
            isTranscribing = false
            if !result.text.isEmpty { showTranscription = true }
        }
    }
}
