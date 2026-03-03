import Foundation
import SwiftData

// MARK: - Airtable REST client
// Table: "Project management 2026" (tbln9PpniXqz43sTj)
// Base:  appyzFVX3fyUhi24q

@MainActor
final class AirtableService: ObservableObject {
    static let shared = AirtableService()

    @Published var isSyncing = false
    @Published var lastSyncDate: Date?
    @Published var lastError: String?
    @Published var syncHistory: [AirtableSyncRunLog] = []

    // Таблица для синхронизации задач
    static let taskTable = "Project management 2026"

    private var apiKey: String { KeychainHelper.load(KeychainKey.airtableAPIKey) ?? "" }
    private var baseId: String { KeychainHelper.load(KeychainKey.airtableBaseId) ?? "" }

    private let baseURL = "https://api.airtable.com/v0"

    private let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private init() {}

    // MARK: - Mapping: Airtable fields ↔ TaskItem

    /// Airtable field names (точно как в таблице)
    private enum F {
        static let title          = "Кратко о задаче"
        static let priority       = "Приоритетность"
        static let projects       = "Проект"
        static let direction      = "Направление"
        static let description    = "Описание задачи"
        static let result         = "Результат выполнения задачи "
        static let resources      = "Используемые ресурсы "
        static let status         = "Статус"
        static let responsible    = "Ответственный"
        static let createdAt      = "Дата создания"
        static let startDate      = "Дата начала работы"
        static let midCheck       = "Дата промежуточной проверки прогресса"
        static let deadline       = "Deadline"
        static let monthlyResults = "Результаты за месяц "
        static let tagged         = "Тегнул по задаче"
        static let link           = "ссылка"
        static let toMeeting      = "Вынести на звонок"
        static let top1           = "ТОП1"
        static let completion     = "Готовность в %"
        static let opType         = "Операционка \\ Развитие "
    }

    // MARK: - Pull: Airtable → SwiftData

    /// Загружает все записи из Airtable и возвращает массив полей
    func pullTasks() async throws -> [AirtableRecord] {
        let records = try await fetchRecords(table: Self.taskTable)
        return records.compactMap { AirtableRecord(json: $0) }
    }

    /// Применяет данные из Airtable к TaskItem
    func applyRecord(_ rec: AirtableRecord, to task: TaskItem) {
        task.title          = rec.title
        task.notes          = rec.description
        task.taskResult     = rec.result
        task.resourcesUsed  = rec.resources
        task.monthlyResults = rec.monthlyResults
        task.linkURL        = rec.link

        task.priorityRaw    = rec.priority
        task.statusRaw      = rec.status
        task.completionPercent = rec.completion
        task.taggedOnTask   = rec.tagged

        task.airtableProjects = rec.projects
        task.directionRaw   = rec.direction
        task.typeRaw        = rec.opType
        task.responsibles   = rec.responsibles

        task.startDate      = rec.startDate
        task.midCheckDate   = rec.midCheckDate
        task.deadline       = rec.deadline

        task.bringToMeetingRaw = rec.toMeeting
        task.top1Raw        = rec.top1

        task.airtableId     = rec.id
        task.airtableUpdatedAt = Date()
    }

    // MARK: - Push: SwiftData → Airtable

    func pushTask(_ task: TaskItem) async throws {
        let fields = buildFields(from: task)
        if task.airtableId.isEmpty {
            // CREATE
            let newId = try await createRecord(table: Self.taskTable, fields: fields)
            task.airtableId = newId
            task.airtableUpdatedAt = Date()
        } else {
            // UPDATE
            try await updateRecord(table: Self.taskTable, recordId: task.airtableId, fields: fields)
            task.airtableUpdatedAt = Date()
        }
    }

