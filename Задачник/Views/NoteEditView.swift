import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

struct NoteEditView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @StateObject private var cal = CalendarService.shared

    var note: QuickNote?
    var embedded: Bool = false
    var onClose: (() -> Void)? = nil
    var onSaved: ((QuickNote) -> Void)? = nil

    @State private var title = ""
    @State private var bodyRaw = ""
    @State private var tags: [String] = []
    @State private var hasDeadline = false
    @State private var deadline = Date()
    @State private var deadlineIncludesTime = false
    @State private var addToCalendar = false
    @State private var showDeadlinePicker = false
    @State private var calendarSyncStatus: NoteCalendarSyncStatus = .idle
    @FocusState private var titleFocused: Bool
    @State private var autoSaveWorkItem: DispatchWorkItem?
    @State private var didInitialLoad = false

    private var isEditing: Bool { note != nil }

    enum NoteCalendarSyncStatus {
        case idle, syncing, synced, error(String)
    }

    var body: some View {
        Group {
            if embedded {
                editorContent
            } else {
                NavigationStack {
                    editorContent
                }
            }
        }
    }

    private var editorContent: some View {
        VStack(spacing: 0) {
            noteDeadlineHeader
            Divider()

            // Title
            TextField("Заголовок", text: $title)
                .font(.title2.weight(.bold))
                .focused($titleFocused)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()

            // Rich text body
            VStack(alignment: .leading, spacing: 12) {
#if os(macOS)
                noteMiniToolbar
                    .padding(.horizontal, 16)
#endif
                // Note body editor is self-scrollable on macOS.
                // Wrapping it in an outer ScrollView collapses its height.
                NoteContentEditor(raw: $bodyRaw, placeholder: "Начните писать...", minHeight: 300)
                    .padding(.horizontal, 16)

                // Tags
                VStack(alignment: .leading, spacing: 6) {
                    Text("Теги")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                    TagInputView(tags: $tags)
                        .padding(.horizontal, 16)
                }
                .padding(.top, 4)
                .padding(.bottom, 16)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationTitle(isEditing ? "Заметка" : "Новая заметка")
        .navigationInline()
        .toolbar {
            if !embedded || onClose != nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button(embedded ? "Закрыть" : "Отмена") {
                        closeEditor()
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isEditing ? "Сохранить" : "Создать") { save() }
                    .fontWeight(.semibold)
                    .disabled(title.isEmpty && NoteRichTextCodec.plainText(from: bodyRaw).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
#if os(macOS)
            ToolbarItem(placement: .automatic) {
                Menu {
                    Button("Жирный") { NoteTextView.send(.bold) }
                        .keyboardShortcut("b", modifiers: [.command])
                    Button("Курсив") { NoteTextView.send(.italic) }
                        .keyboardShortcut("i", modifiers: [.command])
                    Button("Подчеркнутый") { NoteTextView.send(.underline) }
                        .keyboardShortcut("u", modifiers: [.command])
                    Divider()
                    Button("Добавить ссылку") { NoteTextView.send(.addLink) }
                        .keyboardShortcut("k", modifiers: [.command])
                    Button("Убрать ссылку") { NoteTextView.send(.removeLink) }
                    Divider()
                    Button("Заголовок") { NoteTextView.send(.heading) }
                        .keyboardShortcut("h", modifiers: [.command, .shift])
                    Button("Подзаголовок") { NoteTextView.send(.subheading) }
                        .keyboardShortcut("j", modifiers: [.command, .shift])
                    Button("Титул") { NoteTextView.send(.title) }
                        .keyboardShortcut("t", modifiers: [.command, .shift])
                    Button("Обычный текст") { NoteTextView.send(.body) }
                        .keyboardShortcut("b", modifiers: [.command, .shift])
                    Divider()
                    Button("Маркированный список") { NoteTextView.send(.bullet) }
                        .keyboardShortcut("7", modifiers: [.command, .shift])
                    Button("Список с тире") { NoteTextView.send(.dashed) }
                        .keyboardShortcut("8", modifiers: [.command, .shift])
                    Button("Нумерованный список") { NoteTextView.send(.numbered) }
                        .keyboardShortcut("9", modifiers: [.command, .shift])
                    Button("Чеклист") { NoteTextView.send(.checklist) }
                        .keyboardShortcut("l", modifiers: [.command, .shift])
                } label: {
                    Image(systemName: "textformat")
                }
                .help("Формат")
            }
#endif
            if isEditing {
                ToolbarItem(placement: .destructiveAction) {
                    Button(role: .destructive) { deleteNote() } label: {
                        Image(systemName: "trash")
                    }
                }
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
#if os(macOS)
        .onExitCommand {
            closeEditor()
        }
#endif
    }

#if os(macOS)
    private var noteMiniToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                miniToolbarButton("title", command: .title)
                miniToolbarButton("h.square", command: .heading)
                miniToolbarButton("text.alignleft", command: .body)
                Divider().frame(height: 16)
                miniToolbarButton("bold", command: .bold)
                miniToolbarButton("italic", command: .italic)
                miniToolbarButton("underline", command: .underline)
                miniToolbarButton("strikethrough", command: .strikethrough)
                Divider().frame(height: 16)
                miniToolbarButton("list.bullet", command: .bullet)
                miniToolbarButton("list.number", command: .numbered)
                miniToolbarButton("checklist", command: .checklist)
                miniToolbarButton("link", command: .addLink)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func miniToolbarButton(_ icon: String, command: NoteEditorCommand) -> some View {
        Button {
            NoteTextView.send(command)
        } label: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 24)
        }
        .buttonStyle(.plain)
    }
#endif

    private func loadValues() {
        if let n = note {
            title = n.title
            bodyRaw = n.body
            tags = n.tags
            hasDeadline = n.deadline != nil
            deadline = n.deadline ?? Date()
            deadlineIncludesTime = n.deadlineIncludesTime
            addToCalendar = !n.calendarEventId.isEmpty
        } else {
            titleFocused = true
        }
    }

    private func save() {
        let trimTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = NoteRichTextCodec.plainText(from: bodyRaw)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let savedNote: QuickNote
        if let n = note {
            n.title = trimTitle
            n.body = bodyRaw
            n.tags = tags
            n.deadline = hasDeadline ? deadline : nil
            n.deadlineIncludesTime = hasDeadline && deadlineIncludesTime
            savedNote = n
        } else {
            let newNote = QuickNote(
                body: bodyRaw.isEmpty ? (trimmedBody.isEmpty ? trimTitle : trimmedBody) : bodyRaw,
                title: trimTitle,
                tags: tags
            )
            newNote.deadline = hasDeadline ? deadline : nil
            newNote.deadlineIncludesTime = hasDeadline && deadlineIncludesTime
            modelContext.insert(newNote)
            savedNote = newNote
        }
        try? modelContext.save()

        // Calendar sync behavior mirrors tasks/projects: sync on save when enabled.
        if addToCalendar && hasDeadline {
            let eventTitle = "📝 \(trimTitle.isEmpty ? "Заметка" : trimTitle)"
            let eventNotes = NoteRichTextCodec.plainText(from: bodyRaw)
            let noteRef = savedNote
            let eventDate = deadline
            let allDay = !deadlineIncludesTime
            Task {
                do {
                    if !cal.isAuthorized { _ = await cal.requestAccess() }
                    let eventId = try await cal.createOrUpdateEvent(
                        title: eventTitle,
                        startDate: eventDate,
                        notes: eventNotes,
                        existingEventId: noteRef.calendarEventId,
                        isAllDay: allDay
                    )
                    await MainActor.run {
                        noteRef.calendarEventId = eventId
                        try? modelContext.save()
                        calendarSyncStatus = .synced
                    }
                } catch {
                    await MainActor.run {
                        calendarSyncStatus = .error(error.localizedDescription)
                    }
                }
            }
        } else if !savedNote.calendarEventId.isEmpty {
            cal.deleteEvent(eventId: savedNote.calendarEventId)
            savedNote.calendarEventId = ""
            try? modelContext.save()
        }

        onSaved?(savedNote)
        if !embedded {
            dismiss()
        }
    }

    private var autoSaveKey: String {
        let due = hasDeadline ? "\(deadline.timeIntervalSince1970)" : "nil"
        return [title, bodyRaw, tags.joined(separator: ","), "\(hasDeadline)", due, "\(deadlineIncludesTime)", "\(addToCalendar)"]
            .joined(separator: "§")
    }

    private func scheduleAutoSaveIfNeeded() {
        guard didInitialLoad, note != nil else { return }
        autoSaveWorkItem?.cancel()
        let work = DispatchWorkItem { autoSaveNowIfNeeded() }
        autoSaveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    private func autoSaveNowIfNeeded() {
        guard didInitialLoad, let n = note else { return }
        n.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        n.body = bodyRaw
        n.tags = tags
        n.deadline = hasDeadline ? deadline : nil
        n.deadlineIncludesTime = hasDeadline && deadlineIncludesTime
        try? modelContext.save()
        onSaved?(n)
    }

    private func deleteNote() {
        if let n = note {
            modelContext.delete(n)
            try? modelContext.save()
        }
        closeEditor()
    }

    private func closeEditor() {
        if embedded {
            onClose?()
        } else {
            dismiss()
        }
    }

    // MARK: - Deadline + Calendar

    private var noteDeadlineHeader: some View {
        HStack(spacing: 12) {
            Button {
                showDeadlinePicker.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: hasDeadline ? "calendar.badge.clock" : "calendar.badge.plus")
                        .foregroundStyle(hasDeadline ? noteDeadlineColor : .secondary)
                        .font(.system(size: 16, weight: .medium))

                    if hasDeadline {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Дедлайн")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(deadline.formatted(date: .abbreviated, time: deadlineIncludesTime ? .shortened : .omitted))
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(noteDeadlineColor)
                        }
                    } else {
                        Text("Установить дедлайн")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(noteDeadlineBackground, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showDeadlinePicker) {
                noteDeadlinePopover
            }

            Spacer()

            if hasDeadline {
                noteDaysLeftBadge(due: deadline)
            }

            if hasDeadline, isEditing {
                Button {
                    Task { await syncNoteToCalendar() }
                } label: {
                    Group {
                        if case .syncing = calendarSyncStatus {
                            ProgressView().controlSize(.small)
                        } else if case .synced = calendarSyncStatus {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Image(systemName: "calendar.badge.plus").foregroundStyle(.blue)
                        }
                    }
                    .font(.system(size: 16))
                    .frame(width: 32, height: 32)
                    .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help("Синхронизировать в Календарь")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.groupedBackground)
    }

    private var noteDeadlinePopover: some View {
        VStack(spacing: 10) {
            Text("Дедлайн заметки")
                .font(.headline)
                .padding(.top, 12)

            DatePicker(
                "",
                selection: $deadline,
                displayedComponents: deadlineIncludesTime ? [.date, .hourAndMinute] : [.date]
            )
            .datePickerStyle(.graphical)
            .padding(.horizontal, 12)
            .onChange(of: deadline) { _, _ in hasDeadline = true }

            Toggle("Указать время", isOn: $deadlineIncludesTime)
                .padding(.horizontal, 16)
                .tint(.blue)

            Toggle("Добавить в Календарь при сохранении", isOn: $addToCalendar)
                .padding(.horizontal, 16)
                .tint(.green)

            if addToCalendar && cal.isAuthorized && !cal.availableCalendars.isEmpty {
                Menu {
                    ForEach(cal.availableCalendars, id: \.calendarIdentifier) { calendar in
                        Button {
                            cal.selectCalendar(calendar)
                        } label: {
                            HStack {
                                Text(calendar.title)
                                if calendar.calendarIdentifier == cal.selectedCalendarId {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if let selected = cal.selectedCalendar {
                            Circle()
                                .fill(Color(cgColor: selected.cgColor))
                                .frame(width: 8, height: 8)
                            Text(selected.title)
                                .font(.subheadline)
                        } else {
                            Text("Выбрать календарь").font(.subheadline)
                        }
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.caption)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
            }

            if hasDeadline {
                Button {
                    hasDeadline = false
                    deadlineIncludesTime = false
                    addToCalendar = false
                } label: {
                    Label("Убрать дедлайн", systemImage: "xmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 8)
            }
        }
        .frame(width: 340)
    }

    private var noteDeadlineColor: Color {
        guard hasDeadline else { return .secondary }
        if deadline < Date() { return .red }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: deadline).day ?? 0
        return days <= 3 ? .orange : .blue
    }

    private var noteDeadlineBackground: some ShapeStyle {
        guard hasDeadline else { return AnyShapeStyle(Color.secondary.opacity(0.1)) }
        if deadline < Date() { return AnyShapeStyle(Color.red.opacity(0.12)) }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: deadline).day ?? 0
        return days <= 3
            ? AnyShapeStyle(Color.orange.opacity(0.12))
            : AnyShapeStyle(Color.blue.opacity(0.12))
    }

    private func noteDaysLeftBadge(due: Date) -> some View {
        let days = Calendar.current.dateComponents(
            [.day],
            from: Calendar.current.startOfDay(for: Date()),
            to: Calendar.current.startOfDay(for: due)
        ).day ?? 0
        let label: String
        let color: Color
        if days < 0 {
            label = "просрочено \(-days)д"
            color = .red
        } else if days == 0 {
            label = "сегодня"
            color = .orange
        } else if days == 1 {
            label = "завтра"
            color = .orange
        } else {
            label = "ещё \(days)д"
            color = .green
        }
        return Text(label)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func syncNoteToCalendar() async {
        guard let currentNote = note, hasDeadline else { return }
        calendarSyncStatus = .syncing
        if !cal.isAuthorized {
            let granted = await cal.requestAccess()
            guard granted else {
                calendarSyncStatus = .error("Нет доступа к Календарю")
                return
            }
        }
        do {
            let eventTitle = "📝 \(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Заметка" : title)"
            let eventNotes = NoteRichTextCodec.plainText(from: bodyRaw)
            let eventId = try await cal.createOrUpdateEvent(
                title: eventTitle,
                startDate: deadline,
                notes: eventNotes,
                existingEventId: currentNote.calendarEventId,
                isAllDay: !deadlineIncludesTime
            )
            currentNote.calendarEventId = eventId
            currentNote.deadline = deadline
            currentNote.deadlineIncludesTime = deadlineIncludesTime
            try? modelContext.save()
            calendarSyncStatus = .synced
        } catch {
            calendarSyncStatus = .error(error.localizedDescription)
        }
    }
}

enum NoteRichTextCodec {
    static let storagePrefix = "rtf64:"
    static let storagePrefixRTFD = "rtfd64:"

    static func plainText(from raw: String) -> String {
        if raw.hasPrefix(storagePrefixRTFD) {
            let encoded = String(raw.dropFirst(storagePrefixRTFD.count))
            if let data = Data(base64Encoded: encoded),
               let attr = try? NSAttributedString(
                    data: data,
                    options: [.documentType: NSAttributedString.DocumentType.rtfd],
                    documentAttributes: nil
               ) {
                return attr.string
            }
            return raw
        }
        if raw.hasPrefix(storagePrefix) {
            let encoded = String(raw.dropFirst(storagePrefix.count))
            if let data = Data(base64Encoded: encoded),
               let attr = try? NSAttributedString(
                    data: data,
                    options: [.documentType: NSAttributedString.DocumentType.rtf],
                    documentAttributes: nil
               ) {
                return attr.string
            }
            return raw
        }
        if raw.hasPrefix("[") {
            return RichText.plainText(RichText.parse(raw))
        }
        return raw
    }

#if os(macOS)
    static func attributedString(from raw: String) -> NSAttributedString? {
        if raw.hasPrefix(storagePrefixRTFD) {
            let encoded = String(raw.dropFirst(storagePrefixRTFD.count))
            guard let data = Data(base64Encoded: encoded) else { return nil }
            return try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtfd],
                documentAttributes: nil
            )
        }
        if raw.hasPrefix(storagePrefix) {
            let encoded = String(raw.dropFirst(storagePrefix.count))
            guard let data = Data(base64Encoded: encoded) else { return nil }
            return try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            )
        }
        let fallback = raw.hasPrefix("[") ? RichText.plainText(RichText.parse(raw)) : raw
        return NSAttributedString(
            string: fallback,
            attributes: [.font: NSFont.systemFont(ofSize: 17, weight: .regular)]
        )
    }

    static func encodeAttributed(_ attr: NSAttributedString) -> String {
        let range = NSRange(location: 0, length: attr.length)
        guard let data = try? attr.data(
            from: range,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        ) else {
            return attr.string
        }
        return storagePrefixRTFD + data.base64EncodedString()
    }
#endif
}

private struct NoteContentEditor: View {
    @Binding var raw: String
    let placeholder: String
    let minHeight: CGFloat

    var body: some View {
#if os(macOS)
        ZStack(alignment: .topLeading) {
            MacNoteRichTextEditor(raw: $raw, placeholder: placeholder, minHeight: minHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if NoteRichTextCodec.plainText(from: raw).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(placeholder)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, minHeight: max(220, minHeight), idealHeight: max(300, minHeight), alignment: .topLeading)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
#else
        RichTextEditor(raw: $raw, placeholder: placeholder, minHeight: minHeight)
#endif
    }
}

#if os(macOS)
private struct MacNoteRichTextEditor: NSViewRepresentable {
    @Binding var raw: String
    let placeholder: String
    let minHeight: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let textView = NoteTextView()
        textView.isRichText = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.importsGraphics = true
        textView.usesFindBar = true
        textView.isAutomaticLinkDetectionEnabled = true
        textView.registerForDraggedTypes([.fileURL, .tiff, .png, .string])
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = NSSize(width: 0, height: minHeight)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        let bodyFont = NSFont.systemFont(ofSize: 17, weight: .regular)
        textView.font = bodyFont
        textView.typingAttributes = [
            .font: bodyFont,
            .foregroundColor: NSColor.labelColor
        ]
        textView.onContentChanged = {
            context.coordinator.syncFromTextView(textView)
        }

        if let attr = NoteRichTextCodec.attributedString(from: raw) {
            textView.textStorage?.setAttributedString(normalizeTextColor(in: attr))
        }

        scroll.documentView = textView
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        textView.textColor = .textColor
        textView.insertionPointColor = .textColor
        let currentEncoded = NoteRichTextCodec.encodeAttributed(textView.attributedString())
        if currentEncoded != raw, let next = NoteRichTextCodec.attributedString(from: raw) {
            textView.textStorage?.setAttributedString(normalizeTextColor(in: next))
        }
    }

    private func normalizeTextColor(in attr: NSAttributedString) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: attr)
        let range = NSRange(location: 0, length: mutable.length)
        if range.length > 0 {
            mutable.enumerateAttribute(.link, in: range) { value, subrange, _ in
                if value != nil {
                    mutable.addAttribute(.foregroundColor, value: NSColor.linkColor, range: subrange)
                    mutable.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: subrange)
                } else {
                    mutable.addAttribute(.foregroundColor, value: NSColor.textColor, range: subrange)
                }
            }
        }
        return mutable
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacNoteRichTextEditor
        weak var textView: NoteTextView?

        init(parent: MacNoteRichTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            syncFromTextView(textView)
        }

        func syncFromTextView(_ textView: NSTextView) {
            let encoded = NoteRichTextCodec.encodeAttributed(textView.attributedString())
            if parent.raw != encoded {
                parent.raw = encoded
            }
        }
    }
}

private enum NoteEditorCommand {
    case title
    case heading
    case subheading
    case body
    case bold
    case italic
    case underline
    case strikethrough
    case addLink
    case removeLink
    case bullet
    case dashed
    case numbered
    case checklist
}

private final class NoteTextView: NSTextView {
    private static weak var focusedEditor: NoteTextView?
    private static var shortcutMonitor: Any?
    var onContentChanged: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            Self.focusedEditor = self
            Self.installShortcutMonitorIfNeeded()
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, Self.focusedEditor === self {
            Self.focusedEditor = nil
            Self.removeShortcutMonitorIfNeeded()
        }
        return resigned
    }

    deinit {
        if Self.focusedEditor === self {
            Self.focusedEditor = nil
            Self.removeShortcutMonitorIfNeeded()
        }
    }

    static func send(_ command: NoteEditorCommand) {
        focusedEditor?.run(command)
    }

    private static func installShortcutMonitorIfNeeded() {
        guard shortcutMonitor == nil else { return }
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            guard let editor = focusedEditor,
                  editor.window?.firstResponder === editor,
                  editor.window?.isKeyWindow == true else {
                return event
            }
            return editor.handleNotesShortcut(event) ? nil : event
        }
    }

    private static func removeShortcutMonitorIfNeeded() {
        guard focusedEditor == nil, let monitor = shortcutMonitor else { return }
        NSEvent.removeMonitor(monitor)
        shortcutMonitor = nil
    }

    override func didChangeText() {
        super.didChangeText()
        let range = NSRange(location: 0, length: textStorage?.length ?? 0)
        if range.length > 0, let storage = textStorage {
            storage.enumerateAttribute(.link, in: range) { value, subrange, _ in
                if value != nil {
                    storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: subrange)
                    storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: subrange)
                } else {
                    storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: subrange)
                }
            }
        }
        onContentChanged?()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if toggleChecklistAtClick(point: point) {
            return
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let styleMenu = NSMenu(title: "Стиль")
        styleMenu.addItem(makeActionItem("Жирный", action: #selector(applyBoldStyle), key: "b", modifiers: [.command]))
        styleMenu.addItem(makeActionItem("Курсив", action: #selector(applyItalicStyle), key: "i", modifiers: [.command]))
        styleMenu.addItem(makeActionItem("Подчеркнутый", action: #selector(applyUnderlineStyle), key: "u", modifiers: [.command]))
        styleMenu.addItem(makeActionItem("Зачеркнутый", action: #selector(applyStrikethroughStyle), key: "x", modifiers: [.command, .shift]))
        styleMenu.addItem(.separator())
        styleMenu.addItem(makeActionItem("Добавить ссылку", action: #selector(addLink), key: "k", modifiers: [.command]))
        styleMenu.addItem(makeActionItem("Убрать ссылку", action: #selector(removeLink), key: "K", modifiers: [.command, .shift]))
        styleMenu.addItem(.separator())
        styleMenu.addItem(makeActionItem("Заголовок", action: #selector(applyHeading), key: "h", modifiers: [.command, .shift]))
        styleMenu.addItem(makeActionItem("Подзаголовок", action: #selector(applySubheading), key: "j", modifiers: [.command, .shift]))
        styleMenu.addItem(makeActionItem("Титул", action: #selector(applyTitle), key: "t", modifiers: [.command, .shift]))
        styleMenu.addItem(makeActionItem("Обычный текст", action: #selector(applyBody), key: "b", modifiers: [.command, .shift]))
        styleMenu.addItem(.separator())
        styleMenu.addItem(makeActionItem("Маркированный список", action: #selector(applyBulletList), key: "7", modifiers: [.command, .shift]))
        styleMenu.addItem(makeActionItem("Список с тире", action: #selector(applyDashedList), key: "8", modifiers: [.command, .shift]))
        styleMenu.addItem(makeActionItem("Нумерованный список", action: #selector(applyNumberedList), key: "9", modifiers: [.command, .shift]))
        styleMenu.addItem(makeActionItem("Чеклист", action: #selector(applyChecklist), key: "l", modifiers: [.command, .shift]))

        let styleItem = NSMenuItem(title: "Формат", action: nil, keyEquivalent: "")
        styleItem.submenu = styleMenu
        menu.insertItem(styleItem, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleNotesShortcut(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // Tab / Shift+Tab: nested list indentation
        if event.keyCode == 48 {
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if mods.contains(.shift) {
                outdentSelectedLines()
            } else {
                indentSelectedLines()
            }
            return
        }
        // Enter: continue list/checklist line automatically.
        // 36 = Return, 76 = Numpad Enter.
        if (event.keyCode == 36 || event.keyCode == 76), shouldHandleReturnAsContinuation(event) {
            handleListContinuationOnReturn()
            return
        }
        if handleNotesShortcut(event) {
            return
        }
        super.keyDown(with: event)
    }

    private func handleNotesShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == [.command] {
            switch event.keyCode {
            case 11:
                applyBoldStyle(); return true
            case 34:
                applyItalicStyle(); return true
            case 32:
                applyUnderlineStyle(); return true
            case 40:
                addLink(); return true
            default:
                break
            }
        }
        if modifiers.contains([.command, .shift]), event.keyCode == 40 {
            removeLink(); return true
        }

        guard modifiers.contains([.command, .shift]) else { return false }

        // keyCode-based handling makes shortcuts independent of keyboard layout.
        // H=4, T=17, 7=26, 8=28, 9=25, U=32, J=38, B=11, L=37
        switch event.keyCode {
        case 4:
            applyHeading(); return true
        case 38:
            applySubheading(); return true
        case 17:
            applyTitle(); return true
        case 11:
            applyBody(); return true
        case 26:
            applyBulletList(); return true
        case 28:
            applyDashedList(); return true
        case 25:
            applyNumberedList(); return true
        case 37:
            applyChecklist(); return true
        case 32:
            toggleChecklistStateOnLine(); return true
        default:
            return false
        }
    }

    private func run(_ command: NoteEditorCommand) {
        switch command {
        case .title: applyTitle()
        case .heading: applyHeading()
        case .subheading: applySubheading()
        case .body: applyBody()
        case .bold: applyBoldStyle()
        case .italic: applyItalicStyle()
        case .underline: applyUnderlineStyle()
        case .strikethrough: applyStrikethroughStyle()
        case .addLink: addLink()
        case .removeLink: removeLink()
        case .bullet: applyBulletList()
        case .dashed: applyDashedList()
        case .numbered: applyNumberedList()
        case .checklist: applyChecklist()
        }
    }

    private func makeActionItem(
        _ title: String,
        action: Selector,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    @objc private func applyTitle() { applyTextStyle(fontSize: 28, weight: .bold) }
    @objc private func applyHeading() { applyTextStyle(fontSize: 24, weight: .bold) }
    @objc private func applySubheading() { applyTextStyle(fontSize: 20, weight: .semibold) }
    @objc private func applyBody() { applyTextStyle(fontSize: 17, weight: .regular) }
    @objc private func applyBoldStyle() { toggleFontTrait(.boldFontMask) }
    @objc private func applyItalicStyle() { toggleFontTrait(.italicFontMask) }
    @objc private func applyUnderlineStyle() { toggleUnderlineStyle() }
    @objc private func applyStrikethroughStyle() { toggleStrikethroughStyle() }
    @objc private func addLink() { applyLinkPrompt() }
    @objc private func removeLink() { removeLinkAttribute() }

    private func applyTextStyle(fontSize: CGFloat, weight: NSFont.Weight) {
        guard let storage = textStorage else { return }
        let ns = storage.string as NSString
        let range = selectedRange().length == 0 ? ns.paragraphRange(for: selectedRange()) : selectedRange()
        storage.addAttribute(.font, value: NSFont.systemFont(ofSize: fontSize, weight: weight), range: range)
        didChangeText()
    }

    private func toggleFontTrait(_ trait: NSFontTraitMask) {
        guard let storage = textStorage else { return }
        let range = selectedRange()
        let fontManager = NSFontManager.shared
        let defaultFont = NSFont.systemFont(ofSize: 17)

        if range.length > 0 {
            storage.beginEditing()
            storage.enumerateAttribute(.font, in: range) { value, effectiveRange, _ in
                let current = (value as? NSFont) ?? defaultFont
                let traits = fontManager.traits(of: current)
                let updated = traits.contains(trait)
                    ? fontManager.convert(current, toNotHaveTrait: trait)
                    : fontManager.convert(current, toHaveTrait: trait)
                storage.addAttribute(.font, value: updated, range: effectiveRange)
            }
            storage.endEditing()
            didChangeText()
            return
        }

        let currentTyping = (typingAttributes[.font] as? NSFont) ?? font ?? defaultFont
        let typingTraits = fontManager.traits(of: currentTyping)
        let nextTyping = typingTraits.contains(trait)
            ? fontManager.convert(currentTyping, toNotHaveTrait: trait)
            : fontManager.convert(currentTyping, toHaveTrait: trait)
        typingAttributes[.font] = nextTyping
    }

    private func toggleUnderlineStyle() {
        guard let storage = textStorage else { return }
        let range = selectedRange()
        let singleUnderline = NSUnderlineStyle.single.rawValue

        if range.length > 0 {
            var hasUnderline = false
            storage.enumerateAttribute(.underlineStyle, in: range) { value, _, stop in
                let underline = (value as? NSNumber)?.intValue ?? 0
                if underline != 0 {
                    hasUnderline = true
                    stop.pointee = true
                }
            }
            let nextValue = hasUnderline ? 0 : singleUnderline
            storage.addAttribute(.underlineStyle, value: nextValue, range: range)
            didChangeText()
            return
        }

        let current = (typingAttributes[.underlineStyle] as? NSNumber)?.intValue ?? 0
        typingAttributes[.underlineStyle] = (current == 0) ? singleUnderline : 0
    }

    private func toggleStrikethroughStyle() {
        guard let storage = textStorage else { return }
        let range = selectedRange()
        let single = NSUnderlineStyle.single.rawValue

        if range.length > 0 {
            var hasStrike = false
            storage.enumerateAttribute(.strikethroughStyle, in: range) { value, _, stop in
                let strike = (value as? NSNumber)?.intValue ?? 0
                if strike != 0 {
                    hasStrike = true
                    stop.pointee = true
                }
            }
            let nextValue = hasStrike ? 0 : single
            storage.addAttribute(.strikethroughStyle, value: nextValue, range: range)
            didChangeText()
            return
        }

        let current = (typingAttributes[.strikethroughStyle] as? NSNumber)?.intValue ?? 0
        typingAttributes[.strikethroughStyle] = (current == 0) ? single : 0
    }

    private func applyLinkPrompt() {
        guard let storage = textStorage else { return }
        let range = selectedRange()
        guard range.length > 0 else {
            NSSound.beep()
            return
        }

        let initialValue = (storage.attribute(.link, at: range.location, effectiveRange: nil) as? URL)?.absoluteString ?? "https://"
        guard let rawURL = promptForURL(initial: initialValue) else { return }
        guard let normalizedURL = normalizedURL(from: rawURL) else {
            NSSound.beep()
            return
        }

        storage.addAttribute(.link, value: normalizedURL, range: range)
        storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: range)
        storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        didChangeText()
    }

    private func removeLinkAttribute() {
        guard let storage = textStorage else { return }
        let range = selectedRange()
        guard range.length > 0 else {
            NSSound.beep()
            return
        }

        storage.removeAttribute(.link, range: range)
        storage.removeAttribute(.underlineStyle, range: range)
        storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: range)
        didChangeText()
    }

    private func promptForURL(initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Добавить ссылку"
        alert.informativeText = "Введите URL для выделенного текста"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Отмена")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        input.stringValue = initial
        alert.accessoryView = input

        let result = alert.runModal()
        guard result == .alertFirstButtonReturn else { return nil }
        let value = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func normalizedURL(from raw: String) -> URL? {
        if let direct = URL(string: raw), direct.scheme != nil {
            return direct
        }
        return URL(string: "https://\(raw)")
    }

    @objc private func applyBulletList() { transformSelectedLines { line in "• " + stripListPrefix(from: line) } }
    @objc private func applyDashedList() { transformSelectedLines { line in "- " + stripListPrefix(from: line) } }
    @objc private func applyNumberedList() {
        var idx = 1
        transformSelectedLines { line in
            defer { idx += 1 }
            return "\(idx). " + stripListPrefix(from: line)
        }
    }
    @objc private func applyChecklist() { transformSelectedLines { line in "○ " + stripListPrefix(from: line) } }
    @objc private func toggleChecklistStateOnLine() {
        guard let storage = textStorage else { return }
        let source = storage.string as NSString
        let lineRange = source.lineRange(for: selectedRange())
        let line = source.substring(with: lineRange)
        let replaced: String
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("○ ") || line.trimmingCharacters(in: .whitespaces).hasPrefix("☐ ") {
            replaced = line.replacingOccurrences(of: "○ ", with: "✅ ").replacingOccurrences(of: "☐ ", with: "✅ ")
        } else if line.trimmingCharacters(in: .whitespaces).hasPrefix("✅ ") || line.trimmingCharacters(in: .whitespaces).hasPrefix("☑ ") {
            replaced = line.replacingOccurrences(of: "✅ ", with: "○ ").replacingOccurrences(of: "☑ ", with: "○ ")
        } else if line.trimmingCharacters(in: .whitespaces).hasPrefix("- [ ] ") {
            // Backward compatibility with old checklist format.
            replaced = line.replacingOccurrences(of: "- [ ] ", with: "✅ ")
        } else if line.trimmingCharacters(in: .whitespaces).hasPrefix("- [x] ") {
            // Backward compatibility with old checklist format.
            replaced = line.replacingOccurrences(of: "- [x] ", with: "○ ")
        } else {
            replaced = "○ " + stripListPrefix(from: line)
        }
        storage.replaceCharacters(in: lineRange, with: replaced)
        didChangeText()
    }

    private func transformSelectedLines(_ transform: (String) -> String) {
        guard let storage = textStorage else { return }
        let source = storage.string as NSString
        let selected = selectedRange()
        let lineRange = source.lineRange(for: selected)
        let original = source.substring(with: lineRange)
        let lines = original.components(separatedBy: "\n")
        let updated = lines.map(transform).joined(separator: "\n")
        storage.replaceCharacters(in: lineRange, with: updated)
        setSelectedRange(NSRange(location: lineRange.location, length: (updated as NSString).length))
        didChangeText()
    }

    private func indentSelectedLines() {
        transformSelectedLines { "    " + $0 }
    }

    private func outdentSelectedLines() {
        transformSelectedLines { line in
            if line.hasPrefix("    ") { return String(line.dropFirst(4)) }
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            return line
        }
    }

    private func shouldHandleReturnAsContinuation(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return !mods.contains(.command) && !mods.contains(.option) && !mods.contains(.control)
    }

    private func handleListContinuationOnReturn() {
        guard let storage = textStorage else { return }
        let selection = selectedRange()
        let source = storage.string as NSString
        let lineRange = source.lineRange(for: selection)
        let line = source.substring(with: lineRange)
        let leading = String(line.prefix { $0 == " " || $0 == "\t" })
        let content = String(line.dropFirst(leading.count))

        guard let prefix = continuationPrefix(for: content) else {
            insertNewlineAtSelection()
            return
        }

        let stripped = stripListPrefix(from: content).trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty list item -> exit list by replacing marker-only line with empty line.
        if stripped.isEmpty {
            storage.replaceCharacters(in: lineRange, with: leading)
            setSelectedRange(NSRange(location: lineRange.location + (leading as NSString).length, length: 0))
            didChangeText()
            return
        }

        let insertion = "\n" + leading + prefix
        storage.replaceCharacters(in: selection, with: insertion)
        setSelectedRange(NSRange(location: selection.location + (insertion as NSString).length, length: 0))
        didChangeText()
    }

    private func insertNewlineAtSelection() {
        guard let storage = textStorage else { return }
        let selection = selectedRange()
        storage.replaceCharacters(in: selection, with: "\n")
        setSelectedRange(NSRange(location: selection.location + 1, length: 0))
        didChangeText()
    }

    private func continuationPrefix(for line: String) -> String? {
        if line.hasPrefix("○ ") || line.hasPrefix("✅ ") || line.hasPrefix("☐ ") || line.hasPrefix("☑ ") { return "○ " }
        if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") { return "○ " } // old format
        if line.hasPrefix("• ") { return "• " }
        if line.hasPrefix("- ") { return "- " }
        if let match = line.range(of: #"^(\d+)\.\s"#, options: .regularExpression) {
            let rawPrefix = String(line[match])
            let number = Int(rawPrefix.components(separatedBy: ".").first ?? "1") ?? 1
            return "\(number + 1). "
        }
        return nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard

        if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let first = images.first {
            insertImageAttachment(first)
            return true
        }

        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], let first = urls.first {
            insertFileInlineLink(first)
            return true
        }

        return super.performDragOperation(sender)
    }

    private func insertImageAttachment(_ image: NSImage) {
        let attachment = NSTextAttachment()
        attachment.image = image
        let attr = NSAttributedString(attachment: attachment)
        textStorage?.insert(attr, at: selectedRange().location)
        didChangeText()
    }

    private func insertFileInlineLink(_ url: URL) {
        let title = "📎 \(url.lastPathComponent)"
        let attrs: [NSAttributedString.Key: Any] = [
            .link: url,
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .font: NSFont.systemFont(ofSize: 15, weight: .regular)
        ]
        let attr = NSAttributedString(string: title, attributes: attrs)
        let mutable = NSMutableAttributedString(attributedString: attr)
        mutable.append(NSAttributedString(string: "\n"))
        textStorage?.insert(mutable, at: selectedRange().location)
        didChangeText()
    }

    private func stripListPrefix(from line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("• ") { return String(trimmed.dropFirst(2)) }
        if trimmed.hasPrefix("- ") { return String(trimmed.dropFirst(2)) }
        if let match = trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) {
            return String(trimmed[match.upperBound...])
        }
        if trimmed.hasPrefix("○ ") { return String(trimmed.dropFirst(2)) }
        if trimmed.hasPrefix("✅ ") { return String(trimmed.dropFirst(2)) }
        if trimmed.hasPrefix("☐ ") { return String(trimmed.dropFirst(2)) }
        if trimmed.hasPrefix("☑ ") { return String(trimmed.dropFirst(2)) }
        if trimmed.hasPrefix("- [ ] ") { return String(trimmed.dropFirst(6)) }
        if trimmed.hasPrefix("- [x] ") { return String(trimmed.dropFirst(6)) }
        return trimmed
    }

    private func toggleChecklistAtClick(point: NSPoint) -> Bool {
        guard let storage = textStorage,
              let container = textContainer,
              let layout = layoutManager else { return false }

        let glyphIndex = layout.glyphIndex(for: point, in: container)
        let charIndex = layout.characterIndexForGlyph(at: glyphIndex)
        let source = storage.string as NSString
        guard charIndex < source.length else { return false }

        let lineRange = source.lineRange(for: NSRange(location: charIndex, length: 0))
        let line = source.substring(with: lineRange)
        let leadingCount = line.prefix { $0 == " " || $0 == "\t" }.count
        let contentStart = lineRange.location + leadingCount

        guard charIndex <= contentStart + 2 else { return false }

        if line.dropFirst(leadingCount).hasPrefix("○ ") || line.dropFirst(leadingCount).hasPrefix("☐ ") {
            storage.replaceCharacters(in: NSRange(location: contentStart, length: 2), with: "✅ ")
            didChangeText()
            return true
        }
        if line.dropFirst(leadingCount).hasPrefix("✅ ") || line.dropFirst(leadingCount).hasPrefix("☑ ") {
            storage.replaceCharacters(in: NSRange(location: contentStart, length: 2), with: "○ ")
            didChangeText()
            return true
        }
        if line.dropFirst(leadingCount).hasPrefix("- [ ] ") {
            storage.replaceCharacters(in: NSRange(location: contentStart, length: 6), with: "✅ ")
            didChangeText()
            return true
        }
        if line.dropFirst(leadingCount).hasPrefix("- [x] ") {
            storage.replaceCharacters(in: NSRange(location: contentStart, length: 6), with: "○ ")
            didChangeText()
            return true
        }
        return false
    }
}
#endif
