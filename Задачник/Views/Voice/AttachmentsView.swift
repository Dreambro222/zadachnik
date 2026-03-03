import SwiftUI
import SwiftData
import QuickLook
import UniformTypeIdentifiers

struct AttachmentsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \Attachment.createdAt, order: .reverse) private var attachments: [Attachment]

    @State private var showFilePicker  = false
    @State private var previewURL: URL?
    @State private var isDragTargeted  = false
    @State private var isImporting     = false
    @State private var importError: String?

    var body: some View {
        ZStack {
            // Main content
            Group {
                if attachments.isEmpty {
                    emptyDropZone
                } else {
                    fileGrid
                }
            }

            // Full-screen drop overlay (appears when dragging over the window)
            if isDragTargeted {
                dropOverlay
            }
        }
        .navigationTitle("Файлы")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showFilePicker = true } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Добавить файл")
                .accessibilityHint("Открывает выбор файла для импорта")
            }
            if isImporting {
                ToolbarItem {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        // Drop anywhere on the view
        .onDrop(of: [.fileURL, .image, .pdf, .plainText, .data],
                isTargeted: $isDragTargeted) { providers in
            Task { await importFromProviders(providers) }
            return true
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                for url in urls { importFile(from: url) }
                try? modelContext.save()
            }
        }
        .quickLookPreview($previewURL)
        .alert("Ошибка импорта", isPresented: .constant(importError != nil)) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    // MARK: - Empty State (= drop zone)

    private var emptyDropZone: some View {
        VStack(spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(
                        isDragTargeted ? Color.blue : Color.secondary.opacity(0.25),
                        style: StrokeStyle(lineWidth: 2, dash: [8, 5])
                    )
                    .frame(maxWidth: 400, maxHeight: 280)
                    .background(
                        isDragTargeted
                            ? Color.blue.opacity(0.06)
                            : Color.secondary.opacity(0.03),
                        in: RoundedRectangle(cornerRadius: 24)
                    )
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isDragTargeted)

                VStack(spacing: 12) {
                    Image(systemName: isDragTargeted ? "arrow.down.circle.fill" : "doc.badge.plus")
                        .font(.system(size: 52))
                        .foregroundStyle(isDragTargeted ? .blue : .secondary)
                    .animation(reduceMotion ? nil : .spring(duration: 0.3), value: isDragTargeted)
                        .scaleEffect(isDragTargeted ? 1.15 : 1.0)

                    Text(isDragTargeted ? "Отпустите для добавления" : "Перетащите файлы сюда")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundStyle(isDragTargeted ? .blue : .primary)

                    Text("Или нажмите «+» для выбора файлов\nПоддерживаются любые форматы")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            Button {
                showFilePicker = true
            } label: {
                Label("Выбрать файлы", systemImage: "folder")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - File Grid

    private var fileGrid: some View {
        ScrollView {
            // Drop zone banner at top when list has files
            if isDragTargeted {
                dropBanner
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 12)],
                spacing: 12
            ) {
                ForEach(attachments) { att in
                    AttachmentCard(att: att, previewURL: $previewURL)
                        .contextMenu {
                            if let url = att.fileURL {
                                Button {
                                    previewURL = url
                                } label: {
                                    Label("Просмотр", systemImage: "eye")
                                }
                                ShareLink(item: url) {
                                    Label("Поделиться", systemImage: "square.and.arrow.up")
                                }
                            }
                            Button(role: .destructive) {
                                deleteAttachment(att)
                            } label: {
                                Label("Удалить", systemImage: "trash")
                            }
                        }
                }
            }
            .padding(16)
            .animation(reduceMotion ? nil : .spring(duration: 0.3), value: isDragTargeted)
        }
    }

    // MARK: - Drop overlay (full-screen)

    private var dropOverlay: some View {
        ZStack {
            Color.blue.opacity(0.12)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.blue)
                    .modifier(AttachmentBounceModifier(enabled: !reduceMotion))

                Text("Отпустите файлы")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundStyle(.blue)

                Text("Файлы будут добавлены в хранилище")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(40)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
            .shadow(radius: 20)
        }
    }

    private var dropBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.blue)
            Text("Отпустите файлы для добавления")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.blue)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.blue.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Import Logic

    private func importFromProviders(_ providers: [NSItemProvider]) async {
        await MainActor.run { isImporting = true }

        let attachmentsDir = attachmentsDirectory()

        for provider in providers {
            if let url = await loadFileURL(from: provider) {
                await MainActor.run {
                    copyAndSave(url: url, to: attachmentsDir)
                }
            }
        }

        await MainActor.run {
            try? modelContext.save()
            isImporting = false
        }
    }

    private func loadFileURL(from provider: NSItemProvider) async -> URL? {
        // Try loading as URL first (works for file drops from Finder)
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return await withCheckedContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    if let data = item as? Data,
                       let url  = URL(dataRepresentation: data, relativeTo: nil) {
                        continuation.resume(returning: url)
                    } else if let url = item as? URL {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
        return nil
    }

    private func importFile(from url: URL) {
        let dir = attachmentsDirectory()
        guard url.startAccessingSecurityScopedResource() else {
            copyAndSave(url: url, to: dir)
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        copyAndSave(url: url, to: dir)
    }

    private func copyAndSave(url: URL, to dir: URL) {
        let destName = UUID().uuidString + "_" + url.lastPathComponent
        let destURL  = dir.appendingPathComponent(destName)

        do {
            try FileManager.default.copyItem(at: url, to: destURL)
            let size = (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? Int64) ?? 0
            let att  = Attachment(
                fileName: destName,
                mimeType: mimeType(for: url.pathExtension),
                fileSize: size
            )
            // Store original display name separately
            att.displayName = url.lastPathComponent
            modelContext.insert(att)
        } catch {
            importError = error.localizedDescription
        }
    }

    private func attachmentsDirectory() -> URL {
        let dir = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func deleteAttachment(_ att: Attachment) {
        if let url = att.fileURL { try? FileManager.default.removeItem(at: url) }
        modelContext.delete(att)
        try? modelContext.save()
    }

    private func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png":         return "image/png"
        case "gif":         return "image/gif"
        case "webp":        return "image/webp"
        case "pdf":         return "application/pdf"
        case "txt":         return "text/plain"
        case "md":          return "text/markdown"
        case "mp4":         return "video/mp4"
        case "mov":         return "video/quicktime"
        case "mp3":         return "audio/mpeg"
        case "zip":         return "application/zip"
        case "docx":        return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xlsx":        return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        default:            return "application/octet-stream"
        }
    }
}

