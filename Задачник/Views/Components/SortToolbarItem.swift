import SwiftUI

enum SortOption: String, CaseIterable, Identifiable {
    case dateCreated  = "dateCreated"
    case dateDue      = "dateDue"
    case priority     = "priority"
    case importance   = "importance"
    case name         = "name"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dateCreated: return "Дата создания"
        case .dateDue:     return "Срок"
        case .priority:    return "Приоритет"
        case .importance:  return "Важность"
        case .name:        return "Название"
        }
    }

    var icon: String {
        switch self {
        case .dateCreated: return "clock"
        case .dateDue:     return "calendar"
        case .priority:    return "flag.fill"
        case .importance:  return "star.fill"
        case .name:        return "textformat.abc"
        }
    }
}

struct SortToolbarButton: View {
    @Binding var sortOption: SortOption
    @Binding var ascending: Bool

    var body: some View {
        Menu {
            ForEach(SortOption.allCases) { option in
                Button {
                    if sortOption == option {
                        ascending.toggle()
                    } else {
                        sortOption = option
                        ascending = false
                    }
                } label: {
                    HStack {
                        Label(option.label, systemImage: option.icon)
                        if sortOption == option {
                            Image(systemName: ascending ? "chevron.up" : "chevron.down")
                        }
                    }
                }
            }
        } label: {
            Label("Сортировка", systemImage: "arrow.up.arrow.down")
                .labelStyle(.iconOnly)
        }
    }
}

// MARK: - Sorting helpers for TaskItem arrays

extension Array where Element == TaskItem {
    func sorted(by option: SortOption, ascending: Bool) -> [TaskItem] {
        let result: [TaskItem]
        switch option {
        case .dateCreated:
            result = sorted { $0.createdAt < $1.createdAt }
        case .dateDue:
            result = sorted {
                let a = $0.dueDate ?? Date.distantFuture
                let b = $1.dueDate ?? Date.distantFuture
                return a < b
            }
        case .priority:
            result = sorted { $0.priorityRaw > $1.priorityRaw }
        case .importance:
            result = sorted { $0.importanceScore > $1.importanceScore }
        case .name:
            result = sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        }
        return ascending ? result : result.reversed()
    }
}