    private func buildFields(from task: TaskItem) -> [String: Any] {
        var f: [String: Any] = [:]
        f[F.title]          = task.title
        f[F.priority]       = task.priorityRaw
        f[F.projects]       = task.airtableProjects
        f[F.direction]      = task.directionRaw.isEmpty ? NSNull() : task.directionRaw
        f[F.description]    = task.notes.isEmpty ? NSNull() : task.notes
        f[F.result]         = task.taskResult.isEmpty ? NSNull() : task.taskResult
        f[F.resources]      = task.resourcesUsed.isEmpty ? NSNull() : task.resourcesUsed
        f[F.status]         = task.statusRaw
        f[F.responsible]    = task.responsibles
        f[F.monthlyResults] = task.monthlyResults.isEmpty ? NSNull() : task.monthlyResults
        f[F.tagged]         = task.taggedOnTask
        f[F.link]           = task.linkURL.isEmpty ? NSNull() : task.linkURL
        f[F.toMeeting]      = task.bringToMeetingRaw.isEmpty ? NSNull() : task.bringToMeetingRaw
        f[F.top1]           = task.top1Raw.isEmpty ? NSNull() : task.top1Raw
        f[F.completion]     = task.completionPercent
        f[F.opType]         = task.typeRaw.isEmpty ? NSNull() : task.typeRaw

        if let d = task.startDate   { f[F.startDate]  = iso8601.string(from: d) }
        if let d = task.midCheckDate { f[F.midCheck]  = iso8601.string(from: d) }
        if let d = task.deadline    { f[F.deadline]   = iso8601.string(from: d) }

        return f
    }

    // MARK: - Full bidirectional sync

    func syncAll(tasks: [TaskItem], modelContext: Any) async throws -> SyncResult {
        isSyncing = true
        defer { isSyncing = false }

        var result = SyncResult()

        let records = try await pullTasks()
        let recordById = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let taskByAirtableId = Dictionary(uniqueKeysWithValues: tasks.filter { !$0.airtableId.isEmpty }.map { ($0.airtableId, $0) })

        // 1. Airtable → app (новые и обновлённые)
        for rec in records {
            if let existing = taskByAirtableId[rec.id] {
                // Обновляем если Airtable новее
                let localDate = existing.airtableUpdatedAt ?? .distantPast
                if rec.modifiedAt > localDate {
                    applyRecord(rec, to: existing)
                    result.updated += 1
                }
            } else {
                // Запись есть в Airtable, нет локально — отмечаем как новую
                result.newFromAirtable.append(rec)
            }
        }

        // 2. App → Airtable (задачи без airtableId или изменённые после последней синхр.)
        for task in tasks {
            if task.airtableId.isEmpty {
                try await pushTask(task)
                result.pushed += 1
            } else if recordById[task.airtableId] == nil {
                // Записи нет в Airtable — удалена там, удалим и у нас?
                // Пока просто считаем
                result.missingInAirtable += 1
            }
        }

        lastSyncDate = Date()
        return result
    }

    // MARK: - Safe sync planning

    func buildSyncPlan(localTasks: [TaskItem]) async throws -> AirtableSyncPlan {
        let records = try await pullTasks()
        let recordById = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let taskByAirtableId = Dictionary(
            uniqueKeysWithValues: localTasks.filter { !$0.airtableId.isEmpty }.map { ($0.airtableId, $0) }
        )

        var actions: [AirtableSyncAction] = []

        // Airtable -> local
        for rec in records {
            if let task = taskByAirtableId[rec.id] {
                guard !isEquivalent(task: task, record: rec) else { continue }
                let localStamp = task.airtableUpdatedAt ?? .distantPast
                let remoteStamp = rec.modifiedAt
                if remoteStamp.timeIntervalSince(localStamp) > 1 {
                    actions.append(
                        AirtableSyncAction(
                            type: .updateLocal,
                            airtableId: rec.id,
                            localTaskId: task.id,
                            title: rec.title,
                            reason: "Airtable версия новее локальной",
                            remoteRecord: rec
                        )
                    )
                } else if localStamp.timeIntervalSince(remoteStamp) > 1 {
                    actions.append(
                        AirtableSyncAction(
                            type: .updateRemote,
                            airtableId: rec.id,
                            localTaskId: task.id,
                            title: task.title,
                            reason: "Локальная версия новее Airtable",
                            remoteRecord: nil
                        )
                    )
                } else {
                    actions.append(
                        AirtableSyncAction(
                            type: .conflict,
                            airtableId: rec.id,
                            localTaskId: task.id,
                            title: rec.title,
                            reason: "Изменения с обеих сторон, нужен выбор стратегии",
                            remoteRecord: rec
                        )
                    )
                }
            } else {
                actions.append(
                    AirtableSyncAction(
                        type: .createLocal,
                        airtableId: rec.id,
                        localTaskId: nil,
                        title: rec.title,
                        reason: "Новая запись из Airtable",
                        remoteRecord: rec
                    )
                )
            }
        }

        // Local -> Airtable
        for task in localTasks {
            if task.airtableId.isEmpty {
                actions.append(
                    AirtableSyncAction(
                        type: .createRemote,
                        airtableId: "",
                        localTaskId: task.id,
                        title: task.title,
                        reason: "Новая локальная задача без airtableId",
                        remoteRecord: nil
                    )
                )
            } else if recordById[task.airtableId] == nil {
                actions.append(
                    AirtableSyncAction(
                        type: .missingInAirtable,
                        airtableId: task.airtableId,
                        localTaskId: task.id,
                        title: task.title,
                        reason: "Локальная задача ссылается на удалённую/недоступную запись Airtable",
                        remoteRecord: nil
                    )
                )
            }
        }

        return AirtableSyncPlan(createdAt: Date(), actions: actions)
    }