// MARK: - Attachment Card

struct AttachmentCard: View {
    let att: Attachment
    @Binding var previewURL: URL?

    var body: some View {
        Button {
            previewURL = att.fileURL
        } label: {
            VStack(spacing: 10) {
                // Thumbnail or icon
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(iconBackground)
                        .frame(height: 100)

                    if att.isImage, let url = att.fileURL, let img = loadImage(from: url) {
                        img
                            .resizable()
                            .scaledToFill()
                            .frame(height: 100)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        Image(systemName: fileIcon)
                            .font(.system(size: 36))
                            .foregroundStyle(iconColor)
                    }
                }

                VStack(spacing: 3) {
                    Text(att.displayName ?? att.fileName)
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)

                    Text(att.fileSizeLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(.background, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.separator, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(att.displayName ?? att.fileName)
        .accessibilityHint("Открывает предпросмотр файла")
    }

    private var fileIcon: String {
        if att.isImage  { return "photo.fill" }
        if att.isPDF    { return "doc.richtext.fill" }
        switch att.mimeType {
        case "text/plain", "text/markdown": return "doc.text.fill"
        case "video/mp4", "video/quicktime": return "film.fill"
        case "audio/mpeg": return "music.note"
        case "application/zip": return "archivebox.fill"
        case let m where m.contains("word"):  return "doc.fill"
        case let m where m.contains("sheet"): return "tablecells.fill"
        default: return "doc.fill"
        }
    }

    private var iconColor: Color {
        if att.isImage  { return .blue }
        if att.isPDF    { return .red }
        switch att.mimeType {
        case "video/mp4", "video/quicktime": return .purple
        case "audio/mpeg": return .pink
        case "application/zip": return .orange
        default: return .secondary
        }
    }

    private var iconBackground: Color {
        iconColor.opacity(0.1)
    }

    #if os(macOS)
    private func loadImage(from url: URL) -> Image? {
        guard let nsImage = NSImage(contentsOf: url) else { return nil }
        return Image(nsImage: nsImage)
    }
    #else
    private func loadImage(from url: URL) -> Image? {
        guard let data = try? Data(contentsOf: url),
              let uiImage = UIImage(data: data) else { return nil }
        return Image(uiImage: uiImage)
    }
    #endif
}

private struct AttachmentBounceModifier: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.symbolEffect(.bounce, options: .repeating)
        } else {
            content
        }
    }
}
