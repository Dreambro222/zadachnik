import SwiftUI
import SwiftData
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Person Media View
// Вкладка "Медиа" в карточке человека:
// • Записи звонков (VoiceMemo с linkedPersonId)
// • Голосовые записи (VoiceMemo без callRecording но с linkedPersonId)
// • Файлы (Attachment с linkedPersonId) через AttachmentSection

struct PersonMediaView: View {
    @Environment(\.modelContext) private var modelContext
    let person: Person

    @Query(sort: \VoiceMemo.createdAt, order: .reverse) private var allMemos: [VoiceMemo]
    @Query(sort: \Attachment.createdAt, order: .reverse) private var allAttachments: [Attachment]

    @StateObject private var recorder = VoiceRecorderService.shared

    @State private var isRecording = false
    @State private var recordingFileURL: URL?
    @State private var isTranscribing = false
    @State private var showPermissionAlert = false
    @State private var showFilePicker = false

    private var callRecordings: [VoiceMemo] {
        allMemos.filter { $0.linkedPersonId == person.id && $0.isCallRecording }
    }

    private var voiceMemos: [VoiceMemo] {
        allMemos.filter { $0.linkedPersonId == person.id && !$0.isCallRecording }
    }

    private var personAttachments: [Attachment] {
        allAttachments.filter { $0.linkedPersonId == person.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Action buttons bar
            actionBar

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {

                    // Recording in progress indicator
                    if isRecording {
                        recordingIndicator
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                    }

                    // Transcribing indicator
                    if isTranscribing {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.8)
                            Text("Транскрибирую...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                    }

                    // Call recordings section
                    if !callRecordings.isEmpty {
                        mediaSection(title: "Записи звонков", icon: "phone.circle.fill", color: .green) {
                            ForEach(callRecordings) { memo in
                                MediaMemoCard(memo: memo, person: person) {
                                    deleteMemo(memo)
                                }
                                .padding(.horizontal, 16)
                            }
                        }
                    }

                    // Voice memos section
                    if !voiceMemos.isEmpty {
                        mediaSection(title: "Аудиозаметки", icon: "mic.circle.fill", color: .blue) {
                            ForEach(voiceMemos) { memo in
                                MediaMemoCard(memo: memo, person: person) {
                                    deleteMemo(memo)
                                }
                                .padding(.horizontal, 16)
                            }
                        }
                    }

                    // Files section
                    if !personAttachments.isEmpty {
                        mediaSection(title: "Файлы", icon: "doc.fill", color: .secondary) {
                            AttachmentSection(
                                entity: .person(person.id),
                                attachments: personAttachments
                            )
                            .padding(.horizontal, 16)
                        }
                    }

                    // Empty state
                    if callRecordings.isEmpty && voiceMemos.isEmpty && personAttachments.isEmpty && !isRecording {
                        emptyState
                    }
                }
                .padding(.bottom, 40)
            }
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
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav, .aiff, .pdf, .image, .plainText, .data],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result: result)
        }
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(spacing: 12) {
            // Record button
            Button {
                if isRecording { stopRecording() } else { startRecording() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(isRecording ? .red : .blue)
                    Text(isRecording ? "Стоп" : "Записать")
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    isRecording ? Color.red.opacity(0.1) : Color.blue.opacity(0.1),
                    in: Capsule()
                )
            }
            .buttonStyle(.plain)
            .symbolEffect(.pulse, isActive: isRecording)

            // Upload button
            Button {
                showFilePicker = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.doc.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                    Text("Загрузить")
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)

            Spacer()

            // Stats
            if !callRecordings.isEmpty || !voiceMemos.isEmpty || !personAttachments.isEmpty {
                Text("\(callRecordings.count + voiceMemos.count) аудио · \(personAttachments.count) файлов")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Recording indicator

    private var recordingIndicator: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
                .symbolEffect(.pulse)

            VStack(alignment: .leading, spacing: 2) {
                Text("Запись...")
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(.red)
                Text(formatDuration(recorder.recordingDuration))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Audio level bars
            HStack(spacing: 2) {
                ForEach(0..<10, id: \.self) { _ in
                    let height: CGFloat = max(4, CGFloat(recorder.audioLevel) * 32 * CGFloat.random(in: 0.4...1.0))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.red.opacity(0.7))
                        .frame(width: 3, height: height)
                        .animation(.easeInOut(duration: 0.1), value: recorder.audioLevel)
                }
            }
        }
        .padding(12)
        .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Section wrapper

    private func mediaSection<Content: View>(
        title: String,
        icon: String,
        color: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(color)
                .padding(.horizontal, 16)
                .padding(.top, 16)

            content()
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
                .padding(.top, 48)

            Text("Нет медиафайлов")
                .font(.title3)
                .fontWeight(.semibold)

            Text("Запишите звонок или загрузите аудио,\nчтобы получить транскрипцию и тезисы от ИИ")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private func startRecording() {
        Task {
            let granted = await recorder.requestMicrophonePermission()
            guard granted else { showPermissionAlert = true; return }
            do {
                let url = try recorder.startRecording()
                recordingFileURL = url
                isRecording = true
            } catch {
                NSLog("[PersonMedia] Record error: \(error)")
            }
        }
    }

    private func stopRecording() {
        guard let result = recorder.stopRecording() else { isRecording = false; return }
        isRecording = false

        let memo = VoiceMemo(
            fileName: result.url.lastPathComponent,
            duration: result.duration,
            isCallRecording: false,
            callSource: .microphone,
            callerName: "",
            linkedPersonId: person.id
        )
        modelContext.insert(memo)
        try? modelContext.save()

        isTranscribing = true
        Task {
            let text = await WhisperService.shared.transcribe(url: result.url)
            memo.transcription = text.text
            memo.whisperUsed = text.method == .whisper
            try? modelContext.save()
            isTranscribing = false
        }
    }

    private func deleteMemo(_ memo: VoiceMemo) {
        if let url = memo.fileURL {
            try? FileManager.default.removeItem(at: url)
        }
        modelContext.delete(memo)
        try? modelContext.save()
    }

    private func handleFileImport(result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }

        let isAudio = ["m4a", "mp3", "wav", "aiff", "caf"].contains(url.pathExtension.lowercased())

        if isAudio {
            // Import as VoiceMemo
            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }

            let dir = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("VoiceMemos", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            let destName = "import_\(UUID().uuidString).\(url.pathExtension)"
            let destURL = dir.appendingPathComponent(destName)

            do {
                try FileManager.default.copyItem(at: url, to: destURL)
                let asset = AVURLAsset(url: destURL)
                let duration = TimeInterval(CMTimeGetSeconds(asset.duration))

                let memo = VoiceMemo(
                    fileName: destName,
                    duration: duration,
                    isCallRecording: true,
                    callSource: .other,
                    callerName: url.deletingPathExtension().lastPathComponent,
                    linkedPersonId: person.id
                )
                modelContext.insert(memo)
                try? modelContext.save()

                isTranscribing = true
                Task {
                    let text = await WhisperService.shared.transcribe(url: destURL)
                    memo.transcription = text.text
                    memo.whisperUsed = text.method == .whisper
                    try? modelContext.save()
                    isTranscribing = false
                }
            } catch {
                NSLog("[PersonMedia] Import error: \(error)")
            }
        } else {
            // Import as Attachment
            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }

            let attDir = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Attachments", isDirectory: true)
            try? FileManager.default.createDirectory(at: attDir, withIntermediateDirectories: true)

            let destName = "\(UUID().uuidString)_\(url.lastPathComponent)"
            let destURL = attDir.appendingPathComponent(destName)

            do {
                try FileManager.default.copyItem(at: url, to: destURL)
                let size = (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? Int64) ?? 0
                let mime = mimeType(for: url.pathExtension)
                let att = Attachment(fileName: destName, mimeType: mime, fileSize: size)
                att.displayName = url.lastPathComponent
                att.linkedPersonId = person.id
                modelContext.insert(att)
                try? modelContext.save()
            } catch {
                NSLog("[PersonMedia] Attachment import error: \(error)")
            }
        }
    }

    private func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png":         return "image/png"
        case "pdf":         return "application/pdf"
        case "txt":         return "text/plain"
        default:            return "application/octet-stream"
        }
    }

    private func formatDuration(_ d: TimeInterval) -> String {
        String(format: "%d:%02d", Int(d) / 60, Int(d) % 60)
    }
}

