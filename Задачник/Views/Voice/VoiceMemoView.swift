import SwiftUI
import SwiftData
import AVFoundation
import UniformTypeIdentifiers

struct VoiceMemosView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \VoiceMemo.createdAt, order: .reverse) private var memos: [VoiceMemo]
    @StateObject private var recorder = VoiceRecorderService.shared

    @State private var isRecording = false
    @State private var showPermissionAlert = false
    @State private var recordingFileURL: URL?
    @State private var showImportPicker = false
    @State private var importingMemo: VoiceMemo?   // memo being processed (transcribing)
    @State private var importError: String?
    @State private var showImportError = false

    // All audio types Whisper accepts + OGG/Opus
    private let importTypes: [UTType] = {
        var types: [UTType] = [.audio, .mp3, .mpeg4Audio, .wav, .aiff]
        let extra = ["ogg", "oga", "opus", "webm", "flac", "m4a", "mp4"]
        for ext in extra {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }()

    var body: some View {
        Group {
            if memos.isEmpty && !isRecording {
                emptyState
            } else {
                List {
                    if isRecording { recordingRow }
                    ForEach(memos) { memo in
                        VoiceMemoRowView(memo: memo, isImporting: importingMemo?.id == memo.id) {
                            deleteMemo(memo)
                        }
                    }
                }
                .adaptiveListStyle()
            }
        }
        .navigationTitle("Голосовые")
        .toolbar {
            ToolbarItem {
                Button {
                    showImportPicker = true
                } label: {
                    Label("Импорт", systemImage: "square.and.arrow.down")
                }
                .help("Импортировать аудиофайл (OGG, MP3, WAV, M4A…)")
            }
            ToolbarItem(placement: .primaryAction) {
                recordButton
            }
        }
        .fileImporter(
            isPresented: $showImportPicker,
            allowedContentTypes: importTypes,
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            for url in urls { importAudio(from: url) }
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
        .alert("Ошибка импорта", isPresented: $showImportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "Неизвестная ошибка")
        }
    }

    // MARK: - Record button

    private var recordButton: some View {
        Button {
            if isRecording {
                stopRecording()
            } else {
                startRecording()
            }
        } label: {
            Group {
                if reduceMotion {
                    Image(systemName: isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.title2)
                        .foregroundStyle(isRecording ? .red : .blue)
                } else {
                    Image(systemName: isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.title2)
                        .foregroundStyle(isRecording ? .red : .blue)
                        .symbolEffect(.pulse, isActive: isRecording)
                }
            }
        }
        .accessibilityLabel(isRecording ? "Остановить запись" : "Начать запись")
        .accessibilityHint("Управляет записью голосового сообщения")
    }

    // MARK: - Recording indicator row

    private var recordingRow: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
                .modifier(PulseEffectModifier(enabled: !reduceMotion))

            VStack(alignment: .leading, spacing: 2) {
                Text("Запись...")
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(.red)

                Text(formatDuration(recorder.recordingDuration))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Audio level visualizer
            HStack(spacing: 2) {
                ForEach(0..<8) { i in
                    let height: CGFloat = max(4, CGFloat(recorder.audioLevel) * 28 * CGFloat.random(in: 0.5...1.0))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.red.opacity(0.7 + Double(i) * 0.03))
                        .frame(width: 3, height: height)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.1), value: recorder.audioLevel)
                }
            }
        }
        .padding(.vertical, 4)
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
                let url = try recorder.startRecording()
                recordingFileURL = url
                isRecording = true
            } catch {
                print("[VoiceMemo] Recording error: \(error)")
            }
        }
    }

    private func stopRecording() {
        guard let result = recorder.stopRecording() else {
            isRecording = false
            return
        }
        isRecording = false

        let fileName = result.url.lastPathComponent
        let memo = VoiceMemo(fileName: fileName, duration: result.duration)
        modelContext.insert(memo)
        try? modelContext.save()

        // Transcribe in background
        Task {
            let text = await recorder.transcribe(url: result.url)
            if !text.isEmpty {
                memo.transcription = text
                try? modelContext.save()
            }
        }
    }

    private func deleteMemo(_ memo: VoiceMemo) {
        if let url = memo.fileURL {
            try? FileManager.default.removeItem(at: url)
        }
        modelContext.delete(memo)
        try? modelContext.save()
    }

    // MARK: - Import external audio

    private func importAudio(from url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        do {
            let (destURL, duration) = try recorder.importAudioSync(from: url)

            let ext = destURL.pathExtension.lowercased()
            let isTelegramVoice = ["ogg", "oga", "opus"].contains(ext)

            let memo = VoiceMemo(
                fileName: destURL.lastPathComponent,
                duration: duration,
                isCallRecording: false,
                callSource: isTelegramVoice ? .telegram : .microphone
            )
            modelContext.insert(memo)
            try? modelContext.save()

            // Transcribe in background via Whisper
            importingMemo = memo
            Task {
                let result = await WhisperService.shared.transcribe(url: destURL)
                memo.transcription = result.text
                memo.whisperUsed = result.method == .whisper
                try? modelContext.save()
                if importingMemo?.id == memo.id { importingMemo = nil }
            }
        } catch {
            importError = error.localizedDescription
            showImportError = true
        }
    }

    private func formatDuration(_ d: TimeInterval) -> String {
        let mins = Int(d) / 60
        let secs = Int(d) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.blue.gradient)
                .padding(.top, 32)

            Text("Нет записей")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Запишите голосовое или импортируйте аудиофайл")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button {
                    startRecording()
                } label: {
                    Label("Записать", systemImage: "mic.fill")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    showImportPicker = true
                } label: {
                    Label("Импорт OGG / MP3…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PulseEffectModifier: ViewModifier {
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

// MARK: - Voice Memo Row

struct VoiceMemoRowView: View {
    let memo: VoiceMemo
    var isImporting: Bool = false
    let onDelete: () -> Void

    @StateObject private var recorder = VoiceRecorderService.shared
    @State private var isPlaying = false

    private var fileExt: String {
        memo.fileName.components(separatedBy: ".").last?.lowercased() ?? "m4a"
    }

    private var isOgg: Bool { ["ogg", "oga", "opus"].contains(fileExt) }

    private var sourceLabel: String {
        if memo.isCallRecording { return memo.callSource.label }
        if isOgg { return "Telegram" }
        if memo.fileName.hasPrefix("import_") { return "Импорт" }
        return ""
    }

    var body: some View {
        HStack(spacing: 12) {
            // Play / loading button
            Button {
                if !isImporting { togglePlayback() }
            } label: {
                if isImporting {
                    ProgressView()
                        .frame(width: 36, height: 36)
                } else {
                    Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(isPlaying ? .red : .blue)
                }
            }
            .buttonStyle(.plain)
            .disabled(isImporting)

            VStack(alignment: .leading, spacing: 4) {
                // Title row
                HStack(spacing: 6) {
                    Text(memo.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.body)
                        .fontWeight(.medium)

                    if !sourceLabel.isEmpty {
                        Text(sourceLabel)
                            .font(.caption2)
                            .foregroundStyle(isOgg ? Color(red: 0.15, green: 0.56, blue: 0.88) : .secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                (isOgg ? Color(red: 0.15, green: 0.56, blue: 0.88) : Color.secondary).opacity(0.12),
                                in: Capsule()
                            )
                    }
                }

                HStack(spacing: 8) {
                    if memo.duration > 0 {
                        Label(memo.durationLabel, systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text(fileExt.uppercased())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                }

                if isImporting {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.7)
                        Text("Транскрибирование…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if !memo.transcription.isEmpty {
                    Text(memo.transcription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                } else if memo.fileName.hasPrefix("import_") {
                    Text("Нет транскрипции")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .italic()
                }
            }

            Spacer()
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
                NSLog("[VoiceMemo] Playback error: \(error)")
            }
        }
    }
}
