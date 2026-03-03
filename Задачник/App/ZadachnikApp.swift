import SwiftUI
import SwiftData

extension Notification.Name {
    static let showQuickCapture = Notification.Name("showQuickCapture")
}

enum AppThemeMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Системная"
        case .light: return "Светлая"
        case .dark: return "Тёмная"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

@main
struct ZadachnikApp: App {
    @State private var showQuickCapture = false
    @AppStorage("appThemeMode") private var appThemeModeRaw = AppThemeMode.system.rawValue

    init() {
        Self.seedKeychainIfNeeded()
    }

    private var selectedColorScheme: ColorScheme? {
        AppThemeMode(rawValue: appThemeModeRaw)?.colorScheme
    }

    /// Seed secrets from runtime environment only (never hardcoded in source).
    private static func seedKeychainIfNeeded() {
        saveFromEnvironment(["OPENAI_API_KEY"], for: KeychainKey.openAIAPIKey)
        saveFromEnvironment(["TELEGRAM_BOT_TOKEN"], for: KeychainKey.telegramBotToken)
        saveFromEnvironment(["TELEGRAM_CHAT_ID"], for: KeychainKey.telegramChatId)
        saveFromEnvironment(["AIRTABLE_API_KEY"], for: KeychainKey.airtableAPIKey)
        saveFromEnvironment(["AIRTABLE_BASE_ID"], for: KeychainKey.airtableBaseId)
        saveFromEnvironment(["GOOGLE_ICAL_URL"], for: KeychainKey.googleIcalURL)
    }

    private static func saveFromEnvironment(_ keys: [String], for keychainKey: String) {
        let env = ProcessInfo.processInfo.environment
        for key in keys {
            guard let value = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { continue }
            KeychainHelper.save(value, for: keychainKey)
            return
        }
    }

    let container: ModelContainer = {
        let schema = Schema([
            Project.self,
            TaskItem.self,
            QuickNote.self,
            Person.self,
            Interaction.self,
            Deal.self,
            MaterialLink.self,
            RecurringPattern.self,
            CustomField.self,
            CustomFieldValue.self,
            VoiceMemo.self,
            Attachment.self
        ])

        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Zadachnik", isDirectory: true)

        try? FileManager.default.createDirectory(
            at: appSupport,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let storeURL = appSupport.appendingPathComponent("zadachnik.store")

        do {
            let config = ModelConfiguration(schema: schema, url: storeURL)
            let mc = try ModelContainer(for: schema, configurations: [config])
            print("[Задачник] DB: \(storeURL.path)")
            return mc
        } catch {
            print("[Задачник] Custom store failed (\(error)). Trying to recreate...")
            // Remove corrupted store and start fresh (data preserved in zadachnik.store)
            let defaultURL = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("default.store")
            for ext in ["", "-shm", "-wal"] {
                let url = defaultURL.deletingPathExtension().appendingPathExtension("store\(ext)")
                try? FileManager.default.removeItem(at: url)
            }
            // Retry with zadachnik.store only
            let config = ModelConfiguration(schema: schema, url: storeURL)
            if let mc = try? ModelContainer(for: schema, configurations: [config]) {
                return mc
            }
            // Last resort: in-memory (no data loss from disk)
            let memConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return try! ModelContainer(for: schema, configurations: [memConfig])
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(container)
                .preferredColorScheme(selectedColorScheme)
                #if os(macOS)
                .frame(minWidth: 900, minHeight: 600)
                #endif
                .sheet(isPresented: $showQuickCapture) {
                    QuickCaptureView()
                        .modelContainer(container)
                        .preferredColorScheme(selectedColorScheme)
                }
                .onReceive(NotificationCenter.default.publisher(for: .showQuickCapture)) { _ in
                    showQuickCapture = true
                }
                .task {
                    await seedProjectsIfNeeded()
                }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Быстрая запись") {
                    NotificationCenter.default.post(name: .showQuickCapture, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }

        #if os(macOS)
        Settings {
            AppSettingsView()
                .modelContainer(container)
                .preferredColorScheme(selectedColorScheme)
                .frame(width: 520, height: 640)
        }
        #endif
    }

    // MARK: - Seed

    @MainActor
    private func seedProjectsIfNeeded() async {
        let ctx = ModelContext(container)
        let existing = (try? ctx.fetch(FetchDescriptor<Project>())) ?? []
        guard existing.isEmpty else { return }

        let projectDefs: [(String, String, String)] = [
            ("Cursor кодинг",              "laptopcomputer",       "#6366F1"),
            ("Тестирование идей",          "lightbulb.fill",       "#F59E0B"),
            ("Аналитика",                  "chart.bar.fill",       "#3B82F6"),
            ("Airdrops",                   "gift.fill",            "#10B981"),
            ("Работа с инвесторами",       "person.2.fill",        "#8B5CF6"),
            ("Саморазвитие + softskills",  "brain.head.profile",   "#EC4899"),
            ("Операционка",                "gearshape.fill",       "#6B7280"),
            ("Trenches",                   "flame.fill",           "#EF4444"),
            ("Управление капиталом",       "banknote.fill",        "#059669"),
        ]

        for (i, (name, icon, color)) in projectDefs.enumerated() {
            let proj = Project(name: name, colorHex: color, icon: icon, sortOrder: i)
            ctx.insert(proj)
        }
        try? ctx.save()
    }
}
