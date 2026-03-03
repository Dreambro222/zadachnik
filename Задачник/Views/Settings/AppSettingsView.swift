import SwiftUI

struct AppSettingsView: View {
    @StateObject private var cal       = CalendarService.shared
    @StateObject private var airtable  = AirtableService.shared
    @StateObject private var telegram  = TelegramService.shared
    @AppStorage("appThemeMode") private var appThemeModeRaw = AppThemeMode.system.rawValue

    // Airtable
    @State private var airtableKey   = KeychainHelper.load(KeychainKey.airtableAPIKey) ?? ""
    @State private var airtableBase  = KeychainHelper.load(KeychainKey.airtableBaseId) ?? ""
    @State private var savedAirtable = false

    // Telegram
    @State private var tgToken       = KeychainHelper.load(KeychainKey.telegramBotToken) ?? ""
    @State private var tgChatId      = KeychainHelper.load(KeychainKey.telegramChatId)  ?? ""
    @State private var savedTelegram = false
    @State private var tgValidating  = false
    @State private var tgTestSent    = false

    // Shared state
    @State private var validationError: String? = nil
    @State private var isValidating    = false
    @State private var syncResultText: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                // MARK: AI
                Section {
                    NavigationLink {
                        AISettingsView()
                    } label: {
                        Label("ИИ-ключи (OpenAI, Claude, Perplexity)", systemImage: "sparkles")
                    }
                } header: {
                    Text("Искусственный интеллект")
                }

