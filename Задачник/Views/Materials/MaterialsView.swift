import SwiftUI
import SwiftData

struct MaterialsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \MaterialLink.createdAt, order: .reverse) private var materials: [MaterialLink]

    @State private var showAdd = false
    @State private var searchText = ""
    @State private var filterType: MaterialType? = nil

    private var filtered: [MaterialLink] {
        materials.filter { mat in
            let matchSearch = searchText.isEmpty
                || mat.title.localizedCaseInsensitiveContains(searchText)
                || mat.url.localizedCaseInsensitiveContains(searchText)
            let matchType = filterType == nil || mat.type == filterType
            return matchSearch && matchType
        }
    }

    var body: some View {
        Group {
            if materials.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    typeFilter
                    Divider()

                    List {
                        ForEach(filtered) { mat in
                            MaterialRowView(material: mat)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        modelContext.delete(mat)
                                        try? modelContext.save()
                                    } label: {
                                        Label("Удалить", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .adaptiveListStyle()
                    .searchable(text: $searchText, prompt: "Поиск материалов")
                }
            }
        }
        .navigationTitle("Материалы")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAdd = true } label: { Image(systemName: "plus") }
                .accessibilityLabel("Новый материал")
                .accessibilityHint("Открывает форму добавления материала")
            }
        }
        .sheet(isPresented: $showAdd) {
            AddMaterialView()
        }
    }

    private var typeFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(nil, label: "Все", icon: "square.grid.2x2")
                ForEach(MaterialType.allCases) { type in
                    filterChip(type, label: type.rawValue.capitalized, icon: type.icon)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func filterChip(_ type: MaterialType?, label: String, icon: String) -> some View {
        let isSelected = filterType == type
        return Button {
            if reduceMotion {
                filterType = filterType == type ? nil : type
            } else {
                withAnimation { filterType = filterType == type ? nil : type }
            }
        } label: {
            Label(label, systemImage: icon)
                .font(.caption)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(isSelected ? .white : .secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.blue : Color.secondary.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Фильтр материалов: \(label)")
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 56))
                .foregroundStyle(.blue.gradient)

            Text("Нет материалов")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Сохраняйте ссылки, файлы и заметки в одном месте")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button { showAdd = true } label: {
                Label("Добавить", systemImage: "plus")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Material Row

struct MaterialRowView: View {
    let material: MaterialLink

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: material.type.icon)
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 36, height: 36)
                .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(material.displayTitle)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(2)

                if material.type == .link {
                    Text(material.domain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !material.previewText.isEmpty {
                    Text(material.previewText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                // Tags
                if !material.tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(material.tags, id: \.self) { tag in
                                TagChip(tag: tag)
                            }
                        }
                    }
                }
            }

            Spacer()

            // Open link button
            if material.type == .link, let url = URL(string: material.url) {
                Link(destination: url) {
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Add Material

struct AddMaterialView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var title = ""
    @State private var previewText = ""
    @State private var type: MaterialType = .link
    @State private var tags: [String] = []
    @State private var isFetchingMeta = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Ссылка или описание") {
                    TextField("https://...", text: $urlText)
                        #if os(iOS)
                        .keyboardType(.URL)
                        #endif
                        .autocorrectionDisabled()
                        .onSubmit { fetchMetadata() }

                    if isFetchingMeta {
                        HStack {
                            ProgressView()
                            Text("Загрузка превью...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    TextField("Название", text: $title)
                    TextField("Описание", text: $previewText, axis: .vertical)
                        .lineLimit(1...4)
                }

                Section("Тип") {
                    Picker("Тип", selection: $type) {
                        ForEach(MaterialType.allCases) { t in
                            Label(t.rawValue.capitalized, systemImage: t.icon).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Теги") {
                    TagInputView(tags: $tags)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Добавить материал")
            .navigationInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Добавить") { save() }
                        .fontWeight(.semibold)
                        .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func fetchMetadata() {
        guard let url = URL(string: urlText), !urlText.isEmpty else { return }
        isFetchingMeta = true
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let html = String(data: data, encoding: .utf8) ?? ""
                // Parse og:title
                if let range = html.range(of: "og:title\" content=\"") {
                    let start = html.index(range.upperBound, offsetBy: 0)
                    if let end = html[start...].firstIndex(of: "\"") {
                        let ogTitle = String(html[start..<end])
                        await MainActor.run {
                            if title.isEmpty { title = ogTitle }
                        }
                    }
                }
                // Fallback to <title>
                if title.isEmpty, let range = html.range(of: "<title>") {
                    let start = html.index(range.upperBound, offsetBy: 0)
                    if let end = html[start...].range(of: "</title>") {
                        let pageTitle = String(html[start..<end.lowerBound])
                        await MainActor.run { if title.isEmpty { title = pageTitle } }
                    }
                }
            } catch {}
            await MainActor.run { isFetchingMeta = false }
        }
    }

    private func save() {
        let mat = MaterialLink(
            url: urlText,
            title: title,
            previewText: previewText,
            type: type,
            tags: tags
        )
        modelContext.insert(mat)
        try? modelContext.save()
        dismiss()
    }
}
