import SwiftUI
import SwiftData

struct AddInteractionView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let person: Person

    @State private var date = Date()
    @State private var type: InteractionType = .meeting
    @State private var notes = ""
    @State private var result = ""
    @FocusState private var notesFocused: Bool

    // Audio recording for calls
    @StateObject private var recorder = VoiceRecorderService.shared
    @State private var isRecording = false
    @State private var recordedFileName: String? = nil
    @State private var recordedDuration: TimeInterval = 0
    @State private var isTranscribing = false
    @State private var transcription = ""
    @State private var showPermissionAlert = false

    private var isCallType: Bool {
        type == .call
    }

    var body: some View {
        NavigationStack {
            Form {
                // Header
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            PersonAvatarView(person: person, size: 52)
                            Text(person.name)
                                .font(.headline)
                        }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    .padding(.vertical, 4)
                }

                // Date & Type
                Section("Когда и как") {
                    DatePicker("Дата", selection: $date, displayedComponents: [.date])

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Тип взаимодействия")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible()), count: 4),
                            spacing: 8
                        ) {
                            ForEach(InteractionType.allCases) { t in
                                Button {
                                    type = t
                                } label: {
                                    VStack(spacing: 4) {
                                        ZStack {
                                            Circle()
                                                .fill(type == t ? t.color : t.color.opacity(0.1))
                                                .frame(width: 44, height: 44)
                                            Image(systemName: t.icon)
                                                .font(.system(size: 18))
                                                .foregroundStyle(type == t ? .white : t.color)
                                        }
                                        Text(t.label)
                                            .font(.caption2)
                                            .foregroundStyle(type == t ? t.color : .secondary)
                                            .fontWeight(type == t ? .semibold : .regular)
                                    }
                                }
                                .buttonStyle(.plain)
                                .scaleEffect(type == t ? 1.05 : 1.0)
                                .animation(.spring(duration: 0.2), value: type)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                // Audio recording section — shown for call type
                if isCallType {
                    Section {
                        if let fileName = recordedFileName {
                            // Recording saved
                            HStack(spacing: 12) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.title3)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Запись сохранена")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Text(formatDuration(recordedDuration))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    deleteRecording(fileName: fileName)
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                            }

                            if isTranscribing {
                                HStack(spacing: 8) {
                                    ProgressView().scaleEffect(0.75)
                                    Text("Транскрибирую запись...")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } else if !transcription.isEmpty {
                                Text(transcription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(4)
                            }
                        } else {
                            // Record button
                            Button {
                                if isRecording { stopRecording() } else { startRecording() }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: isRecording ? "stop.circle.fill" : "mic.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(isRecording ? .red : .blue)
                                        .symbolEffect(.pulse, isActive: isRecording)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(isRecording ? "Остановить запись" : "Записать звонок")
                                            .font(.subheadline)
                                            .fontWeight(.medium)
                                            .foregroundStyle(isRecording ? .red : .primary)
                                        if isRecording {
                                            Text(formatDuration(recorder.recordingDuration))
                                                .font(.caption)
                                                .monospacedDigit()
                                                .foregroundStyle(.secondary)
                                        } else {
                                            Text("Аудио сохранится к этому взаимодействию")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Label("Аудиозапись", systemImage: "waveform")
                    }
                }

                // Notes
                Section("Заметки") {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $notes)
                            .focused($notesFocused)
                            .frame(minHeight: 80)
                            .scrollContentBackground(.hidden)

                        if notes.isEmpty {
                            Text("Что обсудили? Детали встречи...")
                                .font(.body)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                }

                // Result
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.right.circle.fill")
                            .foregroundStyle(.green)
                        TextField("Договорились о..., результат...", text: $result, axis: .vertical)
                            .lineLimit(1...4)
                    }
                } header: {
                    Text("Результат / Договорённости")
                } footer: {
                    Text("Что вышло из этого взаимодействия? Следующий шаг?")
                        .font(.caption)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Записать встречу")
            .navigationInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") {
                        // Stop recording if still going
                        if isRecording { _ = recorder.stopRecording() }
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { save() }
                        .fontWeight(.semibold)
                }
            }
            .onAppear { notesFocused = true }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .alert("Нет доступа к микрофону", isPresented: $showPermissionAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Разрешите доступ к микрофону в Настройках → Задачник")
        }
    }

    // MARK: - Audio recording

    private func startRecording() {
        Task {
            let granted = await recorder.requestMicrophonePermission()
            guard granted else { showPermissionAlert = true; return }
            do {
                _ = try recorder.startRecording()
                isRecording = true
            } catch {
                NSLog("[AddInteraction] Record error: \(error)")
            }
        }
    }

    private func stopRecording() {
        guard let result = recorder.stopRecording() else { isRecording = false; return }
        isRecording = false
        recordedFileName = result.url.lastPathComponent
        recordedDuration = result.duration

        // Auto-transcribe
        isTranscribing = true
        Task {
            let text = await WhisperService.shared.transcribe(url: result.url)
            transcription = text.text
            isTranscribing = false
        }
    }

    private func deleteRecording(fileName: String) {
        let dir = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceMemos", isDirectory: true)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(fileName))
        recordedFileName = nil
        recordedDuration = 0
        transcription = ""
    }

    private func formatDuration(_ d: TimeInterval) -> String {
        String(format: "%d:%02d", Int(d) / 60, Int(d) % 60)
    }

    // MARK: - Save

    private func save() {
        // Stop recording if still active
        if isRecording {
            if let result = recorder.stopRecording() {
                recordedFileName = result.url.lastPathComponent
                recordedDuration = result.duration
            }
            isRecording = false
        }

        let interaction = Interaction(
            date: date,
            type: type,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            result: result.trimmingCharacters(in: .whitespacesAndNewlines),
            audioFileName: recordedFileName
        )
        interaction.transcription = transcription
        interaction.person = person
        modelContext.insert(interaction)
        try? modelContext.save()
        dismiss()
    }
}
