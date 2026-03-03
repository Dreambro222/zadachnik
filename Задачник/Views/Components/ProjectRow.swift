import SwiftUI

struct ProjectRow: View {
    let project: Project

    private var activeCount: Int { project.activeTasks.count }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color(hex: project.colorHex).opacity(0.2))
                    .frame(width: 30, height: 30)
                Image(systemName: project.icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(hex: project.colorHex))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.body)
                    .lineLimit(1)
                if activeCount > 0 {
                    Text("\(activeCount) активных")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if activeCount > 0 {
                Text("\(activeCount)")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Color(hex: project.colorHex), in: Capsule())
                    .padding(.trailing, 2)
            }
        }
        .contentShape(Rectangle())
    }
}
