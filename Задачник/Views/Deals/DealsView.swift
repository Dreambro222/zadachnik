import SwiftUI
import SwiftData

struct DealsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \Deal.createdAt, order: .reverse) private var deals: [Deal]
    @Query(sort: \Person.name) private var people: [Person]

    @State private var showAdd = false
    @State private var searchText = ""
    @State private var filterStatus: DealStatus? = nil

    private var filteredDeals: [Deal] {
        deals.filter { deal in
            let searchableNotes = RichText.plainText(RichText.parse(deal.notes))
            let matchesSearch = searchText.isEmpty
                || deal.title.localizedCaseInsensitiveContains(searchText)
                || searchableNotes.localizedCaseInsensitiveContains(searchText)
            let matchesStatus = filterStatus == nil || deal.status == filterStatus
            return matchesSearch && matchesStatus
        }
    }

    private func person(for deal: Deal) -> Person? {
        guard let pid = deal.personId else { return nil }
        return people.first { $0.id == pid }
    }

    var body: some View {
        Group {
            if deals.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    statusFilter
                    Divider()

                    List {
                        ForEach(filteredDeals) { deal in
                            DealRowView(deal: deal, person: person(for: deal))
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        modelContext.delete(deal)
                                        try? modelContext.save()
                                    } label: {
                                        Label("Удалить", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .adaptiveListStyle()
                    .searchable(text: $searchText, prompt: "Поиск договорённостей")
                }
            }
        }
        .navigationTitle("Договорённости")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAdd = true } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Новая договоренность")
                .accessibilityHint("Открывает форму создания договоренности")
            }
        }
        .sheet(isPresented: $showAdd) {
            DealDetailView()
        }
    }

    private var statusFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(nil, label: "Все")
                ForEach(DealStatus.allCases) { status in
                    filterChip(status, label: status.label)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func filterChip(_ status: DealStatus?, label: String) -> some View {
        let isSelected = filterStatus == status
        let color: Color = status?.color ?? .secondary
        return Button {
            if reduceMotion {
                filterStatus = filterStatus == status ? nil : status
            } else {
                withAnimation { filterStatus = filterStatus == status ? nil : status }
            }
        } label: {
            Text(label)
                .font(.caption)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(isSelected ? .white : color)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? color : color.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Фильтр: \(label)")
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "handshake.fill")
                .font(.system(size: 56))
                .foregroundStyle(.blue.gradient)

            Text("Нет договорённостей")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Добавьте сделки, партнёрства или договорённости с процентами")
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

// MARK: - Deal Row

struct DealRowView: View {
    @State var deal: Deal
    var person: Person?
    @State private var showDetail = false

    var body: some View {
        Button { showDetail = true } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(deal.title)
                            .font(.body)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)

                        if let p = person {
                            Label(p.name, systemImage: "person.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Image(systemName: deal.status.icon)
                            .foregroundStyle(deal.status.color)
                        if deal.amount > 0 {
                            Text(deal.amountFormatted)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.primary)
                        }
                    }
                }

                // Progress bar
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Прогресс")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(deal.percent))%")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(deal.percent >= 100 ? .green : .primary)
                    }

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(.secondary.opacity(0.2))
                                .frame(height: 6)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(deal.percent >= 100 ? Color.green : Color.blue)
                                .frame(width: geo.size.width * min(deal.percent / 100, 1), height: 6)
                        }
                    }
                    .frame(height: 6)
                }

                if let due = deal.dueDate {
                    Label(due.shortLabel, systemImage: "calendar")
                        .font(.caption2)
                        .foregroundStyle(due < Date() ? .red : .secondary)
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showDetail) {
            DealDetailView(deal: deal)
        }
    }
}
