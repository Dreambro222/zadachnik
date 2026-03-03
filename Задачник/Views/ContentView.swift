import SwiftUI
import SwiftData
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case today
    case inbox
    case notes
    case people
    case deals
    case materials
    case patterns
    case voiceMemos
    case callRecorder
    case files
    case search
    case project(Project)

    static func == (lhs: SidebarItem, rhs: SidebarItem) -> Bool {
        switch (lhs, rhs) {
        case (.today, .today):       return true
        case (.inbox, .inbox):       return true
        case (.notes, .notes):       return true
        case (.people, .people):     return true
        case (.deals, .deals):       return true
        case (.materials, .materials): return true
        case (.patterns, .patterns): return true
        case (.voiceMemos, .voiceMemos): return true
        case (.callRecorder, .callRecorder): return true
        case (.files, .files):       return true
        case (.search, .search):     return true
        case (.project(let a), .project(let b)): return a.id == b.id
        default: return false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .today:         hasher.combine(0)
        case .inbox:         hasher.combine(1)
        case .notes:         hasher.combine(2)
        case .people:        hasher.combine(3)
        case .deals:         hasher.combine(4)
        case .materials:     hasher.combine(5)
        case .patterns:      hasher.combine(6)
        case .voiceMemos:    hasher.combine(7)
        case .callRecorder:  hasher.combine(11)
        case .files:         hasher.combine(8)
        case .search:        hasher.combine(9)
        case .project(let p): hasher.combine(10); hasher.combine(p.id)
        }
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \Project.sortOrder) private var projects: [Project]
    @Query(sort: \Person.name) private var people: [Person]
    @Query(filter: #Predicate<TaskItem> { $0.statusRaw != "Готово" })
    private var activeTasks: [TaskItem]

    @State private var selectedItem: SidebarItem? = .today
    @State private var showAddProject    = false
    @State private var showQuickCapture  = false
    @State private var showAISidebar     = false
    @State private var showAISheet       = false
    @State private var showSearchSheet   = false
    @State private var showAirtableImport = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    // Global file drop
    @State private var isFileDropTargeted = false
    
    private var inboxCount: Int {
        activeTasks.filter { $0.project == nil }.count
    }

    var body: some View {
        #if os(macOS)
        macLayout
        #else
        iOSLayout
        #endif
    }

    // MARK: - macOS

    #if os(macOS)
    @ViewBuilder
    private var macLayout: some View {
        ZStack {
            if showAISidebar {
                HSplitView {
                    mainSplitView

                    AISidebarView(aiContext: currentAIContext, explicitModelContext: modelContext)
                        .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)
                }
            } else {
                mainSplitView
            }

            // Global drop overlay
            if isFileDropTargeted {
                globalDropOverlay
            }
        }
        .sheet(isPresented: $showAddProject) { AddProjectView() }
        .sheet(isPresented: $showQuickCapture) { QuickCaptureView() }
        .sheet(isPresented: $showAirtableImport) { AirtableImportView() }
        .onAppear { ensureValidSelection() }
        .onChange(of: projects.map(\.id)) { _, _ in
            ensureValidSelection()
        }
        // Accept file drops anywhere in the window
        .onDrop(of: [.fileURL, .image, .pdf, .plainText, .data],
                isTargeted: $isFileDropTargeted) { providers in
            selectedItem = .files
            Task {
                await globalImport(providers: providers)
            }
            return true
        }
    }

    @ViewBuilder
    private var mainSplitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            detailView
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var globalDropOverlay: some View {
        ZStack {
            Color.blue.opacity(0.15)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 16) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue)

                Text("Перетащите файлы")
                    .font(.largeTitle).fontWeight(.bold)
                    .foregroundStyle(.blue)

                Text("Файлы сохранятся в раздел «Файлы»")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(40)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28))
            .shadow(color: .black.opacity(0.12), radius: 24)
            .allowsHitTesting(false)
        }
    }

    private func globalImport(providers: [NSItemProvider]) async {
        let dir: URL = {
            let d = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Attachments", isDirectory: true)
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            return d
        }()

        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
            let url: URL? = await withCheckedContinuation { cont in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    if let data = item as? Data, let u = URL(dataRepresentation: data, relativeTo: nil) {
                        cont.resume(returning: u)
                    } else {
                        cont.resume(returning: nil)
                    }
                }
            }
            guard let srcURL = url else { continue }

            await MainActor.run {
                let destName = UUID().uuidString + "_" + srcURL.lastPathComponent
                let destURL  = dir.appendingPathComponent(destName)
                do {
                    try FileManager.default.copyItem(at: srcURL, to: destURL)
                    let size = (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? Int64) ?? 0
                    let att = Attachment(
                        fileName: destName,
                        mimeType: mimeTypeFor(srcURL.pathExtension),
                        fileSize: size
                    )
                    att.displayName = srcURL.lastPathComponent
                    modelContext.insert(att)
                } catch { }
            }
        }
        await MainActor.run { try? modelContext.save() }
    }

    private func mimeTypeFor(_ ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png":         return "image/png"
        case "pdf":         return "application/pdf"
        case "txt", "md":   return "text/plain"
        case "mp4":         return "video/mp4"
        case "mov":         return "video/quicktime"
        case "zip":         return "application/zip"
        default:            return "application/octet-stream"
        }
    }
    #endif

    // MARK: - iOS

    @ViewBuilder
    private var iOSLayout: some View {
        TabView {
            // Today tab — with quick action buttons built in
            NavigationStack {
                TodayView()
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) { captureButton }
                        ToolbarItem(placement: .primaryAction) { searchToolbarButton }
                    }
            }
            // Floating actions overlay for Today
            .overlay(alignment: .bottom) {
                iOSQuickActions
            }
            .tabItem { Label("Сегодня", systemImage: "calendar") }

            NavigationStack {
                ProjectsListView(selectedProject: .constant(nil))
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) { searchToolbarButton }
            }
            .tabItem { Label("Проекты", systemImage: "folder") }

            NavigationStack {
                PeopleView()
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) { searchToolbarButton }
            }
            .tabItem { Label("Люди", systemImage: "person.2") }

            NavigationStack {
                QuickNotesView()
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) { searchToolbarButton }
            }
            .tabItem { Label("Заметки", systemImage: "note.text") }

            NavigationStack {
                moreTab
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) { searchToolbarButton }
            }
            .tabItem { Label("Ещё", systemImage: "ellipsis.circle") }
        }
        .sheet(isPresented: $showAddProject) { AddProjectView() }
        .sheet(isPresented: $showAirtableImport) { AirtableImportView() }
        .sheet(isPresented: $showAISheet) {
            NavigationStack {
                AISidebarView(aiContext: AIContext(screenName: "Сегодня"))
                    .navigationTitle("ИИ-помощник")
                    .navigationInline()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Готово") { showAISheet = false }
                        }
                    }
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showSearchSheet) {
            NavigationStack {
                GlobalSearchView()
                    .navigationTitle("Поиск")
                    .navigationInline()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Готово") { showSearchSheet = false }
                        }
                    }
            }
            .presentationDetents([.large])
        }
    }

    /// Floating quick-action buttons on iOS Today tab
    private var iOSQuickActions: some View {
        HStack(spacing: 12) {
            // New project
            Button {
                showAddProject = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder.badge.plus")
                        .font(.subheadline.weight(.semibold))
                    Text("Проект")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.blue, in: Capsule())
                .shadow(color: .blue.opacity(0.35), radius: 8, y: 4)
            }
            .buttonStyle(.plain)

            // AI assistant
            Button {
                showAISheet = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.subheadline.weight(.semibold))
                    Text("ИИ")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.purple, in: Capsule())
                .shadow(color: .purple.opacity(0.35), radius: 8, y: 4)
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, 90)  // above tab bar
    }

    private var moreTab: some View {
        List {
            NavigationLink { DealsView() }               label: { Label("Договорённости", systemImage: "handshake.fill") }
            NavigationLink { MaterialsView() }           label: { Label("Материалы", systemImage: "folder.badge.plus") }
            NavigationLink { PatternsView() }            label: { Label("Ритуалы", systemImage: "arrow.clockwise.circle.fill") }
            NavigationLink { VoiceMemosView() }          label: { Label("Голосовые", systemImage: "waveform.circle.fill") }
            NavigationLink { CallRecorderView() }        label: { Label("Запись звонков", systemImage: "record.circle.fill") }
            NavigationLink { AttachmentsView() }         label: { Label("Файлы", systemImage: "doc.fill") }
            NavigationLink { GlobalSearchView() }        label: { Label("Поиск", systemImage: "magnifyingglass") }
            NavigationLink { AppSettingsView() }         label: { Label("Настройки", systemImage: "gearshape.fill") }
        }
        .navigationTitle("Ещё")
        .adaptiveListStyle()
    }

    // MARK: - macOS Sidebar

    private var sidebar: some View {
        List(selection: $selectedItem) {
            Section {
                Label("Сегодня", systemImage: "calendar")
                    .tag(SidebarItem.today)
                Label("Заметки", systemImage: "note.text")
                    .tag(SidebarItem.notes)

                HStack {
                    Label("Люди", systemImage: "person.2.fill")
                    Spacer()
                    if !people.isEmpty { countBadge(people.count) }
                }
                .tag(SidebarItem.people)

                Label("Договорённости", systemImage: "handshake.fill")
                    .tag(SidebarItem.deals)
                Label("Материалы", systemImage: "folder.badge.plus")
                    .tag(SidebarItem.materials)
                Label("Ритуалы", systemImage: "arrow.clockwise.circle.fill")
                    .tag(SidebarItem.patterns)
                Label("Голосовые", systemImage: "waveform.circle.fill")
                    .tag(SidebarItem.voiceMemos)
                Label("Запись звонков", systemImage: "record.circle.fill")
                    .tag(SidebarItem.callRecorder)
                Label("Файлы", systemImage: "doc.fill")
                    .tag(SidebarItem.files)
                Label("Поиск", systemImage: "magnifyingglass")
                    .tag(SidebarItem.search)
            }

            Section("Проекты") {
                HStack {
                    Label("Без проекта", systemImage: "tray")
                    Spacer()
                    if inboxCount > 0 { countBadge(inboxCount) }
                }
                .tag(SidebarItem.inbox)

                ForEach(projects) { project in
                    ProjectRow(project: project)
                        .tag(SidebarItem.project(project))
                }
                .onMove(perform: moveProjects)
                .onDelete(perform: deleteProjects)
            }
        }
        .navigationTitle("Задачник")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { captureButton }
            ToolbarItem { aiButton }
            ToolbarItem { searchToolbarButton }
            ToolbarItem {
                Button { showAddProject = true } label: {
                    Label("Новый проект", systemImage: "folder.badge.plus")
                }
            }
        }
    }

    // MARK: - AI Context

    private var currentAIContext: AIContext {
        switch selectedItem {
        case .today, nil:
            return AIContext(screenName: "Сегодня", objectDescription: "")
        case .inbox:
            return AIContext(screenName: "Без проекта (Inbox)", objectDescription: "Задачи без проекта: \(inboxCount)")
        case .notes:
            return AIContext(screenName: "Заметки", objectDescription: "")
        case .people:
            return AIContext(screenName: "Люди / CRM", objectDescription: "")
        case .deals:
            return AIContext(screenName: "Договорённости", objectDescription: "")
        case .materials:
            return AIContext(screenName: "Материалы", objectDescription: "")
        case .patterns:
            return AIContext(screenName: "Ритуалы", objectDescription: "")
        case .voiceMemos:
            return AIContext(screenName: "Голосовые записи", objectDescription: "")
        case .callRecorder:
            return AIContext(screenName: "Запись звонков", objectDescription: "")
        case .files:
            return AIContext(screenName: "Файлы", objectDescription: "")
        case .search:
            return AIContext(screenName: "Поиск", objectDescription: "")
        case .project(let project):
            let active = project.tasks.filter { $0.status != .done }.count
            return AIContext(
                screenName: "Проект «\(project.name)»",
                objectDescription: "Активных задач: \(active)"
            )
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailView: some View {
        switch selectedItem {
        case .today, nil:
            NavigationStack { TodayView() }
        case .inbox:
            NavigationStack { InboxTasksView() }
        case .notes:
            NavigationStack { QuickNotesView() }
        case .people:
            NavigationStack { PeopleView() }
        case .deals:
            NavigationStack { DealsView() }
        case .materials:
            NavigationStack { MaterialsView() }
        case .patterns:
            NavigationStack { PatternsView() }
        case .voiceMemos:
            NavigationStack { VoiceMemosView() }
        case .callRecorder:
            NavigationStack { CallRecorderView() }
        case .files:
            NavigationStack { AttachmentsView() }
        case .search:
            NavigationStack { GlobalSearchView() }
        case .project(let project):
            NavigationStack { ProjectDetailView(project: project).id(project.id) }
        }
    }

    // MARK: - Shared buttons

    private var captureButton: some View {
        Button { showQuickCapture = true } label: {
            Label("Быстрая запись", systemImage: "plus.circle.fill")
                .symbolRenderingMode(.hierarchical)
        }
        .accessibilityHint("Открывает окно быстрого добавления заметки или задачи")
    }

    private var aiButton: some View {
        Button {
            if reduceMotion {
                showAISidebar.toggle()
            } else {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showAISidebar.toggle()
                }
            }
        } label: {
            Image(systemName: showAISidebar ? "sparkles.rectangle.stack.fill" : "sparkles")
                .foregroundStyle(showAISidebar ? .purple : .secondary)
        }
        .accessibilityLabel("ИИ-помощник")
        .accessibilityValue(showAISidebar ? "Открыт" : "Закрыт")
        .accessibilityHint("Показывает или скрывает ИИ-панель")
    }

    private var searchToolbarButton: some View {
        Button {
#if os(macOS)
            if selectedItem == .today || selectedItem == nil {
                NotificationCenter.default.post(name: .focusTodaySearch, object: nil)
            } else {
                selectedItem = .search
            }
#else
            showSearchSheet = true
#endif
        } label: {
            Image(systemName: "magnifyingglass")
        }
        .keyboardShortcut("f", modifiers: [.command])
        .help("Поиск")
        .accessibilityLabel("Поиск")
        .accessibilityHint("Открывает глобальный поиск по приложению")
    }

    private func countBadge(_ count: Int) -> some View {
        Text("\(count)")
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .frame(minWidth: 18)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.secondary, in: Capsule())
    }

    private func moveProjects(from source: IndexSet, to destination: Int) {
        var sorted = projects
        sorted.move(fromOffsets: source, toOffset: destination)
        for (index, project) in sorted.enumerated() {
            project.sortOrder = index
        }
        try? modelContext.save()
    }

    private func deleteProjects(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(projects[index])
        }
        try? modelContext.save()
    }

    private func ensureValidSelection() {
        guard case .project(let selectedProject) = selectedItem else { return }
        let projectExists = projects.contains { $0.id == selectedProject.id }
        if !projectExists {
            selectedItem = .today
        }
    }
}