                // MARK: Appearance
                Section("Оформление") {
                    Picker("Тема", selection: $appThemeModeRaw) {
                        ForEach(AppThemeMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                // MARK: Airtable
                Section {
                    SecureField("API Key (pat...)", text: $airtableKey)
                        .font(.system(.body, design: .monospaced))
                    TextField("Base ID (app...)", text: $airtableBase)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()

                    HStack {
                        Button {
                            Task { await validateAirtable() }
                        } label: {
                            Label(isValidating ? "Проверка..." : "Проверить", systemImage: "wifi")
                        }
                        .disabled(airtableKey.isEmpty || airtableBase.isEmpty || isValidating)

                        Spacer()

                        Button {
                            KeychainHelper.save(airtableKey, for: KeychainKey.airtableAPIKey)
                            KeychainHelper.save(airtableBase, for: KeychainKey.airtableBaseId)
                            savedAirtable = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { savedAirtable = false }
                        } label: {
                            Text(savedAirtable ? "Сохранено ✓" : "Сохранить")
                                .fontWeight(.semibold)
                                .foregroundStyle(savedAirtable ? .green : .blue)
                        }
                    }

                    if let err = validationError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if airtable.lastSyncDate != nil || !airtableKey.isEmpty {
                        Divider()
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Project management 2026")
                                    .font(.subheadline).fontWeight(.medium)
                                if let d = airtable.lastSyncDate {
                                    Text("Синхр.: \(d.formatted(.relative(presentation: .named)))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if airtable.isSyncing {
                                ProgressView().scaleEffect(0.9)
                            } else {
                                Button {
                                    Task { await syncTasks() }
                                } label: {
                                    Label("Синхр.", systemImage: "arrow.triangle.2.circlepath")
                                        .font(.subheadline)
                                }
                                .disabled(airtableKey.isEmpty || airtableBase.isEmpty)
                            }
                        }
                        if let err = airtable.lastError {
                            Text(err).font(.caption).foregroundStyle(.red)
                        }
                        if let result = syncResultText {
                            Text(result).font(.caption).foregroundStyle(.green)
                        }
                    }
                } header: {
                    Label("Airtable", systemImage: "table")
                } footer: {
                    Link("Получить API ключ → airtable.com/create/tokens",
                         destination: URL(string: "https://airtable.com/create/tokens")!)
                        .font(.caption)
                }

                // MARK: Calendar (EventKit → Google Calendar)
                Section {
                    // Status + actions row
                    HStack {
                        if cal.isAuthorized {
                            Label("Доступ разрешён", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.subheadline)
                        } else {
                            Label("Нет доступа", systemImage: "calendar.badge.exclamationmark")
                                .foregroundStyle(.orange)
                                .font(.subheadline)
                        }
                        Spacer()
                        if !cal.isAuthorized {
                            Button {
                                Task { _ = await cal.requestAccess() }
                            } label: {
                                Text("Разрешить")
                                    .font(.subheadline).fontWeight(.semibold)
                                    .foregroundStyle(.blue)
                            }
                        }
                        Button {
                            cal.refresh()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .foregroundStyle(.blue)
                        }
                        .help("Обновить список календарей")
                    }

                    // Calendar list (показываем даже если 1 — чтобы было видно)
                    if cal.isAuthorized {
                        if cal.availableCalendars.isEmpty {
                            HStack {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Календари не найдены")
                                        .font(.subheadline)
                                    Text("Нажмите ↺ для обновления")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Выберите календарь:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.bottom, 4)
                                ForEach(cal.availableCalendars, id: \.calendarIdentifier) { calendar in
                                    Button {
                                        cal.selectCalendar(calendar)
                                    } label: {
                                        HStack(spacing: 10) {
                                            Circle()
                                                .fill(Color(cgColor: calendar.cgColor))
                                                .frame(width: 10, height: 10)
                                            Text(calendar.title)
                                                .font(.subheadline)
                                                .foregroundStyle(.primary)
                                            Spacer()
                                            if calendar.calendarIdentifier == cal.selectedCalendarId {
                                                Image(systemName: "checkmark")
                                                    .foregroundStyle(.blue)
                                                    .fontWeight(.semibold)
                                            }
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.vertical, 3)
                                }
                            }
                        }
                    }
                } header: {
                    Label("Календарь", systemImage: "calendar")
                } footer: {
                    Text("Дедлайны добавляются в выбранный календарь, который синхронизируется с Google Calendar. Если только что добавили аккаунт Google — нажмите ↺.")
                        .font(.caption)
                }

                // MARK: Telegram
                Section {
                    SecureField("Bot Token (1234567890:AAG...)", text: $tgToken)
                        .font(.system(.body, design: .monospaced))
                    TextField("Chat ID (-527441953...)", text: $tgChatId)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()

                    HStack {
                        Button {
                            Task { await validateTelegram() }
                        } label: {
                            Label(tgValidating ? "Проверка..." : "Проверить бота", systemImage: "paperplane")
                        }
                        .disabled(tgToken.isEmpty || tgValidating)

                        Spacer()

                        Button {
                            KeychainHelper.save(tgToken,  for: KeychainKey.telegramBotToken)
                            KeychainHelper.save(tgChatId, for: KeychainKey.telegramChatId)
                            savedTelegram = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { savedTelegram = false }
                        } label: {
                            Text(savedTelegram ? "Сохранено ✓" : "Сохранить")
                                .fontWeight(.semibold)
                                .foregroundStyle(savedTelegram ? .green : .blue)
                        }
                    }

                    if tgTestSent {
                        Label("Тестовое сообщение отправлено!", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    }

                    if let err = telegram.lastError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                } header: {
                    Label("Telegram уведомления", systemImage: "bell.badge.fill")
                } footer: {
                    Link("Создать бота → @BotFather в Telegram",
                         destination: URL(string: "https://t.me/BotFather")!)
                        .font(.caption)
                }

                // MARK: Custom Fields
                Section("Кастомные поля") {
                    NavigationLink {
                        CustomFieldsSettingsView()
                    } label: {
                        Label("Настроить поля задач", systemImage: "slider.horizontal.3")
                    }
                }

                // MARK: Import
                Section("Импорт данных") {
                    NavigationLink {
                        AirtableImportView()
                    } label: {
                        Label("Импорт задач из Airtable", systemImage: "table.badge.more")
                    }

                    NavigationLink {
                        ImportView()
                    } label: {
                        Label("Импорт из Notion / другое", systemImage: "square.and.arrow.down")
                    }
                }

                // MARK: About
                Section("О приложении") {
                    LabeledContent("Версия", value: "1.0")
                    LabeledContent("Синхронизация", value: "iCloud (CloudKit)")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Настройки")
            .navigationInline()
        }
    }

    // MARK: - Actions

    private func validateAirtable() async {
        isValidating = true
        validationError = nil
        KeychainHelper.save(airtableKey, for: KeychainKey.airtableAPIKey)
        KeychainHelper.save(airtableBase, for: KeychainKey.airtableBaseId)
        do {
            try await AirtableService.shared.validateConnection()
        } catch {
            validationError = error.localizedDescription
        }
        isValidating = false
    }

    @MainActor
    private func syncTasks() async {
        syncResultText = nil
        airtable.lastError = nil
        do {
            try await AirtableService.shared.validateConnection()
            airtable.lastSyncDate = Date()
            syncResultText = "Соединение OK. Синхронизируйте задачи через кнопку ↕ в задаче."
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { syncResultText = nil }
        } catch {
            airtable.lastError = error.localizedDescription
        }
    }

    private func validateTelegram() async {
        tgValidating = true
        telegram.lastError = nil
        KeychainHelper.save(tgToken,  for: KeychainKey.telegramBotToken)
        KeychainHelper.save(tgChatId, for: KeychainKey.telegramChatId)
        do {
            try await TelegramService.shared.validateConnection()
            await TelegramService.shared.send("✅ Задачник подключён! Уведомления работают.")
            tgTestSent = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { tgTestSent = false }
        } catch {
            telegram.lastError = error.localizedDescription
        }
        tgValidating = false
    }
}