// MARK: - Media Memo Card

struct MediaMemoCard: View {
    @Bindable var memo: VoiceMemo
    let person: Person
    let onDelete: () -> Void

    @Environment(\.modelContext) private var modelContext
    @StateObject private var recorder = VoiceRecorderService.shared
    @State private var isPlaying = false
    @State private var isTranscribing = false
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header row
            HStack(spacing: 10) {
                // Play/stop
                Button {
                    togglePlayback()
                } label: {
                    Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(isPlaying ? .red : .blue)
                }
                .buttonStyle(.plain)

                // Info
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Label(memo.callSource.label, systemImage: memo.callSource.icon)
                            .font(.subheadline)
                            .fontWeight(.medium)
                        if !memo.callerName.isEmpty {
                            Text("· \(memo.callerName)")
                                .font(.subheadline)
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

                // Expand transcription
                if !memo.transcription.isEmpty {
                    Button {
                        withAnimation(.spring(duration: 0.25)) { isExpanded.toggle() }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "text.alignleft")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Transcription preview
            if !memo.transcription.isEmpty && !isExpanded {
                Text(memo.transcription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if isExpanded && !memo.transcription.isEmpty {
                Text(memo.transcription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            // Action buttons
            HStack(spacing: 8) {
                if memo.transcription.isEmpty {
                    // Transcribe button
                    Button {
                        transcribe()
                    } label: {
                        if isTranscribing {
                            HStack(spacing: 4) {
                                ProgressView().scaleEffect(0.65)
                                Text("Транскрибирую...")
                                    .font(.caption)
                            }
                        } else {
                            Label("Транскрибировать", systemImage: "waveform")
                                .font(.caption)
                                .fontWeight(.semibold)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(.blue)
                    .disabled(isTranscribing)
                }

                if !memo.transcription.isEmpty {
                    SummarizeButton(transcript: memo.transcription, person: person, interaction: nil)
                }

                Spacer()

                // Share
                if let url = memo.fileURL {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                // Delete
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Actions

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
                NSLog("[MediaMemoCard] Playback error: \(error)")
            }
        }
    }

    private func transcribe() {
        guard let url = memo.fileURL else { return }
        isTranscribing = true
        Task {
            let result = await WhisperService.shared.transcribe(url: url)
            memo.transcription = result.text
            memo.whisperUsed = result.method == .whisper
            try? modelContext.save()
            isTranscribing = false
        }
    }
}
