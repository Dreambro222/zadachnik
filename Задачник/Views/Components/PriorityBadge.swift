import SwiftUI

struct PriorityBadge: View {
    let priority: Priority
    var compact: Bool = false

    var body: some View {
        if priority == .none {
            EmptyView()
        } else {
            HStack(spacing: 2) {
                Text(priority.label)
                    .font(.system(size: compact ? 9 : 11, weight: .semibold))
            }
            .foregroundStyle(priority.color)
            .padding(.horizontal, compact ? 5 : 7)
            .padding(.vertical, 3)
            .background(priority.color.opacity(0.12), in: Capsule())
        }
    }
}

struct PriorityPicker: View {
    @Binding var priority: Priority

    var body: some View {
        HStack(spacing: 6) {
            // "Нет" кнопка
            Button { priority = .none } label: {
                Text("Нет")
                    .font(.caption)
                    .foregroundStyle(priority == .none ? .primary : .secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        priority == .none ? Color.secondary.opacity(0.2) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
            }
            .buttonStyle(.plain)

            Divider().frame(height: 20)

            // Звёзды 1–5
            HStack(spacing: 4) {
                ForEach(1...5, id: \.self) { star in
                    let p = Priority(rawValue: star) ?? .low
                    Button {
                        priority = p
                    } label: {
                        Image(systemName: star <= priority.rawValue ? "star.fill" : "star")
                            .font(.system(size: 20))
                            .foregroundStyle(star <= priority.rawValue ? p.color : .secondary.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