    @MainActor
    func executeSyncPlan(
        _ plan: AirtableSyncPlan,
        localTasks: [TaskItem],
        modelContext: ModelContext,
        dryRun: Bool,
        conflictResolution: AirtableConflictResolution = .skip
    ) async throws -> AirtableSyncExecutionResult {
        let startedAt = Date()
        var result = AirtableSyncExecutionResult()
        let localById = Dictionary(uniqueKeysWithValues: localTasks.map { ($0.id, $0) })

        for action in plan.actions {
            if dryRun {
                result.totalPlanned += 1
                switch action.type {
                case .createLocal: result.willCreateLocal += 1
                case .updateLocal: result.willUpdateLocal += 1
                case .createRemote: result.willCreateRemote += 1
                case .updateRemote: result.willUpdateRemote += 1
                case .conflict: result.conflicts += 1
                case .missingInAirtable: result.missingInAirtable += 1
                }
                continue
            }

            do {
                switch action.type {
                case .createLocal:
                    guard let rec = action.remoteRecord else { continue }
                    let task = TaskItem(title: rec.title)
                    modelContext.insert(task)
                    applyRecord(rec, to: task)
                    result.createdLocal += 1

                case .updateLocal:
                    guard let id = action.localTaskId, let task = localById[id], let rec = action.remoteRecord else { continue }
                    applyRecord(rec, to: task)
                    result.updatedLocal += 1

                case .createRemote:
                    guard let id = action.localTaskId, let task = localById[id] else { continue }
                    try await pushTask(task)
                    result.createdRemote += 1

                case .updateRemote:
                    guard let id = action.localTaskId, let task = localById[id] else { continue }
                    try await pushTask(task)
                    result.updatedRemote += 1

                case .conflict:
                    guard let id = action.localTaskId, let task = localById[id], let rec = action.remoteRecord else {
                        result.skipped += 1
                        continue
                    }
                    switch conflictResolution {
                    case .preferRemote:
                        applyRecord(rec, to: task)
                        result.resolvedConflicts += 1
                    case .preferLocal:
                        try await pushTask(task)
                        result.resolvedConflicts += 1
                    case .skip:
                        result.skipped += 1
                    }

                case .missingInAirtable:
                    result.missingInAirtable += 1
                }
            } catch {
                result.errors.append("`\(action.title)`: \(error.localizedDescription)")
            }
        }

        if !dryRun {
            do {
                try modelContext.save()
            } catch {
                result.errors.append("Ошибка сохранения локальной БД: \(error.localizedDescription)")
                appendSyncLog(
                    mode: .apply,
                    conflictResolution: conflictResolution,
                    startedAt: startedAt,
                    plan: plan,
                    result: result
                )
                throw error
            }
            lastSyncDate = Date()
        }
        appendSyncLog(
            mode: dryRun ? .dryRun : .apply,
            conflictResolution: conflictResolution,
            startedAt: startedAt,
            plan: plan,
            result: result
        )
        return result
    }

