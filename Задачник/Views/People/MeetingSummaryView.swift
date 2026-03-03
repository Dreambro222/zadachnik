import SwiftUI
import SwiftData

// MARK: - Meeting Summary View
// Sheet показывающий ИИ-тезисы встречи/звонка в трёх блоках:
// Тема, Договорились, Действия (с кнопкой создать задачу).

struct MeetingSummaryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let summary: MeetingSummary
    let person: Person
    let interaction: Interaction?

    @State private var createdTaskTitles: Set<String> = []
    @State private var showTaskCreated = false
    @State private var lastCreatedTask = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // Topic block
                    summaryBlock(
                        icon: "doc.text.fill",
                        iconColor: .blue,
                        title: "Тема разговора",
                        items: [summary.topic],
                        showAction: false
                    )

                    // Agreements block
                    if !summary.agreements.isEmpty {
                        summaryBlock(
                            icon: "handshake.fill",
                            iconColor: .green,
                            title: "Договорились",
                            items: summary.agreements,
                            showAction: false
                        )
                    }

                    // Actions block
                    if !summary.actions.isEmpty {
                        actionsBlock
                    }

                    // Copy all button
                    Button {
                        copyAll()
                    } label: {
                        Label("Скопировать всё", systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .padding(.top, 8)
                }
                .padding(16)
            }
            .navigationTitle("Тезисы")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .overlay(alignment: .bottom) {
            if showTaskCreated {
                taskCreatedToast
            }
        }
    }

    // MARK: - Summary block

    private func summaryBlock(
        icon: String,
        iconColor: Color,
        title: String,
        items: [String],
        showAction: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(iconColor)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(iconColor)
                            .frame(width: 6, height: 6)
                            .padding(.top, 7)
                        Text(item)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(iconColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(iconColor.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - Actions block with "+ Задача" buttons

    private var actionsBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Действия", systemImage: "checkmark.circle.fill")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(summary.actions, id: \.self) { action in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: createdTaskTitles.contains(action) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(createdTaskTitles.contains(action) ? .green : .orange)
                            .font(.system(size: 16))
                            .padding(.top, 2)

                        Text(action)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                            .strikethrough(createdTaskTitles.contains(action))
                            .foregroundStyle(createdTaskTitles.contains(action) ? .secondary : .primary)

                        Spacer()

                        if !createdTaskTitles.contains(action) {
                            Button {
                                createTask(title: action)
                            } label: {
                                Label("Задача", systemImage: "plus.circle.fill")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.orange, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text("Создана")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.orange.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - Toast

    private var taskCreatedToast: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Задача «\(lastCreatedTask)» создана")
                .font(.subheadline)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
        .padding(.bottom, 32)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Actions

    private func createTask(title: String) {
        let task = TaskItem(
            title: title,
            notes: summary.topic.isEmpty ? "" : "Из звонка: \(summary.topic)",
            priority: .medium
        )
        task.linkedPersonId = person.id
        modelContext.insert(task)
        try? modelContext.save()

        createdTaskTitles.insert(title)
        lastCreatedTask = String(title.prefix(30))
        withAnimation(.spring(duration: 0.3)) { showTaskCreated = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation { showTaskCreated = false }
        }
    }

    private func copyAll() {
        var lines: [String] = []
        lines.append("📋 \(summary.topic)")
        if !summary.agreements.isEmpty {
            lines.append("\n🤝 Договорились:")
            summary.agreements.forEach { lines.append("• \($0)") }
        }
        if !summary.actions.isEmpty {
            lines.append("\n✅ Действия:")
            summary.actions.forEach { lines.append("• \($0)") }
        }
        let text = lines.joined(separator: "\n")
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

// MARK: - Summarize Button View
// Reusable component used in InteractionRowView and PersonMediaView

struct SummarizeButton: View {
    let transcript: String
    let person: Person
    let interaction: Interaction?

    @StateObject private var aiManager = AIManager.shared
    @State private var isLoading = false
    @State private var summary: MeetingSummary?
    @State private var showSummary = false
    @State private var errorMessage: String?

    var body: some View {
        Button {
            generateSummary()
        } label: {
            if isLoading {
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Анализирую...")
                        .font(.caption)
                }
            } else {
                Label("Тезисы", systemImage: "sparkles")
                    .font(.caption)
                    .fontWeight(.semibold)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .tint(.purple)
        .disabled(isLoading || transcript.isEmpty)
        .sheet(isPresented: $showSummary) {
            if let s = summary {
                MeetingSummaryView(summary: s, person: person, interaction: interaction)
            }
        }
        .alert("Ошибка", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func generateSummary() {
        isLoading = true
        Task {
            do {
                let result = try await aiManager.summarizeMeeting(transcript: transcript)
                await MainActor.run {
                    summary = result
                    isLoading = false
                    showSummary = true
                    // Save summary to interaction if provided
                    if let interaction {
                        interaction.summary = (try? JSONEncoder().encode(result)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    }
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
