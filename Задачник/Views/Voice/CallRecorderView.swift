import SwiftUI
import SwiftData

// MARK: - Call Recorder View
// Экран записи звонков через BlackHole (системный аудио) или микрофон.
// После записи — автотранскрипция через Whisper API.

struct CallRecorderView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \Person.name) private var people: [Person]
    @Query(
        filter: #Predicate<VoiceMemo> { $0.isCallRecording == true },
        sort: \VoiceMemo.createdAt,
        order: .reverse
    ) private var callRecordings: [VoiceMemo]

    @StateObject private var recorder = CallRecorderService.shared

    @State private var selectedSource: CallSource = .zoom
    @State private var selectedPersonId: UUID? = nil
    @State private var callerName: String = ""
    @State private var useBlackHole: Bool = true
    @State private var currentMemo: VoiceMemo? = nil
    @State private var isTranscribing = false
    @State private var showBlackHoleAlert = false
    @State private var showPermissionAlert = false
    @State private var showSetupGuide = false

    var body: some View {
        VStack(spacing: 0) {
            // Setup banner if BlackHole not installed
            if !recorder.blackHoleAvailable {
                blackHoleBanner
            }

            List {
                // Recording controls section
                Section {
                    recordingCard
                } header: {
                    Text("Новая запись")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Past recordings
                if !callRecordings.isEmpty {
                    Section {
                        ForEach(callRecordings) { memo in
                            CallRecordingRowView(memo: memo) {
                                deleteMemo(memo)
                            }
                        }
                    } header: {
                        Text("Записи звонков (\(callRecordings.count))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .adaptiveListStyle()
        }
        .navigationTitle("Запись звонков")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showSetupGuide = true
                } label: {
                    Image(systemName: "questionmark.circle")
                }
            }
        }
        .sheet(isPresented: $showSetupGuide) {
            BlackHoleSetupGuideView()
        }
        .alert("Нет доступа к микрофону", isPresented: $showPermissionAlert) {
            Button("Открыть Настройки") {
                #if os(iOS)
                UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                #endif
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Разрешите доступ к микрофону в Настройках → Задачник")
        }
        .onAppear {
            recorder.checkBlackHoleAvailability()
            if recorder.blackHoleAvailable {
                useBlackHole = true
            }
        }
    }

    // MARK: - Recording card

    private var recordingCard: some View {
        VStack(spacing: 16) {
            // Source picker
            if !recorder.isRecording {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Приложение")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $selectedSource) {
                        ForEach(CallSource.allCases, id: \.self) { source in
                            Label(source.label, systemImage: source.icon).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                // Contact picker
                VStack(alignment: .leading, spacing: 8) {
                    Text("Собеседник (опционально)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if people.isEmpty {
                        TextField("Имя собеседника", text: $callerName)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        HStack {
                            Picker("Выбрать из контактов", selection: $selectedPersonId) {
                                Text("Не выбран").tag(Optional<UUID>.none)
                                ForEach(people) { person in
                                    Text(person.name).tag(Optional(person.id))
                                }
                            }
                            if selectedPersonId == nil {
                                TextField("или введите имя", text: $callerName)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                }

                // BlackHole toggle (macOS only)
                #if os(macOS)
                if recorder.blackHoleAvailable {
                    Toggle(isOn: $useBlackHole) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Записывать через BlackHole", systemImage: "waveform.path.ecg")
                                .font(.body)
                            Text("Пишет оба голоса (системный звук)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tint(.blue)
                } else {
                    Label("BlackHole не установлен — пишется только микрофон", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                #endif
            }

            // Recording indicator
            if recorder.isRecording {
                recordingIndicator
            }

            // Record / Stop button
            Button {
                if recorder.isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                        .font(.title2)
                    Text(recorder.isRecording ? "Остановить" : "Начать запись")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(recorder.isRecording ? Color.red : Color.blue)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(recorder.isRecording ? "Остановить запись звонка" : "Начать запись звонка")
            .accessibilityHint("Запускает или останавливает запись текущего звонка")

            if isTranscribing {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Транскрибирую через Whisper...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Recording indicator

    private var recordingIndicator: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Circle()
                    .fill(.red)
                    .frame(width: 10, height: 10)
                    .modifier(CallPulseEffectModifier(enabled: !reduceMotion))

                Text(formatDuration(recorder.recordingDuration))
                    .font(.title2)
                    .fontWeight(.bold)
                    .monospacedDigit()
                    .foregroundStyle(.red)

                Spacer()

                // Audio level bars
                HStack(spacing: 2) {
                    ForEach(0..<12, id: \.self) { i in
                        let height: CGFloat = max(4, CGFloat(recorder.audioLevel) * 36 * CGFloat.random(in: 0.4...1.0))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.red.opacity(0.6 + Double(i) * 0.03))
                            .frame(width: 3, height: height)
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.1), value: recorder.audioLevel)
                    }
                }
            }

            HStack(spacing: 6) {
                Image(systemName: selectedSource.icon)
                    .foregroundStyle(.secondary)
                Text(selectedSource.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let personName = effectiveCallerName, !personName.isEmpty {
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(personName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if useBlackHole && recorder.blackHoleAvailable {
                    Text("·")
                        .foregroundStyle(.secondary)
                    Label("BlackHole", systemImage: "waveform.path.ecg")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }
        }
        .padding(12)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - BlackHole banner

    private var blackHoleBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.path.ecg")
                .foregroundStyle(.orange)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text("Установите BlackHole для записи обоих голосов")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text("Без него пишется только ваш микрофон")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Как?") {
                showSetupGuide = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .background(Color.orange.opacity(0.1))
    }

    // MARK: - Actions

    private func startRecording() {
        Task {
            let granted = await recorder.requestMicrophonePermission()
            guard granted else {
                showPermissionAlert = true
                return
            }
            do {
                #if os(macOS)
                let fileURL = try recorder.startRecording(useBlackHole: useBlackHole && recorder.blackHoleAvailable)
                #else
                let fileURL = try recorder.startRecording(useBlackHole: false)
                #endif

                // Создаём memo сразу (для привязки)
                let memo = VoiceMemo(
                    fileName: fileURL.lastPathComponent,
                    duration: 0,
                    isCallRecording: true,
                    callSource: selectedSource,
                    callerName: effectiveCallerName ?? "",
                    linkedPersonId: selectedPersonId
                )
                modelContext.insert(memo)
                try? modelContext.save()
                currentMemo = memo
            } catch {
                NSLog("[CallRecorder] Start error: \(error)")
            }
        }
    }

    private func stopRecording() {
        guard let result = recorder.stopRecording() else { return }

        if let memo = currentMemo {
            memo.duration = result.duration
            try? modelContext.save()

            // Транскрипция в фоне
            isTranscribing = true
            Task {
                let transcription = await WhisperService.shared.transcribe(url: result.url)
                memo.transcription = transcription.text
                memo.whisperUsed = transcription.method == .whisper
                try? modelContext.save()
                isTranscribing = false
                NSLog("[CallRecorder] Transcription done via \(transcription.method), length=\(transcription.text.count)")
            }
        }

        currentMemo = nil

        // Сброс формы
        callerName = ""
        selectedPersonId = nil
    }

    private func deleteMemo(_ memo: VoiceMemo) {
        if let url = memo.fileURL {
            try? FileManager.default.removeItem(at: url)
        }
        modelContext.delete(memo)
        try? modelContext.save()
    }

    private var effectiveCallerName: String? {
        if let id = selectedPersonId, let person = people.first(where: { $0.id == id }) {
            return person.name
        }
        return callerName.isEmpty ? nil : callerName
    }

    private func formatDuration(_ d: TimeInterval) -> String {
        let mins = Int(d) / 60
        let secs = Int(d) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Call Recording Row

struct CallRecordingRowView: View {
    let memo: VoiceMemo
    let onDelete: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var recorder = VoiceRecorderService.shared
    @State private var isPlaying = false
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                // Play button
                Button {
                    togglePlayback()
                } label: {
                    Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(isPlaying ? .red : .blue)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 4) {
                    // Source + caller
                    HStack(spacing: 6) {
                        Label(memo.callSource.label, systemImage: memo.callSource.icon)
                            .font(.body)
                            .fontWeight(.medium)

                        if !memo.callerName.isEmpty {
                            Text("· \(memo.callerName)")
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 8) {
                        Label(memo.durationLabel, systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(memo.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if memo.whisperUsed {
                            Label("Whisper", systemImage: "waveform")
                                .font(.caption2)
                                .foregroundStyle(.blue)
                        }
                    }
                }

                Spacer()

                if !memo.transcription.isEmpty {
                    Button {
                        if reduceMotion {
                            isExpanded.toggle()
                        } else {
                            withAnimation { isExpanded.toggle() }
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "text.alignleft")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Transcription
            if isExpanded && !memo.transcription.isEmpty {
                Text(memo.transcription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: onDelete) {
                Label("Удалить", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            if let url = memo.fileURL {
                ShareLink(item: url) {
                    Label("Поделиться", systemImage: "square.and.arrow.up")
                }
                .tint(.blue)
            }
        }
    }

    private func togglePlayback() {
        guard let url = memo.fileURL else { return }
        if isPlaying {
            recorder.stopPlayback()
            isPlaying = false
        } else {
            do {
                try recorder.play(url: url) { isPlaying = false }
                isPlaying = true
            } catch {
                NSLog("[CallRecorder] Playback error: \(error)")
            }
        }
    }
}

private struct CallPulseEffectModifier: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.symbolEffect(.pulse)
        } else {
            content
        }
    }
}

// MARK: - BlackHole Setup Guide

struct BlackHoleSetupGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Header
                    HStack(spacing: 16) {
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 48))
                            .foregroundStyle(.blue.gradient)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("BlackHole")
                                .font(.title2)
                                .fontWeight(.bold)
                            Text("Виртуальный аудио-драйвер для записи системного звука")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    setupStep(
                        number: "1",
                        title: "Установите BlackHole",
                        content: "Откройте Terminal и выполните:",
                        code: "brew install blackhole-2ch",
                        note: "Если brew не установлен: скачайте с existingaudio.com/blackhole"
                    )

                    setupStep(
                        number: "2",
                        title: "Создайте Multi-Output Device",
                        content: "Откройте Audio MIDI Setup (Spotlight → Audio MIDI Setup):\n1. Нажмите + внизу слева\n2. Выберите «Create Multi-Output Device»\n3. Включите: ваши наушники/колонки + BlackHole 2ch",
                        code: nil,
                        note: nil
                    )

                    setupStep(
                        number: "3",
                        title: "Установите как вывод звука",
                        content: "Системные настройки → Звук → Вывод → выберите Multi-Output Device",
                        code: nil,
                        note: "Теперь звук идёт и в наушники, и в BlackHole одновременно"
                    )

                    setupStep(
                        number: "4",
                        title: "Во время звонка",
                        content: "1. Начните звонок в Zoom или Telegram\n2. Откройте Задачник → Запись звонков\n3. Нажмите «Начать запись» — BlackHole пишет оба голоса\n4. После звонка нажмите «Остановить»",
                        code: nil,
                        note: nil
                    )

                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Запись автоматически транскрибируется через Whisper AI")
                            .font(.subheadline)
                    }
                    .padding(12)
                    .background(Color.green.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .padding()
            }
            .navigationTitle("Настройка BlackHole")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }

    private func setupStep(number: String, title: String, content: String, code: String?, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 28, height: 28)
                    Text(number)
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                }
                Text(title)
                    .font(.headline)
            }

            Text(content)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.leading, 40)

            if let code {
                Text(code)
                    .font(.system(.caption, design: .monospaced))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.leading, 40)
            }

            if let note {
                Label(note, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.blue)
                    .padding(.leading, 40)
            }
        }
    }
}