    // MARK: - Generic CRUD

    func fetchRecords(table: String) async throws -> [[String: Any]] {
        guard !apiKey.isEmpty, !baseId.isEmpty else { throw AirtableError.notConfigured }

        var allRecords: [[String: Any]] = []
        var offset: String? = nil

        repeat {
            var urlStr = "\(baseURL)/\(baseId)/\(encoded(table))?pageSize=100"
            if let off = offset {
                let encodedOffset = off.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? off
                urlStr += "&offset=\(encodedOffset)"
            }

            guard let url = URL(string: urlStr) else { throw AirtableError.invalidURL }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

            let data = try await send(req)

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            allRecords.append(contentsOf: json?["records"] as? [[String: Any]] ?? [])
            offset = json?["offset"] as? String
        } while offset != nil

        return allRecords
    }

    func createRecord(table: String, fields: [String: Any]) async throws -> String {
        guard !apiKey.isEmpty, !baseId.isEmpty else { throw AirtableError.notConfigured }
        guard let url = URL(string: "\(baseURL)/\(baseId)/\(encoded(table))") else {
            throw AirtableError.invalidURL
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["fields": fields])

        let data = try await send(req)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let id = (json?["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !id.isEmpty else {
            throw AirtableError.apiError("Airtable create вернул пустой id")
        }
        return id
    }

    func updateRecord(table: String, recordId: String, fields: [String: Any]) async throws {
        guard !apiKey.isEmpty, !baseId.isEmpty else { throw AirtableError.notConfigured }
        guard let url = URL(string: "\(baseURL)/\(baseId)/\(encoded(table))/\(recordId)") else {
            throw AirtableError.invalidURL
        }

        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["fields": fields])

        _ = try await send(req)
    }

    func deleteRecord(table: String, recordId: String) async throws {
        guard !apiKey.isEmpty, !baseId.isEmpty else { throw AirtableError.notConfigured }
        guard let url = URL(string: "\(baseURL)/\(baseId)/\(encoded(table))/\(recordId)") else {
            throw AirtableError.invalidURL
        }

        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        _ = try await send(req)
    }

    // MARK: - Validation

    func validateConnection() async throws {
        guard !apiKey.isEmpty, !baseId.isEmpty else { throw AirtableError.notConfigured }
        let url = URL(string: "\(baseURL)/meta/bases/\(baseId)/tables")!
        var req = URLRequest(url: url)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        _ = try await send(req)
    }

    // MARK: - Helpers

    private func encoded(_ table: String) -> String {
        table.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? table
    }

