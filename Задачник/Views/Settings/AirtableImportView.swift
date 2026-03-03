import SwiftUI
import SwiftData

struct AirtableImportView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TaskItem.createdAt) private var existingTasks: [TaskItem]

    @State private var records: [AirtableRecord] = []
    @State private var isLoading = false
    @State private var loadError: String? = nil
    @State private var isImporting = false
    @State private var importDone = false
    @State private var importCount = 0
    @State private var selectedRecordIds: Set<String> = []
    @State private var searchText = ""
    @State private var filterStatus: String = "Все"
    @State private var syncPlan: AirtableSyncPlan?
    @State private var syncResultText: String?
    @State private var syncError: String?
    @State private var isPlanningSync = false
    @State private var isApplyingSync = false
    @State private var conflictResolution: AirtableConflictResolution = .skip
    @State private var exportInfo: String?

    @ObservedObject private var airtable = AirtableService.shared

    private var filteredRecords: [AirtableRecord] {
        var result = records
        if filterStatus != "Все" {
            result = result.filter { $0.status == filterStatus }
        }
        if !searchText.isEmpty {
            result = result.filter {
                $0.title.localizedCaseInsensitiveContains(searchText) ||
                $0.projects.joined().localizedCaseInsensitiveContains(searchText)
            }
        }
        return result
    }

    private var groupedRecords: [(key: String, value: [AirtableRecord])] {
        let grouped = Dictionary(grouping: filteredRecords) { rec in
            rec.projects.first ?? "Без проекта"
        }
        return grouped.sorted { $0.key < $1.key }
    }

    private var allStatuses: [String] {
        let s = Set(records.map { $0.status }).filter { !$0.isEmpty }
        return ["Все"] + s.sorted()
    }

    private var existingAirtableIds: Set<String> {
        Set(existingTasks.map { $0.airtableId }.filter { !$0.isEmpty })
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    loadingView
                } else if let err = loadError {
                    errorView(err)
                } else if records.isEmpty {
                    emptyView
                } else {
                    contentView
                }
            }
            .navigationTitle("Импорт из Airtable")
            .navigationInline()
            .toolbar { toolbarContent }
            .searchable(text: $searchText, prompt: "Поиск задач...")
            .task { await loadRecords() }
        }
    }

    // MARK: - Content

    private var contentView: some View {
        List {
            safeSyncSection
            syncHistorySection

            // Stats banner
            statsBanner

            // Status filter
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(allStatuses, id: \.self) { s in
                            FilterChip(label: s, isSelected: filterStatus == s) {
                                filterStatus = s
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
                }
                .listRowInsets(.init(top: 0, leading: 12, bottom: 0, trailing: 12))
                .listRowBackground(Color.clear)
            }

            // Records grouped by project
            ForEach(groupedRecords, id: \.key) { group in
                Section {
                    ForEach(group.value, id: \.id) { rec in
                        RecordRow(
                            record: rec,
                            isSelected: selectedRecordIds.contains(rec.id),
                            isAlreadyImported: existingAirtableIds.contains(rec.id)
                        ) {
                            toggleSelection(rec.id)
                        }
                    }
                } header: {
                    HStack {
                        Label(group.key, systemImage: "folder.fill")
                            .font(.subheadline).fontWeight(.semibold)
                        Spacer()
                        Text("\(group.value.count)")
                            .font(.caption).foregroundStyle(.secondary)
                        Button {
                            toggleGroup(group.value)
                        } label: {
                            Text(groupAllSelected(group.value) ? "Снять" : "Выбрать")
                                .font(.caption).foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.inset)
        .overlay(alignment: .bottom) {
            if !selectedRecordIds.isEmpty {
                importBar
            }
        }
    }

    private var safeSyncSection: some View {
        Section("Безопасная синхронизация") {
            HStack(spacing: 12) {
                Button {
                    Task { await runDryRun() }
                } label: {
                    if isPlanningSync {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Dry Run", systemImage: "doc.text.magnifyingglass")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isPlanningSync || isApplyingSync)

                Button {
                    Task { await applySyncPlan() }
                } label: {
                    if isApplyingSync {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Применить", systemImage: "arrow.triangle.2.circlepath.circle.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isPlanningSync || isApplyingSync)

                Spacer()
            }

            Picker("Конфликты", selection: $conflictResolution) {
                ForEach(AirtableConflictResolution.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if let plan = syncPlan {
                HStack(spacing: 12) {
                    Label("Локально +\(plan.createLocalCount)", systemImage: "tray.and.arrow.down")
                    Label("Локально ~\(plan.updateLocalCount)", systemImage: "square.and.pencil")
                    Label("Airtable +\(plan.createRemoteCount)", systemImage: "tray.and.arrow.up")
                    Label("Airtable ~\(plan.updateRemoteCount)", systemImage: "icloud.and.arrow.up")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Label("Конфликты: \(plan.conflictCount)", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(plan.conflictCount > 0 ? .orange : .secondary)
                    Label("Missing: \(plan.missingCount)", systemImage: "questionmark.circle")
                        .foregroundStyle(plan.missingCount > 0 ? .red : .secondary)
                }
                .font(.caption)

                ForEach(Array(plan.actions.prefix(15))) { action in
                    HStack(alignment: .top, spacing: 8) {
                        Text(actionBadge(action.type))
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(actionColor(action.type).opacity(0.15), in: Capsule())
                            .foregroundStyle(actionColor(action.type))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(action.title.isEmpty ? "Без названия" : action.title)
                                .font(.caption)
                            Text(action.reason)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if plan.actions.count > 15 {
                    Text("...и ещё \(plan.actions.count - 15) действий")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let syncResultText {
                Text(syncResultText)
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if let syncError {
                Text(syncError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var syncHistorySection: some View {
        Section("Журнал синков") {
            HStack(spacing: 10) {
                Button {
                    exportSyncHistoryJSON()
                } label: {
                    Label("Экспорт JSON", systemImage: "doc.badge.arrow.up")
                }
                .buttonStyle(.bordered)

                Button {
                    exportSyncHistoryCSV()
                } label: {
                    Label("Экспорт CSV", systemImage: "tablecells.badge.ellipsis")
                }
                .buttonStyle(.bordered)

                Spacer()
            }

            if let exportInfo {
                Text(exportInfo)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if airtable.syncHistory.isEmpty {
                Text("Пока нет запусков синхронизации")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(airtable.syncHistory.prefix(10))) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.modeTitle)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(entry.mode == .dryRun ? Color.orange.opacity(0.15) : Color.green.opacity(0.15), in: Capsule())
                            Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if entry.errorsCount > 0 {
                                Label("\(entry.errorsCount)", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                            }
                        }

                        Text("Plan \(entry.plannedActions): L+\(entry.createLocalPlanned) L~\(entry.updateLocalPlanned) A+\(entry.createRemotePlanned) A~\(entry.updateRemotePlanned) !\(entry.conflictsPlanned) ?\(entry.missingPlanned)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        if entry.mode == .apply {
                            Text("Apply: L+\(entry.createdLocal) L~\(entry.updatedLocal) A+\(entry.createdRemote) A~\(entry.updatedRemote) resolved:\(entry.resolvedConflicts) skipped:\(entry.skipped)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Text("Conflict mode: \(entry.conflictResolution.title)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        if !entry.errorsPreview.isEmpty {
                            Text(entry.errorsPreview)
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var statsBanner: some View {
        Section {
            HStack(spacing: 0) {
                StatCell(value: records.count, label: "Всего", color: .blue)
                Divider()
                StatCell(
                    value: records.filter { $0.status == "В работе" }.count,
                    label: "В работе",
                    color: .orange
                )
                Divider()
                StatCell(
                    value: records.filter { $0.status == "Готово" }.count,
                    label: "Готово",
                    color: .green
                )
                Divider()
                StatCell(
                    value: existingAirtableIds.count,
                    label: "Уже в приложении",
                    color: .secondary
                )
            }
            .frame(maxWidth: .infinity)
        }
        .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
    }

    private var importBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Выбрано: \(selectedRecordIds.count)")
                        .fontWeight(.semibold)
                    let alreadyCount = selectedRecordIds.filter { existingAirtableIds.contains($0) }.count
                    if alreadyCount > 0 {
                        Text("\(alreadyCount) уже в приложении — будут обновлены")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    Task { await importSelected() }
                } label: {
                    if isImporting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Импортировать", systemImage: "square.and.arrow.down.fill")
                            .fontWeight(.semibold)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isImporting)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }

    // MARK: - States

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Загрузка из Airtable...")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ err: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Ошибка загрузки")
                .font(.headline)
            Text(err)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Повторить") {
                Task { await loadRecords() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "table.badge.more")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Нет записей")
                .font(.headline)
            Text("Таблица «Project management 2026» пуста или не настроен API ключ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Menu {
                Button {
                    selectedRecordIds = Set(filteredRecords.map { $0.id })
                } label: {
                    Label("Выбрать все", systemImage: "checkmark.circle")
                }
                Button {
                    selectedRecordIds.removeAll()
                } label: {
                    Label("Снять всё", systemImage: "xmark.circle")
                }
                Divider()
                Button {
                    Task { await loadRecords() }
                } label: {
                    Label("Обновить", systemImage: "arrow.clockwise")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        if importDone {
            ToolbarItem(placement: .cancellationAction) {
                Label("Импортировано: \(importCount)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            }
        }
    }

    // MARK: - Actions

    private func loadRecords() async {
        isLoading = true
        loadError = nil
        syncError = nil
        do {
            records = try await airtable.pullTasks()
            // По умолчанию выбираем все, которых ещё нет в приложении
            selectedRecordIds = Set(records.filter { !existingAirtableIds.contains($0.id) }.map { $0.id })
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func importSelected() async {
        isImporting = true
        importCount = 0
        clearSyncMessages()
        let toImport = records.filter { selectedRecordIds.contains($0.id) }

        do {
            for rec in toImport {
                if let existing = existingTasks.first(where: { $0.airtableId == rec.id }) {
                    // Обновить существующую
                    airtable.applyRecord(rec, to: existing)
                    importCount += 1
                } else {
                    // Создать новую
                    let task = TaskItem(title: rec.title)
                    modelContext.insert(task)
                    airtable.applyRecord(rec, to: task)
                    importCount += 1
                }
            }

            try modelContext.save()
            importDone = true
            selectedRecordIds.removeAll()
        } catch {
            syncError = "Импорт не завершён: \(error.localizedDescription)"
            importDone = false
        }
        isImporting = false
    }

    private func runDryRun() async {
        isPlanningSync = true
        clearSyncMessages()
        do {
            let plan = try await airtable.buildSyncPlan(localTasks: existingTasks)
            syncPlan = plan
            let preview = try await airtable.executeSyncPlan(
                plan,
                localTasks: existingTasks,
                modelContext: modelContext,
                dryRun: true,
                conflictResolution: conflictResolution
            )
            syncResultText = preview.summary
        } catch {
            syncError = error.localizedDescription
        }
        isPlanningSync = false
    }

    private func applySyncPlan() async {
        isApplyingSync = true
        clearSyncMessages()
        do {
            let plan = try await airtable.buildSyncPlan(localTasks: existingTasks)
            syncPlan = plan
            let result = try await airtable.executeSyncPlan(
                plan,
                localTasks: existingTasks,
                modelContext: modelContext,
                dryRun: false,
                conflictResolution: conflictResolution
            )
            syncResultText = result.summary
            records = try await airtable.pullTasks()
        } catch {
            syncError = error.localizedDescription
        }
        isApplyingSync = false
    }

    private func actionBadge(_ type: AirtableSyncActionType) -> String {
        switch type {
        case .createLocal: return "L+"
        case .updateLocal: return "L~"
        case .createRemote: return "A+"
        case .updateRemote: return "A~"
        case .conflict: return "!"
        case .missingInAirtable: return "?"
        }
    }

    private func actionColor(_ type: AirtableSyncActionType) -> Color {
        switch type {
        case .createLocal, .updateLocal:
            return .blue
        case .createRemote, .updateRemote:
            return .indigo
        case .conflict:
            return .orange
        case .missingInAirtable:
            return .red
        }
    }

    private func exportSyncHistoryJSON() {
        clearSyncMessages()
        do {
            let url = try airtable.exportSyncHistoryJSON()
            exportInfo = "JSON экспортирован: \(url.path)"
            syncError = nil
        } catch {
            syncError = error.localizedDescription
        }
    }

    private func exportSyncHistoryCSV() {
        clearSyncMessages()
        do {
            let url = try airtable.exportSyncHistoryCSV()
            exportInfo = "CSV экспортирован: \(url.path)"
            syncError = nil
        } catch {
            syncError = error.localizedDescription
        }
    }

    private func clearSyncMessages() {
        syncResultText = nil
        syncError = nil
        exportInfo = nil
    }

    private func toggleSelection(_ id: String) {
        if selectedRecordIds.contains(id) {
            selectedRecordIds.remove(id)
        } else {
            selectedRecordIds.insert(id)
        }
    }

    private func toggleGroup(_ recs: [AirtableRecord]) {
        if groupAllSelected(recs) {
            recs.forEach { selectedRecordIds.remove($0.id) }
        } else {
            recs.forEach { selectedRecordIds.insert($0.id) }
        }
    }

    private func groupAllSelected(_ recs: [AirtableRecord]) -> Bool {
        recs.allSatisfy { selectedRecordIds.contains($0.id) }
    }
}

// MARK: - RecordRow

private struct RecordRow: View {
    let record: AirtableRecord
    let isSelected: Bool
    let isAlreadyImported: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                // Checkbox
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isSelected ? .blue : .secondary.opacity(0.5))
                    .animation(.spring(duration: 0.2), value: isSelected)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .top) {
                        Text(record.title.isEmpty ? "Без названия" : record.title)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 4)
                        if record.priority > 0 {
                            Text(String(repeating: "★", count: record.priority))
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }

                    // Description preview
                    if !record.description.isEmpty {
                        Text(record.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    HStack(spacing: 6) {
                        // Status badge
                        if !record.status.isEmpty {
                            StatusBadge(status: record.status)
                        }

                        // Deadline
                        if let d = record.deadline {
                            Label(d.shortLabel, systemImage: "calendar")
                                .font(.caption2)
                                .foregroundStyle(d < Date() ? .red : .secondary)
                        }

                        // Already imported badge
                        if isAlreadyImported {
                            Label("В приложении", systemImage: "checkmark")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }

                        if !record.responsibles.isEmpty {
                            Label(record.responsibles.joined(separator: ", "), systemImage: "person.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? Color.blue.opacity(0.06) : Color.clear)
    }
}

// MARK: - StatusBadge

private struct StatusBadge: View {
    let status: String

    private var color: Color {
        switch status {
        case "В работе":         return .blue
        case "Готово":           return .green
        case "Надо сделать":     return .secondary
        case "Заблокировано":    return .red
        case "На проверке":      return .orange
        default:                 return .secondary
        }
    }

    var body: some View {
        Text(status)
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}

// MARK: - FilterChip

private struct FilterChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(isSelected ? .white : .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.blue : Color.secondary.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .animation(.spring(duration: 0.2), value: isSelected)
    }
}

// MARK: - StatCell

private struct StatCell: View {
    let value: Int
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.title2).fontWeight(.bold)
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}
