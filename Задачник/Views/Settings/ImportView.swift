import SwiftUI
import SwiftData

struct ImportView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var airtable = AirtableService.shared

    @State private var notionToken = ""
    @State private var notionDatabaseId = ""
    @State private var airtableTable = ""
    @State private var airtableTitleField = "Name"
    @State private var airtableBodyField = "Notes"

    @State private var isImportingNotion = false
    @State private var isImportingAirtable = false
    @State private var importResult: String? = nil
    @State private var importError: String? = nil

    var body: some View {
        Form {
            // MARK: Airtable Import
            Section {
                TextField("Название таблицы", text: $airtableTable)
                TextField("Поле с заголовком", text: $airtableTitleField)
                TextField("Поле с телом", text: $airtableBodyField)

                Button {
                    Task { await importFromAirtable() }
                } label: {
                    HStack {
                        if isImportingAirtable {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(isImportingAirtable ? "Загрузка..." : "Импортировать как заметки")
                            .fontWeight(.semibold)
                    }
                }
                .disabled(airtableTable.isEmpty || isImportingAirtable)
            } header: {
                Label("Импорт из Airtable", systemImage: "table")
            } footer: {
                Text("Требует настроенного API ключа в Настройках → Airtable")
                    .font(.caption)
            }

            // MARK: Notion Import
            Section {
                SecureField("Integration Token (secret_...)", text: $notionToken)
                    .font(.system(.body, design: .monospaced))
                TextField("Database ID", text: $notionDatabaseId)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()

                Button {
                    Task { await importFromNotion() }
                } label: {
                    HStack {
                        if isImportingNotion {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(isImportingNotion ? "Загрузка..." : "Импортировать из Notion")
                            .fontWeight(.semibold)
                    }
                }
                .disabled(notionToken.isEmpty || notionDatabaseId.isEmpty || isImportingNotion)
            } header: {
                Label("Импорт из Notion", systemImage: "text.page")
            } footer: {
                Link("Создать интеграцию → notion.so/profile/integrations",
                     destination: URL(string: "https://www.notion.so/profile/integrations")!)
                    .font(.caption)
            }

            // MARK: Result
            if let result = importResult {
                Section {
                    Label(result, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            if let error = importError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Импорт")
        .navigationInline()
    }

    // MARK: - Airtable Import

    private func importFromAirtable() async {
        isImportingAirtable = true
        importResult = nil
        importError = nil

        do {
            let records = try await airtable.fetchRecords(table: airtableTable)
            var count = 0
            for record in records {
                let fields = record["fields"] as? [String: Any] ?? [:]
                let title = fields[airtableTitleField] as? String ?? "Без названия"
                let body = fields[airtableBodyField] as? String ?? ""
                let note = QuickNote(body: body.isEmpty ? title : body, title: title.isEmpty ? "" : title)
                modelContext.insert(note)
                count += 1
            }
            try? modelContext.save()
            importResult = "Импортировано \(count) записей из Airtable"
        } catch {
            importError = error.localizedDescription
        }
        isImportingAirtable = false
    }

    // MARK: - Notion Import

    private func importFromNotion() async {
        isImportingNotion = true
        importResult = nil
        importError = nil

        do {
            let url = URL(string: "https://api.notion.com/v1/databases/\(notionDatabaseId)/query")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(notionToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["page_size": 100])

            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                let msg = String(data: data, encoding: .utf8) ?? "Ошибка"
                throw NSError(domain: "Notion", code: 0, userInfo: [NSLocalizedDescriptionKey: msg])
            }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let results = json?["results"] as? [[String: Any]] ?? []

            var count = 0
            for page in results {
                let props = page["properties"] as? [String: Any] ?? [:]
                let title = extractNotionTitle(from: props)
                let note = QuickNote(body: title.isEmpty ? "Notion страница" : title, title: title)
                modelContext.insert(note)
                count += 1
            }
            try? modelContext.save()
            importResult = "Импортировано \(count) страниц из Notion"
        } catch {
            importError = error.localizedDescription
        }
        isImportingNotion = false
    }

    private func extractNotionTitle(from props: [String: Any]) -> String {
        for (_, value) in props {
            guard let prop = value as? [String: Any],
                  let titleArr = prop["title"] as? [[String: Any]],
                  let first = titleArr.first,
                  let text = (first["text"] as? [String: Any])?["content"] as? String
            else { continue }
            return text
        }
        return ""
    }
}