    private func send(_ request: URLRequest, maxRetries: Int = 3) async throws -> Data {
        var attempt = 0
        while true {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { return data }

                if shouldRetry(http.statusCode), attempt < maxRetries {
                    attempt += 1
                    let delay = retryDelaySeconds(from: http, attempt: attempt)
                    try await Task.sleep(for: .seconds(delay))
                    continue
                }

                try checkStatus(http, data)
                return data
            } catch {
                if attempt < maxRetries {
                    attempt += 1
                    try await Task.sleep(for: .seconds(Double(attempt)))
                    continue
                }
                throw error
            }
        }
    }

    private func checkStatus(_ response: HTTPURLResponse, _ data: Data) throws {
        guard (200..<300).contains(response.statusCode) else {
            throw AirtableError.apiError(parseErrorMessage(data: data, statusCode: response.statusCode))
        }
        if let err = parseEmbeddedError(data: data) {
            throw AirtableError.apiError(err)
        }
    }

    private func parseErrorMessage(data: Data, statusCode: Int) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any] {
            let type = error["type"] as? String ?? "api_error"
            let message = error["message"] as? String ?? "HTTP \(statusCode)"
            return "[\(type)] \(message)"
        }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? "HTTP \(statusCode)" : text
    }

    private func parseEmbeddedError(data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let error = json["error"] as? [String: Any] else { return nil }
        let type = error["type"] as? String ?? "api_error"
        let message = error["message"] as? String ?? "Ошибка Airtable"
        return "[\(type)] \(message)"
    }

    private func shouldRetry(_ statusCode: Int) -> Bool {
        statusCode == 429 || (500...599).contains(statusCode)
    }

    private func retryDelaySeconds(from response: HTTPURLResponse, attempt: Int) -> Double {
        if let retryAfter = response.value(forHTTPHeaderField: "Retry-After"), let sec = Double(retryAfter) {
            return max(1, sec)
        }
        return min(pow(2, Double(attempt)), 8)
    }

    private func isEquivalent(task: TaskItem, record: AirtableRecord) -> Bool {
        if task.title != record.title { return false }
        if task.notes != record.description { return false }
        if task.taskResult != record.result { return false }
        if task.resourcesUsed != record.resources { return false }
        if task.monthlyResults != record.monthlyResults { return false }
        if task.linkURL != record.link { return false }
        if task.priorityRaw != record.priority { return false }
        if task.statusRaw != record.status { return false }
        if task.completionPercent != record.completion { return false }
        if task.taggedOnTask != record.tagged { return false }
        if task.airtableProjects != record.projects { return false }
        if task.directionRaw != record.direction { return false }
        if task.typeRaw != record.opType { return false }
        if task.responsibles != record.responsibles { return false }
        if task.bringToMeetingRaw != record.toMeeting { return false }
        if task.top1Raw != record.top1 { return false }
        if !datesEqual(task.startDate, record.startDate) { return false }
        if !datesEqual(task.midCheckDate, record.midCheckDate) { return false }
        if !datesEqual(task.deadline, record.deadline) { return false }
        return true
    }

    private func datesEqual(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (l?, r?):
            return abs(l.timeIntervalSince1970 - r.timeIntervalSince1970) < 1
        default:
            return false
        }
    }

    private func appendSyncLog(
        mode: AirtableSyncRunMode,
        conflictResolution: AirtableConflictResolution,
        startedAt: Date,
        plan: AirtableSyncPlan,
        result: AirtableSyncExecutionResult
    ) {
        let entry = AirtableSyncRunLog(
            timestamp: startedAt,
            mode: mode,
            conflictResolution: conflictResolution,
            plannedActions: plan.actions.count,
            createLocalPlanned: plan.createLocalCount,
            updateLocalPlanned: plan.updateLocalCount,
            createRemotePlanned: plan.createRemoteCount,
            updateRemotePlanned: plan.updateRemoteCount,
            conflictsPlanned: plan.conflictCount,
            missingPlanned: plan.missingCount,
            createdLocal: result.createdLocal,
            updatedLocal: result.updatedLocal,
            createdRemote: result.createdRemote,
            updatedRemote: result.updatedRemote,
            resolvedConflicts: result.resolvedConflicts,
            skipped: result.skipped,
            errorsCount: result.errors.count,
            errorsPreview: result.errors.prefix(3).joined(separator: " | ")
        )
        syncHistory.insert(entry, at: 0)
        if syncHistory.count > 40 {
            syncHistory = Array(syncHistory.prefix(40))
        }
    }

    // MARK: - Legacy import

    func importAsNotes(table: String, titleField: String, bodyField: String) async throws -> Int {
        let records = try await fetchRecords(table: table)
        return records.count
    }

    // MARK: - Sync history export

    func exportSyncHistoryJSON() throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(syncHistory)
        let url = try exportFileURL(extension: "json")
        try data.write(to: url, options: .atomic)
        return url
    }

    func exportSyncHistoryCSV() throws -> URL {
        var lines: [String] = []
        lines.append("timestamp,mode,conflictResolution,plannedActions,createLocalPlanned,updateLocalPlanned,createRemotePlanned,updateRemotePlanned,conflictsPlanned,missingPlanned,createdLocal,updatedLocal,createdRemote,updatedRemote,resolvedConflicts,skipped,errorsCount,errorsPreview")

        let formatter = ISO8601DateFormatter()
        for entry in syncHistory {
            let values: [String] = [
                formatter.string(from: entry.timestamp),
                entry.mode.rawValue,
                entry.conflictResolution.rawValue,
                "\(entry.plannedActions)",
                "\(entry.createLocalPlanned)",
                "\(entry.updateLocalPlanned)",
                "\(entry.createRemotePlanned)",
                "\(entry.updateRemotePlanned)",
                "\(entry.conflictsPlanned)",
                "\(entry.missingPlanned)",
                "\(entry.createdLocal)",
                "\(entry.updatedLocal)",
                "\(entry.createdRemote)",
                "\(entry.updatedRemote)",
                "\(entry.resolvedConflicts)",
                "\(entry.skipped)",
                "\(entry.errorsCount)",
                entry.errorsPreview
            ]
            lines.append(values.map(csvEscape).joined(separator: ","))
        }

        let url = try exportFileURL(extension: "csv")
        guard let data = lines.joined(separator: "\n").data(using: .utf8) else {
            throw AirtableError.apiError("Не удалось сформировать CSV")
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    private func exportFileURL(extension ext: String) throws -> URL {
        let fm = FileManager.default
        let root = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let baseURL = root else {
            throw AirtableError.apiError("Не удалось определить папку для экспорта")
        }
        let timestamp = Self.exportTimestampFormatter.string(from: Date())
        return baseURL.appendingPathComponent("airtable-sync-history-\(timestamp).\(ext)")
    }

    private func csvEscape(_ value: String) -> String {
        let normalized = value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let escaped = normalized.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private static let exportTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}

// MARK: - AirtableRecord (typed parsed record)

struct AirtableRecord {
    let id: String
    let modifiedAt: Date

    let title: String
    let priority: Int
    let projects: [String]
    let direction: String
    let description: String
    let result: String
    let resources: String
    let status: String
    let responsibles: [String]
    let startDate: Date?
    let midCheckDate: Date?
    let deadline: Date?
    let monthlyResults: String
    let tagged: Bool
    let link: String
    let toMeeting: String
    let top1: String
    let completion: Int
    let opType: String

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String else { return nil }
        self.id = id

        let f = json["fields"] as? [String: Any] ?? [:]
        self.modifiedAt = Self.resolveModifiedAt(from: json, fields: f)

        self.title          = f["Кратко о задаче"] as? String ?? ""
        self.priority       = f["Приоритетность"] as? Int ?? 0
        self.projects       = (f["Проект"] as? [String]) ?? []
        self.direction      = f["Направление"] as? String ?? ""
        self.description    = f["Описание задачи"] as? String ?? ""
        self.result         = f["Результат выполнения задачи "] as? String ?? ""
        self.resources      = f["Используемые ресурсы "] as? String ?? ""
        self.status         = f["Статус"] as? String ?? TaskStatus.todo.rawValue
        self.responsibles   = (f["Ответственный"] as? [String]) ?? []
        self.monthlyResults = f["Результаты за месяц "] as? String ?? ""
        self.tagged         = f["Тегнул по задаче"] as? Bool ?? false
        self.link           = f["ссылка"] as? String ?? ""
        self.toMeeting      = f["Вынести на звонок"] as? String ?? ""
        self.top1           = f["ТОП1"] as? String ?? ""
        self.completion     = f["Готовность в %"] as? Int ?? 0
        self.opType         = f["Операционка \\ Развитие "] as? String ?? ""

        func parseDate(_ key: String) -> Date? {
            guard let s = f[key] as? String else { return nil }
            return Self.iso.date(from: s)
        }
        self.startDate    = parseDate("Дата начала работы")
        self.midCheckDate = parseDate("Дата промежуточной проверки прогресса")
        self.deadline     = parseDate("Deadline")
    }

    private static func parseISO(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return iso.date(from: raw) ?? isoNoFraction.date(from: raw)
    }

    private static func resolveModifiedAt(from json: [String: Any], fields: [String: Any]) -> Date {
        let candidateFieldKeys = [
            "Last modified time",
            "Last Modified",
            "Last modified",
            "Дата изменения",
            "Последнее изменение"
        ]

        for key in candidateFieldKeys {
            if let raw = fields[key] as? String, let d = parseISO(raw) {
                return d
            }
        }

        if let d = parseISO(json["modifiedAt"] as? String) { return d }
        if let d = parseISO(json["createdTime"] as? String) { return d }
        return .distantPast
    }
}

// MARK: - SyncResult

struct SyncResult {
    var updated = 0
    var pushed = 0
    var missingInAirtable = 0
    var newFromAirtable: [AirtableRecord] = []

    var summary: String {
        "↓ обновлено: \(updated), ↑ отправлено: \(pushed), новых из Airtable: \(newFromAirtable.count)"
    }
}

enum AirtableSyncActionType: String {
    case createLocal
    case updateLocal
    case createRemote
    case updateRemote
    case conflict
    case missingInAirtable
}

enum AirtableConflictResolution: String, CaseIterable, Identifiable, Encodable {
    case preferRemote
    case preferLocal
    case skip

    var id: String { rawValue }

    var title: String {
        switch self {
        case .preferRemote: return "Предпочесть Airtable"
        case .preferLocal: return "Предпочесть локальные"
        case .skip: return "Пропускать конфликты"
        }
    }
}

struct AirtableSyncAction: Identifiable {
    let id = UUID()
    let type: AirtableSyncActionType
    let airtableId: String
    let localTaskId: UUID?
    let title: String
    let reason: String
    let remoteRecord: AirtableRecord?
}

struct AirtableSyncPlan {
    let createdAt: Date
    let actions: [AirtableSyncAction]

    var createLocalCount: Int { actions.filter { $0.type == .createLocal }.count }
    var updateLocalCount: Int { actions.filter { $0.type == .updateLocal }.count }
    var createRemoteCount: Int { actions.filter { $0.type == .createRemote }.count }
    var updateRemoteCount: Int { actions.filter { $0.type == .updateRemote }.count }
    var conflictCount: Int { actions.filter { $0.type == .conflict }.count }
    var missingCount: Int { actions.filter { $0.type == .missingInAirtable }.count }
}

struct AirtableSyncExecutionResult {
    var totalPlanned = 0

    var willCreateLocal = 0
    var willUpdateLocal = 0
    var willCreateRemote = 0
    var willUpdateRemote = 0

    var createdLocal = 0
    var updatedLocal = 0
    var createdRemote = 0
    var updatedRemote = 0

    var conflicts = 0
    var resolvedConflicts = 0
    var missingInAirtable = 0
    var skipped = 0
    var errors: [String] = []

    var summary: String {
        if totalPlanned > 0 {
            return "План: локально +\(willCreateLocal)/~\(willUpdateLocal), Airtable +\(willCreateRemote)/~\(willUpdateRemote), конфликтов: \(conflicts)"
        }
        return "Применено: локально +\(createdLocal)/~\(updatedLocal), Airtable +\(createdRemote)/~\(updatedRemote), решено конфликтов: \(resolvedConflicts), ошибок: \(errors.count)"
    }
}

enum AirtableSyncRunMode: String, Encodable {
    case dryRun
    case apply
}

struct AirtableSyncRunLog: Identifiable, Encodable {
    let id = UUID()
    let timestamp: Date
    let mode: AirtableSyncRunMode
    let conflictResolution: AirtableConflictResolution

    let plannedActions: Int
    let createLocalPlanned: Int
    let updateLocalPlanned: Int
    let createRemotePlanned: Int
    let updateRemotePlanned: Int
    let conflictsPlanned: Int
    let missingPlanned: Int

    let createdLocal: Int
    let updatedLocal: Int
    let createdRemote: Int
    let updatedRemote: Int
    let resolvedConflicts: Int
    let skipped: Int
    let errorsCount: Int
    let errorsPreview: String

    var modeTitle: String {
        mode == .dryRun ? "Dry Run" : "Apply"
    }
}

// MARK: - AirtableError

enum AirtableError: LocalizedError {
    case notConfigured
    case invalidURL
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:  return "Airtable не настроен. Укажите API ключ и Base ID в Настройках."
        case .invalidURL:     return "Неверный URL"
        case .apiError(let m): return m
        }
    }
}
